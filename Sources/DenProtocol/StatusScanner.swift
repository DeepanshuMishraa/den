import Foundation

/// Watches a PTY byte stream for what program status needs from it: OSC
/// 7501 reports, OSC 133;A (a new prompt) and RIS (full reset). Everything
/// else passes by untouched; the VT engine still sees every byte. Sequences
/// may be split across reads.
public struct StatusScanner: Sendable {
    public enum Event: Equatable, Sendable {
        case status(StatusReport)
        case promptStart
        case fullReset
    }

    private enum State: Sendable {
        case ground
        case escape
        case osc
        /// ESC inside an OSC: `\` ends it, anything else aborts it.
        case oscEscape
    }

    private var state = State.ground
    private var buffer: [UInt8] = []
    /// The OSC outgrew the limit and is skipped up to its terminator.
    private var overflowed = false

    /// The spec caps a whole OSC 7501 sequence at 4096 bytes.
    static let maxSequence = 4096

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Event] {
        var events: [Event] = []
        for byte in bytes { step(byte, into: &events) }
        return events
    }

    private mutating func step(_ byte: UInt8, into events: inout [Event]) {
        switch state {
        case .ground:
            if byte == 0x1B { state = .escape }
        case .escape:
            switch byte {
            case 0x5D: // ]
                state = .osc
                buffer.removeAll(keepingCapacity: true)
                overflowed = false
            case 0x63: // c
                events.append(.fullReset)
                state = .ground
            case 0x1B:
                break
            default:
                state = .ground
            }
        case .osc:
            switch byte {
            case 0x07:
                finish(into: &events)
            case 0x1B:
                state = .oscEscape
            case 0x18, 0x1A: // CAN, SUB abort
                state = .ground
            default:
                // "ESC ]" plus the body must fit; past that, drop it.
                if buffer.count + 2 < Self.maxSequence { buffer.append(byte) } else { overflowed = true }
            }
        case .oscEscape:
            if byte == 0x5C {
                finish(into: &events)
            } else {
                // Not a terminator: the OSC is abandoned and this ESC starts
                // a new sequence.
                state = .escape
                step(byte, into: &events)
            }
        }
    }

    private mutating func finish(into events: inout [Event]) {
        state = .ground
        guard !overflowed else { return }
        if buffer.starts(with: Self.statusPrefix) {
            let body = String(decoding: buffer.dropFirst(Self.statusPrefix.count), as: UTF8.self)
            if let report = StatusReport.parse(body[...]) { events.append(.status(report)) }
        } else if buffer.starts(with: Self.promptPrefix), buffer.count == Self.promptPrefix.count || buffer[Self.promptPrefix.count] == 0x3B {
            events.append(.promptStart)
        }
    }

    private static let statusPrefix = Array("7501;".utf8)
    private static let promptPrefix = Array("133;A".utf8)
}
