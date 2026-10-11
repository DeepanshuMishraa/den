import AppKit
import SwiftUI

/// Watches raw trackpad touches for Den's three-finger vertical swipe. The
/// overview follows the fingers continuously (`onOverviewDrag` with progress
/// in levels: +1 = one level deeper) and settles on release
/// (`onOverviewEnd`). Works anywhere in the window.
final class DenWindow: NSWindow {
    var onOverviewDrag: ((CGFloat) -> Void)?
    var onOverviewEnd: ((CGFloat) -> Void)?
    /// Fingers currently on the trackpad, from touch events.
    private(set) var touchCount = 0
    private var startY: CGFloat?
    private var progress: CGFloat = 0
    /// A mouse drag synthesized from three fingers ("three finger drag") is
    /// being dropped until its mouse up.
    private var swallowingDrag = false

    /// Swiping this fraction of the trackpad's height moves one level.
    private static let levelDistance: CGFloat = 0.28

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .gesture, .beginGesture, .endGesture:
            track(event)
        case .leftMouseDown:
            // "Three finger drag" turns the swipe into a mouse drag, which
            // would move the window from the title bar. Swallow all of it.
            if touchCount >= 3 || startY != nil {
                swallowingDrag = true
                return
            }
        case .leftMouseDragged:
            if swallowingDrag { return }
        case .leftMouseUp:
            if swallowingDrag {
                swallowingDrag = false
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
        // The window server can drag a window by its title bar without the
        // app seeing the mouse events, so lock the window itself.
        isMovable = touches.count < 3 && startY == nil
        if touches.count == 3 {
            // Normalized y grows upward; swiping down goes deeper.
            let y = touches.map(\.normalizedPosition.y).reduce(0, +) / 3
            if startY == nil { startY = y }
            progress = ((startY ?? y) - y) / Self.levelDistance
            onOverviewDrag?(progress)
            return
        }
        guard startY != nil else { return }
        startY = nil
        isMovable = true
        onOverviewEnd?(progress)
        progress = 0
    }
}

/// A borderless-looking window whose title bar is Den's tab bar.
@MainActor
final class DenWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel
    /// Behind-window blur used by Modern and Blended. The SwiftUI layers above
    /// it carry the theme color at partial opacity, so the desktop's color
    /// tints through while the window stays as dark (or light) as the theme.
    /// (NSGlassEffectView reads as milky grey over dark themes, unlike Superlogical's Rex.)
    private let backdropBlur = NSVisualEffectView()
    private let backdropGlass = NSVisualEffectView()

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
        for blur in [backdropBlur, backdropGlass] {
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
        }
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }

    /// Keeps the window's appearance (traffic lights, materials, text
    /// fields) in step with the active theme.
    private func followTheme() {
        withObservationTracking {
            window?.appearance = model.theme.nsAppearance
            let backdrop = model.effectiveInterfaceStyle.backdrop
            backdropGlass.isHidden = backdrop != .glass
            backdropBlur.isHidden = backdrop != .blur
            // Match the blur's light/dark rendering to the theme, not the system.
            backdropGlass.appearance = model.theme.nsAppearance
            backdropBlur.appearance = model.theme.nsAppearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTheme() }
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
