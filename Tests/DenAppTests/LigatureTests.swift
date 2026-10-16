import Metal
import Testing
@testable import DenApp

@MainActor
@Suite struct LigatureTests {
    private func atlas(smoothing: Bool = false) throws -> GlyphAtlas {
        FontRegistry.registerBundled()
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try #require(GlyphAtlas(device: device, metrics: FontMetrics(scale: 2), smoothing: smoothing))
    }

    /// The bundled JetBrains Mono ligates these with contextual alternates.
    @Test func symbolRunsShapeIntoLigatures() throws {
        let atlas = try atlas()
        for text in ["->", "!=", "=>", "<=", "==="] {
            let shaped = try #require(atlas.shape(text, bold: false, italic: false), "no ligature for \(text)")
            #expect(Set(shaped.map(\.cell)).isSubset(of: Set(0 ..< text.count)))
            // Leading cells hold blank spacers; the ligature is inked once.
            #expect(shaped.contains { atlas.glyph(id: $0.glyph, bold: false, italic: false) != nil })
        }
    }

    @Test func plainTextIsLeftToTheCells() throws {
        let atlas = try atlas()
        #expect(atlas.shape("a-b", bold: false, italic: false) == nil)
        #expect(atlas.shape("ab", bold: false, italic: false) == nil)
    }

    @Test func smoothingIsPerAtlas() throws {
        #expect(try atlas(smoothing: true).smoothing)
        #expect(try !atlas(smoothing: false).smoothing)
    }
}
