// CommitHistoryLoaderTests.swift
//
// `loadCommitHistory` is `public`, so this target imports both `YardUI` and
// `YardGit` WITHOUT `@testable`, matching `RepositoryLoaderTests` — a public
// loader whose caller-visible members silently dropped to internal would
// still compile under `@testable` (#0116's failure class).

import Foundation
import Testing
import YardGit
import YardUI

@Test("loadCommitHistory returns commit subjects newest first for a fixture repository")
func loadCommitHistoryReturnsSubjectsNewestFirst() async throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    let entries = try await loadCommitHistory(at: repo.url.path)

    // FixtureRepository.linear() builds "a" -> "b" -> "c" on `main`, each
    // commit's message equal to its name (FixtureRepository.Commit.init).
    // `git log HEAD` (no `--reverse`) lists newest first, so the subjects
    // must read "c", "b", "a" -- a bare `count == 3` assertion would still
    // pass if the order came back reversed.
    #expect(entries.map(\.subject) == ["c", "b", "a"])
}
