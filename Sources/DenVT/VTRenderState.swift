import Foundation
import CTermyEngine

public enum CellWidth: Sendable {
    case narrow, wide, spacerTail, spacerHead
}

public enum UnderlineStyle: Sendable {
    case none, single, double, curly, dotted, dashed
}

public struct CellStyle: Sendable {
    public var bold = false
    public var italic = false
    public var faint = false
    public var inverse = false
    public var invisible = false
    public var strikethrough = false
    public var underline = UnderlineStyle.none
    public var underlineColor: RGB?
}

/// One visible cell, valid only for the duration of the visitor call.
public struct CellView {
    public var row: Int
    public var col: Int
    /// Base codepoint followed by combining codepoints. Empty for blank cells.
    public var codepoints: UnsafeBufferPointer<UInt32>
    public var width: CellWidth
    public var style: CellStyle
    public var foreground: RGB?
    public var background: RGB?
    public var selected: Bool
}

public enum CursorShape: Sendable {
    case block, bar, underline, hollowBlock
}

public struct CursorState: Sendable {
    public var x: Int
    public var y: Int
    public var shape: CursorShape
    public var blinking: Bool
    public var wideTail: Bool
}

public struct FrameColors: Sendable {
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB?
    public var palette: [RGB]
}

/// The viewport as libtermy last reported it, kept current by applying its
/// damage. Lives on the terminal so every view of it sees the same cells.
final class FrameCache {
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var cells: [TermyEngineCell] = []
    /// Scalars after the first of each multi-scalar grapheme, by cell index.
    private(set) var clusters: [Int: [UInt32]] = [:]
    private(set) var cursor = TermyEngineCursor()
    /// Rows the viewport is scrolled back.
    private(set) var displayOffset: UInt64 = 0
    var colors = FrameColors(foreground: RGB(0, 0, 0), background: RGB(0, 0, 0), cursor: nil, palette: [])
    /// The palette revision `colors` was read at; nil forces a reread.
    var colorsRevision: UInt64?

    func refresh(_ handle: OpaquePointer) throws(VTError) {
        var frame = TermyEngineFrame()
        try check(termy_engine_frame(handle, false, &frame), "frame")
        cursor = frame.cursor
        displayOffset = frame.display_offset
        let source = UnsafeBufferPointer(start: frame.cells_ptr, count: frame.cells_len)
        let graphemes = UnsafeBufferPointer(start: frame.graphemes_ptr, count: frame.graphemes_len)
        func cluster(_ cell: TermyEngineCell) -> [UInt32] {
            let start = Int(cell.grapheme_start)
            return Array(graphemes[start ..< start + Int(cell.grapheme_len)])
        }

        if frame.damage == UInt32(TERMY_ENGINE_DAMAGE_FULL) {
            cols = Int(frame.cols)
            rows = Int(frame.rows)
            cells = Array(source)
            clusters.removeAll(keepingCapacity: true)
            for (i, cell) in source.enumerated() where cell.grapheme_len > 0 { clusters[i] = cluster(cell) }
        } else {
            var next = 0
            cells.withUnsafeMutableBufferPointer { grid in
                for span in UnsafeBufferPointer(start: frame.spans_ptr, count: frame.spans_len) {
                    let base = Int(span.row) * cols
                    for col in Int(span.start_col) ..< Int(span.end_col) {
                        let cell = source[next]
                        next += 1
                        grid[base + col] = cell
                        if cell.grapheme_len > 0 {
                            clusters[base + col] = cluster(cell)
                        } else if !clusters.isEmpty {
                            clusters[base + col] = nil
                        }
                    }
                }
            }
        }

        if colorsRevision != frame.palette_revision {
            var c = TermyEngineColors()
            try check(termy_engine_effective_colors(handle, &c), "effective_colors")
            let palette = withUnsafeBytes(of: c.palette) { $0.bindMemory(to: UInt32.self).map(RGB.init(packed:)) }
            colors = FrameColors(foreground: RGB(packed: c.foreground), background: RGB(packed: c.background),
                                 cursor: c.cursor_set ? RGB(packed: c.cursor) : nil, palette: palette)
            colorsRevision = frame.palette_revision
        }
    }
}

/// What to draw for one frame, refreshed from a `VTTerminal`.
public final class VTRenderState {
    private var terminal: VTTerminal?
    /// The selection in viewport rows, for this frame.
    private var selected: (start: (row: Int, col: Int), end: (row: Int, col: Int))?
    private var scratch = [UInt32](repeating: 0, count: 32)

    public init() throws(VTError) {}

    public func update(from terminal: VTTerminal) throws(VTError) {
        try terminal.frame.refresh(terminal.handle)
        self.terminal = terminal
        selected = terminal.selection.flatMap { selection in
            // Viewport row v shows stable row firstRow + v.
            let firstRow = Int64(terminal.state.scrolled_into_history) - Int64(terminal.frame.displayOffset)
            let rows = Int64(terminal.frame.rows)
            let start = selection.start.row - firstRow, end = selection.end.row - firstRow
            guard end >= 0, start < rows else { return nil }
            return (start < 0 ? (0, 0) : (Int(start), selection.start.col),
                    end >= rows ? (Int(rows - 1), Int.max) : (Int(end), selection.end.col))
        }
    }

    public var size: (cols: Int, rows: Int) {
        guard let frame = terminal?.frame else { return (0, 0) }
        return (frame.cols, frame.rows)
    }

    public var colors: FrameColors {
        terminal?.frame.colors ?? FrameColors(foreground: RGB(0, 0, 0), background: RGB(0, 0, 0), cursor: nil, palette: [])
    }

    /// Cursor position in viewport coordinates, nil when hidden or scrolled
    /// out of view.
    public var cursor: CursorState? {
        guard let c = terminal?.frame.cursor, c.visible, c.in_viewport else { return nil }
        let shape: CursorShape = switch Int32(c.shape) {
        case TERMY_ENGINE_CURSOR_BAR: .bar
        case TERMY_ENGINE_CURSOR_UNDERLINE: .underline
        default: .block
        }
        return CursorState(x: Int(c.col), y: Int(c.row), shape: shape, blinking: c.blinking, wideTail: c.on_wide_tail)
    }

    /// Visits every cell that has text, styling or a selection highlight.
    public func forEachCell(_ body: (CellView) -> Void) {
        guard let frame = terminal?.frame, frame.cells.count == frame.cols * frame.rows else { return }
        let palette = frame.colors.palette
        func resolve(_ raw: UInt32) -> RGB? {
            switch Int32(raw >> 24) {
            case TERMY_ENGINE_COLOR_INDEXED: palette.indices.contains(Int(raw & 0xFF)) ? palette[Int(raw & 0xFF)] : nil
            case TERMY_ENGINE_COLOR_RGB: RGB(packed: raw)
            default: nil
            }
        }
        let blank = UInt16(TERMY_ENGINE_CELL_BLANK)
        frame.cells.withUnsafeBufferPointer { cells in
            for row in 0 ..< frame.rows {
                for col in 0 ..< frame.cols {
                    let index = row * frame.cols + col
                    let cell = cells[index]
                    let selected = isSelected(row: row, col: col)
                    if cell.flags & blank != 0, !selected { continue }
                    let width: CellWidth = switch Int32(cell.width) {
                    case TERMY_ENGINE_CELL_WIDE: .wide
                    case TERMY_ENGINE_CELL_SPACER_TAIL: .spacerTail
                    case TERMY_ENGINE_CELL_SPACER_HEAD: .spacerHead
                    default: .narrow
                    }
                    let flags = UInt32(cell.flags)
                    var style = CellStyle()
                    style.bold = flags & TERMY_ENGINE_CELL_BOLD != 0
                    style.italic = flags & TERMY_ENGINE_CELL_ITALIC != 0
                    style.faint = flags & TERMY_ENGINE_CELL_FAINT != 0
                    style.inverse = flags & TERMY_ENGINE_CELL_INVERSE != 0
                    style.invisible = flags & TERMY_ENGINE_CELL_INVISIBLE != 0
                    style.strikethrough = flags & TERMY_ENGINE_CELL_STRIKETHROUGH != 0
                    style.underline = switch Int32(cell.underline) {
                    case TERMY_ENGINE_UNDERLINE_SINGLE: .single
                    case TERMY_ENGINE_UNDERLINE_DOUBLE: .double
                    case TERMY_ENGINE_UNDERLINE_CURLY: .curly
                    case TERMY_ENGINE_UNDERLINE_DOTTED: .dotted
                    case TERMY_ENGINE_UNDERLINE_DASHED: .dashed
                    default: .none
                    }
                    style.underlineColor = cell.underline_color == 0 ? nil : resolve(cell.underline_color)

                    // Blanks and spacers carry ' '; they count as having no text.
                    let extra = frame.clusters[index] ?? []
                    let hasText = width != .spacerTail && width != .spacerHead && (cell.codepoint != 0x20 || !extra.isEmpty)
                    let count = hasText ? 1 + extra.count : 0
                    if scratch.count < count { scratch = [UInt32](repeating: 0, count: count) }
                    scratch.withUnsafeMutableBufferPointer { buf in
                        if hasText {
                            buf[0] = cell.codepoint
                            for (i, scalar) in extra.enumerated() { buf[i + 1] = scalar }
                        }
                        body(CellView(
                            row: row, col: col,
                            codepoints: UnsafeBufferPointer(start: buf.baseAddress, count: count),
                            width: width, style: style,
                            foreground: resolve(cell.foreground), background: resolve(cell.background),
                            selected: selected
                        ))
                    }
                }
            }
        }
    }

    private func isSelected(row: Int, col: Int) -> Bool {
        guard let (start, end) = selected else { return false }
        if row < start.row || row > end.row { return false }
        if row == start.row, col < start.col { return false }
        if row == end.row, col > end.col { return false }
        return true
    }
}
