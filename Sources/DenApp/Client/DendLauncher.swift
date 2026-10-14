import Foundation
import DenProtocol

/// Finds or starts the local dend. dend runs in its own session so it (and
/// every shell it owns) outlives the app.
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

    /// Also used by the `den` CLI, which polls the socket itself.
    static func spawn() throws(LaunchError) {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "dend"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LaunchError(description: "dend is missing next to the Den executable. Rebuild with `swift build` or reinstall Den.")
        }
        try? FileManager.default.createDirectory(at: DenPaths.supportDirectory, withIntermediateDirectories: true)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Without this, macOS counts dend (and every shell under it) as
        // Den's own process: after ⌘Q the Dock keeps Den's icon with "Stop
        // running as background service", and that action kills every
        // session. Disclaimed, dend is its own responsible process, so Den
        // quits cleanly and reattaches on the next launch. Terminal.app
        // and iTerm2 do the same for their shells.
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
}

/// libsystem SPI (no public header), stable since macOS 10.14.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32
