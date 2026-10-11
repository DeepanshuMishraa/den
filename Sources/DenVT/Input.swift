import Foundation
import GhosttyVt

public struct KeyMods: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let shift = KeyMods(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
    public static let ctrl = KeyMods(rawValue: UInt16(GHOSTTY_MODS_CTRL))
    public static let alt = KeyMods(rawValue: UInt16(GHOSTTY_MODS_ALT))
    public static let `super` = KeyMods(rawValue: UInt16(GHOSTTY_MODS_SUPER))
    public static let capsLock = KeyMods(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
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
    private let encoder: GhosttyKeyEncoder
    private let event: GhosttyKeyEvent
    private var buffer = [CChar](repeating: 0, count: 128)

    public init() throws(VTError) {
        var e: GhosttyKeyEncoder?
        try check(ghostty_key_encoder_new(nil, &e), "key_encoder_new")
        var ev: GhosttyKeyEvent?
        try check(ghostty_key_event_new(nil, &ev), "key_event_new")
        guard let e, let ev else { throw VTError(operation: "key_encoder_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        encoder = e
        event = ev
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    public func encode(_ input: KeyInput, terminal: VTTerminal, optionAsAlt: Bool) -> Data {
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal.handle)
        var optionMode: GhosttyOptionAsAlt = optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionMode)

        let action: GhosttyKeyAction = switch input.action {
        case .press: GHOSTTY_KEY_ACTION_PRESS
        case .release: GHOSTTY_KEY_ACTION_RELEASE
        case .repeat: GHOSTTY_KEY_ACTION_REPEAT
        }
        ghostty_key_event_set_action(event, action)
        ghostty_key_event_set_key(event, macKeycodes[input.macKeyCode] ?? GHOSTTY_KEY_UNIDENTIFIED)
        ghostty_key_event_set_mods(event, input.mods.rawValue)
        ghostty_key_event_set_consumed_mods(event, input.consumedMods.rawValue)
        ghostty_key_event_set_unshifted_codepoint(event, input.unshifted)
        ghostty_key_event_set_composing(event, false)

        let text = input.text ?? ""
        var written = 0
        let result = text.withCString { ptr in
            ghostty_key_event_set_utf8(event, ptr, strlen(ptr))
            return buffer.withUnsafeMutableBufferPointer { buf in
                ghostty_key_encoder_encode(encoder, event, buf.baseAddress, buf.count, &written)
            }
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return Data() }
        return buffer.withUnsafeBytes { Data($0.prefix(written)) }
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
    private let encoder: GhosttyMouseEncoder
    private let event: GhosttyMouseEvent
    private var buffer = [CChar](repeating: 0, count: 64)

    public init() throws(VTError) {
        var e: GhosttyMouseEncoder?
        try check(ghostty_mouse_encoder_new(nil, &e), "mouse_encoder_new")
        var ev: GhosttyMouseEvent?
        try check(ghostty_mouse_event_new(nil, &ev), "mouse_event_new")
        guard let e, let ev else { throw VTError(operation: "mouse_encoder_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        encoder = e
        event = ev
    }

    deinit {
        ghostty_mouse_event_free(event)
        ghostty_mouse_encoder_free(encoder)
    }

    /// Positions are in pixels relative to the grid's top-left corner.
    public func encode(action: MouseAction, button: MouseButton?, mods: KeyMods, x: Float, y: Float,
                       cellWidth: UInt32, cellHeight: UInt32, cols: UInt16, rows: UInt16,
                       anyButtonPressed: Bool, terminal: VTTerminal) -> Data {
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal.handle)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(cols) * cellWidth
        size.screen_height = UInt32(rows) * cellHeight
        size.cell_width = cellWidth
        size.cell_height = cellHeight
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = anyButtonPressed
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)

        let mouseAction: GhosttyMouseAction = switch action {
        case .press: GHOSTTY_MOUSE_ACTION_PRESS
        case .release: GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: GHOSTTY_MOUSE_ACTION_MOTION
        }
        ghostty_mouse_event_set_action(event, mouseAction)
        if let button {
            let ghosttyButton: GhosttyMouseButton = switch button {
            case .left: GHOSTTY_MOUSE_BUTTON_LEFT
            case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
            case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
            case .wheelUp: GHOSTTY_MOUSE_BUTTON_FOUR
            case .wheelDown: GHOSTTY_MOUSE_BUTTON_FIVE
            case .wheelLeft: GHOSTTY_MOUSE_BUTTON_SIX
            case .wheelRight: GHOSTTY_MOUSE_BUTTON_SEVEN
            }
            ghostty_mouse_event_set_button(event, ghosttyButton)
        } else {
            ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, mods.rawValue)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: x, y: y))

        var written = 0
        let result = buffer.withUnsafeMutableBufferPointer { buf in
            ghostty_mouse_encoder_encode(encoder, event, buf.baseAddress, buf.count, &written)
        }
        guard result == GHOSTTY_SUCCESS, written > 0 else { return Data() }
        return buffer.withUnsafeBytes { Data($0.prefix(written)) }
    }
}

extension VTTerminal {
    public func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    public var bracketedPaste: Bool { mode(2004) }
    public var focusReporting: Bool { mode(1004) }
    /// DEC mode 1007: wheel scrolls send arrow keys on the alternate screen.
    public var alternateScroll: Bool { mode(1007) }

    /// Encodes pasted text, wrapping it in bracketed-paste markers when the
    /// program asked for them.
    public func encodePaste(_ text: String) -> Data {
        var input = Array(text.utf8CString.dropLast())
        let bracketed = bracketedPaste
        var needed = 0
        _ = input.withUnsafeMutableBufferPointer { src in
            ghostty_paste_encode(src.baseAddress, src.count, bracketed, nil, 0, &needed)
        }
        var out = [CChar](repeating: 0, count: max(needed, input.count + 16))
        var written = 0
        let result = input.withUnsafeMutableBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                ghostty_paste_encode(src.baseAddress, src.count, bracketed, dst.baseAddress, dst.count, &written)
            }
        }
        guard result == GHOSTTY_SUCCESS else { return Data(text.utf8) }
        return out.withUnsafeBytes { Data($0.prefix(written)) }
    }

    public static func encodeFocus(_ gained: Bool) -> Data {
        var buf = [CChar](repeating: 0, count: 8)
        var written = 0
        let result = buf.withUnsafeMutableBufferPointer {
            ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, $0.baseAddress, $0.count, &written)
        }
        guard result == GHOSTTY_SUCCESS else { return Data() }
        return buf.withUnsafeBytes { Data($0.prefix(written)) }
    }
}
