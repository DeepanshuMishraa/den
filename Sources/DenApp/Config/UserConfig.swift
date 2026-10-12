import AppKit
import Carbon.HIToolbox
import DenVT

/// `~/.config/den/config.toml`, the file you edit by hand. Missing keys keep
/// their defaults; keys Den doesn't know yet are ignored.
struct UserConfig: Equatable {
    enum Shortcut: Equatable {
        case unbound
        case bound(Trigger)
    }

    static let defaultLeader = KeyChord(modifiers: [.option], key: .code(UInt16(kVK_Space)))

    var optionAsAlt: OptionAsAlt = .both
    /// Terminal typeface and size. When set, they win over Change Font and
    /// ⌘=/⌘- on every config reload.
    var terminalFont: String?
    var terminalFontSize: Double?
    /// Den's own text (toasts, pickers). Defaults to the terminal font.
    var uiFont: String?
    var uiFontSize: Double?
    var keybinds: [Keybind] = []
    /// `[keys] leader`: pressed before a `leader+…` shortcut.
    var leader = UserConfig.defaultLeader
    /// `[keys]` entries replacing a command's built-in shortcut.
    var shortcuts: [DenCommand: Shortcut] = [:]

    /// The command's shortcut after `[keys]` overrides.
    func shortcut(for command: DenCommand) -> Trigger? {
        switch shortcuts[command] {
        case .unbound?: nil
        case .bound(let trigger)?: trigger
        case nil: command.defaultShortcut.flatMap { try? Trigger.parse($0).get() }
        }
    }

    /// "⇧⌘P" or "⌥Space N" for menus and the palette.
    func shortcutLabel(_ command: DenCommand) -> String? {
        shortcut(for: command).map(label)
    }

    func label(_ trigger: Trigger) -> String {
        switch trigger {
        case .chord(let chord): chord.label
        case .leader(let chord): "\(leader.label) \(chord.label)"
        }
    }

    /// Keycap groups for tooltips, one group per keypress. `number` fills
    /// in a digit key (go_to_tab for tab 3 shows ⌘ 3).
    func keycaps(_ command: DenCommand, number: Int? = nil) -> [[String]] {
        switch shortcut(for: command) {
        case nil: []
        case .chord(let chord)?: [chord.keycaps(number: number)]
        case .leader(let chord)?: [leader.keycaps, chord.keycaps(number: number)]
        }
    }

    /// "⌘3" or "⌥Space 3": the shortcut for one numbered target.
    func shortcutLabel(_ command: DenCommand, number: Int) -> String? {
        let groups = keycaps(command, number: number)
        return groups.isEmpty ? nil : groups.map { $0.joined() }.joined(separator: " ")
    }

    /// What the key after the leader runs: a `[[keys.bind]]` entry, else
    /// a command's shortcut.
    func afterLeader(keyCode: UInt16, unmodified: String?, flags: NSEvent.ModifierFlags) -> Keybind.Action? {
        action(keyCode: keyCode, unmodified: unmodified, flags: flags) {
            guard case .leader(let chord) = $0 else { return nil }
            return chord
        }
    }

    /// A direct digit shortcut (go_to_tab = "cmd+digit"). Menus can't hold
    /// these, so the app's key monitor runs them.
    func numberCommand(keyCode: UInt16, unmodified: String?, flags: NSEvent.ModifierFlags) -> DenCommand? {
        let action = action(keyCode: keyCode, unmodified: unmodified, flags: flags) {
            guard case .chord(let chord) = $0, chord.key == .digit else { return nil }
            return chord
        }
        guard case .command(let command)? = action, command.takesNumber else { return nil }
        return command
    }

    private func action(keyCode: UInt16, unmodified: String?, flags: NSEvent.ModifierFlags,
                        chord: (Trigger) -> KeyChord?) -> Keybind.Action? {
        func matches(_ trigger: Trigger) -> Bool {
            chord(trigger)?.matches(keyCode: keyCode, unmodified: unmodified, flags: flags) ?? false
        }
        if let bind = keybinds.last(where: { matches($0.trigger) }) { return bind.action }
        return DenCommand.allCases.first { shortcut(for: $0).map(matches) ?? false }.map(Keybind.Action.command)
    }

    static var url: URL {
        directory.appending(path: "config.toml")
    }

    /// `~/.config/den` (honors `$XDG_CONFIG_HOME`).
    static var directory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "den")
    }

    /// Hand-written `*.json` themes live here; `examples/` holds every
    /// built-in theme in the same format for reference.
    static var themesDirectory: URL { directory.appending(path: "themes") }

    /// The direct (non-leader) keybind for a keypress. The last one for a
    /// chord wins, so later lines override earlier ones.
    func keybind(keyCode: UInt16, unmodified: String?, flags: NSEvent.ModifierFlags) -> Keybind? {
        keybinds.last {
            guard case .chord(let chord) = $0.trigger else { return false }
            return chord.matches(keyCode: keyCode, unmodified: unmodified, flags: flags)
        }
    }

    /// A missing file is the default config.
    static func load(from url: URL = url) -> Result<UserConfig, ConfigError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(UserConfig()) }
        do {
            return parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return .failure(ConfigError(message: "Could not read \(url.path): \(error.localizedDescription)."))
        }
    }

    static func parse(_ text: String) -> Result<UserConfig, ConfigError> {
        // TextEdit's smart quotes would otherwise break every string.
        let straightened = text
            .replacingOccurrences(of: "[“”„]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[‘’]", with: "'", options: .regularExpression)
        switch TOML.parse(straightened) {
        case .failure(let error): return .failure(ConfigError(message: "\(error)"))
        case .success(let root): return decode(root)
        }
    }

    private static func decode(_ root: TOML.Table) -> Result<UserConfig, ConfigError> {
        var config = UserConfig()
        switch root["macos_option_as_alt"] {
        case nil: break
        case .bool(let on)?: config.optionAsAlt = on ? .both : .none
        case let other?:
            guard case .string(let s) = other, let mode = OptionAsAlt(rawValue: s) else {
                return .failure(ConfigError(message: "macos_option_as_alt is \(describe(other)); use true, false, \"left\" or \"right\"."))
            }
            config.optionAsAlt = mode
        }

        func checkSize(_ key: String, _ size: Double) -> Result<Double?, ConfigError> {
            guard (8 ... 32).contains(size) else {
                return .failure(ConfigError(message: "\(key) is \(size); use a size 8–32."))
            }
            return .success(size)
        }
        func fontSize(_ key: String) -> Result<Double?, ConfigError> {
            switch root[key] {
            case nil: return .success(nil)
            case .integer(let i)?: return checkSize(key, Double(i))
            case .float(let f)?: return checkSize(key, f)
            case let other?: return .failure(ConfigError(message: "\(key) is \(describe(other)); use a size 8–32, e.g. \(key) = 13."))
            }
        }
        switch root["terminal_font"] {
        case nil: break
        case .string(let s)?: config.terminalFont = s
        case let other?: return .failure(ConfigError(message: "terminal_font is \(describe(other)); use a family like \"JetBrainsMono Nerd Font\"."))
        }
        switch fontSize("terminal_font_size") {
        case .success(let size): config.terminalFontSize = size
        case .failure(let e): return .failure(e)
        }
        switch root["ui_font"] {
        case nil: break
        case .string(let s)?: config.uiFont = s
        case let other?: return .failure(ConfigError(message: "ui_font is \(describe(other)); use a family like \"SF Mono\"."))
        }
        switch fontSize("ui_font_size") {
        case .success(let size): config.uiFontSize = size
        case .failure(let e): return .failure(e)
        }

        guard case .table(let keys) = root["keys"] ?? .table([:]) else {
            return .failure(ConfigError(message: "“keys” must be a table: [keys]."))
        }
        switch keys["leader"] {
        case nil: break
        case .string(let text)?:
            switch KeyChord.parse(text) {
            case .success(let chord): config.leader = chord
            case .failure(let e): return .failure(ConfigError(message: "[keys] leader: \(e.message)"))
            }
        case let other?:
            return .failure(ConfigError(message: "[keys] leader is \(describe(other)); use a key like \"opt+space\"."))
        }

        for (name, value) in keys.sorted(by: { $0.key < $1.key }) where name != "bind" && name != "leader" {
            guard let command = DenCommand(rawValue: name) else {
                return .failure(ConfigError(message: "[keys] has no command “\(name)”. Open Config File lists every command name."))
            }
            guard case .string(let text) = value else {
                return .failure(ConfigError(message: "[keys] \(name) must be a string like \"cmd+t\", or \"\" for no shortcut."))
            }
            if text.isEmpty {
                config.shortcuts[command] = .unbound
                continue
            }
            switch Trigger.parse(text) {
            case .success(let trigger): config.shortcuts[command] = .bound(trigger)
            case .failure(let e): return .failure(ConfigError(message: "[keys] \(name): \(e.message)"))
            }
        }

        guard case .array(let binds) = keys["bind"] ?? .array([]) else {
            return .failure(ConfigError(message: "keys.bind must be a list of [[keys.bind]] entries."))
        }
        for (i, entry) in binds.enumerated() {
            let n = i + 1
            guard case .table(let t) = entry, case .string(let key)? = t["key"], case .string(let action)? = t["action"] else {
                return .failure(ConfigError(message: "[[keys.bind]] #\(n) needs a string `key` and a string `action`, e.g. key = \"cmd+a\", action = 'text:\\x1ba'."))
            }
            switch (Trigger.parse(key), Keybind.Action.parse(action)) {
            case (.failure(let e), _), (_, .failure(let e)):
                return .failure(ConfigError(message: "[[keys.bind]] #\(n): \(e.message)"))
            case (.success(let trigger), .success(let action)):
                config.keybinds.append(Keybind(trigger: trigger, action: action))
            }
        }
        return .success(config)
    }

    private static func describe(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s): "\"\(s)\""
        case .integer(let i): "\(i)"
        case .float(let f): "\(f)"
        case .bool(let b): "\(b)"
        case .array: "a list"
        case .table: "a table"
        }
    }

    /// Written the first time you open the config.
    static var template: String {
        """
        # Den config. Changes apply when Den comes back to the front, or with
        # “Reload Config” in the command palette (⇧⌘,).

        # Option sends ESC-prefixed keys (alt) instead of typing symbols like å.
        # true | false | "left" | "right"
        macos_option_as_alt = true

        # Fonts, split by surface. When set, these win over Change Font and
        # ⌘=/⌘- on every reload; when commented out, the palette's choices
        # (persisted) apply. Sizes are 8–32.
        # terminal_font = "JetBrainsMono Nerd Font"
        # terminal_font_size = 13
        # ui_font = "SF Mono"
        # ui_font_size = 13

        # Shortcuts for Den's commands. Uncomment a line to change one; "" removes
        # it. Keys are modifiers (cmd, ctrl, opt, shift) and a key, e.g. "cmd+t",
        # "ctrl+shift+tab", "cmd+enter", "f5". "leader+n" means: press the
        # leader, let go, then n. Press the leader twice to send it to the program.
        [keys]
        leader = "opt+space"

        \(commandList)

        # Extra bindings, checked before the shortcuts above. Later entries win.
        #   action: a command name from the list above, e.g. "split_right"
        #           'text:<bytes>'  send bytes to the program (\\x1b or \\e is ESC)
        #           'passthrough'   send the key to the program instead of Den
        #           'ignore'        do nothing
        # Use single quotes for text actions so backslashes stay as written.
        #
        # Pass ⌘A/⌘C/⌘S/⌘X to Neovim as alt+key:
        # [[keys.bind]]
        # key = "cmd+a"
        # action = 'text:\\x1ba'

        """
    }

    private static var commandList: String {
        let width = DenCommand.allCases.map(\.rawValue.count).max() ?? 0
        return DenCommand.allCases.map { c in
            let name = c.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            return "# \(name) = \"\(c.defaultShortcut ?? "")\""
        }.joined(separator: "\n")
    }
}

struct ConfigError: Error, Equatable {
    let message: String
}

struct Keybind: Equatable {
    enum Action: Equatable {
        case command(DenCommand)
        case text(Data)
        case passthrough
        case ignore

        static func parse(_ text: String) -> Result<Action, ConfigError> {
            switch text {
            case "passthrough": return .success(.passthrough)
            case "ignore": return .success(.ignore)
            case _ where text.hasPrefix("text:"):
                return unescape(String(text.dropFirst(5))).map(Action.text)
            default:
                guard let command = DenCommand(rawValue: text) else {
                    return .failure(ConfigError(message: "unknown action “\(text)”; use a command name like \"new_tab\" (Open Config File lists them), 'text:…', 'passthrough' or 'ignore'."))
                }
                return .success(.command(command))
            }
        }

        /// Ghostty-style escapes: `\xNN`, `\e`, `\n`, `\r`, `\t`, `\\`.
        static func unescape(_ text: String) -> Result<Data, ConfigError> {
            var out = Data()
            var chars = text[...]
            while let c = chars.popFirst() {
                guard c == "\\" else { out.append(contentsOf: Array(String(c).utf8)); continue }
                switch chars.popFirst() {
                case "x":
                    let hex = chars.prefix(2)
                    guard hex.count == 2, let byte = UInt8(hex, radix: 16) else {
                        return .failure(ConfigError(message: "“\\x” in “\(text)” needs two hex digits, e.g. \\x1b."))
                    }
                    chars = chars.dropFirst(2)
                    out.append(byte)
                case "e": out.append(0x1B)
                case "n": out.append(0x0A)
                case "r": out.append(0x0D)
                case "t": out.append(0x09)
                case "\\": out.append(0x5C)
                case let other:
                    return .failure(ConfigError(message: "unknown escape “\\\(other.map(String.init) ?? "")” in “\(text)”."))
                }
            }
            return .success(out)
        }
    }

    let trigger: Trigger
    let action: Action
}

/// A key press, directly or after the leader (`leader+n`: press the
/// leader, let go, then n).
enum Trigger: Equatable {
    case chord(KeyChord)
    case leader(KeyChord)

    var configText: String {
        switch self {
        case .chord(let chord): chord.configText
        case .leader(let chord): "leader+" + chord.configText
        }
    }

    static func parse(_ text: String) -> Result<Trigger, ConfigError> {
        let lower = text.lowercased()
        guard lower.hasPrefix("leader+") else { return KeyChord.parse(text).map(Trigger.chord) }
        return KeyChord.parse(String(text.dropFirst("leader+".count))).map(Trigger.leader)
    }
}

struct KeyChord: Equatable {
    enum Modifier: CaseIterable {
        case command, control, option, shift

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .command: .command
            case .control: .control
            case .option: .option
            case .shift: .shift
            }
        }

        static func named(_ name: String) -> Modifier? {
            switch name {
            case "cmd", "command", "super": .command
            case "ctrl", "control": .control
            case "opt", "option", "alt": .option
            case "shift": .shift
            default: nil
            }
        }
    }

    enum Key: Equatable {
        /// What the key types with no modifiers on the current layout.
        case character(String)
        /// A key without text, by macOS virtual keycode.
        case code(UInt16)
        /// Any number key (`digit`, or `1..9`): the number picks the target.
        case digit
    }

    /// The number a digit key typed, or nil if it isn't one.
    static func digit(_ unmodified: String?) -> Int? {
        guard let unmodified, unmodified.count == 1, let n = Int(unmodified) else { return nil }
        return n
    }

    let modifiers: Set<Modifier>
    let key: Key

    static func parse(_ text: String) -> Result<KeyChord, ConfigError> {
        // "cmd++" binds plus: the last part is the key even if it's "+".
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        guard let keyName = parts.popLast(), !keyName.isEmpty else {
            return .failure(ConfigError(message: "“\(text)” has no key; write it like \"cmd+a\"."))
        }
        var modifiers: Set<Modifier> = []
        for part in parts {
            guard let m = Modifier.named(part.trimmingCharacters(in: .whitespaces)) else {
                return .failure(ConfigError(message: "unknown modifier “\(part)” in “\(text)”; use cmd, ctrl, opt or shift."))
            }
            modifiers.insert(m)
        }
        if let code = namedKeys[keyName] { return .success(KeyChord(modifiers: modifiers, key: .code(code))) }
        if ["digit", "number", "1..9", "1..n", "1-9", "1-n"].contains(keyName) {
            return .success(KeyChord(modifiers: modifiers, key: .digit))
        }
        guard keyName.count == 1 else {
            return .failure(ConfigError(message: "unknown key “\(keyName)” in “\(text)”; use one character or a name like enter, tab, space, up, f5."))
        }
        return .success(KeyChord(modifiers: modifiers, key: .character(keyName)))
    }

    static func modifiers(of flags: NSEvent.ModifierFlags) -> Set<Modifier> {
        Set(Modifier.allCases.filter { flags.contains($0.flag) })
    }

    func matches(keyCode: UInt16, unmodified: String?, flags: NSEvent.ModifierFlags) -> Bool {
        guard Self.modifiers(of: flags) == modifiers else { return false }
        switch key {
        case .code(let code): return code == keyCode
        case .character(let c): return unmodified?.lowercased() == c
        case .digit: return Self.digit(unmodified) != nil
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        modifiers.reduce(into: []) { $0.insert($1.flag) }
    }

    /// The menu item key equivalent. Shifted letters are written uppercase,
    /// which is how AppKit matches them.
    var keyEquivalent: String {
        switch key {
        case .digit: ""
        case .character(let c): modifiers.contains(.shift) ? c.uppercased() : c
        case .code(let code):
            switch Int(code) {
            case kVK_Return: "\r"
            case kVK_Tab: "\t"
            case kVK_Space: " "
            case kVK_Escape: "\u{1b}"
            case kVK_Delete: "\u{8}"
            default: Self.functionKeys[Int(code)].flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? ""
            }
        }
    }

    /// "⌥⇧⌘[" in Apple's modifier order.
    var label: String { keycaps.joined() }

    /// How config.toml writes it: "ctrl+opt+shift+cmd+left".
    var configText: String {
        let names: [(Modifier, String)] = [(.control, "ctrl"), (.option, "opt"), (.shift, "shift"), (.command, "cmd")]
        let keyName: String = switch key {
        case .character(let c): c
        case .digit: "digit"
        case .code(let code): Self.canonicalKeyNames[code] ?? "?"
        }
        return (names.filter { modifiers.contains($0.0) }.map(\.1) + [keyName]).joined(separator: "+")
    }

    /// One spelling per keycode, preferring the first alias listed.
    private static let canonicalKeyNames: [UInt16: String] = {
        let preferred = ["enter", "tab", "space", "escape", "backspace", "delete", "up", "down", "left", "right",
                         "home", "end", "page_up", "page_down"] + (1 ... 12).map { "f\($0)" }
        var names: [UInt16: String] = [:]
        for name in preferred { if let code = namedKeys[name], names[code] == nil { names[code] = name } }
        return names
    }()

    /// One label per key, for tooltip keycaps: ["⇧", "⌘", "P"].
    var keycaps: [String] { keycaps(number: nil) }

    /// With `number`, a digit key shows that number (["⌘", "1", "2"]).
    func keycaps(number: Int?) -> [String] {
        let marks: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let keyLabels: [String] = switch key {
        case .character(let c): [c.uppercased()]
        case .code(let code): [Self.codeLabels[Int(code)] ?? "?"]
        case .digit: number.map { String($0).map(String.init) } ?? ["1–9"]
        }
        return marks.filter { modifiers.contains($0.0) }.map(\.1) + keyLabels
    }

    private static let functionKeys: [Int: Int] = {
        var keys = [
            kVK_ForwardDelete: NSDeleteFunctionKey, kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
            kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey, kVK_Home: NSHomeFunctionKey,
            kVK_End: NSEndFunctionKey, kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        ]
        for (i, code) in fKeys.enumerated() { keys[code] = NSF1FunctionKey + i }
        return keys
    }()

    private static let codeLabels: [Int: String] = {
        var labels = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        for (i, code) in fKeys.enumerated() { labels[code] = "F\(i + 1)" }
        return labels
    }()

    private static let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]

    private static let namedKeys: [String: UInt16] = {
        var keys: [String: Int] = [
            "enter": kVK_Return, "return": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
            "escape": kVK_Escape, "esc": kVK_Escape, "backspace": kVK_Delete, "delete": kVK_ForwardDelete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End, "page_up": kVK_PageUp, "page_down": kVK_PageDown,
        ]
        for (i, code) in fKeys.enumerated() { keys["f\(i + 1)"] = code }
        return keys.mapValues { UInt16($0) }
    }()
}
