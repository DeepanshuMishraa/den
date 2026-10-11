import Foundation
import GhosttyVt

/// A libghostty-vt call that returned a non-success result.
public struct VTError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: Int32

    public var description: String {
        let name = switch code {
        case GHOSTTY_OUT_OF_MEMORY.rawValue: "out of memory"
        case GHOSTTY_INVALID_VALUE.rawValue: "invalid value"
        case GHOSTTY_OUT_OF_SPACE.rawValue: "out of space"
        case GHOSTTY_NO_VALUE.rawValue: "no value"
        default: "result \(code)"
        }
        return "libghostty-vt \(operation) failed: \(name)"
    }
}

@inline(__always)
func check(_ result: GhosttyResult, _ operation: String) throws(VTError) {
    guard result == GHOSTTY_SUCCESS else { throw VTError(operation: operation, code: result.rawValue) }
}

public struct RGB: Equatable, Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ c: GhosttyColorRgb) { self.init(c.r, c.g, c.b) }
    var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
}

/// Side effects a terminal produces while processing VT input. Only the
/// server's authoritative terminal installs `writeBack`; replicas leave it nil
/// so query responses are produced exactly once.
public struct VTEffects {
    public var writeBack: ((UnsafeRawBufferPointer) -> Void)?
    public var bell: (() -> Void)?
    public var titleChanged: (() -> Void)?

    public init(writeBack: ((UnsafeRawBufferPointer) -> Void)? = nil, bell: (() -> Void)? = nil, titleChanged: (() -> Void)? = nil) {
        self.writeBack = writeBack
        self.bell = bell
        self.titleChanged = titleChanged
    }
}

private final class EffectsBox {
    var effects: VTEffects
    init(_ effects: VTEffects) { self.effects = effects }
}

/// Owning wrapper around a `GhosttyTerminal`. Not thread-safe: confine each
/// instance to one actor or queue.
public final class VTTerminal {
    let handle: GhosttyTerminal
    private let box = EffectsBox(VTEffects())

    /// Bytes of scrollback kept per terminal. Server and replicas use the same
    /// value so history stays identical.
    public static let scrollbackBytes = 16 * 1024 * 1024
    static let continuationBytes = 64 * 1024

    public init(cols: UInt16, rows: UInt16) throws(VTError) {
        var t: GhosttyTerminal?
        try check(ghostty_terminal_new(nil, &t, cols, rows), "terminal_new")
        guard let t else { throw VTError(operation: "terminal_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        handle = t
        try configure()
    }

    /// Restores a terminal from a snapshot produced by `snapshot()`.
    public init(snapshot: Data) throws(VTError) {
        var decoder: GhosttySnapshotDecoder?
        let result = snapshot.withUnsafeBytes { raw in
            ghostty_snapshot_decoder_new_buf(nil, &decoder, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        try check(result, "snapshot_decoder_new")
        guard let decoder else { throw VTError(operation: "snapshot_decoder_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        defer { ghostty_snapshot_decoder_free(decoder) }
        var t: GhosttyTerminal?
        try check(ghostty_snapshot_decoder_decode(decoder, &t), "snapshot_decode")
        guard let t else { throw VTError(operation: "snapshot_decode", code: GHOSTTY_INVALID_VALUE.rawValue) }
        handle = t
        try configure()
    }

    private func configure() throws(VTError) {
        var continuation = Self.continuationBytes
        try check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation), "set continuation")
        var scrollback = Self.scrollbackBytes
        try check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback), "set scrollback")
        let userdata = Unmanaged.passUnretained(box).toOpaque()
        try check(ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, userdata), "set userdata")
    }

    deinit { ghostty_terminal_free(handle) }

    public var effects: VTEffects {
        get { box.effects }
        set {
            box.effects = newValue
            let writePty: GhosttyTerminalWritePtyFn? = newValue.writeBack == nil ? nil : { _, userdata, data, len in
                guard let userdata, let data else { return }
                let box = Unmanaged<EffectsBox>.fromOpaque(userdata).takeUnretainedValue()
                box.effects.writeBack?(UnsafeRawBufferPointer(start: data, count: len))
            }
            let bell: GhosttyTerminalBellFn? = newValue.bell == nil ? nil : { _, userdata in
                guard let userdata else { return }
                Unmanaged<EffectsBox>.fromOpaque(userdata).takeUnretainedValue().effects.bell?()
            }
            let title: GhosttyTerminalTitleChangedFn? = newValue.titleChanged == nil ? nil : { _, userdata in
                guard let userdata else { return }
                Unmanaged<EffectsBox>.fromOpaque(userdata).takeUnretainedValue().effects.titleChanged?()
            }
            // Setting a callback cannot fail for a valid option; results are
            // ignored to keep the setter non-throwing.
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer?.self))
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer?.self))
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer?.self))
        }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
        ghostty_terminal_vt_write(handle, base, bytes.count)
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { write($0) }
    }

    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32, cellHeightPx: UInt32) throws(VTError) {
        try check(ghostty_terminal_resize(handle, cols, rows, cellWidthPx, cellHeightPx), "resize")
    }

    /// Encodes the full terminal state, including scrollback and any
    /// unfinished escape sequence.
    public func snapshot() throws(VTError) -> Data {
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        try check(ghostty_snapshot_encode_alloc(handle, nil, &ptr, &len), "snapshot_encode")
        guard let ptr else { return Data() }
        defer { ghostty_free(nil, ptr, len) }
        return Data(bytes: ptr, count: len)
    }

    public var cols: UInt16 { get16(GHOSTTY_TERMINAL_DATA_COLS) }
    public var rows: UInt16 { get16(GHOSTTY_TERMINAL_DATA_ROWS) }

    private func get16(_ key: GhosttyTerminalData) -> UInt16 {
        var v: UInt16 = 0
        _ = ghostty_terminal_get(handle, key, &v)
        return v
    }

    /// Cursor cell within the active area, 0-indexed.
    public var cursorPosition: (col: UInt16, row: UInt16) {
        (get16(GHOSTTY_TERMINAL_DATA_CURSOR_X), get16(GHOSTTY_TERMINAL_DATA_CURSOR_Y))
    }

    /// Title set via OSC 0/2, nil when unset.
    public var title: String? { string(GHOSTTY_TERMINAL_DATA_TITLE) }
    /// Working directory reported via OSC 7, nil when unset.
    public var pwd: String? { string(GHOSTTY_TERMINAL_DATA_PWD) }

    private func string(_ key: GhosttyTerminalData) -> String? {
        var s = GhosttyString()
        guard ghostty_terminal_get(handle, key, &s) == GHOSTTY_SUCCESS, s.len > 0, let ptr = s.ptr else { return nil }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: s.len), as: UTF8.self)
    }

    public var isAlternateScreen: Bool {
        var screen = GhosttyTerminalScreen(rawValue: 0)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    public var isMouseTracking: Bool {
        var tracking = false
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        return tracking
    }

    public enum Scroll {
        case top, bottom, delta(Int)
    }

    public func scrollViewport(_ scroll: Scroll) {
        var behavior = GhosttyTerminalScrollViewport()
        switch scroll {
        case .top: behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        case .bottom: behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        case .delta(let n):
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = n
        }
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    /// Sets the default colors used when programs do not override them.
    public func setDefaultColors(foreground: RGB, background: RGB, cursor: RGB?, palette: [RGB]) {
        var fg = foreground.ghostty
        var bg = background.ghostty
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if var c = cursor?.ghostty {
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c)
        } else {
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, nil)
        }
        if palette.count == 256 {
            var full = palette.map(\.ghostty)
            _ = full.withUnsafeMutableBufferPointer { ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
        } else {
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, nil)
        }
    }
}
