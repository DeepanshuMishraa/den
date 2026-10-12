import Foundation
import DenVT

/// Hand-written themes in `~/.config/den/themes/*.json` (honors
/// `$XDG_CONFIG_HOME`, like config.toml). One file holds the dark variant,
/// the light variant, or both:
///
///     {
///       "name": "Harbor",            // optional; the file name is the default
///       "dark": {
///         "background": "#0b1622",   // required
///         "foreground": "#c9d7e3",   // required
///         "cursor": "#7aa2f7",       // optional; defaults to accent
///         "selection": "#1e3a5f",    // optional; background tinted with accent
///         "accent": "#7aa2f7",       // optional; defaults to ANSI blue
///         "ansi": ["#000000", …]     // optional; 16 colors, gaps filled in
///       },
///       "light": { … }
///     }
///
/// A flat file (the variant keys at the top level, with an optional
/// `"appearance": "dark" | "light"`) defines a single theme. Colors are
/// `#rrggbb` or `rrggbb`. Saving a file applies on the next activation —
/// a watcher reloads sooner, so edits show up in the theme picker (with
/// live preview) as you save.
enum ThemeJSON {
    struct FileError: Error, CustomStringConvertible, Sendable {
        let file: String
        let message: String
        var description: String { "\(file): \(message)" }
    }

    /// Parses one file into one theme per variant present.
    static func load(from url: URL) throws(FileError) -> [Theme] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileError(file: url.lastPathComponent, message: "Could not read the file: \(error.localizedDescription).")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FileError(file: url.lastPathComponent, message: "Not valid JSON: \(error.localizedDescription).")
        }
        guard let dict = json as? [String: Any] else {
            throw FileError(file: url.lastPathComponent, message: "The top level must be an object with \"dark\" and/or \"light\" variants.")
        }
        let fallbackName = displayName(for: url)
        var name = fallbackName
        if let raw = dict["name"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { name = trimmed }
        }
        if dict["dark"] != nil || dict["light"] != nil {
            var themes: [Theme] = []
            for appearance in [Appearance.dark, Appearance.light] {
                guard let variant = dict[appearance.rawValue] else { continue }
                guard let v = variant as? [String: Any] else {
                    throw FileError(file: url.lastPathComponent, message: "“\(appearance.rawValue)” must be an object of color tokens.")
                }
                themes.append(try parseVariant(v, name: name, appearance: appearance, file: url.lastPathComponent, source: url))
            }
            guard !themes.isEmpty else {
                throw FileError(file: url.lastPathComponent, message: "Neither “dark” nor “light” holds a theme. See `den config help themes`.")
            }
            return themes
        }
        let appearance: Appearance
        if let raw = dict["appearance"] as? String {
            guard let a = Appearance(rawValue: raw.lowercased()) else {
                throw FileError(file: url.lastPathComponent, message: "“appearance” must be \"dark\" or \"light”, got “\(raw)”.")
            }
            appearance = a
        } else {
            appearance = .init(heuristicFor: dict, file: url.lastPathComponent)
        }
        return [try parseVariant(dict, name: name, appearance: appearance, file: url.lastPathComponent, source: url)]
    }

    /// Every top-level `*.json` theme in the folder, with per-file errors for
    /// the palette to surface instead of failing the whole load.
    static func installed(in directory: URL) -> (themes: [Theme], errors: [FileError]) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var themes: [Theme] = []
        var errors: [FileError] = []
        for file in files.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                themes += try load(from: file)
            } catch let error as FileError {
                errors.append(error)
            } catch {
                errors.append(FileError(file: file.lastPathComponent, message: error.localizedDescription))
            }
        }
        return (themes.sorted { $0.name < $1.name }, errors)
    }

    // MARK: Parsing

    private static func parseVariant(_ dict: [String: Any], name: String, appearance: Appearance, file: String, source: URL) throws(FileError) -> Theme {
        func color(_ key: String) throws(FileError) -> RGB? {
            guard let raw = dict[key] else { return nil }
            guard let s = raw as? String, let c = RGB(hexString: s) else {
                throw FileError(file: file, message: "“\(key)” must be a hex color like \"#c9d7e3”, got “\(raw)”.")
            }
            return c
        }
        func required(_ key: String) throws(FileError) -> RGB {
            guard let c = try color(key) else {
                throw FileError(file: file, message: "“\(key)” is required. See `den config help themes`.")
            }
            return c
        }
        let bg = try required("background")
        let fg = try required("foreground")
        let dark = appearance == .dark
        let base = Theme.generate(ThemeSpec(name: name, appearance: appearance, background: 0, foreground: 0, accentHue: 250))
        var ansi = base.ansi
        if let rawAnsi = dict["ansi"] {
            guard let list = rawAnsi as? [Any], !list.isEmpty, list.count <= 16 else {
                throw FileError(file: file, message: "“ansi” must be an array of up to 16 hex colors.")
            }
            for (i, raw) in list.enumerated() {
                guard let s = raw as? String, let c = RGB(hexString: s) else {
                    throw FileError(file: file, message: "“ansi” entry \(i) must be a hex color like \"#45475a”, got “\(raw)”.")
                }
                ansi[i] = c
            }
        }
        let accent = try color("accent") ?? ansi[4]
        var theme = Theme(
            name: name,
            appearance: appearance,
            background: bg,
            foreground: fg,
            cursor: (try color("cursor")) ?? accent,
            selection: (try color("selection")) ?? bg.mixed(with: accent, dark ? 0.32 : 0.22),
            ansi: ansi,
            accentRGB: accent
        )
        theme.isCustom = true
        theme.fileURL = source
        return theme
    }

    static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    // MARK: Serializing

    static func variantDict(_ theme: Theme) -> [String: Any] {
        func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
        return [
            "background": hex(theme.background),
            "foreground": hex(theme.foreground),
            "cursor": hex(theme.cursor),
            "selection": hex(theme.selection),
            "accent": hex(theme.accentRGB),
            "ansi": theme.ansi.map(hex),
        ]
    }

    static func serialize(_ theme: Theme) -> String {
        let doc: [String: Any] = ["name": theme.name, theme.appearance.rawValue: variantDict(theme)]
        let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}\n").appending("\n")
    }

    /// Writes every built-in theme as an example JSON file (dark/light pairs
    /// share one file), without touching files that already exist — user edits
    /// win. Lives in `examples/` so the examples don't duplicate the picker.
    static func exportExamples(to directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var pairs: [(base: String, dark: Theme?, light: Theme?)] = []
        func baseName(_ name: String) -> String {
            if name.hasSuffix(" Dark") { return String(name.dropLast(5)) }
            if name.hasSuffix(" Light") { return String(name.dropLast(6)) }
            return name
        }
        for theme in ThemeCatalog.dark + ThemeCatalog.light {
            let base = baseName(theme.name)
            if let i = pairs.firstIndex(where: { $0.base == base }) {
                if theme.appearance == .dark { pairs[i].dark = theme } else { pairs[i].light = theme }
            } else {
                pairs.append((base, theme.appearance == .dark ? theme : nil, theme.appearance == .light ? theme : nil))
            }
        }
        for pair in pairs.sorted(by: { $0.base < $1.base }) {
            let url = directory.appending(path: "\(pair.base).json")
            guard !fm.fileExists(atPath: url.path) else { continue }
            var doc: [String: Any] = ["name": pair.base]
            for variant in [pair.dark, pair.light].compactMap({ $0 }) {
                doc[variant.appearance.rawValue] = variantDict(variant)
            }
            if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
        }
    }
}

/// Watches the JSON themes folder and reloads on save, so hand-written
/// themes appear in the picker (and re-apply if selected) in real time.
final class ThemeWatcher: @unchecked Sendable {
    private let stream: FSEventStreamRef?
    private let box: ChangeBox

    init(directory: URL, onChange: @escaping @Sendable () -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let box = ChangeBox(onChange)
        self.box = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ChangeBox>.fromOpaque(info).takeUnretainedValue().fire()
        }
        let paths = [directory.path] as CFArray
        let created = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        )
        stream = created
        if let created {
            FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(created)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private final class ChangeBox: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
        func fire() { onChange() }
    }
}

private extension Appearance {
    /// Guesses dark/light from the background for flat files without an
    /// explicit appearance, like the Ghostty importer does.
    init(heuristicFor dict: [String: Any], file: String) {
        let bg = (dict["background"] as? String).flatMap(RGB.init(hexString:))
        self = (bg?.luminance ?? 1) < 0.3 ? .dark : .light
    }
}
