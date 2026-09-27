// BranchMapLayoutTests.swift — the branch map's staircase tree (#0411, #0426)
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

private func names(_ layout: BranchMapLayout) -> [[String]] {
    layout.headers.map { $0.chips.map(\.name) }
}

/// The lane whose chips name `branch`.
private func lane(_ layout: BranchMapLayout, _ branch: String) throws -> Int {
    try #require(layout.headers.first { $0.chips.contains { $0.name == branch } }).lane
}

/// Decision 29's promise: no connector's horizontal crosses a lane. A
/// connector across row r from lane l to its parent p crosses every lane k
/// strictly between them whose vertical reaches row r, or whose own
/// connector turns below r. A sibling's connector turning on row r itself
/// shares the line, which the decision allows.
private func crossings(_ layout: BranchMapLayout) -> Int {
    var count = 0
    for connector in layout.edges where connector.kind == .fork {
        let row = connector.to.row
        let low = min(connector.from.lane, connector.to.lane)
        let high = max(connector.from.lane, connector.to.lane)
        count += layout.edges.filter { edge in
            guard edge.from.lane > low, edge.from.lane < high else { return false }
            return edge.kind == .lane ? edge.to.row >= row : edge.to.row > row
        }.count
    }
    return count
}

@Test func theDefaultBranchOwnsLaneZeroAndStacksFromTheTopRow() throws {
    let rows = [mapRow("m3", "m2"), mapRow("m2", "m1"), mapRow("m1")]
    let layout = BranchMapLayout.make(rows: rows, refs: mapRefs(head: "main", mapRef("refs/heads/main", "m3")))
    #expect(layout.headers.map(\.tipOid) == ["m3"])
    #expect(layout.headers.map(\.isStub) == [false])
    #expect(layout.headers.map(\.parentLane) == [nil])
    #expect(layout.nodes.map(\.point) == [at(0, 0), at(0, 1), at(0, 2)])
    #expect(layout.laneCount == 1)
    #expect(layout.rowCount == 3)
    #expect(layout.edges == [BranchMapLayout.Edge(kind: .lane, from: at(0, 0), to: at(0, 2))])
}

@Test func aForkCommitSitsOneRowBelowItsChildsLowestRow() throws {
    // main: m3 -> m2 -> m1; feature: f3 -> f2 -> f1 -> m2. Feature's rows
    // are 0-2, so m2 is pushed from row 1 to row 3 and m1 follows at 4.
    let rows = [
        mapRow("f3", "f2"), mapRow("f2", "f1"), mapRow("m3", "m2"), mapRow("f1", "m2"),
        mapRow("m2", "m1"), mapRow("m1"),
    ]
    let refs = mapRefs(head: "main", mapRef("refs/heads/feature", "f3"), mapRef("refs/heads/main", "m3"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(layout) == [["main"], ["feature"]])
    #expect(layout.headers.map(\.parentLane) == [nil, 0])
    #expect(try cell(layout, "m3") == at(0, 0))
    #expect(try cell(layout, "m2") == at(0, 3))
    #expect(try cell(layout, "m1") == at(0, 4))
    #expect(try cell(layout, "f3") == at(1, 0))
    #expect(try cell(layout, "f1") == at(1, 2))
    #expect(layout.edges == [
        BranchMapLayout.Edge(kind: .lane, from: at(0, 0), to: at(0, 4)),
        BranchMapLayout.Edge(kind: .lane, from: at(1, 0), to: at(1, 2)),
        BranchMapLayout.Edge(kind: .fork, from: at(1, 2), to: at(0, 3)),
    ])
}

@Test func theDefaultBranchIsTheRootEvenWhenHeadIsOnAnotherBranch() throws {
    let rows = [mapRow("f1", "m1"), mapRow("m2", "m1"), mapRow("m1")]
    let refs = mapRefs(head: "feature", mapRef("refs/heads/feature", "f1"), mapRef("refs/heads/main", "m2"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(layout) == [["main"], ["feature"]])
    #expect(layout.headers[1].chips.first?.isHead == true)
}

@Test func aNamedDefaultBranchIsTheRootAndWithoutOneHeadIs() throws {
    let rows = [mapRow("t2", "t1"), mapRow("h1", "t1"), mapRow("t1")]
    let refs = mapRefs(head: "topic", mapRef("refs/heads/trunk", "t2"), mapRef("refs/heads/topic", "h1"))
    let named = BranchMapLayout.make(rows: rows, refs: refs, defaultBranch: "trunk")
    #expect(names(named) == [["trunk"], ["topic"]])
    // No `main` and no default named: HEAD's branch is the root.
    let fallback = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(fallback) == [["topic"], ["trunk"]])
}

@Test func childrenSitRightOfTheirParentNearestForkFirstAndNoConnectorCrosses() throws {
    // main: m0 -> m1 -> m2 -> m3. a1 forks m1, b1 forks m2, c1 forks a1.
    // Tree order: main, a (fork index 1), a's child c, then b (index 2).
    let rows = [
        mapRow("c1", "a1"), mapRow("b1", "m2"), mapRow("a1", "m1"),
        mapRow("m0", "m1"), mapRow("m1", "m2"), mapRow("m2", "m3"), mapRow("m3"),
    ]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/a", "a1"), mapRef("refs/heads/b", "b1"), mapRef("refs/heads/c", "c1"),
        mapRef("refs/heads/main", "m0"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(layout) == [["main"], ["a"], ["c"], ["b"]])
    #expect(layout.headers.map(\.parentLane) == [nil, 0, 1, 0])
    #expect(crossings(layout) == 0)
    // a1 is pushed below c1 (row 0) and m1 below a1.
    #expect(try cell(layout, "a1") == at(1, 1))
    #expect(try cell(layout, "m1") == at(0, 2))
    #expect(try cell(layout, "m2") == at(0, 3))
}

@Test func siblingsForkingFromOneCommitAreOrderedNewestTipFirst() throws {
    // `zeta` is the more recent tip (earlier in topological order) than `alpha`.
    let rows = [mapRow("z1", "m1"), mapRow("a1", "m1"), mapRow("m1")]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/alpha", "a1"), mapRef("refs/heads/main", "m1"), mapRef("refs/heads/zeta", "z1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(layout) == [["main"], ["zeta"], ["alpha"]])
    #expect(crossings(layout) == 0)
}

@Test func aBranchStackedOnAnotherHasThatBranchAsItsParent() throws {
    // base: b1 -> m1; stacked: s1 -> b1, and stacked is the newer tip.
    // base has fewer commits main does not reach, so it claims b1 first.
    let rows = [mapRow("s1", "b1"), mapRow("b1", "m1"), mapRow("m1")]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/base", "b1"), mapRef("refs/heads/main", "m1"), mapRef("refs/heads/stacked", "s1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(layout) == [["main"], ["base"], ["stacked"]])
    #expect(layout.headers.map(\.parentLane) == [nil, 0, 1])
    #expect(layout.headers.map(\.isStub) == [false, false, false])
    #expect(try cell(layout, "b1") == at(1, 1))
}

@Test func everyTipSitsOnTheTopRowWhateverItsTopologicalPosition() throws {
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
    #expect(layout.headers.count == 5)
    for header in layout.headers {
        #expect(try cell(layout, header.tipOid) == at(header.lane, 0), "lane \(header.lane)'s tip is not on row 0")
    }
    #expect(crossings(layout) == 0)
}

@Test func aRemoteBranchFoldsIntoItsLocalLaneUnlessItIsAhead() throws {
    // origin/feature is behind feature (f1): a chip on feature's lane.
    // origin/gamma is ahead of gamma (g2 -> g1): a lane of its own, a child
    // of gamma's. origin/orphan has no local namesake: a lane of its own.
    // origin/main is main's tip: one of main's chips.
    let rows = [
        mapRow("f2", "f1"), mapRow("g2", "g1"), mapRow("o1", "m1"), mapRow("g1", "m1"),
        mapRow("f1", "m1"), mapRow("m1"),
    ]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/main", "m1"), mapRef("refs/heads/feature", "f2"), mapRef("refs/heads/gamma", "g1"),
        mapRef("refs/remotes/origin/HEAD", "m1"), mapRef("refs/remotes/origin/main", "m1"),
        mapRef("refs/remotes/origin/feature", "f1"), mapRef("refs/remotes/origin/gamma", "g2"),
        mapRef("refs/remotes/origin/orphan", "o1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(Set(names(layout)) == [
        ["main", "origin/main"], ["feature", "origin/feature"], ["gamma"], ["origin/gamma"], ["origin/orphan"],
    ])
    #expect(layout.headers.first { $0.chips.first?.name == "origin/gamma" }?.parentLane == (try lane(layout, "gamma")))
    #expect(layout.headers.filter(\.isRemoteOnly).map { $0.chips[0].name }.sorted() == ["origin/gamma", "origin/orphan"])
}

@Test func refsAtOneCommitShareOneLane() throws {
    let rows = [mapRow("m2", "m1"), mapRow("m1")]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/main", "m2"), mapRef("refs/heads/spike", "m2"),
        mapRef("refs/remotes/origin/main", "m2"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(layout) == [["main", "spike", "origin/main"]])
    #expect(layout.headers[0].chips.first?.isHead == true)
}

@Test func aBranchBehindMainIsAStubWithOneConnectorToItsTip() throws {
    let rows = [mapRow("m3", "m2"), mapRow("m2", "m1"), mapRow("m1")]
    let refs = mapRefs(head: "main", mapRef("refs/heads/main", "m3"), mapRef("refs/heads/older", "m1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map(\.isStub) == [false, true])
    #expect(layout.headers.map(\.parentLane) == [nil, 0])
    #expect(!layout.nodes.contains { $0.lane == 1 })
    #expect(layout.edges.filter { $0.from.lane == 1 }
        == [BranchMapLayout.Edge(kind: .fork, from: at(1, 0), to: at(0, 2))])
}

@Test func historyMergedFromADeletedBranchIsNotDrawn() throws {
    // main: M (merge of m1 and s2) -> m1 -> root; s2 -> s1 -> root, no ref.
    let rows = [mapRow("M", "m1", "s2"), mapRow("s2", "s1"), mapRow("s1", "root"), mapRow("m1", "root"), mapRow("root")]
    let layout = BranchMapLayout.make(rows: rows, refs: mapRefs(head: "main", mapRef("refs/heads/main", "M")))
    #expect(layout.laneCount == 1)
    #expect(layout.nodes.map(\.oid) == ["M", "m1", "root"])
    #expect(layout.nodes.map(\.point) == [at(0, 0), at(0, 1), at(0, 2)])
    #expect(layout.edges.map(\.kind) == [.lane])
}

@Test func aDetachedHeadIsALaneWithAHeadChipUnderTheDefaultBranch() throws {
    let rows = [mapRow("d1", "m1"), mapRow("m1")]
    let refs = RefSnapshot(head: .detached(oid: "d1"), refs: [mapRef("refs/heads/main", "m1")])
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(layout.headers.map { $0.chips.map(\.kind) } == [[.localBranch], [.detachedHead]])
    #expect(try cell(layout, "d1") == at(1, 0))
    #expect(try cell(layout, "m1") == at(0, 1))
}

@Test func anUnrelatedHistoryIsASecondRootAfterTheFirstRootsTree() throws {
    // pages has no commit in common with main.
    let rows = [mapRow("p1"), mapRow("f1", "m1"), mapRow("m2", "m1"), mapRow("m1")]
    let refs = mapRefs(
        head: "main",
        mapRef("refs/heads/feature", "f1"), mapRef("refs/heads/main", "m2"), mapRef("refs/heads/pages", "p1"))
    let layout = BranchMapLayout.make(rows: rows, refs: refs)
    #expect(names(layout) == [["main"], ["feature"], ["pages"]])
    #expect(layout.headers.map(\.parentLane) == [nil, 0, nil])
    #expect(!layout.edges.contains { $0.from.lane == 2 })
}

@Test func withoutRefsTheFirstRowsFirstParentChainIsOneUnlabelledLane() throws {
    let rows = [mapRow("c3", "c2", "x1"), mapRow("x1", "c1"), mapRow("c2", "c1"), mapRow("c1")]
    let layout = BranchMapLayout.make(rows: rows, refs: nil)
    #expect(layout.headers.isEmpty)
    #expect(layout.nodes.map(\.oid) == ["c3", "c2", "c1"])
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
