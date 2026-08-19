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
