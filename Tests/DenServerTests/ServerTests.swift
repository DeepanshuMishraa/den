import Foundation
import Testing
import DenProtocol
@testable import DenServer
import DenVT

/// Blocking test client speaking the real protocol over the Unix socket.
final class TestClient {
    let fd: Int32
    var decoder = FrameDecoder()
    var replicas: [PaneID: VTTerminal] = [:]
    var layout: SessionLayout?
    var sessions: [SessionSummary] = []
    var metas: [PaneID: PaneMeta] = [:]
    var exited: Set<PaneID> = []
    var status: [PaneID: [StatusRecord]] = [:]

    init(path: String) throws {
        fd = try UnixSocket.connect(path)
    }

    deinit { close(fd) }

    func send(_ m: ClientMessage) {
        let frame = Frame.wrap(m.encode())
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Pumps messages until `done` returns true or the deadline passes.
    func pump(timeout: TimeInterval = 5, until done: () throws -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            if try done() { return true }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { continue }
            decoder.append(Data(buf[0 ..< n]))
            while let payload = try decoder.next() { try apply(ServerMessage.decode(payload)) }
        }
        return try done()
    }

    func apply(_ m: ServerMessage) throws {
        switch m {
        case .sessions(let list): sessions = list
        case .layout(let l): layout = l
        case .paneSnapshot(let id, let bytes): replicas[id] = try VTTerminal(snapshot: bytes)
        case .paneOutput(let id, let bytes): replicas[id]?.write(bytes)
        case .paneResized(let id, let s): try replicas[id]?.resize(cols: s.cols, rows: s.rows, cellWidthPx: s.cellWidthPx, cellHeightPx: s.cellHeightPx)
        case .paneMeta(let id, let meta): metas[id] = meta
        case .paneExited(let id, _): exited.insert(id)
        case .programStatus(let id, let records): status[id] = records
        case .welcome, .sessionClosed, .directoryListing, .error: break
        }
    }

    func text(_ pane: PaneID) throws -> String {
        guard let t = replicas[pane] else { return "" }
        let state = try VTRenderState()
        try state.update(from: t)
        var rows: [Int: [Int: String]] = [:]
        state.forEachCell { cell in
            guard !cell.codepoints.isEmpty else { return }
            rows[cell.row, default: [:]][cell.col] = String(String.UnicodeScalarView(cell.codepoints.compactMap(Unicode.Scalar.init)))
        }
        return rows.keys.sorted().map { r in
            let cols = rows[r] ?? [:]
            return (0 ... (cols.keys.max() ?? 0)).map { cols[$0] ?? " " }.joined()
        }.joined(separator: "\n")
    }
}

@Suite(.serialized) struct ServerTests {
    let size = GridSize(cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16)

    func startServer() async throws -> (DenServer, String) {
        let path = "/tmp/dend-test-\(UUID().uuidString.prefix(8)).sock"
        let server = DenServer(socketPath: path, hostName: "Test Mac")
        try await server.start()
        return (server, path)
    }

    @Test func sessionsSurviveClientReconnect() async throws {
        let (_, path) = try await startServer()
        let sid = SessionID()
        let marker = "den-\(Int.random(in: 1000 ... 9999))"

        do {
            let a = try TestClient(path: path)
            a.send(.hello(version: protocolVersion, client: "test-a"))
            a.send(.createSession(id: sid, name: "persist", size: size))
            #expect(try a.pump { a.sessions.contains { $0.id == sid } })
            a.send(.subscribe)
            #expect(try a.pump { a.layout?.tabs.first != nil && !a.replicas.isEmpty })
            let pane = try #require(a.layout?.tabs.first?.root.panes.first)
            a.send(.input(pane, Data("echo \(marker)\r".utf8)))
            #expect(try a.pump(timeout: 10) { try a.text(pane).components(separatedBy: marker).count >= 3 })
        }

        // A fresh client sees the same screen purely from the snapshot.
        let b = try TestClient(path: path)
        b.send(.hello(version: protocolVersion, client: "test-b"))
        b.send(.subscribe)
        #expect(try b.pump { !b.replicas.isEmpty })
        let pane = try #require(b.layout?.tabs.first?.root.panes.first)
        #expect(try b.text(pane).contains(marker))
    }

    @Test func splitAndCloseUpdateLayout() async throws {
        let (_, path) = try await startServer()
        let c = try TestClient(path: path)
        let sid = SessionID()
        c.send(.hello(version: protocolVersion, client: "test"))
        c.send(.createSession(id: sid, name: "", size: size))
        #expect(try c.pump { c.sessions.contains { $0.id == sid } })
        #expect(c.sessions.first { $0.id == sid }?.name.contains("-") == true)
        c.send(.subscribe)
        #expect(try c.pump { c.layout != nil })
        let first = try #require(c.layout?.tabs.first?.root.panes.first)

        let second = PaneID()
        c.send(.splitPane(target: first, new: second, axis: .horizontal, size: size))
        #expect(try c.pump { c.layout?.tabs.first?.root.panes == [first, second] && c.replicas[second] != nil })

        c.send(.closePane(first))
        #expect(try c.pump { c.layout?.tabs.first?.root == .pane(second) })

        let tab = TabID(), third = PaneID()
        c.send(.newTab(session: sid, tab: tab, pane: third, size: size, cwd: "/tmp"))
        #expect(try c.pump { c.layout?.tabs.count == 2 })
        #expect(try c.pump { c.metas[third]?.cwd?.hasSuffix("/tmp") == true })
    }

    @Test func tabsCanBeRenamedAndReordered() async throws {
        let (_, path) = try await startServer()
        let c = try TestClient(path: path)
        let sid = SessionID()
        c.send(.hello(version: protocolVersion, client: "test"))
        c.send(.subscribe)
        c.send(.createSession(id: sid, name: "tabs", size: size))
        #expect(try c.pump { c.layout?.tabs.count == 1 })
        let first = try #require(c.layout?.tabs.first?.id)
        let second = TabID()
        c.send(.newTab(session: sid, tab: second, pane: PaneID(), size: size, cwd: nil))
        #expect(try c.pump { c.layout?.tabs.count == 2 })

        c.send(.renameTab(second, title: "  api server "))
        #expect(try c.pump { c.layout?.tabs.last?.title == "api server" })
        c.send(.moveTab(second, index: 0))
        #expect(try c.pump { c.layout?.tabs.map(\.id) == [second, first] })
        c.send(.renameTab(second, title: ""))
        #expect(try c.pump { c.layout?.tabs.first?.title == nil })
    }

    @Test func resizeReachesReplicaInOrder() async throws {
        let (_, path) = try await startServer()
        let c = try TestClient(path: path)
        let sid = SessionID()
        c.send(.hello(version: protocolVersion, client: "test"))
        c.send(.createSession(id: sid, name: "r", size: size))
        #expect(try c.pump { !c.sessions.isEmpty })
        c.send(.subscribe)
        #expect(try c.pump { !c.replicas.isEmpty })
        let pane = try #require(c.layout?.tabs.first?.root.panes.first)
        c.send(.resize(pane, GridSize(cols: 100, rows: 30, cellWidthPx: 8, cellHeightPx: 16)))
        c.send(.input(pane, Data("stty size\r".utf8)))
        #expect(try c.pump(timeout: 10) { try c.text(pane).contains("30 100") })
        #expect(c.replicas[pane]?.cols == 100)
    }
}

@Suite(.serialized) struct ProgramStatusServerTests {
    let size = GridSize(cols: 100, rows: 24, cellWidthPx: 8, cellHeightPx: 16)

    /// A subscribed client with one pane, ready for typed commands.
    func paneClient() async throws -> (TestClient, PaneID) {
        let path = "/tmp/dend-test-\(UUID().uuidString.prefix(8)).sock"
        let server = DenServer(socketPath: path, hostName: "Test Mac")
        try await server.start()
        let c = try TestClient(path: path)
        c.send(.hello(version: protocolVersion, client: "test"))
        c.send(.createSession(id: SessionID(), name: "status", size: size))
        c.send(.subscribe)
        #expect(try c.pump { c.layout?.tabs.first != nil && !c.replicas.isEmpty })
        return (c, try #require(c.layout?.tabs.first?.root.panes.first))
    }

    // `sh` and `\007` keep the commands portable across login shells.
    @Test func workingEndsWithItsProcessWhileDoneStays() async throws {
        let (c, pane) = try await paneClient()
        c.send(.input(pane, Data("sh -c \"printf '\\033]7501;state=working:app=t\\007'; sleep 2\"\r".utf8)))
        #expect(try c.pump(timeout: 10) { c.status[pane] == [StatusRecord(phase: .working(progress: nil), app: "t")] })
        #expect(try c.pump(timeout: 10) { c.status[pane] == [] })

        c.send(.input(pane, Data("sh -c \"printf '\\033]7501;state=done:app=t\\007'\"\r".utf8)))
        #expect(try c.pump(timeout: 10) { c.status[pane] == [StatusRecord(phase: .done, app: "t")] })
        // Through the next prompt and the expiry sweep, done stays.
        _ = try c.pump(timeout: 2.5) { false }
        #expect(c.status[pane] == [StatusRecord(phase: .done, app: "t")])
    }

    @Test func queryIsAnsweredOnThePTY() async throws {
        let (c, pane) = try await paneClient()
        c.send(.input(pane, Data("sh -c \"stty -echo -icanon; printf '\\033]7501;?\\007'; head -c 14 | tr -c 'a-z?:=' _; stty sane\"\r".utf8)))
        #expect(try c.pump(timeout: 10) { try c.text(pane).contains("_______?:state") })
    }
}
