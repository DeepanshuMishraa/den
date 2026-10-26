import Foundation
import Testing
import DenProtocol
@testable import DenServer

/// The control channel the den CLI uses, against a real dend.
@Suite(.serialized) struct ControlTests {
    func connect() async throws -> TestClient {
        let path = "/tmp/dend-test-\(UUID().uuidString.prefix(8)).sock"
        let server = DenServer(socketPath: path, hostName: "Test Mac")
        try await server.start()
        let client = try TestClient(path: path)
        client.send(.hello(version: protocolVersion, client: "den-cli-test"))
        return client
    }

    func state(_ c: TestClient) throws -> DenState {
        guard case .state(let state)? = try c.control(.state) else { throw CancellationError() }
        return state
    }

    @Test func launchedCommandRunsLabelledAndCloses() async throws {
        let c = try await connect()
        #expect(try c.control(.watchEvents) == .ok)
        let reply = try c.control(.launch(.session(name: "video"), PaneLaunch(label: "say", command: ["sh", "-c", "exit 4"])))
        guard case .launched(let sid, _, let pane)? = reply else { Issue.record("no launch reply: \(String(describing: reply))"); return }
        #expect(try c.pump(timeout: 10) { c.events.contains(.paneExited(session: sid, pane: pane, exit: .code(4))) })
        // Without keep-open the pane (and its one-pane session) goes away.
        #expect(try c.pump { c.events.contains(.sessionClosed(session: sid)) })
        #expect(try state(c).sessions.isEmpty)
    }

    @Test func keepOpenPaneStaysWithItsExitStatus() async throws {
        let c = try await connect()
        guard case .launched(let sid, _, let first)? = try c.control(.launch(.session(name: "work"), .shell)) else { Issue.record("no session"); return }
        let reply = try c.control(.launch(.split(pane: first, axis: .vertical, before: false),
                                          PaneLaunch(label: "job", command: ["sh", "-c", "echo job-done; exit 3"], keepOpen: true)))
        guard case .launched(_, _, let job)? = reply else { Issue.record("no split"); return }
        #expect(try c.pump(timeout: 10) { (try? state(c))?.sessions.first?.panes.first { $0.id == job }?.exit == .code(3) })

        let session = try #require(try state(c).sessions.first { $0.id == sid })
        #expect(session.tabs.first?.layout == .split(axis: .vertical, ratio: 0.5, first: .pane(first), second: .pane(job)))
        let pane = try #require(session.panes.first { $0.id == job })
        #expect(pane.label == "job")
        #expect(pane.child == nil)

        guard case .text(let text)? = try c.control(.capture(pane: job, format: .text)) else { Issue.record("no capture"); return }
        #expect(text.contains("job-done"))
        #expect(text.contains("[process exited with code 3]"))

        // Input to the dead pane is dropped, not written to a stale fd.
        c.send(.input(job, Data("ignored\r".utf8)))
        c.send(.closePane(job))
        #expect(try c.pump { (try? state(c))?.sessions.first?.panes.map(\.id) == [first] })
    }

    @Test func labelsAndFailuresAreReported() async throws {
        let c = try await connect()
        guard case .launched(_, _, let pane)? = try c.control(.launch(.session(name: "a"), .shell)) else { Issue.record("no session"); return }
        #expect(try c.control(.setLabel(pane: pane, label: "  main ")) == .ok)
        #expect(try state(c).sessions.first?.panes.first?.label == "main")

        guard case .failed(let message)? = try c.control(.launch(.session(name: "a"), .shell)) else { Issue.record("duplicate accepted"); return }
        #expect(message.contains("already exists"))
        guard case .failed? = try c.control(.capture(pane: PaneID(), format: .text)) else { Issue.record("unknown pane accepted"); return }
    }

    /// The app asks dend, not itself: shells inherit dend's privacy grants.
    @Test func permissionsAreReportedForDendItself() async throws {
        let c = try await connect()
        guard case .permissions(let reported)? = try c.control(.permissions) else { Issue.record("no permissions reply"); return }
        // The test runner isn't dend, so the fresh-launch probe is skipped and
        // the reply is this process's direct probe.
        #expect(reported == HostPermissions.probe())
        #expect(reported == HostPermissions.report())
    }

    /// A grant given while dend runs is visible to a new process but not to
    /// the old one; the app must offer a restart, not pretend it's missing.
    @Test func grantsGivenToANewProcessNeedARestart() {
        #expect(HostPermissions.Access.resolve(current: .missing, fresh: .granted) == .needsRestart)
        #expect(HostPermissions.Access.resolve(current: .missing, fresh: .missing) == .missing)
        #expect(HostPermissions.Access.resolve(current: .granted, fresh: .missing) == .granted)
        #expect(HostPermissions.Access.resolve(current: .notApplicable, fresh: .notApplicable) == .notApplicable)
    }
}
