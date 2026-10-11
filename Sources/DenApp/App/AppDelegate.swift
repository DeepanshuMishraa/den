import AppKit
import DenProtocol
import SwiftUI

/// Closure-backed menu item target.
@MainActor
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    // Not `perform(_:)`: that name resolves to NSObject's `performSelector:`,
    // which makes AppKit treat the menu item as a selector.
    @objc func fire(_ sender: Any?) { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var windowController: DenWindowController?
    private var actions: [MenuAction] = []
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontRegistry.registerBundled()
        let model = AppModel(systemIsDark: Self.isDark(NSApp.effectiveAppearance))
        self.model = model
        NSApp.mainMenu = buildMenu(model)
        let controller = DenWindowController(model: model)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()
        // AppKit reports appearance changes on the main thread.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated {
                model.systemAppearanceChanged(isDark: Self.isDark(NSApp.effectiveAppearance))
            }
        }
        Task {
            await model.connect()
            #if DEBUG
            await applyDebugUIState(model)
            #endif
        }
    }

    #if DEBUG
    /// Development aid: `DEN_DEBUG_UI=peek,vertical,theme:Velvet Dusk,tabs:3`
    /// opens the app in a given UI state so it can be inspected or captured.
    private func applyDebugUIState(_ model: AppModel) async {
        guard let spec = ProcessInfo.processInfo.environment["DEN_DEBUG_UI"] else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        for part in spec.split(separator: ",").map(String.init) {
            switch part {
            case "peek": model.overview = .peek
            case "expose": model.overview = .expose
            case "vertical": model.tabStyle = .vertical
            case "keytest":
                // Feeds shortcuts through the real menu matcher and logs whether
                // each one fired.
                for (chars, mods) in [("t", NSEvent.ModifierFlags.command), ("P", [.command, .shift]), ("d", .command), ("k", .command), ("=", .command), ("=", .command), ("=", .command), ("-", .command)] {
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                             windowNumber: NSApp.windows.first?.windowNumber ?? 0, context: nil,
                                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)
                    let handled = e.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
                    NSLog("Den keytest \(chars) handled=\(handled) fontSize=\(model.fontSize)")
                }
            case "palette": model.palette = .root
            case "themes": model.palette = .theme
            case "sessions": model.showSessionMenu = true
            case "split": model.split(.horizontal)
            case _ where part.hasPrefix("type:"):
                // Text with \n for Enter; e.g. type:printf '\\ue725\\n'\n
                let text = String(part.dropFirst(5)).replacingOccurrences(of: "\\n", with: "\r")
                if let pane = model.focused { model.input(pane, Data(text.utf8)) }
            case _ where part.hasPrefix("goto:"):
                let before = model.activeTab
                model.newTab(cwd: String(part.dropFirst(5)))
                try? await Task.sleep(for: .milliseconds(800))
                NSLog("Den goto: active changed=\(before != model.activeTab) isLast=\(model.activeTab == model.tabs.last?.id)")
            case "toast": model.showToast("Copied to clipboard")
            case _ where part.hasPrefix("style:"):
                if let s = InterfaceStyle(rawValue: String(part.dropFirst(6))) { model.interfaceStyle = s }
            case "compact": model.density = .compact
            case "comfortable": model.density = .comfortable
            case "styles": model.palette = .interfaceStyle
            case _ where part.hasPrefix("theme:"):
                let name = String(part.dropFirst(6))
                if let t = ThemeCatalog.named(name) { model.selectTheme(t) }
            case _ where part.hasPrefix("tabs:"):
                for _ in 0 ..< (Int(part.dropFirst(5)) ?? 0) {
                    model.newTab()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            case _ where part.hasPrefix("session:"):
                model.createSession(name: String(part.dropFirst(8)))
                try? await Task.sleep(for: .milliseconds(500))
            default: break
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }
    #endif

    nonisolated private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func applicationDidBecomeActive(_ notification: Notification) { model?.appBecameActive() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.showWindow(nil)
        return true
    }

    // MARK: Menu

    private func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        actions.append(action)
        // Shifted letters are matched against the shifted character, so ⇧⌘P
        // is written "P" (with .shift kept in the mask for clarity).
        let key = mods.contains(.shift) && key.count == 1 && key.first?.isLowercase == true ? key.uppercased() : key
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = action
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    private func buildMenu(_ model: AppModel) -> NSMenu {
        let main = NSMenu()
        let animate: (@escaping () -> Void) -> () -> Void = { body in { withAnimation(.den) { body() } } }

        main.addItem(menu("Den", [
            NSMenuItem(title: "About Den", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            item("Command Palette…", "p", [.command, .shift]) { model.palette = .root },
            .separator(),
            NSMenuItem(title: "Hide Den", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            NSMenuItem(title: "Quit Den", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))

        main.addItem(menu("File", [
            item("New Tab", "t") { model.newTab() },
            item("New Session", "n", [.command, .shift]) { model.createSession(name: "") },
            item("Go to Directory…", "g", [.command, .shift]) { model.palette = .goToDirectory },
            .separator(),
            item("Close", "w") { model.closeFocusedPane() },
            item("Close Tab", "w", [.command, .shift]) { model.activeTab.map(model.closeTab) },
        ]))

        main.addItem(menu("Edit", [
            NSMenuItem(title: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a"),
        ]))

        main.addItem(menu("View", [
            item("Change Theme…") { model.palette = .theme },
            item("Change Font…") { model.palette = .font },
            item("Bigger", "=") { model.adjustFontSize(1) },
            item("Smaller", "-") { model.adjustFontSize(-1) },
            item("Actual Size", "0") { model.resetFontSize() },
            .separator(),
            item("Toggle Vertical Tabs", "s", [.command, .control], animate { model.tabStyle = model.tabStyle == .horizontal ? .vertical : .horizontal }),
            item("Toggle Sidebar", "s", [.command, .option], animate { model.toggleSidebar() }),
            item("Toggle Pane Headers", "", [], animate { model.showPaneHeaders.toggle() }),
            .separator(),
            item("Peek at Tabs", String(UnicodeScalar(NSDownArrowFunctionKey).map(Character.init) ?? "↓"), [.command, .control], animate { model.stepOverview(1) }),
            item("Leave Peek", String(UnicodeScalar(NSUpArrowFunctionKey).map(Character.init) ?? "↑"), [.command, .control], animate { model.stepOverview(-1) }),
            item("Show All Sessions", "e", [.command, .control], animate { model.overview = model.overview == .expose ? .none : .expose }),
            .separator(),
            NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").with(mods: [.command, .control]),
        ]))

        main.addItem(menu("Pane", [
            item("Split Right", "d") { model.split(.horizontal) },
            item("Split Down", "d", [.command, .shift]) { model.split(.vertical) },
            .separator(),
            item("Zoom Pane", "\r", [.command, .shift]) { model.toggleZoom() },
            item("Next Pane", "]") { model.cyclePane(1) },
            item("Previous Pane", "[") { model.cyclePane(-1) },
        ]))

        main.addItem(menu("Session", [
            item("Change Session…", "k") { withAnimation(.denFast) { model.showSessionMenu.toggle() } },
            item("Rename Session…") { model.palette = .renameSession },
            item("Rename Tab…") { model.palette = .renameTab },
            .separator(),
            item("Previous Session", "[", [.command, .option]) { model.cycleSession(-1) },
            item("Next Session", "]", [.command, .option]) { model.cycleSession(1) },
            .separator(),
            item("Close Session") { model.currentSession.map(model.killSession) },
        ]))

        var windowItems = [
            item("Show Next Tab", "]", [.command, .shift]) { model.cycleTab(1) },
            item("Show Previous Tab", "[", [.command, .shift]) { model.cycleTab(-1) },
            item("Move Tab Left", "[", [.command, .shift, .option]) { model.moveActiveTab(-1) },
            item("Move Tab Right", "]", [.command, .shift, .option]) { model.moveActiveTab(1) },
            .separator(),
        ]
        for i in 1 ... 9 {
            windowItems.append(item("Tab \(i)", "\(i)") { model.selectTab(at: i == 9 ? max(model.tabs.count - 1, 0) : i - 1) })
        }
        windowItems.append(.separator())
        windowItems.append(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowMenu = menu("Window", windowItems)
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)

        return main
    }
}

extension NSMenuItem {
    func with(mods: NSEvent.ModifierFlags) -> NSMenuItem {
        keyEquivalentModifierMask = mods
        return self
    }
}
