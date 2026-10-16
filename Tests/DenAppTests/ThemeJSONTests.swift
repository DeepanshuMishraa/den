import Foundation
import Testing
@testable import DenApp
@testable import DenVT

@Suite struct ThemeJSONTests {
    private func write(_ text: String, named name: String = "harbor.json") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "den-theme-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func dualVariantsParse() throws {
        let url = try write("""
            {"dark": {"background": "#0b1622", "foreground": "#c9d7e3"},
             "light": {"background": "#f4f1ea", "foreground": "#2c3a42"}}
            """)
        let themes = try ThemeJSON.load(from: url)
        #expect(themes.count == 2)
        let dark = try #require(themes.first { $0.appearance == .dark })
        let light = try #require(themes.first { $0.appearance == .light })
        #expect(dark.name == "Harbor" && light.name == "Harbor")
        #expect(dark.background == RGB(hexString: "#0b1622"))
        #expect(light.foreground == RGB(hexString: "#2c3a42"))
        #expect(dark.isCustom && light.isCustom)
        #expect(dark.ansi.count == 16)
    }

    @Test func explicitNameAndTokensWin() throws {
        let url = try write("""
            {"name": "Custom",
             "dark": {"background": "0b1622", "foreground": "#c9d7e3",
                      "cursor": "#ff0000", "selection": "#00ff00",
                      "accent": "#0000ff",
                      "ansi": ["#111111", "#222222", "#333333", "#444444",
                               "#555555", "#666666", "#777777", "#888888",
                               "#999999", "#aaaaaa", "#bbbbbb", "#cccccc",
                               "#dddddd", "#eeeeee", "#ffffff", "#000001"]}}
            """, named: "whatever.json")
        let theme = try #require(try ThemeJSON.load(from: url).first)
        #expect(theme.name == "Custom")
        #expect(theme.cursor == RGB(hexString: "#ff0000"))
        #expect(theme.selection == RGB(hexString: "#00ff00"))
        #expect(theme.accentRGB == RGB(hexString: "#0000ff"))
        #expect(theme.ansi[0] == RGB(hexString: "#111111"))
        #expect(theme.ansi[15] == RGB(hexString: "#000001"))
    }

    @Test func flatFileWithAppearance() throws {
        let url = try write("""
            {"appearance": "light", "background": "#f4f1ea", "foreground": "#2c3a42"}
            """, named: "day.json")
        let themes = try ThemeJSON.load(from: url)
        #expect(themes.count == 1)
        #expect(themes[0].appearance == .light)
        #expect(themes[0].name == "Day")
    }

    @Test func flatFileGuessesAppearance() throws {
        let url = try write("""
            {"background": "#101010", "foreground": "#e6e6e6"}
            """, named: "night.json")
        let themes = try ThemeJSON.load(from: url)
        #expect(themes[0].appearance == .dark)
    }

    @Test func missingBackgroundFails() throws {
        let url = try write("{\"dark\": {\"foreground\": \"#c9d7e3\"}}")
        #expect(throws: ThemeJSON.FileError.self) { try ThemeJSON.load(from: url) }
    }

    @Test func badHexFails() throws {
        let url = try write("{\"dark\": {\"background\": \"notacolor\", \"foreground\": \"#c9d7e3\"}}")
        #expect(throws: ThemeJSON.FileError.self) { try ThemeJSON.load(from: url) }
    }

    @Test func invalidJSONFails() throws {
        let url = try write("{oops")
        #expect(throws: ThemeJSON.FileError.self) { try ThemeJSON.load(from: url) }
    }

    @Test func serializeRoundTrips() throws {
        let url = try write("""
            {"name": "Harbor",
             "dark": {"background": "#0b1622", "foreground": "#c9d7e3", "accent": "#7aa2f7"}}
            """)
        let theme = try #require(try ThemeJSON.load(from: url).first)
        let back = try #require(try ThemeJSON.load(from: write(ThemeJSON.serialize(theme))).first)
        #expect(back.name == theme.name && back.appearance == theme.appearance)
        #expect(back.background == theme.background && back.foreground == theme.foreground)
        #expect(back.cursor == theme.cursor && back.selection == theme.selection)
        #expect(back.accentRGB == theme.accentRGB && back.ansi == theme.ansi)
    }

    @Test func exportWritesPairedExamplesWithoutOverwriting() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "den-theme-export-\(UUID().uuidString)")
        ThemeJSON.exportExamples(to: dir.appending(path: "examples"))
        let files = try FileManager.default.contentsOfDirectory(at: dir.appending(path: "examples"), includingPropertiesForKeys: nil)
        // 63 dark + 33 light, with 13 dark/light pairs sharing a file
        // (Gruvbox, One, Solarized, Cool Ranch, Quicksilver…). The hidden
        // manifest tracks what was generated; it isn't a theme.
        #expect(files.filter { !$0.lastPathComponent.hasPrefix(".") }.count == 83)
        let gruvbox = try Data(contentsOf: dir.appending(path: "examples/Gruvbox.json"))
        let doc = try #require(JSONSerialization.jsonObject(with: gruvbox) as? [String: Any])
        #expect(doc["dark"] is [String: Any] && doc["light"] is [String: Any])
        // Existing files (user edits) are left alone.
        let keep = dir.appending(path: "examples/Gruvbox.json")
        try "edited".write(to: keep, atomically: true, encoding: .utf8)
        ThemeJSON.exportExamples(to: dir.appending(path: "examples"))
        #expect(try String(contentsOf: keep, encoding: .utf8) == "edited")
    }

    @Test func syncRefreshesStaleExamplesButKeepsUserEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "den-theme-sync-\(UUID().uuidString)")
        let v1 = [(file: "A.json", data: Data("v1".utf8)), (file: "Gone.json", data: Data("gone".utf8))]
        ThemeJSON.sync(v1, to: dir)
        // User edits one file after the first sync.
        try Data("mine".utf8).write(to: dir.appending(path: "A.json"))
        // v2: A changes upstream, Gone is dropped, B is new.
        let v2 = [(file: "A.json", data: Data("v2".utf8)), (file: "B.json", data: Data("v2".utf8))]
        ThemeJSON.sync(v2, to: dir)
        // User edit wins over the upstream change.
        #expect(try String(contentsOf: dir.appending(path: "A.json"), encoding: .utf8) == "mine")
        // New files are added.
        #expect(try String(contentsOf: dir.appending(path: "B.json"), encoding: .utf8) == "v2")
        // Unmodified orphans go away with the theme.
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "Gone.json").path))
    }

    @Test func syncRefreshesUnmodifiedStaleFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "den-theme-sync-\(UUID().uuidString)")
        ThemeJSON.sync([(file: "A.json", data: Data("v1".utf8))], to: dir)
        ThemeJSON.sync([(file: "A.json", data: Data("v2".utf8))], to: dir)
        #expect(try String(contentsOf: dir.appending(path: "A.json"), encoding: .utf8) == "v2")
    }

    @Test func syncKeepsModifiedOrphans() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "den-theme-sync-\(UUID().uuidString)")
        ThemeJSON.sync([(file: "Gone.json", data: Data("gone".utf8))], to: dir)
        try Data("mine".utf8).write(to: dir.appending(path: "Gone.json"))
        ThemeJSON.sync([], to: dir)
        #expect(try String(contentsOf: dir.appending(path: "Gone.json"), encoding: .utf8) == "mine")
    }
}
