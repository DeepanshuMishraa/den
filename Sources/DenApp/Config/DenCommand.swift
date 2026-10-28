import AppKit
import SwiftUI

/// Every action a shortcut can trigger. The raw value is the name used in
/// config.toml, under `[keys]` to change its shortcut or as a
/// `[[keys.bind]]` action.
enum DenCommand: String, CaseIterable {
    case commandPalette = "command_palette"
    case openSettings = "open_settings"
    case openConfig = "open_config"
    case reloadConfig = "reload_config"
    case checkForUpdates = "check_for_updates"
    case hide, quit

    case newTab = "new_tab"
    case newSession = "new_session"
    case goToDirectory = "go_to_directory"
    case insertPath = "insert_path"
    case closePane = "close_pane"
    case closeTab = "close_tab"

    case copy, paste
    case selectAll = "select_all"
    case find
    case findNext = "find_next"
    case findPrevious = "find_previous"
    case findTab = "find_tab"
    case findSession = "find_session"

    case changeTheme = "change_theme"
    case changeFont = "change_font"
    case fontBigger = "font_bigger"
    case fontSmaller = "font_smaller"
    case fontReset = "font_reset"
    case toggleVerticalTabs = "toggle_vertical_tabs"
    case toggleSidebar = "toggle_sidebar"
    case showSidebar = "show_sidebar"
    case hideSidebar = "hide_sidebar"
    case toggleActivityMode = "toggle_activity_mode"
    case toggleZenMode = "toggle_zen_mode"
    case togglePaneHeaders = "toggle_pane_headers"
    case toggleContrastCorrection = "toggle_contrast_correction"
    case peek
    case leavePeek = "leave_peek"
    case showAllSessions = "show_all_sessions"
    case toggleFullScreen = "toggle_fullscreen"

    case splitRight = "split_right"
    case splitDown = "split_down"
    case zoomPane = "zoom_pane"
    case nextPane = "next_pane"
    case previousPane = "previous_pane"
    case focusPaneLeft = "focus_pane_left"
    case focusPaneDown = "focus_pane_down"
    case focusPaneUp = "focus_pane_up"
    case focusPaneRight = "focus_pane_right"
    case resizePaneLeft = "resize_pane_left"
    case resizePaneDown = "resize_pane_down"
    case resizePaneUp = "resize_pane_up"
    case resizePaneRight = "resize_pane_right"
    case movePaneLeft = "move_pane_left"
    case movePaneRight = "move_pane_right"
    case movePaneUp = "move_pane_up"
    case movePaneDown = "move_pane_down"
    case movePaneToNewTab = "move_pane_to_new_tab"

    case addRemoteHost = "add_remote_host"
    case changeSession = "change_session"
    /// Bound to a digit key: the number picks the session (no upper limit).
    case goToSession = "go_to_session"
    case renameSession = "rename_session"
    case renameTab = "rename_tab"
    case tidyTabTitle = "tidy_tab_title"
    case previousSession = "previous_session"
    case nextSession = "next_session"
    case closeSession = "close_session"
    case nextHost = "next_host"
    case previousHost = "previous_host"

    case nextTab = "next_tab"
    case previousTab = "previous_tab"
    case moveTabLeft = "move_tab_left"
    case moveTabRight = "move_tab_right"
    /// Bound to a digit key: the number picks the tab (no upper limit).
    case goToTab = "go_to_tab"
    case lastTab = "last_tab"
    case minimize

    /// Commands whose key is a digit and that need its number to run.
    var takesNumber: Bool { self == .goToTab || self == .goToSession }

    var title: String {
        switch self {
        case .commandPalette: "Command Palette…"
        case .openSettings: "Settings…"
        case .openConfig: "Open Config File…"
        case .reloadConfig: "Reload Config"
        case .checkForUpdates: "Check for Updates…"
        case .hide: "Hide Den"
        case .quit: "Quit Den"
        case .newTab: "New Tab"
        case .newSession: "New Session"
        case .goToDirectory: "Go to Directory…"
        case .insertPath: "Insert Path…"
        case .closePane: "Close"
        case .closeTab: "Close Tab"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .find: "Find…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .findTab: "Find Tab…"
        case .findSession: "Find Session…"
        case .changeTheme: "Change Theme…"
        case .changeFont: "Change Terminal Font…"
        case .fontBigger: "Bigger"
        case .fontSmaller: "Smaller"
        case .fontReset: "Actual Size"
        case .toggleVerticalTabs: "Toggle Vertical Tabs"
        case .toggleSidebar: "Toggle Sidebar"
        case .showSidebar: "Show Sidebar"
        case .hideSidebar: "Hide Sidebar"
        case .toggleActivityMode: "Toggle Activity Mode"
        case .toggleZenMode: "Toggle Zen Mode"
        case .togglePaneHeaders: "Toggle Pane Headers"
        case .toggleContrastCorrection: "Toggle Automatic Contrast Correction"
        case .peek: "Peek at Tabs"
        case .leavePeek: "Leave Peek"
        case .showAllSessions: "Show All Sessions"
        case .toggleFullScreen: "Toggle Full Screen"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .zoomPane: "Zoom Pane"
        case .nextPane: "Next Pane"
        case .previousPane: "Previous Pane"
        case .focusPaneLeft: "Focus Pane Left"
        case .focusPaneDown: "Focus Pane Below"
        case .focusPaneUp: "Focus Pane Above"
        case .focusPaneRight: "Focus Pane Right"
        case .resizePaneLeft: "Move Pane Edge Left"
        case .resizePaneDown: "Move Pane Edge Down"
        case .resizePaneUp: "Move Pane Edge Up"
        case .resizePaneRight: "Move Pane Edge Right"
        case .movePaneLeft: "Move Pane Left"
        case .movePaneRight: "Move Pane Right"
        case .movePaneUp: "Move Pane Up"
        case .movePaneDown: "Move Pane Down"
        case .movePaneToNewTab: "Move Pane to New Tab"
        case .addRemoteHost: "Add Remote Host…"
        case .changeSession: "Change Session…"
        case .goToSession: "Go to Session…"
        case .renameSession: "Rename Session…"
        case .renameTab: "Rename Tab…"
        case .tidyTabTitle: "Tidy Tab Title"
        case .previousSession: "Previous Session"
        case .nextSession: "Next Session"
        case .closeSession: "Close Session"
        case .nextHost: "Next Machine"
        case .previousHost: "Previous Machine"
        case .nextTab: "Show Next Tab"
        case .previousTab: "Show Previous Tab"
        case .moveTabLeft: "Move Tab Left"
        case .moveTabRight: "Move Tab Right"
        case .goToTab: "Go to Tab…"
        case .lastTab: "Last Tab"
        case .minimize: "Minimize"
        }
    }

    /// Den's built-in shortcut, in config syntax.
    var defaultShortcut: String? {
        switch self {
        case .commandPalette: "cmd+shift+p"
        case .openSettings: "cmd+,"
        case .openConfig: "opt+cmd+,"
        case .reloadConfig: "cmd+shift+,"
        case .hide: "cmd+h"
        case .quit: "cmd+q"
        case .newTab: "leader+n"
        case .newSession: "leader+o"
        case .goToDirectory: "cmd+shift+g"
        case .insertPath: "cmd+o"
        case .closePane: "cmd+w"
        case .closeTab: "leader+w"
        case .copy: "cmd+c"
        case .paste: "cmd+v"
        case .selectAll: "cmd+a"
        case .find: "cmd+f"
        case .findNext: "cmd+g"
        // ⌘⇧G is Go to Directory; ⇧Return in the bar steps back.
        case .findPrevious: nil
        case .findTab: "cmd+t"
        case .findSession: "cmd+p"
        case .fontBigger: "cmd+="
        case .fontSmaller: "cmd+-"
        case .fontReset: "cmd+0"
        case .toggleVerticalTabs: "ctrl+cmd+s"
        case .toggleSidebar: "opt+cmd+s"
        case .toggleActivityMode: "cmd+shift+a"
        case .toggleZenMode: "ctrl+cmd+z"
        case .peek: "ctrl+cmd+down"
        case .leavePeek: "ctrl+cmd+up"
        case .showAllSessions: "ctrl+cmd+e"
        case .toggleFullScreen: "ctrl+cmd+f"
        case .splitRight: "leader+\\"
        case .splitDown: "leader+v"
        case .zoomPane: "leader+z"
        case .nextPane: "cmd+]"
        case .previousPane: "cmd+["
        case .focusPaneLeft: "leader+h"
        case .focusPaneDown: "leader+j"
        case .focusPaneUp: "leader+k"
        case .focusPaneRight: "leader+l"
        case .resizePaneLeft: "leader+shift+h"
        case .resizePaneDown: "leader+shift+j"
        case .resizePaneUp: "leader+shift+k"
        case .resizePaneRight: "leader+shift+l"
        case .movePaneLeft: "opt+cmd+left"
        case .movePaneRight: "opt+cmd+right"
        case .movePaneUp: "opt+cmd+up"
        case .movePaneDown: "opt+cmd+down"
        case .movePaneToNewTab: "leader+b"
        case .addRemoteHost: "leader+x"
        case .changeSession: "leader+s"
        case .renameTab: "leader+r"
        case .renameSession: "leader+shift+r"
        case .goToSession: "leader+digit"
        case .previousSession: "opt+cmd+["
        case .nextSession: "opt+cmd+]"
        case .nextHost: "leader+]"
        case .previousHost: "leader+["
        case .nextTab: "cmd+shift+]"
        case .previousTab: "cmd+shift+["
        case .moveTabLeft: "opt+cmd+shift+["
        case .moveTabRight: "opt+cmd+shift+]"
        case .goToTab: "cmd+digit"
        case .lastTab: nil
        case .minimize: "cmd+m"
        case .changeTheme, .changeFont, .showSidebar, .hideSidebar, .togglePaneHeaders, .toggleContrastCorrection, .tidyTabTitle, .closeSession, .checkForUpdates: nil
        }
    }

    /// Runs a numbered command for target `number` (1-based).
    @MainActor
    func perform(_ model: AppModel, number: Int) {
        switch self {
        case .goToTab:
            if number >= 1, number <= model.tabs.count { model.selectTab(at: number - 1) }
        case .goToSession: model.goToSession(number)
        default: perform(model)
        }
    }

    @MainActor
    func perform(_ model: AppModel) {
        let animated: (() -> Void) -> Void = { body in withAnimation(.den) { body() } }
        switch self {
        case .commandPalette: model.palette = .root
        case .openSettings: model.showSettings?()
        case .openConfig: model.openConfigFile()
        case .reloadConfig: model.reloadConfig(force: true)
        case .checkForUpdates: model.checkForUpdates()
        case .hide: NSApp.hide(nil)
        case .quit: NSApp.terminate(nil)
        case .newTab: model.newTab()
        case .newSession: model.createSession(name: "")
        case .goToDirectory: model.palette = .goToDirectory
        case .insertPath: model.openPathPicker()
        case .closePane: model.closeFocusedPane()
        case .closeTab: model.activeTab.map(model.closeTab)
        case .copy: NSApp.sendAction(#selector(TerminalView.copy(_:)), to: nil, from: nil)
        case .paste: NSApp.sendAction(#selector(TerminalView.paste(_:)), to: nil, from: nil)
        case .selectAll: NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
        case .find: model.openFind()
        case .findNext: model.find == nil ? model.openFind() : model.stepFind(-1)
        case .findPrevious: model.find == nil ? model.openFind() : model.stepFind(1)
        case .findTab: model.palette = .findTab
        case .findSession: model.palette = .changeSession
        case .changeTheme: model.palette = .theme
        case .changeFont: model.palette = .terminalFont
        case .fontBigger: model.adjustFontSize(1)
        case .fontSmaller: model.adjustFontSize(-1)
        case .fontReset: model.resetFontSize()
        case .toggleVerticalTabs: animated { model.tabStyle = model.tabStyle == .horizontal ? .vertical : .horizontal }
        case .toggleSidebar: animated { model.toggleSidebar() }
        case .showSidebar: animated { model.showSidebar() }
        case .hideSidebar: animated { model.hideSidebar() }
        case .toggleActivityMode:
            // Horizontal tabs show activity in the eye button's dropdown.
            if model.tabStyle == .horizontal {
                withAnimation(.denFast) { model.showActivityMenu.toggle() }
            } else {
                animated { model.toggleActivityMode() }
            }
        case .toggleZenMode: animated { model.zenMode.toggle() }
        case .togglePaneHeaders: animated { model.showPaneHeaders.toggle() }
        case .toggleContrastCorrection: model.contrastCorrection.toggle()
        case .peek: animated { model.stepOverview(1) }
        case .leavePeek: animated { model.stepOverview(-1) }
        case .showAllSessions: animated { model.overview = model.overview == .expose ? .none : .expose }
        case .toggleFullScreen: NSApp.keyWindow?.toggleFullScreen(nil)
        case .splitRight: model.split(.horizontal)
        case .splitDown: model.split(.vertical)
        case .zoomPane: model.toggleZoom()
        case .nextPane: model.cyclePane(1)
        case .previousPane: model.cyclePane(-1)
        case .focusPaneLeft: model.focusPane(.left)
        case .focusPaneDown: model.focusPane(.down)
        case .focusPaneUp: model.focusPane(.up)
        case .focusPaneRight: model.focusPane(.right)
        case .resizePaneLeft: model.resizePane(.left)
        case .resizePaneDown: model.resizePane(.down)
        case .resizePaneUp: model.resizePane(.up)
        case .resizePaneRight: model.resizePane(.right)
        case .movePaneLeft: animated { model.moveFocusedPane(.left) }
        case .movePaneRight: animated { model.moveFocusedPane(.right) }
        case .movePaneUp: animated { model.moveFocusedPane(.up) }
        case .movePaneDown: animated { model.moveFocusedPane(.down) }
        case .movePaneToNewTab: model.moveFocusedPaneToNewTab()
        case .addRemoteHost: model.palette = .addHost
        case .changeSession: withAnimation(.denFast) { model.showSessionMenu.toggle() }
        // Without a number (menu, palette) start with the session picker.
        case .goToSession: withAnimation(.denFast) { model.showSessionMenu = true }
        case .renameSession: model.palette = .renameSession
        case .renameTab: model.palette = .renameTab
        case .tidyTabTitle: model.tidyTabTitle()
        case .previousSession: model.cycleSession(-1)
        case .nextSession: model.cycleSession(1)
        case .closeSession: model.currentSession.map(model.killSession)
        case .nextHost: model.cycleHost(1)
        case .previousHost: model.cycleHost(-1)
        case .nextTab: model.cycleTab(1)
        case .previousTab: model.cycleTab(-1)
        case .moveTabLeft: model.moveActiveTab(-1)
        case .moveTabRight: model.moveActiveTab(1)
        case .lastTab: model.selectTab(at: max(model.tabs.count - 1, 0))
        case .goToTab: break
        case .minimize: NSApp.keyWindow?.performMiniaturize(nil)
        }
    }
}
