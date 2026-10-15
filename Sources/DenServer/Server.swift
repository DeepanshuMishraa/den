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
    /// Set by the `watchEvents` control request.
    var watchingEvents = false
    var name = "unknown"
    let connectedAt = Date()

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
        emit(.clientDisconnected(client: cid, name: conn.name))
    }

    /// Sends an event to every connection that asked for them.
    private func emit(_ kind: ControlEvent.Kind) {
        let watchers = connections.values.filter(\.watchingEvents)
        guard !watchers.isEmpty else { return }
        let message = ServerMessage.controlEvent(ControlCoding.encode(ControlEvent(kind: kind)))
        for conn in watchers { send(message, to: conn) }
    }

    private func send(_ message: ServerMessage, to conn: ClientConnection) {
        conn.writer.write(message.framed())
        if conn.writer.pendingBytes > Self.maxClientBacklog {
            disconnect(conn.id, reason: "client fell \(conn.writer.pendingBytes) bytes behind")
        }
    }

    private func broadcast(_ message: ServerMessage) {
        let frame = message.framed()
        for conn in connections.values where conn.subscribed {
            conn.writer.write(frame)
            if conn.writer.pendingBytes > Self.maxClientBacklog {
                disconnect(conn.id, reason: "client fell \(conn.writer.pendingBytes) bytes behind")
            }
        }
    }

    private func broadcastSessions() {
        let frame = ServerMessage.sessions(sessions.map(\.summary)).framed()
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
            emit(.clientConnected(client: conn.id, name: client))

        case .listSessions:
            send(.sessions(sessions.map(\.summary)), to: conn)

        case .createSession(let id, let name, let size):
            do {
                _ = try startSession(id: id, name: name, size: size, launch: .shell)
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
            emit(.sessionRenamed(session: id, name: name))

        case .renameTab(let tabID, let title):
            guard let session = sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
                  let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            session.tabs[i].title = trimmed?.isEmpty == false ? trimmed : nil
            broadcastLayout(session)
            emit(.tabRenamed(session: session.id, tab: tabID, title: session.tabs[i].title))

        case .moveTab(let tabID, let index):
            guard let session = sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
                  let from = session.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let tab = session.tabs.remove(at: from)
            session.tabs.insert(tab, at: min(Int(index), session.tabs.count))
            broadcastLayout(session)
            emit(.layoutChanged(session: session.id))

        case .killSession(let id):
            guard let session = session(id) else { return }
            for paneID in session.tabs.flatMap(\.root.panes) { retire(paneID) }
            session.tabs.removeAll()
            endSession(session)

        case .newTab(let sid, let tab, let paneID, let size, let cwd):
            guard let session = session(sid) else { return }
            do {
                _ = try startTab(tab, pane: paneID, in: session, size: size, launch: PaneLaunch(cwd: cwd))
            } catch {
                send(.error("\(error)"), to: conn)
            }

        case .splitPane(let target, let newID, let axis, let size):
            do {
                _ = try split(target, new: newID, axis: axis, before: false, size: size, launch: PaneLaunch(cwd: panes[target]?.meta.cwd))
            } catch {
                send(.error("\(error)"), to: conn)
            }

        case .setSplitRatio(let tabID, let path, let ratio):
            for session in sessions {
                guard let i = session.tabs.firstIndex(where: { $0.id == tabID }) else { continue }
                session.tabs[i].root = session.tabs[i].root.settingRatio(at: path[...], to: min(max(ratio, 0.1), 0.9))
                broadcastLayout(session)
                emit(.layoutChanged(session: session.id))
            }

        case .movePane(let pane, let target, let placement):
            guard let sid = paneSession[pane], let session = session(sid),
                  let i = session.tabs.firstIndex(where: { $0.root.contains(pane) }),
                  let moved = session.tabs[i].root.moving(pane, to: target, placement: placement) else { return }
            session.tabs[i].root = moved
            broadcastLayout(session)
            emit(.layoutChanged(session: sid))

        case .closePane(let id):
            log("client \(conn.name)#\(conn.id) closed \(id)")
            if let sid = paneSession[id] { emit(.paneClosed(session: sid, pane: id)) }
            retire(id)
            detach(id, status: 0)

        case .input(let id, let bytes):
            // A keep-open pane whose program exited has no PTY to write to.
            guard let pane = panes[id], !pane.stopped else { return }
            pane.lastInput = Date()
            pane.ptyWriter.write(bytes)

        case .resize(let id, let size):
            guard let pane = panes[id] else { return }
            do {
                let changed = pane.size != size
                try pane.resize(size)
                broadcast(.paneResized(id, size))
                if changed, let sid = paneSession[id] { emit(.paneResized(session: sid, pane: id, cols: size.cols, rows: size.rows)) }
            } catch {
                send(.error("Resizing \(id) to \(size.cols)x\(size.rows) failed: \(error)"), to: conn)
            }

        case .listDirectory(let request, let path):
            let (resolved, entries) = Self.listDirectory(path)
            send(.directoryListing(request: request, path: resolved, entries: entries), to: conn)

        case .control(let request, let json):
            let reply: ControlReply = switch ControlCoding.decode(ControlRequest.self, from: json) {
            case .success(let control): handle(control, from: conn)
            case .failure(let error): .failed("dend could not read the request (\(error)). Update den and dend to the same version.")
            }
            send(.controlReply(request: request, ControlCoding.encode(reply)), to: conn)
        }
    }

    // MARK: Control (den CLI)

    private func handle(_ request: ControlRequest, from conn: ClientConnection) -> ControlReply {
        switch request {
        case .state:
            return .state(state())

        case .launch(let target, let launch):
            do {
                switch target {
                case .session(let name):
                    if !name.isEmpty, sessions.contains(where: { $0.name == name }) {
                        return .failed("A session named “\(name)” already exists. Pick another name, or add to it with `den run -s \(name)`.")
                    }
                    let (session, tab, pane) = try startSession(id: SessionID(), name: name, size: defaultSize(), launch: launch)
                    return .launched(session: session, tab: tab, pane: pane)
                case .tab(let sid):
                    guard let session = session(sid) else { return .failed("No session \(sid); it may have just closed.") }
                    let tab = TabID()
                    let size = session.tabs.flatMap(\.root.panes).compactMap { panes[$0]?.size }.first ?? defaultSize()
                    let pane = try startTab(tab, pane: PaneID(), in: session, size: size, launch: launch)
                    return .launched(session: sid, tab: tab, pane: pane)
                case .split(let target, let axis, let before):
                    guard let base = panes[target] else { return .failed("No pane \(target); it may have just closed.") }
                    var size = base.size
                    if axis == .horizontal { size.cols = max(size.cols / 2, 2) } else { size.rows = max(size.rows / 2, 2) }
                    var launch = launch
                    if launch.cwd == nil { launch.cwd = base.meta.cwd }
                    let new = PaneID()
                    guard let (sid, tab) = try split(target, new: new, axis: axis, before: before, size: size, launch: launch) else {
                        return .failed("Pane \(target) is not in any tab.")
                    }
                    return .launched(session: sid, tab: tab, pane: new)
                }
            } catch {
                return .failed("\(error)")
            }

        case .setLabel(let id, let label):
            guard let pane = panes[id], let sid = paneSession[id] else { return .failed("No pane \(id); it may have just closed.") }
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            pane.label = trimmed?.isEmpty == false ? trimmed : nil
            emit(.paneLabelChanged(session: sid, pane: id, label: pane.label))
            return .ok

        case .capture(let id, let format):
            guard let pane = panes[id] else { return .failed("No pane \(id); it may have just closed.") }
            do {
                let vtFormat: VTFormat = switch format {
                case .text: .plain
                case .vt: .vt
                case .html: .html
                }
                return .text(try pane.engine.sync { t in Result { () throws(VTError) in try t.format(vtFormat) } }.get())
            } catch {
                return .failed("Formatting \(id) failed: \(error). The pane is unaffected.")
            }

        case .watchEvents:
            conn.watchingEvents = true
            return .ok
        }
    }

    private func state() -> DenState {
        let sessionStates = sessions.map { session in
            SessionState(id: session.id, name: session.name, tabs: session.tabs.map { tab in
                TabState(id: tab.id, title: tab.title, layout: tab.root, panes: tab.root.panes.compactMap { id in
                    guard let pane = panes[id] else { return nil }
                    let (child, foreground) = pane.processes()
                    return PaneState(
                        id: id, label: pane.label, command: pane.command, keepOpen: pane.keepOpen,
                        process: pane.meta.process, cwd: pane.meta.cwd, title: pane.title,
                        cols: pane.size.cols, rows: pane.size.rows, createdAt: pane.createdAt,
                        child: child, foreground: foreground, exit: pane.exit
                    )
                })
            })
        }
        let clients = connections.values.sorted { $0.id < $1.id }.map {
            ClientState(id: $0.id, name: $0.name, connectedAt: $0.connectedAt, subscribed: $0.subscribed, watchingEvents: $0.watchingEvents)
        }
        return DenState(host: hostName, protocolVersion: protocolVersion, sessions: sessionStates, clients: clients)
    }

    /// For panes no client sized yet: any live pane's size (a client sized
    /// it to its window), else 80x24.
    private func defaultSize() -> GridSize {
        panes.values.first(where: { !$0.stopped })?.size ?? GridSize(cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16)
    }

    // MARK: Layout changes shared by the GUI and control paths

    private func startSession(id: SessionID, name: String, size: GridSize, launch: PaneLaunch) throws -> (SessionID, TabID, PaneID) {
        let session = Session(id: id, name: name.isEmpty ? SessionNames.random(excluding: Set(sessions.map(\.name))) : name)
        let tab = TabID()
        let pane = try spawnPane(PaneID(), in: session, size: size, launch: launch)
        session.tabs.append(TabLayout(id: tab, root: .pane(pane.id)))
        sessions.append(session)
        broadcastSessions()
        broadcastLayout(session)
        broadcastSnapshot(pane)
        emit(.sessionCreated(session: id, name: session.name))
        emit(.tabCreated(session: id, tab: tab))
        emit(.paneCreated(session: id, tab: tab, pane: pane.id, label: pane.label))
        return (id, tab, pane.id)
    }

    private func startTab(_ tab: TabID, pane paneID: PaneID, in session: Session, size: GridSize, launch: PaneLaunch) throws -> PaneID {
        let pane = try spawnPane(paneID, in: session, size: size, launch: launch)
        session.tabs.append(TabLayout(id: tab, root: .pane(pane.id)))
        broadcastLayout(session)
        broadcastSnapshot(pane)
        broadcastSessions()
        emit(.tabCreated(session: session.id, tab: tab))
        emit(.paneCreated(session: session.id, tab: tab, pane: pane.id, label: pane.label))
        return pane.id
    }

    /// Nil when `target` isn't in a tab.
    private func split(_ target: PaneID, new: PaneID, axis: SplitAxis, before: Bool, size: GridSize,
                       launch: PaneLaunch) throws -> (SessionID, TabID)? {
        guard let sid = paneSession[target], let session = session(sid),
              let tabIndex = session.tabs.firstIndex(where: { $0.root.contains(target) }) else { return nil }
        let pane = try spawnPane(new, in: session, size: size, launch: launch)
        session.tabs[tabIndex].root = session.tabs[tabIndex].root.splitting(target, with: pane.id, axis: axis, newFirst: before)
        broadcastLayout(session)
        broadcastSnapshot(pane)
        let tab = session.tabs[tabIndex].id
        emit(.paneCreated(session: sid, tab: tab, pane: pane.id, label: pane.label))
        emit(.layoutChanged(session: sid))
        return (sid, tab)
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
            // Waits for the engine to parse everything already broadcast, so
            // the snapshot lines up with the next output this client gets.
            let snapshot = try pane.engine.sync { t in Result { () throws(VTError) in try t.snapshot() } }.get()
            send(.paneSnapshot(pane.id, snapshot), to: conn)
            send(.paneMeta(pane.id, pane.meta), to: conn)
            // Always, even empty: clients treat this first one as a sync, not news.
            send(.programStatus(pane.id, pane.status.records), to: conn)
        } catch {
            send(.error("Snapshot of \(pane.id) failed: \(error). The pane keeps running; reattach to retry."), to: conn)
        }
    }

    // MARK: Panes

    private func spawnPane(_ id: PaneID, in session: Session, size: GridSize, launch: PaneLaunch) throws -> Pane {
        let pane = try Pane(id: id, session: session.id, size: size, launch: launch, socketPath: socketPath, queue: queue)
        panes[id] = pane
        paneSession[id] = session.id
        let sid = session.id
        // Effects fire on the engine queue; hop to dend's queue for state.
        let queue = queue
        pane.engine.setEffects(VTEffects(
            writeBack: { [self] bytes in
                let reply = Data(bytes)
                queue.async { [self] in assumeIsolated { $0.panes[id]?.ptyWriter.write(reply) } }
            },
            bell: { [self] in queue.async { [self] in assumeIsolated { $0.emit(.paneBell(session: sid, pane: id)) } } }
        ), onTitle: { [self] title in
            queue.async { [self] in assumeIsolated { $0.panes[id]?.title = title } }
        })

        let reader = try PaneReader(fd: pane.master) { [self] in
            queue.async { [self] in assumeIsolated { $0.paneReadable(id) } }
        }
        pane.reader = reader
        reader.start(name: "dend.pty.\(id.raw.uuidString.prefix(8))")

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
        guard let pane = panes[id], let reader = pane.reader else { return }
        let chunk = reader.take()
        guard !chunk.isEmpty else { return }
        // Before the VT engine: a status query's reply must go out ahead of
        // the DA reply a program sends right after it.
        applyStatus(pane.statusScanner.feed(chunk), to: pane)
        // Echo of what the user just typed isn't the agent working.
        if Date().timeIntervalSince(pane.lastInput) > Self.echoWindow { pane.agentOutput = true }
        broadcast(.paneOutput(id, chunk))
        feedEngine(pane, chunk)
    }

    /// Hands output to the pane's engine. Clients already have it, so
    /// parsing overlaps the next PTY read instead of gating it.
    /// `fromPTY` is false for text dend adds itself (the exit note), which the
    /// reader never counted.
    private func feedEngine(_ pane: Pane, _ bytes: Data, fromPTY: Bool = true) {
        let count = bytes.count
        let reader = fromPTY ? pane.reader : nil
        pane.engine.write(bytes) { reader?.release(count) }
    }

    private func paneProcessExited(_ id: PaneID, pid: pid_t, reaped: Int32? = nil) {
        var status: Int32 = reaped ?? 0
        if reaped == nil { waitpid(pid, &status, WNOHANG) }
        log("\(id) process \(pid) exited with status \(status)")
        guard let pane = panes[id], !pane.stopped, let reader = pane.reader else { return }
        let exitStatus = status
        // The program's last output goes out before its exit is reported.
        let queue = queue
        reader.flush { [self] in
            queue.async { [self] in assumeIsolated { $0.finishExit(id, pid: pid, status: exitStatus) } }
        }
    }

    private func finishExit(_ id: PaneID, pid: pid_t, status: Int32) {
        guard let pane = panes[id], !pane.stopped else { return }
        paneReadable(id)
        let exit = ExitState(waitStatus: status)
        if let sid = paneSession[id] { emit(.paneExited(session: sid, pane: id, exit: exit)) }
        guard pane.keepOpen else {
            retire(id)
            detach(id, status: status)
            return
        }
        // Keep the pane and its screen; say how it ended, in-stream so every
        // replica shows the same line.
        pane.terminate()
        pane.exit = exit
        let note = switch exit {
        case .code(let code): "\r\n[process exited with code \(code)]\r\n"
        case .signal(let signal): "\r\n[process killed by signal \(signal)]\r\n"
        }
        let bytes = Data(note.utf8)
        broadcast(.paneOutput(id, bytes))
        feedEngine(pane, bytes, fromPTY: false)
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    /// Stops a pane's process and IO. Safe to call more than once.
    private func retire(_ id: PaneID) {
        guard let pane = panes.removeValue(forKey: id) else { return }
        // A keep-open pane that exited was already signalled and reaped.
        guard !pane.stopped else { return }
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
            guard let root = tab.root.removing(id) else {
                if tab.root.contains(id) { emit(.tabClosed(session: sid, tab: tab.id)) }
                return nil
            }
            return TabLayout(id: tab.id, root: root, title: tab.title)
        }
        emit(.layoutChanged(session: sid))
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
        emit(.sessionClosed(session: session.id))
    }

    private func refreshMeta() {
        for (id, pane) in panes where pane.exitSource == nil && !pane.stopped {
            var status: Int32 = 0
            if waitpid(pane.pid, &status, WNOHANG) == pane.pid { paneProcessExited(id, pid: pane.pid, reaped: status) }
        }
        for (id, pane) in panes {
            expireStatus(of: pane)
            let meta = pane.probeMeta()
            if meta != pane.meta {
                pane.meta = meta
                broadcast(.paneMeta(id, meta))
                if let sid = paneSession[id] { emit(.paneProcessChanged(session: sid, pane: id, process: meta.process, cwd: meta.cwd)) }
            }
            let title = pane.title
            if title != pane.lastTitle {
                pane.lastTitle = title
                if let sid = paneSession[id] { emit(.paneTitleChanged(session: sid, pane: id, title: title)) }
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
        let agent = CodingAgent(process: pane.meta.process)
        if agent == nil { pane.reportsOwnStatus = false }
        guard let agent, !pane.reportsOwnStatus else {
            pane.agentInference = nil
            if pane.status.records.contains(where: { $0.id == Self.inferredID }), pane.status.apply(.clear(id: Self.inferredID)) {
                broadcast(.programStatus(pane.id, pane.status.records))
            }
            return
        }
        guard agent.readsScreen else { return applyInference(to: pane, output: output, screen: nil) }
        // The screen is read off the engine queue, after any output still
        // being parsed, so a busy pane never stalls dend's queue.
        let id = pane.id, queue = queue
        pane.engine.async { [self] terminal in
            let screen = agent.signal(screen: terminal.activeText(), title: terminal.title)
            queue.async { [self] in
                assumeIsolated { server in
                    guard let pane = server.panes[id], CodingAgent(process: pane.meta.process) == agent, !pane.reportsOwnStatus else { return }
                    server.applyInference(to: pane, output: output, screen: screen)
                }
            }
        }
    }

    private func applyInference(to pane: Pane, output: Bool, screen: ScreenSignal?) {
        var inference = pane.agentInference ?? AgentStatusInference()
        let phase = inference.tick(output: output, title: pane.title, screen: screen)
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
