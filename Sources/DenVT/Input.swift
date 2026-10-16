import Foundation
import CTermyEngine

public struct KeyMods: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let shift = KeyMods(rawValue: 1 << 0)
    public static let alt = KeyMods(rawValue: 1 << 1)
    public static let ctrl = KeyMods(rawValue: 1 << 2)
    public static let `super` = KeyMods(rawValue: 1 << 3)
    public static let capsLock = KeyMods(rawValue: 1 << 4)
    /// With `.alt`: the right option key is the one held.
    public static let altRight = KeyMods(rawValue: 1 << 5)

    /// libtermy's modifier bits, saying which Option key is down so
    /// `OptionAsAlt` can apply per side. Caps lock isn't reported.
    var termy: UInt32 {
        var bits: UInt32 = 0
        if contains(.shift) { bits |= UInt32(TERMY_ENGINE_MOD_SHIFT) }
        if contains(.ctrl) { bits |= UInt32(TERMY_ENGINE_MOD_CTRL) }
        if contains(.super) { bits |= UInt32(TERMY_ENGINE_MOD_SUPER) }
        if contains(.alt) {
            bits |= UInt32(TERMY_ENGINE_MOD_ALT)
            bits |= UInt32(contains(.altRight) ? TERMY_ENGINE_MOD_RIGHT_ALT : TERMY_ENGINE_MOD_LEFT_ALT)
        }
        return bits
    }
}

/// Which option keys act as alt (ESC-prefix) instead of composing text,
/// like Ghostty's `macos-option-as-alt`.
public enum OptionAsAlt: String, Sendable, CaseIterable {
    case none = "false", both = "true", left, right

    public func treatsAsAlt(rightSide: Bool) -> Bool {
        switch self {
        case .none: false
        case .both: true
        case .left: !rightSide
        case .right: rightSide
        }
    }

    var termy: UInt32 {
        let mode = switch self {
        case .none: TERMY_ENGINE_OPTION_AS_ALT_NONE
        case .both: TERMY_ENGINE_OPTION_AS_ALT_BOTH
        case .left: TERMY_ENGINE_OPTION_AS_ALT_LEFT
        case .right: TERMY_ENGINE_OPTION_AS_ALT_RIGHT
        }
        return UInt32(mode)
    }
}

public enum KeyAction: Sendable {
    case press, release, `repeat`
}

/// A key event in platform terms, translated to VT bytes by `KeyEncoder`.
public struct KeyInput: Sendable {
    public var macKeyCode: UInt16
    public var action: KeyAction
    public var mods: KeyMods
    /// Modifiers that took part in producing `text` (e.g. shift for `:`).
    /// The encoder leaves these out of kitty/modifyOtherKeys sequences.
    public var consumedMods: KeyMods
    /// Text the key produced after modifiers, if any.
    public var text: String?
    /// Codepoint the key produces without modifiers (for kitty protocol).
    public var unshifted: UInt32

    public init(macKeyCode: UInt16, action: KeyAction, mods: KeyMods, consumedMods: KeyMods, text: String?, unshifted: UInt32) {
        self.macKeyCode = macKeyCode
        self.action = action
        self.mods = mods
        self.consumedMods = consumedMods
        self.text = text
        self.unshifted = unshifted
    }
}

/// Encodes keyboard input using the terminal's current modes (cursor key
/// mode, kitty keyboard flags, ...). Runs against the client's replica.
public final class KeyEncoder {
    public init() throws(VTError) {}

    public func encode(_ input: KeyInput, terminal: VTTerminal, optionAsAlt: Bool) -> Data {
        encode(input, terminal: terminal, optionAsAlt: optionAsAlt ? .both : .none)
    }

    public func encode(_ input: KeyInput, terminal: VTTerminal, optionAsAlt: OptionAsAlt) -> Data {
        // libtermy has no keypad key names, so numpad Enter would encode as
        // Return. In application keypad mode (DECKPAM, legacy keyboard) it
        // sends SS3 M.
        if input.macKeyCode == numpadEnterKeyCode, input.action != .release,
           input.mods.subtracting([.capsLock, .altRight]).isEmpty {
            let state = terminal.state
            if state.application_keypad, state.kitty_keyboard_flags == 0 { return Data("\u{1b}OM".utf8) }
        }
        // Text keys go by the character the layout gives them (libtermy
        // reads `unshifted`), so non-US layouts send what they type.
        var key = macKeyNames[input.macKeyCode] ?? ""
        var text = input.text ?? ""
        // libtermy's legacy encoder sends ' ' for "space" whatever it
        // typed; a composed character (Option-Space's no-break space) goes
        // by its text instead.
        if key == "space", !text.isEmpty, text != " " { key = "" }
        var event = TermyEngineKeyEvent()
        event.unshifted_codepoint = input.unshifted
        event.mods = input.mods.termy
        event.consumed_mods = input.consumedMods.termy
        let action = switch input.action {
        case .press: TERMY_ENGINE_KEY_PRESS
        case .release: TERMY_ENGINE_KEY_RELEASE
        case .repeat: TERMY_ENGINE_KEY_REPEAT
        }
        event.action = UInt8(action)
        event.composing = false
        return (try? key.withUTF8 { keyBuf in
            try text.withUTF8 { textBuf in
                event.key_ptr = keyBuf.baseAddress
                event.key_len = keyBuf.count
                event.text_ptr = textBuf.baseAddress
                event.text_len = textBuf.count
                return try takeBytes("encode_key") { termy_engine_encode_key(terminal.handle, &event, optionAsAlt.termy, $0) }
            }
        }) ?? Data()
    }
}

public enum MouseButton: Sendable {
    case left, right, middle, wheelUp, wheelDown, wheelLeft, wheelRight
}

public enum MouseAction: Sendable {
    case press, release, motion
}

/// Encodes mouse reports when a program has enabled mouse tracking.
public final class MouseEncoder {
    public init() throws(VTError) {}

    /// Positions are in pixels relative to the grid's top-left corner.
    public func encode(action: MouseAction, button: MouseButton?, mods: KeyMods, x: Float, y: Float,
                       cellWidth: UInt32, cellHeight: UInt32, cols: UInt16, rows: UInt16,
                       anyButtonPressed: Bool, terminal: VTTerminal) -> Data {
        var event = TermyEngineMouseEvent()
        let mouseAction = switch action {
        case .press: TERMY_ENGINE_MOUSE_PRESS
        case .release: TERMY_ENGINE_MOUSE_RELEASE
        case .motion: TERMY_ENGINE_MOUSE_MOTION
        }
        let mouseButton = switch button {
        case nil: TERMY_ENGINE_MOUSE_BUTTON_NONE
        case .left: TERMY_ENGINE_MOUSE_BUTTON_LEFT
        case .right: TERMY_ENGINE_MOUSE_BUTTON_RIGHT
        case .middle: TERMY_ENGINE_MOUSE_BUTTON_MIDDLE
        case .wheelUp: TERMY_ENGINE_MOUSE_WHEEL_UP
        case .wheelDown: TERMY_ENGINE_MOUSE_WHEEL_DOWN
        case .wheelLeft: TERMY_ENGINE_MOUSE_WHEEL_LEFT
        case .wheelRight: TERMY_ENGINE_MOUSE_WHEEL_RIGHT
        }
        event.action = UInt8(mouseAction)
        event.button = UInt8(mouseButton)
        event.any_button_pressed = anyButtonPressed
        // Mouse reports carry shift, alt and ctrl only.
        if mods.contains(.shift) { event.mods |= UInt32(TERMY_ENGINE_MOD_SHIFT) }
        if mods.contains(.alt) { event.mods |= UInt32(TERMY_ENGINE_MOD_ALT) }
        if mods.contains(.ctrl) { event.mods |= UInt32(TERMY_ENGINE_MOD_CTRL) }
        // Outside the grid (dragging past an edge) reports the nearest cell,
        // and in pixel mode the nearest pixel inside the grid.
        let width = max(cellWidth, 1), height = max(cellHeight, 1)
        let maxX = width * UInt32(max(cols, 1)) - 1, maxY = height * UInt32(max(rows, 1)) - 1
        func clamp(_ v: Float, _ upper: UInt32) -> UInt32 { v > 0 ? (v < Float(upper) ? UInt32(v) : upper) : 0 }
        let px = clamp(x, maxX), py = clamp(y, maxY)
        event.col = px / width
        event.row = py / height
        event.x_px = px
        event.y_px = py
        return (try? takeBytes("encode_mouse") { termy_engine_encode_mouse(terminal.handle, &event, $0) }) ?? Data()
    }
}

extension VTTerminal {
    /// DECRQM: whether DEC private (or, with `ansi`, ANSI) mode `value` is set.
    public func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        var report: UInt8 = 0
        _ = termy_engine_mode(handle, value, ansi, &report)
        return report == 1 || report == 3
    }

    public var bracketedPaste: Bool { state.bracketed_paste }
    public var focusReporting: Bool { state.focus_reporting }
    /// DEC mode 1007: wheel scrolls send arrow keys on the alternate screen.
    public var alternateScroll: Bool { state.alternate_scroll }

    /// Encodes pasted text, wrapping it in bracketed-paste markers when the
    /// program asked for them.
    public func encodePaste(_ text: String) -> Data {
        var text = text
        let bracketed = bracketedPaste
        // If libtermy can't encode it, paste the text as is rather than
        // dropping the clipboard.
        return (try? text.withUTF8 { buf in
            try takeBytes("encode_paste") { termy_engine_encode_paste(buf.baseAddress, buf.count, bracketed, $0) }
        }) ?? Data(text.utf8)
    }

    public static func encodeFocus(_ gained: Bool) -> Data {
        (try? takeBytes("encode_focus") { termy_engine_encode_focus(gained, $0) }) ?? Data()
    }
}
