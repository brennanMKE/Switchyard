// LaneGeometryTests.swift
//
// `import Foundation` because this file compares `CGFloat` values directly
// (AGENTS.md Rule 8c): without it, `#expect` reports two bit-identical
// `CGFloat`s as unequal.

import Foundation
import Testing
import YardGit
import YardUI

@Test("laneGutterWidth reserves only lane 0 for a linear history")
func laneGutterWidthLinearHistory() {
    #expect(LaneGeometry.laneGutterWidth(maxLane: 0)
             == LaneGeometry.leadingInset + LaneGeometry.trailingInset)
}

@Test("laneGutterWidth grows by one laneSpacing per additional lane")
func laneGutterWidthGrowsWithMaxLane() {
    #expect(LaneGeometry.laneGutterWidth(maxLane: 2)
             == LaneGeometry.leadingInset + 2 * LaneGeometry.laneSpacing + LaneGeometry.trailingInset)
}

@Test("laneGutterWidth clamps a negative maxLane to zero")
func laneGutterWidthClampsNegativeMaxLane() {
    #expect(LaneGeometry.laneGutterWidth(maxLane: -1) == LaneGeometry.laneGutterWidth(maxLane: 0))
}

@Test("xOffset places lane 0 at the leading inset and steps by laneSpacing")
func xOffsetStepsByLaneSpacing() {
    #expect(LaneGeometry.xOffset(forLane: 0) == LaneGeometry.leadingInset)
    #expect(LaneGeometry.xOffset(forLane: 1) == LaneGeometry.leadingInset + LaneGeometry.laneSpacing)
    #expect(LaneGeometry.xOffset(forLane: 3) == LaneGeometry.leadingInset + 3 * LaneGeometry.laneSpacing)
}

@Test("maxLane(in:) is zero for an empty set")
func maxLaneInEmptySet() {
    #expect(LaneGeometry.maxLane(in: []) == 0)
}

@Test("maxLane(in:) counts a parent edge that reaches past every row's own lane")
func maxLaneInCountsParentEdgesBeyondOwnLane() {
    // A row whose own lane is 0 but whose only parent edge runs to lane 2 --
    // the octopus-merge shape `LaneAssignmentTests`' private `maxLane(_:)`
    // helper exists to catch, where `lane` alone would under-report.
    let rows = [GraphRow(oid: "a", parents: ["b"], lane: 0, parentLanes: [2])]
    #expect(LaneGeometry.maxLane(in: rows) == 2)
}
