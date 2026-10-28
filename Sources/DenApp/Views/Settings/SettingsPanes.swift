import AppKit
import DenProtocol
import DenVT
import SwiftUI

// MARK: - Appearance

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Appearance", footer: "Preview Glass or Classic materials with the current theme tint, then select a surface style.") {
                // Side by side when there's room, stacked when not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        schemeTiles
                        theme.separator.frame(width: 0.5).padding(.horizontal, 12).padding(.vertical, 4)
                        styleTiles
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        schemeTiles
                        theme.separator.frame(height: 0.5)
                        styleTiles
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsToggle(title: "Theme tint", detail: "Apply the selected theme's colors to interface surfaces.", isOn: Binding(
                    get: { model.themeTint },
                    set: { value in withAnimation(.easeInOut(duration: 0.25)) { model.themeTint = value } }))
            }

            SettingsSection("Tabs") {
                SettingsRow(title: "Tab style") {
                    SettingsSegments(options: [(TabPlacement.top, "Top", "rectangle.topthird.inset.filled"),
                                               (TabPlacement.left, "Left", "sidebar.left"),
                                               (TabPlacement.right, "Right", "sidebar.right")],
                                     selection: Binding(get: { TabPlacement(model) }, set: { value in
                                         withAnimation(.den) { value.apply(to: model) }
                                     }))
                }
                if model.tabStyle == .vertical {
                    SettingsToggle(title: "Show sidebar", isOn: Binding(
                        get: { !model.sidebarCollapsed },
                        set: { value in withAnimation(.den) { model.sidebarCollapsed = !value } }))
                }
                SettingsToggle(title: "Activity Mode", detail: "The sidebar lists only tabs running agents or reporting status.",
                               isOn: Binding(get: { model.activityMode }, set: { value in
                                   if value != model.activityMode { withAnimation(.den) { model.toggleActivityMode() } }
                               }))
                SettingsToggle(title: "Fold idle sessions", detail: "In the sidebar, sessions you're not in fold to one line after a few seconds untouched.",
                               isOn: Binding(get: { model.autoFoldSessions }, set: { value in withAnimation(.den) { model.autoFoldSessions = value } }))
                SettingsToggle(title: "Zen Mode", detail: "Hide the tab bar or sidebar until the pointer reaches the window's edge.",
                               isOn: Binding(get: { model.zenMode }, set: { value in withAnimation(.den) { model.zenMode = value } }))
            }

            SettingsSection("Activity") {
                SettingsToggle(title: "Play sounds", detail: "Chime when a program finishes, fails or needs your input.",
                               isOn: $model.statusSounds)
                SettingsToggle(title: "System notifications", detail: "Post the same moments to Notification Center while Den isn't in front.",
                               isOn: $model.statusNotifications)
            }

            SettingsSection("Panes") {
                SettingsRow(title: "Pane style") {
                    SettingsSegments(options: [(Density.comfortable, "Comfortable", "square.grid.2x2"),
                                               (Density.compact, "Compact", "rectangle.split.2x2")],
                                     selection: Binding(get: { model.density }, set: { value in withAnimation(.den) { model.density = value } }))
                }
                SettingsToggle(title: "Balance new splits", detail: "Give every pane in a row or column an equal share when you split.",
                               isOn: $model.balancePanes)
                SettingsToggle(title: "Show pane headers", isOn: Binding(
                    get: { model.showPaneHeaders },
                    set: { value in withAnimation(.den) { model.showPaneHeaders = value } }))
                SettingsToggle(title: "Match program backgrounds",
                               detail: "Color a pane and its header with the background a full-screen program such as an editor paints.",
                               isOn: Binding(get: { model.matchProgramBackgrounds },
                                             set: { value in withAnimation(.easeInOut(duration: 0.18)) { model.matchProgramBackgrounds = value } }))
                SettingsToggle(title: "Focus border", detail: "Ring the focused pane in the theme's accent color.", inConfigFile: true,
                               isOn: Binding(get: { model.config.paneBorder },
                                             set: { model.setConfig("pane_border", .bool($0)) }))
            }

            SettingsSection("Fonts", footer: "The interface font covers the sidebar, tabs, toasts, menus and pickers. Without one of its own, it uses the terminal font.") {
                SettingsRow(title: "Terminal font", inConfigFile: true) {
                    FontMenu(selection: model.fontFamily, placeholder: nil, kind: .terminal) { family in
                        if let family { model.setTerminalFont(family) }
                    }
                }
                SettingsRow(title: "Interface font", inConfigFile: true) {
                    FontMenu(selection: model.config.uiFont, placeholder: "Same as Terminal", kind: .interface) { family in
                        model.setConfig("ui_font", family.map(TOMLValue.string))
                    }
                }
                SettingsRow(title: "Interface size", inConfigFile: true) {
                    SizeStepper(value: model.config.uiFontSize.map { Int($0) }, fallback: Int(model.fontSize)) { size in
                        model.setConfig("ui_font_size", size.map { .integer($0) })
                    }
                }
            }
        }
    }

    private var schemeTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color scheme").font(.system(size: 11.5, weight: .medium)).foregroundStyle(model.theme.secondaryText)
            HStack(spacing: 10) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    SettingsTile(title: mode.shortTitle, selected: model.appearanceMode == mode,
                                 action: { withAnimation(.den) { model.appearanceMode = mode } }) {
                        SchemePreview(mode: mode, light: themeNamed(model.lightThemeName, .light),
                                      dark: themeNamed(model.darkThemeName, .dark))
                    }
                }
            }
        }
        .fixedSize()
    }

    private var styleTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interface style").font(.system(size: 11.5, weight: .medium)).foregroundStyle(model.theme.secondaryText)
            HStack(spacing: 10) {
                ForEach(InterfaceStyle.allCases, id: \.self) { style in
                    SettingsTile(title: style.title, selected: model.interfaceStyle == style,
                                 action: { withAnimation(.easeInOut(duration: 0.25)) { model.interfaceStyle = style } }) {
                        StylePreview(style: style, theme: model.theme, themeTint: model.themeTint)
                    }
                }
            }
        }
        .fixedSize()
    }

    private func themeNamed(_ name: String, _ appearance: Appearance) -> Theme {
        model.themes(for: appearance).first { $0.name == name }
            ?? (appearance == .dark ? ThemeCatalog.dark[0] : ThemeCatalog.light[0])
    }
}

/// Where the tabs go: one choice in Settings for tab style plus side.
private enum TabPlacement: Hashable {
    case top, left, right

    @MainActor init(_ model: AppModel) {
        self = model.tabStyle == .horizontal ? .top : (model.sidebarSide == .left ? .left : .right)
    }

    @MainActor func apply(to model: AppModel) {
        switch self {
        case .top: model.tabStyle = .horizontal
        case .left, .right:
            model.sidebarSide = self == .left ? .left : .right
            model.tabStyle = .vertical
        }
    }
}

private extension AppearanceMode {
    var shortTitle: String {
        switch self {
        case .system: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// A tiny Den window in a theme: tab strip and two panes.
private struct MiniWindow: View {
    let theme: Theme
    var chromeOpacity: Double = 1
    /// nil uses the theme's terminal background; pass a neutral for the
    /// untinted surface previews.
    var paneFill: Color? = nil

    var body: some View {
        VStack(spacing: 2.5) {
            HStack(spacing: 2) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 3.5, height: 3.5) }
                Spacer()
            }
            .padding(.leading, 3)
            HStack(spacing: 2.5) {
                ForEach(0 ..< 2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(paneFill ?? theme.background.color)
                }
            }
        }
        .padding(3.5)
        .background(LinearGradient(colors: [theme.windowTop, theme.windowBottom], startPoint: .top, endPoint: .bottom).opacity(chromeOpacity))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct SchemePreview: View {
    let mode: AppearanceMode
    let light: Theme
    let dark: Theme

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.24, green: 0.4, blue: 0.85), Color(red: 0.1, green: 0.16, blue: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            switch mode {
            case .light: MiniWindow(theme: light).padding(9)
            case .dark: MiniWindow(theme: dark).padding(9)
            case .system:
                ZStack {
                    MiniWindow(theme: light)
                    MiniWindow(theme: dark).mask(DiagonalHalf())
                }
                .padding(9)
            }
        }
    }
}

/// The lower-right half of a rect, split corner to corner.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX * 0.62, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX * 0.38, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

private struct StylePreview: View {
    let style: InterfaceStyle
    let theme: Theme
    let themeTint: Bool

    private var neutralPane: Color {
        theme.isDark ? Color(white: 0.12) : Color.white
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.96, green: 0.5, blue: 0.35), Color(red: 0.45, green: 0.25, blue: 0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1, green: 0.85, blue: 0.4)).frame(width: 26).offset(x: -18, y: -10)
            preview
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch (style, themeTint) {
        case (.classic, true):
            MiniWindow(theme: theme).padding(9)
        case (.classic, false):
            MiniWindow(theme: theme, chromeOpacity: 0.15, paneFill: neutralPane)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6))
                .padding(9)
        case (.glass, true):
            MiniWindow(theme: theme, chromeOpacity: 0.25)
                .background(theme.background.color.opacity(0.28), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 0.6))
                .padding(9)
        case (.glass, false):
            MiniWindow(theme: theme, chromeOpacity: 0.15, paneFill: neutralPane)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.6))
                .padding(9)
        }
    }
}

// MARK: - Themes

struct ThemeSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            ForEach([Appearance.light, .dark], id: \.self) { appearance in
                let active = model.theme.appearance == appearance
                let selected = appearance == .dark ? model.darkThemeName : model.lightThemeName
                SettingsSection(title: nil, footer: nil, accessory: {
                    HStack(spacing: 6) {
                        Text(appearance == .dark ? "Dark Mode" : "Light Mode").font(.system(size: 13, weight: .semibold))
                        if active { Text("— Active").font(.system(size: 13)).foregroundStyle(theme.secondaryText) }
                        Spacer()
                        Text(selected).font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                    }
                }) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(model.themes(for: appearance)) { candidate in
                                    ThemeCard(candidate: candidate, selected: candidate.name == selected) {
                                        withAnimation(.easeInOut(duration: 0.25)) { model.useTheme(candidate) }
                                    }
                                    .id(candidate.name)
                                    .contextMenu {
                                        if candidate.isCustom {
                                            Button("Delete Theme", role: .destructive) { model.deleteCustomTheme(candidate) }
                                        }
                                        if let url = candidate.fileURL {
                                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                        }
                                    }
                                }
                            }
                            .padding(14)
                        }
                        .scrollIndicators(.never)
                        .onAppear { proxy.scrollTo(selected, anchor: .center) }
                    }
                }
            }

            SettingsSection("Your Themes", footer: "Den JSON themes, Ghostty theme files and folders of them. Files in the themes folder reload as you save them.") {
                SettingsRow(title: "Import a theme file") {
                    SettingsButton(title: "Import…", symbol: "square.and.arrow.down") { importTheme() }
                }
                SettingsRow(title: "Themes folder", detail: PathQuery.abbreviate(UserConfig.themesDirectory.path)) {
                    SettingsButton(title: "Open", symbol: "folder") {
                        try? FileManager.default.createDirectory(at: UserConfig.themesDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(UserConfig.themesDirectory)
                    }
                }
                ForEach(model.themeFileErrors, id: \.description) { error in
                    SettingsRow(title: error.file, detail: error.message) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
            }
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Den JSON theme, a Ghostty theme file, or a theme folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.importTheme(from: url) }
    }
}

/// A theme as a swatch: sample text, a prompt chip, the cursor and the
/// first eight ANSI colors.
private struct ThemeCard: View {
    let candidate: Theme
    let selected: Bool
    let action: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text("Aa").font(.system(size: 20, weight: .regular))
                            .foregroundStyle(candidate.foreground.color)
                        Spacer(minLength: 0)
                        Text("~/").font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(candidate.background.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(candidate.accent))
                        RoundedRectangle(cornerRadius: 2).fill(candidate.cursor.color).frame(width: 8, height: 18)
                    }
                    HStack(spacing: -3) {
                        ForEach(0 ..< 8, id: \.self) { i in
                            Circle()
                                .fill(candidate.ansi[i].color)
                                .overlay(Circle().strokeBorder(candidate.background.color, lineWidth: 1.2))
                                .frame(width: 13, height: 13)
                        }
                    }
                }
                .padding(11)
                .frame(width: 128, height: 76)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(candidate.background.color))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(selected ? theme.accent : (hovering ? theme.separator : .clear), lineWidth: 2.5)
                )
                HStack(spacing: 4) {
                    Text(candidate.name).lineLimit(1)
                    if candidate.isCustom { Image(systemName: "person.crop.circle").font(.system(size: 10)) }
                }
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.chromeText : theme.secondaryText)
                .frame(width: 134)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
    }
}

// MARK: - Terminal

struct TerminalSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Typography") {
                TerminalPreview(theme: theme, family: model.fontFamily, size: model.fontSize, ligatures: model.fontLigatures)
                    .padding(12)
                SettingsRow(title: "Font", inConfigFile: true) {
                    FontMenu(selection: model.fontFamily, placeholder: nil, kind: .terminal) { family in
                        if let family { model.setTerminalFont(family) }
                    }
                }
                SettingsRow(title: "Size", inConfigFile: true) {
                    SizeStepper(value: model.config.terminalFontSize.map { Int($0) } ?? Int(model.fontSize), fallback: Int(model.fontSize)) { size in
                        if let size { model.fontSize = CGFloat(size) }
                        model.setConfig("terminal_font_size", size.map { .integer($0) })
                    }
                }
                SettingsToggle(title: "Ligatures", detail: "Draw sequences like -> and != as the font's joined glyphs.", isOn: $model.fontLigatures)
                SettingsToggle(title: "Font smoothing", detail: "Heavier, softer strokes, as macOS drew text before Mojave.", isOn: $model.fontSmoothing)
            }

            SettingsSection("Colors") {
                SettingsToggle(title: "Improve text contrast", detail: "Adjust text that would be unreadable against its background.",
                               isOn: $model.contrastCorrection)
            }

            SettingsSection("Cursor") {
                CursorPreview(theme: theme, family: model.fontFamily, size: model.fontSize,
                              blink: model.cursorBlink ? model.cursorBlinkStyle : nil)
                    .padding(12)
                SettingsToggle(title: "Blink", detail: "The focused pane's cursor fades in and out while nothing happens.", isOn: $model.cursorBlink)
                if model.cursorBlink {
                    SettingsRow(title: "Speed") {
                        Picker("Speed", selection: $model.cursorBlinkStyle.speed) {
                            ForEach(CursorBlink.Speed.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    SettingsRow(title: "Transition") {
                        Picker("Transition", selection: $model.cursorBlinkStyle.transition) {
                            ForEach(CursorBlink.Transition.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    SettingsRow(title: "Pause between blinks") {
                        Picker("Pause", selection: $model.cursorBlinkStyle.pause) {
                            ForEach(CursorBlink.Pause.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }

            SettingsSection("Keyboard") {
                SettingsRow(title: "Option key sends Alt", detail: "Option types ESC-prefixed keys for the shell and editors instead of symbols like å.",
                            inConfigFile: true) {
                    Picker("Option as Alt", selection: Binding(get: { model.config.optionAsAlt }, set: { mode in
                        let value: TOMLValue = switch mode {
                        case .none: .bool(false)
                        case .both: .bool(true)
                        case .left: .string("left")
                        case .right: .string("right")
                        }
                        model.setConfig("macos_option_as_alt", value)
                    })) {
                        Text("Both Keys").tag(OptionAsAlt.both)
                        Text("Left Key").tag(OptionAsAlt.left)
                        Text("Right Key").tag(OptionAsAlt.right)
                        Text("Off").tag(OptionAsAlt.none)
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
}

/// A few lines of shell output in the terminal font and theme.
private struct TerminalPreview: View {
    let theme: Theme
    let family: String
    let size: CGFloat
    let ligatures: Bool

    var body: some View {
        let font = Font.custom(family, size: size)
        let c = theme.ansi
        VStack(alignment: .leading, spacing: 2) {
            (Text("~/den ").foregroundColor(c[4].color) + Text("$ ").foregroundColor(theme.foreground.color)
                + Text("swift build && swift test").foregroundColor(theme.foreground.color))
            (Text("main.swift:4: ").foregroundColor(theme.foreground.color.opacity(0.7)) + Text("warning: ").foregroundColor(c[3].color)
                + Text("'run() -> Bool' != nil").foregroundColor(theme.foreground.color))
            (Text("Build complete! ").foregroundColor(c[2].color) + Text("(1.24 sec)").foregroundColor(theme.foreground.color.opacity(0.6)))
        }
        .font(font)
        .environment(\.font, font)
        .kerning(0)
        .typesettingLanguage(.init(languageCode: .english))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.background.color))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
    }
}

/// A prompt with the cursor blinking as configured.
private struct CursorPreview: View {
    let theme: Theme
    let family: String
    let size: CGFloat
    let blink: CursorBlink?

    var body: some View {
        TimelineView(.animation(paused: blink == nil)) { context in
            HStack(spacing: 0) {
                Text("~/den $ ").foregroundStyle(theme.foreground.color)
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.cursor.color)
                    .frame(width: size * 0.6, height: size * 1.25)
                    .opacity(opacity(at: context.date))
            }
            .font(.custom(family, size: size))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.background.color))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
        }
    }

    /// The terminal's own blink curve, restarting after a few seconds as
    /// if you'd typed, so the pause shows too.
    private func opacity(at date: Date) -> Double {
        guard let blink else { return 1 }
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: blink.pause.seconds + blink.speed.seconds * 3)
        return Double(blink.opacity(sinceActivity: t, fades: true))
    }
}

/// Picks any installed family from a searchable popover; `nil` means the
/// default (no key in the file). The list is lazy, so hundreds of fonts
/// scroll without building a row for each.
struct FontMenu: View {
    /// Terminals list monospaced families first; the interface takes any.
    enum Kind { case terminal, interface }

    let selection: String?
    /// Title for the default choice, or nil when there's no default to offer.
    let placeholder: String?
    let kind: Kind
    let onChange: (String?) -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(selection ?? placeholder ?? "")
                    .font(.custom(selection ?? FontRegistry.bundledFamily, size: 12.5))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(theme.chromeText)
            .background(Capsule().fill(hovering || open ? theme.activeTab : theme.hover))
            .overlay(Capsule().strokeBorder(theme.menuBorder, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
        .fixedSize()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            FontPickerList(selection: selection, placeholder: placeholder, kind: kind) { family in
                open = false
                onChange(family)
            }
            .environment(\.settingsTheme, theme)
        }
    }
}

private struct FontPickerList: View {
    let selection: String?
    let placeholder: String?
    let kind: FontMenu.Kind
    let onPick: (String?) -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var catalog = FontCatalog.current
    @State private var query = ""

    var body: some View {
        let sections = sections
        VStack(spacing: 0) {
            SettingsSearchField(text: $query, placeholder: "Search fonts")
                .padding(10)
                .onSubmit { if let first = sections.first?.families.first { onPick(first) } }
            theme.separator.frame(height: 0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: .sectionHeaders) {
                    if let placeholder, query.isEmpty {
                        FontPickerRow(title: placeholder, family: nil, selected: selection == nil) { onPick(nil) }
                    }
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.families, id: \.self) { family in
                                FontPickerRow(title: family, family: family, selected: family == selection) { onPick(family) }
                            }
                        } header: {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                .background(.regularMaterial)
                        }
                    }
                    if catalog == nil {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
                    } else if sections.isEmpty {
                        Text("No fonts match “\(query)”")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.tertiaryText)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 320, height: 400)
        .task { if catalog == nil { catalog = await FontCatalog.load() } }
    }

    private var sections: [(title: String, families: [String])] {
        guard let catalog else { return [] }
        let groups: [(title: String, families: [String])] = switch kind {
        case .terminal: [("Monospaced", catalog.monospaced), ("Proportional", catalog.proportional)]
        case .interface: [("All Fonts", catalog.all)]
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        return groups
            .map { ($0.title, q.isEmpty ? $0.families : $0.families.filter { $0.localizedCaseInsensitiveContains(q) }) }
            .filter { !$0.families.isEmpty }
    }
}

/// A family's name, with a sample set in the family itself; symbol fonts
/// stay readable since the name uses the system font.
private struct FontPickerRow: View {
    let title: String
    let family: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.settingsTheme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.chromeText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let family {
                    Text("Aa")
                        .font(.custom(family, size: 13))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
    }
}

/// Font size 8–32 in points; `nil` means the default.
struct SizeStepper: View {
    let value: Int?
    let fallback: Int
    let onChange: (Int?) -> Void
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let current = value ?? fallback
        HStack(spacing: 8) {
            if value != nil, value != fallback {
                Button { onChange(nil) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.hitArea)
                .foregroundStyle(theme.secondaryText)
                .help("Use the default")
            }
            Text("\(current) pt").font(.system(size: 12.5).monospacedDigit()).foregroundStyle(value == nil ? theme.secondaryText : theme.chromeText)
            Stepper("Size", value: Binding(get: { current }, set: { onChange(min(max($0, 8), 32)) }), in: 8 ... 32)
                .labelsHidden()
        }
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var recording: ShortcutTarget?

    /// Commands grouped like the menus; anything not listed lands in Other.
    private static let groups: [(String, [DenCommand])] = {
        let listed: [(String, [DenCommand])] = [
            ("Den", [.openSettings, .commandPalette, .openConfig, .reloadConfig, .checkForUpdates, .hide, .quit]),
            ("File", [.newTab, .newSession, .goToDirectory, .insertPath, .closePane, .closeTab]),
            ("Edit", [.copy, .paste, .selectAll, .find, .findNext, .findPrevious, .findTab, .findSession]),
            ("View", [.changeTheme, .changeFont, .fontBigger, .fontSmaller, .fontReset, .toggleVerticalTabs, .toggleSidebar,
                      .showSidebar, .hideSidebar, .toggleActivityMode, .toggleZenMode, .togglePaneHeaders, .toggleContrastCorrection,
                      .peek, .leavePeek, .showAllSessions, .toggleFullScreen]),
            ("Panes", [.splitRight, .splitDown, .zoomPane, .nextPane, .previousPane, .focusPaneLeft, .focusPaneDown, .focusPaneUp,
                       .focusPaneRight, .resizePaneLeft, .resizePaneDown, .resizePaneUp, .resizePaneRight, .movePaneLeft,
                       .movePaneRight, .movePaneUp, .movePaneDown, .movePaneToNewTab]),
            ("Sessions", [.changeSession, .goToSession, .renameSession, .previousSession, .nextSession, .closeSession, .previousHost, .nextHost, .addRemoteHost]),
            ("Tabs", [.renameTab, .tidyTabTitle, .nextTab, .previousTab, .moveTabLeft, .moveTabRight, .goToTab, .lastTab]),
            ("Window", [.minimize]),
        ]
        let seen = Set(listed.flatMap(\.1))
        let rest = DenCommand.allCases.filter { !seen.contains($0) }
        return rest.isEmpty ? listed : listed + [("Other", rest)]
    }()

    var body: some View {
        let theme = model.theme
        let config = model.config
        VStack(alignment: .leading, spacing: 0) {
            SettingsSearchField(text: $filter, placeholder: "Filter Shortcuts…")
                .padding(.top, 8)
            Text("Shortcuts are saved under [keys] in config.toml. Click one and press keys to record it; Esc cancels, Delete removes it. Search for a key, like cmd+k, to see what it does.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 10)

            if filter.isEmpty {
                SettingsSection("Leader", footer: "Press the leader, let go, then a key: \(config.leader.label) N opens a tab. Press it twice to send it to the program.") {
                    SettingsRow(title: "Leader key", inConfigFile: true) {
                        ShortcutRecorder(target: .leader, recording: $recording, label: config.leader.label,
                                         isCustom: config.leader != UserConfig.defaultLeader)
                    }
                }
            }

            ForEach(Self.groups, id: \.0) { group, commands in
                let shown = commands.filter { matches($0, config) }
                if !shown.isEmpty {
                    SettingsSection(group) {
                        ForEach(shown, id: \.self) { command in
                            ShortcutRow(command: command, recording: $recording)
                        }
                    }
                }
            }
        }
        .onDisappear {
            recording = nil
            model.isRecordingShortcut = false
        }
    }

    private func matches(_ command: DenCommand, _ config: UserConfig) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let trigger = config.shortcut(for: command)
        return command.title.lowercased().contains(q) || command.rawValue.contains(q)
            || trigger.map { $0.configText.contains(q) || config.label($0).lowercased().contains(q) } ?? false
    }
}

enum ShortcutTarget: Equatable {
    case leader
    case command(DenCommand)
}

private struct ShortcutRow: View {
    let command: DenCommand
    @Binding var recording: ShortcutTarget?
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let trigger = config.shortcut(for: command)
        let clash = trigger.flatMap { t in DenCommand.allCases.first { $0 != command && config.shortcut(for: $0) == t } }
        SettingsRow(title: command.title.replacingOccurrences(of: "…", with: ""),
                    detail: clash.map { "Also bound to \($0.title.replacingOccurrences(of: "…", with: "")); the first in the list wins." }) {
            ShortcutRecorder(target: .command(command), recording: $recording,
                             label: trigger.map(config.label), isCustom: config.shortcuts[command] != nil)
        }
    }
}

/// Shows a shortcut and records a new one when clicked.
private struct ShortcutRecorder: View {
    let target: ShortcutTarget
    @Binding var recording: ShortcutTarget?
    let label: String?
    let isCustom: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.settingsTheme) private var theme
    @State private var monitor: Any?
    /// A command's recorder saw the leader; the next key completes it.
    @State private var afterLeader = false
    @State private var hovering = false

    var body: some View {
        let active = recording == target
        HStack(spacing: 6) {
            if isCustom, !active {
                Button { reset() } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.hitArea)
                .foregroundStyle(theme.secondaryText)
                .help("Restore Den's default")
            }
            Button { active ? stop() : start() } label: {
                Text(active ? (afterLeader ? "\(model.config.leader.label) …" : "Press keys…") : (label ?? "Record Shortcut"))
                    .font(.system(size: 12.5, weight: label == nil || active ? .regular : .medium).monospacedDigit())
                    .foregroundStyle(active ? theme.accent : (label == nil ? theme.tertiaryText : theme.chromeText))
                    .frame(width: 150, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(active ? theme.accent.opacity(0.14) : (hovering ? theme.activeTab : theme.hover))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(active ? theme.accent.opacity(0.7) : theme.menuBorder, lineWidth: active ? 1 : 0.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hitArea)
            .onHover { hovering = $0 }
            .contextMenu {
                if case .command = target { Button("Remove Shortcut") { write(.string("")) } }
                Button("Restore Default") { reset() }
            }
        }
        .onChange(of: recording) { _, now in if now != target { removeMonitor() } }
        .onDisappear { removeMonitor() }
    }

    private func start() {
        recording = target
        afterLeader = false
        model.isRecordingShortcut = true
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode, flags = event.modifierFlags
            let unmodified = event.characters(byApplyingModifiers: [])
            MainActor.assumeIsolated { record(keyCode: keyCode, unmodified: unmodified, flags: flags) }
            return nil
        }
    }

    private func stop() {
        recording = nil
        afterLeader = false
        model.isRecordingShortcut = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(keyCode: UInt16, unmodified: String?, flags: NSEvent.ModifierFlags) {
        let modifiers = KeyChord.modifiers(of: flags)
        if modifiers.isEmpty, keyCode == 53 { return stop() } // Esc
        if modifiers.isEmpty, keyCode == 51 || keyCode == 117 { // Delete, Forward Delete
            if case .command = target { write(.string("")) } else { reset() }
            return stop()
        }
        guard var chord = KeyChord.pressed(keyCode: keyCode, unmodified: unmodified, flags: flags) else { return NSSound.beep() }
        switch target {
        case .leader:
            guard !chord.modifiers.isEmpty else { return NSSound.beep() }
            model.setConfig("leader", chord == UserConfig.defaultLeader ? nil : .string(chord.configText), table: "keys")
            stop()
        case .command(let command):
            if !afterLeader, chord == model.config.leader {
                afterLeader = true
                return
            }
            if command.takesNumber, case .character(let c) = chord.key, KeyChord.digit(c) != nil {
                chord = KeyChord(modifiers: chord.modifiers, key: .digit)
            }
            // Plain letters would stop typing; they need a modifier unless
            // they follow the leader.
            if !afterLeader, chord.modifiers.isEmpty, case .character = chord.key { return NSSound.beep() }
            let trigger: Trigger = afterLeader ? .leader(chord) : .chord(chord)
            write(trigger.configText == command.defaultShortcut ? nil : .string(trigger.configText))
            stop()
        }
    }

    private func write(_ value: TOMLValue?) {
        switch target {
        case .leader: model.setConfig("leader", value, table: "keys")
        case .command(let command): model.setConfig(command.rawValue, value, table: "keys")
        }
    }

    private func reset() { write(nil) }
}

// MARK: - Notifications

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let position = model.config.toastPosition
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Toasts", footer: "Confirmations, progress and prompts such as \"An update is available\" appear here. Their look follows the interface style.") {
                SettingsRow(title: "Position", detail: "Shown \(position.title.lowercased())", inConfigFile: true) {
                    ToastPositionPicker(selection: position) { model.setConfig("toast_position", .string($0.rawValue)) }
                }
                SettingsRow(title: "Try it") {
                    SettingsButton(title: "Show a Toast", symbol: "sparkles") { model.showToast("Toasts appear here") }
                }
            }
        }
    }
}

private extension ToastPosition {
    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// A miniature window with a slot for each toast position.
private struct ToastPositionPicker: View {
    let selection: ToastPosition
    let onSelect: (ToastPosition) -> Void
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        let rows: [[ToastPosition]] = [[.topLeft, .topCenter, .topRight], [.bottomLeft, .bottomCenter, .bottomRight]]
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { r in
                if r == 1 { Spacer(minLength: 22) }
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.self) { position in
                        let on = position == selection
                        Button { onSelect(position) } label: {
                            Capsule()
                                .fill(on ? theme.accent : theme.hover)
                                .overlay(Capsule().strokeBorder(theme.menuBorder, lineWidth: 0.5))
                                .overlay {
                                    if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.onAccent) }
                                }
                                .frame(width: 40, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.hitArea)
                        .help(position.title)
                    }
                }
            }
        }
        .padding(8)
        .frame(height: 76)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.background.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.separator, lineWidth: 0.5))
    }
}

// MARK: - Remote Hosts

struct HostSettings: View {
    @Environment(AppModel.self) private var model
    @State private var removing: RemoteHost?

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(title: "Hosts", footer: "Den runs its server (dend) on each host over ssh, so sessions there survive disconnects. Tailscale names and IPs work too.",
                            accessory: {
                                SettingsButton(title: "Add Host…", symbol: "plus") { addHost() }
                            }) {
                SettingsRow(title: "This Mac", detail: model.connectionState.summary) {
                    StatusDot(color: model.connectionState.isConnected ? .green : .orange)
                }
                ForEach(model.remoteHosts) { host in
                    let state = model.remoteStates[host.id] ?? .disconnected
                    SettingsRow(title: host.label, detail: host.name == nil ? state.summary : "\(host.destination) · \(state.summary)") {
                        HStack(spacing: 10) {
                            StatusDot(color: state.dotColor)
                            Toggle("Connected", isOn: Binding(
                                get: { host.autoConnect },
                                set: { on in on ? model.connectRemote(host.id, reveal: false) : model.disconnectHost(host.id) }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            Button { removing = host } label: {
                                Image(systemName: "trash").font(.system(size: 12))
                            }
                            .buttonStyle(.hitArea)
                            .foregroundStyle(theme.secondaryText)
                            .help("Remove \(host.label)")
                        }
                    }
                }
            }
        }
        .confirmationDialog("Remove \(removing?.label ?? "host")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let host = removing { model.removeRemoteHost(host.id) }
                removing = nil
            }
        } message: {
            Text("Den disconnects and forgets it. Its dend keeps running, so its sessions are still there if you add it again.")
        }
    }

    /// Adding a host happens in the main window's palette, which has the
    /// address field and its suggestions.
    private func addHost() {
        model.palette = .addHost
        NSApp.windows.first { $0 is DenWindow }?.makeKeyAndOrderFront(nil)
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

private extension ConnectionState {
    var summary: String {
        switch self {
        case .connecting: "Connecting to dend…"
        case .connected(let host): "Connected to \(host)"
        case .disconnected(let reason): reason
        }
    }

    var isConnected: Bool { if case .connected = self { true } else { false } }
}

private extension RemoteState {
    var summary: String {
        switch self {
        case .connecting(let step): step
        case .downloading(let received, let total): "Downloading dend… \(total > 0 ? received * 100 / total : 0)%"
        case .uploading(let sent, let total, _): "Sending dend… \(total > 0 ? sent * 100 / total : 0)%"
        case .needsLogin: "Needs login"
        case .connected(let hostName): "Connected to \(hostName)"
        case .reconnecting(_, let retryIn): "Reconnecting in \(retryIn)s"
        case .failed(let message): message
        case .needsRestart: "dend is outdated; restart it from the session menu"
        case .disconnected: "Disconnected"
        }
    }

    var dotColor: Color {
        switch self {
        case .connected: .green
        case .connecting, .downloading, .uploading, .reconnecting: .orange
        case .needsLogin, .needsRestart, .failed: .red
        case .disconnected: .gray
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Den") {
                SettingsRow(title: "Version", detail: version.map { "Den \($0)" } ?? "Development build") {
                    SettingsButton(title: "Check for Updates", symbol: "arrow.down.circle") { model.checkForUpdates() }
                }
            }

            SettingsSection("Shell", footer: "New panes start this shell. Saved in \(PathQuery.abbreviate(DenConfig.url.path)), which dend reads.") {
                SettingsRow(title: "Default shell") {
                    Picker("Shell", selection: Binding(get: { model.defaultShell }, set: { model.setDefaultShell($0) })) {
                        ForEach(shells, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            SettingsSection("Command Line") {
                SettingsRow(title: "den command", detail: "Drive Den from any terminal: \(model.cliInstallDetail).") {
                    SettingsButton(title: "Install", symbol: "terminal") { model.installCommandLineTool() }
                }
                SettingsRow(title: "Den for agents", detail: "The den command plus a skill that teaches Claude Code, Codex and others to use it.") {
                    SettingsButton(title: "Install", symbol: "sparkles") { model.installDenForAgents() }
                }
            }

            SettingsSection("Config File", footer: "Settings marked config.toml are written to this file, keeping your comments. Edits made to the file show up here.") {
                SettingsRow(title: "config.toml", detail: PathQuery.abbreviate(UserConfig.url.path)) {
                    HStack(spacing: 6) {
                        SettingsButton(title: "Open", symbol: "doc.text") { model.openConfigFile() }
                        SettingsButton(title: "Reveal", symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([UserConfig.url])
                        }
                        SettingsButton(title: "Reload", symbol: "arrow.clockwise") { model.reloadConfig(force: true) }
                    }
                }
            }
        }
    }

    private var shells: [String] {
        let available = model.availableShells
        return available.contains(model.defaultShell) ? available : [model.defaultShell] + available
    }
}

// MARK: - Permissions

struct PermissionSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("This Mac", footer: footer) {
                ForEach(DendPermission.allCases) { permission in
                    SettingsRow(title: permission.title, detail: permission.detail) {
                        HStack(spacing: 8) {
                            PermissionStatus(permission: permission, theme: theme)
                            if permission.access(model) == .granted {
                                SettingsButton(title: "Open Settings", symbol: "arrow.up.forward") { open(permission) }
                            }
                        }
                    }
                }
            }
            SettingsSection("dend") {
                SettingsRow(title: "Show dend in Finder", detail: PrivacySettings.dendURL.map { PathQuery.abbreviate($0.path) }) {
                    SettingsButton(title: "Reveal", symbol: "folder") {
                        if let dend = PrivacySettings.dendURL { NSWorkspace.shared.activateFileViewerSelecting([dend]) }
                    }
                }
            }
        }
        .refreshesPermissions()
    }

    private var footer: String {
        let base = "Granted to dend, the process that runs your shells, so every shell and agent inherits them. Turn one off in System Settings to take it back."
        if DendPermission.allCases.contains(where: { $0.access(model) == .needsRestart }) {
            return "macOS has a grant dend can't use until it restarts, which ends its sessions. " + base
        }
        return model.permissions == nil ? "dend hasn't reported its access yet; it may be from an older Den. " + base : base
    }

    private func open(_ permission: DendPermission) {
        switch permission {
        case .fullDiskAccess: PrivacySettings.open(.fullDiskAccess)
        case .screenRecording: PrivacySettings.open(.screenRecording)
        }
    }
}
