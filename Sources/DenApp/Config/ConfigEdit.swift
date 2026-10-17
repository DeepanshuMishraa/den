import Foundation

/// Line edits to config.toml that keep everything else as written:
/// comments, ordering, blank lines and keys Den doesn't know. Settings made
/// in the app land here, so the file stays the one place they live.
enum ConfigEdit {
    /// Sets `key` (or removes it, for `nil`) at the top level or inside
    /// `[table]`. An active line is replaced in place; failing that, a
    /// commented-out `# key = …` line (as in the template) is uncommented;
    /// failing that, the key goes at the end of its section, and a missing
    /// table is appended.
    static func setting(_ key: String, to value: TOMLValue?, inTable table: String?, of text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let replacement = value.map { "\(key) = \($0.literal)" }
        guard let section = section(table, in: lines) else {
            guard let replacement, let table else { return text }
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines += (lines.isEmpty ? [] : [""]) + ["[\(table)]", replacement]
            return lines.joined(separator: "\n") + "\n"
        }
        if let i = section.first(where: { assigned(in: lines[$0]) == key }) {
            if let replacement { lines[i] = replacement } else { lines.remove(at: i) }
        } else if let replacement {
            if let i = section.first(where: { commentedKey(in: lines[$0]) == key }) {
                lines[i] = replacement
            } else {
                // After the section's last non-blank line, before the gap
                // that separates it from the next table.
                let last = section.last(where: { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty })
                lines.insert(replacement, at: last.map { $0 + 1 } ?? section.lowerBound)
            }
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Line indices of a section's body: the top level runs up to the first
    /// header, a table from its header to the next one.
    private static func section(_ table: String?, in lines: [String]) -> Range<Int>? {
        let headers = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        guard let table else { return 0 ..< (headers.first ?? lines.count) }
        guard let start = headers.first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "[\(table)]" }) else { return nil }
        let end = headers.first { $0 > start } ?? lines.count
        return (start + 1) ..< end
    }

    /// The key a `key = value` line sets, or nil for comments and others.
    private static func assigned(in line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    /// The key a `# key = value` line would set: a commented-out setting.
    private static func commentedKey(in line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#") else { return nil }
        let body = t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let key = body[..<eq].trimmingCharacters(in: .whitespaces)
        // Prose comments with an "=" in them aren't settings.
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } && !key.isEmpty ? key : nil
    }
}

extension TOMLValue {
    /// The value as config.toml writes it.
    var literal: String {
        switch self {
        case .string(let s):
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .integer(let i): return "\(i)"
        case .float(let f): return "\(f)"
        case .bool(let b): return "\(b)"
        case .array(let items): return "[" + items.map(\.literal).joined(separator: ", ") + "]"
        case .table(let t): return "{ " + t.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value.literal)" }.joined(separator: ", ") + " }"
        }
    }
}
