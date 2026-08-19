// RepositoryLoaderTests.swift
//
// `loadRepositorySummary` is `public`, so this target imports both `YardUI`
// and `YardGit` WITHOUT `@testable`, matching `ContentViewPublicAPITests` —
// a public loader whose caller-visible members silently dropped to internal
// would still compile under `@testable` (#0116's failure class).

import Foundation
import Testing
import YardGit
import YardUI

@Test("loadRepositorySummary returns real branch and status data for a fixture repository")
func loadRepositorySummaryReturnsRealData() async throws {
    let repo = try FixtureRepository.linear()
    defer { repo.destroy() }

    try repo.writeUntracked(["dirty.txt": "hello\n"])

    let summary = try await loadRepositorySummary(at: repo.url.path)

    #expect(summary.whereAmI.branch == "main")
    #expect(summary.whereAmI.headOID == (try repo.revParse("HEAD")).prefix(7))

    let dirty = summary.status.entries.first { $0.path == "dirty.txt" }
    #expect(dirty != nil)
    #expect(dirty?.worktree == .untracked)
    #expect(dirty?.staged == .unmodified)
}

@Test("loadRepositorySummary throws for a folder that is not a repository")
func loadRepositorySummaryThrowsForNonRepository() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yard-loader-non-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    await #expect(throws: (any Error).self) {
        _ = try await loadRepositorySummary(at: directory.path)
    }
}
