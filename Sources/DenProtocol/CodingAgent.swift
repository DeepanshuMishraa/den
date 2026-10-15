import Foundation

/// Coding agents dend knows by process name, and what their screens look
/// like while they work, wait on the user or sit at their prompt. For agents
/// that don't report OSC 7501 this is how dend tells a permission prompt
/// from plain output.
///
/// The rules are herdr's agent manifests (github.com/ogulcancelik/herdr,
/// `src/detect/manifests`), ported rule for rule: each agent's list is
/// ordered by the manifest's priority and the first match decides.
public enum CodingAgent: String, CaseIterable, Sendable {
    case claude, codex, gemini, cursor, devin, antigravity, cline, opencode, copilot
    case kimi, kiro, droid, amp, grok, hermes, kilo, qoder, pi
    /// Known agents without screen rules; their status comes from output
    /// activity and titles alone.
    case aider, goose, crush, qwen, auggie

    /// The agent a foreground process name (as `ProgramName` resolves it)
    /// belongs to, by its binary names and aliases.
    public init?(process: String) {
        let name = process.lowercased()
        guard let agent = Self.allCases.first(where: { $0.names.contains(name) }) else { return nil }
        self = agent
    }

    var names: Set<String> {
        switch self {
        case .claude: ["claude", "claude-code"]
        case .codex: ["codex"]
        case .gemini: ["gemini"]
        case .cursor: ["cursor-agent", "cursor"]
        case .devin: ["devin", "devin-cli"]
        case .antigravity: ["agy", "antigravity", "antigravity-cli"]
        case .cline: ["cline"]
        case .opencode: ["opencode", "open-code"]
        case .copilot: ["copilot", "github-copilot", "github-copilot-cli", "ghcs"]
        case .kimi: ["kimi", "kimi-code"]
        case .kiro: ["kiro", "kiro-cli"]
        case .droid: ["droid"]
        case .amp: ["amp", "amp-local"]
        case .grok: ["grok", "grok-build"]
        case .hermes: ["hermes", "hermes-agent"]
        case .kilo: ["kilo", "kilo-code"]
        case .qoder: ["qodercli", "qoderclicn", "qoder", "qodercn"]
        case .pi: ["pi"]
        case .aider: ["aider"]
        case .goose: ["goose"]
        case .crush: ["crush"]
        case .qwen: ["qwen"]
        case .auggie: ["auggie"]
        }
    }

    /// What the agent's screen and title say, or nil when no rule matches.
    /// `screen` is the active area's text, one line per row.
    public func signal(screen: String, title: String?) -> ScreenSignal? {
        Self.rules[self]?.first { $0.matches(screen: screen, title: title ?? "") }?.signal
    }

    /// Whether any rule reads the screen, so callers can skip fetching it.
    public var readsScreen: Bool {
        Self.rules[self]?.contains { $0.region != .title } ?? false
    }

    // MARK: Rules

    private static let rules: [CodingAgent: [ScreenRule]] = {
        // The same in OpenCode and its fork Kilo.
        let opencodePermission = ScreenRule(.blocked, .screen, any: [
            c("△ Permission required"),
            Gate(contains: ["esc dismiss"],
                 all: [Gate(any: [c("↑↓ select"), c("⇆ tab")])],
                 any: [c("enter confirm"), c("enter submit"), c("enter toggle")]),
        ])
        let askedYes = [c("yes"), c("❯")]
        let devinBusy = [c("approve once", "esc cancel"), c("running tools", "esc to interrupt"), c("guide devin while it works")]

        return [
            .claude: [
                ScreenRule(.working, .title, regex: [#"^[\x{2800}-\x{28FF}] "#]),
                ScreenRule(.viewer, .bottomLines(3), contains: ["showing detailed transcript"], any: [
                    c("ctrl+o", "to toggle"), c("ctrl+e", "show all"), c("ctrl+e", "collapse"), c("↑↓ scroll"), c("? for shortcuts"),
                ]),
                ScreenRule(.blocked, .afterLastRule, contains: ["enter to select", "esc to cancel"], any: [
                    c("tab/arrow keys to navigate"), c("arrow keys to navigate"), c("arrows to navigate"), c("↑/↓ to navigate"), c("↑↓ to navigate"),
                ]),
                ScreenRule(.blocked, .screen, contains: ["run a dynamic workflow?", "esc to cancel"]),
                ScreenRule(.idle, .promptBox, lines: [#"^\s*❯"#], not: [
                    c("enter to select"), c("esc to cancel"), c("tab/arrow keys"), c("arrow keys to navigate"), c("↑/↓ to navigate"),
                ]),
                ScreenRule(.viewer, .screen, contains: ["select model", "enter to set as default", "esc to cancel"], not: [
                    c("do you want to proceed?"), c("enter to select"),
                ]),
                ScreenRule(.blocked, .screen, contains: ["do you want to proceed?"],
                           all: [Gate(any: [line(#"(?i)^\s*❯?\s*yes\b"#), line(#"(?i)^\s*1\.\s*yes\b"#), line(#"(?i)^\s*2\.\s*no\b"#)])],
                           any: [c("bash command"), c("bash("), c("contains expansion"), c("tab to amend"), c("ctrl+e to explain")]),
                ScreenRule(.blocked, .afterLastRule, contains: ["do you want to proceed?", "esc to cancel"], all: [Gate(any: [
                    line(#"(?i)^\s*❯?\s*1\.\s*yes\b"#), line(#"(?i)^\s*2\.\s*yes\b"#), line(#"(?i)^\s*2\.\s*no\b"#), line(#"(?i)^\s*3\.\s*no\b"#),
                ])]),
                ScreenRule(.blocked, .screen, any: [
                    Gate(contains: ["do you want to"], any: askedYes),
                    Gate(contains: ["would you like to"], any: askedYes),
                    c("waiting for permission"), c("do you want to allow this connection?"), c("tab to amend"), c("ctrl+e to explain"),
                    c("do you want to proceed?", "esc to cancel"), c("review your answers"), c("skip interview and plan immediately"),
                ], not: [Gate(regex: [#"(?m)^\s*❯\s*$"#])]),
                ScreenRule(.idle, .title, regex: [#"^\x{2733} "#]),
            ],
            .codex: [
                ScreenRule(.blocked, .title, contains: ["Action Required"]),
                ScreenRule(.working, .title, regex: [#"^[\x{2800}-\x{28FF}] "#]),
                ScreenRule(.viewer, .afterPromptMarker, contains: ["↑/↓ to scroll", "pgup/pgdn to", "home/end to jump", "q to quit"], any: [
                    c("esc to edit prev"), c("esc/← to edit prev"),
                ]),
                ScreenRule(.blocked, .afterPromptMarker, any: [
                    c("press enter to confirm or esc to cancel"), c("enter to submit answer"), c("enter to submit all"), c("allow command?"),
                ]),
                ScreenRule(.blocked, .screen, any: [
                    c("[y/n]"), c("yes (y)"),
                    Gate(contains: ["do you want to"], any: askedYes),
                    Gate(contains: ["would you like to"], any: askedYes),
                ]),
                ScreenRule(.idle, .title, regex: [#"\S"#], not: [Gate(regex: [#"^[\x{2800}-\x{28FF}]"#]), c("Action Required")]),
            ],
            .gemini: [
                ScreenRule(.blocked, .screen, any: [
                    c("│ Apply this change"), c("│ Allow execution"),
                    Gate(all: [c("yes"), Gate(any: [c("waiting for user confirmation"), c("│ Do you want to proceed"), c("do you want to proceed?")])]),
                    line(#"(?i)^\s*❯.*(yes|allow)"#),
                ]),
                ScreenRule(.working, .screen, contains: ["esc to cancel"]),
            ],
            .amp: [
                ScreenRule(.blocked, .screen, any: [
                    c("waiting for approval"), c("invoke tool"), c("run this command?"), c("allow editing file:"), c("allow creating file:"), c("confirm tool call"),
                    Gate(contains: ["approve"], any: [
                        c("allow all for this session"), c("allow all for every session"), c("allow file for every session"), c("deny with feedback"),
                    ]),
                ]),
                ScreenRule(.working, .screen, contains: ["esc to cancel"]),
            ],
            .antigravity: [
                ScreenRule(.blocked, .screen, contains: ["requesting permission for:"], any: [c("do you want to proceed?"), c("tab amend", "edit command")]),
                ScreenRule(.working, .screen, lines: [#"^\s*[\x{2800}-\x{28FF}]+\s+\p{Alphabetic}+\w*ing\b"#]),
                ScreenRule(.working, .bottomLines(5), lines: [#"(?i).*[1-9][0-9]*\s*·?\s+tasks?.*/tasks"#]),
            ],
            // herdr also calls any other Cline screen working; output activity
            // decides that here instead, so Cline can finish.
            .cline: [
                ScreenRule(.blocked, .screen, any: [
                    c("let cline use this tool"),
                    c("[act mode]", "execute command?", "yes"), c("[act mode]", "use this tool?", "yes"),
                    c("[plan mode]", "execute command?", "yes"), c("[plan mode]", "use this tool?", "yes"),
                ]),
            ],
            .cursor: [
                ScreenRule(.blocked, .bottomLines(8), contains: ["write to this file?", "proceed (y)"], any: [
                    c("reject & propose changes"), c("esc or n or p"), c("add write("),
                ]),
                ScreenRule(.blocked, .screen, any: [
                    Gate(contains: ["waiting for approval", "run this command?"], any: [c("run (once) (y)"), c("skip (esc or n)")]),
                    c("(y) (enter)"), line(#"(?i)^\s*allow .*\(y\)"#), c("keep (n)"), c("skip (esc or n)"),
                    line(#"(?i)^\s*(run |.*\(y\).*(allow|run \(once\)|→ run))"#),
                ]),
                ScreenRule(.working, .bottomLines(6), contains: ["ctrl+c to stop"]),
                ScreenRule(.working, .bottomLines(5), lines: [#"(?i)\b[1-9][0-9]*\s+background\s+tasks?\b"#]),
                ScreenRule(.working, .bottomLines(8), lines: [#"^\s*(⬡|⬢|[\x{2800}-\x{28FF}]+)\s+\p{Alphabetic}+\w*ing\b"#]),
            ],
            .devin: [
                ScreenRule(.blocked, .bottomLines(8), contains: ["do you trust the authors of this directory?", "with untrusted content.", "yes, trust "]),
                ScreenRule(.blocked, .bottomLines(8), contains: ["approve once", "select", "confirm", "esc cancel"]),
                ScreenRule(.working, .bottomLines(8), contains: ["running tools", "esc to interrupt"], not: [c("approve once", "esc cancel")]),
                ScreenRule(.working, .bottomLines(6), contains: ["guide devin while it works"], not: [c("approve once", "esc cancel")]),
                ScreenRule(.working, .bottomLines(8), contains: ["reading shell ", "timeout:"], not: [c("approve once", "esc cancel")]),
                ScreenRule(.idle, .bottomLines(8), contains: ["ask devin to build", "features, fix bugs", "your code"],
                           lines: [#"^\s*❭ Ask Devin to build"#], not: devinBusy),
                ScreenRule(.idle, .bottomLines(6), contains: ["context:"], lines: [#"^\s*❭"#], not: devinBusy),
            ],
            .droid: [
                ScreenRule(.blocked, .screen, contains: ["enter to select", "esc to cancel"],
                           all: [Gate(any: [c("> yes, allow"), c("> no, cancel")])],
                           any: [c("↑↓ to navigate"), c("use ↑↓ to navigate")]),
                ScreenRule(.blocked, .bottomLines(8), contains: ["enter select", "esc cancel"], any: [c("↑/↓ navigate"), c("↑↓ navigate")]),
                ScreenRule(.working, .screen, contains: ["esc to stop"]),
            ],
            .copilot: [
                ScreenRule(.blocked, .screen, contains: ["esc to cancel"], any: [c("enter to select"), c("enter to confirm"), c("enter to submit")]),
                ScreenRule(.working, .screen, any: [c("esc to cancel"), c("esc cancel"), c("esc again to cancel")]),
            ],
            .grok: [
                ScreenRule(.blocked, .screen, contains: ["yes, proceed", "no, reject"], any: [
                    c("use ← → to choose permission whitelist scope"), c("←/→:scope"),
                ]),
                ScreenRule(.working, .screen, any: [
                    Gate(all: [c("ctrl+c:cancel", "ctrl+enter:interject"), c("waiting")]),
                    line(#"^\s*[\x{2800}-\x{28FF}]\s+(Run|Read|Search|List)\b"#),
                ]),
            ],
            .hermes: [
                ScreenRule(.blocked, .screen,
                           all: [Gate(any: [c("enter to confirm"), c("↑/↓ to select"), c("show full command")])],
                           any: [c("dangerous command"), c("allow once", "allow for this session", "deny")]),
                ScreenRule(.working, .screen, any: [c("msg=interrupt"), c("ctrl+c cancel")]),
            ],
            .kilo: [
                opencodePermission,
                ScreenRule(.working, .screen, contains: ["esc interrupt"]),
            ],
            .opencode: [
                opencodePermission,
                ScreenRule(.working, .screen, any: [
                    c("esc to interrupt"), c("ctrl+c to interrupt"), c("press esc to interrupt"), line(#"(?i).*opencode.*esc (again to )?interrupt"#),
                ]),
                ScreenRule(.working, .screen, regex: [#"(■|⬝){4,}"#]),
            ],
            .kimi: [
                ScreenRule(.blocked, .screen, contains: ["↵ confirm"],
                           all: [c(" choose"), Gate(any: [c("approve"), c("reject"), c("revise")])],
                           any: [
                               c("run this command?"), c("write this file?"), c("apply these edits?"), c("stop this task?"),
                               c("ready to build with this plan?"), line(#"(?i)^\s*▶?\s*approve .*\?$"#),
                           ]),
                ScreenRule(.blocked, .screen, contains: ["↑↓ select", "esc cancel"], lines: [#"^\s*question\s*$"#, #"^\s*\? "#], any: [
                    c("↵ choose"), c("↵ toggle"), c("↵ save"),
                ]),
                ScreenRule(.blocked, .screen, contains: ["requesting approval", "reject"],
                           all: [Gate(any: [c("1/2/3/4 choose"), c("↵ confirm")])],
                           any: [c("approve once"), c("approve for this session")]),
                ScreenRule(.working, .bottomLines(3), lines: [#"(?i)\bkimi[-\w.]*\s+thinking\b.*\[[1-9][0-9]*\s+agents?\s+running\]"#]),
                ScreenRule(.working, .screen, lines: [#"^\s*(🌕|🌖|🌗|🌘|🌑|🌒|🌓|🌔)\s*$"#]),
                ScreenRule(.working, .screen, lines: [#"(?i)^\s*[\x{2800}-\x{28FF}]+\s*(thinking\.\.\.|working\.\.\.|using )"#]),
            ],
            .kiro: [
                ScreenRule(.blocked, .screen, contains: ["requires approval"], any: [
                    c("yes, single permission"), c("trust, always allow"), c("no (tab to edit)"), c("esc to close"),
                ]),
                ScreenRule(.blocked, .screen, contains: ["pending from subagents"],
                           all: [Gate(any: [c("approve all pending"), c("configure individually"), c("exit (cancel subagents)")])],
                           any: [c("tool approval"), c("tool approvals")]),
                ScreenRule(.working, .screen, contains: ["kiro is working"]),
                ScreenRule(.working, .screen, contains: ["esc to cancel"], lines: [#"^\s*(◔|◑|◕|●)\s+\p{Alphabetic}"#]),
            ],
            .pi: [
                ScreenRule(.working, .screen, contains: ["Working..."]),
            ],
            .qoder: [
                ScreenRule(.blocked, .screen, any: [
                    Gate(contains: ["waiting for user confirmation"], any: [c("yes"), c("no"), c("allow"), c("reject")]),
                    Gate(contains: ["awaiting approval"], any: [c("allow"), c("reject")]),
                    c("permission required"), c("allow once or always?"), c("asking user"), c("enter your response"),
                    c("review your answers:"), c("shell awaiting input"),
                ]),
                ScreenRule(.working, .screen, contains: ["(esc to cancel,"]),
                ScreenRule(.working, .screen, lines: [#"^\s*[\x{2800}-\x{28FF}]\s+.*\p{Alphabetic}"#]),
            ],
        ]
    }()

    /// Every rule's patterns compile; a pattern that doesn't makes its rule
    /// never match. Checked by tests.
    static var allPatternsCompile: Bool {
        rules.values.joined().allSatisfy { $0.gate.compiles }
    }

    private static func c(_ needles: String...) -> Gate { Gate(contains: needles) }
    private static func line(_ pattern: String) -> Gate { Gate(lines: [pattern]) }
}

/// What a rule concludes from the screen.
public enum ScreenSignal: Equatable, Sendable {
    case idle, working, blocked
    /// The agent shows a transcript or menu, not its live state: keep
    /// whatever was concluded before.
    case viewer
}

/// Where a rule looks.
enum ScreenRegion: Equatable, Sendable {
    /// The whole active area.
    case screen
    /// From the nth-last non-empty line down.
    case bottomLines(Int)
    /// Below the last horizontal rule (`────`).
    case afterLastRule
    /// Below Codex's last `›` prompt line, or everything when there is none.
    case afterPromptMarker
    /// Between the second-last horizontal rule and the next (Claude's input box).
    case promptBox
    /// The OSC 0/2 title.
    case title

    func text(screen: String, title: String) -> String {
        if self == .title { return title }
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        func from(_ index: Int) -> String { lines[min(index, lines.count)...].joined(separator: "\n") }
        switch self {
        case .screen, .title:
            return screen
        case .bottomLines(let count):
            let nonEmpty = lines.indices.filter { !lines[$0].allSatisfy(\.isWhitespace) }
            guard let start = nonEmpty.suffix(count).first else { return "" }
            return from(start)
        case .afterLastRule:
            guard let rule = lines.lastIndex(where: Self.isHorizontalRule) else { return screen }
            return from(rule + 1)
        case .afterPromptMarker:
            guard let prompt = lines.lastIndex(where: { $0 == "›" || $0.hasPrefix("› ") }) else { return screen }
            return from(prompt + 1)
        case .promptBox:
            let rules = lines.indices.filter { Self.isHorizontalRule(lines[$0]) }
            guard rules.count >= 2 else { return "" }
            let top = rules[rules.count - 2]
            return lines[(top + 1) ..< rules[rules.count - 1]].joined(separator: "\n")
        }
    }

    /// A line of `─`, possibly followed by a label once it's 3+ long.
    static func isHorizontalRule(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let rule = trimmed.prefix { $0 == "─" }
        guard !rule.isEmpty else { return false }
        return rule.count == trimmed.count || rule.count >= 3
    }
}

/// Matchers that must all hold: every `contains` needle (case-insensitive),
/// every `regex` somewhere in the text, every `lines` pattern on some line,
/// every `all` gate, at least one `any` gate (when given), no `not` gate.
struct Gate: Sendable {
    let contains: [String]
    let regex: [Pattern]
    let lines: [Pattern]
    let all: [Gate]
    let any: [Gate]
    let not: [Gate]

    init(contains: [String] = [], regex: [String] = [], lines: [String] = [], all: [Gate] = [], any: [Gate] = [], not: [Gate] = []) {
        self.contains = contains.map { $0.lowercased() }
        self.regex = regex.map(Pattern.init)
        self.lines = lines.map(Pattern.init)
        self.all = all
        self.any = any
        self.not = not
    }

    func matches(_ text: String, lowercased: String) -> Bool {
        contains.allSatisfy(lowercased.contains)
            && regex.allSatisfy { $0.matches(text) }
            && lines.allSatisfy { pattern in text.split(separator: "\n").contains { pattern.matches(String($0)) } }
            && all.allSatisfy { $0.matches(text, lowercased: lowercased) }
            && (any.isEmpty || any.contains { $0.matches(text, lowercased: lowercased) })
            && !not.contains { $0.matches(text, lowercased: lowercased) }
    }

    var compiles: Bool {
        (regex + lines).allSatisfy { $0.expression != nil } && (all + any + not).allSatisfy(\.compiles)
    }
}

/// An ICU regular expression. One that fails to compile never matches.
struct Pattern: @unchecked Sendable {
    /// Immutable after init, and matching is thread-safe.
    let expression: NSRegularExpression?

    init(_ pattern: String) { expression = try? NSRegularExpression(pattern: pattern) }

    func matches(_ text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

struct ScreenRule: Sendable {
    let signal: ScreenSignal
    let region: ScreenRegion
    let gate: Gate

    init(_ signal: ScreenSignal, _ region: ScreenRegion, contains: [String] = [], regex: [String] = [], lines: [String] = [],
         all: [Gate] = [], any: [Gate] = [], not: [Gate] = []) {
        self.signal = signal
        self.region = region
        gate = Gate(contains: contains, regex: regex, lines: lines, all: all, any: any, not: not)
    }

    func matches(screen: String, title: String) -> Bool {
        let text = region.text(screen: screen, title: title)
        return gate.matches(text, lowercased: text.lowercased())
    }
}
