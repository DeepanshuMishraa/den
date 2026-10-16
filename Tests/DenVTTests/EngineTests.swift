import Foundation
import Testing
@testable import DenVT

@Suite struct EngineTests {
    /// What the partial frames assembled matches a fresh full frame of the
    /// same terminal (a replica restored from its snapshot).
    @Test func damageUpdatesMatchAFullFrame() throws {
        let t = try VTTerminal(cols: 30, rows: 6)
        let state = try VTRenderState()
        let steps = ["one\r\ntwo\r\n", "\u{1b}[2;2Hx\u{1b}[31mred\u{1b}[0m", "\u{1b}[3;1H\u{1b}[2K", "é\u{301} 漢字 👩‍👩‍👧\r\n", "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n", "\u{1b}[1;10Hend"]
        for step in steps {
            t.write(Data(step.utf8))
            try state.update(from: t)
        }
        let fresh = try VTTerminal(snapshot: try t.snapshot())
        #expect(try screenText(t) == screenText(fresh))
    }

    @Test func graphemeClustersKeepEveryScalar() throws {
        let t = try VTTerminal(cols: 20, rows: 2)
        t.write(Data("e\u{301}x".utf8))
        // Scalars, not String's canonical equivalence: a precomposed é would pass that.
        #expect(try Array(screenText(t)[0].unicodeScalars.prefix(3)) == Array("e\u{301}x".unicodeScalars))
    }

    @Test func indexedColorsResolveThroughThePalette() throws {
        let t = try VTTerminal(cols: 10, rows: 2)
        var palette = (0 ..< 256).map { RGB(UInt8($0), 0, 0) }
        palette[1] = RGB(200, 10, 20)
        t.setDefaultColors(foreground: RGB(1, 2, 3), background: RGB(4, 5, 6), cursor: nil, palette: palette)
        t.write(Data("\u{1b}[31mr\u{1b}[38;2;9;8;7mt\u{1b}[0md".utf8))
        let state = try VTRenderState()
        try state.update(from: t)
        var colors: [Character: RGB?] = [:]
        state.forEachCell { cell in
            guard let scalar = cell.codepoints.first.flatMap(Unicode.Scalar.init) else { return }
            colors[Character(scalar)] = cell.foreground
        }
        #expect(colors["r"] == RGB(200, 10, 20))
        #expect(colors["t"] == RGB(9, 8, 7))
        #expect(colors["d"] == .some(nil))
        #expect(state.colors.background == RGB(4, 5, 6))
    }

    /// A synchronized update the program never ends is shown at its deadline.
    @Test func unfinishedSynchronizedUpdateCommitsAtItsDeadline() async throws {
        let t = try VTTerminal(cols: 20, rows: 2)
        t.write(Data("\u{1b}[?2026hhidden".utf8))
        let remaining = try #require(t.synchronizedUpdateDeadline)
        #expect(try screenText(t)[0].trimmingCharacters(in: .whitespaces).isEmpty)
        try await Task.sleep(for: .milliseconds(Int(remaining) + 20))
        #expect(t.commitDueSynchronizedUpdate())
        #expect(t.synchronizedUpdateDeadline == nil)
        #expect(try screenText(t)[0].hasPrefix("hidden"))
    }

    /// Queries are answered in byte order: the status report before the DA.
    @Test func repliesComeBackInOrder() throws {
        let t = try VTTerminal(cols: 20, rows: 4)
        var replies = Data()
        t.effects = VTEffects(writeBack: { replies.append(contentsOf: $0) })
        t.write(Data("\u{1b}[5n\u{1b}[c".utf8))
        let text = String(decoding: replies, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}[0n\u{1b}[?"))
    }

    @Test func olderSnapshotVersionsStillRestore() throws {
        let t = try VTTerminal(cols: 20, rows: 3)
        t.write(Data("kept\r\n".utf8))
        let old = try t.snapshot(version: VTTerminal.minimumSnapshotVersion)
        let restored = try VTTerminal(snapshot: old)
        #expect(try screenText(restored)[0].hasPrefix("kept"))
    }

    @Test func garbageIsNotASnapshot() throws {
        #expect(throws: VTError.self) { try VTTerminal(snapshot: Data("not a snapshot".utf8)) }
    }

    @Test func titleEventsReachEffects() throws {
        let t = try VTTerminal(cols: 20, rows: 2)
        var titles: [String?] = []
        t.effects = VTEffects(titleChanged: { titles.append($0) })
        t.write(Data("\u{1b}]2;first\u{7}\u{1b}]0;second\u{7}".utf8))
        #expect(titles == ["first", "second"])
    }

    /// History stops at the row cap, and a replica restored from a snapshot
    /// keeps the same cap so both evict the same rows.
    @Test func scrollbackIsCappedByRowsOnBothSides() throws {
        let t = try VTTerminal(cols: 20, rows: 4)
        let lines = Data((0 ..< 10_500).map { "line \($0)\r\n" }.joined().utf8)
        t.write(lines)
        #expect(t.scrollbar.total == UInt64(VTTerminal.scrollbackRows) + 4)
        let replica = try VTTerminal(snapshot: try t.snapshot())
        replica.write(lines)
        t.write(lines)
        #expect(replica.scrollbar == t.scrollbar)
        #expect(try screenText(replica) == screenText(t))
    }

    @Test func scrollbackScrollsAndReportsPosition() throws {
        let t = try VTTerminal(cols: 10, rows: 3)
        for i in 0 ..< 10 { t.write(Data("l\(i)\r\n".utf8)) }
        #expect(t.scrollbar == Scrollbar(total: 11, offset: 8, length: 3))
        t.scrollViewport(.delta(-2))
        #expect(t.scrollbar.offset == 6)
        t.scrollViewport(toRow: 0)
        #expect(t.scrollbar.offset == 0)
        t.scrollViewport(.bottom)
        #expect(t.scrollbar.offset == 8)
    }
}

@Suite struct InputEncodingTests {
    private func key(_ code: UInt16, mods: KeyMods = [], text: String? = nil, unshifted: Character? = nil) -> KeyInput {
        KeyInput(macKeyCode: code, action: .press, mods: mods, consumedMods: [], text: text,
                 unshifted: unshifted.flatMap { $0.unicodeScalars.first?.value } ?? 0)
    }

    @Test func arrowsFollowCursorKeyMode() throws {
        let t = try VTTerminal(cols: 10, rows: 2)
        let up = key(0x7E)
        #expect(try KeyEncoder().encode(up, terminal: t, optionAsAlt: .none) == Data("\u{1b}[A".utf8))
        t.write(Data("\u{1b}[?1h".utf8))
        #expect(try KeyEncoder().encode(up, terminal: t, optionAsAlt: .none) == Data("\u{1b}OA".utf8))
    }

    @Test func controlLetterSendsControlByte() throws {
        let t = try VTTerminal(cols: 10, rows: 2)
        #expect(try KeyEncoder().encode(key(0x08, mods: [.ctrl], unshifted: "c"), terminal: t, optionAsAlt: .none) == Data([0x03]))
    }

    @Test func kittyFlagsReportEscapeAsCSIu() throws {
        let t = try VTTerminal(cols: 10, rows: 2)
        t.write(Data("\u{1b}[>1u".utf8))
        #expect(try KeyEncoder().encode(key(0x35), terminal: t, optionAsAlt: .none) == Data("\u{1b}[27u".utf8))
    }

    @Test func sgrMouseReportsCellsOneBased() throws {
        let t = try VTTerminal(cols: 20, rows: 5)
        t.write(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let bytes = try MouseEncoder().encode(action: .press, button: .left, mods: [], x: 25, y: 40, cellWidth: 8, cellHeight: 16,
                                               cols: 20, rows: 5, anyButtonPressed: true, terminal: t)
        #expect(bytes == Data("\u{1b}[<0;4;3M".utf8))
    }

    /// Dragging past the bottom-right edge reports the last cell.
    @Test func dragPastTheGridReportsTheLastCell() throws {
        let t = try VTTerminal(cols: 20, rows: 5)
        t.write(Data("\u{1b}[?1002h\u{1b}[?1006h".utf8))
        let bytes = try MouseEncoder().encode(action: .motion, button: .left, mods: [], x: 999, y: 999, cellWidth: 8, cellHeight: 16,
                                               cols: 20, rows: 5, anyButtonPressed: true, terminal: t)
        #expect(bytes == Data("\u{1b}[<32;20;5M".utf8))
    }

    @Test func scrollingByIntMinDoesNotTrap() throws {
        let t = try VTTerminal(cols: 10, rows: 2)
        t.scrollViewport(.delta(.min))
        t.scrollViewport(.delta(.max))
    }

    @Test func noMouseReportsWithoutTracking() throws {
        let t = try VTTerminal(cols: 20, rows: 5)
        let bytes = try MouseEncoder().encode(action: .press, button: .left, mods: [], x: 0, y: 0, cellWidth: 8, cellHeight: 16,
                                               cols: 20, rows: 5, anyButtonPressed: true, terminal: t)
        #expect(bytes.isEmpty)
    }

    @Test func pasteIsBracketedOnlyWhenAsked() throws {
        let t = try VTTerminal(cols: 20, rows: 5)
        #expect(t.encodePaste("a\nb") == Data("a\rb".utf8))
        t.write(Data("\u{1b}[?2004h".utf8))
        #expect(t.encodePaste("a\u{1b}b") == Data("\u{1b}[200~ab\u{1b}[201~".utf8))
    }

    @Test func focusReports() {
        #expect(VTTerminal.encodeFocus(true) == Data("\u{1b}[I".utf8))
        #expect(VTTerminal.encodeFocus(false) == Data("\u{1b}[O".utf8))
    }
}
