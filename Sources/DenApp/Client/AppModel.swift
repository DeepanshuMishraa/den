import AppKit
import Foundation
import Observation
import DenProtocol
import DenVT

enum ConnectionState: Equatable {
    case connecting
    case connected(host: String)
    case disconnected(String)
}

/// Peek and exposé are two levels of the same overview gesture.
enum Overview: Int, Comparable {
    case none = 0, peek = 1, expose = 2
    static func < (a: Overview, b: Overview) -> Bool { a.rawValue < b.rawValue }
}

enum TabStyle: String {
    case horizontal, vertical
}

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System Appearance"
        case .light: "Light Appearance"
        case .dark: "Dark Appearance"
        }
    }
}

/// Client-side state for one window. dend streams every session; which
/// session and tab are shown is purely local, so switching is instant.
@MainActor @Observable
final class AppModel {
    private(set) var connectionState = ConnectionState.connecting
    private(set) var sessions: [SessionSummary] = []
    private(set) var layouts: [SessionID: SessionLayout] = [:]
    private(set) var currentSession: SessionID?
    private var activeTabs: [SessionID: TabID] = [:]
    private(set) var focusedPanes: [TabID: PaneID] = [:]
    var zoomedPane: PaneID?
    private(set) var metas: [PaneID: PaneMeta] = [:]
    private(set) var titles: [PaneID: String] = [:]
    /// Panes that produced output while not visible: the tab's favicon badge.
    private(set) var activity: Set<PaneID> = []
    /// OSC 7501 records per pane, as dend reports them.
    private(set) var programStatus: [PaneID: [StatusRecord]] = [:]
    /// Each pane's records as of when it was last on screen: done and error
    /// results in here have been seen and stop being flagged.
    private var seenStatus: [PaneID: [StatusRecord]] = [:]
    /// Panes whose next status message is the attach-time sync, not news.
    @ObservationIgnored private var statusSyncPending: Set<PaneID> = []
    @ObservationIgnored private var chime = StatusChime()
    private(set) var lastError: String?
    /// Panes whose replica exists; observed so views attach once snapshots land.
    private(set) var readyPanes: Set<PaneID> = []

    var overview = Overview.none
    /// Offset from `overview`, in levels, while a three-finger swipe is in
    /// progress; nil otherwise.
    private(set) var overviewDrag: CGFloat?
    var showSessionMenu = false {
        didSet { if oldValue, !showSessionMenu { terminalFocusRequest &+= 1 } }
    }
    var palette: PaletteRoute? {
        didSet {
            if oldValue != nil, palette == nil {
                terminalFocusRequest &+= 1
                previewInterfaceStyle = nil
            }
        }
    }
    /// Bumped when an overlay closes; the focused terminal takes keyboard
    /// focus back so typing goes to the shell again.
    private(set) var terminalFocusRequest = 0

    struct Toast: Equatable {
        let id = UUID()
        let message: String
    }

    /// Brief confirmation shown at the bottom of the window ("Copied").
    private(set) var toast: Toast?

    func showToast(_ message: String) {
        let next = Toast(message: message)
        toast = next
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            if self?.toast?.id == next.id { self?.toast = nil }
        }
    }

    // MARK: Shell

    /// Shells listed in /etc/shells that exist on this Mac.
    var availableShells: [String] {
        let listed = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") } ?? []
        return listed.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The configured shell, else the account's login shell.
    var defaultShell: String {
        if let s = DenConfig.value("shell") { return s }
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return "/bin/zsh" }
        return String(decoding: UnsafeRawBufferPointer(start: shell, count: strlen(shell)), as: UTF8.self)
    }

    func setDefaultShell(_ path: String) {
        do {
            try DenConfig.set("shell", path)
            showToast("New panes will use \((path as NSString).lastPathComponent)")
        } catch {
            lastError = "Could not save the shell setting to \(DenConfig.url.path): \(error.localizedDescription). New panes keep using \((defaultShell as NSString).lastPathComponent)."
        }
    }
    var tabStyle: TabStyle {
        didSet {
            defaults.set(tabStyle.rawValue, forKey: "tabStyle")
            // Choosing vertical tabs means wanting to see them.
            if tabStyle == .vertical { sidebarCollapsed = false }
        }
    }
    /// Vertical tabs only: the sidebar is folded away, leaving the terminal
    /// the full width.
    var sidebarCollapsed: Bool { didSet { defaults.set(sidebarCollapsed, forKey: "sidebarCollapsed") } }

    func toggleSidebar() {
        if tabStyle == .vertical { sidebarCollapsed.toggle() } else { tabStyle = .vertical }
    }
    var showPaneHeaders: Bool { didSet { defaults.set(showPaneHeaders, forKey: "showPaneHeaders") } }
    var contrastCorrection: Bool { didSet { defaults.set(contrastCorrection, forKey: "acc"); refreshReplicas() } }
    var interfaceStyle: InterfaceStyle { didSet { defaults.set(interfaceStyle.rawValue, forKey: "interfaceStyle") } }
    /// Set while hovering a style in the palette; reverted on dismiss.
    var previewInterfaceStyle: InterfaceStyle?
    var effectiveInterfaceStyle: InterfaceStyle { previewInterfaceStyle ?? interfaceStyle }
    var density: Density { didSet { defaults.set(density.rawValue, forKey: "density") } }
    var surfaces: Surfaces { Surfaces(theme: theme, style: effectiveInterfaceStyle) }
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "fontFamily") } }
    var fontSize: CGFloat { didSet { defaults.set(Double(fontSize), forKey: "fontSize") } }

    func adjustFontSize(_ delta: CGFloat) { fontSize = min(max(fontSize + delta, 8), 32) }
    func resetFontSize() { fontSize = FontMetrics.defaultSize }

    // MARK: Theme state

    var appearanceMode: AppearanceMode { didSet { defaults.set(appearanceMode.rawValue, forKey: "appearance"); applyTheme() } }
    private var lightThemeName: String { didSet { defaults.set(lightThemeName, forKey: "lightTheme") } }
    private var darkThemeName: String { didSet { defaults.set(darkThemeName, forKey: "darkTheme") } }
    private(set) var customThemes: [Theme] = ThemeImport.installed()
    private var systemIsDark: Bool
    /// Set while hovering a theme in the palette; reverted on dismiss.
    var previewTheme: Theme? { didSet { applyTheme() } }
    private(set) var theme: Theme

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private(set) var replicas: [PaneID: PaneReplica] = [:] {
        didSet {
            let keys = Set(replicas.keys)
            if keys != readyPanes { readyPanes = keys }
        }
    }
    @ObservationIgnored private var connection: DenConnection?
    @ObservationIgnored private var sentSizes: [PaneID: GridSize] = [:]
    @ObservationIgnored private var lastSeen: [PaneID: Date] = [:]
    @ObservationIgnored private var pendingFocus: PaneID?
    @ObservationIgnored private var pendingSession: SessionID?
    @ObservationIgnored private var creatingFirstSession = false
    /// Grid size used for panes the server creates before their view exists.
    @ObservationIgnored var defaultGridSize = GridSize(cols: 100, rows: 30, cellWidthPx: 16, cellHeightPx: 34)

    private static let lastSessionKey = "lastSessionID"

    init(systemIsDark: Bool) {
        let d = UserDefaults.standard
        self.systemIsDark = systemIsDark
        tabStyle = TabStyle(rawValue: d.string(forKey: "tabStyle") ?? "") ?? .horizontal
        sidebarCollapsed = d.bool(forKey: "sidebarCollapsed")
        showPaneHeaders = d.object(forKey: "showPaneHeaders") as? Bool ?? true
        contrastCorrection = d.object(forKey: "acc") as? Bool ?? true
        interfaceStyle = InterfaceStyle(rawValue: d.string(forKey: "interfaceStyle") ?? "") ?? .themed
        density = Density(rawValue: d.string(forKey: "density") ?? "") ?? .comfortable
        fontFamily = d.string(forKey: "fontFamily") ?? FontMetrics.defaultFamily
        fontSize = CGFloat(d.object(forKey: "fontSize") as? Double ?? Double(FontMetrics.defaultSize))
        appearanceMode = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        lightThemeName = d.string(forKey: "lightTheme") ?? ThemeCatalog.defaultLight
        darkThemeName = d.string(forKey: "darkTheme") ?? ThemeCatalog.defaultDark
        theme = ThemeCatalog.named(ThemeCatalog.defaultDark) ?? ThemeCatalog.dark[0]
        applyTheme()
    }

    // MARK: Connection

    func connect() async {
        connectionState = .connecting
        do {
            let fd = try await DendLauncher.connect()
            let conn = DenConnection(
                fd: fd,
                deliver: { [weak self] batch in self?.receive(batch) },
                closed: { [weak self] reason in self?.connectionClosed(reason) }
            )
            connection = conn
            await conn.start()
            send(.hello(version: protocolVersion, client: "Den.app"))
            send(.subscribe)
        } catch {
            connectionState = .disconnected(error.description)
        }
    }

    private func send(_ message: ClientMessage) {
        connection?.send(message)
    }

    private func connectionClosed(_ reason: String) {
        connection = nil
        connectionState = .disconnected(reason)
        replicas.removeAll()
        sentSizes.removeAll()
        layouts.removeAll()
    }

    // MARK: Server messages

    private func receive(_ batch: [ServerMessage]) {
        for message in batch { handle(message) }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .welcome(_, let host):
            connectionState = .connected(host: host)

        case .sessions(let list):
            sessions = list
            if list.isEmpty, !creatingFirstSession, pendingSession == nil {
                creatingFirstSession = true
                createSession(name: "")
            }

        case .layout(let layout):
            apply(layout)

        case .paneSnapshot(let id, let bytes):
            statusSyncPending.insert(id)
            do {
                if let existing = replicas[id] {
                    try existing.reset(snapshot: bytes)
                } else {
                    let replica = try PaneReplica(id: id, snapshot: bytes, theme: theme, contrastCorrection: contrastCorrection)
                    replica.onTitleChange = { [weak self] title in self?.titles[id] = title }
                    replica.onBell = { [weak self] in self?.markActivity(id) }
                    replicas[id] = replica
                    titles[id] = replica.terminal.title
                    lastSeen[id] = Date()
                }
            } catch {
                lastError = "Could not restore a pane from dend's snapshot: \(error). The pane keeps running in dend; restart Den to resync."
            }

        case .paneOutput(let id, let bytes):
            // Output means the attach sync is over (an older dend sends no
            // status message when a pane has none).
            statusSyncPending.remove(id)
            replicas[id]?.write(bytes)
            markActivity(id)

        case .paneResized(let id, let size):
            do {
                try replicas[id]?.resize(size)
            } catch {
                lastError = "Resizing a pane failed: \(error)"
            }

        case .paneMeta(let id, let meta):
            metas[id] = meta

        case .programStatus(let id, let records):
            if statusSyncPending.remove(id) == nil, let sound = StatusChime.sound(old: programStatus[id] ?? [], new: records) {
                chime.play(sound)
            }
            programStatus[id] = records
            if isVisible(id) { seenStatus[id] = records }

        case .paneExited(let id, _):
            replicas.removeValue(forKey: id)
            sentSizes.removeValue(forKey: id)
            metas.removeValue(forKey: id)
            titles.removeValue(forKey: id)
            activity.remove(id)
            programStatus.removeValue(forKey: id)
            seenStatus.removeValue(forKey: id)
            statusSyncPending.remove(id)

        case .sessionClosed(let id):
            layouts.removeValue(forKey: id)
            activeTabs.removeValue(forKey: id)
            if currentSession == id {
                currentSession = nil
                pickSession(excluding: id)
            }

        case .error(let message):
            lastError = message
        }
    }

    private func apply(_ layout: SessionLayout) {
        let sid = layout.session.id
        layouts[sid] = layout

        let live = Set(layouts.values.flatMap { $0.tabs.flatMap(\.root.panes) })
        for id in replicas.keys where !live.contains(id) {
            replicas.removeValue(forKey: id)
            sentSizes.removeValue(forKey: id)
        }

        if let pending = pendingFocus, let tab = layout.tabs.first(where: { $0.root.contains(pending) }) {
            activeTabs[sid] = tab.id
            focusedPanes[tab.id] = pending
            pendingFocus = nil
            if currentSession != sid { switchSession(sid) }
        }
        if activeTabs[sid].map({ id in layout.tabs.contains { $0.id == id } }) != true {
            activeTabs[sid] = layout.tabs.first?.id
        }
        for tab in layout.tabs where !(focusedPanes[tab.id].map(tab.root.contains) ?? false) {
            focusedPanes[tab.id] = tab.root.panes.first
        }
        if let z = zoomedPane, !live.contains(z) { zoomedPane = nil }

        if pendingSession == sid {
            pendingSession = nil
            switchSession(sid)
        } else if currentSession == nil {
            // Reopen the last session; the session list arrives before layouts.
            let remembered = defaults.string(forKey: Self.lastSessionKey).flatMap(UUID.init(uuidString:)).map(SessionID.init)
            let rememberedExists = remembered.map { r in sessions.contains { $0.id == r } } ?? false
            if !rememberedExists || remembered == sid { switchSession(sid) }
        }
    }

    private func pickSession(excluding: SessionID) {
        if let next = sessions.first(where: { $0.id != excluding && layouts[$0.id] != nil }) {
            switchSession(next.id)
        } else {
            createSession(name: "")
        }
    }

    private func markActivity(_ pane: PaneID) {
        let now = Date()
        if isVisible(pane) {
            lastSeen[pane] = now
            return
        }
        // Shells redraw right after you leave a tab (resize, prompt); only
        // output arriving a moment later counts as new activity.
        if let seen = lastSeen[pane], now.timeIntervalSince(seen) < 2 { return }
        activity.insert(pane)
    }

    private func isVisible(_ pane: PaneID) -> Bool {
        guard NSApp.isActive || overview != .none else { return false }
        return activeLayout?.root.contains(pane) == true
    }

    // MARK: Sessions

    var orderedSessions: [SessionSummary] { sessions.filter { layouts[$0.id] != nil } }

    func switchSession(_ id: SessionID) {
        guard layouts[id] != nil || pendingSession == id else { return }
        currentSession = id
        zoomedPane = nil
        defaults.set(id.raw.uuidString, forKey: Self.lastSessionKey)
        clearActivity()
    }

    func cycleSession(_ delta: Int) {
        let list = orderedSessions
        guard let i = list.firstIndex(where: { $0.id == currentSession }), !list.isEmpty else { return }
        switchSession(list[(i + delta + list.count) % list.count].id)
    }

    func createSession(name: String) {
        let id = SessionID()
        pendingSession = id
        send(.createSession(id: id, name: name, size: defaultGridSize))
    }

    func killSession(_ id: SessionID) { send(.killSession(id)) }

    func renameSession(_ id: SessionID, to name: String) { send(.renameSession(id, name: name)) }

    var currentSummary: SessionSummary? { sessions.first { $0.id == currentSession } }

    // MARK: Tabs and panes

    var currentLayout: SessionLayout? { currentSession.flatMap { layouts[$0] } }
    var tabs: [TabLayout] { currentLayout?.tabs ?? [] }

    func tabs(in session: SessionID) -> [TabLayout] { layouts[session]?.tabs ?? [] }

    var activeTab: TabID? { currentSession.flatMap { activeTabs[$0] } }

    var activeLayout: TabLayout? { tabs.first { $0.id == activeTab } }

    func focusedPane(in tab: TabID) -> PaneID? { focusedPanes[tab] }

    var focused: PaneID? { activeTab.flatMap { focusedPanes[$0] } }

    func selectTab(_ tab: TabID) {
        guard let sid = layouts.first(where: { $0.value.tabs.contains { $0.id == tab } })?.key else { return }
        activeTabs[sid] = tab
        if currentSession != sid { switchSession(sid) }
        zoomedPane = nil
        clearActivity()
    }

    func focus(_ pane: PaneID) {
        guard let (sid, tab) = locate(pane) else { return }
        activeTabs[sid] = tab.id
        focusedPanes[tab.id] = pane
        if currentSession != sid { switchSession(sid) }
        activity.remove(pane)
    }

    /// Keyboard focus moved to a pane's view. Only updates which pane is
    /// focused within the active tab; tab and session stay put.
    func paneTookKeyboardFocus(_ pane: PaneID) {
        guard let tab = activeLayout, tab.root.contains(pane) else { return }
        focusedPanes[tab.id] = pane
        activity.remove(pane)
    }

    private func locate(_ pane: PaneID) -> (SessionID, TabLayout)? {
        for (sid, layout) in layouts {
            if let tab = layout.tabs.first(where: { $0.root.contains(pane) }) { return (sid, tab) }
        }
        return nil
    }

    private func clearActivity() {
        let now = Date()
        // The tab being left counts as just seen, too.
        for pane in lastVisiblePanes { lastSeen[pane] = now }
        for pane in lastVisiblePanes { seenStatus[pane] = programStatus[pane] }
        guard let tab = activeLayout else { return }
        activity.subtract(tab.root.panes)
        for pane in tab.root.panes { lastSeen[pane] = now }
        for pane in tab.root.panes { seenStatus[pane] = programStatus[pane] }
        lastVisiblePanes = tab.root.panes
    }

    @ObservationIgnored private var lastVisiblePanes: [PaneID] = []

    func appBecameActive() { clearActivity() }

    func newTab(cwd: String? = nil) {
        guard let session = currentSession else { return }
        let pane = PaneID()
        pendingFocus = pane
        overview = .none
        send(.newTab(session: session, tab: TabID(), pane: pane, size: defaultGridSize, cwd: cwd ?? focused.flatMap { metas[$0]?.cwd }))
    }

    func split(_ axis: SplitAxis) {
        guard let target = focused else { return newTab() }
        let pane = PaneID()
        pendingFocus = pane
        zoomedPane = nil
        send(.splitPane(target: target, new: pane, axis: axis, size: sentSizes[target] ?? defaultGridSize))
    }

    func close(_ pane: PaneID) { send(.closePane(pane)) }

    func closeFocusedPane() { focused.map(close) }

    func closeTab(_ id: TabID) {
        layouts.values.flatMap(\.tabs).first { $0.id == id }?.root.panes.forEach(close)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func cycleTab(_ delta: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTab }), !tabs.isEmpty else { return }
        selectTab(tabs[(i + delta + tabs.count) % tabs.count].id)
    }

    func moveTab(_ tab: TabID, to index: Int) {
        send(.moveTab(tab, index: UInt16(clamping: index)))
    }

    func renameTab(_ tab: TabID, to title: String?) { send(.renameTab(tab, title: title)) }

    func moveActiveTab(_ delta: Int) {
        guard let tab = activeTab, let i = tabs.firstIndex(where: { $0.id == tab }) else { return }
        let target = i + delta
        guard tabs.indices.contains(target) else { return }
        moveTab(tab, to: target)
    }

    /// "Tidy Tab Title": drops a custom title so the tab follows its program again.
    func tidyTabTitle() { activeTab.map { renameTab($0, to: nil) } }

    func cyclePane(_ delta: Int) {
        guard let tab = activeLayout, let current = focused, let i = tab.root.panes.firstIndex(of: current) else { return }
        let panes = tab.root.panes
        focusedPanes[tab.id] = panes[(i + delta + panes.count) % panes.count]
    }

    func toggleZoom() {
        guard let pane = focused, (activeLayout?.root.panes.count ?? 0) > 1 else { return }
        zoomedPane = zoomedPane == pane ? nil : pane
    }

    func setRatio(tab: TabID, path: [UInt8], ratio: Float) {
        send(.setSplitRatio(tab: tab, path: path, ratio: ratio))
    }

    func input(_ pane: PaneID, _ bytes: Data) {
        guard !bytes.isEmpty else { return }
        send(.input(pane, bytes))
    }

    /// Requests a new grid size; the replica resizes when dend echoes it back
    /// in-stream, which keeps every replica's reflow identical.
    func resize(_ pane: PaneID, _ size: GridSize) {
        defaultGridSize = size
        guard sentSizes[pane] != size else { return }
        sentSizes[pane] = size
        send(.resize(pane, size))
    }

    func replica(_ pane: PaneID) -> PaneReplica? { replicas[pane] }

    func dismissError() { lastError = nil }

    func report(_ message: String) { lastError = message }

    // MARK: Overview

    func stepOverview(_ delta: Int) {
        let next = Overview(rawValue: min(max(overview.rawValue + delta, 0), 2)) ?? .none
        guard next != overview else { return }
        overview = next
    }

    /// Where the overview currently sits, following the fingers mid-swipe:
    /// 0 none, 1 peek, 2 exposé.
    var overviewLevel: CGFloat {
        min(max(CGFloat(overview.rawValue) + (overviewDrag ?? 0), 0), 2)
    }

    func dragOverview(_ progress: CGFloat) { overviewDrag = progress }

    /// Settles a swipe on the nearest level, biased toward the direction of
    /// travel so a short swipe still commits.
    func endOverviewDrag(_ progress: CGFloat) {
        let steps = progress > 0 ? (progress + 0.7).rounded(.down) : (progress - 0.7).rounded(.up)
        overviewDrag = nil
        stepOverview(Int(steps))
    }

    // MARK: Themes

    var effectiveAppearance: Appearance {
        switch appearanceMode {
        case .system: systemIsDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }

    var themesForCurrentAppearance: [Theme] {
        let builtIn = effectiveAppearance == .dark ? ThemeCatalog.dark : ThemeCatalog.light
        return builtIn + customThemes.filter { $0.appearance == effectiveAppearance }
    }

    var selectedThemeName: String { effectiveAppearance == .dark ? darkThemeName : lightThemeName }

    func systemAppearanceChanged(isDark: Bool) {
        guard isDark != systemIsDark else { return }
        systemIsDark = isDark
        applyTheme()
    }

    func selectTheme(_ theme: Theme) {
        previewTheme = nil
        if theme.appearance == .dark { darkThemeName = theme.name } else { lightThemeName = theme.name }
        if theme.appearance != effectiveAppearance { appearanceMode = theme.appearance == .dark ? .dark : .light }
        applyTheme()
    }

    func importTheme(from url: URL) {
        do {
            let theme = try ThemeImport.install(url)
            customThemes.removeAll { $0.name == theme.name }
            customThemes.append(theme)
            selectTheme(theme)
        } catch {
            lastError = error.description
        }
    }

    func deleteCustomTheme(_ theme: Theme) {
        ThemeImport.remove(theme)
        customThemes.removeAll { $0.name == theme.name }
        applyTheme()
    }

    private func resolve(_ name: String, _ appearance: Appearance) -> Theme {
        ThemeCatalog.named(name) ?? customThemes.first { $0.name == name }
            ?? ThemeCatalog.named(appearance == .dark ? ThemeCatalog.defaultDark : ThemeCatalog.defaultLight)
            ?? ThemeCatalog.dark[0]
    }

    private func applyTheme() {
        let next = previewTheme ?? resolve(effectiveAppearance == .dark ? darkThemeName : lightThemeName, effectiveAppearance)
        guard next != theme else { return }
        theme = next
        refreshReplicas()
    }

    private func refreshReplicas() {
        for replica in replicas.values { replica.apply(theme: theme, contrastCorrection: contrastCorrection) }
    }

    // MARK: Titles

    func title(for pane: PaneID) -> String {
        if let t = titles[pane], !t.isEmpty { return t }
        guard let meta = metas[pane] else { return "shell" }
        let name = program(for: pane).name
        guard let cwd = meta.cwd else { return name }
        return "\(name) \(Self.abbreviate(cwd))"
    }

    func tabTitle(_ tab: TabLayout) -> String {
        if let custom = tab.title { return custom }
        return (focusedPanes[tab.id] ?? tab.root.panes.first).map(title(for:)) ?? "shell"
    }

    func program(for pane: PaneID) -> ProgramKind {
        ProgramKind.detect(process: metas[pane]?.process, title: titles[pane])
    }

    /// Front card first, then the tab's other panes.
    func deck(for tab: TabLayout) -> [ProgramKind] {
        let front = focusedPanes[tab.id] ?? tab.root.panes.first
        let rest = tab.root.panes.filter { $0 != front }
        return (front.map { [program(for: $0)] } ?? [ProgramKind.shell]) + rest.map(program(for:))
    }

    func hasActivity(_ tab: TabLayout) -> Bool {
        tab.root.panes.contains(where: activity.contains)
    }

    /// What the tab's programs report, if anything worth showing.
    func status(of tab: TabLayout) -> TabStatus? {
        let panes = tab.root.panes
        return TabStatus.summarize(panes.flatMap { programStatus[$0] ?? [] }, seen: panes.flatMap { seenStatus[$0] ?? [] })
    }

    /// A tab in this session (other than the one on screen) finished or is
    /// waiting on the user.
    func sessionWantsAttention(_ id: SessionID) -> Bool {
        tabs(in: id).contains { $0.id != activeTab && status(of: $0)?.wantsAttention == true }
    }

    func cwd(of pane: PaneID?) -> String? { pane.flatMap { metas[$0]?.cwd } }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
