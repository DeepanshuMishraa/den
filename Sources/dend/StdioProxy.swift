import CDenPTY
import DenProtocol
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `dend --stdio`: what Den.app runs over SSH. Connects to this machine's
/// dend (starting it first if needed) and relays the SSH channel to its
/// socket byte for byte, so a remote client speaks the same protocol as a
/// local one. The daemon outlives the proxy, so sessions survive dropped
/// connections.
enum StdioProxy {
    static func run(socketPath: String) -> Never {
        let fd: Int32
        switch connectOrStart(socketPath) {
        case .success(let connected): fd = connected
        case .failure(let message): fail(message)
        }
        // Blocking IO: one thread per direction is all a relay needs.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        let upstream = Thread {
            pump(from: 0, to: fd)
            // The client hung up: tell dend, which then closes its side.
            shutdown(fd, Int32(SHUT_WR))
        }
        upstream.start()
        pump(from: fd, to: 1)
        exit(0)
    }

    private enum Connect {
        case success(Int32)
        case failure(String)
    }

    private static func connectOrStart(_ socketPath: String) -> Connect {
        if let fd = try? UnixSocket.connect(socketPath) { return .success(fd) }
        if let problem = startDaemon(socketPath) { return .failure(problem) }
        for _ in 0 ..< 100 {
            usleep(50_000)
            if let fd = try? UnixSocket.connect(socketPath) { return .success(fd) }
        }
        return .failure("dend did not start listening on \(socketPath) within 5 seconds. See \(DenPaths.log.path) on this host for its output.")
    }

    /// Starts dend detached from this SSH login. Under systemd it goes into
    /// the user manager (so logind's KillUserProcesses doesn't end it with
    /// the SSH session); elsewhere it double-forks into its own session.
    private static func startDaemon(_ socketPath: String) -> String? {
        guard let executable = Bundle.main.executablePath else { return "dend can't find its own executable to start the server." }
        try? FileManager.default.createDirectory(at: DenPaths.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = DenPaths.log.path
        #if os(Linux)
        if startUnderSystemd(executable: executable, socketPath: socketPath, log: log) { return nil }
        #endif
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("--socket"), strdup(socketPath), nil]
        defer { argv.forEach { free($0) } }
        guard den_spawn_detached(executable, argv, log) > 0 else {
            return "Starting dend at \(executable) failed: \(String(cString: strerror(errno)))."
        }
        return nil
    }

    #if os(Linux)
    private static func startUnderSystemd(executable: String, socketPath: String, log: String) -> Bool {
        // Without lingering the user manager stops at logout and takes dend
        // with it; a double fork then survives better (unless logind kills
        // the session's processes, which lingering is for).
        guard ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] != nil,
              FileManager.default.fileExists(atPath: "/var/lib/systemd/linger/\(NSUserName())"),
              let systemdRun = ["/usr/bin/systemd-run", "/bin/systemd-run"].first(where: FileManager.default.isExecutableFile(atPath:)) else { return false }
        let process = Process()
        process.executableURL = URL(filePath: systemdRun)
        process.arguments = [
            "--user", "--quiet", "--collect", "--unit=den-dend",
            "-p", "StandardOutput=append:\(log)", "-p", "StandardError=append:\(log)",
            executable, "--socket", socketPath,
        ]
        // Never let it read or write the SSH channel.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
    #endif

    private static func pump(from source: Int32, to sink: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            var offset = 0
            while offset < n {
                let w = buffer[offset ..< n].withUnsafeBytes { write(sink, $0.baseAddress, $0.count) }
                if w < 0, errno == EINTR { continue }
                guard w > 0 else { return }
                offset += w
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("[dend] \(message)\n".utf8))
        exit(1)
    }
}
