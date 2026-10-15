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
///         "selectionForeground": "#c9d7e3", // optional; selected text keeps its colors
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
            accentRGB: accent,
            selectionForeground: try color("selectionForeground")
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
        var dict: [String: Any] = [
            "background": hex(theme.background),
            "foreground": hex(theme.foreground),
            "cursor": hex(theme.cursor),
            "selection": hex(theme.selection),
            "accent": hex(theme.accentRGB),
            "ansi": theme.ansi.map(hex),
        ]
        if let selected = theme.selectionForeground { dict["selectionForeground"] = hex(selected) }
        return dict
    }

    static func serialize(_ theme: Theme) -> String {
        let doc: [String: Any] = ["name": theme.name, theme.appearance.rawValue: variantDict(theme)]
        let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}\n").appending("\n")
    }

    /// Writes every built-in theme as an example JSON file (dark/light pairs
    /// share one file), without touching files the user has edited — user
    /// edits win. Lives in `examples/` so the examples don't duplicate the
    /// picker.
    ///
    /// A manifest (`.den-manifest.json`) records the hash of each file as
    /// generated, so the next app update can refresh examples whose
    /// built-ins changed while still leaving user edits alone: a file that
    /// is missing is written, a file that still matches its manifest entry
    /// is refreshed to the latest content, and anything else is treated as
    /// user-modified and preserved. Orphaned examples (a theme renamed or
    /// removed) are deleted only when unmodified.
    static func exportExamples(to directory: URL) {
        sync(exampleDocuments(), to: directory)
    }

    /// The generated example files: filename plus JSON content.
    static func exampleDocuments() -> [(file: String, data: Data)] {
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
        var docs: [(file: String, data: Data)] = []
        for pair in pairs.sorted(by: { $0.base < $1.base }) {
            var doc: [String: Any] = ["name": pair.base]
            for variant in [pair.dark, pair.light].compactMap({ $0 }) {
                doc[variant.appearance.rawValue] = variantDict(variant)
            }
            if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
                docs.append((file: "\(pair.base).json", data: data))
            }
        }
        return docs
    }

    /// Writes `docs` into `directory` per the manifest rules above. Factored
    /// out from `exportExamples` so updates are testable with fixed content.
    static func sync(_ docs: [(file: String, data: Data)], to directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = manifestIn(directory)
        let generated = Dictionary(uniqueKeysWithValues: docs.map { ($0.file, $0.data) })
        for (file, data) in docs {
            let url = directory.appending(path: file)
            let wanted = hash(data)
            guard let current = try? Data(contentsOf: url) else {
                try? data.write(to: url)
                manifest[file] = wanted
                continue
            }
            // Unmodified (matches the manifest, or already current): refresh.
            // Anything else is a user edit and stays untouched.
            if manifest[file] == nil, hash(current) == wanted {
                manifest[file] = wanted
            } else if manifest[file] == hash(current), hash(current) != wanted {
                try? data.write(to: url)
                manifest[file] = wanted
            }
        }
        // Drop orphaned examples only when unmodified; user edits stay as
        // the user's own files (and leave the manifest).
        let orphans = manifest.filter { generated[$0.key] == nil }
        for (file, recorded) in orphans {
            let url = directory.appending(path: file)
            if let current = try? Data(contentsOf: url), hash(current) == recorded {
                try? fm.removeItem(at: url)
                manifest.removeValue(forKey: file)
            } else if (try? Data(contentsOf: url)) == nil {
                manifest.removeValue(forKey: file)
            }
        }
        writeManifest(manifest, to: directory)
    }

    private static let manifestFile = ".den-manifest.json"

    private static func manifestIn(_ directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appending(path: manifestFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    private static func writeManifest(_ manifest: [String: String], to directory: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) {
            try? data.write(to: directory.appending(path: manifestFile))
        }
    }

    /// FNV-1a 64-bit, hex. A stable content fingerprint without imports.
    static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        return String(format: "%016llx", h)
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
