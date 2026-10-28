import Foundation
import Testing
@testable import DenProtocol

@Suite struct ProtocolTests {
    let size = GridSize(cols: 120, rows: 40, cellWidthPx: 16, cellHeightPx: 34)

    @Test func clientMessagesRoundTrip() throws {
        let messages: [ClientMessage] = [
            .hello(version: protocolVersion, client: "Den.app"),
            .hello(version: protocolVersion, client: "Den.app", snapshotVersion: 2),
            .listSessions,
            .createSession(id: SessionID(), name: "dawn-summit", size: size),
            .subscribe,
            .renameTab(TabID(), title: "api server"),
            .renameTab(TabID(), title: nil),
            .moveTab(TabID(), index: 3),
            .renameSession(SessionID(), name: "Website"),
            .killSession(SessionID()),
            .newTab(session: SessionID(), tab: TabID(), pane: PaneID(), size: size, cwd: "/tmp"),
            .newTab(session: SessionID(), tab: TabID(), pane: PaneID(), size: size, cwd: nil),
            .splitPane(target: PaneID(), new: PaneID(), axis: .vertical, size: size),
            .setSplitRatio(tab: TabID(), path: [0, 1, 1], ratio: 0.3),
            .closePane(PaneID()),
            .movePaneToNewTab(PaneID(), tab: TabID(), index: 2),
            .input(PaneID(), Data("ls -la\r".utf8)),
            .resize(PaneID(), size),
            .listDirectory(request: 7, path: "~/src"),
            .control(request: 9, ControlCoding.encode(ControlRequest.state)),
        ]
        for m in messages {
            #expect(try ClientMessage.decode(m.encode()) == m)
        }
    }

    /// Clients before protocol 7 end the hello after their name; dend still
    /// reads it, to tell them they're too old.
    @Test func helloWithoutSnapshotVersionDecodes() throws {
        var w = BinaryWriter()
        w.u8(0x01); w.u16(6); w.string("Den.app")
        #expect(try ClientMessage.decode(w.data) == .hello(version: 6, client: "Den.app", snapshotVersion: 0))
    }

    @Test func controlFramesRoundTrip() throws {
        let messages: [ServerMessage] = [
            .controlReply(request: 9, ControlCoding.encode(ControlReply.ok)),
            .controlEvent(ControlCoding.encode(ControlEvent(kind: .paneBell(session: SessionID(), pane: PaneID())))),
        ]
        for m in messages {
            #expect(try ServerMessage.decode(m.encode()) == m)
        }
    }

    @Test func controlJSONRoundTrips() throws {
        let a = PaneID(), b = PaneID()
        let requests: [ControlRequest] = [
            .state,
            .launch(.session(name: "video"), PaneLaunch(label: "top", command: ["htop", "-d", "10"], cwd: "/tmp", keepOpen: true)),
            .launch(.tab(session: SessionID()), .shell),
            .launch(.split(pane: a, axis: .vertical, before: true), PaneLaunch(command: ["sleep", "5"])),
            .setLabel(pane: a, label: nil),
            .capture(pane: b, format: .html),
            .watchEvents,
            .permissions,
            .requestScreenRecording,
        ]
        for r in requests {
            #expect(try ControlCoding.decode(ControlRequest.self, from: ControlCoding.encode(r)).get() == r)
        }
        // Dates go through ISO 8601, which keeps whole seconds.
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let pane = PaneState(id: a, label: "nvim", command: ["nvim"], keepOpen: false, process: "nvim", cwd: "/src", title: nil,
                             cols: 80, rows: 24, createdAt: created, child: ProcessState(pid: 42, name: "nvim", path: nil, cwd: "/src"),
                             foreground: nil, exit: .signal(9))
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b))
        let state = DenState(host: "Mac", protocolVersion: protocolVersion, sessions: [
            SessionState(id: SessionID(), name: "video", tabs: [TabState(id: TabID(), title: nil, layout: tree, panes: [pane])]),
        ], clients: [ClientState(id: 1, name: "den-cli", connectedAt: created, subscribed: false, watchingEvents: true)])
        #expect(try ControlCoding.decode(ControlReply.self, from: ControlCoding.encode(ControlReply.state(state))).get() == .state(state))
        let permissions = ControlReply.permissions(HostPermissions(fullDiskAccess: .granted, screenRecording: .missing))
        #expect(try ControlCoding.decode(ControlReply.self, from: ControlCoding.encode(permissions)).get() == permissions)
    }

    @Test func exitStateDecodesWaitStatus() {
        #expect(ExitState(waitStatus: 3 << 8) == .code(3))
        #expect(ExitState(waitStatus: 0) == .code(0))
        #expect(ExitState(waitStatus: 9) == .signal(9))
        #expect(ExitState(waitStatus: 9).shellStatus == 137)
    }

    @Test func serverMessagesRoundTrip() throws {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let tree = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .split(axis: .vertical, ratio: 0.25, first: .pane(b), second: .pane(c)))
        let summary = SessionSummary(id: SessionID(), name: "Default", tabCount: 2)
        let messages: [ServerMessage] = [
            .welcome(version: protocolVersion, host: "Mac Studio"),
            .directoryListing(request: 7, path: "/home/me/src", entries: [DirectoryEntry(name: "den", isDirectory: true), DirectoryEntry(name: "notes.md", isDirectory: false)]),
            .directoryListing(request: 8, path: "/root", entries: []),
            .sessions([summary, SessionSummary(id: SessionID(), name: "Website", tabCount: 0)]),
            .layout(SessionLayout(session: summary, tabs: [TabLayout(id: TabID(), root: tree), TabLayout(id: TabID(), root: .pane(PaneID()), title: "logs")])),
            .paneSnapshot(a, Data([0x47, 0x48, 0x00, 0xFF])),
            .paneOutput(b, Data("\u{1b}[31mred".utf8)),
            .paneResized(c, size),
            .paneMeta(a, PaneMeta(process: "nvim", cwd: "/Users/den")),
            .paneMeta(a, PaneMeta(process: "fish", cwd: nil)),
            .paneExited(a, status: -1),
            .sessionClosed(summary.id),
            .error("boom"),
        ]
        for m in messages {
            #expect(try ServerMessage.decode(m.encode()) == m)
        }
    }

    @Test func truncatedPayloadReportsField() {
        let full = ClientMessage.resize(PaneID(), size).encode()
        #expect(throws: DecodeError.self) { try ClientMessage.decode(full.prefix(full.count - 1)) }
    }

    @Test func unknownTagIsRejected() {
        #expect(throws: DecodeError.invalidTag(0x7F, type: "ClientMessage")) { try ClientMessage.decode(Data([0x7F])) }
    }

    @Test func framesSplitAcrossArbitraryChunks() throws {
        let payloads = (0 ..< 50).map { i in Data((0 ..< (i * 37 % 300)).map { UInt8(truncatingIfNeeded: $0 &* i) }) }
        var stream = Data()
        for p in payloads { stream.append(Frame.wrap(p)) }

        var decoder = FrameDecoder()
        var out: [Data] = []
        var index = stream.startIndex
        var chunk = 1
        while index < stream.endIndex {
            let end = min(index + chunk, stream.endIndex)
            decoder.append(stream[index ..< end])
            while let p = try decoder.next() { out.append(p) }
            index = end
            chunk = chunk % 17 + 3
        }
        #expect(out == payloads)
    }

    @Test func oversizedFrameIsRejected() {
        var decoder = FrameDecoder()
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: FrameError.self) { try decoder.next() }
    }

    @Test func splitTreeEditing() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let tree = SplitNode.pane(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        #expect(tree.panes == [a, b, c])
        #expect(tree.removing(b)?.panes == [a, c])
        #expect(tree.removing(a)?.panes == [b, c])
        #expect(SplitNode.pane(a).removing(a) == nil)
    }
}
