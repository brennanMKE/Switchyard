// RepositoryWindowLoaderTests.swift
//
// #0553 (guide §11 decision 44): `loadRepositoryWindow` returns what the six
// loaders it runs at once return, falls back where `ContentView.reload()`
// always fell back, and throws only for the summary. Public API, no
// @testable -- the same reason `RepositoryLoaderTests` gives.

import Foundation
import Testing
import YardGit
import YardUI

@Test("loadRepositoryWindow returns what each loader returns, and indexes the history against the refs")
func loadRepositoryWindowMatchesTheLoaders() async throws {
    var repo = try FixtureRepository.linear()
    defer { repo.destroy() }
    try repo.branch("feature", at: "b")
    try repo.addUpstream()

    let load = try await loadRepositoryWindow(at: repo.url.path)

    #expect(load.summary.whereAmI.branch == "main")
    #expect(load.history.map(\.oid) == (try await loadCommitHistory(at: repo.url.path)).map(\.oid))
    #expect(load.history.map(\.oid) == [repo.oids["c"]!, repo.oids["b"]!, repo.oids["a"]!])
    #expect(load.graphRows.map(\.oid) == load.history.map(\.oid))
    #expect(load.sidebar?.refs.refs.map(\.name).contains("refs/heads/feature") == true)
    #expect(load.remoteNames == ["origin"])
    #expect(load.journalListing != nil)
    // The index is built from this load's history and refs.
    #expect(load.historyIndex.chipsByOid[repo.oids["b"]!]?.map(\.name) == ["feature"])
    #expect(load.historyIndex.entriesByOid.count == 3)
}

@Test("an unborn branch loads its summary with an empty history rather than throwing")
func loadRepositoryWindowUnbornBranch() async throws {
    let repo = try FixtureRepository()
    defer { repo.destroy() }

    let load = try await loadRepositoryWindow(at: repo.url.path)

    #expect(load.summary.whereAmI.branch == "main")
    #expect(load.history.isEmpty)
    #expect(load.graphRows.isEmpty)
    #expect(load.historyIndex.entriesByOid.isEmpty)
    #expect(load.remoteNames.isEmpty)
}

@Test("loadRepositoryWindow throws for a folder that is not a repository")
func loadRepositoryWindowThrowsForNonRepository() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yard-window-non-repo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    await #expect(throws: (any Error).self) {
        _ = try await loadRepositoryWindow(at: directory.path)
    }
}
