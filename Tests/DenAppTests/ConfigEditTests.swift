import Testing
@testable import DenApp

@Suite struct ConfigEditTests {
    private let template = """
    # Den config.

    # Where the toast pill sits.
    toast_position = "bottom-center"
    # terminal_font = "JetBrainsMono Nerd Font"

    [keys]
    leader = "opt+space"
    # new_tab = "leader+n"

    [[keys.bind]]
    key = "cmd+a"
    action = 'text:\\x1ba'
    """

    private func edit(_ key: String, _ value: TOMLValue?, table: String? = nil, in text: String? = nil) -> String {
        ConfigEdit.setting(key, to: value, inTable: table, of: text ?? template)
    }

    @Test func replacesAnActiveLineInPlace() throws {
        let out = edit("toast_position", .string("top-right"))
        #expect(out.contains("toast_position = \"top-right\""))
        #expect(!out.contains("bottom-center"))
        #expect(out.contains("# Where the toast pill sits."))
    }

    @Test func uncommentsAMatchingCommentedLine() throws {
        let out = edit("terminal_font", .string("Berkeley Mono"))
        #expect(out.contains("\nterminal_font = \"Berkeley Mono\"\n"))
        #expect(!out.contains("# terminal_font"))
    }

    @Test func addsAMissingTopLevelKeyBeforeTheFirstTable() throws {
        let out = edit("macos_option_as_alt", .string("left"))
        let root = try TOML.parse(out).get()
        #expect(root["macos_option_as_alt"] == .string("left"))
        guard case .table(let keys)? = root["keys"] else { Issue.record("keys table lost"); return }
        #expect(keys["macos_option_as_alt"] == nil)
    }

    @Test func editsKeysInsideTheNamedTableOnly() throws {
        let out = edit("new_tab", .string("cmd+t"), table: "keys")
        let root = try TOML.parse(out).get()
        guard case .table(let keys)? = root["keys"] else { Issue.record("keys table lost"); return }
        #expect(keys["new_tab"] == .string("cmd+t"))
        #expect(keys["leader"] == .string("opt+space"))
        // [[keys.bind]] entries stay intact.
        guard case .array(let binds)? = keys["bind"] else { Issue.record("binds lost"); return }
        #expect(binds.count == 1)
    }

    @Test func removingAKeyDeletesItsLine() throws {
        let out = edit("leader", nil, table: "keys")
        let root = try TOML.parse(out).get()
        guard case .table(let keys)? = root["keys"] else { Issue.record("keys table lost"); return }
        #expect(keys["leader"] == nil)
    }

    @Test func createsAMissingTable() throws {
        let out = edit("leader", .string("ctrl+a"), table: "keys", in: "toast_position = \"top-left\"\n")
        let root = try TOML.parse(out).get()
        #expect(root["toast_position"] == .string("top-left"))
        #expect(root["keys"] == .table(["leader": .string("ctrl+a")]))
    }

    @Test func writesValuesAsTOMLLiterals() throws {
        let out = edit("weird", .string("a \"quoted\" \\ path"), in: "")
        #expect(try TOML.parse(out).get()["weird"] == .string("a \"quoted\" \\ path"))
        #expect(try TOML.parse(edit("on", .bool(true), in: "")).get()["on"] == .bool(true))
        #expect(try TOML.parse(edit("size", .float(13.5), in: "")).get()["size"] == .float(13.5))
        #expect(try TOML.parse(edit("size", .integer(13), in: "")).get()["size"] == .integer(13))
    }
}
