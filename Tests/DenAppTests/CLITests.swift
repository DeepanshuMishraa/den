import Foundation
import Testing
import DenProtocol
@testable import DenApp

@Suite struct CLITargetTests {
    let video = SessionID(UUID(uuidString: "01A0A1EE-3D84-779D-8FE4-BBDB65F194FC") ?? UUID())
    let other = SessionID(UUID(uuidString: "77AA0000-0000-0000-0000-000000000000") ?? UUID())
    let shell = PaneID(UUID(uuidString: "42020F00-0000-0000-0000-000000000001") ?? UUID())
    let nvim = PaneID(UUID(uuidString: "B0529200-0000-0000-0000-000000000002") ?? UUID())

    func pane(_ id: PaneID, label: String?, process: String, age: TimeInterval) -> PaneState {
        PaneState(id: id, label: label, command: [], keepOpen: false, process: process, cwd: nil, title: nil, cols: 80, rows: 24,
                  createdAt: Date(timeIntervalSince1970: 1000 - age), child: nil, foreground: nil, exit: nil)
    }

    var state: DenState {
        let tab = TabState(id: TabID(), title: "primary", layout: .split(axis: .horizontal, ratio: 0.5, first: .pane(shell), second: .pane(nvim)),
                           panes: [pane(shell, label: nil, process: "zsh", age: 10), pane(nvim, label: "nvim", process: "nvim", age: 5)])
        return DenState(host: "Mac", protocolVersion: protocolVersion, sessions: [
            SessionState(id: video, name: "Video", tabs: [tab]),
            SessionState(id: other, name: "other", tabs: []),
        ], clients: [])
    }

    @Test func sessionsResolveByNameIDOrEnvironment() throws {
        let t = CLITargets(state: state, environment: [:])
        #expect(try t.session("Video").id == video)
        #expect(try t.session("video").id == video)
        #expect(try t.session("01a0a1ee").id == video)
        #expect(try t.session("session:01a0a1ee-3d84-779d-8fe4-bbdb65f194fc").id == video)
        #expect(throws: CLIError.self) { try t.session(nil) }
        #expect(throws: CLIError.self) { try t.session("nope") }
        let inside = CLITargets(state: state, environment: ["DEN_PANE_ID": shell.raw.uuidString])
        #expect(try inside.session(nil).id == video)
    }

    @Test func panesResolveByLabelProcessIDOrDefault() throws {
        let t = CLITargets(state: state, environment: [:])
        let session = try t.session("Video")
        #expect(try t.pane("nvim", in: session).id == nvim)
        #expect(try t.pane("zsh", in: session).id == shell)
        #expect(try t.pane("4202", in: session).id == shell)
        // No reference and not inside Den: the newest pane.
        #expect(try t.pane(nil, in: session).id == nvim)
        let inside = CLITargets(state: state, environment: ["DEN_PANE_ID": shell.raw.uuidString])
        #expect(try inside.pane(nil, in: session).id == shell)
        #expect(throws: CLIError.self) { try t.pane("42", in: session) }
    }

    @Test func tabsResolveByNumberOrTitle() throws {
        let t = CLITargets(state: state, environment: [:])
        let session = try t.session("Video")
        #expect(try t.tab("1", in: session).title == "primary")
        #expect(try t.tab("primary", in: session).title == "primary")
        #expect(throws: CLIError.self) { try t.tab("2", in: session) }
    }
}

@Suite struct CLIArgsTests {
    @Test func optionsFlagsPositionalsAndRest() throws {
        var args = CLIArgs(["-s", "video", "--label=nvim", "--keep-open", "extra", "--", "nvim", "-u", "NONE"])
        #expect(try args.option("-s", "--session") == "video")
        #expect(try args.option("--label", "-l") == "nvim")
        let keepOpen = args.flag("--keep-open")
        #expect(keepOpen)
        #expect(args.rest == ["nvim", "-u", "NONE"])
        #expect(throws: CLIError.self) { try args.finish() }
        let positional = args.next()
        #expect(positional == "extra")
        try args.finish()
    }

    @Test func missingOptionValueIsAUsageError() {
        var args = CLIArgs(["-s"])
        var threw = false
        do { _ = try args.option("-s") } catch { threw = true }
        #expect(threw)
    }
}

@Suite struct KeyNamesTests {
    func bytes(_ name: String) throws -> [UInt8] { [UInt8](try KeyNames.bytes(name).get()) }

    @Test func namesModifiersAndCharacters() throws {
        #expect(try bytes("enter") == [0x0D])
        #expect(try bytes("ctrl-c") == [0x03])
        #expect(try bytes("C-a") == [0x01])
        #expect(try bytes("ctrl-space") == [0x00])
        #expect(try bytes("alt-x") == [0x1B, 0x78])
        #expect(try bytes("up") == Array("\u{1B}[A".utf8))
        #expect(try bytes("f5") == Array("\u{1B}[15~".utf8))
        #expect(try bytes(":") == [0x3A])
        #expect(throws: CLIError.self) { try bytes("hyper") }
        #expect(throws: CLIError.self) { try bytes("ctrl-1") }
    }
}

@Suite struct KeybindListTests {
    @Test func reportsDefaultCustomAndNotSet() throws {
        let config = try UserConfig.parse("""
        [keys]
        command_palette = "cmd+shift+p"
        new_tab = "cmd+t"
        close_tab = ""
        last_tab = "cmd+9"
        """).get()
        let rows = Dictionary(uniqueKeysWithValues: KeybindList.rows(config).map { ($0.command, $0) })
        #expect(rows["command_palette"]?.source == .default)
        #expect(rows["new_tab"]?.source == .custom)
        #expect(rows["new_tab"]?.shortcut == "cmd+t")
        #expect(rows["close_tab"]?.source == .notSet)
        #expect(rows["close_tab"]?.shortcut == nil)
        #expect(rows["last_tab"]?.source == .custom)
        #expect(rows["change_theme"]?.source == .notSet)
        #expect(rows["split_right"]?.shortcut == "leader+\\")
        #expect(rows.count == DenCommand.allCases.count)
    }

    @Test func configTextParsesBackToTheSameTrigger() throws {
        for command in DenCommand.allCases {
            guard let text = command.defaultShortcut else { continue }
            let trigger = try Trigger.parse(text).get()
            #expect(try Trigger.parse(trigger.configText).get() == trigger, "\(command.rawValue): \(trigger.configText)")
        }
    }
}

@Suite struct ConfigManualTests {
    @Test func everyTopicRendersAndListsEveryCommand() throws {
        for topic in ConfigManual.topics { #expect(ConfigManual.text(topic: topic.name) != nil) }
        let full = try #require(ConfigManual.text(topic: nil))
        for command in DenCommand.allCases { #expect(full.contains(command.rawValue)) }
        #expect(ConfigManual.text(topic: "nonsense") == nil)
    }
}

@Suite struct AgentGuideTests {
    @Test func everyCommandTheGuideUsesExists() {
        let words = AgentGuide.markdown.split(whereSeparator: \.isWhitespace)
        let used = zip(words, words.dropFirst()).compactMap { $0 == "den" ? String($1) : nil }.filter { $0.first?.isLetter == true }
        #expect(!used.isEmpty)
        for name in used { #expect(CLICommands.all.contains { $0.names.contains(name) }, "guide uses `den \(name)`") }
    }

    @Test func installWritesBothSkillsAndIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "den-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AgentGuide.install(home: home).map(\.outcome) == [.written, .written])
        let file = home.appending(path: ".claude/skills/den/SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: den\ndescription: "))
        #expect(AgentGuide.install(home: home).map(\.outcome) == [.unchanged, .unchanged])
        // An older skill Den wrote is replaced.
        try (AgentGuide.marker + "\nold").write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentGuide.install(home: home).map(\.outcome) == [.unchanged, .written])
    }

    @Test func installLeavesSomeoneElsesSkillAlone() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "den-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: ".agents/skills/den/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "mine".write(to: file, atomically: true, encoding: .utf8)
        #expect(AgentGuide.install(home: home).map(\.outcome) == [.occupied, .written])
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine")
    }

    @Test func captureTrimDropsTrailingSpaceAndBlankEdges() {
        #expect(CLICommands.trimmed("\n  \nfoo   \n  bar\t\n\n   \n") == "foo\n  bar")
        #expect(CLICommands.trimmed("") == "")
        #expect(CLICommands.trimmed("a\n\nb") == "a\n\nb")
    }
}
