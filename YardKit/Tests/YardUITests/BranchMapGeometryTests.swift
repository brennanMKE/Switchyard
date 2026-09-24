// BranchMapGeometryTests.swift — the branch map's points and strips (#0412)
//
// `import Foundation` because these compare `CGFloat`s (AGENTS.md Rule 8c).

import Foundation
import Testing
import YardGit
import YardUI

private func geoEdge(
    _ kind: BranchMapLayout.EdgeKind, from: (Int, Int), to: (Int, Int)
) -> BranchMapLayout.Edge {
    BranchMapLayout.Edge(
        kind: kind,
        from: BranchMapLayout.Point(lane: from.0, row: from.1),
        to: BranchMapLayout.Point(lane: to.0, row: to.1),
        childOid: "c", parentOid: "p")
}

@Test func cellsMapToLaneAndRowCentres() {
    let point = BranchMapGeometry.point(BranchMapLayout.Point(lane: 2, row: 3))
    #expect(point == CGPoint(x: 24 + 2 * 36, y: 3 * 24 + 12))
}

@Test func contentSizeCoversEveryLaneAndRowPlusTheLastLabel() {
    let layout = BranchMapLayout(headers: [], nodes: [], edges: [], laneCount: 31, rowCount: 36)
    #expect(BranchMapGeometry.contentSize(layout) == CGSize(width: 24 + 30 * 36 + 160, height: 36 * 24))
}

@Test func aChainIsAStraightVertical() {
    #expect(BranchMapGeometry.polyline(geoEdge(.chain, from: (1, 0), to: (1, 1)))
        == [CGPoint(x: 60, y: 12), CGPoint(x: 60, y: 36)])
}

@Test func aForkRunsDownItsOwnLaneAndTurnsHalfARowAboveTheForkPoint() {
    // Lane 1 row 1 down to lane 0 row 5.
    #expect(BranchMapGeometry.polyline(geoEdge(.fork, from: (1, 1), to: (0, 5)))
        == [CGPoint(x: 60, y: 36), CGPoint(x: 60, y: 120), CGPoint(x: 24, y: 132)])
}

@Test func aForkToAPointAboveDropsHalfARowThenRunsStraightThere() {
    #expect(BranchMapGeometry.polyline(geoEdge(.fork, from: (1, 3), to: (0, 0)))
        == [CGPoint(x: 60, y: 84), CGPoint(x: 60, y: 96), CGPoint(x: 24, y: 12)])
}

@Test func aForkOnOneRowIsAStraightLine() {
    #expect(BranchMapGeometry.polyline(geoEdge(.fork, from: (3, 0), to: (0, 0)))
        == [CGPoint(x: 132, y: 12), CGPoint(x: 24, y: 12)])
}

@Test func aMergeTurnsIntoTheParentsLaneHalfARowBelowTheMerge() {
    #expect(BranchMapGeometry.polyline(geoEdge(.merge, from: (0, 0), to: (2, 3)))
        == [CGPoint(x: 24, y: 12), CGPoint(x: 96, y: 24), CGPoint(x: 96, y: 84)])
}

@Test func aMergeToAParentNotBelowIsAStraightLine() {
    #expect(BranchMapGeometry.polyline(geoEdge(.merge, from: (0, 2), to: (1, 0)))
        == [CGPoint(x: 24, y: 60), CGPoint(x: 60, y: 12)])
}

@Test func anEdgeIsListedForEveryRowStripItCrosses() {
    let layout = BranchMapLayout(
        headers: [], nodes: [],
        edges: [geoEdge(.chain, from: (0, 0), to: (0, 1)), geoEdge(.fork, from: (1, 0), to: (0, 3))],
        laneCount: 2, rowCount: 5)
    let strips = BranchMapGeometry.edgesByRow(layout)
    #expect(strips.count == 5)
    #expect(strips[0] == [0, 1])
    #expect(strips[1] == [0, 1])
    #expect(strips[2] == [1])
    #expect(strips[3] == [1])
    #expect(strips[4] == [])
}

@Test func nodesAreGroupedByRow() {
    let layout = BranchMapLayout(
        headers: [],
        nodes: [
            BranchMapLayout.Node(oid: "a", lane: 0, row: 0), BranchMapLayout.Node(oid: "b", lane: 1, row: 0),
            BranchMapLayout.Node(oid: "c", lane: 0, row: 2),
        ],
        edges: [], laneCount: 2, rowCount: 3)
    #expect(BranchMapGeometry.nodesByRow(layout) == [[0, 1], [], [2]])
}

@Test func scrollingCentresTheTargetBelowTheHeader() {
    let offset = BranchMapGeometry.scrollOffset(
        centering: CGPoint(x: 1000, y: 600),
        viewport: CGSize(width: 400, height: 300), content: CGSize(width: 2000, height: 2000))
    #expect(offset == CGPoint(x: 800, y: 600 + 120 - 150))
}

@Test func scrollingClampsAtTheContentEdges() {
    let content = CGSize(width: 1264, height: 864)
    let viewport = CGSize(width: 500, height: 500)
    #expect(BranchMapGeometry.scrollOffset(centering: CGPoint(x: 10, y: 10), viewport: viewport, content: content)
        == .zero)
    #expect(BranchMapGeometry.scrollOffset(centering: CGPoint(x: 1250, y: 860), viewport: viewport, content: content)
        == CGPoint(x: 1264 - 500, y: 864 + 120 - 500))
}

@Test func aViewportLargerThanTheContentNeverScrolls() {
    #expect(BranchMapGeometry.scrollOffset(
        centering: CGPoint(x: 300, y: 300), viewport: CGSize(width: 900, height: 900),
        content: CGSize(width: 400, height: 400)) == .zero)
}
