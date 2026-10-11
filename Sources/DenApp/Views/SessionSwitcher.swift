import DenProtocol
import SwiftUI

/// ⌘K: a menu-style dropdown under the session button. Filter, switch, or
/// create a session from the filter text.
struct SessionMenu: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var filterFocused: Bool

    private enum Row: Equatable {
        /// A host's name and connection state; not selectable.
        case header(HostID)
        case session(SessionSummary, shortcut: Int?)
        case logIn(RemoteHost.ID)
        case reconnect(RemoteHost.ID)
        case newSessionOn(RemoteHost.ID)
        case create(String)
        case newSession
        case addHost

        var isSelectable: Bool { if case .header = self { false } else { true } }
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = model.orderedSessions
        let numbered = Array(all.enumerated())
        func sessionRows(_ list: [(offset: Int, element: SessionSummary)]) -> [Row] {
            list.map { Row.session($0.element, shortcut: $0.offset < 9 ? $0.offset + 1 : nil) }
        }
        var rows: [Row]
        if q.isEmpty {
            // Grouped by host, each remote host with what it needs.
            rows = [.header(.local)] + sessionRows(numbered.filter { isLocal($0.element) })
            for host in model.remoteHosts {
                let id = HostID.remote(host.id)
                rows.append(.header(id))
                rows += sessionRows(numbered.filter { model.sessionHosts[$0.element.id] == id })
                switch model.remoteStates[host.id] {
                case .needsLogin: rows.append(.logIn(host.id))
                case .failed, .reconnecting: rows.append(.reconnect(host.id))
                case .connected: rows.append(.newSessionOn(host.id))
                case .connecting, nil: break
                }
            }
        } else {
            rows = sessionRows(Fuzzy.filter(numbered, query: q, key: \.element.name))
            if !all.contains(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) { rows.append(.create(q)) }
        }
        rows.append(.newSession)
        rows.append(.addHost)
        return rows
    }

    private func isLocal(_ session: SessionSummary) -> Bool {
        (model.sessionHosts[session.id] ?? .local) == .local
    }

    /// The nearest selectable row from `index`, moving by `step`.
    private func selectable(_ index: Int, step: Int, in rows: [Row]) -> Int {
        var i = index
        while rows.indices.contains(i) {
            if rows[i].isSelectable { return i }
            i += step
        }
        return selection
    }

    var body: some View {
        let theme = model.theme
        let rows = rows
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.tertiaryText)
                TextField("Filter or create…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($filterFocused)
                    .onSubmit { activate(selection) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.hover))
            .padding(.bottom, 4)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if row == .newSession {
                    Rectangle().fill(theme.separator).frame(height: 0.5).padding(.vertical, 4).padding(.horizontal, 6)
                }
                if case .header(let host) = row {
                    header(host, first: index == 0)
                } else {
                    rowView(row, highlighted: index == selection)
                        .contentShape(Rectangle())
                        .onTapGesture { activate(index) }
                        .onHover { if $0 { selection = index } }
                }
            }
        }
        .padding(6)
        .frame(width: 256)
        .background(MenuSurface(theme: theme))
        .onAppear {
            KeyboardFocus.takeFromTerminal { filterFocused = true }
            selection = rows.firstIndex { if case .session(let s, _) = $0 { s.id == model.currentSession } else { false } }
                ?? selectable(0, step: 1, in: rows)
        }
        .onChange(of: query) { selection = selectable(0, step: 1, in: self.rows) }
        .onKeyPress(.downArrow) { selection = selectable(min(selection + 1, rows.count - 1), step: 1, in: rows); return .handled }
        .onKeyPress(.upArrow) { selection = selectable(max(selection - 1, 0), step: -1, in: rows); return .handled }
        .onKeyPress(.escape) { model.showSessionMenu = false; return .handled }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard press.modifiers.contains(.command), let n = Int(press.characters), n >= 1,
                  model.orderedSessions.indices.contains(n - 1) else { return .ignored }
            model.switchSession(model.orderedSessions[n - 1].id)
            model.showSessionMenu = false
            return .handled
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row, highlighted: Bool) -> some View {
        let theme = model.theme
        let fg = highlighted ? theme.onAccent : theme.chromeText
        let dim = highlighted ? theme.onAccent.opacity(0.75) : theme.tertiaryText
        HStack(spacing: 7) {
            switch row {
            case .session(let s, let shortcut):
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(s.id == model.currentSession ? 1 : 0)
                    .frame(width: 12)
                Fuzzy.highlighted(s.name, hits: Fuzzy.match(query, in: s.name) ?? [], base: fg, accent: highlighted ? fg : theme.accent)
                    .font(.system(size: 13))
                if s.id != model.currentSession, model.sessionWantsAttention(s.id) {
                    // Something there finished or is waiting on you.
                    Circle().fill(highlighted ? fg : theme.accent).frame(width: 6, height: 6)
                }
                Spacer()
                if let shortcut { Text("⌘\(shortcut)").font(.system(size: 11.5)).foregroundStyle(dim) }
            case .create(let name):
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 12)
                Text("Create “\(name)”").font(.system(size: 13))
                Spacer()
            case .newSession:
                Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 11)).frame(width: 12)
                Text("New Session").font(.system(size: 13))
                Spacer()
                Text("⇧⌘N").font(.system(size: 11.5)).foregroundStyle(dim)
            case .addHost:
                Image(systemName: "network").font(.system(size: 11)).frame(width: 12)
                Text("Add Remote Host…").font(.system(size: 13))
                Spacer()
            case .logIn:
                Image(systemName: "key").font(.system(size: 10.5)).frame(width: 12)
                Text("Log In…").font(.system(size: 13))
                Spacer()
            case .reconnect:
                Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .semibold)).frame(width: 12)
                Text("Reconnect Now").font(.system(size: 13))
                Spacer()
            case .newSessionOn:
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 12)
                Text("New Session Here").font(.system(size: 13))
                Spacer()
            case .header:
                EmptyView()
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlighted ? theme.accent : .clear))
    }

    /// A host's name with a status dot; right-click a remote one to remove it.
    @ViewBuilder
    private func header(_ host: HostID, first: Bool) -> some View {
        let theme = model.theme
        HStack(spacing: 6) {
            switch host {
            case .local:
                Image(systemName: "laptopcomputer").font(.system(size: 10.5))
                Text("This Mac").font(.system(size: 11, weight: .medium))
            case .remote(let id):
                let state = model.remoteStates[id]
                Circle().fill(HostStatus.color(state, theme: theme)).frame(width: 6, height: 6)
                Text(model.hostLabel(host)).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if let state, !state.isConnected {
                    Text(HostStatus.short(state)).font(.system(size: 10.5))
                }
            }
        }
        .foregroundStyle(theme.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.top, first ? 3 : 8)
        .padding(.bottom, 3)
        .help(helpText(host))
        .contextMenu {
            if case .remote(let id) = host {
                Button("Reconnect") { model.connectRemote(id, reveal: false) }
                Button("Remove Host", role: .destructive) { model.removeRemoteHost(id) }
            }
        }
    }

    private func helpText(_ host: HostID) -> String {
        guard case .remote(let id) = host, let state = model.remoteStates[id] else { return "" }
        return HostStatus.detail(state)
    }

    private func activate(_ index: Int) {
        let rows = rows
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .header: return
        case .session(let s, _): model.switchSession(s.id)
        case .create(let name): model.createSession(name: name)
        case .newSession: model.createSession(name: "")
        case .addHost: model.palette = .addHost
        case .logIn(let id): model.requestLogin(id)
        case .reconnect(let id): model.connectRemote(id, reveal: true)
        case .newSessionOn(let id): model.createSession(name: "", on: .remote(id))
        }
        model.showSessionMenu = false
    }
}

/// Shared look for Den's floating menus: themed, translucent, hairline border.
struct MenuSurface: View {
    let theme: Theme

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(theme.menuFill))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(theme.menuBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.18), radius: 18, y: 8)
    }
}
