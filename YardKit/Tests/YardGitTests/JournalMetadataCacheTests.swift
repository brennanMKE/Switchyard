// JournalMetadataCacheTests.swift — the per-repository journal index (#0156)

import Foundation
import Testing
@testable import YardGit

struct JournalMetadataCacheTests {

    private static func id(_ suffix: String) throws -> JournalEntryID {
        try #require(JournalEntryID("010000000000000000000000" + suffix))
    }

    private static func row(_ id: JournalEntryID, ref: String = "refs/probe") -> JournalMetadataCache.Row {
        JournalMetadataCache.Row(
            metadata: JournalEntryMetadata(
                id: id,
                operation: "checkpoint",
                timestamp: Date(timeIntervalSince1970: 0),
                worktree: .init(name: nil, path: "/unused-by-these-tests"),
                captured: .refsOnly),
            snapshotRef: ref)
    }

    // MARK: - The cache is derived state

    /// A missing file is an EMPTY cache, not an error: absence is the ordinary
    /// post-clone condition, and #0030 rebuilds from refs alone.
    @Test func aMissingFileReadsAsAnEmptyCache() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let cache = JournalMetadataCache(context: context)

        #expect(!FileManager.default.fileExists(atPath: cache.fileURL.path),
                "the fixture must start with no cache, or this asserts nothing")
        #expect(try cache.rows().isEmpty)
    }

    @Test func rowsRoundTripAndStayOrderedByEntryId() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let cache = JournalMetadataCache(
            context: try WorktreeContext.resolve(path: repo.url.path))

        // Appended out of order on purpose: the file is an index of a journal
        // read oldest-first, so ordering is the cache's job, not the caller's.
        try cache.append(Self.row(try Self.id("03"), ref: "refs/c"))
        try cache.append(Self.row(try Self.id("01"), ref: "refs/a"))
        try cache.append(Self.row(try Self.id("02"), ref: "refs/b"))

        let rows = try cache.rows()
        #expect(rows.map(\.metadata.id) == [try Self.id("01"), try Self.id("02"), try Self.id("03")])
        #expect(rows.map(\.snapshotRef) == ["refs/a", "refs/b", "refs/c"])
    }

    /// #0033 deletes the cache row BEFORE the anchor, so a re-run after a crash
    /// between the two must not fail on a row that is already gone.
    @Test func removingAnAbsentRowIsSilent() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let cache = JournalMetadataCache(
            context: try WorktreeContext.resolve(path: repo.url.path))
        try cache.append(Self.row(try Self.id("01")))

        try cache.remove(id: try Self.id("99"))
        #expect(try cache.rows().count == 1)

        try cache.remove(id: try Self.id("01"))
        #expect(try cache.rows().isEmpty)
    }

    // MARK: - One journal per repository

    /// The file is addressed from `commonDir`, never `--git-path`: for a
    /// subpath git does not know, `--git-path` resolves PER-WORKTREE, so a
    /// linked worktree would silently get its own private journal.
    @Test func aLinkedWorktreeSeesTheSameJournal() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }

        let mainContext = try WorktreeContext.resolve(path: repo.url.path)
        let sideContext = try WorktreeContext.resolve(path: wt.path)
        // Anti-vacuity: the two contexts must really be different worktrees.
        #expect(mainContext.gitDir != sideContext.gitDir)

        try JournalMetadataCache(context: mainContext)
            .append(Self.row(try Self.id("01"), ref: "refs/shared"))

        let fromSide = try JournalMetadataCache(context: sideContext).rows()
        #expect(fromSide.map(\.snapshotRef) == ["refs/shared"])
        #expect(JournalMetadataCache(context: sideContext).fileURL
            == JournalMetadataCache(context: mainContext).fileURL)
    }

    // MARK: - Typed failure, never silent invention

    @Test func aTornFileIsATypedErrorRatherThanAnEmptyCache() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let cache = JournalMetadataCache(
            context: try WorktreeContext.resolve(path: repo.url.path))
        try cache.append(Self.row(try Self.id("01")))

        try Data("{ not json".utf8).write(to: cache.fileURL)
        let thrown = try #require(throws: JournalMetadataCache.Error.self) {
            _ = try cache.rows()
        }
        guard case let .unreadable(path, _) = thrown else {
            Issue.record("expected .unreadable, got \(thrown)")
            return
        }
        #expect(path == cache.fileURL.path)
        #expect(thrown.exitClass == .repositoryError)
    }

    /// A future schema must report itself, not surface as a missing field.
    @Test func anUnknownSchemaVersionIsItsOwnError() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let cache = JournalMetadataCache(
            context: try WorktreeContext.resolve(path: repo.url.path))
        try FileManager.default.createDirectory(
            at: cache.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":2,"entries":[]}"#.utf8).write(to: cache.fileURL)

        let thrown = try #require(throws: JournalMetadataCache.Error.self) {
            _ = try cache.rows()
        }
        #expect(thrown == .unsupportedSchema(version: 2, path: cache.fileURL.path))
        #expect(thrown.description.contains("schema version 2"))
    }
}
