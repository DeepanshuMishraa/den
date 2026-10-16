import Testing
@testable import DenApp

@Suite struct ProgramCatalogTests {
    @Test func agyMapsToAntigravity() {
        #expect(ProgramKind.detect(process: "agy", title: nil).id == "antigravity")
    }

    @Test func antigravityNameStillMatches() {
        #expect(ProgramKind.detect(process: "antigravity", title: nil).id == "antigravity")
    }

    @Test func processMatchIsCaseInsensitive() {
        #expect(ProgramKind.detect(process: "AGY", title: nil).id == "antigravity")
    }

    @Test func antigravityKeepsBrandGlyph() {
        let kind = ProgramKind.detect(process: "agy", title: nil)
        #expect(kind.glyph == .brand(asset: "antigravity", template: false))
    }

    @Test func agyIsAnAgent() {
        #expect(ProgramKind.detect(process: "agy", title: nil).isAgent)
    }

    /// The `den` CLI runs Den's own binary, as `den` or `Den`.
    @Test func denCLIShowsTheAppIcon() {
        for process in ["den", "Den"] {
            let kind = ProgramKind.detect(process: process, title: nil)
            #expect(kind.id == "den")
            #expect(kind.glyph == .picture(asset: "den"))
        }
        #expect(BrandIcon.image(named: "den", ext: "png", template: false) != nil)
    }
}
