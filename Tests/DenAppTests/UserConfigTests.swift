import AppKit
import Foundation
import Testing
import DenVT
@testable import DenApp

@Suite struct TOMLTests {
    @Test func parsesTablesArraysOfTablesAndScalars() throws {
        let text = """
        onboarding = false # trailing comment
        [ui]
        sidebar_width = 32
        ratio = 0.5
        [ui.toast]
        delivery = "herdr"
        [[keys.command]]
        key = "prefix+a"
        [[keys.command]]
        key = 'prefix+c'
        tags = ["a", 'b',]
        point = { x = 1, y = 2 }
        """
        let root = try TOML.parse(text).get()
        #expect(root["onboarding"] == .bool(false))
        #expect(root["ui"] == .table([
            "sidebar_width": .integer(32), "ratio": .float(0.5),
            "toast": .table(["delivery": .string("herdr")]),
        ]))
        #expect(root["keys"] == .table(["command": .array([
            .table(["key": .string("prefix+a")]),
            .table(["key": .string("prefix+c"), "tags": .array([.string("a"), .string("b")]),
                    "point": .table(["x": .integer(1), "y": .integer(2)])]),
        ])]))
    }

    @Test func basicStringEscapesAndLiteralStringsStayRaw() throws {
        let root = try TOML.parse(#"a = "\u001b\e\t\"" "# + "\n" + #"b = 'text:\x1ba'"#).get()
        #expect(root["a"] == .string("\u{1b}\u{1b}\t\""))
        #expect(root["b"] == .string(#"text:\x1ba"#))
    }

    @Test func dottedKeysCreateTables() throws {
        let root = try TOML.parse("theme.name = \"mocha\"\n\"quoted key\" = 1").get()
        #expect(root["theme"] == .table(["name": .string("mocha")]))
        #expect(root["quoted key"] == .integer(1))
    }

    @Test func duplicateKeyFailsWithLine() {
        #expect(TOML.parse("a = 1\n\na = 2") == .failure(TOMLError(line: 3, message: "“a” is set twice")))
    }

    @Test func rejectsUnquotedStringsAndUnknownEscapes() {
        guard case .failure(let bare) = TOML.parse("name = mocha") else { Issue.record("parsed"); return }
        #expect(bare.line == 1)
        guard case .failure(let escape) = TOML.parse(#"x = "\x1b""#) else { Issue.record("parsed"); return }
        #expect(escape.message.contains("single quotes"))
    }

    @Test func rejectsMultilineStrings() {
        guard case .failure(let e) = TOML.parse("a = \"\"\"\nx\n\"\"\"") else { Issue.record("parsed"); return }
        #expect(e.message.contains("multi-line"))
    }
}

@Suite struct UserConfigTests {
    @Test func emptyFileIsTheDefault() throws {
        #expect(try UserConfig.parse("").get() == UserConfig())
        #expect(UserConfig().optionAsAlt == .both)
    }

    @Test func templateParses() throws {
        #expect(try UserConfig.parse(UserConfig.template).get() == UserConfig())
    }

    @Test func optionAsAltAcceptsGhosttyValues() throws {
        #expect(try UserConfig.parse("macos_option_as_alt = \"left\"").get().optionAsAlt == .left)
        #expect(try UserConfig.parse("macos_option_as_alt = \"right\"").get().optionAsAlt == .right)
        #expect(try UserConfig.parse("macos_option_as_alt = false").get().optionAsAlt == OptionAsAlt.none)
        #expect(try UserConfig.parse("macos_option_as_alt = true").get().optionAsAlt == .both)
        guard case .failure(let e) = UserConfig.parse("macos_option_as_alt = 3") else { Issue.record("parsed"); return }
        #expect(e.message.contains("left"))
    }

    /// The Ghostty bindings that pass ⌘A etc. to Neovim as alt+key.
    @Test func textKeybindSendsEscapedBytes() throws {
        let config = try UserConfig.parse("""
        [[keys.bind]]
        key = "cmd+a"
        action = 'text:\\x1ba'
        """).get()
        let bind = config.keybind(keyCode: 0x00, unmodified: "a", flags: .command)
        #expect(bind?.action == .text(Data([0x1B, UInt8(ascii: "a")])))
        #expect(config.keybind(keyCode: 0x00, unmodified: "a", flags: [.command, .shift]) == nil)
        #expect(config.keybind(keyCode: 0x00, unmodified: "a", flags: []) == nil)
    }

    @Test func textEditSmartQuotesStillParse() throws {
        let config = try UserConfig.parse("[[keys.bind]]\nkey = “cmd+c”\naction = ‘text:\\ec’")
            .get()
        #expect(config.keybinds == [Keybind(trigger: .chord(KeyChord(modifiers: [.command], key: .character("c"))), action: .text(Data([0x1B, 0x63])))])
    }

    @Test func laterKeybindWins() throws {
        let config = try UserConfig.parse("""
        [[keys.bind]]
        key = "ctrl+tab"
        action = "ignore"
        [[keys.bind]]
        key = "control+tab"
        action = "passthrough"
        """).get()
        #expect(config.keybind(keyCode: 0x30, unmodified: "\t", flags: .control)?.action == .passthrough)
    }

    @Test func invalidKeybindsExplainThemselves() {
        let cases = [
            ("key = \"hyper+a\"\naction = \"ignore\"", "unknown modifier"),
            ("key = \"cmd+banana\"\naction = \"ignore\"", "unknown key"),
            ("key = \"cmd+a\"\naction = \"launch\"", "unknown action"),
            ("key = \"cmd+a\"\naction = 'text:\\xZ1'", "two hex digits"),
            ("key = \"cmd+a\"", "needs a string"),
        ]
        for (body, expected) in cases {
            guard case .failure(let e) = UserConfig.parse("[[keys.bind]]\n" + body) else { Issue.record("parsed \(body)"); continue }
            #expect(e.message.contains(expected), "\(e.message)")
        }
    }

    @Test func chordParsesNamedKeysAndPlus() throws {
        #expect(try KeyChord.parse("cmd+enter").get() == KeyChord(modifiers: [.command], key: .code(0x24)))
        #expect(try KeyChord.parse("F5").get() == KeyChord(modifiers: [], key: .code(0x60)))
        #expect(try KeyChord.parse("cmd++").get() == KeyChord(modifiers: [.command], key: .character("+")))
    }

    @Test func unknownTopLevelSectionsAreIgnored() throws {
        let config = try UserConfig.parse("""
        onboarding = false
        [ui]
        sidebar_width = 32
        """).get()
        #expect(config == UserConfig())
    }

    /// A typo under [keys] would silently do nothing, so it's an error.
    @Test func unknownCommandUnderKeysFails() {
        guard case .failure(let e) = UserConfig.parse("[keys]\nnew_tabb = \"cmd+t\"") else { Issue.record("parsed"); return }
        #expect(e.message.contains("new_tabb"))
    }

    @Test func keysTableOverridesAndUnbindsShortcuts() throws {
        let config = try UserConfig.parse("""
        [keys]
        new_tab = "cmd+shift+t"
        select_all = ""
        """).get()
        #expect(config.shortcut(for: .newTab) == .chord(KeyChord(modifiers: [.command, .shift], key: .character("t"))))
        #expect(config.shortcut(for: .selectAll) == nil)
        #expect(config.shortcutLabel(.splitRight) == "⌥Space \\")
        #expect(config.shortcutLabel(.newTab) == "⇧⌘T")
    }

    @Test func keybindCanRunACommand() throws {
        let config = try UserConfig.parse("[[keys.bind]]\nkey = \"ctrl+d\"\naction = \"split_down\"").get()
        #expect(config.keybind(keyCode: 0x02, unmodified: "d", flags: .control)?.action == .command(.splitDown))
    }

    @Test func defaultLeaderShortcuts() {
        let config = UserConfig()
        let opt = NSEvent.ModifierFlags.option
        #expect(config.leader.matches(keyCode: 0x31, unmodified: " ", flags: opt))
        #expect(config.afterLeader(keyCode: 0x2D, unmodified: "n", flags: []) == .command(.newTab))
        #expect(config.afterLeader(keyCode: 0x04, unmodified: "h", flags: []) == .command(.focusPaneLeft))
        #expect(config.afterLeader(keyCode: 0x26, unmodified: "j", flags: []) == .command(.focusPaneDown))
        #expect(config.afterLeader(keyCode: 0x25, unmodified: "l", flags: .shift) == .command(.resizePaneRight))
        #expect(config.afterLeader(keyCode: 0x04, unmodified: "h", flags: .shift) == .command(.resizePaneLeft))
        #expect(config.afterLeader(keyCode: 0x2A, unmodified: "\\", flags: []) == .command(.splitRight))
        #expect(config.afterLeader(keyCode: 0x09, unmodified: "v", flags: []) == .command(.splitDown))
        #expect(config.afterLeader(keyCode: 0x0F, unmodified: "r", flags: []) == .command(.renameTab))
        #expect(config.afterLeader(keyCode: 0x0F, unmodified: "r", flags: .shift) == .command(.renameSession))
        #expect(config.afterLeader(keyCode: 0x14, unmodified: "3", flags: []) == .command(.goToSession))
        #expect(config.afterLeader(keyCode: 0x07, unmodified: "x", flags: []) == .command(.addRemoteHost))
        #expect(config.afterLeader(keyCode: 0x05, unmodified: "g", flags: []) == nil)
        #expect(config.keycaps(.newTab) == [["⌥", "Space"], ["N"]])
        #expect(config.keycaps(.goToTab, number: 12) == [["⌘", "1", "2"]])
        #expect(config.keycaps(.goToTab) == [["⌘", "1–9"]])
        #expect(config.numberCommand(keyCode: 0x13, unmodified: "2", flags: .command) == .goToTab)
        #expect(config.numberCommand(keyCode: 0x13, unmodified: "2", flags: []) == nil)
    }

    @Test func customLeaderAndLeaderKeybinds() throws {
        let config = try UserConfig.parse("""
        [keys]
        leader = "ctrl+b"
        new_tab = "leader+c"
        [[keys.bind]]
        key = "leader+g"
        action = 'text:lazygit\\r'
        """).get()
        #expect(config.leader == KeyChord(modifiers: [.control], key: .character("b")))
        #expect(config.afterLeader(keyCode: 0x08, unmodified: "c", flags: []) == .command(.newTab))
        #expect(config.afterLeader(keyCode: 0x05, unmodified: "g", flags: []) == .text(Data("lazygit\r".utf8)))
        #expect(config.shortcutLabel(.newTab) == "⌃B C")
        // Leader keybinds never fire as direct keys.
        #expect(config.keybind(keyCode: 0x05, unmodified: "g", flags: []) == nil)
    }

    @Test func everyDefaultShortcutParsesAndIsUnique() throws {
        var seen: [String: DenCommand] = [:]
        for command in DenCommand.allCases {
            guard let text = command.defaultShortcut else { continue }
            let label = UserConfig().label(try Trigger.parse(text).get())
            #expect(seen[label] == nil, "\(command) and \(String(describing: seen[label])) share \(label)")
            seen[label] = command
        }
    }

    @Test func labelsAndMenuKeysForNamedKeys() throws {
        let zoom = try KeyChord.parse("cmd+shift+enter").get()
        #expect(zoom.label == "⇧⌘↩")
        #expect(zoom.keyEquivalent == "\r")
        let peek = try KeyChord.parse("ctrl+cmd+down").get()
        #expect(peek.label == "⌃⌘↓")
        #expect(peek.keyEquivalent == String(Character(UnicodeScalar(NSDownArrowFunctionKey) ?? " ")))
        #expect(try KeyChord.parse("cmd+shift+p").get().keyEquivalent == "P")
    }
}

@Suite struct CloseOrderTests {
    /// Closing tab 3 of 4 shows tab 2; closing the first shows the new first.
    @Test func closedItemHandsOverToTheOneBefore() {
        #expect(AppModel.neighbor(of: 2, in: ["1", "2", "4"]) == "2")
        #expect(AppModel.neighbor(of: 0, in: ["2", "3"]) == "2")
        #expect(AppModel.neighbor(of: 3, in: ["1", "2", "3"]) == "3")
        #expect(AppModel.neighbor(of: nil, in: ["1", "2"]) == "1")
        #expect(AppModel.neighbor(of: 1, in: [String]()) == nil)
    }
}

@Suite struct GhosttyMigrationTests {
    let ghostty = """
    macos-option-as-alt = left
    font-size = 18
    keybind = super+a=text:\\x1ba
    keybind = super+shift+t=new_tab
    keybind = super+digit_3=last_tab
    keybind = ctrl+tab=ignore
    keybind = super+k=clear_screen
    keybind = ctrl+a>n=new_tab
    """

    @Test func carriesOptionKeyAndKeybindsIntoTheTemplate() throws {
        let outcome = try GhosttyMigration.migrate(ghostty: ghostty, into: UserConfig.template).get()
        #expect(outcome.optionAsAlt == "left")
        #expect(outcome.keybinds == ["super+a", "super+shift+t", "super+digit_3", "ctrl+tab"])
        #expect(outcome.skipped.count == 2)

        let config = try UserConfig.parse(outcome.config).get()
        #expect(config.optionAsAlt == .left)
        #expect(config.keybinds.map(\.action) == [
            .text(Data([0x1B, UInt8(ascii: "a")])), .command(.newTab), .command(.lastTab), .ignore,
        ])
        #expect(outcome.config.contains("# Not migrated from Ghostty (Den has no clear_screen action)"))
    }

    /// Running it twice adds nothing new.
    @Test func isIdempotent() throws {
        let once = try GhosttyMigration.migrate(ghostty: ghostty, into: "").get()
        let twice = try GhosttyMigration.migrate(ghostty: ghostty, into: once.config).get()
        #expect(twice.config == once.config)
        #expect(twice.keybinds.isEmpty)
    }

    @Test func replacesExistingOptionSettingAboveTables() throws {
        let existing = "macos_option_as_alt = true\n\n[keys]\nnew_tab = \"cmd+t\"\n"
        let outcome = try GhosttyMigration.migrate(ghostty: "macos-option-as-alt = right", into: existing).get()
        #expect(outcome.config == "macos_option_as_alt = \"right\"\n\n[keys]\nnew_tab = \"cmd+t\"\n")
    }

    @Test func brokenDenConfigIsLeftAlone() {
        guard case .failure(let e) = GhosttyMigration.migrate(ghostty: ghostty, into: "x = ") else { Issue.record("migrated"); return }
        #expect(e.message.contains("nothing was migrated"))
    }
}
