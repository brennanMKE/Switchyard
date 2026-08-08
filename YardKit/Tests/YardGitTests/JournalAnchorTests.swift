// JournalAnchorTests.swift — entry ids, anchor refs, and the snapshot commit (#0028)
//
// Deliberately NOT @testable: everything the journal layer exposes is called
// by later M2 issues as a public caller, so a member silently dropping to
// internal must fail here at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct JournalAnchorTests {

    private let git = GitProcess()

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    /// A commit reachable from nothing — no ref, no reflog — with unique
    /// content, so only an anchor's keep-alive parenthood can save it from
    /// `gc --prune=now`.
    private func unreachableCommit(in repo: FixtureRepository, marker: String) throws -> String {
        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data("victim \(marker)\n".utf8)).lines.first)
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

    /// Expires every reflog and prunes immediately, the most aggressive
    /// reclamation ordinary maintenance can perform.
    private func aggressivelyCollect(_ repo: FixtureRepository) throws {
        try git.run(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"],
                    workingDirectory: repo.url.path)
        try git.run(["gc", "--aggressive", "--prune=now", "--quiet"],
                    workingDirectory: repo.url.path)
    }

    private func exists(_ oid: String, in repo: FixtureRepository) throws -> Bool {
        try git.capture(["cat-file", "-e", oid], workingDirectory: repo.url.path).exitCode == 0
    }

    // MARK: - Entry ids

    @Test func generatedIdsSortByCreationOrder() throws {
        let t1 = Date(timeIntervalSince1970: 1_754_000_000)
        let a = JournalEntryID.generate(now: t1)
        let b = JournalEntryID.generate(now: t1.addingTimeInterval(0.002), after: a)
        let c = JournalEntryID.generate(now: t1.addingTimeInterval(60), after: b)
        #expect(a < b && b < c)
        #expect([c, a, b].sorted().map(\.string) == [a, b, c].map(\.string))
        #expect(a.string.count == JournalEntryID.length)
        // Round trip: a generated id parses back to itself.
        #expect(try #require(JournalEntryID(a.string)) == a)
    }

    /// Sixty-four ids in one millisecond must each exceed the last. Without
    /// the monotonic clamp each step is an independent coin flip on random
    /// bits, so an unclamped implementation survives this loop with
    /// probability ~2⁻⁶³ — the mutation is deterministically caught.
    @Test func sameMillisecondIdsStillAscend() throws {
        let now = Date(timeIntervalSince1970: 1_754_000_000)
        var previous = JournalEntryID.generate(now: now)
        let timePrefix = String(previous.string.prefix(10))
        for _ in 0..<64 {
            let next = JournalEntryID.generate(now: now, after: previous)
            #expect(previous < next)
            #expect(String(next.string.prefix(10)) == timePrefix)
            previous = next
        }
    }

    @Test func idParsingRejectsWhatItMust() throws {
        #expect(JournalEntryID("01ARZ3NDEKTSV4RRFFQ69G5FAV") != nil)
        #expect(JournalEntryID("") == nil)
        #expect(JournalEntryID("01ARZ3NDEKTSV4RRFFQ69G5FA") == nil)    // 25 chars
        #expect(JournalEntryID("01ARZ3NDEKTSV4RRFFQ69G5FAVX") == nil)  // 27 chars
        #expect(JournalEntryID("01arz3ndektsv4rrffq69g5fav") == nil)   // lowercase
        #expect(JournalEntryID("01ARZ3NDEKTSV4RRFFQ69G5FAU") == nil)   // U not in alphabet
        #expect(JournalEntryID("81ARZ3NDEKTSV4RRFFQ69G5FAV") == nil)   // leading char > 7
    }

    // MARK: - Writing

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func writeCreatesTheAnchorAndItsSnapshotCommit(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let keep = try #require(repo.oids["c"])
        let metadata = Data(#"{"schemaVersion":1,"operation":"probe"}"#.utf8)
        let id = JournalEntryID.generate()

        let entry = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: metadata, keepAlive: [keep]),
            id: id, in: context(of: repo))

        // The anchor ref points at the snapshot commit.
        #expect(try repo.revParse(JournalAnchor.refName(for: id)) == entry.commit)
        // The keep-alive commit is a parent of the snapshot commit.
        let parents = try git.run(["rev-list", "--parents", "-n1", entry.commit],
                                  workingDirectory: repo.url.path)
        let fields = try #require(parents.lines.first).split(separator: " ").map(String.init)
        #expect(fields == [entry.commit, keep])
        // The metadata blob reads back byte-exact — through the API and
        // through the literal path #0030 will use.
        #expect(try JournalAnchor.metadata(for: id, in: context(of: repo)) == metadata)
        let raw = try git.run(
            ["cat-file", "blob", JournalAnchor.refName(for: id) + ":metadata.json"],
            workingDirectory: repo.url.path)
        #expect(raw.standardOutput == metadata)
    }

    @Test func writeStoresEveryOptionalPieceByItsTreeName() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data("piece\n".utf8)).lines.first)
        let tree = try #require(try git.run(
            ["mktree"], workingDirectory: repo.url.path,
            standardInput: Data("100644 blob \(blob)\tp.txt\n".utf8)).lines.first)
        let id = JournalEntryID.generate()

        try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("{}".utf8), refsBlob: blob,
                                   indexTree: tree, indexBlob: blob, untrackedTree: tree),
            id: id, in: context(of: repo))

        let ref = JournalAnchor.refName(for: id)
        for (name, expected) in [("refs", blob), ("index", tree),
                                 ("index.raw", blob), ("untracked", tree)] {
            #expect(try repo.revParse("\(ref):\(name)") == expected,
                    "tree entry \(name) must hold the piece OID")
        }
    }

    @Test func writeRefusesAnExistingEntryId() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let id = JournalEntryID.generate()
        let first = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("first".utf8)),
            id: id, in: context(of: repo))

        #expect(throws: GitProcess.Failure.self) {
            try JournalAnchor.write(
                JournalAnchor.Contents(metadataJSON: Data("second".utf8)),
                id: id, in: context(of: repo))
        }
        // The original entry is untouched.
        #expect(try repo.revParse(JournalAnchor.refName(for: id)) == first.commit)
        #expect(try JournalAnchor.metadata(for: id, in: context(of: repo)) == Data("first".utf8))
    }

    // MARK: - Listing

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func listIsEmptyThenAscendsByCreation(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        #expect(try JournalAnchor.list(in: context(of: repo)) == [])

        let t = Date(timeIntervalSince1970: 1_754_000_000)
        let idA = JournalEntryID.generate(now: t)
        let idB = JournalEntryID.generate(now: t, after: idA)
        let a = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("a".utf8)), id: idA, in: context(of: repo))
        let b = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("b".utf8)), id: idB, in: context(of: repo))

        #expect(try JournalAnchor.list(in: context(of: repo)) == [a, b])
    }

    @Test func listThrowsOnAForeignRefInTheJournalNamespace() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let c = try #require(repo.oids["c"])
        try git.run(["update-ref", JournalAnchor.refPrefix + "not-an-id", c],
                    workingDirectory: repo.url.path)

        let error = try #require(throws: JournalAnchor.Error.self) {
            _ = try JournalAnchor.list(in: context(of: repo))
        }
        guard case let .foreignRef(name) = error else {
            Issue.record("expected .foreignRef, got \(error)")
            return
        }
        #expect(name == JournalAnchor.refPrefix + "not-an-id")
    }

    @Test func metadataRoundTripsByteExact() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        // Multibyte UTF-8 and no trailing newline: bytes, not lines.
        let metadata = Data(#"{"operation":"héhé — 直す","n":1}"#.utf8)
        let id = JournalEntryID.generate()
        try JournalAnchor.write(JournalAnchor.Contents(metadataJSON: metadata),
                                id: id, in: context(of: repo))
        #expect(try JournalAnchor.metadata(for: id, in: context(of: repo)) == metadata)
    }

    // MARK: - Reachability

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func anchoredSnapshotSurvivesAggressiveGC(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let victim = try unreachableCommit(in: repo, marker: "survives-\(format.rawValue)")
        let metadata = Data("gc-survival".utf8)
        let id = JournalEntryID.generate()
        try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: metadata, keepAlive: [victim]),
            id: id, in: context(of: repo))

        try aggressivelyCollect(repo)

        #expect(try exists(victim, in: repo), "the anchor must keep the snapshot reachable")
        #expect(try JournalAnchor.metadata(for: id, in: context(of: repo)) == metadata)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func deletedEntryIsReclaimedByOrdinaryMaintenance(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let victim = try unreachableCommit(in: repo, marker: "reclaimed-\(format.rawValue)")
        let id = JournalEntryID.generate()
        let entry = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("prune-me".utf8), keepAlive: [victim]),
            id: id, in: context(of: repo))

        try JournalAnchor.delete(entry, in: context(of: repo))
        try aggressivelyCollect(repo)

        #expect(try !exists(victim, in: repo),
                "nothing may depend on objects staying reachable after the anchor is removed")
        #expect(try JournalAnchor.list(in: context(of: repo)) == [])
    }

    // MARK: - Deleting

    @Test func deleteIsGuardedByTheExpectedCommit() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wrong = try #require(repo.oids["c"])
        let id = JournalEntryID.generate()
        let entry = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("guarded".utf8)),
            id: id, in: context(of: repo))

        // A stale caller naming the wrong commit is refused, and the entry survives.
        #expect(throws: GitProcess.Failure.self) {
            try JournalAnchor.delete(JournalAnchor.Entry(id: id, commit: wrong),
                                     in: context(of: repo))
        }
        #expect(try JournalAnchor.list(in: context(of: repo)) == [entry])

        try JournalAnchor.delete(entry, in: context(of: repo))
        #expect(try JournalAnchor.list(in: context(of: repo)) == [])

        // Deleting what no longer exists is also refused, not a silent no-op.
        #expect(throws: GitProcess.Failure.self) {
            try JournalAnchor.delete(entry, in: context(of: repo))
        }
    }

    // MARK: - Sharing and exclusion

    @Test func anchorsAreSharedAcrossWorktrees() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }

        let id = JournalEntryID.generate()
        let entry = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("from-linked-worktree".utf8)),
            id: id, in: WorktreeContext.resolve(path: wt.path))

        // Written from the linked worktree, visible from the main one: the
        // namespace is per-common-dir, so there is exactly one journal.
        #expect(try JournalAnchor.list(in: context(of: repo)) == [entry])
    }

    @Test func defaultPushDoesNotPushJournalRefs() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let remote = try FixtureRepository(bare: true)
        defer { remote.destroy() }
        try git.run(["remote", "add", "origin", remote.url.path],
                    workingDirectory: repo.url.path)
        try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data("stays-local".utf8)),
            id: JournalEntryID.generate(), in: context(of: repo))

        try git.run(["push", "-q", "origin", "main"], workingDirectory: repo.url.path)
        try git.run(["push", "-q", "--all", "origin"], workingDirectory: repo.url.path)
        try git.run(["push", "-q", "--tags", "origin"], workingDirectory: repo.url.path)

        let remoteRefs = try git.run(["for-each-ref", "--format=%(refname)"],
                                     workingDirectory: remote.url.path)
        #expect(remoteRefs.lines == ["refs/heads/main"],
                "no default push variant may carry \(JournalAnchor.refPrefix)")
    }
}
