import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// libc entry points by their own name, where Swift methods would shadow them.
private func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, addr, len) }
private func sysListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int { write(fd, buf, count) }

#if canImport(Glibc)
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
private let streamSocket = SOCK_STREAM
#endif

/// Locations shared by dend and its clients.
public enum DenPaths {
    /// `~/Library/Application Support/Den` on macOS, `~/.den` on Linux (where
    /// Den.app installs dend as `~/.den/bin/dend`).
    public static var supportDirectory: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Den", directoryHint: .isDirectory)
        #else
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".den", directoryHint: .isDirectory)
        #endif
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
    /// Session reopened on launch, as a plain file so dev and bundled builds
    /// (whose UserDefaults domains differ) remember the same one.
    public static var lastSession: URL { supportDirectory.appending(path: "last-session") }
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
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return addr
    }

    /// Opens a non-blocking client connection to `path`.
    public static func connect(_ path: String) throws(SocketError) -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, streamSocket, 0)
        guard fd >= 0 else { throw SocketError(operation: "socket", path: path, errno: errno) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
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
    /// Callers must first take `acquireSingletonLock`: replacing the path
    /// while another dend owns it would orphan that dend's sessions.
    public static func listen(_ path: String) throws(SocketError) -> Int32 {
        var addr = try address(path)
        unlink(path)
        let fd = socket(AF_UNIX, streamSocket, 0)
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
        guard sysListen(fd, 64) == 0 else {
            let e = errno
            close(fd)
            throw SocketError(operation: "listen", path: path, errno: e)
        }
        try configure(fd, path: path)
        return fd
    }

    /// Socket buffer per direction. macOS defaults Unix sockets to 8KB, so a
    /// flood of pane output crossed to the client 8KB per wakeup.
    static let bufferBytes: Int32 = 2 * 1024 * 1024

    public static func configure(_ fd: Int32, path: String) throws(SocketError) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // Best effort: the kernel caps it (kern.ipc.maxsockbuf), and a
        // smaller buffer only costs throughput.
        var size = bufferBytes
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SocketError(operation: "fcntl O_NONBLOCK", path: path, errno: errno)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// One dend per socket, enforced with an flock'd sidecar lock held for
    /// the process's life. A socket connect-test alone is not enough: if the
    /// socket file was deleted out from under a live owner, a second dend
    /// would steal the path and orphan the first dend's sessions.
    /// Returns the fd (keep it open for life), or nil when another live dend
    /// holds the lock. The holder's pid is written into the lock file.
    public static func acquireSingletonLock(_ socketPath: String) throws(SocketError) -> Int32? {
        let lockPath = socketPath + ".lock"
        let fd = lockPath.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
        guard fd >= 0 else { throw SocketError(operation: "open lock", path: lockPath, errno: errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            close(fd)
            if e == EWOULDBLOCK || e == EAGAIN { return nil }
            throw SocketError(operation: "flock", path: lockPath, errno: e)
        }
        let pidLine = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = ftruncate(fd, 0)
        _ = pidLine.withCString { write(fd, $0, strlen($0)) }
        return fd
    }

    /// Best-effort pid of the dend holding `socketPath`'s lock, for messages.
    public static func lockHolderPid(_ socketPath: String) -> String? {
        guard let s = try? String(contentsOfFile: socketPath + ".lock", encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Buffered non-blocking writer for a socket or PTY fd. Not thread-safe;
/// callers confine it to one queue.
public final class FDWriter {
    public let fd: Int32
    /// Unsent chunks, oldest first; `offset` bytes of the first are sent.
    /// Chunks rather than one Data so a partial write costs O(1), not a
    /// copy of the whole backlog.
    private var pending: [Data] = []
    private var head = 0
    private var offset = 0
    private var source: DispatchSourceWrite?
    private let queue: DispatchQueue
    public private(set) var pendingBytes = 0
    /// Called once when a write fails with an error other than EAGAIN.
    public var onError: ((Int32) -> Void)?

    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        var sent = 0
        if pendingBytes == 0 {
            let written = data.withUnsafeBytes { sysWrite(fd, $0.baseAddress, $0.count) }
            if written == data.count { return }
            if written < 0, errno != EAGAIN, errno != EINTR {
                onError?(errno)
                return
            }
            sent = max(written, 0)
            offset = sent
        }
        pending.append(data)
        pendingBytes += data.count - sent
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
        while head < pending.count {
            let chunk = pending[head]
            let written = chunk.withUnsafeBytes { raw in
                sysWrite(fd, raw.baseAddress.map { $0 + offset }, raw.count - offset)
            }
            if written > 0 {
                pendingBytes -= written
                offset += written
                if offset == chunk.count {
                    head += 1
                    offset = 0
                    // Drop sent chunks now and then rather than on every write.
                    if head >= 64, head * 2 >= pending.count {
                        pending.removeFirst(head)
                        head = 0
                    }
                }
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                return
            } else {
                onError?(errno)
                break
            }
        }
        clear()
        source?.cancel()
        source = nil
    }

    private func clear() {
        pending.removeAll()
        head = 0
        offset = 0
        pendingBytes = 0
    }

    public func cancel() {
        source?.cancel()
        source = nil
        clear()
    }
}
