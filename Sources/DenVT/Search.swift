import Foundation
import CTermyEngine

/// Text a search found, in stable rows (see `GridPoint`), so it stays on
/// its content while output scrolls history.
public struct TextMatch: Equatable {
    let start: GridPoint
    /// Inclusive; the right half of a wide glyph that ends the match.
    let end: GridPoint
}

/// Search results drawn over a terminal: every match, and the one the
/// find bar is on.
public struct SearchHighlights: Equatable {
    public var matches: [TextMatch]
    public var current: Int?

    public init(matches: [TextMatch], current: Int?) {
        self.matches = matches
        self.current = current
    }
}

extension VTTerminal {
    /// Rows read from libtermy per call while searching.
    private static let searchChunk: Int64 = 512

    /// Every occurrence of `query` in scrollback and on screen, top to
    /// bottom, found across soft wraps. Smart case: a query with a capital
    /// matches case exactly, otherwise case is ignored.
    public func search(_ query: String) -> [TextMatch] {
        let caseSensitive = query.unicodeScalars.contains { $0.properties.isUppercase }
        let pattern = query.unicodeScalars.map { caseSensitive ? $0 : Self.folded($0) }
        guard !pattern.isEmpty else { return [] }

        let s = state
        let history = Int64(s.history_size), rows = Int64(s.rows)
        // Buffer line L (negative in scrollback) is stable row base + L.
        let base = Int64(s.scrolled_into_history)
        var matches: [TextMatch] = []
        // The logical line being collected: rows joined across soft wraps,
        // with the cells each scalar came from.
        var scalars: [Unicode.Scalar] = []
        var places: [(row: Int64, first: Int, last: Int)] = []

        func endLine() {
            var i = 0
            while i + pattern.count <= scalars.count {
                if pattern.indices.allSatisfy({ pattern[$0] == scalars[i + $0] }) {
                    let first = places[i], last = places[i + pattern.count - 1]
                    matches.append(TextMatch(start: GridPoint(row: first.row, col: first.first),
                                             end: GridPoint(row: last.row, col: last.last)))
                    i += pattern.count
                } else {
                    i += 1
                }
            }
            scalars.removeAll(keepingCapacity: true)
            places.removeAll(keepingCapacity: true)
        }

        var line = -history
        while line < rows {
            var frame = TermyEngineFrame()
            guard termy_engine_read_lines(handle, line, UInt32(min(Self.searchChunk, rows - line)), &frame) == TERMY_ENGINE_OK,
                  frame.rows > 0, frame.cols > 0 else { break }
            let cols = Int(frame.cols), count = Int(frame.rows)
            let cells = UnsafeBufferPointer(start: frame.cells_ptr, count: frame.cells_len)
            let graphemes = UnsafeBufferPointer(start: frame.graphemes_ptr, count: frame.graphemes_len)
            guard cells.count >= count * cols else { break }
            for r in 0 ..< count {
                let row = base + line + Int64(r)
                for c in 0 ..< cols {
                    let cell = cells[r * cols + c]
                    let width = Int32(cell.width)
                    if width == TERMY_ENGINE_CELL_SPACER_TAIL || width == TERMY_ENGINE_CELL_SPACER_HEAD { continue }
                    let last = width == TERMY_ENGINE_CELL_WIDE ? min(c + 1, cols - 1) : c
                    // Concealed text reads as a space, as it does on screen.
                    let shown = cell.flags & UInt16(TERMY_ENGINE_CELL_INVISIBLE) == 0
                    func add(_ value: UInt32) {
                        let scalar = Unicode.Scalar(value) ?? " "
                        scalars.append(caseSensitive ? scalar : Self.folded(scalar))
                        places.append((row, c, last))
                    }
                    add(shown ? cell.codepoint : 0x20)
                    if shown, cell.grapheme_len > 0 {
                        let start = Int(cell.grapheme_start)
                        for value in graphemes[start ..< start + Int(cell.grapheme_len)] { add(value) }
                    }
                }
                if cells[r * cols + cols - 1].flags & UInt16(TERMY_ENGINE_CELL_WRAPPED) == 0 { endLine() }
            }
            line += Int64(count)
        }
        endLine()
        return matches
    }

    /// Lowercase for case-insensitive matching, one scalar for one.
    private static func folded(_ s: Unicode.Scalar) -> Unicode.Scalar {
        if s.isASCII { return ("A" ... "Z").contains(s) ? Unicode.Scalar(s.value + 32) ?? s : s }
        let lower = s.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first ?? s : s
    }

    /// Scrolls the viewport so `match` shows, centered, unless it already
    /// does. A match whose rows history evicted leaves the viewport alone.
    public func reveal(_ match: TextMatch) {
        let s = state
        let base = Int64(s.scrolled_into_history), rows = Int64(s.rows)
        let top = base - Int64(s.display_offset)
        let oldest = base - Int64(s.history_size)
        guard match.end.row >= oldest, match.start.row < top || match.end.row >= top + rows else { return }
        // Scrollbar offset k puts stable row oldest + k at the top.
        scrollViewport(toRow: UInt64(max(match.start.row - oldest - rows / 2, 0)))
    }
}
