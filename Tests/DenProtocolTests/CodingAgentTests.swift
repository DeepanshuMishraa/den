import Testing
@testable import DenProtocol

@Suite struct CodingAgentTests {
    @Test func everyPatternCompiles() {
        #expect(CodingAgent.allPatternsCompile)
    }

    @Test func namesAndAliases() {
        #expect(CodingAgent(process: "claude") == .claude)
        #expect(CodingAgent(process: "Claude-Code") == .claude)
        #expect(CodingAgent(process: "cursor-agent") == .cursor)
        #expect(CodingAgent(process: "agy") == .antigravity)
        #expect(CodingAgent(process: "ghcs") == .copilot)
        #expect(CodingAgent(process: "kiro-cli") == .kiro)
        #expect(CodingAgent(process: "aider") == .aider)
        #expect(CodingAgent(process: "zsh") == nil)
        #expect(!CodingAgent.aider.readsScreen)
        #expect(CodingAgent.codex.readsScreen)
    }

    // MARK: Regions

    @Test func bottomLinesSkipBlankRows() {
        let text = ScreenRegion.bottomLines(2).text(screen: "a\nb\n\nc\n\n", title: "")
        #expect(text == "b\n\nc\n\n")
    }

    @Test func promptBoxIsBetweenTheLastTwoRules() {
        let screen = "old\n────\nanswer\n────────\n❯ draft\n────────\n  ? for shortcuts"
        #expect(ScreenRegion.promptBox.text(screen: screen, title: "") == "❯ draft")
        #expect(ScreenRegion.afterLastRule.text(screen: screen, title: "") == "  ? for shortcuts")
    }

    @Test func labelledRuleCountsOnlyWhenLong() {
        #expect(ScreenRegion.isHorizontalRule("  ─── Edit file"))
        #expect(!ScreenRegion.isHorizontalRule("─ item"))
        #expect(ScreenRegion.isHorizontalRule("─"))
    }

    // MARK: Screens

    @Test func claudePermissionPromptIsBlocked() {
        let screen = """
        ⏺ Bash(rm -rf build)
        ────────────────────────────────
         Bash command
           rm -rf build
         Do you want to proceed?
         ❯ 1. Yes
           2. No, and tell Claude what to do differently (esc)
        """
        #expect(CodingAgent.claude.signal(screen: screen, title: "✳ Claude Code") == .blocked)
    }

    @Test func claudeTitleSpinnerBeatsTheIdlePromptBox() {
        let screen = "⏺ Reading files\n────────\n❯ \n────────\n  ? for shortcuts"
        #expect(CodingAgent.claude.signal(screen: screen, title: "⠂ Reading") == .working)
        #expect(CodingAgent.claude.signal(screen: screen, title: "✳ Claude Code") == .idle)
    }

    @Test func claudeTranscriptViewerKeepsState() {
        let screen = "lots of history\nShowing detailed transcript · ctrl+o to toggle"
        #expect(CodingAgent.claude.signal(screen: screen, title: nil) == .viewer)
    }

    @Test func codexStates() {
        #expect(CodingAgent.codex.signal(screen: "", title: "⠋ repo") == .working)
        #expect(CodingAgent.codex.signal(screen: "", title: "✋ Action Required") == .blocked)
        #expect(CodingAgent.codex.signal(screen: "", title: "repo") == .idle)
        let approval = "› fix the tests\n\n  Allow command?\n  cargo test\n  Press enter to confirm or esc to cancel"
        #expect(CodingAgent.codex.signal(screen: approval, title: nil) == .blocked)
    }

    @Test func geminiApprovalThenWork() {
        #expect(CodingAgent.gemini.signal(screen: "│ Allow execution of: 'ls'?\n│ ● 1. Yes, allow once", title: nil) == .blocked)
        #expect(CodingAgent.gemini.signal(screen: "⠏ Thinking… (esc to cancel, 3s)", title: nil) == .working)
        #expect(CodingAgent.gemini.signal(screen: "> Type your message", title: nil) == nil)
    }

    @Test func opencodePermission() {
        #expect(CodingAgent.opencode.signal(screen: "△ Permission required\n  $ npm install", title: nil) == .blocked)
        #expect(CodingAgent.opencode.signal(screen: "■■■■⬝⬝⬝⬝  esc interrupt", title: nil) == .working)
    }

    @Test func droidSelectionMenu() {
        let screen = "Execute command?\n> Yes, allow\n  No, cancel\nUse ↑↓ to navigate, Enter to select, Esc to cancel"
        #expect(CodingAgent.droid.signal(screen: screen, title: nil) == .blocked)
    }

    @Test func agentsWithoutRulesSayNothing() {
        #expect(CodingAgent.aider.signal(screen: "Do you want to proceed? yes", title: nil) == nil)
    }
}
