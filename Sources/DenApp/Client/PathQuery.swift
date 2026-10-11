import Foundation

/// What the path picker's field says: a folder to list (traditional path
/// navigation) and a fragment to match, or just a fragment to search the
/// whole disk for.
///
/// - `~/Apps/web/` lists that folder.
/// - `~/Apps/web/lic` matches "lic" in that folder and below it.
/// - `license` (no slash) searches everywhere.
struct PathQuery: Equatable {
    /// Absolute folder, nil for a whole-disk search.
    let directory: String?
    let fragment: String

    static func parse(_ text: String, home: String = NSHomeDirectory()) -> PathQuery {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("/") else { return PathQuery(directory: nil, fragment: trimmed) }
        let expanded = trimmed == "~" || trimmed.hasPrefix("~/") ? home + trimmed.dropFirst() : trimmed
        guard let slash = expanded.lastIndex(of: "/") else { return PathQuery(directory: nil, fragment: trimmed) }
        let dir = String(expanded[..<slash])
        return PathQuery(directory: dir.isEmpty ? "/" : dir, fragment: String(expanded[expanded.index(after: slash)...]))
    }

    /// The text a pane gets: relative to its working directory when inside
    /// it, `~/…` under home, else absolute; shell-quoted when needed.
    static func insertion(for path: String, cwd: String?, home: String = NSHomeDirectory()) -> String {
        var shown = path
        if let cwd, cwd != "/", path.hasPrefix(cwd + "/") {
            shown = String(path.dropFirst(cwd.count + 1))
        } else if path == home || path.hasPrefix(home + "/") {
            shown = "~" + path.dropFirst(home.count)
        }
        return quoted(shown)
    }

    /// Backslash-escapes characters a shell would split or expand on; a
    /// leading `~/` stays live.
    static func quoted(_ path: String) -> String {
        let special = Set(" \t'\"\\$`!&*?;|<>()[]{}#")
        var out = ""
        for (i, ch) in path.enumerated() {
            if special.contains(ch) || (ch == "~" && i > 0) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// `~`-abbreviated, for showing folders in the field.
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// One row in the picker.
struct PathEntry: Equatable, Identifiable {
    let path: String
    let isDirectory: Bool
    /// Inserted before; shown with a clock.
    var isRecent = false

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    /// Search hits as a picker shows them: only those whose own name
    /// matches (not ones found through a parent folder's name), best name
    /// match first, then the shallowest, so "Desk" offers Desktop before
    /// anything inside it.
    static func ranked(_ hits: [PathEntry], matching fragment: String, under base: String?) -> [PathEntry] {
        hits.compactMap { hit -> (PathEntry, Int, Int)? in
            guard let match = Fuzzy.rank(fragment, in: hit.name) else { return nil }
            let relative = base.map { hit.path.hasPrefix($0 + "/") ? String(hit.path.dropFirst($0.count + 1)) : hit.path } ?? hit.path
            return (hit, match.score, relative.split(separator: "/").count)
        }
        .sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.2 != b.2 ? a.2 < b.2 : a.0.path < b.0.path }
        .map(\.0)
    }

    /// A folder's children, hidden ones only when asked for, ranked by the
    /// fragment (alphabetical when empty, like Finder's name order).
    static func listing(of directory: String, matching fragment: String, limit: Int = 300) -> [PathEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        let visible = names.filter { !$0.hasPrefix(".") || fragment.hasPrefix(".") }
        let ordered = fragment.isEmpty
            ? visible.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            : Fuzzy.filter(visible.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, query: fragment, key: { $0 })
        return ordered.prefix(limit).map { name in
            let path = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            return PathEntry(path: path, isDirectory: isDir.boolValue)
        }
    }
}
