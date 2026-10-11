import Foundation
import DenProtocol

/// Socket IO for one dend connection. Reads and writes happen on a private
/// serial queue; decoded messages are delivered to the main actor in order.
actor DenConnection {
    private let queue = DispatchSerialQueue(label: "den.connection")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    typealias Deliver = @MainActor @Sendable ([ServerMessage]) -> Void
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

    /// Enqueues a message. Callable from any context; messages are written in
    /// call order, which keeps keystrokes ordered.
    nonisolated func send(_ message: ClientMessage) {
        queue.async { [self] in assumeIsolated { $0.write(message) } }
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
        decoder.append(Data(buffer[0 ..< n]))
        var batch: [ServerMessage] = []
        do {
            while let payload = try decoder.next() { batch.append(try ServerMessage.decode(payload)) }
        } catch {
            return shutdown("dend sent data this client cannot read (\(error)). Restart Den to reconnect.")
        }
        guard !batch.isEmpty else { return }
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(batch) } }
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
