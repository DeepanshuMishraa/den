import Foundation
import Testing
@testable import DenVT

/// Renders the visible grid as plain text lines for comparison.
func screenText(_ terminal: VTTerminal) throws -> [String] {
    let state = try VTRenderState()
    try state.update(from: terminal)
    let (cols, rows) = state.size
    var grid = Array(repeating: Array(repeating: " ", count: cols), count: rows)
    state.forEachCell { cell in
        guard !cell.codepoints.isEmpty else { return }
        let s = String(String.UnicodeScalarView(cell.codepoints.compactMap(Unicode.Scalar.init)))
        grid[cell.row][cell.col] = s
    }
    return grid.map { $0.joined() }
}

@Suite struct ReplicaTests {
    @Test func snapshotReplicaStaysInSyncWithStream() throws {
        let server = try VTTerminal(cols: 40, rows: 6)
        for i in 0 ..< 30 { server.write(Data("line \(i)\r\n".utf8)) }
        // Leave an escape sequence unfinished at snapshot time.
        server.write(Data("\u{1b}[3".utf8))

        let replica = try VTTerminal(snapshot: try server.snapshot())
        #expect(try screenText(replica) == screenText(server))

        let rest = Data("1mred\u{1b}[0m done\r\n\u{1b}[2;5Hmoved".utf8)
        server.write(rest)
        replica.write(rest)
        #expect(try screenText(replica) == screenText(server))
        #expect(replica.cols == 40 && replica.rows == 6)
    }

    @Test func resizeAppliedInOrderMatches() throws {
        let server = try VTTerminal(cols: 20, rows: 4)
        let replica = try VTTerminal(snapshot: try server.snapshot())
        let a = Data("a long line that will wrap around\r\n".utf8)
        server.write(a); replica.write(a)
        try server.resize(cols: 10, rows: 6, cellWidthPx: 8, cellHeightPx: 16)
        try replica.resize(cols: 10, rows: 6, cellWidthPx: 8, cellHeightPx: 16)
        let b = Data("after".utf8)
        server.write(b); replica.write(b)
        #expect(try screenText(replica) == screenText(server))
    }

    @Test func writeBackOnlyFromTerminalWithEffects() throws {
        let server = try VTTerminal(cols: 20, rows: 4)
        var responses = Data()
        server.effects = VTEffects(writeBack: { responses.append(contentsOf: $0) })
        let replica = try VTTerminal(snapshot: try server.snapshot())

        // Device status report: cursor position query.
        let query = Data("\u{1b}[6n".utf8)
        server.write(query)
        replica.write(query)
        #expect(String(decoding: responses, as: UTF8.self) == "\u{1b}[1;1R")
    }

    @Test func titleIsReplicated() throws {
        let server = try VTTerminal(cols: 20, rows: 4)
        server.write(Data("\u{1b}]2;Claude Code\u{07}".utf8))
        let replica = try VTTerminal(snapshot: try server.snapshot())
        #expect(replica.title == "Claude Code")
    }
}
