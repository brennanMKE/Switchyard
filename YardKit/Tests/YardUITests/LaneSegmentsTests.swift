// LaneSegmentsTests.swift — the per-row gutter segment table (#0365)
//
// This target imports YardUI WITHOUT `@testable`, so everything asserted
// here is reachable at exactly the access level the app target sees. The
// expected table is the one measured in #0365 on `f2→f1→m1`, `m2→m1`,
// `m1→root`, topological order `f2, m2, f1, m1, root`; every row is
// asserted cell for cell.

import Testing
import YardGit
import YardUI

private func edge(_ lane: Int, _ child: String, _ parent: String, _ parentIndex: Int) -> LaneEdge {
    LaneEdge(lane: lane, child: child, parent: parent, parentIndex: parentIndex)
}

@Test func segmentsMatchTheMeasuredTable() {
    let rows = [
        GraphRow(oid: "f2", parents: ["f1"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "m2", parents: ["m1"], lane: 1, parentLanes: [1]),
        GraphRow(oid: "f1", parents: ["m1"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "m1", parents: ["root"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "root", parents: [], lane: 0, parentLanes: []),
    ]
    let segments = LaneSegments.make(rows)
    #expect(segments.count == rows.count)

    let f2 = segments[0]
    #expect(f2 == LaneRowSegments(
        incoming: [], passThrough: [],
        outgoing: [edge(0, "f2", "f1", 0)]))

    let m2 = segments[1]
    #expect(m2 == LaneRowSegments(
        incoming: [], passThrough: [edge(0, "f2", "f1", 0)],
        outgoing: [edge(1, "m2", "m1", 0)]))

    let f1 = segments[2]
    #expect(f1 == LaneRowSegments(
        incoming: [edge(0, "f2", "f1", 0)], passThrough: [edge(1, "m2", "m1", 0)],
        outgoing: [edge(0, "f1", "m1", 0)]))

    let m1 = segments[3]
    #expect(m1 == LaneRowSegments(
        incoming: [edge(0, "f1", "m1", 0), edge(1, "m2", "m1", 0)], passThrough: [],
        outgoing: [edge(0, "m1", "root", 0)]))

    let root = segments[4]
    #expect(root == LaneRowSegments(
        incoming: [edge(0, "m1", "root", 0)], passThrough: [],
        outgoing: []))
}

@Test func incomingAndPassThroughAreOrderedByLane() {
    // Two open edges crossing the middle row were opened in the order
    // lane 1 then lane 0 (`open` is append order, not lane order); a third
    // opens at lane 2 below them. Every drawn list must come back sorted
    // by lane regardless of how `open` was built.
    let rows = [
        GraphRow(oid: "root", parents: ["x", "y"], lane: 0, parentLanes: [0, 1]),
        GraphRow(oid: "c", parents: ["mid"], lane: 2, parentLanes: [2]),
        GraphRow(oid: "x", parents: ["mid"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "y", parents: ["mid"], lane: 1, parentLanes: [1]),
        GraphRow(oid: "mid", parents: [], lane: 0, parentLanes: []),
    ]
    let segments = LaneSegments.make(rows)
    // At "c": both root edges pass through, open in lane 1 then lane 0.
    #expect(segments[1].passThrough.map(\.lane) == [0, 1])
    #expect(segments[1].passThrough.map(\.child) == ["root", "root"])
    // At "mid": x's (lane 0), y's (lane 1), c's (lane 2) all converge.
    #expect(segments[4].incoming.map(\.lane) == [0, 1, 2])
    #expect(segments[4].incoming.map(\.child) == ["x", "y", "c"])
}

@Test func emptyRowsProduceEmptySegments() {
    #expect(LaneSegments.make([]).isEmpty)
    let lone = LaneSegments.make([
        GraphRow(oid: "only", parents: [], lane: 0, parentLanes: []),
    ])
    #expect(lone.count == 1)
    #expect(lone[0] == LaneRowSegments(incoming: [], passThrough: [], outgoing: []))
}

@Test func aTipDrawsNoIncomingEdge() {
    // The newest row of a linear history has nothing above it: `incoming`
    // empty is the "no line above a tip" rule, stated as data.
    let rows = [
        GraphRow(oid: "tip", parents: ["base"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "base", parents: [], lane: 0, parentLanes: []),
    ]
    let segments = LaneSegments.make(rows)
    #expect(segments[0].incoming.isEmpty)
    #expect(segments[0].outgoing.map(\.parent) == ["base"])
    #expect(segments[1].incoming.map(\.child) == ["tip"])
}
