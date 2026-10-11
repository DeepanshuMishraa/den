import DenProtocol
import SwiftUI

/// Vertical tabs: the host, then each session with its tabs. Activity Mode
/// narrows it to tabs running agents or reporting status, each with what
/// it's doing and since when.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 232

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Color.clear.frame(width: TitleBar.leadingInset - 4)
                SidebarToggle()
                Spacer()
                ActivityModeToggle()
            }
            .padding(.trailing, 8)
            .frame(height: TitleBar.height)
            .background(TitleBarBackground())

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 9) {
                        Image(systemName: "laptopcomputer").font(.system(size: 13.5))
                        Text("This Mac").font(.system(size: 13.5, weight: .semibold))
                    }
                    .foregroundStyle(theme.chromeText)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                    if model.activityMode {
                        ActivityList()
                    } else {
                        ForEach(model.orderedSessions, id: \.id) { session in
                            SessionHeader(session: session)
                            ForEach(model.tabs(in: session.id), id: \.id) { tab in
                                SidebarRow(tab: tab, selected: session.id == model.currentSession && tab.id == model.activeTab)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .animation(.den, value: model.orderedSessions.map(\.id))
                .animation(.den, value: model.activityMode)
            }
            .scrollIndicators(.never)

            HStack {
                IconButton(symbol: "line.3.horizontal.circle", size: 14) { model.palette = .root }
                    .denTooltip("Command Palette", keys: ["⇧", "⌘", "P"])
                Spacer()
                IconButton(symbol: "rectangle.stack.badge.plus", size: 13) { model.createSession(name: "") }
                    .denTooltip("New Session", keys: ["⇧", "⌘", "N"])
                IconButton(symbol: "globe", size: 13.5) { model.palette = .addHost }
                    .denTooltip("Add Remote Host", keys: [])
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .frame(width: Self.width)
    }
}

/// A session's name over its tabs; tap to switch to it.
private struct SessionHeader: View {
    let session: SessionSummary
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(session.name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(model.theme.tertiaryText)
            .overlay(alignment: .trailing) {
                if session.id != model.currentSession, model.sessionWantsAttention(session.id) {
                    Circle().fill(model.theme.accent).frame(width: 6, height: 6).offset(x: 10)
                }
            }
            .padding(.horizontal, 10)
            // Equal room above and below: the name sits midway between the
            // previous session's last tab and its own first one.
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.switchSession(session.id) }
    }
}

/// Activity Mode's list. Re-reads every second so ages tick on. The tab on
/// screen always stays listed, so the sidebar never goes blank under you.
private struct ActivityList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // TimelineView centers loose content; keep rows in a leading stack.
            VStack(alignment: .leading, spacing: 2) {
            let now = context.date
            let groups = model.orderedSessions.compactMap { session -> (SessionSummary, [(TabLayout, TabActivity)])? in
                let rows = model.tabs(in: session.id).compactMap { tab -> (TabLayout, TabActivity)? in
                    if let activity = model.activity(of: tab, now: now) { return (tab, activity) }
                    guard session.id == model.currentSession, tab.id == model.activeTab else { return nil }
                    return (tab, TabActivity(state: .idle, detail: "No agent running", since: now))
                }
                return rows.isEmpty ? nil : (session, rows)
            }
            ForEach(groups, id: \.0.id) { session, rows in
                SessionHeader(session: session)
                ForEach(rows, id: \.0.id) { tab, activity in
                    ActivityRow(tab: tab, activity: activity, now: now,
                                selected: session.id == model.currentSession && tab.id == model.activeTab)
                }
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shows or leaves Activity Mode. On, it sits in a filled circle like a
/// pressed toggle; off, it wears a dot when a tab off screen has something
/// for you.
private struct ActivityModeToggle: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let on = model.activityMode
        Button { withAnimation(.den) { model.toggleActivityMode() } } label: {
            Image(systemName: "eye")
                .font(.system(size: 14, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? theme.chromeText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(on ? theme.activeTab : (hovering ? theme.hover : .clear)))
                .overlay(Circle().strokeBorder(on ? theme.activeTabBorder : .clear, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if !on, model.anyTabWantsAttention {
                Circle()
                    .fill(Color(.sRGB, red: 0.25, green: 0.55, blue: 1, opacity: 1))
                    .frame(width: 6, height: 6)
                    .offset(x: -4, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .denTooltip(on ? "Leave Activity Mode" : "Activity Mode", keys: ["⇧", "⌘", "A"])
    }
}

/// Folds the sidebar away and back. Sits in the same spot either way.
struct SidebarToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IconButton(symbol: "sidebar.left", size: 14) { withAnimation(.den) { model.toggleSidebar() } }
            .denTooltip(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", keys: ["⌥", "⌘", "S"])
    }
}

/// What stays of a collapsed sidebar: room for the traffic lights, the
/// toggle to bring it back, and a strip to drag the window by.
struct CollapsedSidebarBar: View {
    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: TitleBar.leadingInset - 4)
            SidebarToggle()
            Spacer()
        }
        .frame(height: TitleBar.height)
        .background(TitleBarBackground())
    }
}

struct SidebarRow: View {
    let tab: TabLayout
    let selected: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let status = selected ? nil : model.status(of: tab)
        let theme = model.theme
        HStack(spacing: 9) {
            DeckIcon(deck: model.deck(for: tab), height: 16, badge: !selected && model.hasActivity(tab), fan: .up)
            SidebarTitle(title: model.tabTitle(tab), theme: theme)
            Spacer(minLength: 2)
            if hovering {
                Button { model.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(theme.tertiaryText)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if let status {
                StatusGlyph(indicator: status.indicator)
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

/// A tab in Activity Mode, like Rex's: title over what it's doing; on the
/// right, dots while it works or a pill when it needs you, and its age.
struct ActivityRow: View {
    let tab: TabLayout
    let activity: TabActivity
    let now: Date
    let selected: Bool
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        HStack(spacing: 10) {
            DeckIcon(deck: model.deck(for: tab), height: 16, badge: !selected && (model.hasActivity(tab) || model.status(of: tab)?.wantsAttention == true), fan: .up)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.tabTitle(tab))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(selected ? theme.chromeText : theme.chromeText.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingMark(theme)
                }
                HStack(spacing: 6) {
                    Text(activity.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(TabActivity.age(since: activity.since, now: now))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? theme.activeTab : (hovering ? theme.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? theme.activeTabBorder : .clear, lineWidth: 0.5))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.denFast) { model.selectTab(tab.id) } }
        .contextMenu { Button("Close Tab") { model.closeTab(tab.id) } }
    }

    @ViewBuilder private func trailingMark(_ theme: Theme) -> some View {
        switch activity.state {
        case .working:
            WorkingDots(size: 12)
        case .blocked:
            StatusPill(text: "Blocked", tint: theme.chromeText)
        case .error:
            StatusPill(text: "Failed", tint: .red)
        case .done, .idle:
            EmptyView()
        }
    }
}

/// A small capsule label: "Blocked", "Failed".
struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint.opacity(0.9))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(tint.opacity(0.14)))
            .fixedSize()
    }
}

/// A tab title as Rex sets it: the program bright, its folder dimmed
/// ("fish ~/apps/site", "btop ~"); other titles bright throughout.
struct SidebarTitle: View {
    let title: String
    let theme: Theme

    var body: some View {
        Group {
            if let space = title.firstIndex(of: " "),
               let next = title[title.index(after: space)...].first, next == "~" || next == "/" {
                Text(title[..<space]).foregroundStyle(theme.chromeText)
                    + Text(title[space...]).foregroundStyle(theme.tertiaryText)
            } else {
                Text(title).foregroundStyle(theme.chromeText)
            }
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
