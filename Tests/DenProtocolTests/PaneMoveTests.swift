import Foundation
import Testing
@testable import DenProtocol

@Suite struct PaneMoveTests {
    let a = PaneID(), b = PaneID(), c = PaneID()

    /// a | (b / c)
    var tree: SplitNode {
        .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c)))
    }

    /// Resizing finds the innermost split on the axis: c's left/right edge is
    /// the root divider, its up/down edge the divider between b and c.
    @Test func enclosingSplitPicksTheInnermostOnTheAxis() {
        let side = tree.enclosingSplit(of: c, axis: .horizontal)
        #expect(side?.path == [] && side?.ratio == 0.5)
        let stacked = tree.enclosingSplit(of: c, axis: .vertical)
        #expect(stacked?.path == [1] && stacked?.ratio == 0.5)
        #expect(tree.enclosingSplit(of: a, axis: .vertical) == nil)
        #expect(SplitNode.pane(a).enclosingSplit(of: a, axis: .horizontal) == nil)
    }

    /// Splitting right twice gives a | (b | c); balanced, each takes a third.
    @Test func balancingGivesEveryPaneOnAnAxisAnEqualShare() {
        let row = SplitNode.split(axis: .horizontal, ratio: 0.5, first: .pane(a),
                                  second: .split(axis: .horizontal, ratio: 0.5, first: .pane(b), second: .pane(c)))
        let ratios = row.balancedRatios()
        #expect(ratios.count == 1)
        #expect(ratios.first?.path == [])
        #expect(abs((ratios.first?.ratio ?? 0) - 1.0 / 3) < 1e-6)
        // a | (b / c) is already even: a stack counts as one column.
        #expect(tree.balancedRatios().isEmpty)
        #expect(SplitNode.pane(a).balancedRatios().isEmpty)
    }

    @Test func movingIntoAnotherTabDocksBesideTheTarget() {
        let d = PaneID()
        let other = SplitNode.pane(d)
        // c goes right of d; its old tab closes up around a and b.
        let moved = SplitNode.moving(c, from: tree, to: d, in: other, placement: .right)
        #expect(moved?.source == .split(axis: .horizontal, ratio: 0.5, first: .pane(a), second: .pane(b)))
        #expect(moved?.dest == .split(axis: .horizontal, ratio: 0.5, first: .pane(d), second: .pane(c)))
        // A tab's only pane leaves it empty.
        #expect(SplitNode.moving(a, from: .pane(a), to: d, in: other, placement: .below)?.source == nil)
    }

    @Test func swappingAcrossTabsTradesPlaces() {
        let d = PaneID()
        let moved = SplitNode.moving(a, from: tree, to: d, in: .pane(d), placement: .swap)
        #expect(moved?.source == .split(axis: .horizontal, ratio: 0.5, first: .pane(d), second: .split(axis: .vertical, ratio: 0.5, first: .pane(b), second: .pane(c))))
        #expect(moved?.dest == .pane(a))
        // Nothing to do when the target is missing or the pane is already there.
        #expect(SplitNode.moving(a, from: tree, to: PaneID(), in: .pane(d), placement: .left) == nil)
        #expect(SplitNode.moving(a, from: tree, to: b, in: tree, placement: .left) == nil)
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
