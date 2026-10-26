import Testing
import DenVT
@testable import DenApp

@Suite struct ThemeCatalogTests {
    @Test func everyThemeIsCompleteAndInItsList() {
        for theme in ThemeCatalog.dark { #expect(theme.isDark, "\(theme.name)") }
        for theme in ThemeCatalog.light { #expect(!theme.isDark, "\(theme.name)") }
        let all = ThemeCatalog.dark + ThemeCatalog.light
        for theme in all { #expect(theme.ansi.count == 16, "\(theme.name)") }
        #expect(Set(all.map(\.name)).count == all.count)
    }

    @Test func defaultsExist() {
        #expect(ThemeCatalog.named(ThemeCatalog.defaultDark)?.isDark == true)
        #expect(ThemeCatalog.named(ThemeCatalog.defaultLight)?.isDark == false)
    }

    /// Themes saved under a retired generated name still load as the Rex
    /// theme that replaced it.
    @Test func formerNamesResolveToRenamedThemes() {
        let names = Set((ThemeCatalog.dark + ThemeCatalog.light).map(\.name))
        #expect(ThemeCatalog.renamed.count == 41)
        for (old, new) in ThemeCatalog.renamed {
            #expect(!names.contains(old), "\(old) is still a theme name")
            #expect(ThemeCatalog.named(old)?.name == new, "\(old)")
        }
    }

    /// Spot checks against the projects' own Ghostty ports.
    @Test func officialTokens() throws {
        let mocha = try #require(ThemeCatalog.named("Catppuccin Mocha"))
        #expect(mocha.background == RGB(hex: 0x1E1E2E) && mocha.foreground == RGB(hex: 0xCDD6F4))
        #expect(mocha.selection == RGB(hex: 0x353749) && mocha.ansi[1] == RGB(hex: 0xF38BA8))

        let tokyo = try #require(ThemeCatalog.named("Tokyo Night"))
        #expect(tokyo.background == RGB(hex: 0x1A1B26) && tokyo.ansi[9] == RGB(hex: 0xFF899D))

        let dracula = try #require(ThemeCatalog.named("Dracula"))
        #expect(dracula.background == RGB(hex: 0x282A36) && dracula.accentRGB == RGB(hex: 0xBD93F9))

        let rex = try #require(ThemeCatalog.named("Abyssal Trench"))
        #expect(rex.background == RGB(hex: 0x06101A) && rex.foreground == RGB(hex: 0xB8CDD9))
        #expect(rex.cursor == RGB(hex: 0x4FE3C1) && rex.ansi[15] == RGB(hex: 0xDCEBF3))
        #expect(rex.accentRGB == RGB(hex: 0x4FE3C1))
    }
}
