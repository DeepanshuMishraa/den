import Foundation

/// Status for coding agents that don't report OSC 7501 themselves (Codex,
/// OpenCode, Gemini, Cursor, Grok…), inferred once a second from what they
/// do anyway: what their screen shows, titles with spinners or state
/// glyphs, and sustained output.
///
/// - The agent's screen rules (`CodingAgent.signal`) win: a permission
///   prompt is blocked, a live "esc to cancel" footer is working, an empty
///   input box is idle, a transcript viewer changes nothing.
/// - Then title signals: a braille spinner or Gemini's "✦" means working,
///   "✋ Action Required" means blocked, "◇ Ready" means idle.
/// - Otherwise output in two ticks running is work (a lone redraw from a
///   resize isn't), and three quiet ticks after work is done.
/// - The caller leaves out output that echoes the user's own typing.
public struct AgentStatusInference: Sendable {
    public static func isAgent(_ process: String) -> Bool { CodingAgent(process: process) != nil }

    static let workTicks = 2
    static let doneTicks = 3

    private enum Hint { case working, blocked, ready, keep }

    private var phase: ProgramPhase?
    /// Whether the current work was announced by the screen or title, which
    /// then also announce its end.
    private var workFromTitle = false
    private var busyRun = 0
    private var quietRun = 0

    public init() {}

    /// Advances one tick. Returns the new phase when it changed.
    public mutating func tick(output: Bool, title: String?, screen: ScreenSignal? = nil) -> ProgramPhase? {
        if output { busyRun += 1; quietRun = 0 } else { quietRun += 1; busyRun = 0 }
        let hint: Hint? = switch screen {
        case .blocked: .blocked
        case .working: .working
        case .idle: .ready
        case .viewer: .keep
        case nil: Self.hint(title)
        }
        let next = decide(hint)
        guard next != phase else { return nil }
        phase = next
        return next
    }

    private mutating func decide(_ hint: Hint?) -> ProgramPhase {
        let working = ProgramPhase.working(progress: nil)
        switch hint {
        case .keep:
            return phase ?? .idle
        case .blocked:
            return .blocked(nil, progress: nil)
        case .working:
            workFromTitle = true
            return working
        case .ready:
            return phase == working || phase == .done ? .done : .idle
        case nil:
            if phase == working {
                if workFromTitle || quietRun >= Self.doneTicks { return .done }
                return working
            }
            if busyRun >= Self.workTicks {
                workFromTitle = false
                return working
            }
            if case .blocked = phase { return .idle }
            return phase ?? .idle
        }
    }

    private static func hint(_ title: String?) -> Hint? {
        guard let title, let first = title.unicodeScalars.first(where: { !$0.properties.isWhitespace }) else { return nil }
        if (0x2801 ... 0x28FF).contains(first.value) || first == "✦" { return .working }
        if first == "✋" || title.localizedCaseInsensitiveContains("action required") { return .blocked }
        if first == "◇" { return .ready }
        return nil
    }
}
