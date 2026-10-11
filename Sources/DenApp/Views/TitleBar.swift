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
                    .denTooltip("Command Palette", keys: ["⇧", "⌘", "P"])
                IconButton(symbol: "plus", size: 14) { model.newTab() }
                    .denTooltip("New Tab", keys: ["⌘", "T"])
            }
            .frame(height: Self.height)
            .padding(.trailing, 8)
        }
        .frame(height: Self.height + Self.peekHeight * peek, alignment: .top)
        .background(TitleBarBackground())
    }
}

/// Drags the window, double-click zooms, and a two-finger scroll down over
/// the bar steps into peek and exposé.
struct TitleBarBackground: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    final class View: NSView {
        var onScroll: ((Int) -> Void)?
        private var accumulated: CGFloat = 0
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return }
            if event.phase == .began { accumulated = 0 }
            accumulated += event.scrollingDeltaY
            if event.phase == .ended || event.phase == .cancelled {
                if accumulated < -40 { onScroll?(1) } else if accumulated > 40 { onScroll?(-1) }
                accumulated = 0
            }
        }
    }

    func makeNSView(context: Context) -> View { View() }

    func updateNSView(_ view: View, context: Context) {
        let model = model
        view.onScroll = { delta in withAnimation(.den) { model.stepOverview(delta) } }
    }
}

struct SessionButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        Button { model.showSessionMenu.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(theme.secondaryText)
                VStack(alignment: .leading, spacing: -1) {
                    Text(model.currentSummary?.name ?? "Connecting…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.chromeText)
                    Text(hostLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.tertiaryText)
                }
                .lineLimit(1)
                .contentTransition(.opacity)
            }
            .padding(.horizontal, 7)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || model.showSessionMenu ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .denTooltip("Change Session", keys: ["⌘", "K"])
        .animation(.denFast, value: model.currentSession)
    }

    private var hostLabel: String {
        switch model.connectionState {
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
        let compact = width < TabStrip.compactTabWidth
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DeckIcon(deck: model.deck(for: tab), height: 15, badge: !active && model.hasActivity(tab))
                if !compact {
                    Text(model.tabTitle(tab))
                        .font(.system(size: 13, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? theme.chromeText : theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .denTooltip(model.tabTitle(tab), keys: index < 9 ? ["⌘", "\(index + 1)"] : [])
    }
}
