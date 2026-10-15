import Foundation
import GhosttyVt

public enum VTFormat: Sendable {
    /// Text only, trailing whitespace trimmed.
    case plain
    /// Text with the SGR sequences that reproduce its styling.
    case vt
    case html
}

extension VTTerminal {
    /// The screen, scrollback included, through libghostty's formatter.
    public func format(_ format: VTFormat) throws(VTError) -> String {
        var options = GhosttyFormatterTerminalOptions()
        options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        options.emit = switch format {
        case .plain: GHOSTTY_FORMATTER_FORMAT_PLAIN
        case .vt: GHOSTTY_FORMATTER_FORMAT_VT
        case .html: GHOSTTY_FORMATTER_FORMAT_HTML
        }
        options.trim = true
        options.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        options.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size

        var formatter: GhosttyFormatter?
        try check(ghostty_formatter_terminal_new(nil, &formatter, handle, options), "formatter_terminal_new")
        guard let formatter else { throw VTError(operation: "formatter_terminal_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        defer { ghostty_formatter_free(formatter) }

        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        try check(ghostty_formatter_format_alloc(formatter, nil, &ptr, &len), "formatter_format")
        guard let ptr else { return "" }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    /// Plain text of the active area (the rows the cursor can reach, no
    /// scrollback), one line per row, trailing whitespace trimmed.
    public func activeText() -> String {
        func ref(_ x: UInt16, _ y: UInt32) -> GhosttyGridRef? {
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.size
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_ACTIVE
            point.value.coordinate = GhosttyPointCoordinate(x: x, y: y)
            return ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
        }
        guard cols > 0, rows > 0, let start = ref(0, 0), let end = ref(cols - 1, UInt32(rows - 1)) else { return "" }
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        selection.start = start
        selection.end = end
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.trim = true
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        let result = withUnsafePointer(to: &selection) { sel in
            opts.selection = sel
            return ghostty_terminal_selection_format_alloc(handle, nil, opts, &ptr, &len)
        }
        guard result == GHOSTTY_SUCCESS, let ptr else { return "" }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}
