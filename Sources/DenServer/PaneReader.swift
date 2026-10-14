#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Reads one pane's PTY on a dedicated thread. A macOS PTY read returns at
/// most 1KB, so throughput is the wakeup rate: a thread parked in poll(2)
/// turns around in microseconds, where a dispatch source pays a kqueue
/// event plus a worker-thread handoff for every kilobyte.
///
/// Bytes collect in a buffer that dend's queue takes in batches, so a busy
/// server gets fewer, larger chunks. Reading pauses while more than
/// `backlogHigh` bytes are read but not yet parsed.
final class PaneReader: @unchecked Sendable {
    static let backlogHigh = 8 * 1024 * 1024
    static let backlogLow = 1024 * 1024
    /// A batch smaller than this at EAGAIN is interactive output: deliver it.
    static let bridgeThreshold = 1024
    /// Direct read retries across one refill gap before delivering the batch.
    static let bridgeSpins = 64

    private let fd: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    /// Runs on the reader thread when bytes are waiting and no take is pending.
    private let onReadable: @Sendable () -> Void

    // Guarded by `cond`.
    private let cond = NSCondition()
    private var buffer = Data()
    private var takePending = false
    private var backlog = 0
    private var stopping = false
    private var flushes: [@Sendable () -> Void] = []
    /// The thread exited and closed its descriptors.
    private var finished = false

    init(fd: Int32, onReadable: @escaping @Sendable () -> Void) throws {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        for p in pipeFDs { _ = fcntl(p, F_SETFL, fcntl(p, F_GETFL) | O_NONBLOCK) }
        self.fd = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        self.onReadable = onReadable
    }

    func start(name: String) {
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Everything read since the last take.
    func take() -> Data {
        cond.lock()
        defer { cond.unlock() }
        takePending = false
        let data = buffer
        buffer = Data()
        return data
    }

    /// `count` bytes from earlier takes are parsed; reading may resume.
    func release(_ count: Int) {
        cond.lock()
        backlog -= count
        if backlog < Self.backlogLow { cond.signal() }
        cond.unlock()
    }

    /// Reads whatever the PTY holds now, then runs `then` on the reader
    /// thread after the `onReadable` for those bytes.
    func flush(then: @escaping @Sendable () -> Void) {
        cond.lock()
        guard !finished else {
            cond.unlock()
            return then()
        }
        flushes.append(then)
        wakeLocked()
        cond.unlock()
    }

    /// Ends the thread, which then closes the PTY. Safe to call more than once.
    func stop() {
        cond.lock()
        stopping = true
        cond.signal()
        wakeLocked()
        cond.unlock()
    }

    /// Under `cond`, so the pipe can't be closed (and its number reused) mid-write.
    private func wakeLocked() {
        guard !finished else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    private func run() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        var closed = false
        loop: while true {
            cond.lock()
            while backlog > Self.backlogHigh, !stopping { cond.wait() }
            let stop = stopping
            cond.unlock()
            if stop { break }

            if poll(&fds, 2, -1) < 0, errno != EINTR { break }
            if fds[1].revents != 0 {
                var sink = [UInt8](repeating: 0, count: 64)
                while read(wakeRead, &sink, sink.count) > 0 {}
            }
            // The PTY hands out 1KB a read and a busy writer refills it within
            // microseconds. Like Ghostty's gather stage: under 1KB is
            // interactive and goes out at once; past that the stream is
            // saturated, so bridge refill gaps with a few direct retries and
            // hand over batches of up to 64KB instead of every kilobyte.
            var total = 0
            var spins = 0
            while total < chunk.count {
                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress.map { $0 + total }, $0.count - total) }
                if n > 0 {
                    total += n
                    spins = 0
                    continue
                }
                if n < 0, errno == EINTR { continue }
                if n < 0, errno == EAGAIN {
                    if total < Self.bridgeThreshold || spins >= Self.bridgeSpins { break }
                    spins += 1
                    continue
                }
                // EOF or EIO: the PTY slave side is gone; process exit
                // handling (dend's exit source) takes it from here.
                closed = true
                break
            }
            if total > 0 {
                cond.lock()
                buffer.append(contentsOf: chunk[0 ..< total])
                backlog += total
                let notify = !takePending
                takePending = true
                cond.unlock()
                if notify { onReadable() }
            }
            cond.lock()
            let pendingFlushes = flushes
            flushes.removeAll()
            cond.unlock()
            for flush in pendingFlushes { flush() }
            if closed { break loop }
        }
        // Flushes queued after the last pass still expect to run.
        cond.lock()
        finished = true
        let leftover = flushes
        flushes.removeAll()
        close(wakeRead)
        close(wakeWrite)
        cond.unlock()
        close(fd)
        for flush in leftover { flush() }
    }
}
