import AppKit
import DenProtocol
import SwiftUI

/// Horizontal-tabs title bar. In peek it grows to show a live thumbnail
/// under every tab.
struct TitleBar: View {
    @Environment(AppModel.self) private var model

    static let height: CGFloat = 40
    static let peekHeight: CGFloat = 104
    /// Room for the traffic lights.
    static let leadingInset: CGFloat = 76

    var body: some View {
        let peek = min(model.overviewLevel, 1)
        HStack(alignment: .top, spacing: 4) {
            Color.clear.frame(width: Self.leadingInset, height: Self.height)
            SessionButton()
                .frame(height: Self.height)
            TabStrip()
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                IconButton(symbol: "command", size: 13) { model.palette = .root }
                    .denTooltip("Command Palette", command: .commandPalette)
                IconButton(symbol: "plus", size: 14) { model.newTab() }
                    .denTooltip("New Tab", command: .newTab)
            }
            .frame(height: Self.height)
            .padding(.trailing, 8)
        }
        .frame(height: Self.height + Self.peekHeight * peek, alignment: .top)
        .background(TitleBarBackground())
    }
}

/// Drags the window and double-click zooms. The overview (peek/exposé) is
/// a three-finger swipe handled by DenWindow, plus its keyboard shortcuts —
/// two-finger scrolling over the bar deliberately does nothing, so a scroll
/// aimed at the terminal never pops the glance view open.
struct TitleBarBackground: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {}
}

/// The session's icon and name. Left alone, the name folds away so the tabs
/// get the room; clicking (or switching session) brings it back.
struct SessionButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var expanded = true

    /// How long the name stays out once nothing is touching it.
    private static let idleDelay: Duration = .seconds(3)

    var body: some View {
        let theme = model.theme
        let showsName = expanded || model.showSessionMenu || !isConnected
        Button {
            withAnimation(.den) { expanded = true }
            model.showSessionMenu.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: model.currentHost == .local ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                if showsName {
                    VStack(alignment: .leading, spacing: -1) {
                        Text(model.currentSummary?.name ?? "Connecting…")
                            .uiFont(size: 12.5, weight: .semibold)
                            .foregroundStyle(theme.chromeText)
                        Text(hostLabel)
                            .uiFont(size: 10.5)
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                    .transition(.opacity.combined(with: .offset(x: -6)))
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || model.showSessionMenu ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .denTooltip("Change Session", command: .changeSession)
        .animation(.denFast, value: model.currentSession)
        .onChange(of: model.currentSession) { withAnimation(.den) { expanded = true } }
        // Restarts whenever any of these change; collapses only once all is quiet.
        .task(id: IdleKey(expanded: expanded, hovering: hovering, menuOpen: model.showSessionMenu, session: model.currentSession)) {
            guard expanded, !hovering, !model.showSessionMenu else { return }
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.den) { expanded = false }
        }
    }

    private struct IdleKey: Equatable {
        let expanded: Bool
        let hovering: Bool
        let menuOpen: Bool
        let session: SessionID?
    }

    private var isConnected: Bool {
        if case .remote(let id) = model.currentHost { return model.remoteStates[id]?.isConnected == true }
        if case .connected = model.connectionState { return true } else { return false }
    }

    private var hostLabel: String {
        if case .remote(let id) = model.currentHost {
            let address = model.remoteHost(id)?.address ?? "removed host"
            return model.remoteStates[id].map { $0.isConnected ? address : "\(address) · \(HostStatus.short($0).lowercased())" } ?? address
        }
        return switch model.connectionState {
        case .connected: "This Mac"
        case .connecting: "starting dend"
        case .disconnected: "disconnected"
        }
    }
}

/// The tab strip. One shared capsule slides to the active tab; dividers
/// separate inactive neighbours; tabs drag to reorder.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Namespace private var selection
    @State private var hovered: TabID?
    @State private var dragging: TabID?
    @State private var dragOffset: CGFloat = 0

    static let maxTabWidth: CGFloat = 228
    /// Below this a tab shows only its favicon.
    static let compactTabWidth: CGFloat = 92

    var body: some View {
        GeometryReader { geo in
            let tabs = model.tabs
            // Tabs share the space and shrink toward icon-only, never overflow.
            let width = tabs.isEmpty ? Self.maxTabWidth : min(Self.maxTabWidth, geo.size.width / CGFloat(tabs.count))
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    TabItem(
                        tab: tab, index: index, width: width,
                        active: tab.id == model.activeTab,
                        hovered: hovered == tab.id,
                        selection: selection,
                        showDivider: showDivider(after: index, tabs: tabs)
                    )
                    .onHover { inside in
                        if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
                    }
                    .offset(x: dragging == tab.id ? dragOffset : 0)
                    .zIndex(dragging == tab.id ? 2 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                if dragging == nil {
                                    dragging = tab.id
                                    model.selectTab(tab.id)
                                }
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                let shift = Int((value.translation.width / width).rounded())
                                let target = min(max(index + shift, 0), tabs.count - 1)
                                if target != index { model.moveTab(tab.id, to: target) }
                                withAnimation(.den) {
                                    dragging = nil
                                    dragOffset = 0
                                }
                            }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .leading)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
            }
            .animation(.den, value: tabs.map(\.id))
            .animation(.den, value: model.activeTab)
            .animation(.den, value: model.overview)
        }
        .frame(maxWidth: CGFloat(max(model.tabs.count, 1)) * Self.maxTabWidth)
    }

    private func showDivider(after index: Int, tabs: [TabLayout]) -> Bool {
        guard model.overview == .none, index < tabs.count - 1 else { return false }
        let a = tabs[index].id, b = tabs[index + 1].id
        return a != model.activeTab && b != model.activeTab && a != hovered && b != hovered
    }
}

struct TabItem: View {
    let tab: TabLayout
    let index: Int
    let width: CGFloat
    let active: Bool
    let hovered: Bool
    let selection: Namespace.ID
    let showDivider: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        // 0 → 1 as the peek drawer opens; follows the fingers mid-swipe.
        let peek = min(model.overviewLevel, 1)
        let radius = 15 - 5 * peek
        // Unfocused tabs only: the one on screen speaks for itself.
        let status = active ? nil : model.status(of: tab)
        let compact = width < TabStrip.compactTabWidth
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DeckIcon(deck: model.deck(for: tab), height: 17, badge: !active && model.hasActivity(tab))
                    .overlay(alignment: .bottomTrailing) {
                        if compact, let status { StatusGlyph(indicator: status.indicator, size: 9).offset(x: 4, y: 4) }
                    }
                if !compact {
                    // The tab you're on shows its whole title, flowing, rather than "…".
                    MarqueeText(text: model.tabTitle(tab), flowing: active && peek == 0)
                        .uiFont(size: 13, weight: active ? .medium : .regular)
                        .foregroundStyle(active ? theme.chromeText : theme.secondaryText)
                }
                if !compact, hovered || (active && peek == 0) {
                    Button { model.closeTab(tab.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(theme.tertiaryText)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                } else if !compact, let status {
                    StatusGlyph(indicator: status.indicator)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 30)

            if peek > 0 {
                // Fixed-size thumbnail revealed from the top, so the live
                // terminals inside never resize mid-swipe.
                TabThumbnail(tab: tab)
                    .frame(height: TitleBar.peekHeight - 16)
                    .frame(height: (TitleBar.peekHeight - 16) * peek, alignment: .top)
                    .clipped()
                    .opacity(peek)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6 * peek)
                    .transition(.opacity)
            }
        }
        .frame(width: width - 4)
        .background(alignment: .top) {
            ZStack {
                if active {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.activeTab)
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.activeTabBorder, lineWidth: 0.5))
                        .shadow(color: .black.opacity(theme.isDark ? 0.2 : 0.06), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovered {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.hover)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1, height: 16)
                .offset(x: 2, y: 7)
                .opacity(showDivider ? 1 : 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(tab.id) }
        .denTooltip([model.tabTitle(tab), status?.message].compactMap { $0 }.joined(separator: " — "), command: .goToTab, number: index + 1)
        .animation(.denFast, value: status)
    }
}
