import Testing
@testable import DenApp

@Suite struct FuzzyTests {
    private let palette = [
        "New Tab", "Close Tab", "Change Theme…", "Change Interface Style", "Change Default Shell",
        "Show Sidebar", "Hide Pane Headers", "Automatic Contrast Correction", "Peek at Tabs",
        "Show All Sessions", "Switch to Horizontal Tabs", "Rename Session…", "Split Right", "Split Down",
        "Import Theme File…", "Migrate Theme from Ghostty Config", "Increase Font Size", "Activity Mode",
    ]

    private func top(_ query: String) -> String? { Fuzzy.filter(palette, query: query, key: { $0 }).first }

    @Test func wordPrefixBeatsScatteredLetters() {
        #expect(top("hori") == "Switch to Horizontal Tabs")
        #expect(top("theme") == "Change Theme…")
        #expect(top("split")?.hasPrefix("Split") == true)
        #expect(top("act") == "Activity Mode")
    }

    @Test func titlePrefixBeatsLaterWord() {
        #expect(top("show") == "Show Sidebar")
        #expect(top("new") == "New Tab")
    }

    @Test func initialsFindTheirCommand() {
        #expect(top("sht") == "Switch to Horizontal Tabs" || top("sht") == "Show All Sessions" || top("sht") == "Show Sidebar")
        #expect(top("cds") == "Change Default Shell")
    }

    @Test func missesAreDropped() {
        #expect(Fuzzy.filter(palette, query: "zzz", key: { $0 }).isEmpty)
    }

    @Test func emptyQueryKeepsOrder() {
        #expect(Fuzzy.filter(palette, query: "  ", key: { $0 }) == palette)
    }

    @Test func hitsPointAtTheMatchedWord() {
        #expect(Fuzzy.match("hori", in: "Switch to Horizontal Tabs") == [10, 11, 12, 13])
    }
}
