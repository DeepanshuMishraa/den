import Foundation
import DenProtocol
import DenVT

/// Imports themes written in Ghostty's config format, which is also what
/// Omarchy theme folders ship as `ghostty.conf`.
enum ThemeImport {
    struct ImportError: Error, CustomStringConvertible {
        let description: String
    }

    static var directory: URL {
        DenPaths.themes
    }

    /// Accepts a Ghostty theme file or an Omarchy theme folder.
    static func load(from url: URL) throws(ImportError) -> Theme {
        var file = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let candidates = ["ghostty.conf", "ghostty", "ghostty.theme"]
            guard let found = candidates.map({ url.appending(path: $0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ImportError(description: "\(url.lastPathComponent) has no ghostty.conf. Pick a Ghostty theme file or an Omarchy theme folder that includes one.")
            }
            file = found
        }
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw ImportError(description: "Could not read \(file.path): \(error.localizedDescription)")
        }
        let name = (isDir.boolValue ? url.lastPathComponent : file.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        return try parse(text, name: name)
    }

    static func parse(_ text: String, name: String) throws(ImportError) -> Theme {
        var palette = [Int: RGB]()
        var bg: RGB?, fg: RGB?, cursor: RGB?, selection: RGB?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": bg = RGB(hexString: value)
            case "foreground": fg = RGB(hexString: value)
            case "cursor-color": cursor = RGB(hexString: value)
            case "selection-background": selection = RGB(hexString: value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let i = Int(parts[0]), (0 ..< 16).contains(i), let c = RGB(hexString: parts[1]) {
                    palette[i] = c
                }
            default: continue
            }
        }
        guard let bg, let fg else {
            throw ImportError(description: "The theme needs both `background` and `foreground` set. Nothing was imported.")
        }
        let base = Theme.generate(ThemeSpec(name: name, appearance: bg.luminance < 0.3 ? .dark : .light, background: 0, foreground: 0, accentHue: 250))
        let ansi = (0 ..< 16).map { palette[$0] ?? base.ansi[$0] }
        let accent = ansi[4]
        var theme = Theme(
            name: name,
            appearance: bg.luminance < 0.3 ? .dark : .light,
            background: bg,
            foreground: fg,
            cursor: cursor ?? accent,
            selection: selection ?? bg.mixed(with: accent, 0.3),
            ansi: ansi,
            accentRGB: accent
        )
        theme.isCustom = true
        return theme
    }

    /// Copies an imported theme into Den's themes folder so it survives restarts.
    static func install(_ url: URL) throws(ImportError) -> Theme {
        let theme = try load(from: url)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try serialize(theme).write(to: directory.appending(path: "\(theme.name).conf"), atomically: true, encoding: .utf8)
        } catch {
            throw ImportError(description: "Imported \(theme.name) but could not save it to \(directory.path): \(error.localizedDescription). It will be gone after restart.")
        }
        return theme
    }

    static func installed() -> [Theme] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "conf" }.compactMap { try? load(from: $0) }
            .sorted { $0.name < $1.name }
    }

    static func remove(_ theme: Theme) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(theme.name).conf"))
    }

    private static func serialize(_ t: Theme) -> String {
        func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
        var lines = ["background = \(hex(t.background))", "foreground = \(hex(t.foreground))",
                     "cursor-color = \(hex(t.cursor))", "selection-background = \(hex(t.selection))"]
        for (i, c) in t.ansi.enumerated() { lines.append("palette = \(i)=\(hex(c))") }
        return lines.joined(separator: "\n") + "\n"
    }
}
