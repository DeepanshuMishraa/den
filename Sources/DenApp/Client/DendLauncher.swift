import Foundation
import DenProtocol

/// Finds or starts the local dend. dend runs as its own launchd job so it
/// (and every shell it owns) outlives the app.
enum DendLauncher {
    struct LaunchError: Error, CustomStringConvertible {
        let description: String
    }

    /// The running dend, without suspending: launch uses it to handshake
    /// before the window is built.
    static func connectExisting() -> Int32? {
        try? UnixSocket.connect(DenPaths.socket.path)
    }

    static func connect() async throws(LaunchError) -> Int32 {
        let path = DenPaths.socket.path
        if let fd = connectExisting() { return fd }

        try spawn()
        // dend listens a few ms after spawn; poll finely so launch doesn't
        // sit out a coarse interval.
        for _ in 0 ..< 600 {
            try? await Task.sleep(for: .milliseconds(5))
            if let fd = try? UnixSocket.connect(path) { return fd }
        }
        throw LaunchError(description: "dend did not start listening on \(path) within 3 seconds. See \(DenPaths.log.path) for its output.")
    }

    /// Stops the dend serving this Mac's socket, ending its sessions, so the
    /// next `connect()` starts this build's. For a dend from an older Den,
    /// which refuses this one.
    static func stopRunning() async throws(LaunchError) {
        guard let fd = connectExisting() else { return }
        let pid = peerPID(fd)
        Darwin.close(fd)
        guard let pid, pid > 0 else {
            throw LaunchError(description: "Den couldn't tell which process serves \(DenPaths.socket.path), so nothing was stopped. Quit Den, run `pkill -x dend` in a terminal (this ends every session), then reopen Den.")
        }
        kill(pid, SIGTERM)
        // dend exits at once on SIGTERM; give a busy one 3s before forcing it.
        for _ in 0 ..< 100 where kill(pid, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(30))
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard kill(pid, 0) != 0 else {
            throw LaunchError(description: "dend (pid \(pid)) didn't exit when asked, so it still holds your sessions. Run `kill -9 \(pid)` in a terminal, then reconnect.")
        }
    }

    /// The process on the other end of a Unix socket connection.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    /// Also used by the `den` CLI, which polls the socket itself.
    static func spawn() throws(LaunchError) {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "dend"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LaunchError(description: "dend is missing next to the Den executable. Rebuild with `swift build` or reinstall Den.")
        }
        try? FileManager.default.createDirectory(at: DenPaths.supportDirectory, withIntermediateDirectories: true)

        // A child of Den stays in Den.app's launchd job however detached it
        // is (setsid, disclaimed responsibility): after ⌘Q the Dock keeps
        // Den's icon as "Running in Background", and "Stop Running in
        // Background" ends the job, killing dend and every session. As its
        // own job, dend is nothing of Den's: the icon goes on quit and the
        // sessions stay. Without a GUI login (the CLI over SSH) there's no
        // gui domain, so dend starts as a plain detached child instead.
        do {
            try LaunchdJob(executable: executable, socket: DenPaths.socket.path).start()
        } catch {
            appendToLog("[den] starting dend through launchd failed, starting it from Den instead (it ends if Den's app process is force-stopped): \(error)")
            try spawnDetached(executable)
        }
    }

    private static func spawnDetached(_ executable: URL) throws(LaunchError) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // dend is its own responsible process, not Den's, as Terminal.app
        // and iTerm2 do for their shells.
        _ = responsibility_spawnattrs_setdisclaim(&attr, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, DenPaths.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable.path), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, executable.path, &actions, &attr, argv, environ)
        guard rc == 0 else {
            throw LaunchError(description: "Starting dend at \(executable.path) failed: \(String(cString: strerror(rc))).")
        }
    }

    private static func appendToLog(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: DenPaths.log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// dend as a launchd agent in the user's GUI domain, loaded on demand from a
/// plist in Den's support folder (not ~/Library/LaunchAgents, so it never
/// starts at login and doesn't restart when it exits or is killed).
struct LaunchdJob {
    let executable: URL
    let socket: String

    static let baseLabel = "den.dipxsy.app.dend"

    /// One job per socket, so a `DEN_SOCKET` test dend doesn't replace the
    /// real one's job.
    var label: String {
        guard socket != DenPaths.supportDirectory.appending(path: "dend.sock").path else { return Self.baseLabel }
        // FNV-1a: stable across launches, unlike `hashValue`.
        let hash = socket.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return "\(Self.baseLabel).\(String(hash, radix: 16))"
    }

    var domain: String { "gui/\(getuid())" }
    var service: String { "\(domain)/\(label)" }
    var plistURL: URL { DenPaths.supportDirectory.appending(path: "\(label).plist") }

    func start() throws(DendLauncher.LaunchError) {
        // Loaded and running: that dend is still starting, or its socket
        // file was deleted. Replacing the job would kill its sessions.
        let status = Self.launchctl(["print", service])
        if status.code == 0, status.output.contains("state = running") { return }

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw .init(description: "Could not write \(plistURL.path): \(error.localizedDescription)")
        }

        // Unload a stopped job from an earlier launch, which may name another
        // build's dend, before loading this one.
        if status.code == 0 { _ = Self.launchctl(["bootout", service]) }
        var result = Self.launchctl(["bootstrap", domain, plistURL.path])
        // bootout finishes asynchronously; bootstrap fails until it has.
        for _ in 0 ..< 20 where result.code != 0 {
            usleep(25_000)
            result = Self.launchctl(["bootstrap", domain, plistURL.path])
        }
        guard result.code == 0 else {
            throw .init(description: "launchctl bootstrap \(domain) \(plistURL.path) exited \(result.code): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    var plist: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable.path, "--socket", socket],
            "RunAtLoad": true,
            "KeepAlive": false,
            // A terminal server: never throttled like a background job.
            "ProcessType": "Interactive",
            // dend's shells run in their own sessions, but launchd must not
            // reap anything when dend exits.
            "AbandonProcessGroup": true,
            "StandardOutPath": DenPaths.log.path,
            "StandardErrorPath": DenPaths.log.path,
            "EnvironmentVariables": Self.environment,
        ]
    }

    /// Den's environment, which a spawned dend used to inherit and pass on
    /// to shells, minus what ties it to Den's own launchd job.
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("XPC_") && !key.hasPrefix("__CF") && key != "DEN_SOCKET"
        }
    }

    static func launchctl(_ arguments: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// libsystem SPI (no public header), stable since macOS 10.14.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32
