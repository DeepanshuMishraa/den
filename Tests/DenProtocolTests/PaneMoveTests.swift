import Foundation
import Testing
@testable import DenProtocol

@Suite struct PaneMoveTests {
    let a = PaneID(), b = PaneID(), c = PaneID()

    /// a | (b / c)
    var tree: SplitNode {
        .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c)))
    }

    @Test func swapKeepsTheShape() {
        #expect(tree.moving(a, to: c, placement: .swap)
            == .split(axis: .horizontal, ratio: 0.5, first: .pane(c), second: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(a))))
    }

    @Test func dockingBesideATargetSplitsIt() {
        // Move c to b's left: a | ((c | b))
        #expect(tree.moving(c, to: b, placement: .left)
            == .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .split(axis: .horizontal, ratio: 0.5, first: .pane(c), second: .pane(b))))
        // Move a below c: b / (c / a)
        #expect(tree.moving(a, to: c, placement: .below)
            == .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .split(axis: .vertical, ratio: 0.5, first: .pane(c), second: .pane(a))))
    }

    @Test func movingOntoItselfOrAMissingPaneDoesNothing() {
        #expect(tree.moving(a, to: a, placement: .left) == nil)
        #expect(tree.moving(a, to: PaneID(), placement: .swap) == nil)
        #expect(SplitNode.pane(a).moving(a, to: a, placement: .swap) == nil)
    }

    @Test func neighborsFollowGeometry() {
        #expect(tree.neighbor(of: a, toward: .right) == b)
        #expect(tree.neighbor(of: b, toward: .left) == a)
        #expect(tree.neighbor(of: c, toward: .left) == a)
        #expect(tree.neighbor(of: b, toward: .down) == c)
        #expect(tree.neighbor(of: c, toward: .up) == b)
        #expect(tree.neighbor(of: a, toward: .left) == nil)
        #expect(tree.neighbor(of: b, toward: .up) == nil)
    }

    @Test func placementRoundTripsOverTheWire() throws {
        let message = ClientMessage.movePane(a, to: b, placement: .above)
        #expect(try ClientMessage.decode(message.encode()) == message)
    }
}
