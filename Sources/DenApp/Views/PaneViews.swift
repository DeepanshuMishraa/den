import DenProtocol
import SwiftUI

/// Hosts a `TerminalView` inside SwiftUI.
struct TerminalHost: NSViewRepresentable {
    let pane: PaneID
    let model: AppModel
    var mode: TerminalView.Mode = .interactive
    var isFocused = false
    let isReady: Bool

    func makeNSView(context: Context) -> NSView {
        TerminalView(paneID: pane, model: model, mode: mode) ?? NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let terminal = view as? TerminalView else { return }
        if isReady { terminal.attach(model.replica(pane)) }
        terminal.applyFont(family: model.fontFamily, size: model.fontSize)
        terminal.isFocusedPane = isFocused
        terminal.reclaimFocus(request: model.terminalFocusRequest)
    }
}

/// A pane ("block"): a rounded card with a header and the live terminal.
struct PaneCard: View {
    let pane: PaneID
    let tab: TabID
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var width: CGFloat = 1000

    var body: some View {
        let theme = model.theme
        let focused = model.focusedPane(in: tab) == pane
        let multiple = (model.tabs.first { $0.id == tab }?.root.panes.count ?? 1) > 1
        let kind = model.program(for: pane)
        let islands = model.density == .comfortable
        let radius = model.density.cornerRadius

        VStack(spacing: 0) {
            if model.showPaneHeaders {
                HStack(spacing: 7) {
                    HeaderGlyph(kind: kind, color: focused ? theme.chromeText : theme.secondaryText)
                    Text(model.title(for: pane))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(focused || !multiple ? theme.chromeText : theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    // Narrow panes drop their buttons rather than overflow.
                    if width > 190 {
                    HStack(spacing: 0) {
                        IconButton(symbol: "rectangle.split.2x1", size: 12.5, frame: CGSize(width: 24, height: 22)) {
                            model.focus(pane); model.split(.horizontal)
                        }
                        .denTooltip("Split Right", keys: ["⌘", "D"])
                        IconButton(symbol: "rectangle.split.1x2", size: 12.5, frame: CGSize(width: 24, height: 22)) {
                            model.focus(pane); model.split(.vertical)
                        }
                        .denTooltip("Split Down", keys: ["⇧", "⌘", "D"])
                        IconButton(symbol: model.zoomedPane == pane ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   size: 11.5, frame: CGSize(width: 24, height: 22), enabled: multiple) {
                            model.focus(pane); model.toggleZoom()
                        }
                        .denTooltip("Zoom", keys: ["⇧", "⌘", "↩"])
                        IconButton(symbol: "xmark", size: 11.5, frame: CGSize(width: 24, height: 22), enabled: multiple) {
                            model.close(pane)
                        }
                        .denTooltip("Close", keys: ["⌘", "W"])
                    }
                    .opacity(focused || hovering ? 1 : 0.55)
                    }
                }
                .padding(.leading, 13)
                .padding(.trailing, 7)
                .frame(height: 34)
                .contentShape(Rectangle())
                .onTapGesture { model.focus(pane) }
                .zIndex(1)
            }

            TerminalHost(pane: pane, model: model, isFocused: focused && model.activeTab == tab && model.overview != .expose,
                         isReady: model.readyPanes.contains(pane))
                .overlay {
                    if let request = model.pathPicker, request.pane == pane {
                        PathPickerOverlay(request: request)
                    }
                }
                .padding(.top, model.showPaneHeaders ? 0 : 6)
        }
        .background(model.surfaces.card)
        .clipShape(RoundedRectangle(cornerRadius: islands ? radius : 0, style: .continuous))
        .overlay {
            // Islands get a lit edge; compact panes are one flat surface.
            if islands {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [theme.cardHighlight, theme.cardBorder], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.accent.opacity(focused && multiple ? 0.35 : 0), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(islands ? (theme.isDark ? 0.28 : 0.07) : 0), radius: 8, y: 3)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onHover { hovering = $0 }
        .animation(.denFast, value: focused)
    }
}

/// The small monochrome program mark in a pane header.
struct HeaderGlyph: View {
    let kind: ProgramKind
    let color: Color

    var body: some View {
        ProgramGlyph(kind: kind, size: 13, color: color)
            .frame(width: 16, height: 14)
    }
}

/// Recursively lays out a tab's split tree with draggable dividers. In
/// thumbnail mode it draws non-interactive mini terminals.
struct SplitTreeView: View {
    let node: SplitNode
    let tab: TabID
    var path: [UInt8] = []
    var thumbnail = false
    @Environment(AppModel.self) private var model

    var gap: CGFloat { thumbnail ? 3 : model.density.gap }

    var body: some View {
        switch node {
        case .pane(let id):
            if thumbnail {
                TerminalHost(pane: id, model: model, mode: .thumbnail, isReady: model.readyPanes.contains(id))
            } else {
                PaneCard(pane: id, tab: tab)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
            }
        case .split(let axis, let ratio, let first, let second):
            GeometryReader { geo in
                let total = axis == .horizontal ? geo.size.width : geo.size.height
                let firstSize = max(0, (total - gap) * CGFloat(ratio))
                let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    SplitTreeView(node: first, tab: tab, path: path + [0], thumbnail: thumbnail)
                        .frame(width: axis == .horizontal ? firstSize : nil, height: axis == .vertical ? firstSize : nil)
                    if thumbnail {
                        Color.clear.frame(width: axis == .horizontal ? gap : nil, height: axis == .vertical ? gap : nil)
                    } else {
                        Divider(axis: axis, gap: gap, firstSize: firstSize) { size in
                            model.setRatio(tab: tab, path: path, ratio: Float(size / max(total - gap, 1)))
                        }
                    }
                    SplitTreeView(node: second, tab: tab, path: path + [1], thumbnail: thumbnail)
                }
            }
        }
    }

    private struct Divider: View {
        let axis: SplitAxis
        let gap: CGFloat
        let firstSize: CGFloat
        /// Receives the requested size of the first child.
        let onResize: (CGFloat) -> Void
        @State private var startSize: CGFloat?
        @Environment(AppModel.self) private var model

        var body: some View {
            // Compact panes are split by a visible hairline; islands by a gap.
            let line = model.density == .compact ? model.surfaces.hairline : Color.clear
            // Keep a comfortable grab area even when the line is 1pt.
            let grab: CGFloat = max(gap, 8)
            line
                .frame(width: axis == .horizontal ? gap : nil, height: axis == .vertical ? gap : nil)
                .overlay {
                    Color.clear
                        .frame(width: axis == .horizontal ? grab : nil, height: axis == .vertical ? grab : nil)
                        .contentShape(Rectangle())
                        .modifier(DragHandle(axis: axis, firstSize: firstSize, startSize: $startSize, onResize: onResize))
                }
                .zIndex(1)
        }
    }

    private struct DragHandle: ViewModifier {
        let axis: SplitAxis
        let firstSize: CGFloat
        @Binding var startSize: CGFloat?
        let onResize: (CGFloat) -> Void

        func body(content: Content) -> some View {
            content
                .onHover { inside in
                    if inside {
                        (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = startSize ?? firstSize
                            startSize = start
                            onResize(start + (axis == .horizontal ? value.translation.width : value.translation.height))
                        }
                        .onEnded { _ in startSize = nil }
                )
        }
    }
}

/// A live miniature of a whole tab, used by peek and exposé.
struct TabThumbnail: View {
    let tab: TabLayout
    @Environment(AppModel.self) private var model

    var body: some View {
        SplitTreeView(node: tab.root, tab: tab.id, thumbnail: true)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(model.surfaces.card)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(model.theme.cardBorder, lineWidth: 0.5))
    }
}
