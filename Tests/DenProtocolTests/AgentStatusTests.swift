import Testing
@testable import DenProtocol

@Suite struct AgentStatusTests {
    /// Feeds one tick per element; returns every phase the inference reported.
    private func run(_ ticks: [(output: Bool, title: String?)]) -> [ProgramPhase] {
        var inference = AgentStatusInference()
        return ticks.compactMap { inference.tick(output: $0.output, title: $0.title) }
    }

    private func quiet(_ n: Int, title: String? = nil) -> [(output: Bool, title: String?)] {
        Array(repeating: (false, title), count: n)
    }

    private func busy(_ n: Int, title: String? = nil) -> [(output: Bool, title: String?)] {
        Array(repeating: (true, title), count: n)
    }

    @Test func startsIdle() {
        #expect(run(quiet(3)) == [.idle])
    }

    @Test func sustainedOutputIsWorkThenQuietIsDone() {
        #expect(run(quiet(1) + busy(3) + quiet(4)) == [.idle, .working(progress: nil), .done])
    }

    /// A redraw (resize, focus) is one burst, not work.
    @Test func singleBurstIsNotWork() {
        #expect(run(quiet(1) + busy(1) + quiet(5)) == [.idle])
    }

    /// Streaming output with a short pause stays working.
    @Test func briefPauseStaysWorking() {
        #expect(run(busy(2) + quiet(2) + busy(2) + quiet(3)) == [.idle, .working(progress: nil), .done])
    }

    /// Codex puts a braille spinner in its title while it works.
    @Test func spinnerTitleIsWork() {
        #expect(run([(false, "⠹ work"), (false, "⠸ work"), (false, "work")]) == [.working(progress: nil), .done])
    }

    /// Gemini titles: "✦ …" working, "✋ Action Required", "◇ Ready".
    @Test func geminiTitles() {
        let phases = run([(false, "◇  Ready (work)"), (false, "✦  Reading files"), (false, "✋  Action Required (work)"), (false, "◇  Ready (work)")])
        #expect(phases == [.idle, .working(progress: nil), .blocked(nil, progress: nil), .idle])
    }

    @Test func readyTitleEndsWorkAsDone() {
        #expect(run([(true, "✦  Thinking"), (true, "✦  Thinking"), (false, "◇  Ready")]) == [.working(progress: nil), .done])
    }

    @Test func knowsMajorAgents() {
        for name in ["claude", "codex", "gemini", "opencode", "grok", "cursor-agent", "copilot", "amp", "aider", "qwen", "crush", "droid", "goose"] {
            #expect(AgentStatusInference.isAgent(name), "\(name)")
        }
        #expect(!AgentStatusInference.isAgent("fish"))
        #expect(!AgentStatusInference.isAgent("nvim"))
    }
}
