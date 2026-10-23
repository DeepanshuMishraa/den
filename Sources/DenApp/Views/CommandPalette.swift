import AppKit
import DenProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Which list the palette shows. Submenus appear as a chip in the field.
enum PaletteRoute: Equatable {
    case root, theme, interfaceStyle, font, shell, cursorBlink, changeSession, findTab, renameSession, renameTab, goToDirectory, addHost, deleteTheme
    /// Not a list: shows the Ghostty migration's progress.
    case migrateGhostty
    case renameHost(RemoteHost.ID)

    var chip: String? {
        switch self {
        case .root, .migrateGhostty, .findTab: nil
        case .theme: "Theme"
        case .font: "Font"
        case .shell: "Shell"
        case .cursorBlink: "Cursor Blinking"
        case .interfaceStyle: "Interface Style"
        case .changeSession: "Session"
        case .renameSession, .renameTab: "Rename"
        case .renameHost: "Rename Host"
        case .goToDirectory: nil
        case .addHost: "Add Host"
        case .deleteTheme: "Delete Theme"
        }
    }

    var placeholder: String {
        switch self {
        case .root: "Search commands…"
        case .theme: "Select Theme…"
        case .font: "Select Font…"
        case .shell: "Select Shell…"
        case .cursorBlink: "Filter blink settings…"
        case .interfaceStyle: "Select Interface Style…"
        case .changeSession: "Search sessions…"
        case .findTab: "Search tabs…"
        case .renameSession: "Session name"
        case .renameTab: "Tab title"
        case .renameHost: "Host name"
        case .goToDirectory: "Path"
        case .addHost: "user@host, 100.x.y.z or machine.tailnet.ts.net"
        case .deleteTheme: "Select a custom theme…"
        case .migrateGhostty: ""
        }
    }
}

struct PaletteItem: Identifiable {
    enum Action {
        case run(@MainActor () -> Void)
        case push(PaletteRoute)
    }

    let id: String
    var section: String?
    var sectionIcon: String?
    var icon: String?
    let title: String
    /// A second line under the title, e.g. where a tab lives.
    var subtitle: String?
    var subtitleIcon: String?
    /// A tab's program icons, drawn in place of `icon`.
    var deck: [ProgramKind]?
    var detail: String?
    var shortcut: String?
    var checked = false
    var submenu = false
    /// Keeps the palette open after running (toggles).
    var keepOpen = false
    var theme: Theme?
    var interfaceStyle: InterfaceStyle?
    /// A saved host: the row shows rename and remove on hover.
    var host: RemoteHost.ID?
    let action: Action
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    /// fsearch's folder matches for Go to Directory, refreshed as you type.
    @State private var folderHits: [PathEntry] = []
    /// Go to Directory on a remote host: the folder its dend listed, keyed
    /// by the path as typed so a stale reply isn't shown for a new query.
    @State private var remoteListing: (requested: String, path: String, entries: [DirectoryEntry])?
    /// Where the palette was opened; escaping from there closes it.
    @State private var openedAt = PaletteRoute.root
    @FocusState private var focused: Bool

    /// The model is the source of truth so the first frame already shows
    /// the right list.
    private var route: PaletteRoute { model.palette ?? .root }

    var body: some View {
        if route == .migrateGhostty, let run = model.ghosttyMigration {
            GhosttyMigrationPanel(run: run, theme: model.theme, openConfig: {
                close()
                model.openConfigFile()
            }, done: close)
            .padding(6)
            .frame(width: 440)
            .background(MenuSurface(theme: model.theme))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear(perform: enter)
            .onKeyPress(.return) {
                guard run.phase != .running else { return .ignored }
                close()
                return .handled
            }
            .onKeyPress(.escape) { close(); return .handled }
        } else {
            list
        }
    }

    private var list: some View {
        let theme = model.theme
        let items = visibleItems
        return VStack(alignment: .leading, spacing: 4) {
            field(theme)
            if items.isEmpty {
                Text(emptyHint)
                    .uiFont(size: 13)
                    .foregroundStyle(theme.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                VStack(alignment: .leading, spacing: 1) {
                                    if query.trimmingCharacters(in: .whitespaces).isEmpty, let section = item.section, index == 0 || items[index - 1].section != section {
                                        SectionHeader(title: section, icon: item.sectionIcon, theme: theme)
                                    }
                                    row(item, highlighted: index == selection)
                                        .contentShape(Rectangle())
                                        .onTapGesture { activate(items[index]) }
                                        .onHover { if $0 { select(index, items) } }
                                }
                                .id(index)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 440)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
            if route == .findTab || route == .changeSession { footer(theme) }
        }
        .padding(6)
        .frame(width: 440)
        .background(MenuSurface(theme: theme))
        .onAppear(perform: enter)
        .onChange(of: model.palette) { enter() }
        .task(id: route == .goToDirectory ? query : "") {
            guard route == .goToDirectory else { return }
            folderHits = []
            let host = model.currentHost
            if host != .local {
                let parent = Self.remoteParent(query)
                guard remoteListing?.requested != parent else { return }
                guard let (path, entries) = await model.listDirectory(parent, on: host), !Task.isCancelled else { return }
                remoteListing = (parent, path, entries)
                return
            }
            let parsed = PathQuery.parse(query)
            // A typed folder lists its own children; fsearch is for bare names.
            guard parsed.directory == nil, !parsed.fragment.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, case .success(let hits) = await PathSearch.shared.search(parsed.fragment, foldersOnly: true, limit: 120),
                  !Task.isCancelled else { return }
            folderHits = Array(PathEntry.ranked(hits, matching: parsed.fragment, under: parsed.directory ?? NSHomeDirectory()).prefix(30))
        }
        .onChange(of: query) {
            selection = 0
            if route == .theme || route == .interfaceStyle { previewSelection(visibleItems) }
        }
        .onKeyPress(.downArrow) { select(min(selection + 1, items.count - 1), items); return .handled }
        .onKeyPress(.upArrow) { select(max(selection - 1, 0), items); return .handled }
        .onKeyPress(.escape) { back(); return .handled }
        .onKeyPress(.tab) {
            guard route == .goToDirectory, items.indices.contains(selection) else { return .ignored }
            query = items[selection].id.hasSuffix("/") ? items[selection].id : items[selection].id + "/"
            return .handled
        }
    }

    // MARK: Field

    private func field(_ theme: Theme) -> some View {
        HStack(spacing: 7) {
            if let chip = route.chip {
                Text(chip)
                    .uiFont(size: 12, weight: .semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)))
                    .foregroundStyle(theme.chromeText)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(theme.tertiaryText)
            }
            TextField(route.placeholder, text: $query)
                .textFieldStyle(.plain)
                .uiFont(size: 13.5)
                .focused($focused)
                .onSubmit {
                    let items = visibleItems
                    if items.indices.contains(selection) { activate(items[selection]) }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.tertiaryText)
                }
                .buttonStyle(.hitArea)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.hover))
    }

    private var emptyHint: String {
        switch route {
        case .addHost: "Type an SSH address; Den installs dend there"
        case .goToDirectory: "No folders match"
        default: "No matches"
        }
    }

    // MARK: Rows

    private func row(_ item: PaletteItem, highlighted: Bool) -> some View {
        let theme = model.theme
        let fg = highlighted ? theme.onAccent : theme.chromeText
        let dim = highlighted ? theme.onAccent.opacity(0.75) : theme.tertiaryText
        let hits = route == .root || route == .theme || route == .font || route == .shell || route == .interfaceStyle || route == .changeSession || route == .findTab ? (Fuzzy.match(query, in: item.title) ?? []) : []
        return HStack(spacing: item.subtitle == nil ? 8 : 10) {
            if let deck = item.deck {
                DeckIcon(deck: deck, height: 18)
                    .frame(width: 22)
            } else if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: item.subtitle == nil ? 12 : 13.5))
                    .foregroundStyle(icon == "folder.fill" && !highlighted ? Color(.sRGB, red: 0.33, green: 0.62, blue: 0.96) : fg)
                    .frame(width: item.subtitle == nil ? 16 : 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Fuzzy.highlighted(item.title, hits: hits, base: fg, accent: highlighted ? fg : theme.accent)
                    .uiFont(size: 13.5, weight: item.subtitle == nil ? .regular : .medium)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    HStack(spacing: 4) {
                        if let icon = item.subtitleIcon { Image(systemName: icon).font(.system(size: 10)) }
                        Text(subtitle).uiFont(size: 11.5).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(highlighted ? theme.onAccent.opacity(0.8) : theme.secondaryText)
                }
            }
            Spacer(minLength: 10)
            if let detail = item.detail {
                Text(detail).uiFont(size: 12.5).foregroundStyle(dim).lineLimit(1).truncationMode(.head)
            }
            if let shortcut = item.shortcut {
                Text(shortcut).uiFont(size: 12).foregroundStyle(dim)
            }
            if item.checked {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
            }
            if item.submenu {
                Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(dim)
            }
            if let host = item.host, highlighted {
                HostActions(host: host, color: fg) { model.palette = .renameHost(host) }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: item.subtitle == nil ? 30 : 44)
        .background(RoundedRectangle(cornerRadius: item.subtitle == nil ? 7 : 9, style: .continuous).fill(highlighted ? theme.accent : .clear))
    }

    // MARK: Behavior

    private func enter() {
        guard let target = model.palette else { return }
        if !hasEntered {
            openedAt = target
            hasEntered = true
        }
        selection = 0
        KeyboardFocus.takeFromTerminal { focused = true }
        switch target {
        case .renameSession: query = model.currentSummary?.name ?? ""
        case .renameTab: query = model.activeLayout.map(model.tabTitle) ?? ""
        case .renameHost(let id): query = model.remoteHost(id)?.name ?? ""
        case .goToDirectory: query = (model.cwd(of: model.focused) ?? (model.currentHost == .local ? FileManager.default.homeDirectoryForCurrentUser.path : "~")) + "/"
        case .theme:
            query = ""
            selection = model.themesForCurrentAppearance.firstIndex { $0.name == model.selectedThemeName } ?? 0
        case .interfaceStyle:
            query = ""
            selection = InterfaceStyle.allCases.firstIndex(of: model.interfaceStyle) ?? 0
        default: query = ""
        }
    }

    @State private var hasEntered = false

    private func back() {
        if route == .theme { model.previewTheme = nil }
        if route == .interfaceStyle { model.previewInterfaceStyle = nil }
        if route == .root || route == openedAt {
            close()
        } else {
            model.palette = .root
        }
    }

    private func close() {
        model.previewTheme = nil
        model.palette = nil
    }

    private func select(_ index: Int, _ items: [PaletteItem]) {
        selection = index
        if route == .theme || route == .interfaceStyle { previewSelection(items) }
    }

    /// Themes and interface styles preview live as the selection moves.
    private func previewSelection(_ items: [PaletteItem]) {
        guard items.indices.contains(selection) else { return }
        if let t = items[selection].theme { model.previewTheme = t }
        if let s = items[selection].interfaceStyle { model.previewInterfaceStyle = s }
    }

    private func activate(_ item: PaletteItem) {
        switch item.action {
        case .push(let next):
            model.palette = next
        case .run(let action):
            action()
            if !item.keepOpen { close() }
        }
    }

    // MARK: Items

    private var visibleItems: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch route {
        case .migrateGhostty: return []
        case .root, .theme, .interfaceStyle, .font, .shell, .cursorBlink, .changeSession, .findTab, .deleteTheme:
            let all = items(for: route)
            guard !q.isEmpty else { return all }
            // Tabs also match by the session and host they're in.
            return Fuzzy.filter(all, query: q) { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: " ") }
        case .renameSession:
            guard !q.isEmpty, let id = model.currentSession else { return [] }
            return [PaletteItem(id: "rename", title: "Rename session to “\(q)”", shortcut: "↩", action: .run { model.renameSession(id, to: q) })]
        case .renameTab:
            guard let tab = model.activeTab else { return [] }
            if q.isEmpty {
                return [PaletteItem(id: "reset", title: "Use the program's title", shortcut: "↩", action: .run { model.renameTab(tab, to: nil) })]
            }
            return [PaletteItem(id: "rename", title: "Rename tab to “\(q)”", shortcut: "↩", action: .run { model.renameTab(tab, to: q) })]
        case .renameHost(let id):
            guard let host = model.remoteHost(id) else { return [] }
            if q.isEmpty {
                return [PaletteItem(id: "reset", title: "Use the address", detail: host.destination, shortcut: "↩",
                                    action: .run { model.renameRemoteHost(id, to: nil) })]
            }
            return [PaletteItem(id: "rename", title: "Rename host to “\(q)”", detail: host.destination, shortcut: "↩",
                                action: .run { model.renameRemoteHost(id, to: q) })]
        case .addHost:
            let saved = model.remoteHosts.map { host in
                PaletteItem(id: "host-\(host.id)", section: "Saved Hosts", sectionIcon: "server.rack", icon: "server.rack", title: host.label,
                            detail: model.remoteStates[host.id].map(HostStatus.short), host: host.id,
                            action: .run { model.toggleHost(host.id) })
            }
            guard !q.isEmpty else { return saved }
            let connect = PaletteItem(id: "connect", icon: "network", title: "Connect to “\(q)”", shortcut: "↩", action: .run { model.addRemoteHost(q) })
            return [connect] + Fuzzy.filter(saved, query: q, key: \.title)
        case .goToDirectory:
            return directoryItems(query)
        }
    }

    private func items(for route: PaletteRoute) -> [PaletteItem] {
        switch route {
        case .theme:
            var items = model.themesForCurrentAppearance.map { t in
                PaletteItem(id: "theme-\(t.name)", title: t.name, detail: t.isCustom ? "Custom" : nil,
                            checked: t.name == model.selectedThemeName, theme: t, action: .run { model.selectTheme(t) })
            }
            items.append(PaletteItem(id: "open-themes-folder", icon: "folder", title: "Open Themes Folder…",
                                     detail: PathQuery.abbreviate(UserConfig.themesDirectory.path),
                                     action: .run { NSWorkspace.shared.open(UserConfig.themesDirectory) }))
            for (i, error) in model.themeFileErrors.enumerated() {
                items.append(PaletteItem(id: "theme-error-\(i)", icon: "exclamationmark.triangle", title: error.file,
                                         detail: error.message, action: .run { model.report(error.description) }))
            }
            return items
        case .font:
            var families = FontRegistry.monospacedFamilies()
            if !families.contains(FontRegistry.bundledFamily) { families.insert(FontRegistry.bundledFamily, at: 0) }
            return families.map { family in
                PaletteItem(id: "font-\(family)", title: family,
                            detail: family == FontRegistry.bundledFamily ? "Built in" : nil,
                            checked: family == model.fontFamily, action: .run { model.fontFamily = family })
            }
        case .interfaceStyle:
            return InterfaceStyle.allCases.map { style in
                PaletteItem(id: "style-\(style.rawValue)", title: style.title, checked: style == model.interfaceStyle,
                            interfaceStyle: style, action: .run {
                                model.interfaceStyle = style
                                model.previewInterfaceStyle = nil
                            })
            }
        case .cursorBlink:
            // Picks stay open and apply at once: the pane behind shows them.
            var items = [PaletteItem(id: "blink-on", title: "Blinking", checked: model.cursorBlink, keepOpen: true,
                                     action: .run { model.cursorBlink.toggle() })]
            items += CursorBlink.Speed.allCases.map { speed in
                PaletteItem(id: "blink-speed-\(speed.rawValue)", section: "Speed", title: speed.title,
                            detail: String(format: "%.2gs cycle", speed.seconds),
                            checked: model.cursorBlinkStyle.speed == speed, keepOpen: true, action: .run {
                                model.cursorBlinkStyle.speed = speed
                                model.cursorBlink = true
                            })
            }
            items += CursorBlink.Transition.allCases.map { transition in
                PaletteItem(id: "blink-transition-\(transition.rawValue)", section: "Transition", title: transition.title,
                            detail: transition == .instant ? "No fade" : String(format: "%.2gs fade", transition.seconds),
                            checked: model.cursorBlinkStyle.transition == transition, keepOpen: true, action: .run {
                                model.cursorBlinkStyle.transition = transition
                                model.cursorBlink = true
                            })
            }
            items += CursorBlink.Pause.allCases.map { pause in
                PaletteItem(id: "blink-pause-\(pause.rawValue)", section: "Pause After Typing", title: pause.title,
                            detail: pause == .none ? "Blinks at once" : String(format: "%.2gs solid", pause.seconds),
                            checked: model.cursorBlinkStyle.pause == pause, keepOpen: true, action: .run {
                                model.cursorBlinkStyle.pause = pause
                                model.cursorBlink = true
                            })
            }
            return items
        case .shell:
            let current = model.defaultShell
            return model.availableShells.map { path in
                PaletteItem(id: "shell-\(path)", icon: "terminal", title: (path as NSString).lastPathComponent, detail: path,
                            checked: path == current, action: .run { model.setDefaultShell(path) })
            }
        case .changeSession:
            // Numbers count the machine on screen, like go_to_session.
            let here = model.sessions(on: model.currentHost).map(\.id)
            return model.orderedSessions.map { s in
                let tabs = model.tabs(in: s.id)
                let host = model.sessionHosts[s.id] ?? .local
                let number = here.firstIndex(of: s.id).map { $0 + 1 }
                return PaletteItem(id: "session-\(s.id)", title: s.name,
                                   subtitle: "\(model.hostLabel(host)) · \(tabs.count) \(tabs.count == 1 ? "tab" : "tabs")",
                                   subtitleIcon: Self.hostIcon(host), deck: tabs.first.map(model.deck),
                                   shortcut: number.flatMap { model.config.shortcutLabel(.goToSession, number: $0) }, checked: s.id == model.currentSession,
                                   action: .run { model.switchSession(s.id) })
            }
        case .findTab:
            return model.orderedSessions.flatMap { s in
                let host = model.sessionHosts[s.id] ?? .local
                return model.tabs(in: s.id).map { tab in
                    PaletteItem(id: "tab-\(tab.id)", title: model.tabTitle(tab),
                                subtitle: "\(model.hostLabel(host)) › \(s.name)", subtitleIcon: Self.hostIcon(host),
                                deck: model.deck(for: tab), checked: s.id == model.currentSession && tab.id == model.activeTab,
                                action: .run { withAnimation(.denFast) { model.selectTab(tab.id) } })
                }
            }
        case .deleteTheme:
            // Dual-variant files appear once: both variants share one file.
            var seen: Set<String> = []
            return model.customThemes.compactMap { t in
                guard seen.insert(t.name).inserted else { return nil }
                return PaletteItem(id: "delete-\(t.name)", icon: "trash", title: t.name, action: .run { model.deleteCustomTheme(t) })
            }
        default:
            return rootItems
        }
    }

    /// The command's current shortcut label, as the config sets it.
    private func key(_ command: DenCommand) -> String? {
        model.config.shortcutLabel(command)
    }

    private var rootItems: [PaletteItem] {
        let session = model.currentSummary?.name
        let tabTitle = model.activeLayout.map(model.tabTitle)
        let cwd = model.cwd(of: model.focused).map { model.abbreviate($0, on: model.currentHost) }
        var items: [PaletteItem] = [
            PaletteItem(id: "change-session", title: "Change Session", detail: session, submenu: true, action: .push(.changeSession)),
            PaletteItem(id: "rename-session", title: "Rename Session", detail: session, submenu: true, action: .push(.renameSession)),
            PaletteItem(id: "rename-tab", title: "Rename Tab", detail: tabTitle, submenu: true, action: .push(.renameTab)),
            PaletteItem(id: "add-host", icon: "network", title: "Add Remote Host…", submenu: true, action: .push(.addHost)),
            PaletteItem(id: "find-tab", icon: "rectangle.stack", title: "Find Tab…", shortcut: key(.findTab), submenu: true, action: .push(.findTab)),
            PaletteItem(id: "find", icon: "magnifyingglass", title: "Find in Tab…", shortcut: key(.find),
                        action: .run { DispatchQueue.main.async { model.openFind() } }),
            PaletteItem(id: "new-session", title: "New Session", shortcut: key(.newSession), action: .run { model.createSession(name: "") }),
            PaletteItem(id: "new-tab", title: "New Tab", shortcut: key(.newTab), action: .run { model.newTab() }),
            PaletteItem(id: "insert-path", icon: "text.insert", title: "Insert Path…", shortcut: key(.insertPath),
                        // After the palette hands focus back to the terminal.
                        action: .run { DispatchQueue.main.async { model.openPathPicker() } }),
            PaletteItem(id: "goto", icon: "folder", title: "Go to Directory…", detail: cwd, shortcut: key(.goToDirectory), submenu: true, action: .push(.goToDirectory)),
            PaletteItem(id: "close-tab", title: "Close Tab", shortcut: key(.closeTab), action: .run { model.activeTab.map(model.closeTab) }),
            PaletteItem(id: "prev-session", title: "Previous Session", action: .run { model.cycleSession(-1) }),
            PaletteItem(id: "next-session", title: "Next Session", action: .run { model.cycleSession(1) }),
            PaletteItem(id: "prev-tab", title: "Show Previous Tab", shortcut: key(.previousTab), action: .run { model.cycleTab(-1) }),
            PaletteItem(id: "next-tab", title: "Show Next Tab", shortcut: key(.nextTab), action: .run { model.cycleTab(1) }),
            PaletteItem(id: "move-tab-left", title: "Move Tab Left", shortcut: key(.moveTabLeft), action: .run { model.moveActiveTab(-1) }),
            PaletteItem(id: "move-tab-right", title: "Move Tab Right", shortcut: key(.moveTabRight), action: .run { model.moveActiveTab(1) }),
            PaletteItem(id: "tidy", title: "Tidy Tab Title", action: .run { model.tidyTabTitle() }),
            PaletteItem(id: "close-session", title: "Close Session", action: .run { model.currentSession.map(model.killSession) }),
        ]
        let paneSpecs: [(String, String, String?, @MainActor () -> Void)] = [
            ("split-right", "Split Pane Right", key(.splitRight), { model.split(.horizontal) }),
            ("split-down", "Split Pane Down", key(.splitDown), { model.split(.vertical) }),
            ("focus-next", "Focus Next Pane", key(.nextPane), { model.cyclePane(1) }),
            ("focus-prev", "Focus Previous Pane", key(.previousPane), { model.cyclePane(-1) }),
            ("zoom", "Zoom Pane", key(.zoomPane), { model.toggleZoom() }),
            ("close-pane", "Close Pane", key(.closePane), { model.closeFocusedPane() }),
        ]
        let pane = paneSpecs.map { id, title, key, run in
            PaletteItem(id: id, section: "Pane", sectionIcon: "rectangle.split.2x2", title: title, shortcut: key, action: .run(run))
        }
        items += pane

        var view: [PaletteItem] = [
            PaletteItem(id: "change-theme", title: "Change Theme", detail: model.selectedThemeName, submenu: true, action: .push(.theme)),
            PaletteItem(id: "change-font", title: "Change Font", detail: model.fontFamily, submenu: true, action: .push(.font)),
            PaletteItem(id: "change-style", title: "Change Interface Style", detail: model.interfaceStyle.title, submenu: true,
                        action: .push(.interfaceStyle)),
            PaletteItem(id: "density-comfortable", title: Density.comfortable.title, checked: model.density == .comfortable,
                        action: .run { withAnimation(.den) { model.density = .comfortable } }),
            PaletteItem(id: "density-compact", title: Density.compact.title, checked: model.density == .compact,
                        action: .run { withAnimation(.den) { model.density = .compact } }),
            PaletteItem(id: "change-shell", title: "Change Default Shell", detail: (model.defaultShell as NSString).lastPathComponent,
                        submenu: true, action: .push(.shell)),
            PaletteItem(id: "font-bigger", title: "Increase Font Size", detail: "\(Int(model.fontSize)) pt", shortcut: key(.fontBigger),
                        keepOpen: true, action: .run { model.adjustFontSize(1) }),
            PaletteItem(id: "font-smaller", title: "Decrease Font Size", shortcut: key(.fontSmaller), keepOpen: true, action: .run { model.adjustFontSize(-1) }),
        ]
        view += AppearanceMode.allCases.map { mode in
            PaletteItem(id: "appearance-\(mode.rawValue)", title: mode.title, checked: model.appearanceMode == mode, action: .run { model.appearanceMode = mode })
        }
        view += [
            PaletteItem(id: "tabs", title: model.tabStyle == .horizontal ? "Switch to Vertical Tabs" : "Switch to Horizontal Tabs",
                        action: .run { withAnimation(.den) { model.tabStyle = model.tabStyle == .horizontal ? .vertical : .horizontal } }),
            PaletteItem(id: "sidebar", title: model.tabStyle == .vertical && !model.sidebarCollapsed ? "Hide Sidebar" : "Show Sidebar", shortcut: key(.toggleSidebar),
                        action: .run { withAnimation(.den) { model.toggleSidebar() } }),
            PaletteItem(id: "sidebar-side", title: model.sidebarSide == .left ? "Move Sidebar to the Right" : "Move Sidebar to the Left",
                        action: .run { withAnimation(.den) {
                            model.sidebarSide = model.sidebarSide == .left ? .right : .left
                            model.showSidebar()
                        } }),
            PaletteItem(id: "activity", title: model.activityMode ? "Leave Activity Mode" : "Activity Mode", shortcut: key(.toggleActivityMode),
                        action: .run { withAnimation(.den) { model.toggleActivityMode() } }),
            PaletteItem(id: "zen", title: model.zenMode ? "Leave Zen Mode" : "Zen Mode", shortcut: key(.toggleZenMode),
                        action: .run { withAnimation(.den) { model.zenMode.toggle() } }),
            PaletteItem(id: "headers", title: model.showPaneHeaders ? "Hide Pane Headers" : "Show Pane Headers",
                        action: .run { withAnimation(.den) { model.showPaneHeaders.toggle() } }),
            PaletteItem(id: "acc", title: "Automatic Contrast Correction", checked: model.contrastCorrection,
                        keepOpen: true, action: .run { model.contrastCorrection.toggle() }),
            PaletteItem(id: "ligatures", title: model.fontLigatures ? "Disable Terminal Font Ligatures" : "Enable Terminal Font Ligatures",
                        action: .run { model.fontLigatures.toggle() }),
            PaletteItem(id: "smoothing", title: model.fontSmoothing ? "Disable Terminal Font Smoothing" : "Enable Terminal Font Smoothing",
                        action: .run { model.fontSmoothing.toggle() }),
            PaletteItem(id: "cursor-blink", title: "Cursor Blinking", detail: model.cursorBlink ? model.cursorBlinkStyle.summary : "Off",
                        submenu: true, action: .push(.cursorBlink)),
            PaletteItem(id: "peek", title: "Peek at Tabs", shortcut: key(.peek), action: .run { withAnimation(.den) { model.overview = .peek } }),
            PaletteItem(id: "expose", title: "Show All Sessions", shortcut: key(.showAllSessions), action: .run { withAnimation(.den) { model.overview = .expose } }),
            PaletteItem(id: "import-theme", title: "Import Theme File…", action: .run { importTheme() }),
            PaletteItem(id: "migrate-ghostty", icon: "arrow.down.doc", title: "Migrate from Ghostty Config", detail: "Theme, option key, key bindings",
                        keepOpen: true, action: .run { model.migrateFromGhostty() }),
            PaletteItem(id: "settings", icon: "gearshape", title: "Settings…", shortcut: key(.openSettings),
                        action: .run { model.showSettings?() }),
            PaletteItem(id: "open-config", icon: "doc.text", title: "Open Config File", detail: PathQuery.abbreviate(UserConfig.url.path),
                        shortcut: key(.openConfig), action: .run { model.openConfigFile() }),
            PaletteItem(id: "reload-config", icon: "arrow.clockwise", title: "Reload Config", shortcut: key(.reloadConfig),
                        action: .run { model.reloadConfig(force: true) }),
            PaletteItem(id: "install-cli", icon: "terminal", title: "Install Command Line Tool…", detail: model.cliInstallDetail,
                        action: .run { model.installCommandLineTool() }),
            PaletteItem(id: "install-for-agents", icon: "sparkles", title: "Install Den for Agents", detail: "den command and skill for Claude Code, Codex and others",
                        action: .run { model.installDenForAgents() }),
            PaletteItem(id: "check-updates", icon: "arrow.down.circle", title: "Check for Updates…",
                        action: .run { model.checkForUpdates() }),
        ]
        if !model.customThemes.isEmpty {
            view.append(PaletteItem(id: "delete-theme", title: "Delete Custom Theme…", submenu: true, action: .push(.deleteTheme)))
        }
        items += view.map { var i = $0; i.section = "View"; i.sectionIcon = "paintpalette"; return i }
        return items
    }

    /// Folders to open a tab in: the typed folder's children, then fsearch's
    /// matches below it, or across the disk for a bare name.
    /// The folder part of a remote path as typed; `~` stays for dend to expand.
    private static func remoteParent(_ text: String) -> String {
        if text.hasSuffix("/") || text == "~" { return text }
        let parent = (text as NSString).deletingLastPathComponent
        return parent.isEmpty ? "~" : parent
    }

    /// Go to Directory on a remote host: the typed folder's subfolders from
    /// its dend (no whole-disk search there).
    private func remoteDirectoryItems(_ text: String) -> [PaletteItem] {
        guard let listing = remoteListing, listing.requested == Self.remoteParent(text) else { return [] }
        let prefix = text.hasSuffix("/") || text == "~" ? "" : (text as NSString).lastPathComponent
        let folders = listing.entries.filter { $0.isDirectory && (!$0.name.hasPrefix(".") || prefix.hasPrefix(".")) }.map(\.name)
        let base = listing.path == "/" ? "" : listing.path
        var items: [PaletteItem] = []
        if prefix.isEmpty {
            let name = (listing.path as NSString).lastPathComponent
            items.append(PaletteItem(id: listing.path, section: "Go to", sectionIcon: "folder", icon: "folder.fill",
                                     title: name.isEmpty ? "/" : name, action: .run { model.newTab(cwd: listing.path) }))
        }
        for name in Fuzzy.filter(folders, query: prefix, key: { $0 }).prefix(200) {
            let path = base + "/" + name
            items.append(PaletteItem(id: path, section: "Go to", sectionIcon: "folder", icon: "folder.fill", title: name, action: .run { model.newTab(cwd: path) }))
        }
        return items
    }

    private func directoryItems(_ text: String) -> [PaletteItem] {
        if model.currentHost != .local { return remoteDirectoryItems(text) }
        let deeper = folderHits.map { hit in
            PaletteItem(id: hit.path, section: "Go to", sectionIcon: "folder", icon: "folder.fill",
                        title: PathQuery.abbreviate(hit.path), action: .run { model.newTab(cwd: hit.path) })
        }
        guard text.contains("/") || text.hasPrefix("~") else { return deeper }
        let expanded = (text as NSString).expandingTildeInPath
        let endsWithSlash = expanded.hasSuffix("/")
        let parent = endsWithSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = endsWithSlash ? "" : (expanded as NSString).lastPathComponent
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else { return [] }
        let folders = ((try? fm.contentsOfDirectory(atPath: parent)) ?? [])
            .filter { !$0.hasPrefix(".") || prefix.hasPrefix(".") }
            .filter { var d: ObjCBool = false; return fm.fileExists(atPath: (parent as NSString).appendingPathComponent($0), isDirectory: &d) && d.boolValue }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let children = Fuzzy.filter(folders, query: prefix, key: { $0 })
        var items: [PaletteItem] = []
        if endsWithSlash {
            let path = String(parent.dropLast()).isEmpty ? "/" : String(parent.dropLast())
            items.append(PaletteItem(id: path, section: "Go to", sectionIcon: "folder", icon: "folder.fill",
                                     title: (path as NSString).lastPathComponent, action: .run { model.newTab(cwd: path) }))
        }
        for name in children.prefix(200) {
            let path = (parent as NSString).appendingPathComponent(name)
            items.append(PaletteItem(id: path, section: "Go to", sectionIcon: "folder", icon: "folder.fill", title: name, action: .run { model.newTab(cwd: path) }))
        }
        let shown = Set(items.map(\.id))
        return items + deeper.filter { !shown.contains($0.id) }
    }

    private static func hostIcon(_ host: HostID) -> String {
        host == .local ? "laptopcomputer" : "server.rack"
    }

    /// The keys a picker answers to, under its list.
    private func footer(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Text("Close").uiFont(size: 11.5).foregroundStyle(theme.tertiaryText)
            Keycap(label: "esc", theme: theme).foregroundStyle(theme.secondaryText)
            Text(route == .findTab ? "Go to Tab" : "Switch").uiFont(size: 11.5).foregroundStyle(theme.secondaryText).padding(.leading, 8)
            Keycap(label: "↩", theme: theme).foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 9)
        .padding(.top, 7)
        .padding(.bottom, 2)
        .overlay(alignment: .top) { theme.separator.frame(height: 0.5).padding(.horizontal, -6) }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Den JSON theme, a Ghostty theme file, or a theme folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .init(filenameExtension: "conf")].compactMap { $0 } + [.plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importTheme(from: url) }
    }

}

private struct SectionHeader: View {
    let title: String
    let icon: String?
    let theme: Theme

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10.5)) }
            Text(title).uiFont(size: 11.5, weight: .medium)
        }
        .foregroundStyle(theme.tertiaryText)
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}
