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
    private var leaderMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontRegistry.registerBundled()
        // The `den` CLI installs explicitly from the command palette, never
        // on launch. Panes still get the bundle's bin folder on PATH through
        // dend, so `den` works inside Den regardless.
        let model = AppModel(systemIsDark: Self.isDark(NSApp.effectiveAppearance))
        self.model = model
        NSApp.mainMenu = buildMenu(model)
        model.configDidChange = { [weak self, weak model] in
            guard let self, let model else { return }
            NSApp.mainMenu = buildMenu(model)
        }
        // Before any view sees the key, so the leader works wherever focus is.
        leaderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            let keyCode = event.keyCode, flags = event.modifierFlags
            let unmodified = event.characters(byApplyingModifiers: [])
            let used = MainActor.assumeIsolated {
                model?.handleKey(keyCode: keyCode, unmodified: unmodified, flags: flags) ?? false
            }
            return used ? nil : event
        }
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

    /// A menu item for a command, with its shortcut from the config.
    private func item(_ command: DenCommand, _ model: AppModel) -> NSMenuItem {
        let action = MenuAction { command.perform(model) }
        actions.append(action)
        // Menus can't show two-step shortcuts; leader ones run from the
        // leader monitor, and their label sits in the title instead.
        let trigger = model.config.shortcut(for: command)
        var title = command.title
        var chord: KeyChord?
        switch trigger {
        case .chord(let c)? where c.key == .digit: title += "    " + c.label
        case .chord(let c)?: chord = c
        case .leader?: title += "    " + (model.config.shortcutLabel(command) ?? "")
        case nil: break
        }
        let item = NSMenuItem(title: title, action: #selector(MenuAction.fire(_:)), keyEquivalent: chord?.keyEquivalent ?? "")
        item.keyEquivalentModifierMask = chord?.modifierFlags ?? []
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
        actions.removeAll()
        let main = NSMenu()
        let items: ([DenCommand?]) -> [NSMenuItem] = { commands in
            commands.map { $0.map { self.item($0, model) } ?? .separator() }
        }

        main.addItem(menu("Den", [
            NSMenuItem(title: "About Den", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
        ] + items([.commandPalette, .openConfig, .reloadConfig, .checkForUpdates, nil, .hide, .quit])))

        main.addItem(menu("File", items([.newTab, .newSession, .goToDirectory, .insertPath, nil, .closePane, .closeTab])))
        main.addItem(menu("Edit", items([.copy, .paste, .selectAll])))
        main.addItem(menu("View", items([
            .changeTheme, .changeFont, .fontBigger, .fontSmaller, .fontReset, nil,
            .toggleVerticalTabs, .toggleSidebar, .toggleActivityMode, .togglePaneHeaders, .toggleContrastCorrection, nil,
            .peek, .leavePeek, .showAllSessions, nil, .toggleFullScreen,
        ])))
        main.addItem(menu("Pane", items([
            .splitRight, .splitDown, nil, .zoomPane, .nextPane, .previousPane, nil,
            .movePaneLeft, .movePaneRight, .movePaneUp, .movePaneDown, nil,
            .focusPaneLeft, .focusPaneDown, .focusPaneUp, .focusPaneRight, nil,
            .resizePaneLeft, .resizePaneDown, .resizePaneUp, .resizePaneRight,
        ])))
        main.addItem(menu("Session", items([
            .changeSession, .renameSession, .renameTab, .tidyTabTitle, nil, .previousSession, .nextSession, nil,
            .goToSession, nil,
            .addRemoteHost, .closeSession,
        ])))
        let windowMenu = menu("Window", items([
            .nextTab, .previousTab, .moveTabLeft, .moveTabRight, nil,
            .goToTab, .lastTab, nil, .minimize,
        ]))
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)

        return main
    }
}
