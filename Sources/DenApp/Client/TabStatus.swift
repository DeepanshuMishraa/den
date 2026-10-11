import DenProtocol

/// The most urgent thing a tab's programs report over OSC 7501, for the tab
/// bar, sidebar and session picker.
struct TabStatus: Equatable {
    enum Indicator: Equatable {
        case blocked(BlockedKind?)
        case error
        case working
        case done
    }

    let indicator: Indicator
    /// The record's one-line message, for tooltips.
    let message: String?

    /// Blocked first (it needs you), then error, working, done. Idle shows
    /// nothing, and done/error the user has already seen are skipped.
    static func summarize(_ records: [StatusRecord], seen: [StatusRecord]) -> TabStatus? {
        var best: (rank: Int, status: TabStatus)?
        for record in records {
            let indicator: Indicator
            switch record.phase {
            case .idle: continue
            case .blocked(let kind, _): indicator = .blocked(kind)
            case .working: indicator = .working
            case .done, .error:
                if seen.contains(record) { continue }
                indicator = record.phase == .done ? .done : .error
            }
            let rank = indicator.rank
            if best.map({ rank < $0.rank }) ?? true {
                best = (rank, TabStatus(indicator: indicator, message: record.msg ?? record.title))
            }
        }
        return best?.status
    }

    /// Finished or waiting on the user: worth a mark in the session picker.
    var wantsAttention: Bool {
        switch indicator {
        case .blocked, .done, .error: true
        case .working: false
        }
    }
}

private extension TabStatus.Indicator {
    var rank: Int {
        switch self {
        case .blocked: 0
        case .error: 1
        case .working: 2
        case .done: 3
        }
    }
}
