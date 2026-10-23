import Foundation

// Protocol 6: the control channel the `den` CLI speaks. Requests and replies
// are JSON inside `ClientMessage.control` / `ServerMessage.controlReply`
// frames, so automation can grow without new binary encodings. Layout edits
// that already have binary messages (rename, move, close, input, ratio) keep
// using them.

/// What a pane runs, set when it's created.
public struct PaneLaunch: Codable, Equatable, Sendable {
    /// Shown by `den pane list` and used to address the pane.
    public var label: String?
    /// Program and arguments, run through the login shell. Empty runs the
    /// shell itself.
    public var command: [String]
    public var cwd: String?
    /// Keep the pane on screen after its program exits.
    public var keepOpen: Bool

    public init(label: String? = nil, command: [String] = [], cwd: String? = nil, keepOpen: Bool = false) {
        self.label = label
        self.command = command
        self.cwd = cwd
        self.keepOpen = keepOpen
    }

    public static let shell = PaneLaunch()
}

/// Where a launched pane goes.
public enum LaunchTarget: Codable, Equatable, Sendable {
    /// A new session holding one tab. An empty name picks a random one.
    case session(name: String)
    case tab(session: SessionID)
    /// Splits `pane`; `before` puts the new pane left of or above it.
    case split(pane: PaneID, axis: SplitAxis, before: Bool)
}

public enum CaptureFormat: String, Codable, Sendable, CaseIterable {
    case text, vt, html
}

public enum ControlRequest: Codable, Equatable, Sendable {
    /// Every session, tab, pane and client.
    case state
    case launch(LaunchTarget, PaneLaunch)
    case setLabel(pane: PaneID, label: String?)
    /// The pane's screen and scrollback, formatted.
    case capture(pane: PaneID, format: CaptureFormat)
    /// From now on this connection receives `controlEvent` frames.
    case watchEvents
    /// dend's own macOS privacy access, which every shell it runs inherits.
    case permissions
    /// Asks macOS to list dend under Screen & System Audio Recording
    /// (showing its prompt the first time); replies with `permissions`.
    case requestScreenRecording
}

public enum ControlReply: Codable, Equatable, Sendable {
    case ok
    case state(DenState)
    case launched(session: SessionID, tab: TabID, pane: PaneID)
    case text(String)
    case permissions(HostPermissions)
    case failed(String)
}

/// The macOS privacy grants dend holds. Shells and agents inherit them,
/// since dend, not the Den app, is the process macOS holds responsible.
public struct HostPermissions: Codable, Equatable, Sendable {
    public enum Access: String, Codable, Sendable {
        case granted, missing
        /// Not a macOS host.
        case notApplicable
    }

    /// Reading protected folders: Downloads, Desktop, Documents, Mail,
    /// other apps' containers.
    public let fullDiskAccess: Access
    public let screenRecording: Access

    public init(fullDiskAccess: Access, screenRecording: Access) {
        self.fullDiskAccess = fullDiskAccess
        self.screenRecording = screenRecording
    }
}

// MARK: - State

public struct DenState: Codable, Equatable, Sendable {
    public var host: String
    public var protocolVersion: UInt16
    public var sessions: [SessionState]
    public var clients: [ClientState]

    public init(host: String, protocolVersion: UInt16, sessions: [SessionState], clients: [ClientState]) {
        self.host = host
        self.protocolVersion = protocolVersion
        self.sessions = sessions
        self.clients = clients
    }
}

public struct SessionState: Codable, Equatable, Sendable {
    public var id: SessionID
    public var name: String
    public var tabs: [TabState]

    public init(id: SessionID, name: String, tabs: [TabState]) {
        self.id = id
        self.name = name
        self.tabs = tabs
    }

    public var panes: [PaneState] { tabs.flatMap(\.panes) }
}

public struct TabState: Codable, Equatable, Sendable {
    public var id: TabID
    /// User-chosen title; nil when Den derives it from the focused pane.
    public var title: String?
    public var layout: SplitNode
    /// In layout order.
    public var panes: [PaneState]

    public init(id: TabID, title: String?, layout: SplitNode, panes: [PaneState]) {
        self.id = id
        self.title = title
        self.layout = layout
        self.panes = panes
    }
}

public struct PaneState: Codable, Equatable, Sendable {
    public var id: PaneID
    public var label: String?
    public var command: [String]
    public var keepOpen: Bool
    /// Foreground program name, as Den shows it.
    public var process: String
    public var cwd: String?
    /// OSC 0/2 title, if the program set one.
    public var title: String?
    public var cols: UInt16
    public var rows: UInt16
    public var createdAt: Date
    /// The process dend started (usually the shell).
    public var child: ProcessState?
    /// Whatever owns the terminal now, e.g. nvim inside the shell.
    public var foreground: ProcessState?
    /// Set once the child exited; only seen on keep-open panes.
    public var exit: ExitState?

    public init(id: PaneID, label: String?, command: [String], keepOpen: Bool, process: String, cwd: String?, title: String?,
                cols: UInt16, rows: UInt16, createdAt: Date, child: ProcessState?, foreground: ProcessState?, exit: ExitState?) {
        self.id = id
        self.label = label
        self.command = command
        self.keepOpen = keepOpen
        self.process = process
        self.cwd = cwd
        self.title = title
        self.cols = cols
        self.rows = rows
        self.createdAt = createdAt
        self.child = child
        self.foreground = foreground
        self.exit = exit
    }
}

public struct ProcessState: Codable, Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var path: String?
    public var cwd: String?

    public init(pid: Int32, name: String, path: String?, cwd: String?) {
        self.pid = pid
        self.name = name
        self.path = path
        self.cwd = cwd
    }
}

/// How a process ended, decoded from its wait status.
public enum ExitState: Codable, Equatable, Sendable {
    case code(Int32)
    case signal(Int32)

    public init(waitStatus status: Int32) {
        let signal = status & 0x7F
        self = signal == 0 ? .code((status >> 8) & 0xFF) : .signal(signal)
    }

    /// What a shell would report: the code, or 128 + signal.
    public var shellStatus: Int32 {
        switch self {
        case .code(let code): code
        case .signal(let signal): 128 + signal
        }
    }
}

public struct ClientState: Codable, Equatable, Sendable {
    public var id: Int
    /// What the client called itself in `hello`.
    public var name: String
    public var connectedAt: Date
    /// Receives every session's layout and output (Den.app does).
    public var subscribed: Bool
    public var watchingEvents: Bool

    public init(id: Int, name: String, connectedAt: Date, subscribed: Bool, watchingEvents: Bool) {
        self.id = id
        self.name = name
        self.connectedAt = connectedAt
        self.subscribed = subscribed
        self.watchingEvents = watchingEvents
    }
}

// MARK: - Events

public struct ControlEvent: Codable, Equatable, Sendable {
    public var time: Date
    public var kind: Kind

    public init(time: Date = Date(), kind: Kind) {
        self.time = time
        self.kind = kind
    }

    public enum Kind: Codable, Equatable, Sendable {
        case sessionCreated(session: SessionID, name: String)
        case sessionRenamed(session: SessionID, name: String)
        case sessionClosed(session: SessionID)
        case tabCreated(session: SessionID, tab: TabID)
        case tabRenamed(session: SessionID, tab: TabID, title: String?)
        case tabClosed(session: SessionID, tab: TabID)
        case layoutChanged(session: SessionID)
        case paneCreated(session: SessionID, tab: TabID, pane: PaneID, label: String?)
        case paneExited(session: SessionID, pane: PaneID, exit: ExitState)
        case paneClosed(session: SessionID, pane: PaneID)
        case paneResized(session: SessionID, pane: PaneID, cols: UInt16, rows: UInt16)
        case paneProcessChanged(session: SessionID, pane: PaneID, process: String, cwd: String?)
        case paneTitleChanged(session: SessionID, pane: PaneID, title: String?)
        case paneLabelChanged(session: SessionID, pane: PaneID, label: String?)
        case paneBell(session: SessionID, pane: PaneID)
        case clientConnected(client: Int, name: String)
        case clientDisconnected(client: Int, name: String)

        /// The session the event belongs to; nil for server-wide events.
        public var session: SessionID? {
            switch self {
            case .sessionCreated(let s, _), .sessionRenamed(let s, _), .sessionClosed(let s),
                 .tabCreated(let s, _), .tabRenamed(let s, _, _), .tabClosed(let s, _), .layoutChanged(let s),
                 .paneCreated(let s, _, _, _), .paneExited(let s, _, _), .paneClosed(let s, _),
                 .paneResized(let s, _, _, _), .paneProcessChanged(let s, _, _, _), .paneTitleChanged(let s, _, _),
                 .paneLabelChanged(let s, _, _), .paneBell(let s, _):
                s
            case .clientConnected, .clientDisconnected:
                nil
            }
        }
    }
}

// MARK: - JSON

public enum ControlCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // Only plain value types are encoded here, which cannot fail.
        return (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> Result<T, DecodingError> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .success(try decoder.decode(type, from: data))
        } catch let error as DecodingError {
            return .failure(error)
        } catch {
            return .failure(.dataCorrupted(.init(codingPath: [], debugDescription: "\(error)")))
        }
    }
}

// IDs encode as their bare lowercase UUID.

extension SessionID: Codable {
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(UUID.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw.uuidString.lowercased())
    }
}

extension TabID: Codable {
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(UUID.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw.uuidString.lowercased())
    }
}

extension PaneID: Codable {
    public init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(UUID.self)) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw.uuidString.lowercased())
    }
}

extension SplitAxis: Codable {}
