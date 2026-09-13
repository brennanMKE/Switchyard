// RemoteOnlyHistoryTests.swift — #0368's local-reachability rule
//
// This target imports YardUI WITHOUT `@testable`, so everything asserted
// here is reachable at exactly the access level the app target sees. The
// fixture is #0365's branch-off graph: `f2→f1→m1`, `m2→m1`, `m1→root`, in
// topological order `f2, m2, f1, m1, root`. With local tips `["m2"]` the
// measured reachability is `["m2", "m1", "root"]`, so exactly `f2>f1` and
// `f1>m1` are the dashed edges; `m2>m1` and `m1>root` stay solid.

import Testing
import YardGit
import YardUI

private let branchOffRows = [
    GraphRow(oid: "f2", parents: ["f1"], lane: 0, parentLanes: [0]),
    GraphRow(oid: "m2", parents: ["m1"], lane: 1, parentLanes: [1]),
    GraphRow(oid: "f1", parents: ["m1"], lane: 0, parentLanes: [0]),
    GraphRow(oid: "m1", parents: ["root"], lane: 0, parentLanes: [0]),
    GraphRow(oid: "root", parents: [], lane: 0, parentLanes: []),
]

/// Every edge instance the gutter strokes, with its repeats: `f2>f1` is
/// drawn by three rows (f2's outgoing, m2's pass-through, f1's incoming)
/// and `f1>m1` by two, so 10 instances in all.
private func allDrawnEdges(rows: [GraphRow]) -> [LaneEdge] {
    LaneSegments.make(rows).flatMap { $0.incoming + $0.passThrough + $0.outgoing }
}

@Test func reachabilityFromTheMainTipIsExactlyMainHistory() {
    let local = LocalReachability.oids(in: branchOffRows, from: ["m2"])
    #expect(local == Set(["m2", "m1", "root"]))
}

@Test func tipsOutsideTheLoadedWindowReachNothing() {
    let local = LocalReachability.oids(in: branchOffRows, from: ["m2", "not-in-window"])
    #expect(local == Set(["m2", "m1", "root"]))
}

@Test func exactlyF2F1AndF1M1AreDashed() {
    let local = LocalReachability.oids(in: branchOffRows, from: ["m2"])
    let allEdges = allDrawnEdges(rows: branchOffRows)
    #expect(allEdges.count == 10)

    // LaneGutterView's rule, as data: an edge is dashed when its child is
    // not locally reachable.
    let dashed = Set(allEdges.filter { !local.contains($0.child) }.map { "\($0.child)>\($0.parent)" })
    #expect(dashed == Set(["f2>f1", "f1>m1"]))

    // And the rest stays solid: every local child's edge.
    let solid = Set(allEdges.filter { local.contains($0.child) }.map { "\($0.child)>\($0.parent)" })
    #expect(solid == Set(["m2>m1", "m1>root"]))
}

@Test func localTipsReachEverythingSoNoEdgeIsDashed() {
    let local = LocalReachability.oids(in: branchOffRows, from: ["f2", "m2"])
    #expect(local == Set(["f2", "m2", "f1", "m1", "root"]))

    let allEdges = allDrawnEdges(rows: branchOffRows)
    #expect(allEdges.count == 10)
    #expect(allEdges.allSatisfy { local.contains($0.child) })
}

@Test func localTipsIsHeadOidPlusLocalBranchTipsOnly() {
    let snapshot = RefSnapshot(
        head: .symbolic(target: "refs/heads/main"),
        refs: [
            RefSnapshot.Entry(name: "refs/heads/main", oid: "m2"),
            RefSnapshot.Entry(name: "refs/heads/feature", oid: "f2"),
            RefSnapshot.Entry(name: "refs/remotes/origin/feature", oid: "f2"),
            RefSnapshot.Entry(name: "refs/tags/v1.0", oid: "root"),
        ])
    #expect(LocalReachability.localTips(refs: snapshot, headOid: "abc123") == Set(["m2", "f2", "abc123"]))
    #expect(LocalReachability.localTips(refs: snapshot, headOid: nil) == Set(["m2", "f2"]))
}
