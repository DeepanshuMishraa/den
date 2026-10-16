import Foundation
import CTermyEngine

public struct Scrollbar: Equatable, Sendable {
    /// Total rows including scrollback.
    public var total: UInt64
    /// First visible row.
    public var offset: UInt64
    /// Visible rows.
    public var length: UInt64
}

/// A cell in rows numbered from the first line output ever scrolled, so a
/// point stays on its content while new output scrolls history.
struct GridPoint: Comparable {
    var row: Int64
    var col: Int

    static func < (a: GridPoint, b: GridPoint) -> Bool { (a.row, a.col) < (b.row, b.col) }
}

/// Selected text from `start` to `end`, both inclusive, in reading order.
struct TextSelection: Equatable {
    var start: GridPoint
    var end: GridPoint
}

extension VTTerminal {
    public var scrollbar: Scrollbar {
        var s = TermyEngineScrollbar()
        _ = termy_engine_scrollbar(handle, &s)
        return Scrollbar(total: s.total, offset: s.offset, length: s.len)
    }

    public func scrollViewport(toRow row: UInt64) {
        var changed = false
        _ = termy_engine_scroll_viewport(handle, UInt32(TERMY_ENGINE_SCROLL_OFFSET), Int64(clamping: row), &changed)
    }

    public func clearSelection() {
        selection = nil
    }

    /// Plain text of the active selection, nil when nothing is selected.
    public func selectedText() -> String? {
        guard let selection else { return nil }
        let s = state
        let first = Int64(s.scrolled_into_history)
        let oldest = -Int64(s.history_size)
        var range = TermyEngineTextRange(
            start_line: selection.start.row - first, start_col: UInt32(clamping: selection.start.col),
            end_line: selection.end.row - first, end_col: UInt32(clamping: selection.end.col), rectangular: false
        )
        // Evicted history is gone; keep what remains.
        guard range.end_line >= oldest else { return nil }
        if range.start_line < oldest {
            range.start_line = oldest
            range.start_col = 0
        }
        let options = UInt32(TERMY_ENGINE_TEXT_UNWRAP) | UInt32(TERMY_ENGINE_TEXT_TRIM)
        guard let bytes = try? takeBytes("read_text", { termy_engine_read_text(handle, &range, UInt32(TERMY_ENGINE_FORMAT_PLAIN), options, $0) }),
              !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The stable point under a viewport cell.
    func gridPoint(viewportCol col: Int, row: Int) -> GridPoint {
        let s = state
        let line = Int64(row) - Int64(s.display_offset)
        return GridPoint(row: Int64(s.scrolled_into_history) + line, col: col)
    }

    /// The word (or run of one symbol) at `point`, across soft wraps.
    func word(at point: GridPoint) -> TextSelection {
        textUnit(at: point) { line, range in termy_engine_select_word(handle, line, UInt32(clamping: point.col), range) }
    }

    /// The logical line at `point`, across soft wraps.
    func line(at point: GridPoint) -> TextSelection {
        textUnit(at: point) { line, range in termy_engine_select_line(handle, line, range) }
    }

    private func textUnit(at point: GridPoint, _ select: (Int64, UnsafeMutablePointer<TermyEngineTextRange>) -> TermyEngineStatus) -> TextSelection {
        let first = Int64(state.scrolled_into_history)
        var range = TermyEngineTextRange()
        guard select(point.row - first, &range) == TERMY_ENGINE_OK else { return TextSelection(start: point, end: point) }
        return TextSelection(start: GridPoint(row: range.start_line + first, col: Int(range.start_col)),
                             end: GridPoint(row: range.end_line + first, col: Int(range.end_col)))
    }
}

/// Click/drag/double/triple-click selection: a drag selects cells, a
/// double-click words and a triple-click lines, and dragging after either
/// extends by that unit.
public final class SelectionGesture {
    private enum Unit { case cell, word, line }

    /// Clicks closer together than this, on the same cell, count as one gesture.
    static let multiClickNs: UInt64 = 500_000_000

    private var unit = Unit.cell
    /// What the press selected; a drag extends from it.
    private var anchor: TextSelection?
    private var lastPress: (time: UInt64, point: GridPoint)?
    private var clicks = 0
    /// The terminal the gesture's state is about; a replaced replica starts
    /// over. Weak, since a freed terminal's address can be reused.
    private weak var current: VTTerminal?

    public init() throws(VTError) {}

    public enum Phase { case press, drag, release }

    /// Feeds one mouse event. `col`/`row` are viewport cells; `x`/`y` are
    /// pixels relative to the grid. Returns true when the selection changed.
    @discardableResult
    public func handle(_ phase: Phase, col: Int, row: Int, x: Double, y: Double, timeNs: UInt64,
                       columns: Int, cellWidth: Int, screenHeight: Int, terminal: VTTerminal) -> Bool {
        if current !== terminal {
            current = terminal
            lastPress = nil
            clicks = 0
            anchor = nil
        }
        let point = terminal.gridPoint(viewportCol: max(col, 0), row: max(row, 0))
        let before = terminal.selection
        switch phase {
        case .press:
            if let last = lastPress, last.point == point, timeNs >= last.time, timeNs - last.time <= Self.multiClickNs {
                clicks = clicks % 3 + 1
            } else {
                clicks = 1
            }
            lastPress = (timeNs, point)
            switch clicks {
            case 2:
                unit = .word
                anchor = terminal.word(at: point)
            case 3:
                unit = .line
                anchor = terminal.line(at: point)
            default:
                unit = .cell
                anchor = TextSelection(start: point, end: point)
            }
            // A single click selects nothing until it drags.
            terminal.selection = unit == .cell ? nil : anchor
        case .drag:
            guard let anchor else { return false }
            // A drag off the pressed cell ends the multi-click: pressing
            // there again starts a new selection.
            if let last = lastPress, last.point != point { lastPress = nil }
            let head = switch unit {
            case .cell: TextSelection(start: point, end: point)
            case .word: terminal.word(at: point)
            case .line: terminal.line(at: point)
            }
            terminal.selection = unit == .cell && head == anchor
                ? nil
                : TextSelection(start: min(anchor.start, head.start), end: max(anchor.end, head.end))
        case .release:
            anchor = nil
        }
        return terminal.selection != before
    }

    /// Ends the current drag. Click timing is kept, so a triple-click still
    /// works after the double-click's selection was copied and cleared.
    public func reset(_ terminal: VTTerminal) {
        anchor = nil
    }
}
