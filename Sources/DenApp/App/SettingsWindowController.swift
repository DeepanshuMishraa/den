import AppKit
import SwiftUI

/// Den's Settings window. Everything in it reads and writes the same state
/// as the command palette and menus, and config.toml settings are written
/// to that file, so the window, the palette and the file always agree.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let backdropGlass: NSView = SettingsWindowController.makeGlass()

    private static func makeGlass() -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .behindWindow
        blur.state = .active
        return blur
    }

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Settings"
        window.minSize = NSSize(width: 520, height: 420)
        window.tabbingMode = .disallowed
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("DenSettingsWindow")
        let host = NSHostingView(rootView: SettingsView().environment(model))
        host.sizingOptions = []
        let container = NSView()
        for view in [backdropGlass, host] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container
        super.init(window: window)
        window.delegate = self
        followTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        model.isRecordingShortcut = false
    }

    /// Same appearance and backdrop as the main window: glass only for the
    /// Modern style, so Themed stays opaque and Blended frosted.
    private func followTheme() {
        withObservationTracking {
            window?.appearance = model.theme.nsAppearance
            backdropGlass.appearance = model.theme.nsAppearance
            backdropGlass.isHidden = model.effectiveInterfaceStyle.backdrop == .none
            if #available(macOS 26, *), let glass = backdropGlass as? NSGlassEffectView {
                glass.tintColor = model.theme.glassTint
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.followTheme() }
        }
    }
}
