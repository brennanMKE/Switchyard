// CommitGraphLoaderTests.swift
//
// `loadCommitGraph` is `public`, so this target imports both `YardUI` and
// `YardGit` WITHOUT `@testable`, matching `CommitHistoryLoaderTests` and
// `RepositoryLoaderTests` -- a public loader whose caller-visible members
// silently dropped to internal would still compile under `@testable`
// (#0116's failure class).

import Foundation
import Testing
import YardGit
import YardUI

@Test("loadCommitGraph reports two parent edges for a merge commit and none for its root, by value")
func loadCommitGraphReportsParentEdgesByValue() async throws {
    let repo = try FixtureRepository.merged()
    defer { repo.destroy() }

    let rows = try await loadCommitGraph(at: repo.url.path)

    // FixtureRepository.merged() builds "a" -> "b" -> "merge", with "side"
    // branching off "a" and merging into "merge" alongside "b" -- "a" is the
    // DAG's only root and "merge" its only two-parent commit.
    let mergeOid = try #require(repo.oids["merge"])
    let rootOid = try #require(repo.oids["a"])
    let merge = try #require(rows.first { $0.oid == mergeOid })
    let root = try #require(rows.first { $0.oid == rootOid })

    #expect(merge.parentLanes.count == 2)
    #expect(root.parentLanes.isEmpty)
}

@Test("both history loaders walk an unmerged side branch and return the same oid sequence")
func bothHistoryLoadersWalkUnmergedSideBranchAndAgree() async throws {
    var repo = try FixtureRepository(refFormat: .files)
    defer { repo.destroy() }

    // `a` -> `b` on `main`; `side` branches off `a` and is NOT merged back.
    // `HEAD` (main) is `b`, so a HEAD-only walk never reaches `side`.
    try repo.build([FixtureRepository.Commit("a"),
                    FixtureRepository.Commit("b", parents: ["a"])])
    try repo.build([FixtureRepository.Commit("side", parents: ["a"])])
    try repo.branch("main", at: "b")
    try repo.branch("side", at: "side")
    try repo.checkout("main")

    let sideOid = try #require(repo.oids["side"])
    let rootOid = try #require(repo.oids["a"])

    let entries = try await loadCommitHistory(at: repo.url.path)
    let rows = try await loadCommitGraph(at: repo.url.path)

    let historyOids = entries.map(\.oid)
    let graphOids = rows.map(\.oid)

    #expect(historyOids == graphOids)
    #expect(historyOids.contains(sideOid))
    #expect(historyOids.count == 3)
    // `--topo-order` guarantees a parent after its children; `a` is the
    // parent of both tips, so it must be last whatever the b/side tie-break.
    #expect(historyOids.last == rootOid)
}
