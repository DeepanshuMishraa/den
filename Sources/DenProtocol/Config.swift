import Foundation

/// `~/Library/Application Support/Den/config`: simple `key = value` lines
/// shared by the app (which writes settings) and dend (which reads them when
/// spawning panes).
public enum DenConfig {
    public static var url: URL { DenPaths.supportDirectory.appending(path: "config") }

    public static func value(_ key: String) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<eq].trimmingCharacters(in: .whitespaces) == key {
                let v = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Sets or removes (`nil`) a key, keeping other lines and comments.
    public static func set(_ key: String, _ value: String?) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "="), !t.hasPrefix("#") else { return false }
            return t[..<eq].trimmingCharacters(in: .whitespaces) == key
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if let value { lines.append("\(key) = \(value)") }
        try FileManager.default.createDirectory(at: DenPaths.supportDirectory, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
