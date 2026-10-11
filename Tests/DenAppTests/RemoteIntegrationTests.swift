import DenProtocol
import Foundation
import Testing
@testable import DenApp

/// Against a real SSH server: `DEN_TEST_SSH=user@host:port` (key login with
/// Den's key) and `scripts/build-dend-linux.sh` already run. Walks the same
/// steps as `AppModel.establish`: probe, install, stream, then speaks the
/// protocol through the channel.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEN_TEST_SSH"] != nil))
struct RemoteIntegrationTests {
    let host = RemoteHost.parse(ProcessInfo.processInfo.environment["DEN_TEST_SSH"] ?? "")

    private func linuxBinary(_ arch: String) -> URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "dist/linux/dend-linux-\(arch)")
    }

    @Test func installsDendAndAttachesOverSSH() async throws {
        let host = try #require(host)
        let ssh = SSH(host: host)

        let first = try (await ssh.run(RemoteSetup.probeCommand)).get()
        let probe = try #require(RemoteSetup.parseProbe(first.text))
        #expect(probe.os == "Linux")

        let binary = linuxBinary(probe.arch)
        let hash = try #require(RemoteSetup.sha256(of: binary))
        if probe.installedHash != hash {
            _ = try (await ssh.run(RemoteSetup.installCommand, input: try Data(contentsOf: binary), compress: true)).get()
        }
        let again = try #require(RemoteSetup.parseProbe(try (await ssh.run(RemoteSetup.probeCommand)).get().text))
        #expect(again.installedHash == hash)

        let channel = try ssh.openChannel(RemoteSetup.streamCommand).get()
        defer {
            channel.terminate()
            close(channel.fd)
        }
        let flags = fcntl(channel.fd, F_GETFL)
        _ = fcntl(channel.fd, F_SETFL, flags & ~O_NONBLOCK)
        for message in [ClientMessage.hello(version: minimumProtocolVersion, client: "test"), .listDirectory(request: 9, path: "~")] {
            let frame = Frame.wrap(message.encode())
            _ = frame.withUnsafeBytes { write(channel.fd, $0.baseAddress, $0.count) }
        }

        var decoder = FrameDecoder()
        var welcome: UInt16?
        var home: String?
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(20)
        while (welcome == nil || home == nil), Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { read(channel.fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            decoder.append(Data(buffer[0 ..< n]))
            while let payload = try decoder.next() {
                switch try ServerMessage.decode(payload) {
                case .welcome(let version, _): welcome = version
                case .directoryListing(9, let path, _): home = path
                default: break
                }
            }
        }
        #expect(welcome == protocolVersion, "stderr: \(channel.lastError)")
        #expect(home?.hasPrefix("/") == true)
    }

    /// A shell on the host's PTY runs commands, and dend reads its process
    /// and folder from /proc.
    @Test func runsAShellOnTheHost() async throws {
        let host = try #require(host)
        let channel = try SSH(host: host).openChannel(RemoteSetup.streamCommand).get()
        defer {
            channel.terminate()
            close(channel.fd)
        }
        let flags = fcntl(channel.fd, F_GETFL)
        _ = fcntl(channel.fd, F_SETFL, flags & ~O_NONBLOCK)
        let session = SessionID()
        let size = GridSize(cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 16)
        func send(_ message: ClientMessage) {
            let frame = Frame.wrap(message.encode())
            _ = frame.withUnsafeBytes { write(channel.fd, $0.baseAddress, $0.count) }
        }
        send(.hello(version: minimumProtocolVersion, client: "test"))
        send(.subscribe)
        send(.createSession(id: session, name: "linux-check", size: size))

        var decoder = FrameDecoder()
        var pane: PaneID?
        var output = ""
        var meta: PaneMeta?
        var sentCommand = false
        var sentExit = false
        var exited = false
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(20)
        while !exited, Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { read(channel.fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            decoder.append(Data(buffer[0 ..< n]))
            while let payload = try decoder.next() {
                switch try ServerMessage.decode(payload) {
                case .layout(let layout) where layout.session.id == session:
                    pane = layout.tabs.first?.root.panes.first
                case .paneOutput(let id, let bytes) where id == pane:
                    output += String(decoding: bytes, as: UTF8.self)
                case .paneMeta(let id, let m) where id == pane:
                    meta = m
                case .paneExited(let id, _) where id == pane:
                    exited = true
                default: break
                }
            }
            if let pane, !sentCommand {
                sentCommand = true
                send(.input(pane, Data("cd /tmp && echo den-ok-$((6*7))\r".utf8)))
            }
            // Then `exit`: dend notices through the pidfd and closes the pane.
            if let pane, !sentExit, output.contains("den-ok-42"), meta?.cwd == "/tmp" {
                sentExit = true
                send(.input(pane, Data("exit\r".utf8)))
            }
        }
        if !exited { send(.killSession(session)) }
        #expect(exited, "the pane didn't close after `exit`")
        #expect(output.contains("den-ok-42"), "output: \(output.suffix(300))")
        #expect(meta?.cwd == "/tmp")
        #expect(meta?.process == "bash")
    }
}
