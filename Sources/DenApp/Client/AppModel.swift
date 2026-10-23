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

/// Which side of the window vertical tabs sit on.
enum SidebarSide: String {
    case left, right
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

/// Client-side state for one window. Each connected dend (this Mac's, and
/// one per remote host) streams every session; which session and tab are
/// shown is purely local, so switching is instant, across hosts too.
@MainActor @Observable
final class AppModel {
    /// The local dend's connection.
    private(set) var connectionState = ConnectionState.connecting
    /// The protocol version each connected dend speaks (from its welcome).
    @ObservationIgnored private var protocols: [HostID: UInt16] = [:]
    /// Every host's sessions: this Mac's first, then each remote host's.
    private(set) var sessions: [SessionSummary] = []
    @ObservationIgnored private var hostSessions: [HostID: [SessionSummary]] = [:]
    /// Which dend owns each session; entries outlive a dropped connection so
    /// the session can show that it's reconnecting.
    private(set) var sessionHosts: [SessionID: HostID] = [:]
    @ObservationIgnored private var paneHosts: [PaneID: HostID] = [:]
    /// Saved remote hosts and how each connection stands.
    private(set) var remoteHosts: [RemoteHost] = RemoteHostStore.load()
    private(set) var remoteStates: [RemoteHost.ID: RemoteState] = [:]
    /// Set when a host needs a user name and password.
    var loginRequest: LoginRequest?
    /// Each host user's home folder, for `~` in titles and paths.
    private(set) var hostHomes: [HostID: String] = [.local: NSHomeDirectory()]
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
    /// When each pane's headline status last changed state, for "12h" ages
    /// in Activity Mode.
    private(set) var statusSince: [PaneID: Date] = [:]
    /// Panes whose next status message is the attach-time sync, not news.
    @ObservationIgnored private var statusSyncPending: Set<PaneID> = []
    @ObservationIgnored private var chime = StatusChime()
    private(set) var lastError: String?
    /// Panes whose replica exists; observed so views attach once snapshots land.
    private(set) var readyPanes: Set<PaneID> = []

    var overview = Overview.none {
        didSet {
            // Leaving the overview hands the keyboard back to the terminal,
            // so the cursor is a solid block again instead of a hollow one.
            if oldValue != .none, overview == .none { terminalFocusRequest &+= 1 }
        }
    }
    /// Offset from `overview`, in levels, while a three-finger swipe is in
    /// progress; nil otherwise.
    private(set) var overviewDrag: CGFloat?
    var showSessionMenu = false {
        didSet { if oldValue, !showSessionMenu { terminalFocusRequest &+= 1 } }
    }
    /// Horizontal tabs: the eye button's dropdown of tabs reporting activity.
    var showActivityMenu = false
    var palette: PaletteRoute? {
        didSet {
            if oldValue != nil, palette == nil {
                terminalFocusRequest &+= 1
                previewInterfaceStyle = nil
            }
        }
    }
    /// The path picker, open over a pane at its cursor.
    var pathPicker: PathPickerRequest? {
        didSet { if oldValue != nil, pathPicker == nil { terminalFocusRequest &+= 1 } }
    }
    struct PathPickerRequest: Equatable {
        let pane: PaneID
        let cwd: String?
        /// Cursor cell when it opened; the picker hangs off it.
        let col: Int, row: Int
        let rows: Int
    }
    /// The find bar (⌘F), searching the panes of one tab.
    var find: TabFind? {
        didSet { if oldValue != nil, find == nil { terminalFocusRequest &+= 1 } }
    }
    /// Bumped to move the keyboard into the open find bar's field.
    var findFocusRequest = 0
    /// Paths inserted with the picker, newest first.
    private(set) var recentPaths: [String]
    /// The folder the picker was in when it last closed, per host; it opens
    /// there again. This Mac's survives relaunch.
    @ObservationIgnored private var pathPickerFolders: [HostID: String] = [:]

    /// Bumped when an overlay closes; the focused terminal takes keyboard
    /// focus back so typing goes to the shell again.
    private(set) var terminalFocusRequest = 0

    struct ToastAction: Equatable {
        let id = UUID()
        let label: String
        /// Displayed hint inside the button ("⇧⌘U"), if one was given.
        let shortcut: String?
        /// Matchable chord for the hint; nil when there is no hint or it
        /// didn't parse. Checked in `handleKey` so the buttons work from
        /// the keyboard exactly as shown.
        let chord: KeyChord?
        /// A labelled button, or the round ✕ that closes the toast.
        var role: Role = .button

        enum Role: Equatable { case button, dismiss }
    }

    struct Toast: Equatable {
        /// Green with a check for confirmations; the theme's accent with a
        /// symbol badge for notices that ask something (an update).
        enum Tone: Equatable {
            case success
            case notice(symbol: String)
            /// Orange: something needs a look but nothing is broken.
            case warning
            /// Red: something failed.
            case danger
        }

        let id = UUID()
        var message: String
        /// A second, dimmer line under the message: the reason, for failures.
        var detail: String?
        /// Download/install fraction 0…1, if one is in flight.
        var progress: Double?
        /// Buttons the toast offers; empty for plain confirmations.
        var actions: [ToastAction] = []
        var tone = Tone.success
        /// Plain confirmations vanish on their own; progress and action
        /// toasts stay until replaced or dismissed.
        var isPersistent: Bool { progress != nil || !actions.isEmpty }
    }

    /// Brief confirmation shown at the bottom of the window ("Copied").
    private(set) var toast: Toast?
    /// Handlers for the current toast's buttons, by action id.
    @ObservationIgnored private var toastHandlers: [UUID: () -> Void] = [:]

    func showToast(_ message: String, tone: Toast.Tone = .success) {
        // A transient note must not bury an action prompt (notably the
        // update's Restart button, which Sparkle is waiting on): show it
        // briefly, then put the prompt back.
        if let current = toast, !current.actions.isEmpty {
            let restore = current
            let restoreHandlers = toastHandlers
            let next = Toast(message: message, tone: tone)
            toastHandlers = [:]
            toast = next
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1600))
                guard let self, self.toast?.id == next.id else { return }
                self.toast = restore
                self.toastHandlers = restoreHandlers
            }
            return
        }
        toastHandlers = [:]
        let next = Toast(message: message, tone: tone)
        toast = next
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            if self?.toast?.id == next.id { self?.toast = nil }
        }
    }

    /// Creates or refreshes the update progress toast. A nil message keeps
    /// the current text; a nil progress shows an indeterminate state.
    func showUpdateProgress(_ message: String?, progress: Double?) {
        if let current = toast, !current.actions.isEmpty {
            // An action prompt (e.g. the update's Restart button) is showing:
            // a stale progress push must not replace the choice Sparkle is
            // waiting on. The driver re-shows the prompt on focus instead.
            return
        }
        if var current = toast, current.isPersistent, current.actions.isEmpty {
            if let message { current.message = message }
            current.progress = progress
            toast = current
        } else {
            toastHandlers = [:]
            toast = Toast(message: message ?? "Working…", progress: progress)
        }
    }

    /// A toast that stays until one of its buttons is tapped. Each action
    /// may name a `cmd+shift+u`-style shortcut: it is shown in the button
    /// (as "⇧⌘U") and fires the button from `handleKey`.
    /// `dismiss` adds a round ✕ after the buttons, running its handler too.
    func showActionToast(_ message: String, tone: Toast.Tone = .success, detail: String? = nil,
                         actions: [(label: String, shortcut: String?, handler: () -> Void)],
                         dismiss: (shortcut: String?, handler: () -> Void)? = nil) {
        toastHandlers = [:]
        var toastActions: [ToastAction] = []
        func add(_ label: String, _ shortcut: String?, _ role: ToastAction.Role, _ handler: @escaping () -> Void) {
            let chord: KeyChord?
            if let shortcut, case .success(let parsed) = KeyChord.parse(shortcut) {
                chord = parsed
            } else {
                chord = nil
            }
            let action = ToastAction(label: label, shortcut: chord?.label ?? shortcut, chord: chord, role: role)
            toastActions.append(action)
            toastHandlers[action.id] = handler
        }
        for (label, shortcut, handler) in actions { add(label, shortcut, .button, handler) }
        if let dismiss { add("Dismiss", dismiss.shortcut, .dismiss, dismiss.handler) }
        toast = Toast(message: message, detail: detail, actions: toastActions, tone: tone)
    }

    func performToastAction(_ id: UUID) {
        guard let handler = toastHandlers[id] else { return }
        dismissToast()
        handler()
    }

    func dismissToast() {
        toastHandlers = [:]
        toast = nil
    }

    // MARK: Updates

    /// Sparkle updater, nil for dev builds (a raw binary has no bundle to
    /// update). Created last in init: starting it is safe once self exists.
    private(set) var updateController: UpdateController?

    func checkForUpdates() {
        guard let updates = updateController, updates.isAvailable else {
            showToast("Updates are only available in release builds")
            return
        }
        updates.checkForUpdates()
    }

    /// Everything coding agents need to drive Den: the `den` command they
    /// run, and the den Agent Skill telling them how (`den agent install`).
    /// The toast follows each step as it happens.
    func installDenForAgents() {
        let steps = 1 + AgentGuide.skillDirectories.count
        var problems: [String] = []
        func step(_ index: Int, _ message: String) async {
            showUpdateProgress(message, progress: Double(index) / Double(steps))
            // Long enough to read; each step itself takes a few milliseconds.
            try? await Task.sleep(for: .milliseconds(350))
        }
        Task {
            await step(0, "Installing the den command…")
            switch await Task.detached(priority: .userInitiated, operation: { CLIInstaller.install() }).value {
            case .linked, .alreadyLinked:
                if !Self.cliLinkWorks { problems.append("~/.local/bin/den is a broken link; remove it and run this again.") }
            case .occupied: problems.append("Something else is at ~/.local/bin/den, so the den command wasn't linked.")
            case .failed(let message): problems.append(message)
            // Dev builds: the skill still installs; agents can run Den's own binary.
            case .notBundled: problems.append("The den command installs from release builds.")
            }
            for (i, folder) in AgentGuide.skillDirectories.enumerated() {
                await step(i + 1, "Writing the den skill to ~/\(folder)…")
                let (path, outcome) = await Task.detached(priority: .userInitiated) { AgentGuide.install(into: folder) }.value
                switch outcome {
                case .written, .unchanged: break
                case .occupied: problems.append("\(PathQuery.abbreviate(path)) is another skill; left alone.")
                case .failed(let message): problems.append(message)
                }
            }
            showUpdateProgress(nil, progress: 1)
            try? await Task.sleep(for: .milliseconds(250))
            // Only the progress toast: an update's Restart/Later prompt stays.
            if toast?.actions.isEmpty == true { dismissToast() }
            if problems.isEmpty {
                showToast("Den is ready for agents: den command and skill installed")
            } else {
                lastError = "Installing Den for agents finished with problems. " + problems.joined(separator: " ")
            }
        }
    }

    /// Installs the `den` command line tool (`~/.local/bin/den`), narrating
    /// each step in a toast. Explicit only: launching the app never links it.
    func installCommandLineTool() {
        showUpdateProgress("Installing command line tool…", progress: nil)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { CLIInstaller.install() }.value
            switch outcome {
            case .linked:
                if Self.cliLinkWorks {
                    showToast("Installed den to ~/.local/bin/den")
                } else {
                    lastError = "Linked ~/.local/bin/den, but it doesn't resolve to an executable. The link may be broken; remove it and install again."
                }
            case .alreadyLinked:
                showToast(Self.cliLinkWorks ? "Command line tool already installed" : "The den link exists but is broken — remove ~/.local/bin/den and install again")
            case .occupied:
                showActionToast("Something else is at \(CLIInstaller.linkURL.path) — left alone",
                                actions: [("Reveal", nil, { NSWorkspace.shared.activateFileViewerSelecting([CLIInstaller.linkURL]) })])
            case .failed(let message):
                lastError = message
            case .notBundled:
                showToast("The command line tool installs from release builds")
            }
        }
    }

    /// Palette detail for the install item.
    var cliInstallDetail: String {
        guard CLIInstaller.bundledCLI != nil else { return "Release builds only" }
        return Self.cliLinkWorks ? "Installed" : "Not installed"
    }

    /// The link exists, points at this bundle's tool, and executes.
    private static var cliLinkWorks: Bool {
        let fm = FileManager.default
        guard let target = CLIInstaller.bundledCLI,
              let dest = try? fm.destinationOfSymbolicLink(atPath: CLIInstaller.linkURL.path),
              URL(fileURLWithPath: dest).standardizedFileURL.path == URL(fileURLWithPath: target.path).standardizedFileURL.path
        else { return false }
        return fm.isExecutableFile(atPath: dest)
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
    var sidebarSide: SidebarSide { didSet { defaults.set(sidebarSide.rawValue, forKey: "sidebarSide") } }
    /// Machines folded away in the sidebar, by `HostID.storageKey`.
    private(set) var collapsedHosts: Set<String> { didSet { defaults.set(collapsedHosts.sorted(), forKey: "collapsedHosts") } }

    func isCollapsed(_ host: HostID) -> Bool { collapsedHosts.contains(host.storageKey) }

    func toggleCollapsed(_ host: HostID) {
        if collapsedHosts.remove(host.storageKey) == nil { collapsedHosts.insert(host.storageKey) }
    }

    func toggleSidebar() {
        if tabStyle == .vertical { sidebarCollapsed.toggle() } else { tabStyle = .vertical }
    }

    /// Shows the sidebar, switching to vertical tabs first if needed.
    func showSidebar() {
        if tabStyle != .vertical { tabStyle = .vertical }
        sidebarCollapsed = false
    }

    /// Folds the sidebar away, leaving the terminal the full width.
    func hideSidebar() {
        if tabStyle == .vertical { sidebarCollapsed = true }
    }

    /// Activity Mode lives in the sidebar, so turning it on shows that.
    func toggleActivityMode() {
        activityMode.toggle()
        if activityMode, tabStyle != .vertical || sidebarCollapsed {
            tabStyle = .vertical
            sidebarCollapsed = false
        }
    }
    /// Zen Mode: the tab bar (or sidebar) stays out of sight until the
    /// pointer reaches the window's top (or leading) edge.
    var zenMode: Bool {
        didSet {
            defaults.set(zenMode, forKey: "zenMode")
            zenChromeHovered = false
        }
    }
    /// Zen Mode only: the pointer is over the revealed tab bar or sidebar.
    var zenChromeHovered = false
    /// Zen Mode keeps the chrome away unless it's hovered or in use.
    var zenChromeHidden: Bool {
        zenMode && !zenChromeHovered && !showSessionMenu && !showActivityMenu && overview == .none
    }
    /// The sidebar lists only tabs running agents or reporting status, each
    /// with what it's doing and since when.
    var activityMode: Bool { didSet { defaults.set(activityMode, forKey: "activityMode") } }
    var showPaneHeaders: Bool { didSet { defaults.set(showPaneHeaders, forKey: "showPaneHeaders") } }
    var contrastCorrection: Bool { didSet { defaults.set(contrastCorrection, forKey: "acc"); refreshReplicas() } }
    /// Terminal text drawn with the font's ligatures (`->` as an arrow).
    var fontLigatures: Bool { didSet { defaults.set(fontLigatures, forKey: "fontLigatures"); refreshReplicas() } }
    /// Core Text font smoothing for terminal text: heavier, softer strokes.
    var fontSmoothing: Bool { didSet { defaults.set(fontSmoothing, forKey: "fontSmoothing"); refreshReplicas() } }
    /// The focused pane's cursor fades in and out while nothing happens.
    var cursorBlink: Bool { didSet { defaults.set(cursorBlink, forKey: "cursorBlink"); refreshReplicas() } }
    /// How it blinks: speed, transition and pause, each a preset.
    var cursorBlinkStyle: CursorBlink {
        didSet {
            defaults.set(cursorBlinkStyle.speed.rawValue, forKey: "cursorBlinkSpeed")
            defaults.set(cursorBlinkStyle.transition.rawValue, forKey: "cursorBlinkTransition")
            defaults.set(cursorBlinkStyle.pause.rawValue, forKey: "cursorBlinkPause")
            refreshReplicas()
        }
    }
    var interfaceStyle: InterfaceStyle { didSet { defaults.set(interfaceStyle.rawValue, forKey: "interfaceStyle") } }
    /// Set while hovering a style in the palette; reverted on dismiss.
    var previewInterfaceStyle: InterfaceStyle?
    var effectiveInterfaceStyle: InterfaceStyle { previewInterfaceStyle ?? interfaceStyle }
    var density: Density { didSet { defaults.set(density.rawValue, forKey: "density") } }
    var surfaces: Surfaces { Surfaces(theme: theme, style: effectiveInterfaceStyle) }
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "fontFamily") } }
    var fontSize: CGFloat { didSet { defaults.set(Double(fontSize), forKey: "fontSize") } }
    /// Den's own text (toasts, pickers). The config can split it from the
    /// terminal font; otherwise it follows the terminal.
    var uiFontFamily: String { config.uiFont ?? fontFamily }
    var uiFontSize: CGFloat { config.uiFontSize.map { CGFloat($0) } ?? fontSize }

    func adjustFontSize(_ delta: CGFloat) { fontSize = min(max(fontSize + delta, 8), 32) }
    func resetFontSize() { fontSize = FontMetrics.defaultSize }

    // MARK: Theme state

    var appearanceMode: AppearanceMode { didSet { defaults.set(appearanceMode.rawValue, forKey: "appearance"); applyTheme() } }
    private(set) var lightThemeName: String { didSet { defaults.set(lightThemeName, forKey: "lightTheme") } }
    private(set) var darkThemeName: String { didSet { defaults.set(darkThemeName, forKey: "darkTheme") } }
    private(set) var customThemes: [Theme] = []
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
    @ObservationIgnored private var connections: [HostID: DenConnection] = [:]
    @ObservationIgnored private var channels: [RemoteHost.ID: SSH.Channel] = [:]
    /// Bumped per connection attempt so a stale attempt's result is ignored.
    @ObservationIgnored private var attempts: [RemoteHost.ID: Int] = [:]
    /// Hosts whose sessions should come to the front once they arrive.
    @ObservationIgnored private var revealOnConnect: Set<RemoteHost.ID> = []
    @ObservationIgnored private var listings: [UInt32: (host: HostID, reply: CheckedContinuation<(String, [DirectoryEntry])?, Never>)] = [:]
    @ObservationIgnored private var nextListing: UInt32 = 1
    @ObservationIgnored private var sentSizes: [PaneID: GridSize] = [:]
    @ObservationIgnored private var lastSeen: [PaneID: Date] = [:]
    /// Unobserved on purpose: it changes on every write. Activity Mode reads
    /// it on a timer.
    @ObservationIgnored private var lastOutput: [PaneID: Date] = [:]
    @ObservationIgnored private var pendingFocus: PaneID?
    @ObservationIgnored private var pendingSession: SessionID?
    @ObservationIgnored private var creatingFirstSession = false
    /// Grid size used for panes the server creates before their view exists.
    @ObservationIgnored var defaultGridSize = GridSize(cols: 100, rows: 30, cellWidthPx: 16, cellHeightPx: 34)

    private static let lastSessionKey = "lastSessionID" // legacy UserDefaults key
    /// The session open when Den last quit, until it's back on screen or
    /// you pick another one. File-backed so dev and bundled builds (whose
    /// UserDefaults domains differ) remember the same session.
    @ObservationIgnored private var awaitingRemembered: SessionID? = AppModel.readRememberedSession()

    private static func readRememberedSession() -> SessionID? {
        if let s = try? String(contentsOf: DenPaths.lastSession, encoding: .utf8),
           let uuid = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return SessionID(uuid)
        }
        if let s = UserDefaults.standard.string(forKey: lastSessionKey),
           let uuid = UUID(uuidString: s) {
            let id = SessionID(uuid)
            writeRememberedSession(id)
            return id
        }
        return nil
    }

    private static func writeRememberedSession(_ id: SessionID) {
        try? FileManager.default.createDirectory(at: DenPaths.supportDirectory, withIntermediateDirectories: true)
        try? id.raw.uuidString.write(to: DenPaths.lastSession, atomically: true, encoding: .utf8)
    }

    init(systemIsDark: Bool) {
        let d = UserDefaults.standard
        self.systemIsDark = systemIsDark
        tabStyle = TabStyle(rawValue: d.string(forKey: "tabStyle") ?? "") ?? .horizontal
        sidebarCollapsed = d.bool(forKey: "sidebarCollapsed")
        sidebarSide = SidebarSide(rawValue: d.string(forKey: "sidebarSide") ?? "") ?? .left
        collapsedHosts = Set(d.stringArray(forKey: "collapsedHosts") ?? [])
        activityMode = d.bool(forKey: "activityMode")
        zenMode = d.bool(forKey: "zenMode")
        recentPaths = d.stringArray(forKey: "recentPaths") ?? []
        if let folder = d.string(forKey: "pathPickerFolder") { pathPickerFolders[.local] = folder }
        showPaneHeaders = d.object(forKey: "showPaneHeaders") as? Bool ?? true
        contrastCorrection = d.object(forKey: "acc") as? Bool ?? true
        fontLigatures = d.bool(forKey: "fontLigatures")
        fontSmoothing = d.bool(forKey: "fontSmoothing")
        cursorBlink = d.bool(forKey: "cursorBlink")
        cursorBlinkStyle = CursorBlink(
            speed: CursorBlink.Speed(rawValue: d.string(forKey: "cursorBlinkSpeed") ?? "") ?? .normal,
            transition: CursorBlink.Transition(rawValue: d.string(forKey: "cursorBlinkTransition") ?? "") ?? .smooth,
            pause: CursorBlink.Pause(rawValue: d.string(forKey: "cursorBlinkPause") ?? "") ?? .normal
        )
        interfaceStyle = InterfaceStyle(rawValue: d.string(forKey: "interfaceStyle") ?? "") ?? .themed
        density = Density(rawValue: d.string(forKey: "density") ?? "") ?? .comfortable
        fontFamily = d.string(forKey: "fontFamily") ?? FontMetrics.defaultFamily
        fontSize = CGFloat(d.object(forKey: "fontSize") as? Double ?? Double(FontMetrics.defaultSize))
        appearanceMode = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
        // Map names stored before Den's generated themes were renamed.
        let storedLight = d.string(forKey: "lightTheme") ?? ThemeCatalog.defaultLight
        let storedDark = d.string(forKey: "darkTheme") ?? ThemeCatalog.defaultDark
        lightThemeName = ThemeCatalog.renamed[storedLight] ?? storedLight
        darkThemeName = ThemeCatalog.renamed[storedDark] ?? storedDark
        theme = ThemeCatalog.named(ThemeCatalog.defaultDark) ?? ThemeCatalog.dark[0]
        ThemeJSON.exportExamples(to: UserConfig.themesDirectory.appending(path: "examples"))
        reloadCustomThemes()
        applyTheme()
        reloadConfig()
        themeWatcher = ThemeWatcher(directory: UserConfig.themesDirectory) { [weak self] in
            Task { @MainActor in self?.reloadCustomThemes() }
        }
        // Before the updater, which marks this launch in the defaults.
        announceUpdateIfNeeded(d)
        updateController = UpdateController(model: self)
    }

    // MARK: What's new

    /// The release notes shown once after an update.
    private(set) var whatsNew: WhatsNew?

    /// On the first launch of a new version, shows its release notes; the
    /// dialog opens at once and the notes fill in from GitHub.
    private func announceUpdateIfNeeded(_ defaults: UserDefaults) {
        let info = Bundle.main.infoDictionary
        let current = info?["CFBundleShortVersionString"] as? String
        let version = WhatsNew.versionToAnnounce(current: current,
                                                 lastLaunched: defaults.string(forKey: WhatsNew.lastLaunchedKey),
                                                 launchedBefore: defaults.bool(forKey: WhatsNew.sparkleLaunchedKey))
        // Recorded now, so a crash on the way doesn't announce it twice.
        if let current { defaults.set(current, forKey: WhatsNew.lastLaunchedKey) }
        guard let version,
              let repository = ReleaseNotes.repository(feed: (info?["SUFeedURL"] as? String).flatMap(URL.init(string:))) else { return }
        showWhatsNew(version: version, repository: repository)
    }

    /// Opens the dialog for `version` and loads its notes.
    private func showWhatsNew(version: String, repository: String) {
        guard let page = ReleaseNotes.page(repository: repository, version: version) else { return }
        whatsNew = WhatsNew(version: version, page: page, notes: .loading)
        Task { [weak self] in
            let result = await ReleaseNotes.fetch(repository: repository, version: version)
            guard let self, self.whatsNew?.version == version else { return }
            switch result {
            case .success(let blocks): self.whatsNew?.notes = .loaded(blocks)
            case .failure(let error): self.whatsNew?.notes = .unavailable(error.description)
            }
        }
    }

    func dismissWhatsNew() {
        guard whatsNew != nil else { return }
        whatsNew = nil
        terminalFocusRequest &+= 1
    }

    // MARK: Connection

    @ObservationIgnored private var startedRemotes = false

    /// Connects to this Mac's dend (starting it if needed), and on first
    /// launch to every saved remote host.
    func connect() async {
        connectionState = .connecting
        do {
            let fd = if let running = DendLauncher.connectExisting() { running } else { try await DendLauncher.connect() }
            attach(fd: fd, to: .local) { [weak self] reason in self?.connectionClosed(.local, reason) }
        } catch {
            connectionState = .disconnected(error.description)
        }
        if !startedRemotes {
            startedRemotes = true
            // Disconnected hosts stay that way until explicitly reconnected.
            for host in remoteHosts where host.autoConnect { connectRemote(host.id, reveal: false) }
        }
    }

    private func attach(fd: Int32, to host: HostID, closed: @escaping DenConnection.Closed) {
        let conn = DenConnection(fd: fd, deliver: { [weak self] batch in self?.receive(batch, from: host) }, closed: closed)
        connections[host] = conn
        // The oldest version we speak, so an older running dend still
        // accepts us; its welcome says what it can do. Subscribing waits for
        // the welcome, so a dend that refuses us streams nothing.
        conn.open(greeting: [.hello(version: minimumProtocolVersion, client: "Den.app", snapshotVersion: VTTerminal.snapshotVersion)])
    }

    /// Sends to the dend that owns what the message is about.
    private func send(_ message: ClientMessage) {
        send(message, to: route(message))
    }

    private func send(_ message: ClientMessage, to host: HostID) {
        connections[host]?.send(message)
    }

    private func route(_ message: ClientMessage) -> HostID {
        switch message {
        case .killSession(let id), .renameSession(let id, _), .newTab(let id, _, _, _, _):
            sessionHosts[id] ?? .local
        case .renameTab(let tab, _), .moveTab(let tab, _), .setSplitRatio(let tab, _, _):
            host(ofTab: tab)
        case .splitPane(let pane, _, _, _), .closePane(let pane), .movePane(let pane, _, _), .input(let pane, _), .resize(let pane, _):
            paneHosts[pane] ?? .local
        case .hello, .listSessions, .subscribe, .createSession, .listDirectory, .control:
            .local
        }
    }

    private func host(ofTab tab: TabID) -> HostID {
        layouts.first { $0.value.tabs.contains { $0.id == tab } }.flatMap { sessionHosts[$0.key] } ?? .local
    }

    func host(ofPane pane: PaneID?) -> HostID { pane.flatMap { paneHosts[$0] } ?? .local }

    /// The host of the session on screen.
    var currentHost: HostID { currentSession.flatMap { sessionHosts[$0] } ?? .local }

    private func connectionClosed(_ host: HostID, _ reason: String) {
        connections[host] = nil
        protocols[host] = nil
        forget(host)
        if host == .local { connectionState = .disconnected(reason) }
    }

    /// Drops everything streamed from `host`; its next subscribe resends it.
    private func forget(_ host: HostID) {
        for (sid, h) in sessionHosts where h == host { layouts.removeValue(forKey: sid) }
        hostSessions[host] = nil
        rebuildSessions()
        for (pane, h) in paneHosts where h == host { dropPane(pane) }
        for (id, waiting) in listings where waiting.host == host {
            listings.removeValue(forKey: id)
            waiting.reply.resume(returning: nil)
        }
    }

    private func dropPane(_ id: PaneID) {
        replicas.removeValue(forKey: id)
        sentSizes.removeValue(forKey: id)
        metas.removeValue(forKey: id)
        titles.removeValue(forKey: id)
        activity.remove(id)
        programStatus.removeValue(forKey: id)
        seenStatus.removeValue(forKey: id)
        statusSince.removeValue(forKey: id)
        lastOutput.removeValue(forKey: id)
        statusSyncPending.remove(id)
        paneHosts.removeValue(forKey: id)
    }

    private func rebuildSessions() {
        sessions = (hostSessions[.local] ?? []) + remoteHosts.flatMap { hostSessions[.remote($0.id)] ?? [] }
    }

    // MARK: Server messages

    private func receive(_ batch: [Incoming], from host: HostID) {
        for incoming in batch {
            switch incoming {
            case .message(.error(let message)) where protocols[host] == nil:
                refused(host, message)
            // Until dend welcomes us its stream isn't ours to read: a dend that
            // refused the hello still answers the subscribe, in its own format.
            case _ where protocols[host] == nil:
                if case .message(let message) = incoming, case .welcome = message { handle(message, from: host) }
            case .message(let message): handle(message, from: host)
            case .snapshot(let id, let restored): restore(id, restored)
            }
        }
    }

    /// dend turned down the hello, almost always because it's a build from
    /// before this Den that is still running.
    private func refused(_ host: HostID, _ message: String) {
        NSLog("Den: dend on %@ refused this Den: %@", hostLabel(host), message)
        // Let go of it: the old dend and its sessions run on until you choose.
        switch host {
        case .local:
            connections[.local]?.disconnect("dend is still running from an older Den, which can't talk to this one. Your sessions there keep running until you restart it.")
        case .remote(let id):
            disconnectRemote(id)
            remoteStates[id] = .needsRestart
        }
        outdatedDends.insert(host)
        promptDendRestart()
    }

    /// Hosts whose running dend is from an older Den and refused this one,
    /// until restarted.
    private(set) var outdatedDends: Set<HostID> = []

    /// One prompt for every outdated dend. "Later" leaves them running; the
    /// placeholder (this Mac) and Reconnect (remote hosts) ask again.
    private func promptDendRestart() {
        guard !outdatedDends.isEmpty else { return }
        let remotes = outdatedDends.filter { $0 != .local }.map(hostLabel).sorted()
        let places = (outdatedDends.contains(.local) ? ["this Mac"] : []) + remotes
        let message = outdatedDends == [.local]
            ? "dend is from an older Den. Restart it to connect; its sessions will end."
            : "dend on \(places.joined(separator: ", ")) is from an older Den. Restart to connect; sessions there will end."
        showActionToast(message, actions: [
            ("Restart dend", nil, { [weak self] in Task { await self?.restartOutdatedDends() } }),
            ("Later", nil, {}),
        ])
    }

    /// Stops each outdated dend, ending its sessions, and connects to this
    /// Den's in its place.
    func restartOutdatedDends() async {
        let hosts = outdatedDends
        outdatedDends = []
        for host in hosts {
            switch host {
            case .local:
                connectionState = .connecting
                do {
                    try await DendLauncher.stopRunning()
                } catch {
                    outdatedDends.insert(.local)
                    connectionState = .disconnected(error.description)
                    continue
                }
                await connect()
            case .remote(let id):
                guard let remote = remoteHost(id) else { continue }
                remoteStates[id] = .connecting(step: "Restarting dend on \(remote.address)…")
                switch await SSH(host: remote).run(RemoteSetup.restartCommand) {
                case .failure(let failure):
                    outdatedDends.insert(host)
                    remoteStates[id] = .failed("Restarting dend on \(remote.address) failed: \(failure). Its old dend may still be running with its sessions; try again from the session menu.")
                case .success:
                    connectRemote(id, reveal: false)
                }
            }
        }
    }

    private func restore(_ id: PaneID, _ restored: Result<RestoredTerminal, VTError>) {
        statusSyncPending.insert(id)
        switch restored {
        case .success(let restored):
            if let existing = replicas[id] {
                existing.reset(terminal: restored.terminal)
            } else {
                let replica = PaneReplica(id: id, terminal: restored.terminal, theme: theme, contrastCorrection: contrastCorrection)
                replica.onTitleChange = { [weak self] title in self?.titles[id] = title }
                replica.onBell = { [weak self] in self?.markActivity(id) }
                replicas[id] = replica
                titles[id] = replica.terminal.title
                lastSeen[id] = Date()
            }
        case .failure(let error):
            lastError = "Could not restore a pane from dend's snapshot: \(error). The pane keeps running in dend; restart Den to resync."
        }
    }

    private func handle(_ message: ServerMessage, from host: HostID) {
        switch message {
        case .welcome(let version, let name):
            protocols[host] = version
            send(.subscribe, to: host)
            switch host {
            case .local:
                connectionState = .connected(host: name)
            case .remote(let id):
                remoteStates[id] = .connected(hostName: name)
                retryDelays[id] = nil
                announcedFailures.remove(id)
                endHostToast(id, "Connected to \(remoteHost(id)?.label ?? name)")
                if version >= 5 {
                    Task { [weak self] in
                        if let (home, _) = await self?.listDirectory("~", on: host) { self?.hostHomes[host] = home }
                    }
                }
                installKeyIfNeeded(on: id)
            }

        case .sessions(let list):
            hostSessions[host] = list
            for s in list { sessionHosts[s.id] = host }
            let live = Set(list.map(\.id))
            for (sid, h) in sessionHosts where h == host && !live.contains(sid) {
                sessionHosts.removeValue(forKey: sid)
                layouts.removeValue(forKey: sid)
            }
            rebuildSessions()
            if let current = currentSession, sessionHosts[current] == nil, pendingSession != current {
                currentSession = nil
                pickSession(excluding: current)
            }
            switch host {
            case .local:
                if list.isEmpty, !creatingFirstSession, pendingSession == nil {
                    creatingFirstSession = true
                    createSession(name: "", on: .local)
                }
            case .remote(let id):
                // A host you just connected to opens on screen: its first
                // session, or a new one when it has none.
                guard revealOnConnect.remove(id) != nil else { break }
                if let first = list.first {
                    if layouts[first.id] != nil { switchSession(first.id) } else { pendingSession = first.id }
                } else {
                    createSession(name: "", on: host)
                }
            }

        case .layout(let layout):
            sessionHosts[layout.session.id] = host
            for pane in layout.tabs.flatMap(\.root.panes) { paneHosts[pane] = host }
            apply(layout)

        case .directoryListing(let request, let path, let entries):
            listings.removeValue(forKey: request)?.reply.resume(returning: (path, entries))

        case .paneSnapshot:
            // DenConnection restores snapshots and delivers them as `.snapshot`.
            break

        case .paneOutput(let id, let bytes):
            // Output means the attach sync is over (an older dend sends no
            // status message when a pane has none).
            statusSyncPending.remove(id)
            replicas[id]?.write(bytes)
            lastOutput[id] = Date()
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
            let before = StatusRecords(programStatus[id] ?? []).headline?.phase
            if statusSince[id] == nil || StatusRecords(records).headline?.phase != before { statusSince[id] = Date() }
            programStatus[id] = records
            if isVisible(id) { seenStatus[id] = records }

        case .paneExited(let id, _):
            dropPane(id)

        case .sessionClosed(let id):
            layouts.removeValue(forKey: id)
            activeTabs.removeValue(forKey: id)
            sessionHosts.removeValue(forKey: id)
            if currentSession == id {
                currentSession = nil
                pickSession(excluding: id)
            }

        case .controlReply, .controlEvent:
            // Only the den CLI asks for these.
            break

        case .error(let message):
            lastError = host == .local ? message : "\(hostLabel(host)): \(message)"
        }
    }

    /// What takes over from the item that was at `closedAt`: the one before
    /// it, or the first when it was first (or unknown).
    nonisolated static func neighbor<T>(of closedAt: Int?, in items: [T]) -> T? {
        guard let closedAt, !items.isEmpty else { return items.first }
        return items[min(max(closedAt - 1, 0), items.count - 1)]
    }

    private func apply(_ layout: SessionLayout) {
        let sid = layout.session.id
        let previous = layouts[sid]
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
            // A closed tab hands over to the one before it, like a browser.
            let closedAt = previous?.tabs.firstIndex { $0.id == activeTabs[sid] }
            activeTabs[sid] = Self.neighbor(of: closedAt, in: layout.tabs)?.id
        }
        for tab in layout.tabs where !(focusedPanes[tab.id].map(tab.root.contains) ?? false) {
            let oldPanes = previous?.tabs.first { $0.id == tab.id }?.root.panes ?? []
            let closedAt = focusedPanes[tab.id].flatMap(oldPanes.firstIndex)
            focusedPanes[tab.id] = Self.neighbor(of: closedAt, in: tab.root.panes)
        }
        if let z = zoomedPane, !live.contains(z) { zoomedPane = nil }

        if pendingSession == sid {
            pendingSession = nil
            switchSession(sid)
        } else if awaitingRemembered == sid {
            // The last session you had open, possibly on a host that
            // connected after this Mac's dend.
            switchSession(sid)
        } else if currentSession == nil {
            // Reopen the last session; the session list arrives before
            // layouts. Meanwhile show this one, still waiting for that.
            let rememberedExists = awaitingRemembered.map { r in sessions.contains { $0.id == r } } ?? false
            if !rememberedExists { show(sid) }
        }
    }

    private func pickSession(excluding: SessionID) {
        if let next = sessions.first(where: { $0.id != excluding && layouts[$0.id] != nil }) {
            switchSession(next.id)
        } else {
            createSession(name: "", on: .local)
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

    // MARK: Remote hosts

    /// Seconds before the next reconnect attempt, doubling up to a minute.
    @ObservationIgnored private var retryDelays: [RemoteHost.ID: Int] = [:]

    func remoteHost(_ id: RemoteHost.ID) -> RemoteHost? { remoteHosts.first { $0.id == id } }

    func hostLabel(_ host: HostID) -> String {
        switch host {
        case .local: "This Mac"
        case .remote(let id): remoteHost(id)?.label ?? "A removed host"
        }
    }

    func sessions(on host: HostID) -> [SessionSummary] {
        orderedSessions.filter { (sessionHosts[$0.id] ?? .local) == host }
    }

    /// Adds a host from what was typed (`user@host:port`) and connects;
    /// a host already saved is reconnected or brought to the front instead.
    func addRemoteHost(_ text: String) {
        guard let parsed = RemoteHost.parse(text) else {
            lastError = "“\(text)” isn't a host address. Type a name or IP, optionally with a user and port (user@host:2222). No host was added."
            return
        }
        if let existing = remoteHosts.first(where: { $0.sameDestination(as: parsed) }) {
            if let session = sessions(on: .remote(existing.id)).first {
                switchSession(session.id)
            } else {
                connectRemote(existing.id, reveal: true)
            }
            return
        }
        remoteHosts.append(parsed)
        RemoteHostStore.save(remoteHosts)
        connectRemote(parsed.id, reveal: true)
    }

    /// Forgets a host and its saved password. Its sessions keep running on
    /// the host; adding it again reattaches them.
    /// Names a saved host; an empty name goes back to its address.
    func renameRemoteHost(_ id: RemoteHost.ID, to name: String?) {
        guard let i = remoteHosts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteHosts[i].name = trimmed?.isEmpty == false ? trimmed : nil
        RemoteHostStore.save(remoteHosts)
    }

    func removeRemoteHost(_ id: RemoteHost.ID) {
        guard let host = remoteHost(id) else { return }
        disconnectRemote(id)
        endHostToast(id)
        remoteHosts.removeAll { $0.id == id }
        RemoteHostStore.save(remoteHosts)
        SSHPasswords.delete(for: host.account)
        remoteStates[id] = nil
        retryDelays[id] = nil
        if loginRequest?.host == id { loginRequest = nil }
        for (sid, h) in sessionHosts where h == .remote(id) { sessionHosts.removeValue(forKey: sid) }
        rebuildSessions()
        if let current = currentSession, sessionHosts[current] == nil {
            currentSession = nil
            pickSession(excluding: current)
        }
        showToast("Removed \(host.label)")
    }

    /// Connects now, replacing any connection or attempt in progress.
    /// `reveal` brings the host's session on screen once it's up.
    func connectRemote(_ id: RemoteHost.ID, reveal: Bool) {
        guard let host = remoteHost(id) else { return }
        if reveal {
            revealOnConnect.insert(id)
            // Asked for again: a new failure gets its own toast.
            announcedFailures.remove(id)
        }
        // An explicit connect re-arms launch auto-connect and retries; a
        // disconnect clears it (see disconnectHost), so it sticks.
        if let i = remoteHosts.firstIndex(where: { $0.id == id }), !remoteHosts[i].autoConnect {
            remoteHosts[i].autoConnect = true
            RemoteHostStore.save(remoteHosts)
        }
        // Already on its way (maybe mid-upload): starting over would only
        // throw that work away.
        switch remoteStates[id] {
        case .connecting?, .uploading?: if setups[id] != nil { return }
        default: break
        }
        disconnectRemote(id)
        remoteStates[id] = .connecting(step: "Connecting to \(host.address)…")
        let attempt = attempts[id, default: 0]
        setups[id] = Task { [weak self] in
            await self?.establish(host, attempt: attempt)
            if self?.attempts[id] == attempt { self?.setups[id] = nil }
        }
    }

    /// Ends a host's connection and stops retrying. Its sessions keep
    /// running on the host for the next connect.
    func disconnectHost(_ id: RemoteHost.ID) {
        revealOnConnect.remove(id)
        disconnectRemote(id)
        endHostToast(id)
        retryDelays[id] = nil
        // Persisted: a disconnected host stays disconnected across restarts
        // until explicitly connected again.
        if let i = remoteHosts.firstIndex(where: { $0.id == id }), remoteHosts[i].autoConnect {
            remoteHosts[i].autoConnect = false
            RemoteHostStore.save(remoteHosts)
        }
        remoteStates[id] = .disconnected
        if let current = currentSession, sessionHosts[current] == .remote(id) {
            if let next = orderedSessions.first(where: { sessionHosts[$0.id] != .remote(id) }) { switchSession(next.id) }
        }
    }

    /// Connected hosts disconnect, others connect (clicking a saved host).
    func toggleHost(_ id: RemoteHost.ID) {
        if remoteStates[id]?.isConnected == true { disconnectHost(id) } else { connectRemote(id, reveal: true) }
    }

    /// Each host's connection attempt in flight; cancelling it ends its ssh.
    @ObservationIgnored private var setups: [RemoteHost.ID: Task<Void, Never>] = [:]
    /// Hosts whose dend boot persistence was ensured this launch (fresh
    /// install or persistCommand), so it isn't re-run on every reconnect.
    @ObservationIgnored private var persistenceEnsured: Set<RemoteHost.ID> = []
    /// The toast each host has up: its dend setup's progress, or a failure.
    @ObservationIgnored private var hostToasts: [RemoteHost.ID: UUID] = [:]
    /// Hosts whose current failure streak was already toasted.
    @ObservationIgnored private var announcedFailures: Set<RemoteHost.ID> = []

    /// Ends the connection and invalidates attempts and retries in flight.
    private func disconnectRemote(_ id: RemoteHost.ID) {
        attempts[id, default: 0] += 1
        setups.removeValue(forKey: id)?.cancel()
        channels.removeValue(forKey: id)?.terminate()
        endHostToast(id, keepFailure: true)
        if connections[.remote(id)] != nil { connectionClosed(.remote(id), "disconnected") }
    }

    /// Probe, install or update dend if needed, then open the stream.
    private func establish(_ host: RemoteHost, attempt: Int) async {
        let id = host.id
        let ssh = SSH(host: host)
        let probe: RemoteSetup.Probe
        switch await ssh.run(RemoteSetup.probeCommand) {
        case .failure(let failure):
            guard attempts[id] == attempt else { return }
            return setupFailed(host, failure)
        case .success(let output):
            guard attempts[id] == attempt else { return }
            guard let parsed = RemoteSetup.parseProbe(output.text) else {
                return setupFailed(host, .launch("\(host.address) answered Den's setup check with output Den can't read (\(output.text.prefix(120))). Nothing was installed."))
            }
            probe = parsed
        }

        let binary: URL
        switch RemoteSetup.binary(for: probe) {
        case .failure(let failure): return setupFailed(host, failure)
        case .success(.file(let url)): binary = url
        case .success(.release(let url, let cache)):
            let what = "dend for \(probe.os) \(probe.arch)"
            remoteStates[id] = .downloading(received: 0, total: 0)
            showSetupProgress(id, "Downloading \(what)…", 0)
            let downloaded = await RemoteSetup.download(url, to: cache) { [weak self] received, total in
                Task { @MainActor in
                    guard let self, self.attempts[id] == attempt else { return }
                    self.remoteStates[id] = .downloading(received: received, total: total)
                    let fraction = total > 0 ? Double(received) / Double(total) : nil
                    self.showSetupProgress(id, "Downloading \(what)… \(fraction.map { "\(Int($0 * 100))%" } ?? "\(received >> 20) MB")", fraction ?? 0)
                }
            }
            guard attempts[id] == attempt else { return }
            switch downloaded {
            case .failure(let failure): return setupFailed(host, failure)
            case .success(let url): binary = url
            }
        }
        if RemoteSetup.sha256(of: binary) != probe.installedHash {
            guard let data = try? Data(contentsOf: binary) else {
                return setupFailed(host, .launch("Den could not read its dend build at \(binary.path). Nothing was installed."))
            }
            let total = data.count, isUpdate = probe.installedHash != nil
            let verb = isUpdate ? "Updating" : "Installing"
            remoteStates[id] = .uploading(sent: 0, total: total, isUpdate: isUpdate)
            showSetupProgress(id, "\(verb) dend on \(host.label)…", 0)
            let installed = await ssh.run(RemoteSetup.installCommand, input: data, compress: true) { [weak self] sent in
                Task { @MainActor in
                    guard let self, self.attempts[id] == attempt else { return }
                    self.remoteStates[id] = .uploading(sent: sent, total: total, isUpdate: isUpdate)
                    self.showSetupProgress(id, "\(verb) dend on \(host.label)… \(sent * 100 / max(total, 1))%", Double(sent) / Double(max(total, 1)))
                }
            }
            guard attempts[id] == attempt else { return }
            if case .failure(let failure) = installed { return setupFailed(host, failure) }
            // A fresh install registers boot persistence itself.
            persistenceEnsured.insert(id)
        } else if !probe.serviceRegistered, !persistenceEnsured.contains(id) {
            // dend predates boot persistence (or the service was removed):
            // register it so the daemon is back after a reboot. Best-effort
            // and once per launch; on-demand start over SSH covers the rest.
            persistenceEnsured.insert(id)
            let persisted = await ssh.run(RemoteSetup.persistCommand)
            guard attempts[id] == attempt else { return }
            if case .failure(let failure) = persisted {
                NSLog("Den: boot persistence not registered on %@: %@", host.label, failure.description)
            }
        }

        remoteStates[id] = .connecting(step: "Attaching to \(host.address)…")
        if let toastID = hostToasts[id], toast?.id == toastID, toast?.progress != nil {
            showSetupProgress(id, "Starting dend on \(host.label)…", 1)
        }
        switch ssh.openChannel(RemoteSetup.streamCommand) {
        case .failure(let failure):
            setupFailed(host, failure)
        case .success(let channel):
            guard attempts[id] == attempt else { return channel.terminate() }
            channels[id] = channel
            attach(fd: channel.fd, to: .remote(id)) { [weak self] reason in
                self?.remoteClosed(id, attempt: attempt, reason: reason, channel: channel)
            }
        }
    }

    /// Mirrors a host's dend download and install into a progress toast.
    private func showSetupProgress(_ id: RemoteHost.ID, _ message: String, _ fraction: Double) {
        showUpdateProgress(message, progress: fraction)
        if let toast, toast.progress != nil { hostToasts[id] = toast.id }
    }

    /// Takes down a host's toast, if it's still the one on screen, showing
    /// `message` in its place. `keepFailure` leaves a failure toast up, so
    /// it isn't swept away by the retry that follows it.
    private func endHostToast(_ id: RemoteHost.ID, _ message: String? = nil, keepFailure: Bool = false) {
        guard let toastID = hostToasts[id], let current = toast, current.id == toastID else {
            hostToasts[id] = nil
            return
        }
        if keepFailure, current.progress == nil { return }
        hostToasts[id] = nil
        // Dismissed first: showToast would put an action toast back after it.
        dismissToast()
        if let message { showToast(message) }
    }

    /// "Couldn't connect" with the reason and Try Again, once per failure
    /// streak; retries in the background don't bring it back.
    private func showHostFailure(_ host: RemoteHost, _ reason: String) {
        guard !announcedFailures.contains(host.id) else { return }
        announcedFailures.insert(host.id)
        showActionToast("Couldn't connect to \(host.label)", tone: .danger, detail: reason,
                        actions: [(label: "Try Again", shortcut: nil, handler: { [weak self] in self?.connectRemote(host.id, reveal: true) })],
                        dismiss: (shortcut: nil, handler: {}))
        if let toast { hostToasts[host.id] = toast.id }
    }

    private func setupFailed(_ host: RemoteHost, _ failure: SSH.Failure) {
        let id = host.id
        endHostToast(id)
        switch failure {
        case .authentication:
            remoteStates[id] = .needsLogin
            // Only interrupt with a form when you asked for this host;
            // background reconnects wait in the session menu instead.
            guard revealOnConnect.contains(id) else { return }
            let triedPassword = SSHPasswords.exists(for: host.account)
            loginRequest = LoginRequest(
                host: id, user: host.user ?? NSUserName(),
                message: triedPassword ? "That user name and password didn't work. Nothing was changed on the host; check them and try again." : nil
            )
        case .unreachable(let detail):
            // Hosts that are down or asleep get retried until they're up.
            let reason = detail.isEmpty ? "\(host.address) isn't answering." : detail
            // Said out loud only when you asked for this host; launch
            // auto-connects show it in the sidebar instead.
            if revealOnConnect.contains(id) { showHostFailure(host, "Can't reach \(host.address). \(reason) Den keeps retrying.") }
            scheduleRetry(id, reason: reason)
        case .hostKeyChanged, .remote, .launch:
            revealOnConnect.remove(id)
            remoteStates[id] = .failed(failure.description)
            showHostFailure(host, failure.description)
        }
    }

    private func remoteClosed(_ id: RemoteHost.ID, attempt: Int, reason: String, channel: SSH.Channel) {
        guard attempts[id] == attempt else { return }
        channels[id] = nil
        endHostToast(id, keepFailure: true)
        connectionClosed(.remote(id), reason)
        let said = channel.lastError
        scheduleRetry(id, reason: said.isEmpty ? "The connection closed. Sessions keep running on the host." : said)
    }

    private func scheduleRetry(_ id: RemoteHost.ID, reason: String) {
        let delay = min((retryDelays[id] ?? 1) * 2, 60)
        retryDelays[id] = delay
        remoteStates[id] = .reconnecting(reason: reason, retryIn: delay)
        let attempt = attempts[id, default: 0]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.attempts[id] == attempt else { return }
            self.connectRemote(id, reveal: false)
        }
    }

    /// From the login form: saves the password to the Keychain and retries.
    func logIn(_ request: LoginRequest, password: String, installKey: Bool) {
        guard var host = remoteHost(request.host) else { return }
        let previous = host.account
        let user = request.user.trimmingCharacters(in: .whitespaces)
        host.user = user.isEmpty ? nil : user
        if let i = remoteHosts.firstIndex(where: { $0.id == host.id }) { remoteHosts[i] = host }
        RemoteHostStore.save(remoteHosts)
        if previous != host.account { SSHPasswords.delete(for: previous) }
        if case .failure(let failure) = SSHPasswords.save(password, for: host.account) {
            lastError = "\(failure). The password wasn't saved, so Den can't log in to \(host.address) with it. Unlock the login keychain and try again."
            return
        }
        loginRequest = nil
        host.keyLogin = installKey ? .wanted : .declined
        if let i = remoteHosts.firstIndex(where: { $0.id == host.id }) { remoteHosts[i] = host }
        RemoteHostStore.save(remoteHosts)
        connectRemote(host.id, reveal: true)
    }

    func cancelLogin() {
        guard let request = loginRequest else { return }
        loginRequest = nil
        revealOnConnect.remove(request.host)
    }

    /// Opens the login form for a host waiting on credentials.
    func requestLogin(_ id: RemoteHost.ID) {
        guard let host = remoteHost(id) else { return }
        revealOnConnect.insert(id)
        loginRequest = LoginRequest(host: id, user: host.user ?? NSUserName(), message: nil)
    }

    /// After a login that may have used the saved password, adds Den's
    /// public key to the host's authorized_keys so later logins don't read
    /// the password (and don't prompt for Keychain access). The password
    /// stays saved as a fallback. Survives restarts: the choice and the
    /// result live on the saved host.
    private func installKeyIfNeeded(on id: RemoteHost.ID) {
        guard let host = remoteHost(id), host.keyLogin != .declined, host.keyLogin != .installed,
              SSHPasswords.exists(for: host.account) else { return }
        Task { [weak self] in
            switch await RemoteSetup.publicKey() {
            case .failure(let failure):
                self?.lastError = "\(host.label): \(failure.description)"
            case .success(let key):
                switch await SSH(host: host).run(RemoteSetup.authorizeCommand(publicKey: key)) {
                case .success:
                    guard let self, let i = self.remoteHosts.firstIndex(where: { $0.id == id }) else { return }
                    self.remoteHosts[i].keyLogin = .installed
                    RemoteHostStore.save(self.remoteHosts)
                    self.showToast("Installed Den's SSH key on \(host.address)")
                case .failure(let failure):
                    self?.lastError = "Den couldn't add its SSH key on \(host.address): \(failure.description) Logins keep using the saved password."
                }
            }
        }
    }

    /// A folder's entries on `host`'s dend; nil when it's not connected or
    /// too old to list folders (protocol 5).
    func listDirectory(_ path: String, on host: HostID) async -> (String, [DirectoryEntry])? {
        guard (protocols[host] ?? 0) >= 5, let conn = connections[host] else { return nil }
        let request = nextListing
        nextListing &+= 1
        return await withCheckedContinuation { continuation in
            listings[request] = (host, continuation)
            conn.send(.listDirectory(request: request, path: path))
        }
    }

    /// Why the session on screen has nothing to show, when its host is
    /// remote and not connected.
    var currentHostProblem: (host: RemoteHost.ID, message: String)? {
        guard case .remote(let id) = currentHost, let sid = currentSession, layouts[sid] == nil else { return nil }
        let name = remoteHost(id)?.address ?? "the host"
        let message = switch remoteStates[id] {
        case .connecting(let step): step
        case .downloading, .uploading: remoteStates[id].map(HostStatus.detail) ?? ""
        case .needsLogin: "\(name) needs you to log in."
        case .reconnecting(let reason, let retryIn): "Lost \(name): \(reason) Retrying in \(retryIn)s; your sessions keep running there."
        case .failed(let reason): reason
        case .needsRestart: "dend on \(name) is from an older Den. Restart it from the prompt, or reconnect from the session menu to be asked again; restarting ends its sessions."
        case .disconnected: "Disconnected from \(name). Your sessions keep running there; reconnect from the session menu."
        case .connected, nil: "Reattaching to \(name)…"
        }
        return (id, message)
    }

    // MARK: Sessions

    var orderedSessions: [SessionSummary] { sessions.filter { layouts[$0.id] != nil } }

    /// The session last shown on each machine, where `cycleHost` returns to.
    @ObservationIgnored private var lastSessions: [HostID: SessionID] = [:]

    func switchSession(_ id: SessionID) {
        guard layouts[id] != nil || pendingSession == id else { return }
        awaitingRemembered = nil
        show(id)
    }

    /// Shows a session without giving up on reopening the remembered one.
    private func show(_ id: SessionID) {
        currentSession = id
        lastSessions[sessionHosts[id] ?? .local] = id
        zoomedPane = nil
        Self.writeRememberedSession(id)
        clearActivity()
    }

    /// Next/previous session on the machine on screen; other machines'
    /// sessions are a `cycleHost` away.
    func cycleSession(_ delta: Int) {
        let list = sessions(on: currentHost)
        guard let i = list.firstIndex(where: { $0.id == currentSession }), !list.isEmpty else { return }
        switchSession(list[(i + delta + list.count) % list.count].id)
    }

    /// go_to_session: the `number`th session (1-based) on the machine on screen.
    func goToSession(_ number: Int) {
        let list = sessions(on: currentHost)
        if list.indices.contains(number - 1) { switchSession(list[number - 1].id) }
    }

    /// Machines with sessions to show, This Mac first, then saved hosts in order.
    var hostsWithSessions: [HostID] {
        ([HostID.local] + remoteHosts.map { .remote($0.id) }).filter { !sessions(on: $0).isEmpty }
    }

    /// Moves to the next/previous machine, back to the session last shown there.
    func cycleHost(_ delta: Int) {
        let hosts = hostsWithSessions
        guard hosts.count > 1, let i = hosts.firstIndex(of: currentHost) else { return }
        let target = hosts[(i + delta + hosts.count) % hosts.count]
        let list = sessions(on: target)
        let last = lastSessions[target].flatMap { id in list.first { $0.id == id } }
        if let session = last ?? list.first { switchSession(session.id) }
    }

    /// A new session on `host`, by default the host of the session on screen.
    func createSession(name: String, on host: HostID? = nil) {
        let target = host ?? currentHost
        guard connections[target] != nil else {
            lastError = "\(hostLabel(target)) isn't connected, so no session was created. Wait for it to reconnect, or create the session on this Mac."
            return
        }
        let id = SessionID()
        pendingSession = id
        send(.createSession(id: id, name: name, size: defaultGridSize), to: target)
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
        // The tab's focused pane takes the keyboard back from whatever was
        // clicked to get here.
        terminalFocusRequest &+= 1
    }

    func focus(_ pane: PaneID) {
        guard let (sid, tab) = locate(pane) else { return }
        activeTabs[sid] = tab.id
        focusedPanes[tab.id] = pane
        if currentSession != sid { switchSession(sid) }
        activity.remove(pane)
        terminalFocusRequest &+= 1
    }

    /// Keyboard focus moved to a pane's view. Only updates which pane is
    /// focused within the active tab; tab and session stay put.
    func paneTookKeyboardFocus(_ pane: PaneID) {
        guard let tab = activeLayout, tab.root.contains(pane) else { return }
        focusedPanes[tab.id] = pane
        activity.remove(pane)
    }

    /// The window is key again (spaces, system gestures and other apps take
    /// it away): the focused pane takes the keyboard back, restoring a solid
    /// block cursor instead of a hollow one.
    func windowBecameKey() {
        terminalFocusRequest &+= 1
        reassertSizes(lastVisiblePanes)
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

    func appBecameActive() {
        reassertSizes(lastVisiblePanes)
        clearActivity()
        reloadConfig()
        reloadCustomThemes()
    }

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

    /// Moves `pane` beside `target` (or swaps them) within their tab. Needs
    /// a dend that speaks protocol 4; an older one would drop the connection.
    func movePane(_ pane: PaneID, to target: PaneID, placement: PanePlacement) {
        guard (protocols[host(ofPane: pane)] ?? 0) >= 4 else {
            lastError = "The running dend is older than this Den and can't move panes. Your panes are unchanged. Quit dend (its shells end) and reopen Den to use the new one."
            return
        }
        send(.movePane(pane, to: target, placement: placement))
    }

    // MARK: ⌘-drag panes

    struct PaneDragState: Equatable {
        let source: PaneID
        /// Pointer, in window (SwiftUI global) coordinates.
        var point: CGPoint
        var target: PaneID?
        var placement: PanePlacement?
    }
    private(set) var paneDrag: PaneDragState?
    /// Each visible pane's frame in window coordinates, for drop hit-testing.
    @ObservationIgnored var paneFrames: [PaneID: CGRect] = [:]

    /// Only when the tab has somewhere to move the pane to.
    func beginPaneDrag(_ pane: PaneID, at point: CGPoint) -> Bool {
        guard let tab = activeLayout, tab.root.contains(pane), tab.root.panes.count > 1 else { return false }
        paneDrag = PaneDragState(source: pane, point: point)
        return true
    }

    func updatePaneDrag(at point: CGPoint) {
        guard var drag = paneDrag, let tab = activeLayout else { return }
        drag.point = point
        let target = tab.root.panes.first { $0 != drag.source && paneFrames[$0]?.contains(point) == true }
        drag.target = target
        drag.placement = target.flatMap { id in
            paneFrames[id].map { frame in PaneDrag.placement(at: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY), in: frame.size) }
        }
        if drag != paneDrag { paneDrag = drag }
    }

    /// Drops where the pointer is; outside any other pane it's a no-op.
    func endPaneDrag() {
        guard let drag = paneDrag else { return }
        paneDrag = nil
        if let target = drag.target, let placement = drag.placement { movePane(drag.source, to: target, placement: placement) }
    }

    /// Swaps the focused pane with its neighbor in `direction`; focus
    /// travels with the pane.
    /// Focuses the pane beside the focused one (leader+h/j/k/l).
    func focusPane(_ direction: PaneDirection) {
        guard let tab = activeLayout, let pane = focused, let neighbor = tab.root.neighbor(of: pane, toward: direction) else { return }
        focus(neighbor)
    }

    /// Moves the focused pane's nearest edge toward `direction` by 5% of
    /// its split (leader+shift+h/j/k/l). dend keeps ratios within 10–90%.
    func resizePane(_ direction: PaneDirection) {
        guard let tab = activeLayout, let pane = focused else { return }
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        guard let (path, ratio) = tab.root.enclosingSplit(of: pane, axis: axis) else { return }
        let step: Float = direction == .right || direction == .down ? 0.05 : -0.05
        setRatio(tab: tab.id, path: path, ratio: min(max(ratio + step, 0.1), 0.9))
    }

    func moveFocusedPane(_ direction: PaneDirection) {
        guard let tab = activeLayout, let pane = focused, let neighbor = tab.root.neighbor(of: pane, toward: direction) else { return }
        movePane(pane, to: neighbor, placement: .swap)
    }

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
        reassertSizes([pane])
        send(.input(pane, bytes))
    }

    /// dend sizes a pane for whichever client asked last, so another client
    /// on the same session (a second Den, the CLI) can leave it bigger than
    /// this window: the bottom rows fall off the pane. Sends this window's
    /// size again where the pane's current grid differs from it.
    private func reassertSizes(_ panes: [PaneID]) {
        for pane in panes {
            guard let size = sentSizes[pane], let terminal = replicas[pane]?.terminal,
                  terminal.cols != size.cols || terminal.rows != size.rows else { continue }
            send(.resize(pane, size))
        }
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

    // MARK: Path picker

    func openPathPicker() {
        guard let pane = focused, let terminal = replicas[pane]?.terminal else { return }
        let cursor = terminal.cursorPosition
        pathPicker = PathPickerRequest(pane: pane, cwd: cwd(of: pane), col: Int(cursor.col), row: Int(cursor.row), rows: Int(terminal.rows))
    }

    /// Types the path at the pane's cursor, as if the user had.
    func insertPath(_ path: String) {
        guard let request = pathPicker else { return }
        let host = host(ofPane: request.pane)
        let text = PathQuery.insertion(for: path, cwd: request.cwd, home: hostHomes[host])
        replicas[request.pane]?.scroll(.bottom)
        input(request.pane, Data(text.utf8))
        // Recents are this Mac's paths; a remote host's would mislead.
        if host == .local {
            recentPaths = Array(([path] + recentPaths.filter { $0 != path }).prefix(20))
            defaults.set(recentPaths, forKey: "recentPaths")
        }
        rememberPathPickerFolder((path as NSString).deletingLastPathComponent, on: host)
        pathPicker = nil
    }

    /// Where the picker opens on `host`: the folder it last closed in, if
    /// that still exists (a remote one can't be checked from here).
    func pathPickerFolder(on host: HostID) -> String? {
        guard let folder = pathPickerFolders[host] else { return nil }
        var isDir: ObjCBool = false
        return host != .local || (FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue) ? folder : nil
    }

    func rememberPathPickerFolder(_ folder: String, on host: HostID) {
        pathPickerFolders[host] = folder
        if host == .local { defaults.set(folder, forKey: "pathPickerFolder") }
    }

    func dismissError() { lastError = nil }

    func report(_ message: String) { lastError = message }

    // MARK: Config

    /// `~/.config/den/config.toml`, read on launch and when Den comes back
    /// to the front; a broken file keeps the previous config.
    private(set) var config = UserConfig()
    @ObservationIgnored private var configStamp: Date?
    /// Settings' shortcut recorder is listening; Den's own key handling
    /// (leader, menus) stands aside meanwhile.
    @ObservationIgnored var isRecordingShortcut = false
    /// Opens the Settings window; set by the app delegate.
    @ObservationIgnored var showSettings: (() -> Void)?
    /// Called after a new config loads, so the menu picks up its shortcuts.
    @ObservationIgnored var configDidChange: (() -> Void)?

    /// Re-reads the config. Unless `force`, does nothing when the file
    /// hasn't changed since the last read.
    func reloadConfig(force: Bool = false) {
        syncStoredThemeNames()
        applyTheme()
        let url = UserConfig.url
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard force || stamp != configStamp else { return }
        configStamp = stamp
        switch UserConfig.load(from: url) {
        case .success(let loaded):
            config = loaded
            applyConfigFonts()
            configDidChange?()
            if force { showToast("Config reloaded") }
        case .failure(let error):
            report("Den's config at \(url.path) has an error, so the previous settings stay in use: \(error.message) Fix it and run Reload Config.")
        }
    }

    /// Writes one setting to config.toml (creating it from the template
    /// first) and applies it at once. `nil` removes the key, restoring the
    /// default. Comments and other keys in the file stay as written.
    func setConfig(_ key: String, _ value: TOMLValue?, table: String? = nil) {
        let url = UserConfig.url
        do {
            let existing = FileManager.default.fileExists(atPath: url.path)
                ? try String(contentsOf: url, encoding: .utf8)
                : UserConfig.template
            let edited = ConfigEdit.setting(key, to: value, inTable: table, of: existing)
            // Check before writing: a setting must never leave the file broken.
            if case .failure(let error) = UserConfig.parse(edited) {
                return report("Den didn't save \(table.map { "[\($0)] " } ?? "")\(key) because the result wouldn't load: \(error.message) \(url.path) is unchanged.")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try edited.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return report("Could not save \(key) to \(url.path): \(error.localizedDescription). The setting is unchanged; check the folder's permissions.")
        }
        configStamp = nil
        reloadConfig()
    }

    /// Terminal font keys from the config win over the persisted palette
    /// choices (and are persisted themselves).
    private func applyConfigFonts() {
        if let family = config.terminalFont { fontFamily = family }
        if let size = config.terminalFontSize { fontSize = CGFloat(size) }
    }

    /// Set by the leader key until the next keypress, which picks the command.
    private(set) var leaderPending = false

    /// Digits typed for go_to_tab/go_to_session, while more could follow.
    private struct NumberEntry {
        let command: DenCommand
        let modifiers: Set<KeyChord.Modifier>
        var digits: String
    }
    @ObservationIgnored private var numberEntry: NumberEntry?
    @ObservationIgnored private var numberCommit: Task<Void, Never>?

    /// App-wide key filter for leader shortcuts and digit shortcuts. True
    /// when it used the key. The leader pressed twice goes through to the
    /// program.
    func handleKey(keyCode: UInt16, unmodified: String?, flags: NSEvent.ModifierFlags) -> Bool {
        // Settings is recording a shortcut: every key goes to the recorder.
        if isRecordingShortcut { return false }
        // A button toast's shortcuts (shown in its buttons) fire first, so
        // the update's Relaunch/Dismiss keys work even while typing.
        if let toast, !toast.actions.isEmpty {
            for action in toast.actions where action.chord?.matches(keyCode: keyCode, unmodified: unmodified, flags: flags) == true {
                performToastAction(action.id)
                return true
            }
        }
        let digit = KeyChord.digit(unmodified)
        if let entry = numberEntry {
            let held = KeyChord.modifiers(of: flags)
            if let digit, held == entry.modifiers || held.isEmpty {
                enterDigit(digit, entry)
                return true
            }
            commitNumber()
        }

        let isLeader = config.leader.matches(keyCode: keyCode, unmodified: unmodified, flags: flags)
        if leaderPending {
            leaderPending = false
            if isLeader { return false }
            switch config.afterLeader(keyCode: keyCode, unmodified: unmodified, flags: flags) {
            case .command(let command)? where command.takesNumber:
                if let digit { enterDigit(digit, NumberEntry(command: command, modifiers: KeyChord.modifiers(of: flags), digits: "")) }
            case .command(let command)?: command.perform(self)
            case .text(let bytes)?: if let pane = focused { input(pane, bytes) }
            case .passthrough?: return false
            case .ignore?, nil: break
            }
            return true
        }
        if isLeader {
            leaderPending = true
            return true
        }
        if let digit, let command = config.numberCommand(keyCode: keyCode, unmodified: unmodified, flags: flags) {
            enterDigit(digit, NumberEntry(command: command, modifiers: KeyChord.modifiers(of: flags), digits: ""))
            return true
        }
        return false
    }

    /// Acts at once unless another digit could still name a target (1 with
    /// 12 tabs might become 12); then waits briefly for it.
    private func enterDigit(_ digit: Int, _ entry: NumberEntry) {
        var entry = entry
        entry.digits += String(digit)
        numberCommit?.cancel()
        let number = Int(entry.digits) ?? 0
        let count = entry.command == .goToTab ? tabs.count : orderedSessions.count
        guard number * 10 <= count else {
            numberEntry = nil
            entry.command.perform(self, number: number)
            return
        }
        numberEntry = entry
        numberCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.commitNumber()
        }
    }

    private func commitNumber() {
        numberCommit?.cancel()
        guard let entry = numberEntry else { return }
        numberEntry = nil
        entry.command.perform(self, number: Int(entry.digits) ?? 0)
    }

    /// The Ghostty migration the palette is showing.
    private(set) var ghosttyMigration: GhosttyMigrationRun?

    /// Carries Ghostty's theme, option key and keybinds into Den, step by
    /// step so the palette can show progress.
    func migrateFromGhostty() {
        ghosttyMigration = GhosttyMigrationRun()
        palette = .migrateGhostty
        Task {
            var run = GhosttyMigrationRun()
            // Short beats between steps so each one registers.
            @MainActor func advance(_ step: GhosttyMigrationRun.StepID, _ status: GhosttyMigrationRun.Status) async {
                run.set(step, .running)
                ghosttyMigration = run
                try? await Task.sleep(for: .milliseconds(260))
                run.set(step, status)
                ghosttyMigration = run
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = [home.appending(path: ".config/ghostty/config"),
                              home.appending(path: "Library/Application Support/com.mitchellh.ghostty/config")]
            guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let ghostty = try? String(contentsOf: source, encoding: .utf8) else {
                await advance(.source, .failed("Not found"))
                run.phase = .failed("No Ghostty config at ~/.config/ghostty/config. Nothing changed.")
                ghosttyMigration = run
                return
            }
            await advance(.source, .done(PathQuery.abbreviate(source.path)))

            let target = UserConfig.url
            let existing = FileManager.default.fileExists(atPath: target.path)
                ? (try? String(contentsOf: target, encoding: .utf8)) ?? ""
                : UserConfig.template
            let outcome: GhosttyMigration.Outcome
            switch GhosttyMigration.migrate(ghostty: ghostty, into: existing) {
            case .success(let o): outcome = o
            case .failure(let e):
                await advance(.option, .failed("Config has an error"))
                run.phase = .failed(e.message)
                ghosttyMigration = run
                return
            }
            if outcome.config != existing {
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try outcome.config.write(to: target, atomically: true, encoding: .utf8)
                } catch {
                    await advance(.option, .failed("Could not save"))
                    run.phase = .failed("Could not write \(target.path): \(error.localizedDescription). Your config is unchanged.")
                    ghosttyMigration = run
                    return
                }
                configStamp = nil
                reloadConfig()
            }
            await advance(.option, outcome.optionAsAlt.map { .done(Self.optionLabel($0)) } ?? .skipped("Not set"))
            let skipped = outcome.skipped.isEmpty ? "" : " · \(outcome.skipped.count) unsupported"
            await advance(.keybinds, outcome.keybinds.isEmpty && outcome.skipped.isEmpty
                ? .skipped("None") : .done("\(outcome.keybinds.count) added\(skipped)"))

            let themeStatus: GhosttyMigrationRun.Status
            do {
                let theme = try ThemeImport.install(source)
                customThemes.removeAll { $0.name == theme.name }
                customThemes.append(theme)
                selectTheme(theme)
                themeStatus = .done(theme.name)
            } catch {
                themeStatus = .skipped("No colors set")
            }
            await advance(.theme, themeStatus)
            run.phase = .finished
            ghosttyMigration = run
        }
    }

    private static func optionLabel(_ value: String) -> String {
        switch value {
        case "left": "Left option is Alt"
        case "right": "Right option is Alt"
        case "true": "Option is Alt"
        default: "Option types symbols"
        }
    }

    /// Opens the config in TextEdit, writing a commented starter file first
    /// if there isn't one.
    func openConfigFile() {
        let url = UserConfig.url
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try UserConfig.template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return report("Could not create \(url.path): \(error.localizedDescription). Create it by hand to configure Den.")
            }
        }
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.report("TextEdit could not open \(url.path): \(error.localizedDescription). The file is there to edit with any editor.")
            }
        }
    }

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

    func dragOverview(_ progress: CGFloat) {
        // The first movement of a swipe drops any selection a
        // three-finger-drag gesture started before we began swallowing its
        // mouse events, so the terminal never sits highlighted under the glance.
        if overviewDrag == nil {
            for replica in replicas.values { replica.clearSelection() }
        }
        overviewDrag = progress
    }

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

    var themesForCurrentAppearance: [Theme] { themes(for: effectiveAppearance) }

    func themes(for appearance: Appearance) -> [Theme] {
        let builtIn = appearance == .dark ? ThemeCatalog.dark : ThemeCatalog.light
        // A hand-written theme with a built-in's name replaces it.
        let shadowed = Set(customThemes.map(\.name))
        return builtIn.filter { !shadowed.contains($0.name) }
            + customThemes.filter { $0.appearance == appearance }
    }

    /// Makes `theme` the one used in its appearance, without switching
    /// appearance (Settings lists light and dark themes side by side).
    func useTheme(_ theme: Theme) {
        if theme.appearance == .dark { darkThemeName = theme.name } else { lightThemeName = theme.name }
        applyTheme()
    }

    /// Files in `~/.config/den/themes/` that failed to parse, for the
    /// theme picker to surface.
    private(set) var themeFileErrors: [ThemeJSON.FileError] = []
    @ObservationIgnored private var themeWatcher: ThemeWatcher?

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
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue, url.pathExtension.lowercased() == "json" {
            do {
                let themes = try ThemeImport.installJSON(from: url)
                reloadCustomThemes()
                // Select the matching variant for the current appearance.
                let pick = themes.first { $0.appearance == effectiveAppearance } ?? themes[0]
                selectTheme(customThemes.first { $0.name == pick.name && $0.appearance == pick.appearance } ?? pick)
            } catch {
                lastError = error.description
            }
            return
        }
        do {
            let theme = try ThemeImport.install(url)
            reloadCustomThemes()
            selectTheme(customThemes.first { $0.name == theme.name && $0.appearance == theme.appearance } ?? theme)
        } catch {
            lastError = error.description
        }
    }

    func deleteCustomTheme(_ theme: Theme) {
        ThemeImport.remove(theme)
        reloadCustomThemes()
        applyTheme()
    }

    /// Re-reads hand-written JSON themes (and Ghostty imports). Saved edits
    /// to the selected theme apply at once; a deleted one falls back.
    func reloadCustomThemes() {
        syncStoredThemeNames()
        let loaded = ThemeImport.installedWithErrors()
        customThemes = loaded.themes
        themeFileErrors = loaded.errors
        guard previewTheme == nil else { return }
        let name = selectedThemeName
        if customThemes.contains(where: { $0.name == name && $0.appearance == effectiveAppearance }) {
            applyTheme()
        } else if theme.isCustom, !customThemes.contains(where: { $0.name == theme.name && $0.appearance == theme.appearance }) {
            applyTheme()
        }
    }

    /// Adopts theme names another tool (such as Hued) wrote to the defaults
    /// while Den runs; otherwise they would only be read at launch.
    private func syncStoredThemeNames() {
        func stored(_ key: String) -> String? { defaults.string(forKey: key).map { ThemeCatalog.renamed[$0] ?? $0 } }
        if let dark = stored("darkTheme"), dark != darkThemeName { darkThemeName = dark }
        if let light = stored("lightTheme"), light != lightThemeName { lightThemeName = light }
    }

    private func resolve(_ name: String, _ appearance: Appearance) -> Theme {
        // Hand-written themes win over built-ins of the same name.
        customThemes.first { $0.name == name && $0.appearance == appearance }
            ?? customThemes.first { $0.name == name }
            ?? ThemeCatalog.named(name)
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

    /// A shell at its prompt shows its folder ("~/site"), or "~ - fish" at
    /// home, whatever title it sets;
    /// other programs keep the title they set, else "Node ~/site".
    func title(for pane: PaneID) -> String {
        let kind = program(for: pane)
        let atPrompt = kind.glyph == .prompt
        if !atPrompt, let t = titles[pane], !t.isEmpty { return t }
        guard let meta = metas[pane] else { return titles[pane].flatMap { $0.isEmpty ? nil : $0 } ?? "shell" }
        guard let cwd = meta.cwd else { return kind.name }
        let folder = abbreviate(cwd, on: host(ofPane: pane))
        guard atPrompt else { return "\(kind.name) \(folder)" }
        return folder == "~" ? "~ - \(kind.name)" : folder
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

    /// The tab's line in Activity Mode, or nil for tabs it leaves out. The
    /// most urgent OSC 7501 status wins; an agent that reports none is idle.
    /// Panes back at a shell prompt drop out: their program has exited, and
    /// the done/error it left behind is the tab badge's to show.
    func activity(of tab: TabLayout, now: Date) -> TabActivity? {
        let panes = tab.root.panes.filter { program(for: $0).glyph != .prompt }
        let reported = panes.compactMap { pane in
            StatusRecords(programStatus[pane] ?? []).headline.map { (record: $0, pane: pane) }
        }
        if let top = reported.min(by: { $0.record.phase.urgency < $1.record.phase.urgency }) {
            return TabActivity(record: top.record, since: statusSince[top.pane] ?? now)
        }
        let agents = panes.filter { program(for: $0).isAgent }
        guard !agents.isEmpty else { return nil }
        return TabActivity.unreported(lastOutput: agents.compactMap { lastOutput[$0] }.max(), now: now)
    }

    /// One pane's share of the above, for the tab hover card.
    func activity(of pane: PaneID, now: Date) -> TabActivity? {
        guard program(for: pane).glyph != .prompt else { return nil }
        if let record = StatusRecords(programStatus[pane] ?? []).headline {
            return TabActivity(record: record, since: statusSince[pane] ?? now)
        }
        guard program(for: pane).isAgent else { return nil }
        return TabActivity.unreported(lastOutput: lastOutput[pane], now: now)
    }

    /// Something outside the tab on screen finished or is waiting on the
    /// user: the Activity Mode button wears a dot.
    var anyTabWantsAttention: Bool {
        layouts.values.contains { layout in
            layout.tabs.contains { $0.id != activeTab && status(of: $0)?.wantsAttention == true }
        }
    }

    /// Some tab has an agent open or a program reporting status: the
    /// Activity Mode button wears a dot for as long as it lasts.
    var anyTabHasActivity: Bool {
        let now = Date()
        return layouts.values.contains { layout in layout.tabs.contains { activity(of: $0, now: now) != nil } }
    }

    /// A tab in this session (other than the one on screen) finished or is
    /// waiting on the user.
    func sessionWantsAttention(_ id: SessionID) -> Bool {
        tabs(in: id).contains { $0.id != activeTab && status(of: $0)?.wantsAttention == true }
    }

    func cwd(of pane: PaneID?) -> String? { pane.flatMap { metas[$0]?.cwd } }

    static func abbreviate(_ path: String) -> String {
        PathQuery.abbreviate(path)
    }

    /// `~`-abbreviated against the home of the host the path is on.
    func abbreviate(_ path: String, on host: HostID) -> String {
        hostHomes[host].map { PathQuery.abbreviate(path, home: $0) } ?? path
    }
}
