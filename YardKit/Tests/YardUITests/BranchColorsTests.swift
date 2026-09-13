// BranchColorsTests.swift — per-branch colour and ownership (#0366)
//
// This target imports YardUI WITHOUT `@testable`, same idiom as
// LaneSegmentsTests: everything asserted here is reachable at exactly the
// access level the app target sees. Every pinned index and owner is a
// result from #0366's measured table.

import SwiftUI
import Testing
import YardGit
import YardUI

private func tip(_ name: String, _ oid: String, remote: Bool = false) -> BranchTip {
    BranchTip(name: name, oid: oid, isRemote: remote)
}

private func ref(_ name: String, _ oid: String) -> RefSnapshot.Entry {
    RefSnapshot.Entry(name: name, oid: oid)
}

@Test func tipsOrderIsHeadBranchThenLocalsThenRemotes() {
    let refs = RefSnapshot(
        head: .symbolic(target: "refs/heads/main"),
        refs: [
            ref("refs/remotes/origin/HEAD", "r0"),
            ref("refs/remotes/origin/feature", "r1"),
            ref("refs/heads/feature", "f1"),
            ref("refs/heads/main", "m1"),
        ])
    let tips = BranchOwnership.tips(from: refs)
    #expect(tips.map(\.name) == ["main", "feature", "origin/feature"])
    #expect(tips.map(\.isRemote) == [false, false, true])
    #expect(tips.map(\.oid) == ["m1", "f1", "r1"])
}

@Test func aDetachedHeadTipsFirstAndClaimsItsChain() {
    let refs = RefSnapshot(
        head: .detached(oid: "d0"),
        refs: [ref("refs/heads/main", "m1")])
    let tips = BranchOwnership.tips(from: refs)
    #expect(tips.map(\.name) == ["HEAD", "main"])

    let rows = [
        GraphRow(oid: "d0", parents: ["m1"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "m1", parents: [], lane: 0, parentLanes: []),
    ]
    let owners = BranchOwnership.owners(in: rows, tips: tips)
    #expect(owners["d0"]?.name == "HEAD")
    #expect(owners["m1"]?.name == "HEAD")
}

@Test func branchOffOwnershipMatchesTheMeasuredTable() throws {
    // #0365's fixture: `main` at m2, `feature` at f2. main claims its
    // first-parent chain m2, m1, root; feature claims f2, f1 and stops at
    // the already-claimed m1.
    let rows = [
        GraphRow(oid: "f2", parents: ["f1"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "m2", parents: ["m1"], lane: 1, parentLanes: [1]),
        GraphRow(oid: "f1", parents: ["m1"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "m1", parents: ["root"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "root", parents: [], lane: 0, parentLanes: []),
    ]
    let main = tip("main", "m2")
    let feature = tip("feature", "f2")
    let owners = BranchOwnership.owners(in: rows, tips: [main, feature])
    #expect(owners["m2"] == main)
    #expect(owners["m1"] == main)
    #expect(owners["root"] == main)
    #expect(owners["f2"] == feature)
    #expect(owners["f1"] == feature)

    let segments = LaneSegments.make(rows)
    // The converging edge f1>m1, drawn in row m1's gutter, belongs to the
    // child's branch -- feature -- even though m1 itself is main's.
    let converging = try #require(segments[3].incoming.first { $0.child == "f1" && $0.parent == "m1" })
    #expect(BranchOwnership.owner(of: converging, in: owners) == feature)
    // The same edge crossing row m2 is owned the same way.
    let crossing = try #require(segments[1].passThrough.first { $0.child == "f2" && $0.parent == "f1" })
    #expect(BranchOwnership.owner(of: crossing, in: owners) == feature)
}

@Test func mergeEdgeBelongsToTheBranchOwningTheMergedParent() throws {
    // c3 -> c2 (merge of c1, s1) -> c1 -> root, and s1 -> root, tips
    // main=c3 and side=s1.
    let rows = [
        GraphRow(oid: "c3", parents: ["c2"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "c2", parents: ["c1", "s1"], lane: 0, parentLanes: [0, 1]),
        GraphRow(oid: "s1", parents: ["root"], lane: 1, parentLanes: [1]),
        GraphRow(oid: "c1", parents: ["root"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "root", parents: [], lane: 0, parentLanes: []),
    ]
    let main = tip("main", "c3")
    let side = tip("side", "s1")

    let withSide = BranchOwnership.owners(in: rows, tips: [main, side])
    #expect(withSide["s1"] == side)
    let segments = LaneSegments.make(rows)
    let mergeEdge = try #require(segments[1].outgoing.first { $0.parentIndex == 1 })
    #expect(mergeEdge.child == "c2")
    #expect(mergeEdge.parent == "s1")
    // The merge edge c2>s1#1 belongs to the branch owning the merged
    // parent -- side -- in both rows it spans.
    #expect(BranchOwnership.owner(of: mergeEdge, in: withSide) == side)
    let arriving = try #require(segments[2].incoming.first { $0.child == "c2" && $0.parent == "s1" })
    #expect(BranchOwnership.owner(of: arriving, in: withSide) == side)

    // Without the side tip, s1 is unowned and the edge falls back to the
    // child's branch, main.
    let mainOnly = BranchOwnership.owners(in: rows, tips: [main])
    #expect(mainOnly["s1"] == nil)
    #expect(BranchOwnership.owner(of: mergeEdge, in: mainOnly) == main)
}

@Test func remoteColorKeyDropsTheRemoteSegment() {
    #expect(tip("origin/feature", "x", remote: true).colorKey == "feature")
    #expect(tip("origin/main", "x", remote: true).colorKey == "main")
    #expect(tip("feature", "x").colorKey == "feature")
}

@Test func colourIndicesArePinnedForStabilityAcrossLaunchesAndMachines() {
    #expect(BranchColor.palette.count == 10)
    #expect(BranchColor.index(forKey: "main") == 6)
    #expect(BranchColor.index(forKey: "feature") == 9)
    #expect(BranchColor.index(forKey: "issue/0404") == 5)
    #expect(BranchColor.index(forKey: "issue/0364") == 8)
    #expect(BranchColor.index(forKey: "HEAD") == 1)
}

@Test func unownedHistoryDrawsSecondaryAndOwnedDrawsThePinnedPaletteEntry() {
    #expect(BranchColor.color(for: nil) == .secondary)
    #expect(BranchColor.color(for: tip("main", "x")) == BranchColor.palette[6])
    #expect(BranchColor.color(for: tip("feature", "x")) == BranchColor.palette[9])
    #expect(BranchColor.color(for: tip("origin/feature", "x", remote: true))
            == BranchColor.color(for: tip("feature", "x")))
}

@Test func ownerAndColourAreIndependentOfLaneAssignment() throws {
    let refs = RefSnapshot(
        head: .symbolic(target: "refs/heads/main"),
        refs: [ref("refs/heads/main", "m2"), ref("refs/heads/feature", "f2")])
    let tips = BranchOwnership.tips(from: refs)

    // The same DAG laid out twice, tips emitted in a different order, so
    // LaneAssigner puts feature in a different lane.
    let nodesA = [
        GraphNode(oid: "f2", parents: ["f1"]),
        GraphNode(oid: "m2", parents: ["m1"]),
        GraphNode(oid: "f1", parents: ["m1"]),
        GraphNode(oid: "m1", parents: ["root"]),
        GraphNode(oid: "root", parents: []),
    ]
    let nodesB = [
        GraphNode(oid: "m2", parents: ["m1"]),
        GraphNode(oid: "f2", parents: ["f1"]),
        GraphNode(oid: "m1", parents: ["root"]),
        GraphNode(oid: "f1", parents: ["m1"]),
        GraphNode(oid: "root", parents: []),
    ]
    let rowsA = LaneAssigner.assign(nodesA)
    let rowsB = LaneAssigner.assign(nodesB)
    let f2A = try #require(rowsA.first { $0.oid == "f2" })
    let f2B = try #require(rowsB.first { $0.oid == "f2" })
    #expect(f2A.lane != f2B.lane)

    let ownersA = BranchOwnership.owners(in: rowsA, tips: tips)
    let ownersB = BranchOwnership.owners(in: rowsB, tips: tips)
    #expect(ownersA.count == 5)
    #expect(ownersA.keys == ownersB.keys)
    for oid in rowsA.map(\.oid) {
        let a = try #require(ownersA[oid])
        let b = try #require(ownersB[oid])
        #expect(a == b)
        #expect(BranchColor.color(for: a) == BranchColor.color(for: b))
        #expect(BranchColor.index(forKey: a.colorKey) == BranchColor.index(forKey: b.colorKey))
    }
}
