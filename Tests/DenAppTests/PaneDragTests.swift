import DenProtocol
import Foundation
import Testing
@testable import DenApp

@Suite struct PaneDragTests {
    let size = CGSize(width: 300, height: 300)

    @Test func middleSwapsAndEdgesDock() {
        #expect(PaneDrag.placement(at: CGPoint(x: 150, y: 150), in: size) == .swap)
        #expect(PaneDrag.placement(at: CGPoint(x: 20, y: 150), in: size) == .left)
        #expect(PaneDrag.placement(at: CGPoint(x: 280, y: 160), in: size) == .right)
        #expect(PaneDrag.placement(at: CGPoint(x: 150, y: 15), in: size) == .above)
        #expect(PaneDrag.placement(at: CGPoint(x: 140, y: 290), in: size) == .below)
    }

    /// A little off center already picks a side; only the compass's middle
    /// square swaps.
    @Test func directionFromCenterPicksTheSide() {
        #expect(PaneDrag.placement(at: CGPoint(x: 110, y: 150), in: size) == .left)
        #expect(PaneDrag.placement(at: CGPoint(x: 195, y: 160), in: size) == .right)
        #expect(PaneDrag.placement(at: CGPoint(x: 150, y: 105), in: size) == .above)
        #expect(PaneDrag.placement(at: CGPoint(x: 160, y: 200), in: size) == .below)
        #expect(PaneDrag.placement(at: CGPoint(x: 160, y: 140), in: size) == .swap)
    }

    /// The compass squares are targets too: pointing at one picks it.
    @Test func compassSquaresAreTargets() {
        let c = CGPoint(x: 400, y: 300), big = CGSize(width: 800, height: 600)
        #expect(PaneDrag.placement(at: CGPoint(x: c.x - 34, y: c.y), in: big) == .left)
        #expect(PaneDrag.placement(at: CGPoint(x: c.x + 34, y: c.y), in: big) == .right)
        #expect(PaneDrag.placement(at: CGPoint(x: c.x, y: c.y - 34), in: big) == .above)
        #expect(PaneDrag.placement(at: CGPoint(x: c.x, y: c.y + 34), in: big) == .below)
    }
}
