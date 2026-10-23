import SwiftUI

/// The panes of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, themes, terminal, shortcuts, notifications, hosts, permissions, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .themes: "Themes"
        case .terminal: "Terminal"
        case .shortcuts: "Shortcuts"
        case .notifications: "Notifications"
        case .hosts: "Remote Hosts"
        case .permissions: "Permissions"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "macwindow"
        case .themes: "paintpalette.fill"
        case .terminal: "apple.terminal.fill"
        case .shortcuts: "command"
        case .notifications: "bell.badge.fill"
        case .hosts: "globe"
        case .permissions: "lock.shield.fill"
        case .general: "gearshape.fill"
        }
    }

    /// The icon tile's gradient, like System Settings.
    var tile: [Color] {
        switch self {
        case .appearance: [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.2, green: 0.25, blue: 0.82)]
        case .themes: [Color(red: 1, green: 0.55, blue: 0.3), Color(red: 0.93, green: 0.26, blue: 0.55)]
        case .terminal: [Color(red: 0.25, green: 0.27, blue: 0.3), Color(red: 0.1, green: 0.11, blue: 0.13)]
        case .shortcuts: [Color(red: 0.58, green: 0.6, blue: 0.64), Color(red: 0.4, green: 0.42, blue: 0.46)]
        case .notifications: [Color(red: 1, green: 0.42, blue: 0.38), Color(red: 0.92, green: 0.2, blue: 0.24)]
        case .hosts: [Color(red: 0.72, green: 0.42, blue: 1), Color(red: 0.5, green: 0.24, blue: 0.9)]
        case .permissions: [Color(red: 0.3, green: 0.62, blue: 1), Color(red: 0.12, green: 0.4, blue: 0.9)]
        case .general: [Color(red: 0.6, green: 0.62, blue: 0.66), Color(red: 0.38, green: 0.4, blue: 0.44)]
        }
    }

    /// Words a search should find this pane by, beyond its title.
    var keywords: [String] {
        switch self {
        case .appearance: ["light", "dark", "system", "style", "glass", "modern", "themed", "blended", "tabs", "vertical",
                           "horizontal", "sidebar", "zen", "activity", "density", "compact", "pane", "headers", "border", "focus", "font", "ui font", "interface font", "terminal font"]
        case .themes: ["color", "palette", "import", "ghostty", "json"]
        case .terminal: ["font", "size", "ligatures", "smoothing", "contrast", "cursor", "blink", "option", "alt", "keyboard"]
        case .shortcuts: ["keys", "keybind", "leader", "hotkey", "binding"]
        case .notifications: ["toast", "position"]
        case .hosts: ["ssh", "remote", "tailscale", "server", "dend"]
        case .permissions: ["privacy", "full disk access", "downloads", "operation not permitted", "screen recording", "tcc"]
        case .general: ["update", "shell", "cli", "command line", "agents", "config", "toml"]
        }
    }

    /// Sidebar groups, separated by a gap.
    static let groups: [[SettingsPane]] = [[.appearance, .themes], [.terminal, .shortcuts, .notifications], [.hosts, .permissions], [.general]]

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || title.lowercased().contains(q) || keywords.contains { $0.contains(q) }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pane = SettingsPane.appearance
    @State private var back: [SettingsPane] = []
    @State private var forward: [SettingsPane] = []
    @State private var search = ""

    /// Below this width the sidebar shrinks to its icons.
    private static let compactWidth: CGFloat = 780

    var body: some View {
        let theme = model.theme
        let surfaces = model.surfaces
        GeometryReader { geometry in
            let compact = geometry.size.width < Self.compactWidth
            HStack(spacing: 0) {
                sidebar(compact: compact)
                    .frame(width: compact ? 64 : 224)
                    .background(surfaces.windowBottom.opacity(model.effectiveInterfaceStyle == .themed ? 1 : 0.5))
                theme.separator.frame(width: 0.5)
                detail(compact: compact)
            }
            .animation(.den, value: compact)
        }
        .background(LinearGradient(colors: [surfaces.windowTop, surfaces.windowBottom], startPoint: .top, endPoint: .bottom))
        .foregroundStyle(theme.chromeText)
        .tint(theme.accent)
        .environment(\.settingsTheme, theme)
        .ignoresSafeArea()
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.25), value: theme)
    }

    // MARK: Sidebar

    private func sidebar(compact: Bool) -> some View {
        let theme = model.theme
        let query = compact ? "" : search
        let groups = SettingsPane.groups.map { $0.filter { $0.matches(query) } }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 48)
            if !compact {
                SettingsSearchField(text: $search, placeholder: "Search Settings")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .onSubmit { if let first = groups.first?.first { select(first) } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(groups[i]) { item in
                                SidebarItem(pane: item, selected: item == pane, compact: compact) { select(item) }
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("No Results").font(.system(size: 12)).foregroundStyle(theme.tertiaryText).padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Detail

    private func detail(compact: Bool) -> some View {
        let theme = model.theme
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    navButton("chevron.left", enabled: !back.isEmpty) { goBack() }
                    theme.separator.frame(width: 0.5, height: 16)
                    navButton("chevron.right", enabled: !forward.isEmpty) { goForward() }
                }
                .background(Capsule().fill(theme.hover))
                .overlay(Capsule().strokeBorder(theme.menuBorder, lineWidth: 0.5))
                Text(pane.title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding(.leading, compact ? 24 : 18)
            .padding(.trailing, 18)
            .frame(height: 52)

            ScrollView {
                paneContent
                    .frame(maxWidth: 640)
                    .padding(.horizontal, compact ? 18 : 28)
                    .padding(.top, 6)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }
            .id(pane)
            .scrollIndicators(.automatic)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .appearance: AppearanceSettings()
        case .themes: ThemeSettings()
        case .terminal: TerminalSettings()
        case .shortcuts: ShortcutSettings()
        case .notifications: NotificationSettings()
        case .hosts: HostSettings()
        case .permissions: PermissionSettings()
        case .general: GeneralSettings()
        }
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hitArea)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func select(_ next: SettingsPane) {
        guard next != pane else { return }
        back.append(pane)
        forward.removeAll()
        pane = next
    }

    private func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(pane)
        pane = previous
    }

    private func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(pane)
        pane = next
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    /// Just the icon, centered: the narrow sidebar.
    let compact: Bool
    let action: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIconTile(symbol: pane.symbol, colors: pane.tile, size: compact ? 26 : 22)
                if !compact {
                    Text(pane.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: compact ? .infinity : nil)
            .frame(height: compact ? 38 : 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? theme.activeTab : (hovering ? theme.hover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? theme.activeTabBorder : .clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
        .help(compact ? pane.title : "")
    }
}

/// A rounded, gradient icon tile like System Settings'.
struct SettingsIconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }
}

// MARK: - Building blocks

private struct SettingsThemeKey: EnvironmentKey {
    static let defaultValue = ThemeCatalog.dark[0]
}

extension EnvironmentValues {
    /// The theme Settings is drawn in, so rows needn't each read the model.
    var settingsTheme: Theme {
        get { self[SettingsThemeKey.self] }
        set { self[SettingsThemeKey.self] = newValue }
    }
}

struct SettingsSearchField: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.settingsTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.tertiaryText)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.tertiaryText)
                }
                .buttonStyle(.hitArea)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(theme.hover))
        .overlay(Capsule().strokeBorder(focused ? theme.accent.opacity(0.6) : theme.menuBorder, lineWidth: focused ? 1 : 0.5))
    }
}

/// A titled group of rows on a card, with hairlines between rows.
struct SettingsSection<Content: View, Accessory: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || !(accessory is EmptyView) {
                HStack(alignment: .firstTextBaseline) {
                    if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
                    Spacer()
                    accessory
                }
                .padding(.horizontal, 4)
            }
            Group(subviews: content) { rows in
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        rows[i]
                        if i < rows.count - 1 {
                            theme.separator.opacity(0.7).frame(height: 0.5).padding(.horizontal, 14)
                        }
                    }
                }
            }
            .background(SettingsCardBackground())
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 18)
    }
}

extension SettingsSection where Accessory == EmptyView {
    init(_ title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

struct SettingsCardBackground: View {
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape
            .fill(theme.isDark ? Color.white.opacity(0.045) : Color.white.opacity(0.7))
            .overlay(shape.strokeBorder(theme.cardBorder, lineWidth: 0.5))
    }
}

/// A label on the left (with an optional explanation under it) and a
/// control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String?
    /// Marks settings that live in config.toml.
    var inConfigFile = false
    @ViewBuilder let trailing: Trailing
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                // An ideal width, so a long explanation wraps instead of
                // pushing the control under it.
                label.frame(minWidth: 120, idealWidth: 180, maxWidth: .infinity, alignment: .leading)
                trailing
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                trailing
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13))
                if inConfigFile {
                    Text("config.toml")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.hover))
                        .help("Saved to \(PathQuery.abbreviate(UserConfig.url.path))")
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String?
    var inConfigFile = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail, inConfigFile: inConfigFile) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

/// A capsule segmented control: icon and label per option.
struct SettingsSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String, symbol: String?)]
    @Binding var selection: Value
    @Environment(\.settingsTheme) private var theme
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    withAnimation(.denFast) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 11.5)) }
                        Text(option.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .foregroundStyle(selected ? theme.chromeText : theme.secondaryText)
                    .background {
                        if selected {
                            Capsule()
                                .fill(theme.activeTab)
                                .overlay(Capsule().strokeBorder(theme.activeTabBorder, lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.hitArea)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.hover))
        .overlay(Capsule().strokeBorder(theme.menuBorder, lineWidth: 0.5))
    }
}

/// A large selectable tile with a drawn preview and a caption.
struct SettingsTile<Preview: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                preview
                    .frame(width: 78, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? theme.accent : (hovering ? theme.separator : .clear), lineWidth: 2.5)
                    )
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.chromeText : theme.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
    }
}

/// A plain rounded button in Settings' style.
struct SettingsButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    var destructive = false
    let action: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(prominent ? theme.onAccent : (destructive ? Color.red : theme.chromeText))
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(prominent ? .clear : theme.menuBorder, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if prominent { return theme.accent.opacity(hovering ? 0.88 : 1) }
        if destructive { return Color.red.opacity(hovering ? 0.2 : 0.12) }
        return hovering ? theme.activeTab : theme.hover
    }
}
