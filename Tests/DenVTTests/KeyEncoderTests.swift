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
}
