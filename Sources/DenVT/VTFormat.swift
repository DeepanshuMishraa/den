import Foundation
import CTermyEngine

public enum VTFormat: Sendable {
    /// Text only, trailing whitespace trimmed.
    case plain
    /// Text with the SGR sequences that reproduce its styling.
    case vt
    case html
}

extension VTTerminal {
    /// The screen, scrollback included, through libtermy's formatter.
    public func format(_ format: VTFormat) throws(VTError) -> String {
        let emit = switch format {
        case .plain: TERMY_ENGINE_FORMAT_PLAIN
        case .vt: TERMY_ENGINE_FORMAT_VT
        case .html: TERMY_ENGINE_FORMAT_HTML
        }
        let bytes = try takeBytes("read_text") { termy_engine_read_text(handle, nil, UInt32(emit), UInt32(TERMY_ENGINE_TEXT_TRIM), $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Plain text of the active area (the rows the cursor can reach, no
    /// scrollback), one line per row, trailing whitespace trimmed.
    public func activeText() -> String {
        let s = state
        guard s.cols > 0, s.rows > 0 else { return "" }
        var range = TermyEngineTextRange(start_line: 0, start_col: 0, end_line: Int64(s.rows) - 1, end_col: UInt32(s.cols) - 1, rectangular: false)
        let bytes = (try? takeBytes("read_text") {
            termy_engine_read_text(handle, &range, UInt32(TERMY_ENGINE_FORMAT_PLAIN), UInt32(TERMY_ENGINE_TEXT_TRIM), $0)
        }) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }
}
