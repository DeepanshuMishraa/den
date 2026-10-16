import Foundation
import DenProtocol
import DenVT
import Synchronization

/// A terminal restored on the connection queue and handed to the main
/// actor, which owns it from then on. Never used from two places at once.
struct RestoredTerminal: @unchecked Sendable {
    let terminal: VTTerminal
}

/// A server message as the app receives it: pane snapshots arrive already
/// restored, so the main thread never decodes scrollback.
enum Incoming: Sendable {
    case message(ServerMessage)
    case snapshot(PaneID, Result<RestoredTerminal, VTError>)
}

/// Socket IO for one dend connection. Reads and writes happen on a private
/// serial queue; decoded messages are delivered to the main actor in order.
actor DenConnection {
    private let queue = DispatchSerialQueue(label: "den.connection")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    typealias Deliver = @MainActor @Sendable ([Incoming]) -> Void
    typealias Closed = @MainActor @Sendable (String) -> Void

    private let fd: Int32
    private let deliver: Deliver
    private let closed: Closed
    private var writer: FDWriter?
    private var source: DispatchSourceRead?
    private var decoder = FrameDecoder()
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)
    private var isOpen = true

    init(fd: Int32, deliver: @escaping Deliver, closed: @escaping Closed) {
        self.fd = fd
        self.deliver = deliver
        self.closed = closed
    }

    func start() {
        let writer = FDWriter(fd: fd, queue: queue)
        writer.onError = { [self] code in
            assumeIsolated { $0.shutdown("Lost connection to dend: \(String(cString: strerror(code))).") }
        }
        self.writer = writer
        let fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in assumeIsolated { $0.readable() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Starts IO and sends `greeting` first, from any context without
    /// waiting for the actor, so a handshake can go out mid-launch.
    nonisolated func open(greeting: [ClientMessage]) {
        queue.async { [self] in
            assumeIsolated { conn in
                conn.start()
                for message in greeting { conn.write(message) }
            }
        }
    }

    /// Enqueues a message. Callable from any context; messages are written in
    /// call order, which keeps keystrokes ordered.
    nonisolated func send(_ message: ClientMessage) {
        queue.async { [self] in assumeIsolated { $0.write(message) } }
    }

    /// Ends the connection from this side; `closed` gets `reason`.
    nonisolated func disconnect(_ reason: String) {
        queue.async { [self] in assumeIsolated { $0.shutdown(reason) } }
    }

    private func write(_ message: ClientMessage) {
        guard isOpen else { return }
        writer?.write(Frame.wrap(message.encode()))
    }

    private func readable() {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n == 0 { return shutdown("dend closed the connection. Your sessions keep running if dend is still alive.") }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return shutdown("Reading from dend failed: \(String(cString: strerror(errno))).")
        }
        buffer.withUnsafeBytes { decoder.append(UnsafeRawBufferPointer(rebasing: $0[0 ..< n])) }
        var batch: [ServerMessage] = []
        do {
            while let payload = try decoder.next() { batch.append(try ServerMessage.decode(payload)) }
        } catch {
            return shutdown("dend sent data this client cannot read (\(error)). Restart Den to reconnect.")
        }
        guard !batch.isEmpty else { return }
        let incoming = Self.restoreSnapshots(batch)
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(incoming) } }
    }

    /// Restores every snapshot in `batch`, in parallel: an attach sends one
    /// per pane, each with its full scrollback.
    private static func restoreSnapshots(_ batch: [ServerMessage]) -> [Incoming] {
        let snapshots = batch.indices.filter { if case .paneSnapshot = batch[$0] { true } else { false } }
        guard !snapshots.isEmpty else { return batch.map(Incoming.message) }
        let slots = Mutex([Result<RestoredTerminal, VTError>?](repeating: nil, count: snapshots.count))
        DispatchQueue.concurrentPerform(iterations: snapshots.count) { i in
            guard case .paneSnapshot(_, let bytes) = batch[snapshots[i]] else { return }
            let result = Result { () throws(VTError) in RestoredTerminal(terminal: try VTTerminal(snapshot: bytes)) }
            slots.withLock { $0[i] = result }
        }
        let restored = slots.withLock { $0 }
        var next = 0
        return batch.enumerated().map { index, message in
            guard next < snapshots.count, snapshots[next] == index, case .paneSnapshot(let id, _) = message,
                  let result = restored[next] else { return .message(message) }
            next += 1
            return .snapshot(id, result)
        }
    }

    private func shutdown(_ reason: String) {
        guard isOpen else { return }
        isOpen = false
        writer?.cancel()
        source?.cancel()
        let closed = closed
        DispatchQueue.main.async { MainActor.assumeIsolated { closed(reason) } }
    }
}
