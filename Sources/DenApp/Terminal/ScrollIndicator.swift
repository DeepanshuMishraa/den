import AppKit
import QuartzCore
import DenVT

/// A pane's scrollbar: a thin rounded pill at the right edge that appears
/// while scrolling or when the pointer nears the edge, then fades away. The
/// pill glides to new positions instead of jumping, widens under the
/// pointer, and drags continuously, row by row.
@MainActor
final class ScrollIndicator: NSView {
    /// Asks the pane to show this row at the top of the viewport.
    var onScroll: ((UInt64) -> Void)?

    private let knob = CALayer()
    private var bar: Scrollbar?
    private var color = NSColor.white
    private var hovering = false
    private var dragging: (grabY: CGFloat, startTop: CGFloat)?
    private var hideTask: DispatchWorkItem?

    /// Width of the area that reacts to the pointer; the pill is narrower.
    static let hitWidth: CGFloat = 14
    private static let thin: CGFloat = 4.5
    private static let wide: CGFloat = 7
    private static let inset = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 3)
    private static let minKnob: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(knob)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Hidden, it lets clicks through to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.01, isScrollable else { return nil }
        return super.hitTest(point)
    }

    private var isScrollable: Bool { bar.map { $0.total > $0.length } ?? false }

    func setColor(_ color: NSColor) {
        guard color != self.color else { return }
        self.color = color
        layoutKnob(animated: false)
    }

    /// New scroll state from the terminal; shows the pill when it moved.
    func update(_ bar: Scrollbar) {
        guard bar != self.bar else { return }
        let moved = self.bar.map { $0.offset != bar.offset } ?? false
        self.bar = bar
        layoutKnob(animated: dragging == nil)
        if !isScrollable {
            hideTask?.cancel()
            fade(to: 0)
        } else if moved {
            reveal()
        }
    }

    /// Shows the pill now and hides it after a quiet moment.
    func reveal() {
        guard isScrollable else { return }
        fade(to: 1)
        scheduleHide()
    }

    /// The pointer is near the right edge (or left it).
    func setHovering(_ near: Bool) {
        guard near != hovering else { return }
        hovering = near
        layoutKnob(animated: true)
        if near { reveal() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, self.dragging == nil else { return }
            self.fade(to: 0)
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: task)
    }

    private func fade(to alpha: CGFloat) {
        guard alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.12 : 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = alpha
        }
    }

    override func layout() {
        super.layout()
        layoutKnob(animated: false)
    }

    // MARK: Geometry

    private var track: CGRect {
        CGRect(x: 0, y: Self.inset.top, width: bounds.width, height: max(bounds.height - Self.inset.top - Self.inset.bottom, 0))
    }

    private func knobHeight(_ bar: Scrollbar) -> CGFloat {
        let track = track.height
        return min(track, max(Self.minKnob, track * CGFloat(Double(bar.length) / Double(max(bar.total, 1)))))
    }

    /// Top of the pill for a viewport offset.
    private func knobTop(_ bar: Scrollbar) -> CGFloat {
        let range = Double(bar.total - min(bar.length, bar.total))
        let travel = track.height - knobHeight(bar)
        let fraction = range > 0 ? Double(bar.offset) / range : 1
        return track.minY + travel * CGFloat(fraction)
    }

    private func layoutKnob(animated: Bool) {
        guard let bar, isScrollable else { return }
        let width = hovering || dragging != nil ? Self.wide : Self.thin
        let frame = CGRect(x: bounds.width - Self.inset.right - width, y: knobTop(bar), width: width, height: knobHeight(bar))
        CATransaction.begin()
        if animated {
            // Glide rather than jump between rows.
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        knob.frame = frame
        knob.cornerRadius = width / 2
        knob.backgroundColor = color.withAlphaComponent(hovering || dragging != nil ? 0.55 : 0.38).cgColor
        CATransaction.commit()
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        guard let bar, isScrollable else { return }
        let y = convert(event.locationInWindow, from: nil).y
        var top = knobTop(bar)
        let height = knobHeight(bar)
        if y < top || y > top + height {
            // Clicking the track jumps there, centered on the pointer.
            top = y - height / 2
            scroll(toKnobTop: top, bar)
        }
        dragging = (y, top)
        layoutKnob(animated: true)
        fade(to: 1)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = dragging, let bar else { return }
        let y = convert(event.locationInWindow, from: nil).y
        scroll(toKnobTop: drag.startTop + (y - drag.grabY), bar)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        layoutKnob(animated: true)
        scheduleHide()
    }

    private func scroll(toKnobTop top: CGFloat, _ bar: Scrollbar) {
        let travel = track.height - knobHeight(bar)
        guard travel > 0 else { return }
        let fraction = min(max((top - track.minY) / travel, 0), 1)
        let range = Double(bar.total - bar.length)
        onScroll?(UInt64((Double(fraction) * range).rounded()))
    }
}
