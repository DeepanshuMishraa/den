import Foundation
import DenProtocol
import DenServer

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
let socketPath: String = {
    if let i = arguments.firstIndex(of: "--socket"), i + 1 < arguments.count { return arguments[i + 1] }
    return DenPaths.socket.path
}()

if arguments.contains("--version") {
    print("dend protocol \(minimumProtocolVersion)-\(protocolVersion)")
    exit(0)
}

// Asked by the running dend, which can't see grants macOS made after it
// started: a new process reports what the next dend will get. Prints the
// JSON `HostPermissions` and exits before touching the socket.
if arguments.contains("--check-permissions") {
    FileHandle.standardOutput.write(ControlCoding.encode(HostPermissions.probe()))
    exit(0)
}

// Den.app's SSH transport: relay stdin/stdout to this host's dend.
if arguments.contains("--stdio") { StdioProxy.run(socketPath: socketPath) }

do {
    try FileManager.default.createDirectory(at: URL(filePath: socketPath).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch {
    FileHandle.standardError.write(Data("[dend] cannot create \(socketPath)'s directory: \(error)\n".utf8))
    exit(1)
}

// Only one dend per socket: if something already answers, leave it alone.
if let fd = try? UnixSocket.connect(socketPath) {
    close(fd)
    FileHandle.standardError.write(Data("[dend] already running on \(socketPath)\n".utf8))
    exit(0)
}

// ... and even when the socket file is gone but its owner lives. A second
// dend used to steal the path here and orphan the first dend's sessions.
// The kernel releases the lock if we die, so it never goes stale.
let singletonFd: Int32 = {
    do {
        if let fd = try UnixSocket.acquireSingletonLock(socketPath) { return fd }
    } catch {
        FileHandle.standardError.write(Data("[dend] cannot lock \(socketPath).lock: \(error)\n".utf8))
        exit(1)
    }
    let holder = UnixSocket.lockHolderPid(socketPath).map { " (pid \($0))" } ?? ""
    FileHandle.standardError.write(Data("[dend] already running\(holder); leaving it alone\n".utf8))
    exit(0)
}()
_ = singletonFd

#if os(macOS)
let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
#else
let hostName = ProcessInfo.processInfo.hostName
#endif
let server = DenServer(socketPath: socketPath, hostName: hostName)
Task {
    do {
        try await server.start()
    } catch {
        FileHandle.standardError.write(Data("[dend] failed to start: \(error)\n".utf8))
        exit(1)
    }
}
dispatchMain()
