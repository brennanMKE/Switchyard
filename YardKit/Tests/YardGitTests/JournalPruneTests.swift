// JournalPruneTests.swift — expiry policy and pruning of journal entries (#0033)
//
// Deliberately NOT @testable, like JournalAnchorTests: pruning's callers
// (#0034's journal command, #0156's cache wiring) are public callers, so a
// member silently dropping to internal must fail here at compile time.

import Foundation
import Testing
import YardGit

struct JournalPruneTests {

    private let git = GitProcess()

    private struct StubCacheFailure: Error {}

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    /// Entries for the pure `plan` tests: ids minted at controlled instants,
    /// commits fabricated — `plan` never touches a repository.
    private func fabricated(
        count: Int, from start: Date, spacing: TimeInterval = 60
    ) -> [JournalAnchor.Entry] {
        var previous: JournalEntryID?
        var entries: [JournalAnchor.Entry] = []
        for index in 0..<count {
            let id = JournalEntryID.generate(
                now: start.addingTimeInterval(TimeInterval(index) * spacing),
                after: previous)
            previous = id
            entries.append(JournalAnchor.Entry(
                id: id, commit: String(repeating: "0", count: 40)))
        }
        return entries
    }

    /// Writes a real anchored entry whose id was minted at `date`.
    @discardableResult
    private func writeEntry(
        in repo: FixtureRepository, at date: Date,
        after previous: JournalEntryID? = nil, keepAlive: [String] = []
    ) throws -> JournalAnchor.Entry {
        try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("prune-fixture".utf8),
                                   keepAlive: keepAlive),
            id: JournalEntryID.generate(now: date, after: previous),
            in: context(of: repo))
    }

    /// A commit reachable from nothing, so only keep-alive parenthood can
    /// save it from `gc --prune=now` run by the fixture.
    private func unreachableCommit(in repo: FixtureRepository, marker: String) throws -> String {
        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data("prune victim \(marker)\n".utf8)).lines.first)
        let tree = try #require(try git.run(
            ["mktree"], workingDirectory: repo.url.path,
            standardInput: Data("100644 blob \(blob)\tv.txt\n".utf8)).lines.first)
        return try #require(try git.run(
            ["commit-tree", tree, "-m", "victim \(marker)"],
            workingDirectory: repo.url.path,
            extraEnvironment: ["GIT_AUTHOR_NAME": "v", "GIT_AUTHOR_EMAIL": "v@invalid",
                               "GIT_COMMITTER_NAME": "v", "GIT_COMMITTER_EMAIL": "v@invalid"])
            .lines.first)
    }

    /// The most aggressive reclamation ordinary maintenance can perform —
    /// run by the TEST fixture to prove reachability claims. Production
    /// (`JournalPrune`) never invokes gc; that is the point of the test
    /// that calls this.
    private func aggressivelyCollect(_ repo: FixtureRepository) throws {
        try git.run(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"],
                    workingDirectory: repo.url.path)
        try git.run(["gc", "--aggressive", "--prune=now", "--quiet"],
                    workingDirectory: repo.url.path)
    }

    private func exists(_ oid: String, in repo: FixtureRepository) throws -> Bool {
        try git.capture(["cat-file", "-e", oid], workingDirectory: repo.url.path).exitCode == 0
    }

    // MARK: - The id's embedded timestamp

    @Test func creationDateRoundTripsThroughTheGeneratedId() throws {
        // Truncation to the millisecond: decoded ≤ minted-from, within 1ms.
        let instant = Date(timeIntervalSince1970: 1_754_000_000.5)
        let id = JournalEntryID.generate(now: instant)
        #expect(id.creationDate <= instant)
        #expect(instant.timeIntervalSince(id.creationDate) < 0.001)

        // A whole-millisecond instant decodes exactly.
        let exact = Date(timeIntervalSince1970: 1_754_000_000)
        #expect(JournalEntryID.generate(now: exact).creationDate == exact)

        // The monotonic clamp increments the random half only, so a
        // same-millisecond successor reports the same creation instant.
        let first = JournalEntryID.generate(now: exact)
        let clamped = JournalEntryID.generate(now: exact, after: first)
        #expect(clamped.creationDate == first.creationDate)
    }

    // MARK: - Planning

    @Test func countPolicyKeepsTheNewestEntries() throws {
        let start = Date(timeIntervalSince1970: 1_754_000_000)
        let entries = fabricated(count: 5, from: start)

        let deletions = JournalPrune.plan(
            entries, policy: .init(maxCount: 2), now: start.addingTimeInterval(600))
        #expect(deletions == Array(entries.prefix(3)),
                "the three oldest expire, oldest first; the newest two stay")

        #expect(JournalPrune.plan(entries, policy: .init(maxCount: 5)) == [])
        #expect(JournalPrune.plan([], policy: .init(maxCount: 1)) == [])
    }

    @Test func agePolicyExpiresStrictlyOlderThanTheCutoff() throws {
        let now = Date(timeIntervalSince1970: 1_754_000_000)
        var previous: JournalEntryID?
        let entries = [-100.0, -50.0, -10.0, -1.0].map { offset -> JournalAnchor.Entry in
            let id = JournalEntryID.generate(now: now.addingTimeInterval(offset), after: previous)
            previous = id
            return JournalAnchor.Entry(id: id, commit: String(repeating: "0", count: 40))
        }

        let deletions = JournalPrune.plan(entries, policy: .init(maxAge: 50), now: now)
        // Strictly older than now − 50: the −100s entry only. The entry at
        // exactly the cutoff is kept — expiry is `<`, not `<=`.
        #expect(deletions == [entries[0]])
    }

    @Test func planWithoutLimitsDeletesNothing() throws {
        let ancient = fabricated(count: 4, from: Date(timeIntervalSince1970: 1_000))
        #expect(JournalPrune.plan(ancient, policy: JournalPrune.Policy()) == [])
    }

    @Test func theNewestEntryIsNeverPlannedEvenWhenExpired() throws {
        let start = Date(timeIntervalSince1970: 1_754_000_000)
        let entries = fabricated(count: 3, from: start)
        let later = start.addingTimeInterval(1_000_000)

        // Age-expired to the last entry: the newest survives anyway.
        let byAge = JournalPrune.plan(entries, policy: .init(maxAge: 1), now: later)
        #expect(byAge == Array(entries.prefix(2)))

        // maxCount 0 behaves as 1 for the same reason.
        let byCount = JournalPrune.plan(entries, policy: .init(maxCount: 0), now: later)
        #expect(byCount == Array(entries.prefix(2)))
    }

    @Test func protectedEntriesAreNeverPlanned() throws {
        let start = Date(timeIntervalSince1970: 1_754_000_000)
        let entries = fabricated(count: 4, from: start)
        let later = start.addingTimeInterval(1_000_000)

        let deletions = JournalPrune.plan(
            entries, policy: .init(maxAge: 1),
            protected: [entries[1].id], now: later)
        #expect(deletions == [entries[0], entries[2]],
                "the protected entry and the newest survive; order stays oldest-first")
    }

    // MARK: - Executing

    @Test func executeRemovesTheCacheRowBeforeItsAnchorInPlanOrder() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let base = Date(timeIntervalSince1970: 1_754_000_000)
        let a = try writeEntry(in: repo, at: base)
        let b = try writeEntry(in: repo, at: base.addingTimeInterval(60), after: a.id)
        let c = try writeEntry(in: repo, at: base.addingTimeInterval(120), after: b.id)

        var removed: [JournalEntryID] = []
        let ctx = try context(of: repo)
        try JournalPrune.execute([a, b], in: ctx) { id in
            // The cache row is removed while the anchor still exists: this
            // closure must run BEFORE the ref delete, or a crash between the
            // two would leave a cache row naming a deleted anchor.
            let anchor = try self.git.capture(
                ["rev-parse", "--verify", "-q", JournalAnchor.refName(for: id)],
                workingDirectory: repo.url.path)
            #expect(anchor.exitCode == 0,
                    "anchor \(id) must still exist when its cache row is removed")
            removed.append(id)
        }

        #expect(removed == [a.id, b.id], "cache rows evicted in plan order")
        #expect(try JournalAnchor.list(in: ctx) == [c])
    }

    @Test func aFailingCacheRemovalLeavesTheAnchorInPlace() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let entry = try writeEntry(in: repo, at: Date(timeIntervalSince1970: 1_754_000_000))
        let ctx = try context(of: repo)

        #expect(throws: StubCacheFailure.self) {
            try JournalPrune.execute([entry], in: ctx) { _ in throw StubCacheFailure() }
        }
        // The anchor was not deleted: both stores still agree the entry exists.
        #expect(try JournalAnchor.list(in: ctx) == [entry])
    }

    @Test func executeThrowsWhenAnAnchorVanishedUnderneathThePlan() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let entry = try writeEntry(in: repo, at: Date(timeIntervalSince1970: 1_754_000_000))
        let ctx = try context(of: repo)

        // A concurrent prune (or any outside actor) removes the anchor after
        // the plan was made. The guarded delete refuses — a prune that
        // deleted nothing must never read as one that succeeded, because a
        // bare `update-ref -d` on a missing ref exits 0 silently (measured).
        try JournalAnchor.delete(entry, in: ctx)
        #expect(throws: GitProcess.Failure.self) {
            try JournalPrune.execute([entry], in: ctx)
        }
    }

    // MARK: - End to end

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func pruneAppliesThePolicyAgainstTheLiveJournal(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let base = Date(timeIntervalSince1970: 1_754_000_000)
        let a = try writeEntry(in: repo, at: base)
        let b = try writeEntry(in: repo, at: base.addingTimeInterval(60), after: a.id)
        let c = try writeEntry(in: repo, at: base.addingTimeInterval(120), after: b.id)
        let d = try writeEntry(in: repo, at: base.addingTimeInterval(180), after: c.id)
        let ctx = try context(of: repo)

        let deleted = try JournalPrune.prune(
            policy: .init(maxCount: 2), now: base.addingTimeInterval(240), in: ctx)

        #expect(deleted == [a, b], "prune reports what it deleted, oldest first")
        #expect(try JournalAnchor.list(in: ctx) == [c, d])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func prunedObjectsAwaitOrdinaryMaintenanceAndKeptOnesSurviveIt(
        format: FixtureRepository.RefFormat
    ) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let base = Date(timeIntervalSince1970: 1_754_000_000)
        let doomedVictim = try unreachableCommit(in: repo, marker: "doomed-\(format.rawValue)")
        let keptVictim = try unreachableCommit(in: repo, marker: "kept-\(format.rawValue)")
        let doomed = try writeEntry(in: repo, at: base, keepAlive: [doomedVictim])
        let kept = try writeEntry(in: repo, at: base.addingTimeInterval(60),
                                  after: doomed.id, keepAlive: [keptVictim])
        let ctx = try context(of: repo)

        let deleted = try JournalPrune.prune(
            policy: .init(maxCount: 1), now: base.addingTimeInterval(120), in: ctx)
        #expect(deleted == [doomed])

        // Pruning is a ref operation: the pruned entry's objects still exist
        // until real maintenance runs, so nothing an in-flight operation
        // holds an OID to has been destroyed — and prune itself ran no gc.
        #expect(try exists(doomedVictim, in: repo))
        #expect(try exists(doomed.commit, in: repo))

        // Ordinary maintenance — run by the TEST, never by JournalPrune —
        // reclaims exactly the released entry and nothing the kept anchor
        // still reaches.
        try aggressivelyCollect(repo)
        #expect(try !exists(doomedVictim, in: repo),
                "the pruned entry's objects must be reclaimable by ordinary maintenance")
        #expect(try exists(keptVictim, in: repo),
                "the kept entry's keep-alive must survive the same collection")
        #expect(try JournalAnchor.list(in: ctx) == [kept])
    }
}
