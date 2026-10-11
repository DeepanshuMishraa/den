import Foundation
import GhosttyVt

public struct Scrollbar: Equatable, Sendable {
    /// Total rows including scrollback.
    public var total: UInt64
    /// First visible row.
    public var offset: UInt64
    /// Visible rows.
    public var length: UInt64
}

extension VTTerminal {
    public var scrollbar: Scrollbar {
        var s = GhosttyTerminalScrollbar()
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s)
        return Scrollbar(total: s.total, offset: s.offset, length: s.len)
    }

    public func scrollViewport(toRow row: UInt64) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        behavior.value.row = Int(clamping: row)
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    public func clearSelection() {
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    /// Plain text of the active selection, nil when nothing is selected.
    public func selectedText() -> String? {
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.trim = true
        opts.unwrap = true
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        let result = withUnsafePointer(to: &selection) { sel in
            opts.selection = sel
            return ghostty_terminal_selection_format_alloc(handle, nil, opts, &ptr, &len)
        }
        guard result == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { ghostty_free(nil, ptr, len) }
        let text = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}

/// Click/drag/double/triple-click selection, using libghostty's gesture
/// state machine so behavior matches Ghostty.
public final class SelectionGesture {
    private let gesture: GhosttySelectionGesture
    private let press: GhosttySelectionGestureEvent
    private let drag: GhosttySelectionGestureEvent
    private let release: GhosttySelectionGestureEvent

    public init() throws(VTError) {
        var g: GhosttySelectionGesture?
        try check(ghostty_selection_gesture_new(nil, &g), "selection_gesture_new")
        func event(_ type: GhosttySelectionGestureEventType) throws(VTError) -> GhosttySelectionGestureEvent {
            var e: GhosttySelectionGestureEvent?
            try check(ghostty_selection_gesture_event_new(nil, &e, type), "selection_gesture_event_new")
            guard let e else { throw VTError(operation: "selection_gesture_event_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
            return e
        }
        guard let g else { throw VTError(operation: "selection_gesture_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        gesture = g
        press = try event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        drag = try event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        release = try event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
    }

    deinit {
        ghostty_selection_gesture_event_free(press)
        ghostty_selection_gesture_event_free(drag)
        ghostty_selection_gesture_event_free(release)
        // Release tracked refs against the terminal they point into. Holding
        // `lastTerminal` keeps that terminal alive until this point.
        ghostty_selection_gesture_free(gesture, lastTerminal?.handle)
    }

    private var lastTerminal: VTTerminal?

    public enum Phase { case press, drag, release }

    /// Feeds one mouse event. `col`/`row` are viewport cells; `x`/`y` are
    /// pixels relative to the grid. Returns true when the selection changed.
    @discardableResult
    public func handle(_ phase: Phase, col: Int, row: Int, x: Double, y: Double, timeNs: UInt64,
                       columns: Int, cellWidth: Int, screenHeight: Int, terminal: VTTerminal) -> Bool {
        if let last = lastTerminal, last !== terminal {
            // The replica was rebuilt from a snapshot; drop refs into the old one.
            ghostty_selection_gesture_reset(gesture, last.handle)
        }
        lastTerminal = terminal
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: max(col, 0)), y: UInt32(clamping: max(row, 0)))
        guard ghostty_terminal_grid_ref(terminal.handle, point, &ref) == GHOSTTY_SUCCESS else { return false }

        let event: GhosttySelectionGestureEvent = switch phase {
        case .press: press
        case .drag: drag
        case .release: release
        }
        _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        var position = GhosttySurfacePosition(x: x, y: y)
        _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        var time = timeNs
        _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
        var geometry = GhosttySelectionGestureGeometry(
            columns: UInt32(max(columns, 1)), cell_width: UInt32(max(cellWidth, 1)),
            padding_left: 0, screen_height: UInt32(max(screenHeight, 1))
        )
        _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)

        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        let result = ghostty_selection_gesture_event(gesture, terminal.handle, event, &selection)
        guard result == GHOSTTY_SUCCESS else {
            if phase == .press { terminal.clearSelection() }
            return phase == .press
        }
        _ = ghostty_terminal_set(terminal.handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
        return true
    }

    public func reset(_ terminal: VTTerminal) {
        ghostty_selection_gesture_reset(gesture, terminal.handle)
    }
}
