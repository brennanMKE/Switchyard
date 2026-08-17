// JournalObservedTests.swift — observed foreign ref transactions (#0153)
//
// Deliberately NOT @testable: `JournalObserved` is called by the hook layer
// (#0191) as a public caller, so a member silently dropping to internal must
// fail here at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct JournalObservedTests {

    private static func id(_ suffix: String) throws -> JournalEntryID {
        try #require(JournalEntryID("010000000000000000000000" + suffix))
    }

    /// Writes an ordinary checkpoint entry through the real journal path,
    /// mirroring `JournalListTests`'s helper.
    @discardableResult
    private static func writeCheckpoint(
        _ id: JournalEntryID, in context: WorktreeContext
    ) throws -> JournalAnchor.Entry {
        let metadata = JournalEntryMetadata(
            id: id, operation: "checkpoint",
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: nil, path: "/unused-by-these-tests"),
            captured: .refsOnly)
        return try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: try metadata.serialized()),
            id: id, in: context)
    }

    /// `JournalAnchor.metadata` reads through the journal namespace only, so
    /// an observed entry's blob is read directly by its own ref name.
    private static func observedMetadataJSON(
        for id: JournalEntryID, in context: WorktreeContext
    ) throws -> Data {
        try GitProcess().run(
            ["cat-file", "blob",
             JournalObserved.refPrefix + id.string + ":" + JournalAnchor.metadataTreeEntryName],
            workingDirectory: context.topLevel ?? context.gitDir
        ).standardOutput
    }

    @Test func anObservedEntryIsInvisibleToTheJournalAndItsListing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let checkpoint = try Self.writeCheckpoint(try Self.id("01"), in: context)
        let observed = try JournalObserved.record(
            [ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: try repo.revParse("HEAD"),
                refName: "refs/heads/main")],
            in: context, now: Date(timeIntervalSince1970: 0))

        let anchored = try JournalAnchor.list(in: context)
        #expect(!anchored.isEmpty)
        #expect(anchored.map(\.id) == [checkpoint.id])
        #expect(!anchored.map(\.id).contains(observed.id))

        let listing = try JournalList.list(in: context)
        #expect(!listing.items.isEmpty)
        #expect(listing.items.map(\.entry.id) == [checkpoint.id])
        #expect(!listing.items.map(\.entry.id).contains(observed.id))
        #expect(listing.items.compactMap(\.defect).isEmpty)
    }

    /// `JournalObserved.Metadata` and `RefUpdate` are `Encodable` only (#0153
    /// pins the wire shape one way), so decoding the written blob back for
    /// assertions goes through a local mirror with the identical keys.
    private struct DecodedRefUpdate: Decodable, Equatable {
        let oldValue: String
        let newValue: String
        let refName: String
    }

    private struct DecodedMetadata: Decodable {
        let schemaVersion: Int
        let updates: [DecodedRefUpdate]
    }

    @Test func observedEntriesRoundTripTheirRefUpdates() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let head = try repo.revParse("HEAD")
        let updates = [
            ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: head, refName: "refs/heads/main"),
            ReferenceTransaction.RefUpdate(
                oldValue: head, newValue: String(repeating: "0", count: 40),
                refName: "refs/heads/stale"),
        ]
        let entry = try JournalObserved.record(
            updates, in: context, now: Date(timeIntervalSince1970: 0))

        let listed = try JournalObserved.list(in: context)
        #expect(!listed.isEmpty)
        #expect(listed.map(\.id) == [entry.id])

        let json = try Self.observedMetadataJSON(for: entry.id, in: context)
        #expect(!json.isEmpty)
        let decoded = try JSONDecoder().decode(DecodedMetadata.self, from: json)
        #expect(!decoded.updates.isEmpty)
        #expect(decoded.updates.count == updates.count)
        #expect(decoded.updates == updates.map {
            DecodedRefUpdate(oldValue: $0.oldValue, newValue: $0.newValue, refName: $0.refName)
        })
    }

    @Test func theObservedNamespaceIsNotTheJournalNamespace() throws {
        #expect(JournalObserved.refPrefix != JournalAnchor.refPrefix)

        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let head = try repo.revParse("HEAD")

        let entry = try JournalObserved.record(
            [ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: head, refName: "refs/heads/main")],
            in: context, now: Date(timeIntervalSince1970: 0))

        let refs = try GitProcess().run(
            ["for-each-ref", "--format=%(refname)", "refs/switchyard/**"],
            workingDirectory: context.topLevel ?? context.gitDir).lines
        #expect(!refs.isEmpty)
        let matching = refs.filter { $0.hasSuffix(entry.id.string) }
        #expect(!matching.isEmpty)
        #expect(matching.allSatisfy { $0.hasPrefix(JournalObserved.refPrefix) })
    }
}
