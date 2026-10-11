import CDenPTY
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import DenProtocol
import DenVT

final class Session {
    let id: SessionID
    var name: String
    var tabs: [TabLayout] = []

    init(id: SessionID, name: String) {
        self.id = id
        self.name = name
    }

    var summary: SessionSummary { SessionSummary(id: id, name: name, tabCount: UInt32(tabs.count)) }
    var layout: SessionLayout { SessionLayout(session: summary, tabs: tabs) }
}

final class ClientConnection {
    let id: Int
    let fd: Int32
    let writer: FDWriter
    var decoder = FrameDecoder()
    var readSource: DispatchSourceRead?
    /// Set by `.subscribe`; subscribed clients receive every session's state.
    var subscribed = false
    var name = "unknown"

    init(id: Int, fd: Int32, queue: DispatchQueue) {
        self.id = id
        self.fd = fd
        self.writer = FDWriter(fd: fd, queue: queue)
    }
}

/// dend: owns sessions, PTYs and the authoritative terminal state machines.
/// Every client keeps a replica of each pane's terminal, seeded from a
/// snapshot and advanced with the same byte stream the server consumed.
public actor DenServer {
    private let executor: QueueExecutor
    private let queue: DispatchQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private let socketPath: String
    private let hostName: String
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var metaTimer: DispatchSourceTimer?

    private var sessions: [Session] = []
    private var panes: [PaneID: Pane] = [:]
    private var paneSession: [PaneID: SessionID] = [:]
    private var connections: [Int: ClientConnection] = [:]
    private var nextConnectionID = 1
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)

    /// A client whose unsent backlog exceeds this is disconnected instead of
    /// letting dend's memory grow without bound.
    private static let maxClientBacklog = 128 * 1024 * 1024

    public init(socketPath: String, hostName: String) {
        self.executor = QueueExecutor(label: "dend")
        self.queue = executor.queue
        self.socketPath = socketPath
        self.hostName = hostName
    }

    public func start() throws {
        listenFD = try UnixSocket.listen(socketPath)
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [self] in assumeIsolated { $0.acceptConnections() } }
        source.resume()
        listenSource = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [self] in assumeIsolated { $0.refreshMeta() } }
        timer.resume()
        metaTimer = timer
        log("listening on \(socketPath)")
    }

    // MARK: Connections

    private func acceptConnections() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            do {
                try UnixSocket.configure(fd, path: socketPath)
            } catch {
                log("dropping connection: \(error)")
                close(fd)
                continue
            }
            let conn = ClientConnection(id: nextConnectionID, fd: fd, queue: queue)
            nextConnectionID += 1
            let cid = conn.id
            conn.writer.onError = { [self] code in
                assumeIsolated { $0.disconnect(cid, reason: "write failed: \(String(cString: strerror(code)))") }
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in assumeIsolated { $0.connectionReadable(cid) } }
            source.setCancelHandler { close(fd) }
            source.resume()
            conn.readSource = source
            connections[cid] = conn
        }
    }

    private func connectionReadable(_ cid: Int) {
        guard let conn = connections[cid] else { return }
        let n = readBuffer.withUnsafeMutableBytes { read(conn.fd, $0.baseAddress, $0.count) }
        if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
            disconnect(cid, reason: n == 0 ? "closed by client" : "read failed: \(String(cString: strerror(errno)))")
            return
        }
        guard n > 0 else { return }
        conn.decoder.append(Data(readBuffer[0 ..< n]))
        do {
            while let payload = try conn.decoder.next() {
                handle(try ClientMessage.decode(payload), from: conn)
                // A handler may have disconnected this client.
                guard connections[cid] != nil else { return }
            }
        } catch {
            disconnect(cid, reason: "protocol error: \(error)")
        }
    }

    private func disconnect(_ cid: Int, reason: String) {
        guard let conn = connections.removeValue(forKey: cid) else { return }
        log("client \(conn.name)#\(cid) disconnected: \(reason)")
        conn.writer.cancel()
        conn.readSource?.cancel()
    }

    private func send(_ message: ServerMessage, to conn: ClientConnection) {
        conn.writer.write(Frame.wrap(message.encode()))
        if conn.writer.pendingBytes > Self.maxClientBacklog {
            disconnect(conn.id, reason: "client fell \(conn.writer.pendingBytes) bytes behind")
        }
    }

    private func broadcast(_ message: ServerMessage) {
        let frame = Frame.wrap(message.encode())
        for conn in connections.values where conn.subscribed {
            conn.writer.write(frame)
            if conn.writer.pendingBytes > Self.maxClientBacklog {
                disconnect(conn.id, reason: "client fell \(conn.writer.pendingBytes) bytes behind")
            }
        }
    }

    private func broadcastSessions() {
        let frame = Frame.wrap(ServerMessage.sessions(sessions.map(\.summary)).encode())
        for conn in connections.values { conn.writer.write(frame) }
    }

    private func broadcastLayout(_ session: Session) {
        broadcast(.layout(session.layout))
    }

    private func broadcastSnapshot(_ pane: Pane) {
        for conn in connections.values where conn.subscribed { sendSnapshot(pane, to: conn) }
    }

    // MARK: Messages

    private func handle(_ message: ClientMessage, from conn: ClientConnection) {
        switch message {
        case .hello(let version, let client):
            conn.name = client
            guard (minimumProtocolVersion ... protocolVersion).contains(version) else {
                send(.error("dend speaks protocol \(minimumProtocolVersion)–\(protocolVersion) but \(client) sent \(version). Restart dend or update the client."), to: conn)
                return
            }
            log("client \(client)#\(conn.id) connected")
            send(.welcome(version: protocolVersion, host: hostName), to: conn)
            send(.sessions(sessions.map(\.summary)), to: conn)

        case .listSessions:
            send(.sessions(sessions.map(\.summary)), to: conn)

        case .createSession(let id, let name, let size):
            let session = Session(id: id, name: name.isEmpty ? SessionNames.random(excluding: Set(sessions.map(\.name))) : name)
            do {
                let pane = try spawnPane(PaneID(), in: session, size: size, cwd: nil)
                session.tabs.append(TabLayout(id: TabID(), root: .pane(pane.id)))
                sessions.append(session)
                broadcastSessions()
                broadcastLayout(session)
                broadcastSnapshot(pane)
            } catch {
                send(.error("\(error)"), to: conn)
            }

        case .subscribe:
            conn.subscribed = true
            for session in sessions {
                send(.layout(session.layout), to: conn)
                for paneID in session.tabs.flatMap(\.root.panes) {
                    guard let pane = panes[paneID] else { continue }
                    sendSnapshot(pane, to: conn)
                }
            }

        case .renameSession(let id, let name):
            guard let session = session(id), !name.isEmpty else { return }
            session.name = name
            broadcastSessions()
            broadcastLayout(session)

        case .renameTab(let tabID, let title):
            guard let session = sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
                  let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.tabs[i].title = trimmed?.isEmpty == false ? trimmed : nil
            broadcastLayout(session)

        case .moveTab(let tabID, let index):
            guard let session = sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
                  let from = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let tab = session.tabs.remove(at: from)
            session.tabs.insert(tab, at: min(Int(index), session.tabs.count))
            broadcastLayout(session)

        case .killSession(let id):
            guard let session = session(id) else { return }
            for paneID in session.tabs.flatMap(\.root.panes) { retire(paneID) }
            session.tabs.removeAll()
            endSession(session)

        case .newTab(let sid, let tab, let paneID, let size, let cwd):
            guard let session = session(sid) else { return }
            do {
                let pane = try spawnPane(paneID, in: session, size: size, cwd: cwd)
                session.tabs.append(TabLayout(id: tab, root: .pane(pane.id)))
                broadcastLayout(session)
                broadcastSnapshot(pane)
                broadcastSessions()
            } catch {
                send(.error("\(error)"), to: conn)
            }

        case .splitPane(let target, let newID, let axis, let size):
            guard let sid = paneSession[target], let session = session(sid),
                  let tabIndex = session.tabs.firstIndex(where: { $0.root.contains(target) }) else { return }
            do {
                let pane = try spawnPane(newID, in: session, size: size, cwd: panes[target]?.meta.cwd)
                session.tabs[tabIndex].root = session.tabs[tabIndex].root.splitting(target, with: pane.id, axis: axis)
                broadcastLayout(session)
                broadcastSnapshot(pane)
            } catch {
                send(.error("\(error)"), to: conn)
            }

        case .setSplitRatio(let tabID, let path, let ratio):
            for session in sessions {
                guard let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { continue }
                session.tabs[i].root = session.tabs[i].root.settingRatio(at: path[...], to: min(max(ratio, 0.1), 0.9))
                broadcastLayout(session)
            }

        case .movePane(let pane, let target, let placement):
            guard let sid = paneSession[pane], let session = session(sid),
                  let i = session.tabs.firstIndex(where: { $0.root.contains(pane) }),
                  let moved = session.tabs[i].root.moving(pane, to: target, placement: placement) else { return }
            session.tabs[i].root = moved
            broadcastLayout(session)

        case .closePane(let id):
            log("client \(conn.name)#\(conn.id) closed \(id)")
            retire(id)
            detach(id, status: 0)

        case .input(let id, let bytes):
            panes[id]?.lastInput = Date()
            panes[id]?.ptyWriter.write(bytes)

        case .resize(let id, let size):
            guard let pane = panes[id] else { return }
            do {
                try pane.resize(size)
                broadcast(.paneResized(id, size))
            } catch {
                send(.error("Resizing \(id) to \(size.cols)x\(size.rows) failed: \(error)"), to: conn)
            }

        case .listDirectory(let request, let path):
            let (resolved, entries) = Self.listDirectory(path)
            send(.directoryListing(request: request, path: resolved, entries: entries), to: conn)
        }
    }

    /// `~` expanded to this user's home; symlinked folders count as folders.
    static func listDirectory(_ path: String) -> (String, [DirectoryEntry]) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let resolved = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard let names = try? fm.contentsOfDirectory(atPath: resolved) else { return (resolved, []) }
        let entries = names.sorted().prefix(Int(DirectoryEntry.maxPerListing)).map { name in
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: (resolved as NSString).appendingPathComponent(name), isDirectory: &isDir)
            return DirectoryEntry(name: name, isDirectory: isDir.boolValue)
        }
        return (resolved, Array(entries))
    }

    private func session(_ id: SessionID) -> Session? { sessions.first { $0.id == id } }

    private func sendSnapshot(_ pane: Pane, to conn: ClientConnection) {
        do {
            send(.paneSnapshot(pane.id, try pane.terminal.snapshot()), to: conn)
            send(.paneMeta(pane.id, pane.meta), to: conn)
            // Always, even empty: clients treat this first one as a sync, not news.
            send(.programStatus(pane.id, pane.status.records), to: conn)
        } catch {
            send(.error("Snapshot of \(pane.id) failed: \(error). The pane keeps running; reattach to retry."), to: conn)
        }
    }

    // MARK: Panes

    private func spawnPane(_ id: PaneID, in session: Session, size: GridSize, cwd: String?) throws -> Pane {
        let pane = try Pane(id: id, size: size, cwd: cwd, queue: queue)
        panes[id] = pane
        paneSession[id] = session.id

        let master = pane.master
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [self] in assumeIsolated { $0.paneReadable(id) } }
        read.setCancelHandler { close(master) }
        read.resume()
        pane.readSource = read

        let pid = pane.pid
        #if os(Linux)
        // No process sources in Linux Dispatch: a pidfd turns readable on
        // exit. Kernels before 5.3 lack pidfds; refreshMeta polls those.
        let pidfd = den_pidfd_open(pid)
        if pidfd >= 0 {
            let exit = DispatchSource.makeReadSource(fileDescriptor: pidfd, queue: queue)
            exit.setEventHandler { [self] in assumeIsolated { $0.paneProcessExited(id, pid: pid) } }
            exit.setCancelHandler { close(pidfd) }
            exit.resume()
            pane.exitSource = exit
        }
        #else
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in assumeIsolated { $0.paneProcessExited(id, pid: pid) } }
        exit.resume()
        pane.exitSource = exit
        #endif
        return pane
    }

    private func paneReadable(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        var chunk = Data()
        // Coalesce bursts into one message, but yield regularly so one noisy
        // pane cannot starve the others.
        for _ in 0 ..< 8 {
            let n = readBuffer.withUnsafeMutableBytes { read(pane.master, $0.baseAddress, $0.count) }
            if n > 0 {
                chunk.append(contentsOf: readBuffer[0 ..< n])
                continue
            }
            if n < 0, errno == EAGAIN || errno == EINTR { break }
            // EOF or EIO: the PTY slave side is gone; exit handling follows.
            pane.readSource?.cancel()
            break
        }
        guard !chunk.isEmpty else { return }
        // Before the VT engine: a status query's reply must go out ahead of
        // the DA reply a program sends right after it.
        applyStatus(pane.statusScanner.feed(chunk), to: pane)
        // Echo of what the user just typed isn't the agent working.
        if Date().timeIntervalSince(pane.lastInput) > Self.echoWindow { pane.agentOutput = true }
        pane.terminal.write(chunk)
        broadcast(.paneOutput(id, chunk))
    }

    private func paneProcessExited(_ id: PaneID, pid: pid_t, reaped: Int32? = nil) {
        var status: Int32 = reaped ?? 0
        if reaped == nil { waitpid(pid, &status, WNOHANG) }
        log("\(id) process \(pid) exited with status \(status)")
        if panes[id] != nil { paneReadable(id) }
        retire(id)
        detach(id, status: status)
    }

    /// Stops a pane's process and IO. Safe to call more than once.
    private func retire(_ id: PaneID) {
        guard let pane = panes.removeValue(forKey: id) else { return }
        pane.terminate()
        let pid = pane.pid
        // Reap in the background so the child does not linger as a zombie.
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// Removes a pane from its session's layout and notifies clients.
    private func detach(_ id: PaneID, status: Int32) {
        guard let sid = paneSession.removeValue(forKey: id), let session = session(sid) else { return }
        broadcast(.paneExited(id, status: status))
        session.tabs = session.tabs.compactMap { tab in
            guard let root = tab.root.removing(id) else { return nil }
            return TabLayout(id: tab.id, root: root, title: tab.title)
        }
        if session.tabs.isEmpty {
            endSession(session)
        } else {
            broadcastLayout(session)
            broadcastSessions()
        }
    }

    private func endSession(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        for (paneID, sid) in paneSession where sid == session.id { paneSession.removeValue(forKey: paneID) }
        broadcast(.sessionClosed(session.id))
        broadcastSessions()
    }

    private func refreshMeta() {
        for (id, pane) in panes where pane.exitSource == nil {
            var status: Int32 = 0
            if waitpid(pane.pid, &status, WNOHANG) == pane.pid { paneProcessExited(id, pid: pane.pid, reaped: status) }
        }
        for (id, pane) in panes {
            expireStatus(of: pane)
            let meta = pane.probeMeta()
            if meta != pane.meta {
                pane.meta = meta
                broadcast(.paneMeta(id, meta))
            }
            inferAgentStatus(of: pane)
        }
    }

    // MARK: Program status (OSC 7501)

    private func applyStatus(_ events: [StatusScanner.Event], to pane: Pane) {
        guard !events.isEmpty else { return }
        var changed = false
        for event in events {
            switch event {
            case .status(.query):
                pane.ptyWriter.write(StatusReport.queryReply)
            case .status(let report):
                pane.reportsOwnStatus = true
                if case .update(let record) = report, record.phase.isTransient { pane.statusOwner = pane.foregroundGroup() }
                changed = pane.status.apply(report) || changed
            case .promptStart:
                changed = pane.status.dropTransient() || changed
            case .fullReset:
                changed = pane.status.removeAll() || changed
            }
        }
        if changed { broadcast(.programStatus(pane.id, pane.status.records)) }
    }

    /// The record dend reports for agents that don't report their own.
    static let inferredID = ["den-agent"]
    /// Output this soon after input is taken for echo.
    static let echoWindow: TimeInterval = 0.4

    /// One inference tick for an agent that doesn't speak OSC 7501. When no
    /// agent runs, or it turns out to report status itself, any inferred
    /// record goes.
    private func inferAgentStatus(of pane: Pane) {
        let output = pane.agentOutput
        pane.agentOutput = false
        let isAgent = AgentStatusInference.isAgent(pane.meta.process)
        if !isAgent { pane.reportsOwnStatus = false }
        guard isAgent, !pane.reportsOwnStatus else {
            pane.agentInference = nil
            if pane.status.records.contains(where: { $0.id == Self.inferredID }), pane.status.apply(.clear(id: Self.inferredID)) {
                broadcast(.programStatus(pane.id, pane.status.records))
            }
            return
        }
        var inference = pane.agentInference ?? AgentStatusInference()
        let phase = inference.tick(output: output, title: pane.terminal.title)
        pane.agentInference = inference
        guard let phase else { return }
        pane.status.apply(.update(StatusRecord(id: Self.inferredID, phase: phase, app: pane.meta.process)))
        broadcast(.programStatus(pane.id, pane.status.records))
    }

    /// Working and blocked records end with the process that reported them.
    private func expireStatus(of pane: Pane) {
        guard pane.status.hasTransient, let owner = pane.statusOwner, kill(-owner, 0) == -1, errno == ESRCH else { return }
        pane.statusOwner = nil
        if pane.status.dropTransient() { broadcast(.programStatus(pane.id, pane.status.records)) }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[dend] \(message)\n".utf8))
    }
}

extension SplitNode {
    /// Sets the ratio of the split reached by following `path` (0 = first,
    /// 1 = second) from this node.
    func settingRatio(at path: ArraySlice<UInt8>, to ratio: Float) -> SplitNode {
        guard case .split(let axis, let r, let a, let b) = self else { return self }
        guard let step = path.first else { return .split(axis: axis, ratio: ratio, first: a, second: b) }
        let rest = path.dropFirst()
        return step == 0
            ? .split(axis: axis, ratio: r, first: a.settingRatio(at: rest, to: ratio), second: b)
            : .split(axis: axis, ratio: r, first: a, second: b.settingRatio(at: rest, to: ratio))
    }
}

enum SessionNames {
    static let adjectives = ["dawn", "drifting", "cosmic", "bright", "golden", "quiet", "amber", "silver", "misty", "velvet", "hidden", "lunar", "rapid", "gentle", "wild", "frosty"]
    static let nouns = ["summit", "cedar", "dune", "cliff", "quarry", "harbor", "meadow", "canyon", "river", "grove", "ridge", "lagoon", "tundra", "forest", "valley", "comet"]

    static func random(excluding taken: Set<String>) -> String {
        for _ in 0 ..< 64 {
            let name = "\(adjectives.randomElement() ?? "new")-\(nouns.randomElement() ?? "session")"
            if !taken.contains(name) { return name }
        }
        return "session-\(taken.count + 1)"
    }
}
