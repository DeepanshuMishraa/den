import Foundation
import Testing
@testable import DenVT

@Suite struct SearchTests {
    private func terminal(_ text: String, cols: UInt16 = 20, rows: UInt16 = 4) throws -> VTTerminal {
        let t = try VTTerminal(cols: cols, rows: rows)
        t.write(Data(text.utf8))
        return t
    }

    /// The text each match covers, read back through the selection.
    private func texts(_ t: VTTerminal, _ matches: [TextMatch]) -> [String?] {
        matches.map { m in
            t.selection = TextSelection(start: m.start, end: m.end)
            defer { t.selection = nil }
            return t.selectedText()
        }
    }

    @Test func findsEveryOccurrenceInReadingOrder() throws {
        let t = try terminal("one two one\r\nthree one")
        let matches = t.search("one")
        #expect(matches.count == 3)
        #expect(matches.map(\.start.col) == [0, 8, 6])
        #expect(texts(t, matches) == ["one", "one", "one"])
    }

    @Test func ignoresCaseUnlessTheQueryHasACapital() throws {
        let t = try terminal("Error error ERROR")
        #expect(t.search("error").count == 3)
        #expect(t.search("Error").count == 1)
    }

    @Test func matchesAcrossASoftWrap() throws {
        // 10 columns: "abcdefghij" fills row 0 and "klm" wraps onto row 1.
        let t = try terminal("abcdefghijklm", cols: 10)
        let matches = t.search("ijkl")
        #expect(matches.count == 1)
        #expect(texts(t, matches) == ["ijkl"])
    }

    @Test func doesNotMatchAcrossAHardLineBreak() throws {
        let t = try terminal("abc\r\ndef")
        #expect(t.search("cd").isEmpty)
    }

    @Test func searchesScrollback() throws {
        let t = try terminal((1 ... 20).map { "line \($0)" }.joined(separator: "\r\n"), rows: 4)
        #expect(texts(t, t.search("line 2")) == ["line 2", "line 2"]) // "line 2" and "line 20"
        #expect(t.search("line 1").count == 11)
    }

    @Test func emptyQueryFindsNothing() throws {
        #expect(try terminal("anything").search("").isEmpty)
    }

    @Test func revealScrollsAMatchInScrollbackIntoView() throws {
        let t = try terminal((1 ... 40).map { "line \($0)" }.joined(separator: "\r\n"), rows: 4)
        let match = try #require(t.search("line 3").first)
        #expect(t.scrollbar.offset == t.scrollbar.total - t.scrollbar.length)
        t.reveal(match)
        let bar = t.scrollbar
        let top = Int64(t.state.scrolled_into_history) - Int64(t.state.history_size) + Int64(bar.offset)
        #expect((top ..< top + Int64(bar.length)).contains(match.start.row))
    }

    @Test func revealLeavesAVisibleMatchAlone() throws {
        let t = try terminal((1 ... 40).map { "line \($0)" }.joined(separator: "\r\n"), rows: 4)
        let before = t.scrollbar
        t.reveal(try #require(t.search("line 40").first))
        #expect(t.scrollbar == before)
    }

    @Test func renderStateMarksMatchesAndTheCurrentOne() throws {
        let t = try terminal("foo bar foo")
        let matches = t.search("foo")
        t.searchHighlights = SearchHighlights(matches: matches, current: 1)
        let state = try VTRenderState()
        try state.update(from: t)
        var found: [Int: CellView.Found] = [:]
        state.forEachCell { if $0.row == 0 { found[$0.col] = $0.found } }
        #expect(found[0] == .match && found[2] == .match)
        #expect(found[3] == nil) // a blank outside any match is never visited
        #expect(found[8] == .current && found[10] == .current)
    }
}
