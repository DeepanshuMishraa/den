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
}
