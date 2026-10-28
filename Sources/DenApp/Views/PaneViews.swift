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
    @State private var size = CGSize(width: 1000, height: 600)
    private var width: CGFloat { size.width }

    var body: some View {
        let theme = model.theme
        let focused = model.focusedPane(in: tab) == pane
        let multiple = (model.tabs.first { $0.id == tab }?.root.panes.count ?? 1) > 1
        let kind = model.program(for: pane)
        let islands = model.density == .comfortable
        let radius = model.density.cornerRadius
        // A full-screen program's background colors the pane and its header;
        // the ink flips to stay readable on it.
        let programBackground = model.matchProgramBackgrounds ? model.paneProgramBackgrounds[pane] : nil
        let ink: Color? = programBackground.map { $0.luminance > 0.45 ? .black : .white }
        let activeInk = ink ?? theme.chromeText
        let inactiveInk = ink?.opacity(0.62) ?? theme.secondaryText

        VStack(spacing: 0) {
            if model.showPaneHeaders {
                HStack(spacing: 7) {
                    HeaderGlyph(kind: kind, color: focused ? activeInk : inactiveInk)
                    Text(model.title(for: pane))
                        .uiFont(size: 13, weight: .semibold)
                        .foregroundStyle(focused || !multiple ? activeInk : inactiveInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    // Narrow panes drop their buttons rather than overflow.
                    if width > 190 {
                    HStack(spacing: 0) {
                        IconButton(symbol: "rectangle.split.2x1", size: 12.5, frame: CGSize(width: 24, height: 22), ink: ink) {
                            model.focus(pane); model.split(.horizontal)
                        }
                        .denTooltip("Split Right", command: .splitRight)
                        IconButton(symbol: "rectangle.split.1x2", size: 12.5, frame: CGSize(width: 24, height: 22), ink: ink) {
                            model.focus(pane); model.split(.vertical)
                        }
                        .denTooltip("Split Down", command: .splitDown)
                        IconButton(symbol: model.zoomedPane == pane ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   size: 11.5, frame: CGSize(width: 24, height: 22), ink: ink, enabled: multiple) {
                            model.focus(pane); model.toggleZoom()
                        }
                        .denTooltip("Zoom", command: .zoomPane)
                        IconButton(symbol: "xmark", size: 11.5, frame: CGSize(width: 24, height: 22), ink: ink, enabled: multiple) {
                            model.close(pane)
                        }
                        .denTooltip("Close", command: .closePane)
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
        .background(programBackground.map { AnyShapeStyle($0.color) } ?? model.surfaces.card)
        .clipShape(RoundedRectangle(cornerRadius: islands ? radius : 0, style: .continuous))
        .overlay {
            // Islands get a lit edge; compact panes are one flat surface.
            if islands {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [theme.cardHighlight, theme.cardBorder], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                if !model.config.paneBorder {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(theme.accent.opacity(focused && multiple ? 0.35 : 0), lineWidth: 1)
                }
            }
            // `pane_border`: the focused pane wears the theme's accent, in
            // either density; it fades across as focus moves.
            if model.config.paneBorder {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.accent.opacity(focused && multiple ? 0.9 : 0), lineWidth: 1.5)
                    .animation(.easeInOut(duration: 0.22), value: focused)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(islands ? (theme.isDark ? 0.28 : 0.07) : 0), radius: 8, y: 3)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .overlay {
            // ⌘-drag: the lifted pane dims; every other one shows where it can go.
            if let drag = model.paneDrag {
                if drag.source == pane {
                    RoundedRectangle(cornerRadius: islands ? radius : 0, style: .continuous)
                        .fill(Color.black.opacity(0.4))
                        .allowsHitTesting(false)
                } else {
                    PaneDropRegions(active: dropPlacement(drag), theme: theme, radius: max(radius - 3, 4))
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.paneDrag?.source)
        // No cleanup on disappear: after a move the rebuilt card records its
        // frame before the old one goes away, and removing it then would
        // leave the pane undroppable. Drops only consider the tab's panes.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(RootView.space)) } action: { frame in
            size = frame.size
            model.paneFrames[pane] = frame
        }
        .onHover { hovering = $0 }
        .animation(.denFast, value: focused)
    }

    private func dropPlacement(_ drag: AppModel.PaneDragState) -> PanePlacement? {
        guard case .pane(let target, let placement)? = drag.drop, target == pane else { return nil }
        return placement
    }
}

/// The tab on screen: its panes laid out flat, each card keyed by its pane,
/// so a split, move, swap or close springs every card from its old frame to
/// its new one, as in Rex, instead of rebuilding the cards whose place in
/// the split tree changed.
struct PaneDeck: View {
    let tab: TabLayout
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let gap = model.density.gap
            let layout = DeckLayout(tab.root, in: CGRect(origin: .zero, size: geo.size), gap: gap)
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.pane) { slot in
                    PaneCard(pane: slot.pane, tab: tab.id)
                        .frame(width: slot.rect.width, height: slot.rect.height)
                        .position(x: slot.rect.midX, y: slot.rect.midY)
                        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                }
                ForEach(layout.splits, id: \.path) { split in
                    SplitTreeView.Divider(axis: split.axis, gap: gap, firstSize: split.firstSize) { size in
                        model.setRatio(tab: tab.id, path: split.path, ratio: Float(size / max(split.total - gap, 1)))
                    }
                    .frame(width: split.gap.width, height: split.gap.height)
                    .position(x: split.gap.midX, y: split.gap.midY)
                }
            }
        }
    }
}

/// Where each pane and divider of a split tree sits, with `gap` between
/// siblings: the same arithmetic as `SplitTreeView`, flattened.
struct DeckLayout {
    struct Slot {
        let pane: PaneID
        let rect: CGRect
    }

    struct Split {
        let path: [UInt8]
        let axis: SplitAxis
        /// The gap between the two children, where the divider sits.
        let gap: CGRect
        let firstSize: CGFloat
        /// The split's length along its axis, gap included.
        let total: CGFloat
    }

    private(set) var panes: [Slot] = []
    private(set) var splits: [Split] = []

    init(_ root: SplitNode, in rect: CGRect, gap: CGFloat) {
        place(root, in: rect, path: [], gap: gap)
    }

    private mutating func place(_ node: SplitNode, in rect: CGRect, path: [UInt8], gap: CGFloat) {
        switch node {
        case .pane(let id):
            panes.append(Slot(pane: id, rect: rect))
        case .split(let axis, let ratio, let first, let second):
            let horizontal = axis == .horizontal
            let total = horizontal ? rect.width : rect.height
            let a = max(0, (total - gap) * CGFloat(ratio))
            let b = max(0, total - a - gap)
            let (firstRect, gapRect, secondRect) = horizontal
                ? (CGRect(x: rect.minX, y: rect.minY, width: a, height: rect.height),
                   CGRect(x: rect.minX + a, y: rect.minY, width: gap, height: rect.height),
                   CGRect(x: rect.minX + a + gap, y: rect.minY, width: b, height: rect.height))
                : (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: a),
                   CGRect(x: rect.minX, y: rect.minY + a, width: rect.width, height: gap),
                   CGRect(x: rect.minX, y: rect.minY + a + gap, width: rect.width, height: b))
            place(first, in: firstRect, path: path + [0], gap: gap)
            splits.append(Split(path: path, axis: axis, gap: gapRect, firstSize: a, total: total))
            place(second, in: secondRect, path: path + [1], gap: gap)
        }
    }
}

/// The outlined card that grows out of a pane as it splits, toward where
/// the new pane lands, as in Rex. It fades once the real pane is in place.
struct SplitGhostCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let ghost = model.splitGhost {
                Grow(ghost: ghost).id(ghost.id).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.16), value: model.splitGhost)
        .allowsHitTesting(false)
    }

    private struct Grow: View {
        let ghost: AppModel.SplitGhost
        @Environment(AppModel.self) private var model
        @State private var grown = false

        var body: some View {
            let theme = model.theme
            let gap = model.density.gap
            let f = ghost.frame
            let side = ghost.axis == .horizontal
            // The new pane's slot: the far half of the split pane.
            let slot = side
                ? CGRect(x: f.midX + gap / 2, y: f.minY, width: max(f.width / 2 - gap / 2, 0), height: f.height)
                : CGRect(x: f.minX, y: f.midY + gap / 2, width: f.width, height: max(f.height / 2 - gap / 2, 0))
            let radius = max(model.density.cornerRadius, 6)
            HStack(spacing: 7) {
                HeaderGlyph(kind: .shell, color: theme.secondaryText)
                Text(ProgramKind.shell.name).uiFont(size: 13, weight: .semibold).foregroundStyle(theme.secondaryText)
            }
            .padding(.leading, 13)
            .frame(height: 34)
            .frame(width: side && !grown ? 0 : slot.width, height: !side && !grown ? 0 : slot.height, alignment: .topLeading)
            .background(model.surfaces.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(theme.accent.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.3 : 0.1), radius: 10, y: 4)
            .offset(x: slot.minX, y: slot.minY)
            .onAppear { withAnimation(.denFast) { grown = true } }
        }
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

    struct Divider: View {
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
