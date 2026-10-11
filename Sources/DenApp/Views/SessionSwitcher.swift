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
        case session(SessionSummary, shortcut: Int?)
        case create(String)
        case newSession
        case addHost
    }

    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = model.orderedSessions
        let matches = all.enumerated().filter { q.isEmpty || Fuzzy.match(q, in: $0.element.name) != nil }
        var rows = matches.map { Row.session($0.element, shortcut: $0.offset < 9 ? $0.offset + 1 : nil) }
        if !q.isEmpty, !all.contains(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
            rows.append(.create(q))
        }
        rows.append(.newSession)
        rows.append(.addHost)
        return rows
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

            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").font(.system(size: 10.5))
                Text("This Mac").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(theme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if row == .newSession {
                    Rectangle().fill(theme.separator).frame(height: 0.5).padding(.vertical, 4).padding(.horizontal, 6)
                }
                rowView(row, highlighted: index == selection)
                    .contentShape(Rectangle())
                    .onTapGesture { activate(index) }
                    .onHover { if $0 { selection = index } }
            }
        }
        .padding(6)
        .frame(width: 236)
        .background(MenuSurface(theme: theme))
        .onAppear {
            KeyboardFocus.takeFromTerminal { filterFocused = true }
            selection = rows.firstIndex { if case .session(let s, _) = $0 { s.id == model.currentSession } else { false } } ?? 0
        }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, rows.count - 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
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
            }
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlighted ? theme.accent : .clear))
    }

    private func activate(_ index: Int) {
        let rows = rows
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
        case .session(let s, _): model.switchSession(s.id)
        case .create(let name): model.createSession(name: name)
        case .newSession: model.createSession(name: "")
        case .addHost: model.palette = .addHost
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
