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
                // On the right, the traffic lights sit over the panes' bar.
                Color.clear.frame(width: model.sidebarSide == .left ? TitleBar.leadingInset - 4 : 6)
                SidebarToggle()
                Spacer()
                ActivityModeToggle()
            }
            .padding(.trailing, 8)
            .frame(height: TitleBar.height)
            .background(TitleBarBackground())

            ScrollView {
                // Like Rex, the list blurs across when the mode flips.
                Group {
                    if model.activityMode {
                        ActivityList()
                            .transition(.blurReplace)
                    } else {
                        // Each machine, then its sessions and their tabs.
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach([HostID.local] + model.remoteHosts.map { .remote($0.id) }, id: \.self) { host in
                                SidebarHostHeader(host: host)
                                if !model.isCollapsed(host) {
                                    ForEach(model.sessions(on: host), id: \.id) { session in
                                        VStack(alignment: .leading, spacing: 3) {
                                            SessionHeader(session: session, controls: true)
                                            if model.isFolded(session.id) {
                                                FoldedSessionRow(session: session)
                                                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                                            } else {
                                                ForEach(model.tabs(in: session.id), id: \.id) { tab in
                                                    SidebarRow(tab: tab, selected: session.id == model.currentSession && tab.id == model.activeTab)
                                                        .transition(.opacity.combined(with: .offset(y: -6)))
                                                }
                                            }
                                            if session.id == model.currentSession, model.paneDrag?.drop == .newTab {
                                                NewTabDropPill(theme: model.theme)
                                                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
                                            }
                                        }
                                        .onHover { model.hoverSession(session.id, inside: $0) }
                                        .onAppear { model.sessionWentIdle(session.id) }
                                        .animation(.den, value: model.isFolded(session.id))
                                    }
                                }
                            }
                        }
                        .transition(.blurReplace)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .animation(.den, value: model.orderedSessions.map(\.id))
                .animation(.den, value: model.collapsedHosts)
                .animation(.den, value: model.activityMode)
                .animation(.denFast, value: model.paneDrag?.drop == .newTab)
            }
            .scrollIndicators(.never)
            .paneDropTabStrip(model: model)

            HStack {
                IconButton(symbol: "line.3.horizontal.circle", size: 14) { model.palette = .root }
                    .denTooltip("Command Palette", command: .commandPalette)
                Spacer()
                IconButton(symbol: "rectangle.stack.badge.plus", size: 13) { model.createSession(name: "") }
                    .denTooltip("New Session", command: .newSession)
                IconButton(symbol: "globe", size: 13.5) { model.palette = .addHost }
                    .denTooltip("Add Remote Host", command: .addRemoteHost)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
        }
        .frame(width: Self.width)
    }
}

/// A machine over its sessions: This Mac or a remote host with its state.
/// Tap to fold it away (remembered across launches); a host that isn't
/// connected offers to try again, or to log in.
private struct SidebarHostHeader: View {
    let host: HostID
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let collapsed = model.isCollapsed(host)
        HStack(spacing: 9) {
            icon(theme)
                .font(.system(size: 13.5))
                .frame(width: 16)
            Text(model.hostLabel(host))
                .uiFont(size: 13.5, weight: .semibold)
                .foregroundStyle(theme.chromeText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if case .remote(let id) = host, let state = model.remoteStates[id], !state.isConnected {
                if hovering, let action = recovery(id, state) {
                    IconButton(symbol: action.symbol, size: 11) { action.run() }
                        .denTooltip(action.label)
                } else {
                    Text(HostStatus.short(state))
                        .uiFont(size: 11)
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
                .rotationEffect(.degrees(collapsed ? -90 : 0))
                .opacity(hovering || collapsed ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .padding(.top, host == .local ? 0 : 16)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.den) { model.toggleCollapsed(host) } }
        .onHover { hovering = $0 }
        .help(helpText)
        .contextMenu {
            if case .remote(let id) = host {
                if model.remoteStates[id]?.isConnected == true {
                    Button("New Session Here") { model.createSession(name: "", on: host) }
                    Button("Disconnect") { model.disconnectHost(id) }
                } else {
                    Button("Try Again") { model.connectRemote(id, reveal: true) }
                }
                Button("Rename Host…") { model.palette = .renameHost(id) }
                Button("Remove Host", role: .destructive) { model.removeRemoteHost(id) }
            } else {
                Button("New Session") { model.createSession(name: "", on: .local) }
            }
        }
    }

    @ViewBuilder
    private func icon(_ theme: Theme) -> some View {
        switch host {
        case .local:
            Image(systemName: "laptopcomputer").foregroundStyle(theme.chromeText)
        case .remote(let id):
            switch model.remoteStates[id] {
            case .connected?:
                Image(systemName: "server.rack").foregroundStyle(theme.chromeText)
            case .connecting?, .downloading?, .uploading?:
                ProgressView().controlSize(.mini)
            case .failed?, .reconnecting?, .needsLogin?, .needsRestart?:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            case .disconnected?, nil:
                Image(systemName: "server.rack").foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private func recovery(_ id: RemoteHost.ID, _ state: RemoteState) -> (symbol: String, label: String, run: () -> Void)? {
        switch state {
        case .needsLogin: ("key", "Log In…", { model.requestLogin(id) })
        case .failed, .reconnecting, .disconnected, .needsRestart: ("arrow.clockwise", "Try Again", { model.connectRemote(id, reveal: true) })
        case .connecting, .downloading, .uploading, .connected: nil
        }
    }

    private var helpText: String {
        guard case .remote(let id) = host, let state = model.remoteStates[id] else { return "" }
        return HostStatus.detail(state)
    }
}

/// A session's name over its tabs; tap to switch to it.
private struct SessionHeader: View {
    let session: SessionSummary
    /// Hovering shows a new-tab button and the fold chevron, as in Rex.
    var controls = false
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let folded = model.isFolded(session.id)
        HStack(spacing: 0) {
            Text(session.name)
                .uiFont(size: 12, weight: .medium)
                .foregroundStyle(theme.tertiaryText)
                .overlay(alignment: .trailing) {
                    if session.id != model.currentSession, model.sessionWantsAttention(session.id) {
                        Circle().fill(theme.accent).frame(width: 6, height: 6).offset(x: 10)
                    }
                }
            Spacer(minLength: 4)
            if controls, hovering {
                HStack(spacing: 0) {
                    IconButton(symbol: "plus.circle", size: 12, frame: CGSize(width: 22, height: 20)) {
                        withAnimation(.den) { model.unfoldForNow(session.id) }
                        model.newTab(in: session.id)
                    }
                    .help("New Tab in \(session.name)")
                    IconButton(symbol: "chevron.down", size: 10.5, frame: CGSize(width: 22, height: 20)) {
                        withAnimation(.den) { model.toggleFolded(session.id) }
                    }
                    .rotationEffect(.degrees(folded ? -90 : 0))
                    .help(folded ? "Unfold" : "Fold to One Line")
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        // Equal room above and below: the name sits midway between the
        // previous session's last tab and its own first one.
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { model.switchSession(session.id) }
        .onHover { inside in withAnimation(.denFast) { hovering = inside } }
        .animation(.den, value: folded)
    }
}

/// A folded session: one line with its tabs' icons fanned in a stack and
/// what's on screen. Clicking opens it for a look; it folds back on its own.
private struct FoldedSessionRow: View {
    let session: SessionSummary
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let tabs = model.tabs(in: session.id)
        let current = session.id == model.currentSession
        let lead = tabs.first { current && $0.id == model.activeTab } ?? tabs.first
        // The same deck a tab draws for its panes: the lead tab's program in
        // front, the other tabs' as cards fanned up behind it.
        let others = tabs.filter { $0.id != lead?.id }
        let deck = (lead.map { [$0] } ?? []).compactMap { model.deck(for: $0).first }
            + others.compactMap { model.deck(for: $0).first }
        HStack(spacing: 9) {
            DeckIcon(deck: deck, height: 14, badge: tabs.contains(where: model.hasActivity), fan: .up)
            Text(lead.map(model.tabTitle) ?? session.name)
                .uiFont(size: 13, weight: .medium)
                .foregroundStyle(current ? theme.chromeText : theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 2)
            if tabs.count > 1 {
                Text("\(tabs.count)")
                    .uiFont(size: 11, weight: .semibold)
                    .foregroundStyle(theme.tertiaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if current { Elevated(shape: shape, theme: theme) } else { shape.fill(hovering ? theme.hover : .clear) }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.den) { model.unfoldForNow(session.id) } }
        .onHover { hovering = $0 }
        .help("\(tabs.count) tabs, folded")
    }
}

/// Activity Mode's list. Re-reads every second so ages tick on. The tab on
/// screen always stays listed, so the sidebar never goes blank under you.
private struct ActivityList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // TimelineView centers loose content; keep rows in a leading stack.
            VStack(alignment: .leading, spacing: 3) {
            let now = context.date
            let agents = model.orderedSessions.compactMap { session -> (SessionSummary, [(TabLayout, TabActivity)])? in
                let rows = model.tabs(in: session.id).compactMap { tab in model.activity(of: tab, now: now).map { (tab, $0) } }
                return rows.isEmpty ? nil : (session, rows)
            }
            // Like Rex, other tabs drop out, the one on screen included;
            // only with no agent anywhere does it stay, so the list isn't bare.
            let groups = agents.isEmpty ? currentTabOnly(now: now) : agents
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

    private func currentTabOnly(now: Date) -> [(SessionSummary, [(TabLayout, TabActivity)])] {
        guard let session = model.currentSummary, let tab = model.activeLayout else { return [] }
        return [(session, [(tab, TabActivity(state: .idle, detail: "No agent running", since: now))])]
    }
}

/// Shows or leaves Activity Mode; with horizontal tabs, opens the activity
/// dropdown instead. On, it sits in a filled circle like a pressed toggle;
/// off, it wears a dot while any agent is open or a tab off screen has
/// something for you.
struct ActivityModeToggle: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let dropdown = model.tabStyle == .horizontal
        let on = dropdown ? model.showActivityMenu : model.activityMode
        Button {
            if dropdown {
                withAnimation(.denFast) { model.showActivityMenu.toggle() }
            } else {
                withAnimation(.den) { model.toggleActivityMode() }
            }
        } label: {
            Image(systemName: "eye")
                .font(.system(size: 14, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? theme.chromeText : theme.secondaryText)
                .frame(width: 28, height: 28)
                .background {
                    if on { Elevated(shape: Circle(), theme: theme) } else { Circle().fill(hovering ? theme.hover : .clear) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.hitArea)
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if !on, model.anyTabWantsAttention || model.anyTabHasActivity {
                Circle()
                    .fill(Color(.sRGB, red: 0.25, green: 0.55, blue: 1, opacity: 1))
                    .frame(width: 6, height: 6)
                    .offset(x: -4, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .denTooltip(dropdown ? "Activity" : (on ? "Leave Activity Mode" : "Activity Mode"), command: .toggleActivityMode)
    }
}

/// Horizontal tabs' Activity Mode: a dropdown under the eye button listing
/// tabs running agents or reporting status, grouped by session.
struct ActivityMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let theme = model.theme
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let groups = model.orderedSessions.compactMap { session -> (SessionSummary, [(TabLayout, TabActivity)])? in
                let rows = model.tabs(in: session.id).compactMap { tab in model.activity(of: tab, now: now).map { (tab, $0) } }
                return rows.isEmpty ? nil : (session, rows)
            }
            VStack(alignment: .leading, spacing: 2) {
                if groups.isEmpty {
                    Text("No processes are reporting activity")
                        .uiFont(size: 13)
                        .foregroundStyle(theme.tertiaryText)
                        .frame(maxWidth: .infinity, minHeight: 96)
                }
                ForEach(groups, id: \.0.id) { session, rows in
                    Text(session.name)
                        .uiFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    ForEach(rows, id: \.0.id) { tab, activity in
                        ActivityRow(tab: tab, activity: activity, now: now,
                                    selected: session.id == model.currentSession && tab.id == model.activeTab,
                                    style: .menu)
                    }
                }
            }
            .frame(width: 300, alignment: .leading)
        }
        .padding(6)
        .background(MenuSurface(theme: theme))
    }
}

/// Folds the sidebar away and back. Sits in the same spot either way.
struct SidebarToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IconButton(symbol: model.sidebarSide == .left ? "sidebar.left" : "sidebar.right", size: 14) { withAnimation(.den) { model.toggleSidebar() } }
            .denTooltip(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar", command: .toggleSidebar)
    }
}

/// What stays of a collapsed sidebar: room for the traffic lights, the
/// toggle to bring it back, and a strip to drag the window by. With the
/// sidebar on the right it tops the panes, without the toggle (the
/// sidebar has its own).
struct CollapsedSidebarBar: View {
    var showsToggle = true
    @Environment(AppModel.self) private var model

    var body: some View {
        // The toggle sits on the side the sidebar comes back on.
        let right = model.sidebarSide == .right
        HStack(spacing: 2) {
            Color.clear.frame(width: TitleBar.leadingInset - 4)
            if showsToggle, !right { SidebarToggle() }
            Spacer()
            if showsToggle, right { SidebarToggle().padding(.trailing, 8) }
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
            DeckIcon(deck: model.deck(for: tab), height: 14, badge: !selected && model.hasActivity(tab), fan: .up)
            SidebarTitle(title: model.tabTitle(tab), theme: theme)
            Spacer(minLength: 2)
            if hovering {
                Button { model.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(theme.tertiaryText)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.hitArea)
            } else if let status {
                StatusGlyph(indicator: status.indicator)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if selected { Elevated(shape: shape, theme: theme) } else { shape.fill(hovering ? theme.hover : .clear) }
        }
        .contentShape(Rectangle())
        // Before tabCard: its tap (which hides the card) sits on this view,
        // and a tap attached outside it would never fire.
        .onTapGesture { withAnimation(.denFast) { model.selectTab(tab.id) } }
        .paneDropHighlight(model.paneDrag?.drop == .tab(tab.id), theme: theme, radius: 16)
        .paneDropTab(tab.id, model: model)
        .tabCard(tab, edge: model.sidebarSide.edge == .leading ? .trailing : .leading, enabled: model.paneDrag == nil)
        .onHover { hovering = $0 }
    }
}

/// A tab in Activity Mode, like Rex's: title over what it's doing; on the
/// right, dots while it works or a pill when it needs you, and its age.
struct ActivityRow: View {
    /// The sidebar marks the tab on screen; the dropdown highlights the
    /// hovered row in the accent, like a menu.
    enum Style { case sidebar, menu }

    let tab: TabLayout
    let activity: TabActivity
    let now: Date
    let selected: Bool
    var style = Style.sidebar
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let theme = model.theme
        let lit = style == .menu && hovering
        let dim = lit ? theme.onAccent.opacity(0.75) : theme.tertiaryText
        HStack(spacing: 9) {
            DeckIcon(deck: model.deck(for: tab), height: style == .menu ? 17 : 14,
                     badge: !selected && (model.hasActivity(tab) || model.status(of: tab)?.wantsAttention == true), fan: .up)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.tabTitle(tab))
                        .uiFont(size: 13)
                        .foregroundStyle(lit ? theme.onAccent : (selected ? theme.chromeText : theme.chromeText.opacity(0.88)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    trailingMark(theme)
                        .foregroundStyle(lit ? AnyShapeStyle(theme.onAccent) : AnyShapeStyle(.primary))
                }
                HStack(spacing: 6) {
                    Text(activity.detail)
                        .uiFont(size: 11.5)
                        .foregroundStyle(dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(TabActivity.age(since: activity.since, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(dim)
                }
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(height: 46)
        .background(background(theme))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.denFast) {
                model.selectTab(tab.id)
                if style == .menu { model.showActivityMenu = false }
            }
        }
        .tabCard(tab, edge: model.sidebarSide.edge == .leading ? .trailing : .leading, enabled: style == .sidebar)
        .onHover { hovering = $0 }
        .contextMenu { Button("Close Tab") { model.closeTab(tab.id) } }
    }

    @ViewBuilder private func background(_ theme: Theme) -> some View {
        let shape = RoundedRectangle(cornerRadius: style == .menu ? 8 : 12, style: .continuous)
        switch style {
        case .sidebar:
            if selected {
                Elevated(shape: shape, theme: theme)
            } else {
                shape.fill(hovering ? theme.hover : .clear)
            }
        case .menu:
            shape.fill(hovering ? theme.accent : .clear)
        }
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
            .uiFont(size: 11, weight: .semibold)
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
    var weight = Font.Weight.regular

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
        .uiFont(size: 13, weight: weight)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}
