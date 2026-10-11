import AppKit
import DenProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Which list the palette shows. Submenus appear as a chip in the field.
enum PaletteRoute: Equatable {
    case root, theme, interfaceStyle, font, shell, changeSession, renameSession, renameTab, goToDirectory, addHost, deleteTheme

    var chip: String? {
        switch self {
        case .root: nil
        case .theme: "Theme"
        case .font: "Font"
        case .shell: "Shell"
        case .interfaceStyle: "Interface Style"
        case .changeSession: "Session"
        case .renameSession, .renameTab: "Rename"
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
        case .interfaceStyle: "Select Interface Style…"
        case .changeSession: "Filter sessions…"
        case .renameSession: "Session name"
        case .renameTab: "Tab title"
        case .goToDirectory: "Path"
        case .addHost: "user@host, 100.x.y.z or machine.tailnet.ts.net"
        case .deleteTheme: "Select a custom theme…"
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
    var detail: String?
    var shortcut: String?
    var checked = false
    var submenu = false
    /// Keeps the palette open after running (toggles).
    var keepOpen = false
    var theme: Theme?
    var interfaceStyle: InterfaceStyle?
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
        let theme = model.theme
        let items = visibleItems
        VStack(alignment: .leading, spacing: 4) {
            field(theme)
            if items.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 13))
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
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)))
                    .foregroundStyle(theme.chromeText)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(theme.tertiaryText)
            }
            TextField(route.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .onSubmit {
                    let items = visibleItems
                    if items.indices.contains(selection) { activate(items[selection]) }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.tertiaryText)
                }
                .buttonStyle(.plain)
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
        let hits = route == .root || route == .theme || route == .font || route == .shell || route == .interfaceStyle || route == .changeSession ? (Fuzzy.match(query, in: item.title) ?? []) : []
        return HStack(spacing: 8) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(icon == "folder.fill" && !highlighted ? Color(.sRGB, red: 0.33, green: 0.62, blue: 0.96) : fg)
                    .frame(width: 16)
            }
            Fuzzy.highlighted(item.title, hits: hits, base: fg, accent: highlighted ? fg : theme.accent)
                .font(.system(size: 13.5))
                .lineLimit(1)
            Spacer(minLength: 10)
            if let detail = item.detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(dim).lineLimit(1).truncationMode(.head)
            }
            if let shortcut = item.shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(dim)
            }
            if item.checked {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(dim)
            }
            if item.submenu {
                Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(dim)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? theme.accent : .clear))
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
        case .root, .theme, .interfaceStyle, .font, .shell, .changeSession, .deleteTheme:
            let all = items(for: route)
            guard !q.isEmpty else { return all }
            return Fuzzy.filter(all, query: q, key: \.title)
        case .renameSession:
            guard !q.isEmpty, let id = model.currentSession else { return [] }
            return [PaletteItem(id: "rename", title: "Rename session to “\(q)”", shortcut: "↩", action: .run { model.renameSession(id, to: q) })]
        case .renameTab:
            guard let tab = model.activeTab else { return [] }
            if q.isEmpty {
                return [PaletteItem(id: "reset", title: "Use the program's title", shortcut: "↩", action: .run { model.renameTab(tab, to: nil) })]
            }
            return [PaletteItem(id: "rename", title: "Rename tab to “\(q)”", shortcut: "↩", action: .run { model.renameTab(tab, to: q) })]
        case .addHost:
            let saved = model.remoteHosts.map { host in
                PaletteItem(id: "host-\(host.id)", section: "Saved Hosts", sectionIcon: "server.rack", icon: "server.rack", title: host.label,
                            detail: model.remoteStates[host.id].map(HostStatus.short), action: .run { model.connectRemote(host.id, reveal: true) })
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
            return model.themesForCurrentAppearance.map { t in
                PaletteItem(id: "theme-\(t.name)", title: t.name, checked: t.name == model.selectedThemeName, theme: t, action: .run { model.selectTheme(t) })
            }
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
        case .shell:
            let current = model.defaultShell
            return model.availableShells.map { path in
                PaletteItem(id: "shell-\(path)", icon: "terminal", title: (path as NSString).lastPathComponent, detail: path,
                            checked: path == current, action: .run { model.setDefaultShell(path) })
            }
        case .changeSession:
            return model.orderedSessions.enumerated().map { i, s in
                PaletteItem(id: "session-\(s.id)", title: s.name, shortcut: i < 9 ? "⌘\(i + 1)" : nil, checked: s.id == model.currentSession,
                            action: .run { model.switchSession(s.id) })
            }
        case .deleteTheme:
            return model.customThemes.map { t in
                PaletteItem(id: "delete-\(t.name)", icon: "trash", title: t.name, action: .run { model.deleteCustomTheme(t) })
            }
        default:
            return rootItems
        }
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
            PaletteItem(id: "new-session", title: "New Session", shortcut: "⇧⌘N", action: .run { model.createSession(name: "") }),
            PaletteItem(id: "new-tab", title: "New Tab", shortcut: "⌘T", action: .run { model.newTab() }),
            PaletteItem(id: "insert-path", icon: "text.insert", title: "Insert Path…", shortcut: "⌘O",
                        // After the palette hands focus back to the terminal.
                        action: .run { DispatchQueue.main.async { model.openPathPicker() } }),
            PaletteItem(id: "goto", icon: "folder", title: "Go to Directory…", detail: cwd, shortcut: "⇧⌘G", submenu: true, action: .push(.goToDirectory)),
            PaletteItem(id: "close-tab", title: "Close Tab", shortcut: "⇧⌘W", action: .run { model.activeTab.map(model.closeTab) }),
            PaletteItem(id: "prev-session", title: "Previous Session", action: .run { model.cycleSession(-1) }),
            PaletteItem(id: "next-session", title: "Next Session", action: .run { model.cycleSession(1) }),
            PaletteItem(id: "prev-tab", title: "Show Previous Tab", shortcut: "⇧⌘[", action: .run { model.cycleTab(-1) }),
            PaletteItem(id: "next-tab", title: "Show Next Tab", shortcut: "⇧⌘]", action: .run { model.cycleTab(1) }),
            PaletteItem(id: "move-tab-left", title: "Move Tab Left", shortcut: "⌥⇧⌘[", action: .run { model.moveActiveTab(-1) }),
            PaletteItem(id: "move-tab-right", title: "Move Tab Right", shortcut: "⌥⇧⌘]", action: .run { model.moveActiveTab(1) }),
            PaletteItem(id: "tidy", title: "Tidy Tab Title", action: .run { model.tidyTabTitle() }),
            PaletteItem(id: "close-session", title: "Close Session", action: .run { model.currentSession.map(model.killSession) }),
        ]
        let paneSpecs: [(String, String, String, @MainActor () -> Void)] = [
            ("split-right", "Split Pane Right", "⌘D", { model.split(.horizontal) }),
            ("split-down", "Split Pane Down", "⇧⌘D", { model.split(.vertical) }),
            ("focus-next", "Focus Next Pane", "⌘]", { model.cyclePane(1) }),
            ("focus-prev", "Focus Previous Pane", "⌘[", { model.cyclePane(-1) }),
            ("zoom", "Zoom Pane", "⇧⌘↩", { model.toggleZoom() }),
            ("close-pane", "Close Pane", "⌘W", { model.closeFocusedPane() }),
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
            PaletteItem(id: "font-bigger", title: "Increase Font Size", detail: "\(Int(model.fontSize)) pt", shortcut: "⌘=",
                        keepOpen: true, action: .run { model.adjustFontSize(1) }),
            PaletteItem(id: "font-smaller", title: "Decrease Font Size", shortcut: "⌘-", keepOpen: true, action: .run { model.adjustFontSize(-1) }),
        ]
        view += AppearanceMode.allCases.map { mode in
            PaletteItem(id: "appearance-\(mode.rawValue)", title: mode.title, checked: model.appearanceMode == mode, action: .run { model.appearanceMode = mode })
        }
        view += [
            PaletteItem(id: "tabs", title: model.tabStyle == .horizontal ? "Switch to Vertical Tabs" : "Switch to Horizontal Tabs",
                        action: .run { withAnimation(.den) { model.tabStyle = model.tabStyle == .horizontal ? .vertical : .horizontal } }),
            PaletteItem(id: "sidebar", title: model.tabStyle == .vertical && !model.sidebarCollapsed ? "Hide Sidebar" : "Show Sidebar", shortcut: "⌥⌘S",
                        action: .run { withAnimation(.den) { model.toggleSidebar() } }),
            PaletteItem(id: "activity", title: model.activityMode ? "Leave Activity Mode" : "Activity Mode", shortcut: "⇧⌘A",
                        action: .run { withAnimation(.den) { model.toggleActivityMode() } }),
            PaletteItem(id: "headers", title: model.showPaneHeaders ? "Hide Pane Headers" : "Show Pane Headers",
                        action: .run { withAnimation(.den) { model.showPaneHeaders.toggle() } }),
            PaletteItem(id: "acc", title: "Automatic Contrast Correction", checked: model.contrastCorrection,
                        keepOpen: true, action: .run { model.contrastCorrection.toggle() }),
            PaletteItem(id: "peek", title: "Peek at Tabs", shortcut: "⌃⌘↓", action: .run { withAnimation(.den) { model.overview = .peek } }),
            PaletteItem(id: "expose", title: "Show All Sessions", shortcut: "⌃⌘E", action: .run { withAnimation(.den) { model.overview = .expose } }),
            PaletteItem(id: "import-theme", title: "Import Theme File…", action: .run { importTheme() }),
            PaletteItem(id: "migrate-ghostty", title: "Migrate Theme from Ghostty Config", action: .run { migrateGhostty() }),
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

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Ghostty theme file or an Omarchy theme folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importTheme(from: url) }
    }

    private func migrateGhostty() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".config/ghostty/config"),
            home.appending(path: "Library/Application Support/com.mitchellh.ghostty/config"),
        ]
        guard let config = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            model.report("No Ghostty config found at ~/.config/ghostty/config. Nothing was imported.")
            return
        }
        model.importTheme(from: config)
    }
}

private struct SectionHeader: View {
    let title: String
    let icon: String?
    let theme: Theme

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10.5)) }
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(theme.tertiaryText)
        .padding(.horizontal, 9)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}
