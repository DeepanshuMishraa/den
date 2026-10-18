import Testing
@testable import DenApp
@testable import DenVT

@Suite struct BackgroundFoldTests {
    let dracula = RGB(0x28, 0x2A, 0x36)

    private func composite(_ layer: SIMD4<Float>, over base: RGB) -> SIMD3<Float> {
        let b = base.simd()
        return SIMD3(layer.x, layer.y, layer.z) * layer.w + SIMD3(b.x, b.y, b.z) * (1 - layer.w)
    }

    @Test func layersReproduceTheColorOverTheBase() throws {
        let fold = BackgroundFold(theme: dracula, defaultBackground: dracula, coverage: [:], cellCount: 100)
        for color in [RGB(0x44, 0x47, 0x5A), RGB(255, 255, 255), RGB(0, 0, 0), RGB(0xFF, 0x79, 0xC6), RGB(0x20, 0x90, 0x10)] {
            let layer = try #require(fold.layer(color))
            let got = composite(layer, over: dracula)
            let want = color.simd()
            #expect(abs(got.x - want.x) < 1.5 / 255 && abs(got.y - want.y) < 1.5 / 255 && abs(got.z - want.z) < 1.5 / 255)
        }
    }

    @Test func theBaseItselfDrawsNothing() {
        let fold = BackgroundFold(theme: dracula, defaultBackground: dracula, coverage: [:], cellCount: 100)
        #expect(fold.canvas == .none)
        #expect(fold.clear == nil)
        #expect(fold.layer(dracula) == nil)
        #expect(fold.layer(RGB(0x29, 0x2A, 0x36)) == nil)
    }

    @Test func aNearbyCanvasFoldsAndShiftsTheRest() throws {
        let canvas = RGB(0x1E, 0x1E, 0x2E)
        let panel = RGB(0x31, 0x32, 0x44)
        let fold = BackgroundFold(theme: dracula, defaultBackground: dracula, coverage: [canvas: 80, panel: 10], cellCount: 100)
        #expect(fold.canvas == .folded(canvas))
        #expect(fold.clear == nil)
        #expect(fold.layer(canvas) == nil)
        // The panel keeps its step above the canvas, now above the card.
        let rebased = fold.rebased(panel)
        #expect(abs((OKLab(rebased).l - OKLab(dracula).l) - (OKLab(panel).l - OKLab(canvas).l)) < 0.01)
        #expect(fold.layer(panel) != nil)
    }

    /// btop's own theme on a much darker Den theme still folds: same
    /// register, near neutral, however far apart in lightness.
    @Test func aDistantDarkCanvasOnADarkThemeFolds() {
        let theme = RGB(0x0B, 0x0F, 0x14)
        let btop = RGB(0x2A, 0x2E, 0x3C)
        let fold = BackgroundFold(theme: theme, defaultBackground: theme, coverage: [btop: 95], cellCount: 100)
        #expect(fold.canvas == .folded(btop))
        #expect(fold.clear == nil)
        #expect(fold.layer(btop) == nil)
    }

    @Test func sparseBackgroundsAreNoCanvas() {
        let fold = BackgroundFold(theme: dracula, defaultBackground: dracula, coverage: [RGB(0x1E, 0x1E, 0x2E): 10], cellCount: 100)
        #expect(fold.canvas == .none)
    }

    /// A light app on a dark theme keeps its color but fills the pane edge
    /// to edge, so it reads as the pane's surface, not an inset sheet.
    @Test func aLightCanvasOnADarkThemeFillsThePane() throws {
        let paper = RGB(0xF4, 0xF1, 0xEA)
        let fold = BackgroundFold(theme: dracula, defaultBackground: dracula, coverage: [paper: 90], cellCount: 100)
        #expect(fold.canvas == .filled(paper))
        #expect(fold.layer(paper) == nil)
        let clear = try #require(fold.clear)
        // Premultiplied: composited over the card it gives the paper color.
        let b = dracula.simd(), p = paper.simd()
        let got = SIMD3(clear.x, clear.y, clear.z) + SIMD3(b.x, b.y, b.z) * (1 - clear.w)
        #expect(abs(got.x - p.x) < 1.5 / 255 && abs(got.y - p.y) < 1.5 / 255 && abs(got.z - p.z) < 1.5 / 255)
    }

    @Test func aStronglyTintedCanvasKeepsItsColor() {
        let mcBlue = RGB(0x00, 0x00, 0xAA)
        let fold = BackgroundFold(theme: dracula, defaultBackground: dracula, coverage: [mcBlue: 90], cellCount: 100)
        #expect(fold.canvas == .filled(mcBlue))
    }

    @Test func aNearbyOSC11BackgroundFolds() {
        let osc11 = RGB(0x24, 0x27, 0x3A)
        let fold = BackgroundFold(theme: dracula, defaultBackground: osc11, coverage: [:], cellCount: 100)
        #expect(fold.canvas == .folded(osc11))
        #expect(fold.base == dracula)
    }

    @Test func aFarOSC11BackgroundFillsThePane() {
        let osc11 = RGB(255, 255, 255)
        let fold = BackgroundFold(theme: dracula, defaultBackground: osc11, coverage: [:], cellCount: 100)
        #expect(fold.canvas == .filled(osc11))
        #expect(fold.base == osc11)
        #expect(fold.clear != nil)
    }
}
