import Foundation
import Testing
@testable import DenVT

/// 2x2 RGBA: red, green / blue, white.
private let pixels = "/wAA/wD/AP8AAP///////w=="

private func upload(_ keys: String) -> Data {
    Data("\u{1b}_Ga=T,f=32,s=2,v=2,q=2,\(keys);\(pixels)\u{1b}\\".utf8)
}

@Suite struct ImageTests {
    @Test func placementCoversItsCellsAtAnyCellSize() throws {
        let terminal = try VTTerminal(cols: 20, rows: 6)
        try terminal.resize(cols: 20, rows: 6, cellWidthPx: 10, cellHeightPx: 20)
        terminal.write(Data("\r\n  ".utf8))
        terminal.write(upload("i=5,c=4,r=2"))

        let placed = try terminal.imagePlacements(cellWidth: 10, cellHeight: 20)
        #expect(placed.count == 1)
        let p = try #require(placed.first)
        #expect(p.key.id == 5 && p.pixelWidth == 2 && p.pixelHeight == 2 && p.layer == .aboveText)
        #expect(p.clip == SIMD4(20, 20, 40, 40))
        #expect(p.image == SIMD4(20, 20, 40, 40))

        // A larger font: the same cells, drawn larger.
        let larger = try #require(try terminal.imagePlacements(cellWidth: 20, cellHeight: 40).first)
        #expect(larger.clip == SIMD4(40, 40, 80, 80))

        guard case .rgba(let rgba) = try terminal.imagePixels(larger.key) else {
            Issue.record("expected RGBA pixels")
            return
        }
        #expect(Array(rgba.prefix(4)) == [255, 0, 0, 255])
    }

    @Test func replicaFromSnapshotKeepsImagesAndTakesNewOnes() throws {
        let server = try VTTerminal(cols: 20, rows: 6)
        server.write(upload("i=1,c=2,r=1"))
        let replica = try VTTerminal(snapshot: try server.snapshot())
        let next = Data("\r\n".utf8) + upload("i=2,c=2,r=1")
        server.write(next)
        replica.write(next)

        let ids = try replica.imagePlacements(cellWidth: 10, cellHeight: 20).map(\.key.id)
        #expect(ids == [1, 2])
    }

    @Test func zIndexPicksTheLayer() throws {
        let terminal = try VTTerminal(cols: 20, rows: 6)
        terminal.write(upload("i=1,z=-1"))
        terminal.write(upload("i=2,z=-1073741825"))
        let layers = try terminal.imagePlacements(cellWidth: 10, cellHeight: 20).map(\.layer)
        #expect(layers == [.belowBackgrounds, .belowText])
    }

    @Test func imagesScrollWithTheirTextAndLeaveTheViewport() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        terminal.write(upload("i=1,c=2,r=1"))
        let tops = try terminal.imagePlacements(cellWidth: 10, cellHeight: 20).map(\.clip.y)
        #expect(tops == [0])
        terminal.write(Data(String(repeating: "\r\n", count: 8).utf8))
        #expect(try terminal.imagePlacements(cellWidth: 10, cellHeight: 20).isEmpty)
        terminal.scrollViewport(toRow: 0)
        #expect(try terminal.imagePlacements(cellWidth: 10, cellHeight: 20).count == 1)
    }

    @Test func deletedImagesAreGone() throws {
        let terminal = try VTTerminal(cols: 20, rows: 4)
        terminal.write(upload("i=9"))
        let key = try #require(try terminal.imagePlacements(cellWidth: 10, cellHeight: 20).first?.key)
        terminal.write(Data("\u{1b}_Ga=d,d=I,i=9,q=2\u{1b}\\".utf8))
        #expect(try terminal.imagePlacements(cellWidth: 10, cellHeight: 20).isEmpty)
        #expect(throws: VTError.self) { try terminal.imagePixels(key) }
    }
}
