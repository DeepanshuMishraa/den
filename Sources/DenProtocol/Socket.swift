import Foundation

/// Locations shared by dend and its clients.
public enum DenPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Den", directoryHint: .isDirectory)
    }

    /// `DEN_SOCKET` overrides the path, e.g. to run a second dend for testing.
    public static var socket: URL {
        if let override = ProcessInfo.processInfo.environment["DEN_SOCKET"], !override.isEmpty {
            return URL(filePath: override)
        }
        return supportDirectory.appending(path: "dend.sock")
    }
    public static var log: URL { supportDirectory.appending(path: "dend.log") }
    public static var themes: URL { supportDirectory.appending(path: "themes", directoryHint: .isDirectory) }
}

public struct SocketError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let path: String
    public let errno: Int32

    public var description: String {
        "\(operation) \(path) failed: \(String(cString: strerror(errno))) (errno \(errno))"
    }
}

/// Minimal POSIX Unix-domain socket helpers.
public enum UnixSocket {
    private static func address(_ path: String) throws(SocketError) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw SocketError(operation: "socket path too long", path: path, errno: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Opens a non-blocking client connection to `path`.
    public static func connect(_ path: String) throws(SocketError) -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(operation: "socket", path: path, errno: errno) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw SocketError(operation: "connect", path: path, errno: e)
        }
        try configure(fd, path: path)
        return fd
    }

    /// Binds and listens on `path`, replacing a stale socket file.
    public static func listen(_ path: String) throws(SocketError) -> Int32 {
        var addr = try address(path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(operation: "socket", path: path, errno: errno) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw SocketError(operation: "bind", path: path, errno: e)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 64) == 0 else {
            let e = errno
            close(fd)
            throw SocketError(operation: "listen", path: path, errno: e)
        }
        try configure(fd, path: path)
        return fd
    }

    public static func configure(_ fd: Int32, path: String) throws(SocketError) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SocketError(operation: "fcntl O_NONBLOCK", path: path, errno: errno)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
}

/// Buffered non-blocking writer for a socket or PTY fd. Not thread-safe;
/// callers confine it to one queue.
public final class FDWriter {
    public let fd: Int32
    private var pending = Data()
    private var source: DispatchSourceWrite?
    private let queue: DispatchQueue
    public var pendingBytes: Int { pending.count }
    /// Called once when a write fails with an error other than EAGAIN.
    public var onError: ((Int32) -> Void)?

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        if pending.isEmpty {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written == data.count { return }
            if written < 0, errno != EAGAIN, errno != EINTR {
                onError?(errno)
                return
            }
            pending.append(data.dropFirst(max(written, 0)))
        } else {
            pending.append(data)
        }
        armSource()
    }

    private func armSource() {
        guard source == nil else { return }
        let s = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.flush() }
        source = s
        s.resume()
    }

    private func flush() {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                return
            } else {
                onError?(errno)
                pending.removeAll()
                break
            }
        }
        source?.cancel()
        source = nil
    }

    public func cancel() {
        source?.cancel()
        source = nil
        pending.removeAll()
    }
}
