import Foundation
import Testing
@testable import DenVT

@Suite struct KeyEncoderTests {
    /// Shift+; on a US layout, as AppKit reports it.
    private let colon = KeyInput(macKeyCode: 0x29, action: .press, mods: [.shift], consumedMods: [.shift],
                                 text: ":", unshifted: UInt32(UInt8(ascii: ";")))

    @Test func shiftedPunctuationSendsTextInLegacyMode() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        let bytes = try KeyEncoder().encode(colon, terminal: terminal, optionAsAlt: true)
        #expect(bytes == Data(":".utf8))
    }

    /// Neovim enables kitty's disambiguate flag; a shift that produced the
    /// text must not turn `:` into CSI 59;2u.
    @Test func shiftedPunctuationSendsTextWithKittyDisambiguate() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        terminal.write(Data("\u{1b}[>1u".utf8))
        let bytes = try KeyEncoder().encode(colon, terminal: terminal, optionAsAlt: true)
        #expect(bytes == Data(":".utf8))
    }

    private func optionSpace(right: Bool, text: String, consumed: KeyMods) -> KeyInput {
        KeyInput(macKeyCode: 0x31, action: .press, mods: right ? [.alt, .altRight] : [.alt], consumedMods: consumed,
                 text: text, unshifted: UInt32(UInt8(ascii: " ")))
    }

    @Test func optionSpaceSendsEscSpaceWhenOptionIsAlt() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        let bytes = try KeyEncoder().encode(optionSpace(right: false, text: " ", consumed: []), terminal: terminal, optionAsAlt: .both)
        #expect(bytes == Data("\u{1b} ".utf8))
    }

    @Test func leftOnlyModeTreatsLeftOptionAsAlt() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        let bytes = try KeyEncoder().encode(optionSpace(right: false, text: " ", consumed: []), terminal: terminal, optionAsAlt: .left)
        #expect(bytes == Data("\u{1b} ".utf8))
    }

    /// Right option composes text (here a no-break space) when only left is alt.
    @Test func leftOnlyModeLetsRightOptionCompose() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        let bytes = try KeyEncoder().encode(optionSpace(right: true, text: "\u{a0}", consumed: [.alt]), terminal: terminal, optionAsAlt: .left)
        #expect(bytes == Data("\u{a0}".utf8))
    }

    @Test func optionComposesWhenNotAlt() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        let bytes = try KeyEncoder().encode(optionSpace(right: false, text: "\u{a0}", consumed: [.alt]), terminal: terminal, optionAsAlt: .none)
        #expect(bytes == Data("\u{a0}".utf8))
    }

    private let numpadEnter = KeyInput(macKeyCode: 0x4c, action: .press, mods: [], consumedMods: [], text: "\r", unshifted: 0x0d)

    @Test func numpadEnterSendsSS3MInApplicationKeypadMode() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        #expect(try KeyEncoder().encode(numpadEnter, terminal: terminal, optionAsAlt: .none) == Data("\r".utf8))
        terminal.write(Data("\u{1b}=".utf8))
        #expect(try KeyEncoder().encode(numpadEnter, terminal: terminal, optionAsAlt: .none) == Data("\u{1b}OM".utf8))
    }
}
