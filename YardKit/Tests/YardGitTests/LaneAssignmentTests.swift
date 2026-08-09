// LaneAssignmentTests.swift — commit DAG lane assignment (#0015)

import Foundation
import Testing
@testable import YardGit

// MARK: - Helpers

/// The row of the fixture commit built under `name`. `#require` cannot be
/// nested inside another macro expansion, so lookups are hoisted here.
private func row(_ name: String, _ repo: FixtureRepository,
                 _ rows: [GraphRow]) throws -> GraphRow {
    let oid = try #require(repo.oids[name], "fixture has no commit named \(name)")
    return try #require(rows.first { $0.oid == oid }, "no row for \(name)")
}

/// The widest column any row or edge touches — the graph's lane count minus 1.
private func maxLane(_ rows: [GraphRow]) -> Int {
    rows.map { row in max(row.lane, row.parentLanes.max() ?? 0) }.max() ?? 0
}

/// One commit with an explicit committer date, so topological ties are
/// impossible and the emission order the test asserts is forced.
private func datedCommit(_ name: String, date: String,
                         in repo: FixtureRepository, git: GitProcess) throws -> String {
    try repo.writeUntracked([name + ".txt": name + "\n"])
    try git.run(["add", "-A"], workingDirectory: repo.url.path)
    try git.run(["commit", "-q", "-m", name],
                workingDirectory: repo.url.path,
                extraEnvironment: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date])
    return try repo.revParse("HEAD")
}

// MARK: - Fixture-backed

@Test(arguments: FixtureRepository.RefFormat.supported())
func linearHistoryOccupiesOneLane(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository.linear(refFormat: format)
    defer { repo.destroy() }

    let rows = try graphRows(at: repo.url.path)
    #expect(rows.map(\.oid) == [repo.oids["c"], repo.oids["b"], repo.oids["a"]].compactMap { $0 })
    #expect(rows.map(\.lane) == [0, 0, 0])
    #expect(rows.map(\.parentLanes) == [[0], [0], []])

    // Deterministic: a second listing reports identical rows.
    let again = try graphRows(at: repo.url.path)
    #expect(again == rows)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func branchAndMergeUsesTwoLanes(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository.merged(refFormat: format)
    defer { repo.destroy() }
    let rows = try graphRows(at: repo.url.path)

    let merge = try row("merge", repo, rows)
    let b = try row("b", repo, rows)
    let side = try row("side", repo, rows)
    let a = try row("a", repo, rows)
    #expect(merge.lane == 0)
    #expect(merge.parentLanes == [0, 1])  // first parent b straight down, side to lane 1
    #expect(b.lane == 0)
    #expect(side.lane == 1)
    // The shared base converges into the leftmost awaiting lane.
    #expect(a.lane == 0)
    #expect(maxLane(rows) == 1)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func octopusMergeFansOutAndConverges(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository.octopus(refFormat: format)
    defer { repo.destroy() }
    let rows = try graphRows(at: repo.url.path)

    let octo = try row("octo", repo, rows)
    let x = try row("x", repo, rows)
    let y = try row("y", repo, rows)
    let z = try row("z", repo, rows)
    let base = try row("base", repo, rows)
    #expect(octo.lane == 0)
    #expect(octo.parentLanes == [0, 1, 2])  // one lane per parent, in parent order
    #expect(x.lane == 0)
    #expect(y.lane == 1)
    #expect(z.lane == 2)
    #expect(base.lane == 0)
    #expect(maxLane(rows) == 2)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func sharedSecondParentReusesItsAwaitingLane(format: FixtureRepository.RefFormat) throws {
    // Two merges of the same branch: m1 and m2 both carry `side` as their
    // second parent. When m1 is reached, a lane is already awaiting `side`
    // (opened at m2's row) — the edge must join it, not open another lane.
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.build([.init("side", parents: ["base"])])
    try repo.build([.init("a", parents: ["base"])])
    try repo.build([.init("b", parents: ["base"])])
    try repo.build([.init("m1", parents: ["a", "side"])])
    try repo.build([.init("m2", parents: ["b", "side"])])
    try repo.build([.init("tip", parents: ["m1", "m2"])])

    let rows = try graphRows(at: repo.url.path)
    let side = try row("side", repo, rows)
    let m1 = try row("m1", repo, rows)
    #expect(side.lane == 2)
    #expect(m1.parentLanes == [0, 2])  // side's edge joins lane 2
    #expect(maxLane(rows) == 2)        // a lane leak would make this 3
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func crissCrossMergesShareTwoLanes(format: FixtureRepository.RefFormat) throws {
    // b and s each merge the other (x = b+s, y = s+b), and z merges the two
    // results — the classic criss-cross. Correct assignment needs only
    // three columns, and both merge rows route their second parents into
    // lanes that later converge.
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([.init("base")])
    try repo.build([.init("b", parents: ["base"])])
    try repo.build([.init("s", parents: ["base"])])
    try repo.build([.init("x", parents: ["b", "s"])])
    try repo.build([.init("y", parents: ["s", "b"])])
    try repo.build([.init("z", parents: ["x", "y"])])

    let rows = try graphRows(at: repo.url.path)
    let z = try row("z", repo, rows)
    let y = try row("y", repo, rows)
    let x = try row("x", repo, rows)
    let s = try row("s", repo, rows)
    let b = try row("b", repo, rows)
    let base = try row("base", repo, rows)
    #expect(z.lane == 0)
    #expect(y.lane == 1)
    #expect(y.parentLanes == [1, 2])
    #expect(x.lane == 0)
    #expect(x.parentLanes == [0, 1])
    #expect(s.lane == 1)
    #expect(b.lane == 0)
    #expect(base.lane == 0)
    #expect(maxLane(rows) == 2)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func topoOrderKeepsEachBranchContiguous(format: FixtureRepository.RefFormat) throws {
    // Committer dates force default (date) order to interleave the two
    // branches: m, b2, a2, b1, a1. Topological order keeps each branch's
    // commits together: m, b2, b1, a2, a1 — measured. Only the row order
    // distinguishes the two here, so the row order is the assertion.
    let repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    let git = GitProcess()
    let a1 = try datedCommit("a1", date: "2026-01-01T00:00:01Z", in: repo, git: git)
    let a2 = try datedCommit("a2", date: "2026-01-01T00:00:03Z", in: repo, git: git)
    try repo.checkoutDetached(a1)
    let b1 = try datedCommit("b1", date: "2026-01-01T00:00:02Z", in: repo, git: git)
    let b2 = try datedCommit("b2", date: "2026-01-01T00:00:04Z", in: repo, git: git)
    try repo.checkoutDetached(a2)
    _ = try git.capture(["merge", "--no-ff", "--no-commit", b2],
                        workingDirectory: repo.url.path)
    let m = try datedCommit("m", date: "2026-01-01T00:00:05Z", in: repo, git: git)

    let rows = try graphRows(at: repo.url.path)
    #expect(rows.map(\.oid) == [m, b2, b1, a2, a1])
    #expect(rows.map(\.lane) == [0, 1, 1, 0, 0])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func windowLimitBoundsTheRowCount(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository.linear(refFormat: format)
    defer { repo.destroy() }

    let rows = try graphRows(at: repo.url.path, limit: 2)
    #expect(rows.count == 2)
    #expect(rows.map(\.oid) == [repo.oids["c"], repo.oids["b"]].compactMap { $0 })
    // b's parent a is outside the window; its edge still leaves the row so
    // a renderer can draw it running off the bottom.
    #expect(rows.last?.parents == [repo.oids["a"]].compactMap { $0 })
    #expect(rows.last?.parentLanes == [0])
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func orphanRootReusesAFreedLane(format: FixtureRepository.RefFormat) throws {
    // Two unrelated histories, dated so the main chain is emitted first.
    // Its root frees lane 0, and the orphan chain reuses it: four rows,
    // one column.
    let repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    let git = GitProcess()
    let a1 = try datedCommit("a1", date: "2026-01-01T00:00:03Z", in: repo, git: git)
    let a2 = try datedCommit("a2", date: "2026-01-01T00:00:04Z", in: repo, git: git)
    try git.run(["checkout", "-q", "--orphan", "orphan"], workingDirectory: repo.url.path)
    try git.run(["rm", "-rfq", "."], workingDirectory: repo.url.path)
    let o1 = try datedCommit("o1", date: "2026-01-01T00:00:01Z", in: repo, git: git)
    let o2 = try datedCommit("o2", date: "2026-01-01T00:00:02Z", in: repo, git: git)
    #expect(a1 != o1)

    let rows = try graphRows(at: repo.url.path, revisions: [a2, o2])
    #expect(rows.map(\.oid) == [a2, a1, o2, o1])
    #expect(rows.map(\.lane) == [0, 0, 0, 0])
    #expect(maxLane(rows) == 0)
}

@Test(arguments: FixtureRepository.RefFormat.supported())
func unbornRepositoryThrows(format: FixtureRepository.RefFormat) throws {
    let repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }

    // `git rev-list HEAD` on an unborn branch is `fatal: bad revision
    // 'HEAD'`, exit 128 — surfaced, not swallowed into an empty graph.
    #expect(throws: GitProcess.Failure.self) {
        try graphRows(at: repo.url.path)
    }
}

// MARK: - Pure lane assignment (literal inputs)

@Test func exactRowsForALiteralCrissCross() {
    // The criss-cross DAG in the emission order git was measured to use,
    // with every expected row written out. Any change to lane choice,
    // convergence, inheritance, or edge routing moves at least one value.
    let nodes = [
        GraphNode(oid: "z", parents: ["x", "y"]),
        GraphNode(oid: "y", parents: ["s", "b"]),
        GraphNode(oid: "x", parents: ["b", "s"]),
        GraphNode(oid: "s", parents: ["base"]),
        GraphNode(oid: "b", parents: ["base"]),
        GraphNode(oid: "base", parents: []),
    ]
    let expected = [
        GraphRow(oid: "z", parents: ["x", "y"], lane: 0, parentLanes: [0, 1]),
        GraphRow(oid: "y", parents: ["s", "b"], lane: 1, parentLanes: [1, 2]),
        GraphRow(oid: "x", parents: ["b", "s"], lane: 0, parentLanes: [0, 1]),
        GraphRow(oid: "s", parents: ["base"], lane: 1, parentLanes: [1]),
        GraphRow(oid: "b", parents: ["base"], lane: 0, parentLanes: [0]),
        GraphRow(oid: "base", parents: [], lane: 0, parentLanes: []),
    ]
    #expect(LaneAssigner.assign(nodes) == expected)
}

@Test func laneClosedByConvergenceIsReused() throws {
    // r's row converges lanes 0 and 1; lane 1 closes there and must be free
    // again when tip t arrives one row later. If convergence failed to
    // close it, t would be pushed out to lane 2.
    let nodes = [
        GraphNode(oid: "m", parents: ["a", "b"]),
        GraphNode(oid: "a", parents: ["r"]),
        GraphNode(oid: "b", parents: ["r"]),
        GraphNode(oid: "r", parents: ["q"]),
        GraphNode(oid: "t", parents: ["q"]),
        GraphNode(oid: "q", parents: []),
    ]
    let rows = LaneAssigner.assign(nodes)
    let r = try #require(rows.first { $0.oid == "r" })
    let t = try #require(rows.first { $0.oid == "t" })
    let q = try #require(rows.first { $0.oid == "q" })
    #expect(r.lane == 0)
    #expect(t.lane == 1)
    #expect(q.lane == 0)
    #expect(maxLane(rows) == 1)
}

@Test func rootCommitFreesItsLaneForReuse() {
    // Two single-commit histories: the first root closes lane 0, and the
    // second occupies it instead of opening lane 1.
    let rows = LaneAssigner.assign([
        GraphNode(oid: "a", parents: []),
        GraphNode(oid: "b", parents: []),
    ])
    #expect(rows.map(\.lane) == [0, 0])
    #expect(rows.map(\.parentLanes) == [[], []])
}

// MARK: - Parser (measured literals)

@Test func parserReadsOidsAndParents() throws {
    // Verbatim `git rev-list --topo-order --parents` output from a measured
    // branch-and-merge repository: merge, side, b, root.
    let text = """
    371ca71448b11b86e031b7b2befd68b37dcf6fc3 b13a957168d23180638ed0990a917389c6405211 ddb5354110e2fa720d3ea52e0ce3994f502767f9
    ddb5354110e2fa720d3ea52e0ce3994f502767f9 2c62f014defa6b518815d9795b9493632e1248ef
    b13a957168d23180638ed0990a917389c6405211 2c62f014defa6b518815d9795b9493632e1248ef
    2c62f014defa6b518815d9795b9493632e1248ef

    """
    let nodes = try RevListParser().parse(text)
    #expect(nodes.count == 4)
    #expect(nodes[0].oid == "371ca71448b11b86e031b7b2befd68b37dcf6fc3")
    #expect(nodes[0].parents == [
        "b13a957168d23180638ed0990a917389c6405211",
        "ddb5354110e2fa720d3ea52e0ce3994f502767f9",
    ])
    #expect(nodes[3].parents.isEmpty)

    // And the assignment over it matches the fixture-backed shape.
    let rows = LaneAssigner.assign(nodes)
    #expect(rows.map(\.lane) == [0, 1, 0, 0])
}

@Test func parserThrowsOnAMalformedLine() {
    #expect(throws: RevListParser.Failure.self) {
        try RevListParser().parse("not a rev-list line\n")
    }
    // A truncated oid is malformed too, not "close enough".
    #expect(throws: RevListParser.Failure.self) {
        try RevListParser().parse("371ca71448b11b86e031b7b2befd68b37dcf6fc\n")
    }
}

@Test func parserReturnsNoNodesForEmptyOutput() throws {
    let nodes = try RevListParser().parse("")
    #expect(nodes.isEmpty)
}
// MARK: - Journal refs exclusion from graph (#0157)

/// Build a snapshot commit that `refs/switchyard/*` makes reachable via
/// `--all`, and write it to refs/switchyard/journal/<id>. No JournalAnchor
/// API is exercised — only raw git commands to instrument the repo state.
private func buildJournalSnapshot(in repo: FixtureRepository, id: JournalEntryID) throws -> String {
    let git = GitProcess()

    // Need a tree with at least the transaction file + metadata.json. The
    // simplest route is to modify HEAD's working tree temporarily so the
    // snapshot commit gets a non-trivial shape.
    try repo.writeUntracked(["transaction.md": "journal target\n"])

    let transactionBlob = try git.run(
        ["hash-object", "-w", "--stdin"],
        workingDirectory: repo.url.path,
        standardInput: Data("journal target\n".utf8))

    // Build metadata blob the way a real snapshot would.
    let metaBlob = try git.run(
        ["hash-object", "-w", "--stdin"],
        workingDirectory: repo.url.path,
        standardInput: Data("{\"schemaVersion\":1,\"operation\":\"probe\"}\n".utf8))

    // Tree with both files: mode + hash + filename \t path\n
    let treeInput = "100644 blob \(transactionBlob.lines.first.map(String.init) ?? "")\ttransaction.md\n100644 blob \(metaBlob.lines.first.map(String.init) ?? "")\tmetadata.json\n"
    let tree = try git.run(["mktree"], workingDirectory: repo.url.path,
                           standardInput: Data(treeInput.utf8))

    let parentArgs = ["-p", try repo.revParse("HEAD")]
    let snapshotOid = try git.run(
        ["commit-tree", tree.lines.first.map(String.init)!, "-m", "snapshot \(id.string)", parentArgs].joined(separator: " "),
        workingDirectory: repo.url.path,
        extraEnvironment: ["GIT_AUTHOR_NAME": "v", "GIT_AUTHOR_EMAIL": "v@invalid",
                           "GIT_COMMITTER_NAME": "v", "GIT_COMMITTER_EMAIL": "v@invalid"])
    .lines.first.map(String.init).map { $0 } ?? ""

    try git.run(["update-ref", JournalAnchor.refPrefix + "journal/" + id.string, snapshotOid],
                workingDirectory: repo.url.path)

    

    return snapshotOid
}

@Test func allocationTakesTheLeftmostFreeLane() throws {






@Test(arguments: FixtureRepository.RefFormat.supported())
func journalSnapshotIsExcludedFromAll(format: FixtureRepository.RefFormat) throws {
    var repo = try FixtureRepository(refFormat: format)
    defer { repo.destroy() }
    try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])

    let id = JournalEntryID.generate()
    let snapshotOid = try buildJournalSnapshot(in: repo, id: id)

    let rows = try graphRows(at: repo.url.path, revisions: ["--all"])
    let rowOids = rows.map(\.oid)

    #expect(!rowOids.contains(snapshotOid),
            "snapshot commit \(snapshotOid) must not appear in --all output")

    let ordinaryOids = try #require(repo.oids["a"], repo.oids["b"])
    #expect(rowOids.contains(ordinaryOids[0]), "first ordinary commit must appear in --all")
    #expect(rowOids.contains(ordinaryOids[1]), "second ordinary commit must appear in --all")
}


AllocationTakesTheLeftmostFreeLane() throws {

    // Rules 2 and 4 both say a lane is taken from the *leftmost* free slot.
    // Every other fixture here has at most one hole at a time, so leftmost


    // and rightmost coincide and the choice is unpinned. This one opens two
    // holes simultaneously: tips a, b and c take lanes 0, 1 and 2; pa and pb
    // are roots, so lanes 0 and 1 both free while lane 2 stays occupied by
    // c's edge. Tip d must then land in lane 0, not lane 1.
    //
    // Without this, allocate() could pick lanes.lastIndex(of: nil) and the
    // whole suite stays green — a graph whose columns wander for no reason
    // a reader can see, which is exactly what stable lanes exist to prevent.
    let rows = LaneAssigner.assign([
        GraphNode(oid: "a", parents: ["pa"]),
        GraphNode(oid: "b", parents: ["pb"]),
        GraphNode(oid: "c", parents: ["pc"]),
        GraphNode(oid: "pa", parents: []),
        GraphNode(oid: "pb", parents: []),
        GraphNode(oid: "d", parents: []),
    ])
    let d = try #require(rows.first { $0.oid == "d" })
    #expect(d.lane == 0)
    #expect(maxLane(rows) == 2)
}
