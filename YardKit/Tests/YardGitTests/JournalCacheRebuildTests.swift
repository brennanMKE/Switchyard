// JournalCacheRebuildTests.swift — rebuild rewrites the cache (#0164)

import Foundation
import Testing
@testable import YardGit

struct JournalCacheRebuildTests {

    private static func id(_ suffix: String) throws -> JournalEntryID {
        try #require(JournalEntryID("010000000000000000000000" + suffix))
    }

    /// Writes one entry through the real path: #0155 metadata inside #0028's
    /// anchored snapshot commit.
    @discardableResult
    private static func writeEntry(
        _ id: JournalEntryID, in context: WorktreeContext
    ) throws -> JournalAnchor.Entry {
        let metadata = JournalEntryMetadata(
            id: id,
            operation: "checkpoint",
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: nil, path: "/unused-by-these-tests"),
            captured: .refsOnly)
        return try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: try metadata.serialized()),
            id: id, in: context)
    }

    /// **The M2 criterion made literal.** Delete the state directory for real,
    /// rebuild from the anchor refs alone, rewrite the cache, and require the
    /// recovered rows to equal what was lost — byte for byte, in order.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func deletingTheCacheLosesNothing(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let cache = JournalMetadataCache(context: context)

        for suffix in ["01", "02", "03"] {
            let entry = try Self.writeEntry(try Self.id(suffix), in: context)
            let json = try JournalAnchor.metadata(for: entry.id, in: context)
            try cache.append(JournalMetadataCache.Row(
                metadata: try JournalEntryMetadata(serialized: json),
                snapshotRef: JournalAnchor.refName(for: entry.id)))
        }
        let before = try cache.rows()
        #expect(before.count == 3, "the fixture must populate the cache, or this asserts nothing")

        // Delete the whole state directory, not just the file.
        let stateDirectory = cache.fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: stateDirectory)
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path),
                "the wreck must take effect")
        #expect(try cache.rows().isEmpty)

        let rebuilt = try JournalRebuild.rebuild(in: context)
        #expect(rebuilt.defects.isEmpty)
        let outcome = try cache.rewrite(from: rebuilt)

        #expect(outcome.defects.isEmpty)
        #expect(try cache.rows() == before, "recovered rows must equal what was deleted")
        #expect(outcome.written == before)
    }

    /// A planted, lying cache must be replaced wholesale — not merged with —
    /// because the refs are the authority and a merge would preserve rows for
    /// entries the journal no longer has (#0033's over-reporting ban).
    @Test func rewriteReplacesRatherThanMerges() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let cache = JournalMetadataCache(context: context)

        let real = try Self.writeEntry(try Self.id("01"), in: context)
        try cache.append(JournalMetadataCache.Row(
            metadata: JournalEntryMetadata(
                id: try Self.id("99"), operation: "ghost",
                timestamp: Date(timeIntervalSince1970: 0),
                worktree: .init(name: nil, path: "/gone"), captured: .refsOnly),
            snapshotRef: "refs/ghost"))
        #expect(try cache.rows().count == 1, "the ghost row must exist to be displaced")

        let outcome = try cache.rewrite(from: try JournalRebuild.rebuild(in: context))
        #expect(outcome.written.map(\.metadata.id) == [real.id])
        #expect(try cache.rows().map(\.metadata.id) == [real.id])
    }

    /// Undecodable metadata is reported as a row defect — never a silently
    /// invented row, and never a thrown error that loses the good entries.
    @Test func undecodableMetadataIsReportedNotInvented() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let cache = JournalMetadataCache(context: context)

        let good = try Self.writeEntry(try Self.id("01"), in: context)
        let badID = try Self.id("02")
        try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("not json\n".utf8)),
            id: badID, in: context)

        let outcome = try cache.rewrite(from: try JournalRebuild.rebuild(in: context))
        #expect(outcome.written.map(\.metadata.id) == [good.id])
        #expect(outcome.defects.map(\.id) == [badID])
        #expect(try #require(outcome.defects.first).description.contains(badID.description))
        // The good entry is still cached: one bad blob must not sink the file.
        #expect(try cache.rows().map(\.metadata.id) == [good.id])
    }
}
