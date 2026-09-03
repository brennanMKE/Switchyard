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

    // MARK: - The rewrite constraint (#0224)

    /// #0221's `updateMetadata` rewrites an entry's metadata blob and re-points
    /// its anchor ref without touching this file, and the row's `snapshotRef` —
    /// a ref name, not an oid — survives untouched, so the staleness is quiet.
    /// Pinned in three phases: the hazard (after a real rewrite, the cached row
    /// still shows the PRE-rewrite metadata, so the attached mapping is
    /// invisible), the behaviour the future wirer must implement (update the
    /// cached row and the mapping is visible through the cache), and the
    /// standing remedy (rebuild from refs #0030 recovers the rewrite).
    @Test func aMetadataRewriteStalesTheCachedRowUntilUpdatedOrRebuilt() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let cache = JournalMetadataCache(context: context)
        let id = try Self.id("01")
        let ref = JournalAnchor.refName(for: id)

        // A real entry, anchored by the real write path.
        let pre = JournalEntryMetadata(
            id: id,
            operation: "checkpoint",
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: nil, path: "/unused-by-these-tests"),
            captured: .refsOnly)
        _ = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: try pre.serialized()),
            id: id, in: context)
        try cache.append(JournalMetadataCache.Row(metadata: pre, snapshotRef: ref))

        // The real rewrite path (#0221's attachRewrite, end to end): attach an
        // own-invocation mapping and push it into the entry through
        // `updateMetadata`. The oids are fixture commits, exactly as a
        // post-rewrite hook would deliver them.
        let mapping = JournalEntryMetadata.RewriteMapping(
            source: "amend",
            rewrites: [PostRewrite.Rewrite(
                oldOid: try #require(repo.oids["b"]),
                newOid: try #require(repo.oids["c"]))])
        let post = pre.attachingRewrite(mapping)
        let rewritten = try JournalAnchor.updateMetadata(
            try post.serialized(), for: id, in: context)
        // Anti-vacuity: the rewrite really happened — the ref moved and the
        // live blob carries the mapping — so phase 1's absence below cannot
        // pass merely because nothing was rewritten.
        #expect(try repo.revParse(ref) == rewritten.commit)
        #expect(try JournalEntryMetadata(
            serialized: try JournalAnchor.metadata(for: id, in: context)).rewrite == mapping)

        // Phase 1 — the hazard: the cache was not told, and the ref in the row
        // is still valid, so the only thing wrong is the embedded metadata.
        let stale = try #require(try cache.rows().first { $0.metadata.id == id })
        #expect(stale.metadata == pre, "the cached row must still show PRE-rewrite metadata")
        #expect(stale.metadata.rewrite == nil, "the attached mapping must be invisible here")
        #expect(stale.snapshotRef == ref,
                "the ref name survives the rewrite — that is why the staleness is quiet")

        // Phase 2 — the behaviour whoever wires the cache must implement:
        // update the cached row on rewrite, and the mapping is visible on the
        // fast path.
        try cache.append(JournalMetadataCache.Row(metadata: post, snapshotRef: ref))
        let updated = try #require(try cache.rows().first { $0.metadata.id == id })
        #expect(updated.metadata == post)
        #expect(updated.metadata.rewrite == mapping)

        // Phase 3 — the standing remedy: even with a stale row back in place,
        // rebuilding from the refs alone recovers the rewrite, because the
        // refs are the authority.
        try cache.append(JournalMetadataCache.Row(metadata: pre, snapshotRef: ref))
        #expect(try #require(try cache.rows().first { $0.metadata.id == id }).metadata.rewrite == nil,
                "the row must be stale again, or the rebuild below asserts nothing")
        let outcome = try cache.rewrite(from: try JournalRebuild.rebuild(in: context))
        #expect(outcome.defects.isEmpty)
        let recovered = try #require(try cache.rows().first { $0.metadata.id == id })
        #expect(recovered.metadata == post)
        #expect(recovered.metadata.rewrite == mapping)
        #expect(recovered.snapshotRef == ref)
    }
}
