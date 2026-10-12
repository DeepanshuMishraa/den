import DenProtocol
import SwiftUI

/// Exposé: every session's tabs as live cards, like Mission Control for the
/// terminal. Click a card to jump straight into it.
struct ExposeView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 14, alignment: .top)]

    var body: some View {
        let theme = model.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(model.orderedSessions, id: \.id) { session in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(session.name)
                                .uiFont(size: 13, weight: .semibold)
                                .foregroundStyle(session.id == model.currentSession ? theme.chromeText : theme.secondaryText)
                            if session.id == model.currentSession {
                                Circle().fill(theme.accent).frame(width: 5, height: 5)
                            }
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(model.tabs(in: session.id), id: \.id) { tab in
                                ExposeCard(tab: tab, isActive: session.id == model.currentSession && tab.id == model.activeTab)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 50)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.automatic)
    }
}

struct ExposeCard: View {
    let tab: TabLayout
    let isActive: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DeckIcon(deck: model.deck(for: tab), height: 15, badge: model.hasActivity(tab))
                Text(model.tabTitle(tab))
                    .uiFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.chromeText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering {
                    Button { model.closeTab(tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(theme.tertiaryText)
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            TabThumbnail(tab: tab)
                .aspectRatio(16 / 9, contentMode: .fit)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(hovering ? theme.activeTab : theme.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isActive ? theme.accent.opacity(0.6) : .clear, lineWidth: 1.5)
        )
        .scaleEffect(hovering ? 1.015 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.den) {
                model.selectTab(tab.id)
                model.overview = .none
            }
        }
        .animation(.denFast, value: hovering)
    }
}
