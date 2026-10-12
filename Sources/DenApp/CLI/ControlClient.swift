import Foundation
import DenProtocol

/// A failure the CLI reports as `den: <message>` and exits with `status`.
struct CLIError: Error {
    let message: String
    var status: Int32 = 1

    static func usage(_ message: String) -> CLIError { CLIError(message: message, status: 2) }
}

/// Blocking connection to dend for one CLI invocation.
final class ControlClient {
    private let fd: Int32
    private var decoder = FrameDecoder()
    private var nextRequest: UInt32 = 1
    /// Events that arrived while waiting for a reply.
    private var queuedEvents: [ControlEvent] = []
    private var buffer = [UInt8](repeating: 0, count: 256 * 1024)

    private init(fd: Int32) { self.fd = fd }

    deinit { close(fd) }

    /// Connects (starting the local dend when it isn't running and no
    /// other socket was asked for) and checks dend speaks the control channel.
    static func connect(socket: String?) throws(CLIError) -> ControlClient {
        let path = socket ?? DenPaths.socket.path
        let fd = try openSocket(path, mayStart: socket == nil)
        // Blocking IO: the CLI does one thing at a time.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let client = ControlClient(fd: fd)
        // Like the app: hello with the oldest version so an older dend still
        // welcomes us and the check below can explain what to do.
        try client.send(.hello(version: minimumProtocolVersion, client: "den-cli"))
        while true {
            switch try client.readMessage(timeout: 5) {
            case .welcome(let version, _)?:
                guard version >= 6 else {
                    throw CLIError(message: """
                    The running dend is older than this den (it speaks protocol \(version); the CLI needs 6). \
                    Your sessions are fine. To update it, quit Den, run `pkill -x dend` (this ends every session), then reopen Den.
                    """)
                }
                return client
            case .error(let message)?:
                throw CLIError(message: "dend refused the connection: \(message)")
            case nil:
                throw CLIError(message: "dend at \(path) did not answer within 5 seconds. Check \(DenPaths.log.path) for its output.")
            default:
                continue
            }
        }
    }

    private static func openSocket(_ path: String, mayStart: Bool) throws(CLIError) -> Int32 {
        if let fd = try? UnixSocket.connect(path) { return fd }
        guard mayStart else {
            throw CLIError(message: "Nothing is listening on \(path). Start that dend, or drop --socket/DEN_SOCKET to use Den's own.")
        }
        do {
            try DendLauncher.spawn()
        } catch {
            throw CLIError(message: "\(error.description)")
        }
        for _ in 0 ..< 60 {
            usleep(50_000)
            if let fd = try? UnixSocket.connect(path) { return fd }
        }
        throw CLIError(message: "dend did not start listening on \(path) within 3 seconds. See \(DenPaths.log.path) for its output.")
    }

    func send(_ message: ClientMessage) throws(CLIError) {
        let frame = Frame.wrap(message.encode())
        var offset = 0
        while offset < frame.count {
            let n = frame[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw CLIError(message: "Lost the connection to dend while sending: \(String(cString: strerror(errno))).") }
            offset += n
        }
    }

    /// Sends a control request and waits for its reply. A `failed` reply
    /// becomes an error.
    @discardableResult
    func request(_ control: ControlRequest) throws(CLIError) -> ControlReply {
        let id = nextRequest
        nextRequest += 1
        try send(.control(request: id, ControlCoding.encode(control)))
        while true {
            switch try readMessage(timeout: 30) {
            case .controlReply(let replyID, let json)? where replyID == id:
                switch ControlCoding.decode(ControlReply.self, from: json) {
                case .success(.failed(let message)): throw CLIError(message: message)
                case .success(let reply): return reply
                case .failure(let error): throw CLIError(message: "dend sent a reply this den can't read (\(error)). Update den and dend to the same version.")
                }
            case .controlEvent(let json)?:
                if case .success(let event) = ControlCoding.decode(ControlEvent.self, from: json) { queuedEvents.append(event) }
            case .error(let message)?:
                throw CLIError(message: message)
            case nil:
                throw CLIError(message: "dend did not answer within 30 seconds.")
            default:
                continue
            }
        }
    }

    func state() throws(CLIError) -> DenState {
        guard case .state(let state) = try request(.state) else { throw CLIError(message: "dend answered a state request with something else.") }
        return state
    }

    /// The next event, or nil when `timeout` (seconds) passes first.
    func nextEvent(timeout: Double?) throws(CLIError) -> ControlEvent? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if !queuedEvents.isEmpty { return queuedEvents.removeFirst() }
            let remaining = deadline.map { $0.timeIntervalSinceNow }
            if let remaining, remaining <= 0 { return nil }
            switch try readMessage(timeout: remaining) {
            case .controlEvent(let json)?:
                if case .success(let event) = ControlCoding.decode(ControlEvent.self, from: json) { return event }
            case nil:
                return nil
            default:
                continue
            }
        }
    }

    /// Nil on timeout. A closed connection is an error.
    private func readMessage(timeout: Double?) throws(CLIError) -> ServerMessage? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            do {
                if let payload = try decoder.next() { return try ServerMessage.decode(payload) }
            } catch {
                throw CLIError(message: "dend sent data this den can't read (\(error)). Update den and dend to the same version.")
            }
            var waitMs: Int32 = -1
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                if left <= 0 { return nil }
                waitMs = Int32(min(left * 1000, Double(Int32.max)))
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0, errno == EINTR { continue }
            if ready == 0 { return nil }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw CLIError(message: "dend closed the connection.") }
            decoder.append(Data(buffer[0 ..< n]))
        }
    }
}
