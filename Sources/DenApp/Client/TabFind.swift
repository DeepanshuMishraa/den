import DenProtocol
import DenVT

/// ⌘F: text found in every pane of one tab, scrollback included, in pane
/// order and top to bottom within each pane.
struct TabFind: Equatable {
    struct Hit: Equatable {
        let pane: PaneID
        let match: TextMatch
    }

    let tab: TabID
    var query = ""
    var hits: [Hit] = []
    /// The hit the bar is on; nil when nothing matches.
    var current: Int?
    /// Each searched pane's replica generation, to notice output since.
    var searched: [PaneID: Int] = [:]

    /// "3 of 12", or nil before anything was typed.
    var counter: String? {
        guard !query.isEmpty else { return nil }
        guard let current else { return "No results" }
        return "\(current + 1) of \(hits.count)"
    }
}

extension AppModel {
    /// Opens the find bar on the active tab, or moves the keyboard back
    /// into it when it's already open.
    func openFind() {
        guard let tab = activeTab else { return }
        if find?.tab != tab {
            closeFind()
            find = TabFind(tab: tab)
        }
        findFocusRequest &+= 1
    }

    func closeFind() {
        guard let find else { return }
        for pane in find.searched.keys {
            guard let replica = replica(pane) else { continue }
            replica.terminal.searchHighlights = nil
            replica.touch()
        }
        self.find = nil
    }

    /// Searches again for `query`, starting on the newest hit in the
    /// focused pane, where the eye usually is.
    func setFindQuery(_ query: String) {
        guard var find, find.query != query else { return }
        find.query = query
        search(&find)
        let inFocused = find.hits.lastIndex { $0.pane == focused }
        find.current = inFocused ?? (find.hits.isEmpty ? nil : find.hits.count - 1)
        showFind(find)
    }

    /// Moves to the next hit (`1`, newer) or the previous one (`-1`,
    /// older), wrapping. Output since the last search is searched first.
    func stepFind(_ delta: Int) {
        guard var find, !find.query.isEmpty else { return }
        let stale = find.searched.contains { replica($0.key)?.generation != $0.value }
        if stale {
            let previous = find.current.map { find.hits[$0] }
            search(&find)
            // Stay on the same text if it's still there.
            find.current = previous.flatMap { p in find.hits.firstIndex(of: p) } ?? find.current.map { min($0, find.hits.count - 1) }
            if find.hits.isEmpty { find.current = nil }
        }
        guard !find.hits.isEmpty else { return showFind(find) }
        let count = find.hits.count
        find.current = find.current.map { ($0 + delta % count + count) % count } ?? (delta > 0 ? 0 : count - 1)
        showFind(find)
    }

    private func search(_ find: inout TabFind) {
        let panes = tabs.first { $0.id == find.tab }?.root.panes ?? []
        let query = find.query
        find.hits = panes.flatMap { pane in
            (replica(pane)?.terminal.search(query) ?? []).map { TabFind.Hit(pane: pane, match: $0) }
        }
        // Panes searched before but gone from the tab keep no highlights.
        for gone in find.searched.keys where !panes.contains(gone) {
            replica(gone)?.terminal.searchHighlights = nil
        }
        find.searched = [:]
        for pane in panes { find.searched[pane] = 0 }
    }

    /// Draws every pane's hits and scrolls the current one into view.
    private func showFind(_ found: TabFind) {
        var find = found
        for pane in find.searched.keys {
            guard let replica = replica(pane) else { continue }
            let indices = find.hits.indices.filter { find.hits[$0].pane == pane }
            replica.terminal.searchHighlights = find.query.isEmpty ? nil : SearchHighlights(
                matches: indices.map { find.hits[$0].match },
                current: find.current.flatMap { indices.firstIndex(of: $0) }
            )
            if let current = find.current, find.hits[current].pane == pane {
                replica.terminal.reveal(find.hits[current].match)
            }
            replica.touch()
            find.searched[pane] = replica.generation
        }
        self.find = find
    }
}
