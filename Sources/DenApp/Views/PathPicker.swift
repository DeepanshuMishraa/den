import DenProtocol
import SwiftUI

/// Inserts a path to anything, anywhere, at the cursor of whatever runs in
/// the pane: a shell, an editor, an agent. The field starts where the picker
/// last closed (else the pane's folder) for ordinary path navigation; Tab
/// steps into the selected folder, typing narrows it, and fsearch
/// finds matches below the folder (or across the disk, for a bare word).
/// The selected path previews at the cursor in ghost text.
struct PathPickerOverlay: View {
    let request: AppModel.PathPickerRequest
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var entries: [PathEntry] = []
    @State private var selection = 0
    @State private var note: String?
    @State private var cell = CGSize(width: 8, height: 17)
    @FocusState private var focused: Bool

    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 24
    static let maxRows = 10

    private var host: HostID { model.host(ofPane: request.pane) }
    /// The pane's host user's home; nil for a remote host not asked yet.
    private var home: String? { model.hostHomes[host] }
    /// For parsing and abbreviating; an unknown remote home never matches.
    private var homeOrRoot: String { home ?? "/" }

    var body: some View {
        GeometryReader { geo in
            let origin = CGPoint(x: TerminalView.padding.width + CGFloat(request.col) * cell.width,
                                 y: TerminalView.padding.height + CGFloat(request.row) * cell.height)
            // Below the cursor unless it sits in the lower half; then above,
            // with the field nearest the cursor.
            let above = request.row > request.rows / 2
            let x = min(max(origin.x - 8, 6), max(geo.size.width - Self.width - 6, 6))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .onTapGesture { model.pathPicker = nil }
                ghost
                    .offset(x: origin.x, y: origin.y)
                if above {
                    panel(above: true)
                        .frame(width: Self.width)
                        .frame(height: max(origin.y - 4, 0), alignment: .bottom)
                        .offset(x: x)
                } else {
                    panel(above: false)
                        .frame(width: Self.width)
                        .frame(maxHeight: max(geo.size.height - origin.y - cell.height - 10, 60), alignment: .top)
                        .offset(x: x, y: origin.y + cell.height + 4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .onAppear(perform: enter)
        .onDisappear {
            if let dir = PathQuery.parse(text, home: homeOrRoot).directory { model.rememberPathPickerFolder(dir, on: host) }
        }
        .task(id: text) { await refresh() }
        .onKeyPress(.escape) { model.pathPicker = nil; return .handled }
        .onKeyPress(.downArrow) { move(request.row > request.rows / 2 ? -1 : 1); return .handled }
        .onKeyPress(.upArrow) { move(request.row > request.rows / 2 ? 1 : -1); return .handled }
        .onKeyPress(.tab) { descend(); return .handled }
    }

    // MARK: Pieces

    /// The selected path, previewed where it will land.
    @ViewBuilder private var ghost: some View {
        if entries.indices.contains(selection) {
            Text(PathQuery.insertion(for: entries[selection].path, cwd: request.cwd, home: home))
                .font(.custom(model.uiFontFamily, size: model.uiFontSize))
                .foregroundStyle(model.theme.tertiaryText)
                .lineLimit(1)
                .fixedSize()
                .allowsHitTesting(false)
        }
    }

    private func panel(above: Bool) -> some View {
        let theme = model.theme
        let rows = Array(entries.prefix(60).enumerated())
        return VStack(spacing: 4) {
            if !above { field(theme) }
            if let note, entries.isEmpty {
                Text(note).uiFont(size: 12).foregroundStyle(theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 6)
            } else if !entries.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(above ? rows.reversed() : rows, id: \.element.id) { index, entry in
                                row(entry, highlighted: index == selection, theme: theme)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.insertPath(entry.path) }
                                    .onHover { if $0 { selection = index } }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .defaultScrollAnchor(above ? .bottom : .top)
                    .frame(maxHeight: Self.rowHeight * CGFloat(Self.maxRows) + CGFloat(Self.maxRows))
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
            if above { field(theme) }
        }
        .padding(5)
        .background(MenuSurface(theme: theme))
    }

    private func field(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.tertiaryText)
            TextField("Path or name", text: $text)
                .textFieldStyle(.plain)
                .uiFont(size: 12.5)
                .focused($focused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)))
    }

    private func row(_ entry: PathEntry, highlighted: Bool, theme: Theme) -> some View {
        let fg = highlighted ? theme.onAccent : theme.chromeText
        return HStack(spacing: 7) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(highlighted ? theme.onAccent : (entry.isDirectory ? Color.accentColor : theme.secondaryText))
                .frame(width: 14)
            Text(label(for: entry))
                .uiFont(size: 12.5)
                .foregroundStyle(fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if entry.isRecent {
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(highlighted ? theme.onAccent.opacity(0.8) : theme.tertiaryText)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlighted ? theme.accent : .clear))
    }

    /// Children by name; deeper hits and recents by their path from the
    /// listed folder (or `~`).
    private func label(for entry: PathEntry) -> String {
        let query = PathQuery.parse(text, home: homeOrRoot)
        if let dir = query.directory, (entry.path as NSString).deletingLastPathComponent == dir { return entry.name }
        if let dir = query.directory, entry.path.hasPrefix(dir + "/") { return String(entry.path.dropFirst(dir.count + 1)) }
        return home.map { PathQuery.abbreviate(entry.path, home: $0) } ?? entry.path
    }

    // MARK: Behavior

    private func enter() {
        let metrics = FontMetrics(family: model.fontFamily, pointSize: model.fontSize, scale: 2)
        cell = CGSize(width: metrics.cellWidth / 2, height: metrics.cellHeight / 2)
        let start = model.pathPickerFolder(on: host) ?? request.cwd ?? home ?? "/"
        text = (home.map { PathQuery.abbreviate(start, home: $0) } ?? start) + (start == "/" ? "" : "/")
        KeyboardFocus.takeFromTerminal { focused = true }
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selection = min(max(selection + delta, 0), min(entries.count, 60) - 1)
    }

    /// Into the selected folder, or the selected file's path into the field.
    private func descend() {
        guard entries.indices.contains(selection) else { return }
        let entry = entries[selection]
        text = (home.map { PathQuery.abbreviate(entry.path, home: $0) } ?? entry.path) + (entry.isDirectory ? "/" : "")
    }

    private func submit() {
        if entries.indices.contains(selection) {
            model.insertPath(entries[selection].path)
        } else {
            let typed = PathQuery.parse(text, home: homeOrRoot)
            let path = typed.directory.map { ($0 as NSString).appendingPathComponent(typed.fragment) } ?? typed.fragment
            // Remote paths can't be checked from here; dend lists them as you type.
            if host != .local || FileManager.default.fileExists(atPath: path) { model.insertPath(path) }
        }
    }

    private func refresh() async {
        let query = PathQuery.parse(text, home: homeOrRoot)
        selection = 0
        note = nil
        if host != .local { return await refreshRemote(query) }
        var shown: [PathEntry] = []
        if let dir = query.directory {
            if query.fragment.isEmpty {
                shown = model.recentPaths
                    .filter { $0.hasPrefix(dir + "/") && FileManager.default.fileExists(atPath: $0) }
                    .prefix(3)
                    .map { PathEntry(path: $0, isDirectory: false, isRecent: true) }
            }
            shown += PathEntry.listing(of: dir, matching: query.fragment).filter { e in !shown.contains { $0.path == e.path } }
        } else if query.fragment.isEmpty {
            shown = model.recentPaths.prefix(8).map { PathEntry(path: $0, isDirectory: false, isRecent: true) }
        }
        entries = shown
        // A typed folder lists just that folder, like a shell completing a
        // path; fsearch is for bare names.
        guard query.directory == nil, !query.fragment.isEmpty else {
            if entries.isEmpty, !query.fragment.isEmpty { note = "Nothing here matches “\(query.fragment)”." }
            return
        }

        // Deeper and whole-disk matches from fsearch, after a beat so fast
        // typing doesn't queue a search per keystroke.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        switch await PathSearch.shared.search(query.fragment, limit: 120) {
        case .success(let hits):
            guard !Task.isCancelled else { return }
            let known = Set(entries.map(\.path))
            let ranked = PathEntry.ranked(hits.filter { !known.contains($0.path) }, matching: query.fragment,
                                          under: query.directory ?? NSHomeDirectory())
            entries += ranked
            if entries.isEmpty { note = "Nothing matches “\(query.fragment)”." }
        case .failure(.notInstalled):
            if entries.isEmpty {
                note = query.directory == nil
                    ? "Whole-disk search needs fsearch, which this build of Den doesn't include. Type a folder path to browse."
                    : "Nothing here matches “\(query.fragment)”."
            }
        case .failure(.indexing):
            if entries.isEmpty { note = "fsearch is still indexing the disk; folder browsing works meanwhile." }
        case .failure(.failed(let reason)):
            if entries.isEmpty { note = "Search failed: \(reason). Folder browsing still works." }
        }
    }
}

extension PathPickerOverlay {
    /// A remote pane: its dend lists the typed folder. fsearch indexes this
    /// Mac only, so bare names don't search the host's disk.
    fileprivate func refreshRemote(_ query: PathQuery) async {
        guard let dir = query.directory else {
            entries = []
            if !query.fragment.isEmpty { note = "On \(model.hostLabel(host)), type a folder path to browse; whole-disk search covers this Mac only." }
            return
        }
        guard let (path, listed) = await model.listDirectory(dir, on: host), !Task.isCancelled else {
            if !Task.isCancelled { note = "\(model.hostLabel(host)) isn't connected or its dend is too old to list folders." }
            return
        }
        entries = PathEntry.listing(of: path, entries: listed, matching: query.fragment)
        if entries.isEmpty { note = query.fragment.isEmpty ? "This folder is empty or can't be read." : "Nothing here matches “\(query.fragment)”." }
    }
}
