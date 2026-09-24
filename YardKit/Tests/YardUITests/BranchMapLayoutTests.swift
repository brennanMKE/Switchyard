// BranchMapLayoutTests.swift — the branch map's lanes and rows (#0411)
//
// Public-API import, same idiom as BranchColorsTests. Every DAG here is
// hand-written in topological order (children first), the order
// `graphRows` returns. `lane` and `parentLanes` are irrelevant to the
// branch map and are passed as 0.

import Testing
import YardGit
import YardUI

private func mapRow(_ oid: String, _ parents: String...) -> GraphRow {
    GraphRow(oid: oid, parents: parents, lane: 0, parentLanes: parents.map { _ in 0 })
}

private func mapRef(_ name: String, _ oid: String) -> RefSnapshot.Entry {
    RefSnapshot.Entry(name: name, oid: oid)
}

private func mapRefs(head: String, _ entries: RefSnapshot.Entry...) -> RefSnapshot {
    RefSnapshot(head: .symbolic(target: "refs/heads/\(head)"), refs: entries)
}

private func cell(_ layout: BranchMapLayout, _ oid: String) throws -> BranchMapLayout.Point {
    try #require(layout.nodes.first { $0.oid == oid }).point
}

private func at(_ lane: Int, _ row: Int) -> BranchMapLayout.Point {
    BranchMapLayout.Point(lane: lane, row: row)
}

@Test func theHeadBranchOwnsLaneZeroAndStacksFromTheTopRow() throws {
    let rows = [mapRow("m3", "m2"), mapRow("m2", "m1"), mapRow("m1")]
    let layout = BranchMapLayout.make(rows: rows, refs: mapRefs(head: "main", mapRef("refs/heads/main", "m3")))
    #expect(layout.headers.map(\.tipOid) == ["m3"])
    #expect(layout.headers.map(\.isStub) == [false])
    #expect(try cell(layout, "m3") == at(0, 0))
    #expect(try cell(layout, "m2") == at(0, 1))
    #expect(try cell(layout, "m1") == at(0, 2))
    #expect(layout.laneCount == 1)
    #expect(layout.rowCount == 3)
    #expect(layout.edges.map(\.kind) == [.chain, .chain])
}

@Test func aFeatureBranchGetsItsOwnLaneFromTheTopRowAndForksDownToMain() throws {
    // main: m3 -> m2 -> m1 -> root; feature: f2 -> f1 -> m1.
    let rows = [
        mapRow("f2", "f1"), mapRow("m3", "m2"), mapRow("f1", "m1"),
        mapRow("m2", "m1"), mapRow("m1", "root"), mapRow("root"),
    ]
    let refs = mapRefs(head: "main", mapRef("refs/heads/feature", "f2"), mapRef("refs/heads/main", "m3"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map { $0.chips.map(\.name) } == [["main"], ["feature"]])
    #expect(try cell(layout, "m1") == at(0, 2))
    #expect(try cell(layout, "f2") == at(1, 0))
    #expect(try cell(layout, "f1") == at(1, 1))
    let fork = try #require(layout.edges.first { $0.childOid == "f1" })
    #expect(fork.kind == .fork)
    #expect(fork.from == at(1, 1))
    #expect(fork.to == at(0, 2))
    #expect(fork.parentOid == "m1")
}

@Test func everyLabelledTipSitsOnTheTopRowWhateverItsTopologicalPosition() throws {
    // Four branches forking from main at increasing depth; in topological
    // order their tips are rows 0, 3, 6 and 9 of the input.
    var rows: [GraphRow] = []
    var refs: [RefSnapshot.Entry] = [mapRef("refs/heads/main", "m0")]
    rows.append(mapRow("m0", "m1"))
    for depth in 1...4 {
        rows.append(mapRow("b\(depth)", "m\(depth)"))
        rows.append(mapRow("m\(depth)", "m\(depth + 1)"))
        refs.append(mapRef("refs/heads/branch-\(depth)", "b\(depth)"))
    }
    rows.append(mapRow("m5"))
    let layout = BranchMapLayout.make(
        rows: rows, refs: RefSnapshot(head: .symbolic(target: "refs/heads/main"), refs: refs))
    let tips = layout.headers.filter { !$0.isStub }
    #expect(tips.count == 5)
    for header in tips {
        let tip = try cell(layout, header.tipOid)
        #expect(tip == at(header.lane, 0), "the tip of lane \(header.lane) is not on the top row")
    }
}

@Test func lanesAfterHeadAreOrderedByRecencyNotName() throws {
    // `zeta` is the more recent tip (earlier in topological order) than `alpha`.
    let rows = [mapRow("z1", "m1"), mapRow("a1", "m1"), mapRow("m1")]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/alpha", "a1"), mapRef("refs/heads/main", "m1"), mapRef("refs/heads/zeta", "z1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map { $0.chips.map(\.name) } == [["main"], ["zeta"], ["alpha"]])
}

@Test func aRemoteOnlyLaneSitsRightAfterItsLocalNamesake() throws {
    let rows = [
        mapRow("f2", "f1"), mapRow("o1", "m1"), mapRow("g1", "m1"),
        mapRow("x1", "m1"), mapRow("f1", "m1"), mapRow("m1"),
    ]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/main", "m1"), mapRef("refs/heads/feature", "f2"), mapRef("refs/heads/gamma", "g1"),
        mapRef("refs/remotes/origin/HEAD", "m1"), mapRef("refs/remotes/origin/feature", "f1"),
        mapRef("refs/remotes/origin/orphan", "o1"), mapRef("refs/remotes/origin/xray", "x1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map { $0.chips.map(\.name) } == [
        ["main"], ["feature"], ["origin/feature"], ["gamma"], ["origin/orphan"], ["origin/xray"],
    ])
    #expect(layout.headers.map(\.isRemoteOnly) == [false, false, true, false, true, true])
    // origin/feature is behind feature: a stub pointing at f1 in feature's lane.
    #expect(layout.headers[2].isStub)
    let stub = try #require(layout.edges.first { $0.childOid == nil && $0.parentOid == "f1" })
    #expect(stub.from == at(2, 0))
    #expect(stub.to == at(1, 1))
}

@Test func refsAtOneCommitShareOneLane() throws {
    let rows = [mapRow("m2", "m1"), mapRow("m1")]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/main", "m2"), mapRef("refs/heads/spike", "m2"),
        mapRef("refs/remotes/origin/main", "m2"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.count == 1)
    #expect(layout.headers[0].chips.map(\.name) == ["main", "spike", "origin/main"])
    #expect(layout.headers[0].chips.first?.isHead == true)
}

@Test func aBranchBehindMainIsAStubOnTheTopRowWithAForkEdgeToItsTip() throws {
    let rows = [mapRow("m3", "m2"), mapRow("m2", "m1"), mapRow("m1")]
    let refs = mapRefs(head: "main", mapRef("refs/heads/main", "m3"), mapRef("refs/heads/older", "m1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map(\.isStub) == [false, true])
    #expect(layout.laneCount == 2)
    let stub = try #require(layout.edges.first { $0.childOid == nil })
    #expect(stub.kind == .fork)
    #expect(stub.from == at(1, 0))
    #expect(stub.to == at(0, 2))
    #expect(!layout.nodes.contains { $0.lane == 1 })
}

@Test func historyMergedFromADeletedBranchRunsBelowItsMergeInAnUnlabelledTrack() throws {
    // main: M (merge of m1 and s2) -> m1 -> root; s2 -> s1 -> root, no ref.
    let rows = [mapRow("M", "m1", "s2"), mapRow("s2", "s1"), mapRow("s1", "root"), mapRow("m1", "root"), mapRow("root")]
    let layout = BranchMapLayout.make(rows: rows, refs: mapRefs(head: "main", mapRef("refs/heads/main", "M")))
    #expect(layout.headers.count == 1)
    #expect(layout.laneCount == 2)
    #expect(try cell(layout, "M") == at(0, 0))
    #expect(try cell(layout, "m1") == at(0, 1))
    #expect(try cell(layout, "root") == at(0, 2))
    #expect(try cell(layout, "s2") == at(1, 1))
    #expect(try cell(layout, "s1") == at(1, 2))
    let merge = try #require(layout.edges.first { $0.childOid == "M" && $0.parentOid == "s2" })
    #expect(merge.kind == .merge)
    #expect(merge.to == at(1, 1))
    let fork = try #require(layout.edges.first { $0.childOid == "s1" })
    #expect(fork.kind == .fork)
    #expect(fork.to == at(0, 2))
}

@Test func unlabelledRunsShareATrackOnlyWhenTheirRowsDoNotOverlap() throws {
    // main: M1 -> m2 -> M3 -> M4 -> m5 (rows 0-4). M1 merges a1 (fork m2),
    // M3 merges c1 and M4 merges b1 (both fork m5). Run a occupies track
    // rows 0-1 (entry row to fork row). Run b, met first in topological
    // order, occupies rows 3-4 and reuses that track; run c occupies rows
    // 2-4, overlaps b, and opens a second track.
    let rows = [
        mapRow("M1", "m2", "a1"), mapRow("a1", "m2"),
        mapRow("m2", "M3"), mapRow("M3", "M4", "c1"),
        mapRow("M4", "m5", "b1"), mapRow("b1", "m5"), mapRow("c1", "m5"),
        mapRow("m5"),
    ]
    let layout = BranchMapLayout.make(rows: rows, refs: mapRefs(head: "main", mapRef("refs/heads/main", "M1")))
    #expect(try cell(layout, "a1") == at(1, 1))
    #expect(try cell(layout, "M3") == at(0, 2))
    #expect(try cell(layout, "M4") == at(0, 3))
    #expect(try cell(layout, "b1") == at(1, 4))
    #expect(try cell(layout, "c1") == at(2, 3))
    #expect(layout.laneCount == 3)
}

@Test func aDetachedHeadTakesTheFirstLaneWithAHeadChip() throws {
    let rows = [mapRow("d1", "m1"), mapRow("m1")]
    let refs = RefSnapshot(head: .detached(oid: "d1"), refs: [mapRef("refs/heads/main", "m1")])
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map { $0.chips.map(\.kind) } == [[.detachedHead], [.localBranch]])
    #expect(try cell(layout, "d1") == at(0, 0))
    #expect(try cell(layout, "m1") == at(0, 1))
    #expect(layout.headers[1].isStub)
}

@Test func withoutRefsEveryCommitSitsInOneUnlabelledTrackFromTheTopRow() throws {
    let rows = [mapRow("c3", "c2"), mapRow("c2", "c1"), mapRow("c1")]
    let layout = BranchMapLayout.make(rows: rows, refs: nil)
    #expect(layout.headers.isEmpty)
    #expect(layout.nodes.map(\.point) == [at(0, 0), at(0, 1), at(0, 2)])
    #expect(layout.laneCount == 1)
}

@Test func aRefOutsideTheLoadedRowsGetsNoLane() throws {
    let rows = [mapRow("m2", "m1"), mapRow("m1")]
    let refs = mapRefs(head: "main", mapRef("refs/heads/main", "m2"), mapRef("refs/heads/ancient", "zz"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map(\.tipOid) == ["m2"])
}

@Test func anEmptyHistoryHasNoRows() {
    let layout = BranchMapLayout.make(rows: [], refs: nil)
    #expect(layout.rowCount == 0)
    #expect(layout.laneCount == 0)
    #expect(layout.nodes.isEmpty)
}
