import DenVT
import SwiftUI

/// The UI chrome typeface from `ui_font` (falls back to the terminal font).
/// Set once at the root; SF symbols are unaffected (they keep .system).
private struct UiFontFamilyKey: EnvironmentKey {
    static let defaultValue = FontMetrics.defaultFamily
}

extension EnvironmentValues {
    var uiFontFamily: String {
        get { self[UiFontFamilyKey.self] }
        set { self[UiFontFamilyKey.self] = newValue }
    }
}

private struct UiFontModifier: ViewModifier {
    @Environment(\.uiFontFamily) private var family
    let size: CGFloat
    let weight: Font.Weight
    func body(content: Content) -> some View {
        content.font(.custom(family, size: size).weight(weight))
    }
}

extension View {
    /// Chrome text in the configured UI face. Sizes stay per-site; only the
    /// family is centralized. Terminals, icon monograms and SF symbols keep
    /// their own fonts.
    func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(UiFontModifier(size: size, weight: weight))
    }
}

/// Den's tooltip: a small label with keycaps, shown below the view after a
/// short hover (e.g. "Change Session ⌥ Space then S"). The view only
/// publishes where it is; `TooltipLayer` draws it above everything and keeps
/// it inside the window.
struct DenTooltip: ViewModifier {
    let text: String
    let command: DenCommand?
    let number: Int?
    @Environment(AppModel.self) private var model
    @State private var visible = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                task?.cancel()
                if inside {
                    task = Task {
                        try? await Task.sleep(for: .milliseconds(650))
                        guard !Task.isCancelled else { return }
                        visible = true
                    }
                } else {
                    visible = false
                }
            }
            .onDisappear { task?.cancel(); visible = false }
            .simultaneousGesture(TapGesture().onEnded { task?.cancel(); visible = false })
            .anchorPreference(key: TooltipKey.self, value: .bounds) { anchor in
                guard visible, !text.isEmpty else { return [] }
                let keys = command.map { model.config.keycaps($0, number: number) } ?? []
                return [TooltipRequest(text: text, keys: keys, anchor: anchor)]
            }
    }
}

struct TooltipRequest {
    let text: String
    let keys: [[String]]
    let anchor: Anchor<CGRect>
}

struct TooltipKey: PreferenceKey {
    static let defaultValue: [TooltipRequest] = []
    static func reduce(value: inout [TooltipRequest], nextValue: () -> [TooltipRequest]) {
        value.append(contentsOf: nextValue())
    }
}

/// Draws the hovered view's tooltip at the top of the window's view tree.
struct TooltipLayer: View {
    let requests: [TooltipRequest]
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            if let request = requests.last {
                TooltipPlacement(target: proxy[request.anchor]) {
                    TooltipBubble(text: request.text, keys: request.keys, theme: theme)
                        .fixedSize()
                }
                .id(request.text)
                .transition(.opacity.combined(with: .offset(y: -2)))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: requests.last?.text)
    }
}

/// Centers the bubble under its target, flips it above near the bottom
/// edge, and keeps it clear of the window's edges.
private struct TooltipPlacement: Layout {
    let target: CGRect
    let gap: CGFloat = 6
    let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(.unspecified)
        let maxX = max(bounds.minX + margin, bounds.maxX - margin - size.width)
        let x = min(max(target.midX - size.width / 2, bounds.minX + margin), maxX)
        var y = target.maxY + gap
        if y + size.height > bounds.maxY - margin { y = target.minY - gap - size.height }
        bubble.place(at: CGPoint(x: x, y: max(y, bounds.minY + margin)), proposal: .unspecified)
    }
}

struct TooltipBubble: View {
    let text: String
    /// One group per keypress; leader shortcuts have two.
    let keys: [[String]]
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Text(text).uiFont(size: 11.5, weight: .medium)
            ForEach(Array(keys.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Text("then").uiFont(size: 10.5).foregroundStyle(theme.tertiaryText)
                }
                HStack(spacing: 3) {
                    ForEach(Array(group.enumerated()), id: \.offset) { Keycap(label: $0.element, theme: theme) }
                }
            }
        }
        .foregroundStyle(theme.chromeText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.menuFill))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.menuBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

struct Keycap: View {
    let label: String
    let theme: Theme

    var body: some View {
        Text(label)
            .uiFont(size: 10.5, weight: .semibold)
            .frame(minWidth: 15, minHeight: 15)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 3.5).fill(theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07)))
    }
}

extension View {
    /// Keycaps come from the command's shortcut in the config.
    func denTooltip(_ text: String, command: DenCommand? = nil, number: Int? = nil) -> some View {
        modifier(DenTooltip(text: text, command: command, number: number))
    }
}

/// Plain button style whose entire label bounds are clickable.
/// `.plain` hit-tests only opaque pixels, so clicks on padding, transparent
/// gaps or a `Spacer` fall through; this style makes the full frame respond.
struct HitAreaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == HitAreaButtonStyle {
    static var hitArea: HitAreaButtonStyle { HitAreaButtonStyle() }
}

/// Borderless icon button with a rounded hover fill.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var weight: Font.Weight = .medium
    var frame = CGSize(width: 26, height: 24)
    var enabled = true
    let action: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(enabled ? model.theme.secondaryText : model.theme.tertiaryText.opacity(0.6))
                .frame(width: frame.width, height: frame.height)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && enabled ? model.theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.hitArea)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// Den's toast: a floating glass pill pinned to the bottom edge of the
/// window, as in Superlogical's Rex. The pill blurs what is behind it and
/// tints the blur with the active theme; how much theme shows follows the
/// interface style (Modern most see-through, Themed opaque). A success
/// badge, a single-line message that ticks over when it is too long to
/// fit, and capsule buttons with their shortcuts printed inside.
struct ToastView: View {
    let toast: AppModel.Toast
    let theme: Theme
    let style: InterfaceStyle
    let fontFamily: String
    let fontSize: CGFloat
    let onAction: (UUID) -> Void

    /// Success green that reads on both appearances.
    private var green: Color {
        theme.isDark
            ? Color(red: 0.32, green: 0.92, blue: 0.52)
            : Color(red: 0.03, green: 0.48, blue: 0.24)
    }

    private var orange: Color {
        theme.isDark ? Color(red: 1, green: 0.7, blue: 0.3) : Color(red: 0.72, green: 0.4, blue: 0)
    }

    private var red: Color {
        theme.isDark ? Color(red: 1, green: 0.45, blue: 0.45) : Color(red: 0.78, green: 0.13, blue: 0.13)
    }

    /// The toast's color: green for confirmations, the theme's accent for
    /// notices, orange for warnings, red for failures.
    private var tint: Color {
        switch toast.tone {
        case .success: green
        case .notice: theme.accent
        case .warning: orange
        case .danger: red
        }
    }

    var body: some View {
        let font = Font.custom(fontFamily, size: fontSize)
        let buttons = toast.actions.filter { $0.role == .button }
        let dismiss = toast.actions.first { $0.role == .dismiss }
        ToastLayout(spacing: 5, maxWidth: 636) {
            HStack(spacing: 10) {
                badge.padding(.leading, 2)
                VStack(alignment: .leading, spacing: 1) {
                    TickerText(text: toast.message, font: font.weight(.semibold), color: titleColor)
                    if let detail = toast.detail {
                        Text(detail)
                            .font(font.weight(.regular))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(detail)
                    }
                }
                // Beside buttons the message gets a short window and ticks
                // through it, keeping the pill compact; a detail line
                // needs room to say why.
                .frame(maxWidth: toast.actions.isEmpty ? nil : (toast.detail == nil ? 240 : 380), alignment: .leading)
                .layoutPriority(1)
                if !toast.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(buttons.enumerated()), id: \.element.id) { index, action in
                            ToastButton(label: action.label, shortcut: action.shortcut,
                                        primary: index == 0, theme: theme, tint: tint, font: font) {
                                onAction(action.id)
                            }
                        }
                        if let dismiss {
                            ToastDismissButton(theme: theme, tint: tint) { onAction(dismiss.id) }
                                .help(dismiss.shortcut.map { "Dismiss (\($0))" } ?? "Dismiss")
                        }
                    }
                }
            }
            if let progress = toast.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(height: 3)
                    .clipShape(Capsule())
            } else if toast.isPersistent, toast.actions.isEmpty {
                // Indeterminate work (checking, installing): a thin bar
                // under the message keeps the pill visibly alive.
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(height: 3)
                    .clipShape(Capsule())
            }
        }
        // Buttons sit close to the rounded end, as capsules nested in a capsule.
        .padding(.leading, 10)
        .padding(.trailing, toast.actions.isEmpty ? 14 : 7)
        .padding(.vertical, 7)
        .background(toastGlass)
    }

    /// Warnings and failures always read in their color; other toasts only
    /// beside buttons.
    private var titleColor: Color {
        switch toast.tone {
        case .warning, .danger: tint
        case .success, .notice: toast.actions.isEmpty ? theme.chromeText : tint
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch toast.tone {
        case .warning, .danger:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
        case .success:
            ZStack {
                Circle().fill(green)
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .heavy))
                    .foregroundStyle(theme.isDark ? Color.black.opacity(0.75) : Color.white)
            }
            .frame(width: 18, height: 18)
        case .notice(let symbol):
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient)
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
        }
    }

    /// The capsule behind the toast follows the interface style: opaque
    /// for Themed, theme-tinted Liquid Glass for Modern, a frosted blur for
    /// Blended. Each gets a hairline border and a glossy top highlight.
    @ViewBuilder
    private var toastGlass: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        switch style {
        case .modern:
            if #available(macOS 26, *) {
                Color.clear
                    .glassEffect(.regular.tint(Color(nsColor: theme.glassTint)), in: shape)
                    .overlay(shape.strokeBorder(theme.menuBorder, lineWidth: 0.5))
                    .overlay(gloss(shape))
                    .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.15), radius: 20, y: 8)
            } else {
                frosted(shape)
            }
        case .blended:
            frosted(shape)
        case .themed:
            shape
                .fill(theme.isDark ? theme.background.lightened(0.06).color : Color.white)
                .overlay(shape.strokeBorder(theme.menuBorder, lineWidth: 0.5))
                .overlay(shape.strokeBorder(highlight, lineWidth: 0.5).padding(0.5).opacity(0.6))
                .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.2), radius: 22, y: 10)
        }
    }

    private func frosted(_ shape: RoundedRectangle) -> some View {
        let tint = theme.isDark
            ? theme.background.darkened(0.25).color.opacity(style == .modern ? 0.55 : 0.82)
            : Color.white.opacity(style == .modern ? 0.55 : 0.85)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(shape.fill(tint))
            .overlay(shape.strokeBorder(theme.menuBorder, lineWidth: 0.5))
            .overlay(gloss(shape))
            .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.2), radius: 22, y: 10)
    }

    /// A bright rim fading down from the top edge.
    private func gloss(_ shape: RoundedRectangle) -> some View {
        shape.strokeBorder(highlight, lineWidth: 1)
            .padding(0.5)
            .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
    }

    private var highlight: Color {
        theme.isDark ? Color.white.opacity(0.14) : Color.white.opacity(0.9)
    }
}

/// One pill button inside the toast. The first button is the primary
/// action in the toast's color; the rest are neutral. A shortcut hint
/// prints inside, dimmed.
private struct ToastButton: View {
    let label: String
    let shortcut: String?
    let primary: Bool
    let theme: Theme
    let tint: Color
    let font: Font
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(font.weight(.semibold))
                if let shortcut {
                    Text(shortcut).font(font.weight(.medium)).opacity(0.6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
        }
        .buttonStyle(.hitArea)
        .foregroundStyle(foreground)
        .opacity(hovering ? 0.88 : 1)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if primary { return tint.opacity(theme.isDark ? 0.22 : 0.14) }
        return theme.isDark ? Color.white.opacity(hovering ? 0.13 : 0.08) : Color.black.opacity(hovering ? 0.09 : 0.06)
    }

    private var stroke: Color {
        if primary { return tint.opacity(0.45) }
        return theme.menuBorder
    }

    private var foreground: Color {
        primary ? tint : theme.chromeText
    }
}

/// The round ✕ at a toast's end.
private struct ToastDismissButton: View {
    let theme: Theme
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(hovering ? 0.26 : 0.16)))
                .contentShape(Circle())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
    }
}

/// Lays out the toast's content row and optional progress bar. Sizes the toast to
/// hug its content row (capped at `maxWidth`), and forces the progress bar to match
/// the width of the row rather than greedily expanding the toast.
private struct ToastLayout: Layout {
    var spacing: CGFloat = 5
    var maxWidth: CGFloat = 636

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let availableWidth = min(proposal.width ?? maxWidth, maxWidth)
        let firstSize = first.sizeThatFits(ProposedViewSize(width: availableWidth, height: proposal.height))
        let toastWidth = min(firstSize.width, availableWidth)
        var totalHeight = firstSize.height
        for subview in subviews.dropFirst() {
            let s = subview.sizeThatFits(ProposedViewSize(width: toastWidth, height: proposal.height))
            totalHeight += spacing + s.height
        }
        return CGSize(width: toastWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        var y = bounds.minY
        let rowH = first.sizeThatFits(ProposedViewSize(width: bounds.width, height: proposal.height)).height
        first.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: rowH))
        y += rowH + spacing
        for subview in subviews.dropFirst() {
            let h = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h + spacing
        }
    }
}

/// Sizes ticker text to fit its natural text width when unconstrained, but caps at
/// the proposed width when constrained so long text can scroll.
private struct TickerTextLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let textMeasure = subviews.first else { return .zero }
        let natural = textMeasure.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let width = proposal.width.map { min(natural.width, $0) } ?? natural.width
        return CGSize(width: width, height: max(20, natural.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Every subview must be placed, or SwiftUI centers it in bounds.
        subviews.first?.place(at: bounds.origin, proposal: .unspecified)
        if subviews.count > 1 {
            subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// A single-line message that scrolls like a ticker when it overflows,
/// with soft fades at the edges while it moves.
private struct TickerText: View {
    let text: String
    let font: Font
    let color: Color
    @State private var textWidth: CGFloat = 0
    @State private var start = Date()

    private static let speed: CGFloat = 42
    private static let gap: CGFloat = 56

    var body: some View {
        TickerTextLayout {
            // Index 0: unconstrained measurement of text width, never drawn
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }

            // Index 1: placed within visible bounds
            GeometryReader { geo in
                let visibleWidth = geo.size.width
                let scrolling = textWidth > visibleWidth + 1
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    let offset = x(at: context.date, scrolling: scrolling)
                    HStack(spacing: 0) {
                        Text(text).font(font).foregroundStyle(color)
                            .fixedSize()
                        if scrolling {
                            // Second copy for a seamless wrap.
                            Text(text).font(font).foregroundStyle(color)
                                .fixedSize()
                                .padding(.leading, Self.gap)
                        }
                    }
                    .offset(x: offset)
                    .lineLimit(1)
                    .frame(width: visibleWidth, alignment: .leading)
                    .clipped()
                    .mask(fade(scrolling: scrolling))
                }
            }
        }
        .frame(height: 20)
        .onChange(of: text) { start = Date() }
    }

    private func x(at date: Date, scrolling: Bool) -> CGFloat {
        guard scrolling else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(start) - 1.1)
        let total = textWidth + Self.gap
        return -(elapsed * Self.speed).truncatingRemainder(dividingBy: total)
    }

    @ViewBuilder
    private func fade(scrolling: Bool) -> some View {
        if scrolling {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.93),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        } else {
            LinearGradient(colors: [.black], startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// The terminal is an AppKit view holding first responder, so SwiftUI's
/// `@FocusState` alone can't move focus into an overlay's text field.
@MainActor
enum KeyboardFocus {
    /// Moves first responder off the terminal, then lets SwiftUI focus the field.
    static func takeFromTerminal(_ focusField: @escaping @MainActor () -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.firstResponder is TerminalView {
            // The window itself; SwiftUI then moves focus into the field.
            window.makeFirstResponder(nil)
        }
        // Next runloop turn, after the hosting view owns the responder chain.
        DispatchQueue.main.async { focusField() }
    }
}

/// One line of text that, while `flowing` and too wide for its space, drifts
/// left in a seamless loop instead of ending in "…": a pause to read the
/// start, then two copies a gap apart scroll by under faded edges. Otherwise,
/// and under Reduce Motion, it truncates like any label. Font and color come
/// from the environment.
struct MarqueeText: View {
    let text: String
    let flowing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0

    var body: some View {
        let flows = flowing && !reduceMotion && boxWidth > 0 && textWidth > boxWidth + 0.5
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(flows ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                // Natural width, measured without affecting layout.
                Text(text)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if flows {
                    MarqueeStrip(text: text, distance: textWidth + MarqueeStrip.gap)
                        .frame(width: boxWidth, alignment: .leading)
                        .mask(MarqueeStrip.edgeFade)
                        // A new title or width starts the loop over.
                        .id(MarqueeStrip.Key(text: text, textWidth: textWidth))
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .animation(.denFast, value: flows)
    }
}

/// The moving part of `MarqueeText`.
private struct MarqueeStrip: View {
    struct Key: Hashable {
        let text: String
        let textWidth: CGFloat
    }

    static let gap: CGFloat = 32
    /// Points per second: slow enough to read along.
    static let speed: CGFloat = 32
    /// Rest at the start of every pass.
    static let pause: Double = 1.4

    static let edgeFade = LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.06),
            .init(color: .black, location: 0.86),
            .init(color: .clear, location: 1),
        ],
        startPoint: .leading, endPoint: .trailing
    )

    let text: String
    /// One copy plus the gap: shifting this far looks like no shift at all.
    let distance: CGFloat
    @State private var shift: CGFloat = 0

    var body: some View {
        HStack(spacing: Self.gap) {
            Text(text).fixedSize()
            Text(text).fixedSize()
        }
        .lineLimit(1)
        .offset(x: shift)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: distance / Self.speed).delay(Self.pause).repeatForever(autoreverses: false)) {
                shift = -distance
            }
        }
    }
}

/// The springs Den uses throughout: quick and slightly soft.
extension Animation {
    static let den = Animation.spring(response: 0.3, dampingFraction: 0.86)
    static let denFast = Animation.spring(response: 0.22, dampingFraction: 0.9)
}

/// Fuzzy matching for the palette and menus, ranked so what you meant
/// comes first: exact, then prefix, then a word starting with the query,
/// then a plain substring, then letters scattered through the text (best
/// when they land on word starts and run together).
enum Fuzzy {
    struct Match: Equatable {
        /// Matched character offsets, for highlighting.
        let hits: [Int]
        /// Higher is better.
        let score: Int
    }

    /// Returns matched character offsets, or nil when `query` doesn't match.
    static func match(_ query: String, in text: String) -> [Int]? {
        rank(query, in: text)?.hits
    }

    static func rank(_ query: String, in text: String) -> Match? {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return Match(hits: [], score: 0) }
        let t = fold(text)
        guard q.count <= t.count else { return nil }
        // Shorter texts win ties: "Theme" over "Change Theme Folder".
        let brevity = -t.count

        if t == q { return Match(hits: Array(t.indices), score: 10_000) }
        if let start = substring(q, in: t) {
            let hits = Array(start ..< start + q.count)
            if start == 0 { return Match(hits: hits, score: 8_000 + brevity) }
            if let word = wordStarts(t).first(where: { substring(q, in: Array(t[$0...])) == 0 }) {
                return Match(hits: Array(word ..< word + q.count), score: 6_000 - word * 4 + brevity)
            }
            return Match(hits: hits, score: 4_000 - start * 4 + brevity)
        }
        return scattered(q, in: t).map { Match(hits: $0.hits, score: $0.score + brevity) }
    }

    /// Ranks `items` by how well `key` matches `query`, dropping misses.
    /// Equal scores keep their original order.
    static func filter<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, item in rank(query, in: key(item)).map { (i, item, $0.score) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    private static func fold(_ s: String) -> [Character] {
        s.map { Character($0.lowercased().first.map(String.init) ?? String($0)) }
    }

    private static func substring(_ q: [Character], in t: [Character]) -> Int? {
        guard q.count <= t.count else { return nil }
        return (0 ... t.count - q.count).first { t[$0 ..< $0 + q.count].elementsEqual(q) }
    }

    private static func isWordStart(_ t: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = t[i - 1]
        return !(prev.isLetter || prev.isNumber) || (prev.isLowercase && t[i].isUppercase)
    }

    private static func wordStarts(_ t: [Character]) -> [Int] {
        t.indices.filter { isWordStart(t, $0) && (t[$0].isLetter || t[$0].isNumber) }
    }

    /// Best subsequence placement: word starts and runs score, gaps cost.
    private static func scattered(_ q: [Character], in t: [Character]) -> (hits: [Int], score: Int)? {
        let n = t.count, m = q.count
        let none = Int.min / 4
        // best[j][i]: best score with q[..<j+1] matched and q[j] at t[i].
        var best = Array(repeating: Array(repeating: none, count: n), count: m)
        var from = Array(repeating: Array(repeating: -1, count: n), count: m)
        for j in 0 ..< m {
            // Max of best[j-1][k] + k over k <= i - 2: a gap of i - k - 1
            // costs that many points.
            var far = none, farAt = -1
            for i in 0 ..< n {
                if j > 0, i >= 2, best[j - 1][i - 2] > none, best[j - 1][i - 2] + (i - 2) > far {
                    far = best[j - 1][i - 2] + (i - 2)
                    farAt = i - 2
                }
                guard t[i] == q[j] else { continue }
                let bonus = 10 + (isWordStart(t, i) ? 20 : 0)
                if j == 0 {
                    best[j][i] = bonus - i
                    continue
                }
                let adjacent = i >= 1 && best[j - 1][i - 1] > none ? best[j - 1][i - 1] + 15 : none
                let gapped = farAt >= 0 ? far - i + 1 : none
                guard max(adjacent, gapped) > none else { continue }
                if adjacent >= gapped {
                    best[j][i] = adjacent + bonus
                    from[j][i] = i - 1
                } else {
                    best[j][i] = gapped + bonus
                    from[j][i] = farAt
                }
            }
        }
        guard let end = (0 ..< n).max(by: { best[m - 1][$0] < best[m - 1][$1] }), best[m - 1][end] > none else { return nil }
        var hits = [end]
        var j = m - 1, i = end
        while j > 0 { i = from[j][i]; j -= 1; hits.append(i) }
        return (hits.reversed(), best[m - 1][end])
    }

    static func highlighted(_ text: String, hits: [Int], base: Color, accent: Color) -> Text {
        let set = Set(hits)
        var out = AttributedString()
        for (i, ch) in text.enumerated() {
            var piece = AttributedString(String(ch))
            piece.foregroundColor = set.contains(i) ? accent : base
            out.append(piece)
        }
        return Text(out)
    }
}
