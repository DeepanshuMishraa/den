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
        // 27 dark + 14 light pair into shared files (Merino, Silver Point).
        #expect(files.count == 39)
        let merino = try Data(contentsOf: dir.appending(path: "examples/Merino.json"))
        let doc = try #require(JSONSerialization.jsonObject(with: merino) as? [String: Any])
        #expect(doc["dark"] is [String: Any] && doc["light"] is [String: Any])
        // Existing files (user edits) are left alone.
        let keep = dir.appending(path: "examples/Merino.json")
        try "edited".write(to: keep, atomically: true, encoding: .utf8)
        ThemeJSON.exportExamples(to: dir.appending(path: "examples"))
        #expect(try String(contentsOf: keep, encoding: .utf8) == "edited")
    }
}
