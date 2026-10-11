import Foundation
import GhosttyVt

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

/// Snapshot of what to draw for one frame, refreshed from a `VTTerminal`.
public final class VTRenderState {
    private let state: GhosttyRenderState
    private let rows: GhosttyRenderStateRowIterator
    private let cells: GhosttyRenderStateRowCells
    private var codepointBuffer = [UInt32](repeating: 0, count: 32)

    public init() throws(VTError) {
        var s: GhosttyRenderState?
        try check(ghostty_render_state_new(nil, &s), "render_state_new")
        var it: GhosttyRenderStateRowIterator?
        try check(ghostty_render_state_row_iterator_new(nil, &it), "row_iterator_new")
        var c: GhosttyRenderStateRowCells?
        try check(ghostty_render_state_row_cells_new(nil, &c), "row_cells_new")
        guard let s, let it, let c else { throw VTError(operation: "render_state_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        state = s
        rows = it
        cells = c
    }

    deinit {
        ghostty_render_state_row_cells_free(cells)
        ghostty_render_state_row_iterator_free(rows)
        ghostty_render_state_free(state)
    }

    public func update(from terminal: VTTerminal) throws(VTError) {
        try check(ghostty_render_state_update(state, terminal.handle), "render_state_update")
    }

    public var size: (cols: Int, rows: Int) {
        var c: UInt16 = 0, r: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &c)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &r)
        return (Int(c), Int(r))
    }

    public var colors: FrameColors {
        var c = GhosttyRenderStateColors()
        c.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &c)
        let palette = withUnsafeBytes(of: c.palette) { raw in
            raw.bindMemory(to: GhosttyColorRgb.self).map(RGB.init)
        }
        return FrameColors(foreground: RGB(c.foreground), background: RGB(c.background), cursor: c.cursor_has_value ? RGB(c.cursor) : nil, palette: palette)
    }

    /// Cursor position in viewport coordinates, nil when hidden or scrolled
    /// out of view.
    public var cursor: CursorState? {
        var c = GhosttyRenderStateCursor()
        c.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &c) == GHOSTTY_SUCCESS,
              c.visible, c.viewport_has_value else { return nil }
        let shape: CursorShape = switch c.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: .hollowBlock
        default: .block
        }
        return CursorState(x: Int(c.viewport_x), y: Int(c.viewport_y), shape: shape, blinking: c.blinking, wideTail: c.wide_tail)
    }

    /// Visits every cell that has text or a non-default background.
    public func forEachCell(_ body: (CellView) -> Void) {
        var iterator: GhosttyRenderStateRowIterator? = rows
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS else { return }
        var y = 0
        while ghostty_render_state_row_iterator_next(rows) {
            defer { y += 1 }
            var rowCells: GhosttyRenderStateRowCells? = cells
            guard ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells) == GHOSTTY_SUCCESS else { continue }
            var x = 0
            while ghostty_render_state_row_cells_next(cells) {
                defer { x += 1 }
                visitCell(row: y, col: x, body)
            }
        }
    }

    private func visitCell(row: Int, col: Int, _ body: (CellView) -> Void) {
        var len: UInt32 = 0
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
        var bg = GhosttyColorRgb()
        let hasBg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS
        var selected = false
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected)
        var styled = false
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
        guard len > 0 || hasBg || selected || styled else { return }

        var raw = GhosttyCell()
        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
        var wide = GHOSTTY_CELL_WIDE_NARROW
        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        let width: CellWidth = switch wide {
        case GHOSTTY_CELL_WIDE_WIDE: .wide
        case GHOSTTY_CELL_WIDE_SPACER_TAIL: .spacerTail
        case GHOSTTY_CELL_WIDE_SPACER_HEAD: .spacerHead
        default: .narrow
        }

        var style = CellStyle()
        if styled {
            var s = GhosttyStyle()
            s.size = MemoryLayout<GhosttyStyle>.size
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &s)
            style.bold = s.bold
            style.italic = s.italic
            style.faint = s.faint
            style.inverse = s.inverse
            style.invisible = s.invisible
            style.strikethrough = s.strikethrough
            style.underline = switch s.underline {
            case 1: .single
            case 2: .double
            case 3: .curly
            case 4: .dotted
            case 5: .dashed
            default: .none
            }
            if s.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB {
                style.underlineColor = RGB(s.underline_color.value.rgb)
            }
        }

        var fg = GhosttyColorRgb()
        let hasFg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS

        let count = Int(min(len, UInt32(codepointBuffer.count)))
        codepointBuffer.withUnsafeMutableBufferPointer { buf in
            if len > 0, len <= UInt32(buf.count) {
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf.baseAddress)
            }
            let view = CellView(
                row: row,
                col: col,
                codepoints: UnsafeBufferPointer(start: buf.baseAddress, count: len <= UInt32(buf.count) ? count : 0),
                width: width,
                style: style,
                foreground: hasFg ? RGB(fg) : nil,
                background: hasBg ? RGB(bg) : nil,
                selected: selected
            )
            body(view)
        }
    }

    /// Marks the frame as drawn so the next update reports fresh dirty state.
    public func markClean() {
        _ = ghostty_render_state_clean(state)
    }
}
