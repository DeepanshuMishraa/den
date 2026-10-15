import Foundation
import Testing
@testable import DenVT

@Suite struct SelectionTests {
    private let ms: UInt64 = 1_000_000

    private func terminal(_ text: String, cols: UInt16 = 20, rows: UInt16 = 4) throws -> VTTerminal {
        let t = try VTTerminal(cols: cols, rows: rows)
        t.write(Data(text.utf8))
        return t
    }

    private func click(_ g: SelectionGesture, _ t: VTTerminal, col: Int, row: Int, at time: UInt64) {
        g.handle(.press, col: col, row: row, x: 0, y: 0, timeNs: time, columns: Int(t.cols), cellWidth: 8, screenHeight: 64, terminal: t)
        g.handle(.release, col: col, row: row, x: 0, y: 0, timeNs: time, columns: Int(t.cols), cellWidth: 8, screenHeight: 64, terminal: t)
    }

    private func drag(_ g: SelectionGesture, _ t: VTTerminal, from: (Int, Int), to: (Int, Int)) {
        g.handle(.press, col: from.0, row: from.1, x: 0, y: 0, timeNs: 0, columns: Int(t.cols), cellWidth: 8, screenHeight: 64, terminal: t)
        g.handle(.drag, col: to.0, row: to.1, x: 0, y: 0, timeNs: 0, columns: Int(t.cols), cellWidth: 8, screenHeight: 64, terminal: t)
        g.handle(.release, col: to.0, row: to.1, x: 0, y: 0, timeNs: 0, columns: Int(t.cols), cellWidth: 8, screenHeight: 64, terminal: t)
    }

    @Test func dragSelectsAcrossRowsInReadingOrder() throws {
        let t = try terminal("hello world\r\nsecond line")
        let g = try SelectionGesture()
        // Dragging backwards selects the same text as forwards.
        drag(g, t, from: (5, 1), to: (6, 0))
        #expect(t.selectedText() == "world\nsecond")
    }

    @Test func singleClickSelectsNothing() throws {
        let t = try terminal("hello world")
        let g = try SelectionGesture()
        click(g, t, col: 2, row: 0, at: 0)
        #expect(t.selectedText() == nil)
    }

    @Test func doubleClickSelectsWordAndTripleClickTheLine() throws {
        let t = try terminal("echo some-words here")
        let g = try SelectionGesture()
        click(g, t, col: 1, row: 0, at: 0)
        click(g, t, col: 1, row: 0, at: 100 * ms)
        #expect(t.selectedText() == "echo")
        g.handle(.press, col: 1, row: 0, x: 0, y: 0, timeNs: 200 * ms, columns: 20, cellWidth: 8, screenHeight: 64, terminal: t)
        #expect(t.selectedText() == "echo some-words here")
    }

    @Test func slowSecondClickStartsOver() throws {
        let t = try terminal("echo here")
        let g = try SelectionGesture()
        click(g, t, col: 1, row: 0, at: 0)
        click(g, t, col: 1, row: 0, at: 900 * ms)
        #expect(t.selectedText() == nil)
    }

    /// A triple-click still works after copy-on-select cleared the
    /// double-click's word.
    @Test func tripleClickSurvivesResetAfterDoubleClick() throws {
        let t = try terminal("echo some words")
        let g = try SelectionGesture()
        click(g, t, col: 1, row: 0, at: 0)
        click(g, t, col: 1, row: 0, at: 100 * ms)
        t.clearSelection()
        g.reset(t)
        click(g, t, col: 1, row: 0, at: 200 * ms)
        #expect(t.selectedText() == "echo some words")
    }

    @Test func selectionStaysOnItsTextWhileOutputScrolls() throws {
        let t = try terminal("alpha\r\nbeta\r\ngamma\r\ndelta")
        let g = try SelectionGesture()
        drag(g, t, from: (0, 1), to: (3, 1))
        #expect(t.selectedText() == "beta")
        t.write(Data("\r\nmore\r\nlines\r\nhere".utf8))
        #expect(t.selectedText() == "beta")
    }

    @Test func renderStateMarksSelectedCells() throws {
        let t = try terminal("hello world")
        let g = try SelectionGesture()
        drag(g, t, from: (0, 0), to: (4, 0))
        let state = try VTRenderState()
        try state.update(from: t)
        var selected: [Int] = []
        state.forEachCell { if $0.selected { selected.append($0.col) } }
        #expect(selected == [0, 1, 2, 3, 4])
    }
}
