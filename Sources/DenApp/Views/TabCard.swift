import DenProtocol
import SwiftUI

/// A tab's hover card: its title over each of its panes, with the pane's
/// folder and what its program reports. Like `DenTooltip`, the tab only
/// publishes where it is; `TabCardLayer` draws the card above everything.
private struct TabCardHover: ViewModifier {
    let tab: TabLayout
    /// The side of the tab the card opens on.
    let edge: Edge
    let enabled: Bool
    @State private var visible = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                task?.cancel()
                if inside {
                    task = Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        visible = true
                    }
                } else {
                    visible = false
                }
            }
            .onDisappear { task?.cancel(); visible = false }
            .simultaneousGesture(TapGesture().onEnded { task?.cancel(); visible = false })
            .anchorPreference(key: TabCardKey.self, value: .bounds) { anchor in
                guard visible, enabled else { return [] }
                return [TabCardRequest(tab: tab, edge: edge, anchor: anchor)]
            }
    }
}

extension View {
    func tabCard(_ tab: TabLayout, edge: Edge, enabled: Bool = true) -> some View {
        modifier(TabCardHover(tab: tab, edge: edge, enabled: enabled))
    }
}

struct TabCardRequest {
    let tab: TabLayout
    let edge: Edge
    let anchor: Anchor<CGRect>
}

struct TabCardKey: PreferenceKey {
    static let defaultValue: [TabCardRequest] = []
    static func reduce(value: inout [TabCardRequest], nextValue: () -> [TabCardRequest]) {
        value.append(contentsOf: nextValue())
    }
}

/// Draws the hovered tab's card at the top of the window's view tree.
struct TabCardLayer: View {
    let requests: [TabCardRequest]
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            if let request = requests.last, model.overview == .none {
                TabCardPlacement(target: proxy[request.anchor], edge: request.edge) {
                    TabCard(tab: request.tab).fixedSize()
                }
                .id(request.tab.id)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: request.edge.anchor)))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: requests.last?.tab.id)
    }
}

private extension Edge {
    /// Where the card grows from: the side touching the tab.
    var anchor: UnitPoint {
        switch self {
        case .top: .bottom
        case .bottom: .top
        case .leading: .trailing
        case .trailing: .leading
        }
    }
}

/// Puts the card on `edge` of the tab, lined up with its start, and keeps
/// it inside the window.
private struct TabCardPlacement: Layout {
    let target: CGRect
    let edge: Edge
    let gap: CGFloat = 6
    let margin: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let size = card.sizeThatFits(.unspecified)
        var origin: CGPoint = switch edge {
        case .bottom: CGPoint(x: target.minX, y: target.maxY + gap)
        case .top: CGPoint(x: target.minX, y: target.minY - gap - size.height)
        case .trailing: CGPoint(x: target.maxX + gap, y: target.minY)
        case .leading: CGPoint(x: target.minX - gap - size.width, y: target.minY)
        }
        origin.x = min(max(origin.x, bounds.minX + margin), max(bounds.minX + margin, bounds.maxX - margin - size.width))
        origin.y = min(max(origin.y, bounds.minY + margin), max(bounds.minY + margin, bounds.maxY - margin - size.height))
        card.place(at: origin, proposal: .unspecified)
    }
}

private struct TabCard: View {
    let tab: TabLayout
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        let now = Date.now
        // A lone pane is the tab itself: the title says it all.
        let panes = tab.root.panes.count > 1 ? tab.root.panes : []
        VStack(alignment: .leading, spacing: 6) {
            SidebarTitle(title: model.tabTitle(tab), theme: theme, weight: .semibold)
                .padding(.bottom, panes.isEmpty ? 0 : 2)
            ForEach(panes, id: \.self) { pane in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgramTile(kind: model.program(for: pane), height: 11)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 12) {
                            Text(model.title(for: pane))
                                .uiFont(size: 13)
                                .foregroundStyle(theme.chromeText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let activity = model.activity(of: pane, now: now) {
                                Text(activity.state.label)
                                    .uiFont(size: 12)
                                    .foregroundStyle(theme.tertiaryText)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        if let cwd = model.cwd(of: pane) {
                            Text(model.abbreviate(cwd, on: model.host(ofPane: pane)))
                                .uiFont(size: 11.5)
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: panes.isEmpty ? nil : 200, maxWidth: 320, alignment: .leading)
        .background(MenuSurface(theme: theme))
    }
}
