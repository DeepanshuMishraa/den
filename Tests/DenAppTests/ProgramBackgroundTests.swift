import Foundation
import Testing
@testable import DenApp
@testable import DenVT

@Suite struct ProgramBackgroundTests {
    let dracula = RGB(0x28, 0x2A, 0x36)

    @Test func osc11BackgroundWinsWithoutCoverage() {
        let bg = RGB(0x1E, 0x1E, 0x2E)
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: bg, counts: [:], cellCount: 100)
        #expect(detected == bg)
    }

    @Test func aBackgroundCoveringMostOfTheGridIsTheProgramBackground() {
        let btop = RGB(0x0B, 0x16, 0x22)
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula, counts: [btop: 95], cellCount: 100)
        #expect(detected == btop)
    }

    @Test func exactlyThirtyFivePercentCounts() {
        let editor = RGB(0x20, 0x20, 0x20)
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula, counts: [editor: 35], cellCount: 100)
        #expect(detected == editor)
    }

    @Test func aSmallPanelIsNotAProgramBackground() {
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula, counts: [RGB(0x44, 0x47, 0x5A): 34], cellCount: 100)
        #expect(detected == nil)
    }

    @Test func anUnpaintedGridHasNoProgramBackground() {
        #expect(ProgramBackground.detect(theme: dracula, defaultBackground: dracula, counts: [:], cellCount: 100) == nil)
    }

    @Test func anEmptyGridHasNoProgramBackground() {
        #expect(ProgramBackground.detect(theme: dracula, defaultBackground: dracula, counts: [:], cellCount: 0) == nil)
    }

    @Test func osc11OnlyCountsWhenItDiffersFromTheTheme() {
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula, counts: [RGB(0xFF, 0xFF, 0xFF): 60], cellCount: 100)
        #expect(detected == RGB(0xFF, 0xFF, 0xFF))
    }

    @Test func aNearTieKeepsTheBackgroundAlreadyShown() {
        let shown = RGB(0x0D, 0x0C, 0x0C)
        let challenger = RGB(0x10, 0x0F, 0x0F)
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula,
                                                counts: [challenger: 39, shown: 35], cellCount: 100,
                                                previous: shown)
        #expect(detected == shown)
    }

    @Test func aClearlyLargerBackgroundReplacesTheShownOne() {
        let shown = RGB(0x0D, 0x0C, 0x0C)
        let challenger = RGB(0x10, 0x0F, 0x0F)
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula,
                                                counts: [challenger: 55, shown: 30], cellCount: 100,
                                                previous: shown)
        #expect(detected == challenger)
    }

    @Test func aBackgroundThatDroppedBelowTheHoldIsReplaced() {
        let shown = RGB(0x0D, 0x0C, 0x0C)
        let next = RGB(0x20, 0x20, 0x20)
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula,
                                                counts: [next: 40, shown: 15], cellCount: 100,
                                                previous: shown)
        #expect(detected == next)
    }

    @Test func aBackgroundThatVanishedIsReplaced() {
        let shown = RGB(0x0D, 0x0C, 0x0C)
        let next = RGB(0x20, 0x20, 0x20)
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: dracula,
                                                counts: [next: 60], cellCount: 100,
                                                previous: shown)
        #expect(detected == next)
    }

    @Test func aHeldBackgroundStillYieldsWhenTheProgramPaintsNothing() {
        let shown = RGB(0x0D, 0x0C, 0x0C)
        #expect(ProgramBackground.detect(theme: dracula, defaultBackground: dracula,
                                         counts: [shown: 10], cellCount: 100, previous: shown) == nil)
    }

    @Test func aFullScreenProgramPaintsTheDetectedBackground() throws {
        let painted = RGB(0x0B, 0x16, 0x22)
        let terminal = try VTTerminal(cols: 10, rows: 5)
        terminal.setDefaultColors(foreground: RGB(0xF8, 0xF8, 0xF2), background: dracula, cursor: nil, palette: [])
        let fill = "\u{1b}[48;2;\(painted.r);\(painted.g);\(painted.b)m" + String(repeating: " ", count: 50) + "\u{1b}[0m"
        terminal.write(Data(fill.utf8))
        let state = try VTRenderState()
        try state.update(from: terminal)

        var counts: [RGB: Int] = [:]
        var cellCount = 0
        state.forEachCell { cell in
            cellCount += 1
            guard let background = cell.background else { return }
            counts[background, default: 0] += cell.width == .wide ? 2 : 1
        }
        let detected = ProgramBackground.detect(theme: dracula, defaultBackground: state.colors.background,
                                                counts: counts, cellCount: cellCount)
        #expect(detected == painted)
    }
}
