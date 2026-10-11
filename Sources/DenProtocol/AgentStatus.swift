import Foundation

/// Status for coding agents that don't report OSC 7501 themselves (Codex,
/// OpenCode, Gemini, Cursor, Grok…), inferred once a second from what they
/// do anyway: titles with spinners or state glyphs, and sustained output.
///
/// - Title signals win: a braille spinner or Gemini's "✦" means working,
///   "✋ Action Required" means blocked, "◇ Ready" means idle.
/// - Otherwise output in two ticks running is work (a lone redraw from a
///   resize isn't), and three quiet ticks after work is done.
/// - The caller leaves out output that echoes the user's own typing.
public struct AgentStatusInference: Sendable {
    /// Process names of agents dend infers status for.
    public static let agents: Set<String> = [
        "claude", "codex", "gemini", "opencode", "grok", "cursor-agent", "copilot", "github-copilot-cli",
        "amp", "aider", "goose", "crush", "droid", "qwen", "antigravity", "kimi", "auggie", "kiro-cli", "cline",
    ]

    public static func isAgent(_ process: String) -> Bool { agents.contains(process.lowercased()) }

    static let workTicks = 2
    static let doneTicks = 3

    private enum Hint { case working, blocked, ready }

    private var phase: ProgramPhase?
    /// Whether the current work was announced by the title, which then
    /// also announces its end.
    private var workFromTitle = false
    private var busyRun = 0
    private var quietRun = 0

    public init() {}

    /// Advances one tick. Returns the new phase when it changed.
    public mutating func tick(output: Bool, title: String?) -> ProgramPhase? {
        if output { busyRun += 1; quietRun = 0 } else { quietRun += 1; busyRun = 0 }
        let next = decide(Self.hint(title))
        guard next != phase else { return nil }
        phase = next
        return next
    }

    private mutating func decide(_ hint: Hint?) -> ProgramPhase {
        let working = ProgramPhase.working(progress: nil)
        switch hint {
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
