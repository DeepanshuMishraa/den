import Foundation
import CTermyEngine

/// A libtermy_engine call that returned a non-success status.
public struct VTError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: UInt32

    public var description: String {
        let name = switch code {
        case TERMY_ENGINE_NULL.rawValue: "a required pointer was null (a bug in Den's libtermy wrapper)"
        case TERMY_ENGINE_INVALID_ARGUMENT.rawValue: "invalid argument"
        case TERMY_ENGINE_PANICKED.rawValue: "libtermy panicked; this terminal's state may be inconsistent"
        case TERMY_ENGINE_NOT_A_SNAPSHOT.rawValue: "the data is not a libtermy snapshot"
        case TERMY_ENGINE_UNSUPPORTED_SNAPSHOT_VERSION.rawValue:
            "the snapshot comes from an incompatible libtermy release; run the same Den version on both ends and restart dend"
        case TERMY_ENGINE_TRUNCATED_SNAPSHOT.rawValue: "the snapshot is truncated"
        case TERMY_ENGINE_CORRUPT_SNAPSHOT.rawValue: "the snapshot is corrupt"
        default: "status \(code)"
        }
        return "libtermy \(operation) failed: \(name)"
    }
}

@inline(__always)
func check(_ status: TermyEngineStatus, _ operation: String) throws(VTError) {
    guard status == TERMY_ENGINE_OK else { throw VTError(operation: operation, code: status.rawValue) }
}

/// Bytes libtermy returns through a `TermyEngineBytes`, copied out and freed.
func takeBytes(_ operation: String, _ body: (UnsafeMutablePointer<TermyEngineBytes>) -> TermyEngineStatus) throws(VTError) -> Data {
    var bytes = TermyEngineBytes()
    defer { termy_engine_bytes_free(&bytes) }
    try check(body(&bytes), operation)
    guard let ptr = bytes.ptr, bytes.len > 0 else { return Data() }
    return Data(bytes: ptr, count: bytes.len)
}

public struct RGB: Equatable, Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// From libtermy's 0xRRGGBB.
    init(packed: UInt32) { self.init(UInt8(truncatingIfNeeded: packed >> 16), UInt8(truncatingIfNeeded: packed >> 8), UInt8(truncatingIfNeeded: packed)) }
    var packed: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }
}

/// Side effects a terminal produces while processing VT input. Only the
/// server's authoritative terminal installs `writeBack`; replicas leave it nil
/// so query responses are produced exactly once.
public struct VTEffects {
    public var writeBack: ((UnsafeRawBufferPointer) -> Void)?
    public var bell: (() -> Void)?
    /// The OSC 0/2 title as it was set, nil when reset. Fires once per
    /// change, after the write that made it.
    public var titleChanged: ((String?) -> Void)?

    public init(writeBack: ((UnsafeRawBufferPointer) -> Void)? = nil, bell: (() -> Void)? = nil, titleChanged: ((String?) -> Void)? = nil) {
        self.writeBack = writeBack
        self.bell = bell
        self.titleChanged = titleChanged
    }
}

/// Owning wrapper around a libtermy engine. Not thread-safe: confine each
/// instance to one actor or queue.
public final class VTTerminal {
    let handle: OpaquePointer
    /// The viewport's cells, shared by every view drawing this terminal:
    /// libtermy reports damage once, to whoever asks first.
    let frame = FrameCache()
    /// Highlighted text, in rows that stay put while output scrolls.
    var selection: TextSelection?

    /// Scrollback kept per terminal: rows, with a byte budget as a backstop
    /// for very wide panes. libtermy evicts about 4x slower when the byte
    /// budget is what binds, so the row limit should bind first (10,000
    /// rows of 117 columns is ~19 MiB). Replicas get both from the snapshot.
    public static let scrollbackRows: UInt32 = 10_000
    public static let scrollbackBytes = 64 * 1024 * 1024
    /// Longest OSC/DCS payload parsed; longer ones are dropped whole.
    static let maxStringBytes: UInt32 = 64 * 1024

    /// The snapshot format this build writes, and the oldest it reads.
    public static var snapshotVersion: UInt32 { termy_engine_snapshot_version() }
    public static var minimumSnapshotVersion: UInt32 { termy_engine_snapshot_min_version() }

    /// The format version a snapshot was written in, read from its header.
    public static func snapshotVersion(of snapshot: Data) throws(VTError) -> UInt32 {
        var version: UInt32 = 0
        let status = snapshot.withUnsafeBytes { raw in
            termy_engine_snapshot_peek_version(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &version)
        }
        try check(status, "snapshot_peek_version")
        return version
    }

    public init(cols: UInt16, rows: UInt16) throws(VTError) {
        try Self.checkABI()
        var options = termy_engine_options_default()
        options.cols = cols
        options.rows = rows
        options.scrollback_rows = Self.scrollbackRows
        options.scrollback_bytes = UInt64(Self.scrollbackBytes)
        options.max_string_bytes = Self.maxStringBytes
        options.reply_mode = UInt32(TERMY_ENGINE_REPLIES_DISCARD)
        var engine: OpaquePointer?
        try check(termy_engine_new(&options, &engine), "engine_new")
        guard let engine else { throw VTError(operation: "engine_new", code: TERMY_ENGINE_NULL.rawValue) }
        handle = engine
    }

    /// Restores a terminal from a snapshot produced by `snapshot()`.
    public init(snapshot: Data) throws(VTError) {
        try Self.checkABI()
        var engine: OpaquePointer?
        let status = snapshot.withUnsafeBytes { raw in
            termy_engine_snapshot_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, UInt32(TERMY_ENGINE_REPLIES_DISCARD), &engine)
        }
        try check(status, "snapshot_decode")
        guard let engine else { throw VTError(operation: "snapshot_decode", code: TERMY_ENGINE_NULL.rawValue) }
        handle = engine
    }

    /// The header and the linked library must agree on struct layouts.
    private static func checkABI() throws(VTError) {
        guard termy_engine_abi_version() == UInt32(TERMY_ENGINE_ABI_VERSION) else {
            throw VTError(operation: "abi_version (header \(TERMY_ENGINE_ABI_VERSION), library \(termy_engine_abi_version()))",
                          code: TERMY_ENGINE_INVALID_ARGUMENT.rawValue)
        }
    }

    deinit { termy_engine_free(handle) }

    public var effects = VTEffects() {
        didSet {
            let mode = effects.writeBack == nil ? TERMY_ENGINE_REPLIES_DISCARD : TERMY_ENGINE_REPLIES_RETURN
            // Cannot fail for a live handle and a valid mode.
            _ = termy_engine_set_reply_mode(handle, UInt32(mode))
        }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.bindMemory(to: UInt8.self).baseAddress, !bytes.isEmpty else { return }
        if effects.writeBack == nil {
            let status = termy_engine_feed(handle, base, bytes.count, nil)
            assert(status == TERMY_ENGINE_OK, "termy_engine_feed: \(status.rawValue)")
        } else {
            var replies = TermyEngineBytes()
            let status = termy_engine_feed(handle, base, bytes.count, &replies)
            assert(status == TERMY_ENGINE_OK, "termy_engine_feed: \(status.rawValue)")
            deliver(&replies)
        }
        drainEvents()
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    private func deliver(_ replies: inout TermyEngineBytes) {
        defer { termy_engine_bytes_free(&replies) }
        guard let ptr = replies.ptr, replies.len > 0 else { return }
        effects.writeBack?(UnsafeRawBufferPointer(start: ptr, count: replies.len))
    }

    /// Bell and title effects. Without handlers the events stay in
    /// libtermy's bounded queue, which drops the oldest.
    private func drainEvents() {
        guard effects.bell != nil || effects.titleChanged != nil else { return }
        var found = false
        var event = TermyEngineEvent()
        while termy_engine_next_event(handle, &found, &event) == TERMY_ENGINE_OK, found {
            defer { termy_engine_event_free(&event) }
            switch Int32(event.kind) {
            case TERMY_ENGINE_EVENT_BELL: effects.bell?()
            case TERMY_ENGINE_EVENT_TITLE:
                let title = event.payload.ptr.map { String(decoding: UnsafeBufferPointer(start: $0, count: event.payload.len), as: UTF8.self) }
                effects.titleChanged?(title?.isEmpty == false ? title : nil)
            case TERMY_ENGINE_EVENT_RESET_TITLE: effects.titleChanged?(nil)
            default: break
            }
        }
    }

    /// Milliseconds left before a synchronized update (?2026) the program
    /// hasn't ended must be shown anyway; nil when none is pending. Call
    /// `commitDueSynchronizedUpdate()` once it passes: libtermy has no timer.
    public var synchronizedUpdateDeadline: UInt64? {
        var pending = false
        var remaining: UInt64 = 0
        guard termy_engine_synchronized_deadline(handle, &pending, &remaining) == TERMY_ENGINE_OK, pending else { return nil }
        return remaining
    }

    /// Commits a synchronized update whose deadline has passed. Returns
    /// whether anything changed.
    @discardableResult
    public func commitDueSynchronizedUpdate() -> Bool {
        var committed = false
        if effects.writeBack == nil {
            _ = termy_engine_tick(handle, false, &committed, nil)
        } else {
            var replies = TermyEngineBytes()
            _ = termy_engine_tick(handle, false, &committed, &replies)
            deliver(&replies)
        }
        drainEvents()
        return committed
    }

    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) throws(VTError) {
        try check(termy_engine_resize(handle, cols, rows), "resize")
        try check(termy_engine_set_cell_pixels(handle, UInt16(clamping: cellWidthPx), UInt16(clamping: cellHeightPx)), "set_cell_pixels")
        // Reflow moves content between rows; the selection's anchors don't follow.
        selection = nil
    }

    /// Encodes the full terminal state, including scrollback and any
    /// unfinished escape sequence. `version` writes an older format for an
    /// older reader; nil writes this build's.
    public func snapshot(version: UInt32? = nil) throws(VTError) -> Data {
        if let version, version != Self.snapshotVersion {
            return try takeBytes("snapshot_encode_version(\(version))") { termy_engine_snapshot_encode_version(handle, version, $0) }
        }
        return try takeBytes("snapshot_encode") { termy_engine_snapshot_encode(handle, $0) }
    }

    var state: TermyEngineState {
        var s = TermyEngineState()
        _ = termy_engine_get_state(handle, &s)
        return s
    }

    public var cols: UInt16 { state.cols }
    public var rows: UInt16 { state.rows }

    /// Cursor cell within the active area, 0-indexed.
    public var cursorPosition: (col: UInt16, row: UInt16) {
        let s = state
        return (s.cursor_col, s.cursor_row)
    }

    /// Title set via OSC 0/2, nil when unset.
    public var title: String? {
        let bytes = (try? takeBytes("title") { termy_engine_title(handle, $0) }) ?? Data()
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    /// Working directory reported via OSC 7, nil when unset.
    public var pwd: String? {
        var found = false
        let bytes = (try? takeBytes("working_directory") { termy_engine_working_directory(handle, &found, $0) }) ?? Data()
        return found && !bytes.isEmpty ? String(decoding: bytes, as: UTF8.self) : nil
    }

    public var isAlternateScreen: Bool { state.alternate_screen }
    public var isMouseTracking: Bool { state.mouse_tracking != UInt8(TERMY_ENGINE_MOUSE_TRACKING_OFF) }

    public enum Scroll {
        /// Rows; negative scrolls back into history.
        case top, bottom, delta(Int)
    }

    public func scrollViewport(_ scroll: Scroll) {
        let (kind, value): (Int32, Int64) = switch scroll {
        case .top: (TERMY_ENGINE_SCROLL_TOP, 0)
        case .bottom: (TERMY_ENGINE_SCROLL_BOTTOM, 0)
        // libtermy's positive delta scrolls back.
        case .delta(let n): (TERMY_ENGINE_SCROLL_DELTA, -Int64(n))
        }
        var changed = false
        _ = termy_engine_scroll_viewport(handle, UInt32(kind), value, &changed)
    }

    /// Sets the default colors used when programs do not override them.
    public func setDefaultColors(foreground: RGB, background: RGB, cursor: RGB?, palette: [RGB]) {
        // A 256-entry palette replaces the xterm one; anything else keeps it.
        let full = palette.count == 256 ? palette.map(\.packed) : []
        var cursorColor = cursor?.packed ?? 0
        withUnsafePointer(to: &cursorColor) { cursorPtr in
            full.withUnsafeBufferPointer { paletteBuf in
                _ = termy_engine_set_default_colors(handle, foreground.packed, background.packed,
                                                    cursor == nil ? nil : cursorPtr, full.isEmpty ? nil : paletteBuf.baseAddress)
            }
        }
        frame.colorsRevision = nil
    }
}
