import DenProtocol
import Foundation

/// Runs the system ssh against one host, so `~/.ssh/config`, the agent,
/// known_hosts, ProxyJump and Tailscale SSH all work as they do in a shell.
/// Passwords come from the Keychain through Den's askpass mode; nothing is
/// ever typed into ssh.
struct SSH: Sendable {
    let host: RemoteHost

    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The server turned every credential down.
        case authentication(String)
        /// DNS, routing, refused or timed out: the host isn't answering.
        case unreachable(String)
        /// known_hosts has a different key for this host.
        case hostKeyChanged(String)
        /// Connected and authenticated, but the command failed.
        case remote(status: Int32, String)
        case launch(String)

        var description: String {
            switch self {
            case .authentication(let detail): "The server rejected the login. \(detail)"
            case .unreachable(let detail): "Can't reach the host. \(detail)"
            case .hostKeyChanged(let detail): "The host's SSH key changed since the last connection, so Den stopped. If the server was reinstalled, remove the old key with `ssh-keygen -R <host>` and connect again. \(detail)"
            case .remote(let status, let detail): "The command on the host failed (exit \(status)). \(detail)"
            case .launch(let detail): detail
            }
        }
    }

    struct Output: Sendable {
        let stdout: Data
        let stderr: String
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    static let executable = "/usr/bin/ssh"

    /// Den's own key, installed on hosts after a password login.
    static var keyURL: URL { DenPaths.supportDirectory.appending(path: "ssh/id_ed25519") }

    func arguments(_ command: String, compress: Bool = false) -> [String] {
        var args = [
            "-T", "-e", "none",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            // Trust on first use, like clicking through ssh's yes/no; a
            // changed key still stops the connection.
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=1",
        ]
        if FileManager.default.fileExists(atPath: Self.keyURL.path) {
            // Naming any IdentityFile drops ssh's defaults, so list those too.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let defaults = ["id_ed25519", "id_ecdsa", "id_ed25519_sk", "id_ecdsa_sk", "id_rsa"].map { "\(home)/.ssh/\($0)" }
            for identity in defaults.filter(FileManager.default.fileExists(atPath:)) + [Self.keyURL.path] {
                args += ["-i", identity]
            }
        }
        if compress { args += ["-o", "Compression=yes"] }
        if let user = host.user { args += ["-l", user] }
        if let port = host.port { args += ["-p", String(port)] }
        args += ["--", host.address, command]
        return args
    }

    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let me = Bundle.main.executablePath {
            env["SSH_ASKPASS"] = me
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env[Askpass.accountVariable] = host.account
        }
        return env
    }

    private func process(_ command: String, compress: Bool = false) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: Self.executable)
        process.arguments = arguments(command, compress: compress)
        process.environment = environment()
        return process
    }

    /// Runs `command` on the host, feeding it `input`, and waits for it.
    /// `compress` is for big uploads (dend is ~55 MB, ~22 MB compressed).
    /// `progress` gets the bytes of `input` handed to ssh so far. Cancelling
    /// the calling task ends ssh, so a replaced attempt stops uploading.
    func run(_ command: String, input: Data? = nil, compress: Bool = false,
             progress: (@Sendable (Int) -> Void)? = nil) async -> Result<Output, Failure> {
        let process = process(command, compress: compress)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .failure(.launch("Could not start \(Self.executable): \(error.localizedDescription)"))
        }
        let writer = stdin.fileHandleForWriting
        Self.background {
            if let input {
                let chunk = 1 << 20
                var offset = 0
                while offset < input.count {
                    let end = min(offset + chunk, input.count)
                    do { try writer.write(contentsOf: input[offset ..< end]) } catch { break }
                    offset = end
                    progress?(offset)
                }
            }
            try? writer.close()
        }
        return await withTaskCancellationHandler {
            // Drain both pipes at once so neither fills up and stalls ssh.
            async let out = Self.readAll(stdout.fileHandleForReading)
            async let err = Self.readAll(stderr.fileHandleForReading)
            let (outData, errData) = await (out, err)
            let status = await Self.exitStatus(process)
            let message = String(decoding: errData, as: UTF8.self)
            return status == 0
                ? .success(Output(stdout: outData, stderr: message))
                : .failure(Self.classify(status: status, stderr: message))
        } onCancel: {
            process.terminate()
        }
    }

    private static func background(_ work: @escaping @Sendable () -> Void) {
        DispatchQueue.global().async(execute: work)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            background { continuation.resume(returning: handle.readDataToEndOfFile()) }
        }
    }

    private static func exitStatus(_ process: Process) async -> Int32 {
        await withCheckedContinuation { continuation in
            background {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    /// A long-lived `command` whose stdin and stdout are one end of a socket
    /// pair; the other end is what `DenConnection` reads and writes.
    final class Channel: @unchecked Sendable {
        let fd: Int32
        let process: Process
        private let lock = NSLock()
        private var stderrTail = ""

        init(fd: Int32, process: Process) {
            self.fd = fd
            self.process = process
        }

        func appendStderr(_ data: Data) {
            lock.withLock {
                stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(4000))
            }
        }

        /// What ssh last said on stderr, for explaining a dropped connection.
        var lastError: String { lock.withLock { stderrTail.trimmingCharacters(in: .whitespacesAndNewlines) } }

        func terminate() { if process.isRunning { process.terminate() } }
    }

    func openChannel(_ command: String) -> Result<Channel, Failure> {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            return .failure(.launch("Could not create a socket pair for ssh: \(String(cString: strerror(errno)))."))
        }
        let (mine, theirs) = (pair[0], pair[1])
        let process = process(command)
        let child = FileHandle(fileDescriptor: theirs, closeOnDealloc: false)
        process.standardInput = child
        process.standardOutput = child
        let stderr = Pipe()
        process.standardError = stderr
        let channel = Channel(fd: mine, process: process)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { channel.appendStderr(data) }
        }
        do {
            try process.run()
        } catch {
            close(mine)
            close(theirs)
            return .failure(.launch("Could not start \(Self.executable): \(error.localizedDescription)"))
        }
        // ssh has its own copy now; ours would keep the channel open after it exits.
        close(theirs)
        do {
            try UnixSocket.configure(mine, path: "ssh \(host.label)")
        } catch {
            process.terminate()
            close(mine)
            return .failure(.launch("\(error)"))
        }
        return .success(channel)
    }

    /// ssh exits 255 for its own errors; anything else is the remote command's.
    static func classify(status: Int32, stderr: String) -> Failure {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("Warning: Permanently added") && !$0.hasPrefix("**") }
        let detail = lines.suffix(3).joined(separator: " ")
        guard status == 255 else { return .remote(status: status, detail) }
        let lower = stderr.lowercased()
        if lower.contains("remote host identification has changed") || lower.contains("host key verification failed") {
            return .hostKeyChanged(detail)
        }
        if lower.contains("permission denied") || lower.contains("too many authentication failures") || lower.contains("authentication failed") {
            return .authentication(detail)
        }
        let unreachable = ["could not resolve hostname", "connection refused", "timed out", "no route to host", "network is unreachable", "connection closed by", "host is down"]
        if unreachable.contains(where: lower.contains) { return .unreachable(detail) }
        return .launch(detail.isEmpty ? "ssh exited with status 255 and gave no reason." : detail)
    }
}
