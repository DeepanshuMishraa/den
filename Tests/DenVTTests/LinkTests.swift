import Foundation
import Testing
@testable import DenVT

@Suite struct LinkTests {
    private func terminal(_ text: String, cols: UInt16 = 60, rows: UInt16 = 4) throws -> VTTerminal {
        let t = try VTTerminal(cols: cols, rows: rows)
        t.write(Data(text.utf8))
        return t
    }

    private func urls(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return VTTerminal.urlRanges(in: scalars).map { r in
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[r])
            return String(view)
        }
    }

    @Test func findsAPlainURLUnderTheCell() throws {
        let t = try terminal("The PR is open: https://github.com/DeepanshuMishraa/den/pull/1", cols: 80)
        let link = try #require(t.link(atCol: 20, row: 0))
        #expect(link.target == "https://github.com/DeepanshuMishraa/den/pull/1")
        // 16 columns of "The PR is open: ", then 46 of URL.
        #expect(link.spans == [.init(row: 0, columns: 16 ... 61)])
        #expect(link.url?.host == "github.com")
        #expect(t.link(atCol: 3, row: 0) == nil)
    }

    @Test func urlWrappedOverRowsIsOneLink() throws {
        let t = try terminal("see https://example.com/a/very/long/path ok", cols: 20)
        let link = try #require(t.link(atCol: 2, row: 1))
        #expect(link.target == "https://example.com/a/very/long/path")
        #expect(link.spans.map(\.row) == [0, 1])
    }

    @Test func trailingPunctuationAndUnmatchedBracketsStayOut() {
        #expect(urls("go to https://example.com/x.") == ["https://example.com/x"])
        #expect(urls("(see https://example.com/y)") == ["https://example.com/y"])
        #expect(urls("https://en.wikipedia.org/wiki/Foo_(bar)") == ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        #expect(urls("\"http://a.b/c\", mailto:me@x.y") == ["http://a.b/c", "mailto:me@x.y"])
    }

    @Test func needsAKnownSchemeAtAWordStart() {
        #expect(urls("xhttps://nope.com").isEmpty)
        #expect(urls("https://").isEmpty)
        #expect(urls("javascript:alert(1)").isEmpty)
        #expect(urls("HTTPS://Example.com") == ["HTTPS://Example.com"])
    }

    @Test func stopsAtTUIBorders() {
        #expect(urls("│ https://example.com│") == ["https://example.com"])
    }

    @Test func osc8HyperlinksWinOverText() throws {
        let t = try terminal("\u{1b}]8;;https://den.example/docs\u{1b}\\docs here\u{1b}]8;;\u{1b}\\ plain")
        let link = try #require(t.link(atCol: 1, row: 0))
        #expect(link.target == "https://den.example/docs")
        #expect(link.spans == [.init(row: 0, columns: 0 ... 8)])
        #expect(t.link(atCol: 11, row: 0) == nil)
    }

    /// OSC 8 can name any scheme; only web and mail links open.
    @Test func onlySafeSchemesOpen() throws {
        let t = try terminal("\u{1b}]8;;file:///etc/passwd\u{1b}\\x\u{1b}]8;;\u{1b}\\")
        let link = try #require(t.link(atCol: 0, row: 0))
        #expect(link.url == nil)
    }
}
