import Foundation

/// `den keybinds`: every command and what triggers it under the current
/// config.toml.
enum KeybindList {
    struct Row: Encodable {
        let command: String
        let title: String
        /// Config syntax, nil when not set.
        let shortcut: String?
        /// As menus show it, nil when not set.
        let label: String?
        let source: Source
    }

    enum Source: String, Encodable {
        case `default`, custom
        case notSet = "not set"
    }

    static func rows(_ config: UserConfig) -> [Row] {
        DenCommand.allCases.map { command in
            let trigger = config.shortcut(for: command)
            let builtIn = command.defaultShortcut.flatMap { try? Trigger.parse($0).get() }
            // A [keys] line repeating the default (as the template does) isn't a change.
            let source: Source = trigger == nil ? .notSet : trigger == builtIn ? .default : .custom
            return Row(command: command.rawValue, title: command.title, shortcut: trigger?.configText,
                       label: trigger.map(config.label), source: source)
        }
    }

    static func print(onlyUnset: Bool, onlyCustom: Bool, json: Bool) -> Int32 {
        let config: UserConfig
        switch UserConfig.load() {
        case .success(let loaded): config = loaded
        case .failure(let error):
            CLIOutput.error("\(UserConfig.url.path): \(error.message) Showing Den's built-in shortcuts instead.")
            config = UserConfig()
        }
        let rows = rows(config).filter { row in
            (!onlyUnset || row.source == .notSet) && (!onlyCustom || row.source == .custom)
        }
        if json {
            CLIOutput.json(rows)
            return 0
        }
        Swift.print("\(CLIOutput.bold("leader")) \(config.label(.chord(config.leader))) (\(config.leader.configText))  "
            + CLIOutput.dim("leader+x: press the leader, let go, then x"))
        Swift.print()
        CLIOutput.table(["COMMAND", "SHORTCUT", "KEYS", "SOURCE", "DOES"], rows.map {
            [$0.command, $0.shortcut ?? "not set", $0.label ?? "-", $0.source.rawValue, $0.title]
        })
        if !config.keybinds.isEmpty, !onlyUnset {
            Swift.print()
            Swift.print(CLIOutput.bold("[[keys.bind]] entries") + CLIOutput.dim("  (checked first; later entries win)"))
            CLIOutput.table(["KEY", "KEYS", "ACTION"], config.keybinds.map { [$0.trigger.configText, config.label($0.trigger), describe($0.action)] })
        }
        Swift.print()
        Swift.print(CLIOutput.dim("Change one under [keys] in \(UserConfig.url.path); `den config help keys` explains how."))
        return 0
    }

    private static func describe(_ action: Keybind.Action) -> String {
        switch action {
        case .command(let command): command.rawValue
        case .text(let bytes): "text: " + bytes.map { $0 >= 0x20 && $0 < 0x7F ? String(UnicodeScalar($0)) : String(format: "\\x%02x", $0) }.joined()
        case .passthrough: "passthrough"
        case .ignore: "ignore"
        }
    }
}
