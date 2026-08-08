// JournalListTests.swift — journal listing and the prune composition (#0170)
//
// Deliberately NOT @testable: `journal` and the M3 wiring call this listing
// as public callers, so a member silently dropping to internal must fail
// here at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct JournalListTests {

    // MARK: - Fixture helpers

    /// Six ascending ids. Fixed literals so ordering is visible in the test;
    /// their embedded timestamps sit at the epoch, so any age policy with
    /// `now` = today has long expired them.
    private static func id(_ suffix: String) throws -> JournalEntryID {
        try #require(JournalEntryID("010000000000000000000000" + suffix))
    }

    /// Writes one journal entry through the real write path: #0155 metadata
    /// serialized into #0028's anchored snapshot commit.
    @discardableResult
    private static func writeEntry(
        _ id: JournalEntryID,
        worktree: String?,
        traversal: JournalChain.Traversal? = nil,
        in context: WorktreeContext
    ) throws -> JournalAnchor.Entry {
        let metadata = JournalEntryMetadata(
            id: id,
            operation: traversal == nil ? "checkpoint" : "undo",
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: worktree, path: "/unused-by-these-tests"),
            captured: .refsOnly,
            traversal: traversal)
        return try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: try metadata.serialized()),
            id: id, in: context)
    }

    /// The five-entry main-worktree journal with an active undo run:
    /// three checkpoints, then two undos, leaving the cursor on entry 2.
    /// Returns the entries in id order.
    private static func activeRunFixture(
        in context: WorktreeContext
    ) throws -> [JournalAnchor.Entry] {
        let n1 = try id("01"), n2 = try id("02"), n3 = try id("03")
        let t4 = try id("04"), t5 = try id("05")
        return [
            try writeEntry(n1, worktree: nil, in: context),
            try writeEntry(n2, worktree: nil, in: context),
            try writeEntry(n3, worktree: nil, in: context),
            try writeEntry(t4, worktree: nil,
                           traversal: .init(restored: n3, resultingPosition: n3),
                           in: context),
            try writeEntry(t5, worktree: nil,
                           traversal: .init(restored: n2, resultingPosition: n2),
                           in: context),
        ]
    }

    /// An age policy that expires every fixed-id entry: their embedded
    /// timestamps are at the epoch, decades past any hour-scale limit.
    private static let expireEverything = JournalPrune.Policy(maxAge: 3600)

    // MARK: - Listing

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func positionsAcrossAnActiveUndoRunMatchTheChainState(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let entries = try Self.activeRunFixture(in: context)

        let listing = try JournalList.list(in: context)
        #expect(listing.items.map(\.entry) == entries)
        #expect(listing.items.map(\.position) == [
            .history, .cursor, .redoTail, .traversal, .traversal,
        ])
        #expect(listing.state.cursor == entries[1].id)
        #expect(listing.state.undoTarget == entries[0].id)
        #expect(listing.state.redoTarget == .entry(entries[2].id))
        #expect(listing.state.protectedIDs == Set(entries.dropFirst().map(\.id)))
        // Metadata rides through, so `journal` can report what each entry
        // captured and how it was made.
        let first = try #require(listing.items.first?.metadata)
        #expect(first.operation == "checkpoint")
        #expect(first.captured == .refsOnly)
        #expect(listing.items.allSatisfy { $0.defect == nil })
        #expect(listing.foreignRefs.isEmpty)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aSiblingWorktreesEntriesListAsOtherWorktreeAndLeaveTheCursorAlone(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let mine = try Self.writeEntry(try Self.id("01"), worktree: nil, in: context)
        let theirs = try Self.writeEntry(
            try Self.id("02"), worktree: "agent-a", in: context)

        let listing = try JournalList.list(in: context)
        #expect(listing.items.map(\.position) == [.history, .otherWorktree])
        #expect(listing.items.last?.metadata?.worktree.name == "agent-a")
        // The sibling's newer checkpoint is not this worktree's undo target.
        #expect(listing.state.undoTarget == mine.id)
        #expect(listing.state.cursor == nil)
        _ = theirs
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func anUndecodableMetadataEntryListsWithADefectAndSinksNothing(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let good = try Self.writeEntry(try Self.id("01"), worktree: nil, in: context)
        let bad = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("not json\n".utf8)),
            id: try Self.id("02"), in: context)

        let listing = try JournalList.list(in: context)
        #expect(listing.items.map(\.entry) == [good, bad])
        // `.last` + #require, never items[1]: under a mutation that drops
        // the defective item, a raw subscript would trap and destroy the
        // whole run summary instead of failing this test.
        let defective = try #require(listing.items.last)
        #expect(defective.entry == bad)
        #expect(defective.metadata == nil)
        #expect(defective.position == nil)
        #expect(try #require(defective.defect).contains("does not decode"))
        // The well-formed entry is still positioned and still the target.
        #expect(listing.items[0].position == .history)
        #expect(listing.state.undoTarget == good.id)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func metadataWhoseIdDisagreesWithItsAnchorIsADefectNotAChainEntry(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let good = try Self.writeEntry(try Self.id("01"), worktree: nil, in: context)
        // A blob that decodes fine but claims the *first* entry's id. Fed to
        // the chain it would be a duplicate id — `.unordered`, sinking the
        // whole listing; the mismatch check must catch it first.
        let doctored = JournalEntryMetadata(
            id: good.id, operation: "checkpoint",
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: nil, path: "/unused-by-these-tests"),
            captured: .refsOnly)
        let bad = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: try doctored.serialized()),
            id: try Self.id("02"), in: context)

        let listing = try JournalList.list(in: context)
        #expect(listing.items.map(\.entry) == [good, bad])
        let defective = try #require(listing.items.last)
        #expect(defective.entry == bad)
        #expect(defective.metadata != nil)   // decoded — kept as evidence
        #expect(defective.position == nil)
        #expect(try #require(defective.defect).contains("does not match"))
        #expect(listing.state.undoTarget == good.id)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func foreignRefsInTheNamespaceAreReportedBesideTheItems(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let good = try Self.writeEntry(try Self.id("01"), worktree: nil, in: context)
        let squatter = JournalAnchor.refPrefix + "not-an-entry"
        try GitProcess().run(
            ["update-ref", squatter, try repo.revParse("HEAD")],
            workingDirectory: repo.url.path)

        let listing = try JournalList.list(in: context)
        #expect(listing.foreignRefs == [squatter])
        #expect(listing.items.map(\.entry) == [good])
        #expect(listing.state.undoTarget == good.id)
    }

    // MARK: - Prune composition

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func pruneNeverDeletesTheLiveChain(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let entries = try Self.activeRunFixture(in: context)

        // Every entry is decades past the age limit; only protection and the
        // newest-entry rule stand between the live chain and deletion.
        let deleted = try JournalList.prune(
            policy: Self.expireEverything, in: context)
        #expect(deleted == [entries[0]])
        #expect(try JournalAnchor.list(in: context) == Array(entries.dropFirst()))

        // The survivors still resolve as a chain: cursor and redo intact.
        let listing = try JournalList.list(in: context)
        #expect(listing.state.cursor == entries[1].id)
        #expect(listing.state.redoTarget == .entry(entries[2].id))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aDeadWorktreesChainStopsProtectingOncePrunable(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let worktreePath = try repo.addWorktree(named: "agent-a", branch: "agent-a")
        let agent = try #require(
            try WorktreeContext.resolve(path: worktreePath.path).worktreeName)

        let n1 = try Self.writeEntry(try Self.id("01"), worktree: nil, in: context)
        let n2 = try Self.writeEntry(try Self.id("02"), worktree: agent, in: context)
        let t3 = try Self.writeEntry(
            try Self.id("03"), worktree: agent,
            traversal: .init(restored: n2.id, resultingPosition: n2.id),
            in: context)
        let n4 = try Self.writeEntry(try Self.id("04"), worktree: nil, in: context)

        // Phase 1 — the worktree is live, so its open run {n2, t3} is
        // protected and only main's dead history goes. This phase is the
        // control that makes phase 2 load-bearing: it proves the protection
        // existed before the directory vanished.
        let whileLive = try JournalList.prune(
            policy: Self.expireEverything, in: context)
        #expect(whileLive == [n1])
        #expect(try JournalAnchor.list(in: context) == [n2, t3, n4])

        // Phase 2 — the agent checkout is deleted without `worktree remove`.
        // Porcelain now reports it prunable, its chain stops protecting, and
        // its entries expire like any other history (#0044 decision 5).
        try FileManager.default.removeItem(at: worktreePath)
        let afterDeath = try JournalList.prune(
            policy: Self.expireEverything, in: context)
        #expect(afterDeath == [n2, t3])
        #expect(try JournalAnchor.list(in: context) == [n4])
    }

    @Test func listingNeedsNoLockAndPruneRespectsIt() throws {
        let repo = try FixtureRepository.linear(refFormat: .files)
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let entry = try Self.writeEntry(try Self.id("01"), worktree: nil, in: context)

        try JournalLock(context: context).withLock {
            // Reading is lock-free by design, so it works while a writer
            // holds the journal lock.
            let listing = try JournalList.list(in: context)
            #expect(listing.items.map(\.entry) == [entry])
            // Pruning mutates and must queue behind the held lock.
            #expect(throws: JournalLockError.self) {
                try JournalList.prune(
                    policy: Self.expireEverything,
                    lockTimeout: .milliseconds(50), in: context)
            }
        }
        #expect(try JournalAnchor.list(in: context) == [entry])
    }
}
