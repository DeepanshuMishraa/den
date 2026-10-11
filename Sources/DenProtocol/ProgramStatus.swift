import Foundation

/// OSC 7501 program status: programs report what they are doing (working,
/// blocked on the user, done…) and the terminal decides how to show it.
/// Spec: https://www.superlogical.com/rex/docs/build/program-status

public enum BlockedKind: String, Sendable, CaseIterable {
    case permission, question, auth
}

/// A record's state. `kind` and `progress` only exist where the spec gives
/// them meaning.
public enum ProgramPhase: Equatable, Sendable {
    case idle
    /// `progress` is 0...100; nil is indeterminate.
    case working(progress: UInt8?)
    case done
    case blocked(BlockedKind?, progress: UInt8?)
    case error

    /// Working and blocked describe a live process; they end with it.
    public var isTransient: Bool {
        switch self {
        case .working, .blocked: true
        case .idle, .done, .error: false
        }
    }

    /// Lower is more urgent: blocked needs you, then failures, live work,
    /// finished results, idle.
    public var urgency: Int {
        switch self {
        case .blocked: 0
        case .error: 1
        case .working: 2
        case .done: 3
        case .idle: 4
        }
    }

    static let names = ["idle", "working", "done", "blocked", "error"]
}

/// One status record. Each report replaces its record whole.
public struct StatusRecord: Equatable, Sendable {
    /// Slash-separated path segments; empty is the root record.
    public var id: [String]
    public var phase: ProgramPhase
    public var app: String?
    public var title: String?
    public var msg: String?

    public init(id: [String] = [], phase: ProgramPhase, app: String? = nil, title: String? = nil, msg: String? = nil) {
        self.id = id
        self.phase = phase
        self.app = app
        self.title = title
        self.msg = msg
    }

    func isWithin(_ ancestor: [String]) -> Bool { id.starts(with: ancestor) }
}

/// A parsed OSC 7501 sequence.
public enum StatusReport: Equatable, Sendable {
    /// `OSC 7501 ; ? ST`: the program asks whether the terminal supports this.
    case query
    case update(StatusRecord)
    /// Removes the record at `id` and everything beneath it; nil removes all.
    case clear(id: [String]?)

    /// The terminal's answer to `query`.
    public static let queryReply = Data("\u{1B}]7501;?:states=\(ProgramPhase.names.joined(separator: ",")):kinds=\(BlockedKind.allCases.map(\.rawValue).joined(separator: ","))\u{1B}\\".utf8)

    static let maxKeyBytes = 16
    static let maxAppBytes = 32
    static let maxMsgEncoded = 2732, maxMsgDecoded = 2048
    static let maxTitleEncoded = 256, maxTitleDecoded = 192
    static let maxIDBytes = 128, maxIDSegmentBytes = 32, maxIDDepth = 8

    /// Parses the body after `7501;`. Returns nil when the spec says to drop
    /// the whole report: no or unknown state, bad base64, over a limit, or
    /// control characters in text.
    public static func parse(_ body: Substring) -> StatusReport? {
        if body.trimmingCharacters(in: .whitespaces).hasPrefix("?") { return .query }

        var pairs: [String: String] = [:]
        for pair in body.split(separator: ":", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Malformed pairs are skipped; a repeated key keeps its last value.
            guard !key.isEmpty, key.utf8.count <= maxKeyBytes, key.utf8.allSatisfy(isLowercase),
                  value.utf8.allSatisfy(isValueByte) else { continue }
            pairs[key] = value
        }

        var id: [String] = []
        if let raw = pairs["id"] {
            guard let parsed = parseID(raw) else { return nil }
            id = parsed
        }

        guard let state = pairs["state"] else { return nil }
        if state == "clear" { return .clear(id: pairs["id"] == nil ? nil : id) }

        let progress = pairs["progress"].flatMap(UInt8.init).flatMap { $0 <= 100 ? $0 : nil }
        let phase: ProgramPhase
        switch state {
        case "idle": phase = .idle
        case "working": phase = .working(progress: progress)
        case "done": phase = .done
        case "blocked": phase = .blocked(pairs["kind"].flatMap(BlockedKind.init(rawValue:)), progress: progress)
        case "error": phase = .error
        default: return nil
        }

        let app = pairs["app"].flatMap { a in
            a.utf8.count <= maxAppBytes && !a.isEmpty && a.utf8.allSatisfy(isNameByte) ? a : nil
        }
        guard let title = decodeText(pairs["title"], maxEncoded: maxTitleEncoded, maxDecoded: maxTitleDecoded),
              let msg = decodeText(pairs["msg"], maxEncoded: maxMsgEncoded, maxDecoded: maxMsgDecoded) else { return nil }
        return .update(StatusRecord(id: id, phase: phase, app: app, title: title.value, msg: msg.value))
    }

    static func parseID(_ raw: String) -> [String]? {
        guard raw.utf8.count <= maxIDBytes else { return nil }
        let segments = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count <= maxIDDepth,
              segments.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maxIDSegmentBytes && $0.utf8.allSatisfy(isNameByte) })
        else { return nil }
        return segments
    }

    /// Wraps the decoded text so "absent" (fine) differs from "invalid" (nil).
    struct Text { let value: String? }

    static func decodeText(_ encoded: String?, maxEncoded: Int, maxDecoded: Int) -> Text? {
        guard let encoded, !encoded.isEmpty else { return Text(value: nil) }
        guard encoded.utf8.count <= maxEncoded,
              let data = Data(base64Encoded: encoded), data.count <= maxDecoded,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // Control characters void the report; invisible formatting is disarmed.
        guard !text.unicodeScalars.contains(where: isControl) else { return nil }
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisibleFormatting($0) }))
        return Text(value: cleaned)
    }

    private static func isLowercase(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
    private static func isAlnum(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || isLowercase(b) }
    /// `[A-Za-z0-9_.,+/=-]`
    private static func isValueByte(_ b: UInt8) -> Bool { isAlnum(b) || "_.,+/=-".utf8.contains(b) }
    /// `[A-Za-z0-9_.+-]`, for `app` and id segments.
    private static func isNameByte(_ b: UInt8) -> Bool { isAlnum(b) || "_.+-".utf8.contains(b) }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || (0x7F ... 0x9F).contains(s.value)
    }

    /// Bidi overrides/isolates, zero-width characters and the BOM: they can
    /// make a message read differently from what it says.
    private static func isInvisibleFormatting(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x200B ... 0x200F, 0x202A ... 0x202E, 0x2060 ... 0x2064, 0x2066 ... 0x2069, 0xFEFF: true
        default: false
        }
    }
}

/// A terminal's status records, with the spec's lifetimes and cap.
public struct StatusRecords: Equatable, Sendable {
    /// Least recently updated first, so eviction takes the front.
    public private(set) var records: [StatusRecord] = []

    public static let capacity = 256

    public init(_ records: [StatusRecord] = []) { self.records = records }

    /// Applies a report. Returns whether the records changed.
    @discardableResult
    public mutating func apply(_ report: StatusReport) -> Bool {
        switch report {
        case .query:
            return false
        case .update(let record):
            let previous = records
            records.removeAll { $0.id == record.id }
            records.append(record)
            if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
            return records != previous
        case .clear(let id):
            let before = records.count
            if let id { records.removeAll { $0.isWithin(id) } } else { records.removeAll() }
            return records.count != before
        }
    }

    /// The reporting process exited or a new prompt began: working and
    /// blocked records go; done and error stay for the user to find.
    @discardableResult
    public mutating func dropTransient() -> Bool {
        let before = records.count
        records.removeAll { $0.phase.isTransient }
        return records.count != before
    }

    /// Full reset (RIS).
    @discardableResult
    public mutating func removeAll() -> Bool {
        defer { records.removeAll() }
        return !records.isEmpty
    }

    public var hasTransient: Bool { records.contains { $0.phase.isTransient } }

    /// The record that speaks for the whole terminal: the most urgent, and
    /// the most recently updated among equally urgent ones.
    public var headline: StatusRecord? {
        records.reversed().min { $0.phase.urgency < $1.phase.urgency }
    }

    /// `app` for a record, inherited from the nearest ancestor that set one.
    public func app(for record: StatusRecord) -> String? {
        if let app = record.app { return app }
        var path = record.id
        while !path.isEmpty {
            path.removeLast()
            if let app = records.first(where: { $0.id == path })?.app { return app }
        }
        return nil
    }
}
