import AppKit
import SwiftUI

/// Watches raw trackpad touches for Den's three-finger vertical swipe. The
/// overview follows the fingers continuously (`onOverviewDrag` with progress
/// in levels: +1 = one level deeper) and settles on release
/// (`onOverviewEnd`). Works anywhere in the window except the title bar,
/// where a three-finger drag moves the window as in every other app.
final class DenWindow: NSWindow {
    var onOverviewDrag: ((CGFloat) -> Void)?
    var onOverviewEnd: ((CGFloat) -> Void)?
    /// Fingers currently on the trackpad, from touch events.
    private(set) var touchCount = 0
    private var swipe = Swipe.idle
    /// A mouse drag synthesized from three fingers ("three finger drag") over
    /// the terminal is being dropped until its mouse up.
    private var swallowingDrag = false
    /// Set when a swipe starts mid-click-drag: the press already reached the
    /// terminal, so the drag and release that follow it are dropped too, or
    /// the half-started selection sticks around as a highlight.
    private var swallowUntilMouseUp = false

    private enum Swipe {
        case idle
        case tracking(startY: CGFloat, progress: CGFloat)
        /// The fingers are moving the window; ignored until they lift.
        case movingWindow
    }

    /// Swiping this fraction of the trackpad's height moves one level.
    private static let levelDistance: CGFloat = 0.28

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // However the move starts (our drag or the window server's), a moving
        // window must not also be opening the overview.
        NotificationCenter.default.addObserver(forName: NSWindow.willMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelSwipeForWindowMove() }
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .gesture, .beginGesture, .endGesture:
            track(event)
        case .leftMouseDown where isSwipeTracking || touchCount >= 3:
            // "Three finger drag" turns the swipe into a mouse drag. Over the
            // title bar it should move the window like anywhere else in
            // macOS; over the terminal it is the overview swipe, so drop it.
            // Only the swipe state and gesture-refresh counts here: querying
            // the device's live touches on a click also sees resting
            // palms/fingers and would swallow every normal click, breaking
            // text selection entirely.
            if isTitleBar(event.locationInWindow) {
                cancelSwipeForWindowMove()
            } else {
                swallowingDrag = true
                return
            }
        case .leftMouseDragged:
            if swallowingDrag || swallowUntilMouseUp { return }
        case .leftMouseUp:
            if swallowingDrag {
                swallowingDrag = false
                return
            }
            if swallowUntilMouseUp {
                swallowUntilMouseUp = false
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private func track(_ event: NSEvent) {
        let touches = event.touches(matching: .touching, in: nil)
        touchCount = touches.count
        // Normalized y grows upward; swiping down goes deeper.
        let y = touches.map(\.normalizedPosition.y).reduce(0, +) / CGFloat(max(touches.count, 1))
        switch swipe {
        case .movingWindow:
            if touches.isEmpty { swipe = .idle }
        case .idle:
            // Exactly three fingers start a swipe. One or two fingers never
            // do: two-finger scrolling over the title bar used to step into
            // peek and felt like a mis-triggered glance.
            if touches.count == 3 {
                swipe = .tracking(startY: y, progress: 0)
                // The press of a three-finger-drag click can reach the
                // terminal before this gesture event does; drop the rest of
                // that click so no half-started selection sticks.
                swallowUntilMouseUp = true
            }
        case .tracking(let startY, _) where touches.count == 3:
            let progress = (startY - y) / Self.levelDistance
            swipe = .tracking(startY: startY, progress: progress)
            onOverviewDrag?(progress)
        case .tracking(_, let progress):
            swipe = .idle
            onOverviewEnd?(progress)
        }
    }

    /// True while a three-finger swipe is in flight.
    private var isSwipeTracking: Bool {
        if case .tracking = swipe { return true }
        return false
    }

    private func cancelSwipeForWindowMove() {
        if case .tracking = swipe { onOverviewEnd?(0) }
        if touchCount > 0 { swipe = .movingWindow }
    }

    /// The tab bar or sidebar header: anything in the top band that isn't a
    /// live terminal (peek thumbnails count as terminal).
    private func isTitleBar(_ point: NSPoint) -> Bool {
        guard let content = contentView, point.y >= content.bounds.height - TitleBar.height else { return false }
        var view = content.hitTest(point)
        while let current = view {
            if current is TerminalView { return false }
            view = current.superview
        }
        return true
    }
}

/// A borderless-looking window whose title bar is Den's tab bar.
@MainActor
final class DenWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    /// The native window material behind untinted Classic.
    private let backdropBlur = NSVisualEffectView()
    /// Glass's Liquid Glass, tinted with the theme when the theme tint is on
    /// so dark themes don't read milky grey. Before macOS 26 it falls back to
    /// a frosted blur.
    private let backdropGlass: NSView = DenWindowController.makeGlass()

    private static func makeGlass() -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        return blur
    }

    init(model: AppModel) {
        self.model = model
        let window = DenWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Den"
        window.minSize = NSSize(width: 560, height: 340)
        window.tabbingMode = .disallowed
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrameAutosaveName("DenMainWindow")
        let host = NSHostingView(rootView: RootView().environment(model))
        host.allowedTouchTypes = [.indirect]
        // The window owns its size (minSize, autosave, user resizing). By
        // default the hosting view turns SwiftUI's min/ideal/max size into
        // Auto Layout constraints, so once the content loads the window snaps
        // to its height and that edge stops resizing.
        host.sizingOptions = []
        // Backdrop (glass or blur) sits under the SwiftUI content; which one
        // shows depends on the interface style.
        let container = NSView()
        container.allowedTouchTypes = [.indirect]
        for view in [backdropBlur, backdropGlass, host] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        backdropBlur.material = .hudWindow
        backdropBlur.blendingMode = .behindWindow
        backdropBlur.state = .active
        window.contentView = container
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
        // Follow the fingers 1:1; animate only the settle on release.
        window.onOverviewDrag = { [weak model] progress in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model?.dragOverview(progress) }
        }
        window.onOverviewEnd = { [weak model] progress in
            withAnimation(.den) { model?.endOverviewDrag(progress) }
        }
        positionTrafficLights()
        followTheme()
        followZenMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) {
        positionTrafficLights()
        model.windowBecameKey()
    }

    /// Keeps the window's appearance (traffic lights, materials, text
    /// fields) in step with the active theme.
    private func followTheme() {
        withObservationTracking {
            window?.appearance = model.theme.nsAppearance
            let backdrop = model.effectiveBackdrop
            backdropGlass.isHidden = backdrop != .glass
            backdropBlur.isHidden = backdrop != .system
            // Untinted Classic uses the native window background; Glass
            // frosts whatever is behind the window.
            backdropBlur.material = backdrop == .system ? .windowBackground : .hudWindow
            // Match the blur's light/dark rendering to the theme, not the system.
            backdropGlass.appearance = model.theme.nsAppearance
            backdropBlur.appearance = model.theme.nsAppearance
            if #available(macOS 26, *), let glass = backdropGlass as? NSGlassEffectView {
                glass.tintColor = model.themeTint ? model.theme.glassTint : nil
            }
            // Read so a layout switch also re-places the traffic lights.
            _ = model.tabStyle
            _ = model.density
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.followTheme()
                self?.refreshChrome()
            }
        }
    }

    /// Zen Mode fades the traffic lights out with the tab bar or sidebar
    /// they sit on, and back in when it's revealed.
    private func followZenMode() {
        withObservationTracking {
            let hidden = model.zenChromeHidden
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                for type in buttons {
                    window?.standardWindowButton(type)?.animator().alphaValue = hidden ? 0 : 1
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.followZenMode() }
        }
    }

    /// An appearance or layout change makes AppKit lay out the title bar
    /// again, which puts the traffic lights back at its default spot, and a
    /// clear window keeps the shadow of its old contents. Once now, and once
    /// after the change has animated in.
    private func refreshChrome() {
        for delay in [0.0, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.positionTrafficLights()
                self?.window?.invalidateShadow()
            }
        }
    }

    /// Centers the traffic lights vertically in the 40pt tab bar.
    private func positionTrafficLights() {
        guard let window, let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview?.superview else { return }
        let barHeight = TitleBar.height
        var frame = titlebar.frame
        frame.size.height = barHeight
        frame.origin.y = window.frame.height - barHeight
        titlebar.frame = frame
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type), let superview = button.superview else { continue }
            button.setFrameOrigin(NSPoint(
                x: 16 + CGFloat(i) * 20,
                y: (superview.bounds.height - button.frame.height) / 2
            ))
        }
    }
}
