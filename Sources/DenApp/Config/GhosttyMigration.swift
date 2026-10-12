import Foundation

/// Carries the Ghostty settings Den understands (`macos-option-as-alt` and
/// `keybind`) into the text of Den's config.toml, keeping what's there.
enum GhosttyMigration {
    struct Outcome: Equatable {
        /// The new config.toml text.
        var config: String
        /// Ghostty's `macos-option-as-alt` value, when it set one.
        var optionAsAlt: String?
        /// Triggers of the keybinds carried over, e.g. "super+a".
        var keybinds: [String]
        /// Keybinds Den can't express; left as comments in the config.
        var skipped: [String]
    }

    static func migrate(ghostty: String, into existing: String) -> Result<Outcome, ConfigError> {
        let current: UserConfig
        switch UserConfig.parse(existing) {
        case .success(let c): current = c
        case .failure(let e):
            return .failure(ConfigError(message: "Den's config has an error, so nothing was migrated: \(e.message)"))
        }
        var outcome = Outcome(config: existing, optionAsAlt: nil, keybinds: [], skipped: [])
        var bound = current.keybinds.compactMap { bind -> KeyChord? in
            guard case .chord(let chord) = bind.trigger else { return nil }
            return chord
        }
        var blocks: [String] = []

        for raw in ghostty.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            switch key {
            case "macos-option-as-alt":
                guard ["true", "false", "left", "right"].contains(value) else { continue }
                outcome.config = setOptionAsAlt(value, in: outcome.config)
                outcome.optionAsAlt = value
            case "keybind":
                switch keybind(value) {
                case .failure(let reason):
                    let note = "# Not migrated from Ghostty (\(reason.message)): keybind = \(value)"
                    if !outcome.config.contains(note) { blocks.append(note) }
                    outcome.skipped.append(value)
                case .success(let (chordText, chord, action)):
                    guard !bound.contains(chord) else { continue }
                    bound.append(chord)
                    blocks.append("""
                    # From Ghostty: keybind = \(value)
                    [[keys.bind]]
                    key = "\(chordText)"
                    action = \(tomlString(action))
                    """)
                    outcome.keybinds.append(String(value.prefix { $0 != "=" }))
                }
            default: continue
            }
        }
        if !blocks.isEmpty {
            var text = outcome.config
            while text.hasSuffix("\n\n") { text.removeLast() }
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            outcome.config = text + (text.isEmpty ? "" : "\n") + blocks.joined(separator: "\n\n") + "\n"
        }
        return .success(outcome)
    }

    /// Replaces the top-level `macos_option_as_alt` line, or adds one above
    /// the first table so it stays top-level.
    private static func setOptionAsAlt(_ value: String, in text: String) -> String {
        let setting = "macos_option_as_alt = " + (value == "true" || value == "false" ? value : "\"\(value)\"")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        if let existing = lines[..<firstTable].firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("macos_option_as_alt") && t.dropFirst("macos_option_as_alt".count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }) {
            lines[existing] = setting
        } else if firstTable == lines.endIndex {
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines.append(setting)
            lines.append("")
        } else {
            lines.insert(contentsOf: [setting, ""], at: firstTable)
        }
        return lines.joined(separator: "\n")
    }

    /// `super+a=text:\x1ba` → ("cmd+a", chord, "text:\x1ba").
    private static func keybind(_ value: String) -> Result<(String, KeyChord, String), ConfigError> {
        guard let eq = value.firstIndex(of: "="), eq != value.startIndex else {
            return .failure(ConfigError(message: "not trigger=action"))
        }
        let trigger = String(value[..<eq]).lowercased()
        let ghosttyAction = String(value[value.index(after: eq)...])
        if trigger.contains(":") { return .failure(ConfigError(message: "Den has no trigger prefixes like global:")) }
        if trigger.contains(">") { return .failure(ConfigError(message: "Den has no key sequences")) }

        let action: String
        switch ghosttyAction {
        case "ignore": action = "ignore"
        case "unbind": action = "passthrough"
        case _ where ghosttyAction.hasPrefix("text:"): action = ghosttyAction
        default:
            guard let command = commands[ghosttyAction] else {
                return .failure(ConfigError(message: "Den has no \(ghosttyAction.prefix { $0 != ":" }) action"))
            }
            action = command.rawValue
        }
        if case .failure(let e) = Keybind.Action.parse(action) { return .failure(e) }

        var parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if trigger.hasSuffix("++") { parts.removeLast(2); parts.append("+") }
        let mapped = parts.map { modifierNames[$0] ?? keyNames[$0] ?? $0 }
        let chordText = mapped.last == "+" ? mapped.dropLast().joined(separator: "+") + "++" : mapped.joined(separator: "+")
        switch KeyChord.parse(chordText) {
        case .success(let chord): return .success((chordText, chord, action))
        case .failure: return .failure(ConfigError(message: "Den doesn't know the key “\(parts.last ?? trigger)”"))
        }
    }

    /// Ghostty actions with a Den equivalent.
    private static let commands: [String: DenCommand] = {
        let map: [String: DenCommand] = [
            "toggle_command_palette": .commandPalette, "open_config": .openConfig, "reload_config": .reloadConfig,
            "quit": .quit, "new_tab": .newTab, "new_window": .newSession, "close_surface": .closePane, "close_tab": .closeTab,
            "copy_to_clipboard": .copy, "paste_from_clipboard": .paste, "select_all": .selectAll,
            "increase_font_size:1": .fontBigger, "decrease_font_size:1": .fontSmaller, "reset_font_size": .fontReset,
            "toggle_fullscreen": .toggleFullScreen, "new_split:right": .splitRight, "new_split:down": .splitDown,
            "toggle_split_zoom": .zoomPane, "goto_split:next": .nextPane, "goto_split:previous": .previousPane,
            "next_tab": .nextTab, "previous_tab": .previousTab, "move_tab:-1": .moveTabLeft, "move_tab:1": .moveTabRight,
            "last_tab": .lastTab,
        ]
        return map
    }()

    private static let modifierNames = ["super": "cmd", "command": "cmd", "alt": "opt", "option": "opt", "control": "ctrl"]

    private static let keyNames: [String: String] = {
        var names = [
            "arrow_up": "up", "arrow_down": "down", "arrow_left": "left", "arrow_right": "right",
            "equal": "=", "minus": "-", "plus": "+", "comma": ",", "period": ".", "slash": "/", "semicolon": ";",
            "quote": "'", "backquote": "`", "grave_accent": "`", "bracket_left": "[", "bracket_right": "]", "backslash": "\\",
        ]
        for d in 0 ... 9 { names["digit_\(d)"] = "\(d)" }
        return names
    }()

    private static func unquote(_ s: String) -> String {
        s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s
    }

    /// Literal string when possible, so `\x1b` stays readable.
    private static func tomlString(_ s: String) -> String {
        if !s.contains("'") { return "'\(s)'" }
        return "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
