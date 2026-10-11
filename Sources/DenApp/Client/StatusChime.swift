import AppKit
import DenProtocol

/// Plays a sound when a program newly needs the user (blocked), fails, or
/// finishes. One sound per burst, so a chatty program can't ring on
/// repeat (the spec asks terminals to rate-limit external effects).
@MainActor
struct StatusChime {
    enum Sound: Int, Comparable {
        case done = 0, error = 1, blocked = 2

        static func < (a: Sound, b: Sound) -> Bool { a.rawValue < b.rawValue }

        var name: NSSound.Name {
            switch self {
            case .blocked: "Glass"
            case .error: "Basso"
            case .done: "Tink"
            }
        }
    }

    private var lastPlayed = Date.distantPast
    private static let minimumGap: TimeInterval = 1

    /// The most urgent new state in `new` that `old` didn't already have.
    static func sound(old: [StatusRecord], new: [StatusRecord]) -> Sound? {
        new.compactMap { record -> Sound? in
            let previous = old.first { $0.id == record.id }?.phase
            switch record.phase {
            case .blocked:
                if case .blocked = previous { return nil }
                return .blocked
            case .error: return previous == .error ? nil : .error
            case .done: return previous == .done ? nil : .done
            case .idle, .working: return nil
            }
        }.max()
    }

    mutating func play(_ sound: Sound) {
        let now = Date()
        guard now.timeIntervalSince(lastPlayed) >= Self.minimumGap else { return }
        lastPlayed = now
        NSSound(named: sound.name)?.play()
    }
}
