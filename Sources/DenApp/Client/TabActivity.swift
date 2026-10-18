import DenProtocol
import Foundation

/// A tab's line in Activity Mode: what its program is up to and since when.
/// Only tabs running something worth watching (a program reporting OSC
/// 7501, or a coding agent) have one; plain shells and editors don't.
struct TabActivity: Equatable {
    enum State: Equatable {
        case blocked(BlockedKind?)
        case error
        case working
        case done
        case idle
    }

    let state: State
    /// The program's own message, or a plain word for the state.
    let detail: String
    let since: Date

    init(state: State, detail: String? = nil, since: Date) {
        self.state = state
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 } ?? state.label
        self.since = since
    }

    init(record: StatusRecord, since: Date) {
        let state: State = switch record.phase {
        case .blocked(let kind, _): .blocked(kind)
        case .error: .error
        case .working: .working
        case .done: .done
        case .idle: .idle
        }
        self.init(state: state, detail: record.msg, since: since)
    }

    /// An agent that doesn't report OSC 7501 (or hasn't yet).
    static func unreported(lastOutput: Date?, now: Date) -> TabActivity {
        TabActivity(state: .idle, since: lastOutput ?? now)
    }

    /// "now", "4m", "12h", "3d".
    static func age(since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}

private extension TabActivity.State {
    var label: String {
        switch self {
        case .blocked(.permission): "Needs permission"
        case .blocked(.question): "Has a question"
        case .blocked(.auth): "Needs sign-in"
        case .blocked(nil): "Waiting for you"
        case .error: "Failed"
        case .working: "Working"
        case .done: "Done"
        case .idle: "Idle"
        }
    }
}
