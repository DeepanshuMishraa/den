import DenProtocol
import SwiftUI

/// Vertical tabs: the host, then each session with its tabs.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 232

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Color.clear.frame(width: TitleBar.leadingInset - 4)
                IconButton(symbol: "sidebar.left", size: 14) { withAnimation(.den) { model.tabStyle = .horizontal } }
                    .denTooltip("Switch to Horizontal Tabs")
                Spacer()
                IconButton(symbol: "command", size: 13) { model.palette = .root }
                    .denTooltip("Command Palette", keys: ["⇧", "⌘", "P"])
                IconButton(symbol: "plus", size: 14) { model.newTab() }
                    .denTooltip("New Tab", keys: ["⌘", "T"])
            }
            .frame(height: TitleBar.height)
            .background(TitleBarBackground())

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer").font(.system(size: 13))
                        Text("This Mac").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(theme.chromeText)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                    ForEach(model.orderedSessions, id: \.id) { session in
                        Text(session.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                            .contentShape(Rectangle())
                            .onTapGesture { model.switchSession(session.id) }
                        ForEach(model.tabs(in: session.id), id: \.id) { tab in
                            SidebarRow(tab: tab, selected: session.id == model.currentSession && tab.id == model.activeTab)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .animation(.den, value: model.orderedSessions.map(\.id))
            }
            .scrollIndicators(.never)

            HStack {
                IconButton(symbol: "gearshape", size: 13) { model.palette = .root }
                Spacer()
                IconButton(symbol: "rectangle.stack.badge.plus", size: 13) { model.createSession(name: "") }
                    .denTooltip("New Session", keys: ["⇧", "⌘", "N"])
                IconButton(symbol: "square.grid.2x2", size: 13) { withAnimation(.den) { model.overview = .expose } }
                    .denTooltip("Show All Sessions", keys: ["⌃", "⌘", "E"])
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .frame(width: Self.width)
    }
}

struct SidebarRow: View {
    let tab: TabLayout
    let selected: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        HStack(spacing: 9) {
            DeckIcon(deck: model.deck(for: tab), height: 15, badge: !selected && model.hasActivity(tab))
            Text(model.tabTitle(tab))
                .font(.system(size: 13))
                .foregroundStyle(selected ? theme.chromeText : theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 2)
            if hovering {
                Button { model.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(theme.tertiaryText)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? theme.activeTab : (hovering ? theme.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? theme.activeTabBorder : .clear, lineWidth: 0.5))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.denFast) { model.selectTab(tab.id) } }
    }
}
