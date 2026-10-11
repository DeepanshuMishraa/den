import Foundation
import DenProtocol
import DenServer

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
let socketPath: String = {
    if let i = arguments.firstIndex(of: "--socket"), i + 1 < arguments.count { return arguments[i + 1] }
    return DenPaths.socket.path
}()

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

let server = DenServer(socketPath: socketPath, hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
Task {
    do {
        try await server.start()
    } catch {
        FileHandle.standardError.write(Data("[dend] failed to start: \(error)\n".utf8))
        exit(1)
    }
}
dispatchMain()
