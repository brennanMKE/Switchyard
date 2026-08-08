// JournalRebuildTests.swift — the journal survives a rebuild from refs alone (#0030)
//
// Deliberately NOT @testable: the rebuild is consumed by the journal listing
// (#0034) and the cache rewrite (#0164) as a public caller, so a member
// silently dropping to internal must fail here at compile time.

import Foundation
import Testing
import YardGit

struct JournalRebuildTests {

    private let git = GitProcess()

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    /// Writes one entry through the real anchor layer and returns what the
    /// rebuild must recover for it.
    @discardableResult
    private func writeEntry(
        _ metadata: String, id: JournalEntryID, in repo: FixtureRepository
    ) throws -> JournalRebuild.RecoveredEntry {
        let entry = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data(metadata.utf8)),
            id: id, in: context(of: repo))
        return JournalRebuild.RecoveredEntry(
            id: entry.id, commit: entry.commit, metadataJSON: Data(metadata.utf8))
    }

    /// Anchors an arbitrary OID under a valid entry id, bypassing
    /// `JournalAnchor.write` — how the corruption fixtures plant anchors
    /// `write` would never produce.
    private func plantAnchor(_ oid: String, id: JournalEntryID,
                             in repo: FixtureRepository) throws {
        try git.run(["update-ref", JournalAnchor.refPrefix + id.string, oid],
                    workingDirectory: repo.url.path)
    }

    /// Three ids whose creation order crosses a millisecond boundary: two in
    /// the same millisecond (ascending only because of the monotonic clamp),
    /// one in the next.
    private func threeIds() -> (a: JournalEntryID, b: JournalEntryID, c: JournalEntryID) {
        let t = Date(timeIntervalSince1970: 1_754_500_000)
        let a = JournalEntryID.generate(now: t)
        let b = JournalEntryID.generate(now: t, after: a)
        let c = JournalEntryID.generate(now: t.addingTimeInterval(0.001), after: b)
        return (a, b, c)
    }

    // MARK: - Recovery

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func rebuildOfAnEmptyJournalIsEmpty(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let result = try JournalRebuild.rebuild(in: context(of: repo))
        #expect(result == JournalRebuild.Result(entries: [], defects: []))
    }

    /// The core criterion: every entry comes back byte-exact from the
    /// repository alone, oldest first — in creation order even though the
    /// anchors were *written* in a different order, because the entry ids
    /// sort chronologically across the millisecond boundary `threeIds`
    /// builds in, and `for-each-ref`'s refname sort does the rest.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func rebuildRecoversEveryEntryByteExactOldestFirst(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ids = threeIds()
        #expect(ids.b.string.prefix(10) == ids.a.string.prefix(10),
                "a and b must share a millisecond for the ordering claim to mean anything")
        #expect(ids.c.string.prefix(10) != ids.b.string.prefix(10),
                "c must sit across the millisecond boundary")

        // Written youngest-first: creation order must come from the ids, not
        // from write order.
        let c = try writeEntry(#"{"op":"third"}"#, id: ids.c, in: repo)
        let a = try writeEntry(#"{"op":"first","note":"héhé — 直す"}"#, id: ids.a, in: repo)
        let b = try writeEntry(#"{"op":"second"}"#, id: ids.b, in: repo)

        let result = try JournalRebuild.rebuild(in: context(of: repo))
        #expect(result == JournalRebuild.Result(entries: [a, b, c], defects: []))
    }

    /// A `--mirror` clone is the one clone shape that carries anchor refs
    /// (a plain clone copies none of them — measured at #0028). Rebuilding
    /// inside the bare mirror, which has never had a cache, a state
    /// directory, or a worktree, recovers the identical journal: the
    /// repository's refs and objects alone are sufficient, which is the
    /// stated M2 exit criterion made literal.
    @Test func rebuildInABareMirrorCloneRecoversTheIdenticalJournal() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ids = threeIds()
        let a = try writeEntry(#"{"op":"one"}"#, id: ids.a, in: repo)
        let b = try writeEntry(#"{"op":"two"}"#, id: ids.b, in: repo)

        let mirrorPath = repo.url.deletingLastPathComponent()
            .appendingPathComponent("\(repo.url.lastPathComponent)-mirror")
        defer { try? FileManager.default.removeItem(at: mirrorPath) }
        try git.run(["clone", "-q", "--mirror", repo.url.path, mirrorPath.path])

        let mirror = try WorktreeContext.resolve(path: mirrorPath.path)
        #expect(mirror.isBare)
        let result = try JournalRebuild.rebuild(in: mirror)
        #expect(result == JournalRebuild.Result(entries: [a, b], defects: []))
    }

    /// The cache is derived, never consulted: a lying `journal.json` under
    /// the common dir changes nothing, and deleting the whole `switchyard/`
    /// state directory — for real, not mocked — loses nothing.
    @Test func rebuildIgnoresAndSurvivesDeletionOfTheCacheDirectory() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ids = threeIds()
        let a = try writeEntry(#"{"op":"kept"}"#, id: ids.a, in: repo)
        let expected = JournalRebuild.Result(entries: [a], defects: [])

        // A decoy cache that claims something else entirely. The path is
        // switchyard's own state file under $GIT_COMMON_DIR (#0156), not a
        // git file — git never reads or writes it.
        let stateDir = URL(fileURLWithPath: try context(of: repo).commonDir)
            .appendingPathComponent("switchyard")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let cache = stateDir.appendingPathComponent("journal.json")
        try Data(#"{"schemaVersion":1,"entries":[{"id":"NOT-A-REAL-ENTRY"}]}"#.utf8)
            .write(to: cache)

        #expect(try JournalRebuild.rebuild(in: context(of: repo)) == expected,
                "a present cache must not leak into a rebuild")

        try FileManager.default.removeItem(at: stateDir)
        #expect(!FileManager.default.fileExists(atPath: stateDir.path))
        #expect(try JournalRebuild.rebuild(in: context(of: repo)) == expected,
                "deleting the state directory must lose nothing")
    }

    // MARK: - Corruption

    /// An anchor whose snapshot commit is gone from the object database.
    /// `for-each-ref` still lists the ref (measured: exit 0, both formats),
    /// so the loss surfaces at content fetch — as a reported defect, with
    /// every healthy entry still recovered.
    @Test func rebuildSkipsAndReportsAnAnchorWhoseCommitIsMissing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ids = threeIds()
        let good = try writeEntry(#"{"op":"survivor"}"#, id: ids.a, in: repo)
        let doomed = try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: Data(#"{"op":"doomed"}"#.utf8)),
            id: ids.b, in: context(of: repo))

        // Delete the snapshot commit's loose object. The path comes from
        // `--git-path` (via WorktreeContext), never from string-building
        // onto `.git/`; a fresh fixture has run no gc, so the object is
        // loose by construction.
        let oid = doomed.commit
        let objectPath = try context(of: repo).path(
            for: "objects/\(oid.prefix(2))/\(oid.dropFirst(2))")
        try FileManager.default.removeItem(atPath: objectPath)

        let result = try JournalRebuild.rebuild(in: context(of: repo))
        #expect(result.entries == [good])
        #expect(result.defects == [.missingSnapshotCommit(id: ids.b, commit: doomed.commit)])
    }

    /// An anchor pointing at a blob under a perfectly valid entry id —
    /// `update-ref` accepts any object for a custom namespace (measured).
    @Test func rebuildSkipsAndReportsAnAnchorThatIsNotACommit() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ids = threeIds()
        let good = try writeEntry(#"{"op":"good"}"#, id: ids.a, in: repo)
        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data("not a snapshot".utf8)).lines.first)
        try plantAnchor(blob, id: ids.b, in: repo)

        let result = try JournalRebuild.rebuild(in: context(of: repo))
        #expect(result.entries == [good])
        #expect(result.defects == [.anchorNotACommit(id: ids.b, oid: blob, type: "blob")])
    }

    /// Snapshot commits that carry no metadata *blob*: one whose tree lacks
    /// the entry entirely, one where `metadata.json` is a tree. Both are
    /// reported per entry; the healthy entry still comes back.
    @Test func rebuildSkipsAndReportsSnapshotCommitsWithoutAMetadataBlob() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ids = threeIds()
        let good = try writeEntry(#"{"op":"good"}"#, id: ids.a, in: repo)

        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data("x".utf8)).lines.first)
        let plainTree = try #require(try git.run(
            ["mktree"], workingDirectory: repo.url.path,
            standardInput: Data("100644 blob \(blob)\tother.txt\n".utf8)).lines.first)
        let treeAsMetadata = try #require(try git.run(
            ["mktree"], workingDirectory: repo.url.path,
            standardInput: Data("040000 tree \(plainTree)\tmetadata.json\n".utf8)).lines.first)
        let identity = ["GIT_AUTHOR_NAME": "s", "GIT_AUTHOR_EMAIL": "s@invalid",
                        "GIT_COMMITTER_NAME": "s", "GIT_COMMITTER_EMAIL": "s@invalid"]
        let noMetadata = try #require(try git.run(
            ["commit-tree", plainTree, "-m", "no metadata"],
            workingDirectory: repo.url.path, extraEnvironment: identity).lines.first)
        let wrongType = try #require(try git.run(
            ["commit-tree", treeAsMetadata, "-m", "tree metadata"],
            workingDirectory: repo.url.path, extraEnvironment: identity).lines.first)
        try plantAnchor(noMetadata, id: ids.b, in: repo)
        try plantAnchor(wrongType, id: ids.c, in: repo)

        let result = try JournalRebuild.rebuild(in: context(of: repo))
        #expect(result.entries == [good])
        #expect(result.defects == [
            .missingMetadata(id: ids.b, commit: noMetadata),
            .missingMetadata(id: ids.c, commit: wrongType),
        ])
    }

    /// The two policies, side by side: a foreign ref in the namespace makes
    /// `JournalAnchor.list` throw — state confusion in normal operation —
    /// while rebuild reports it and recovers everything else, because a
    /// recovery that halts on the first oddity recovers nothing.
    @Test func rebuildReportsForeignRefsWhereListThrows() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ids = threeIds()
        let good = try writeEntry(#"{"op":"good"}"#, id: ids.a, in: repo)
        let c = try #require(repo.oids["c"])
        try git.run(["update-ref", JournalAnchor.refPrefix + "not-an-id", c],
                    workingDirectory: repo.url.path)

        #expect(throws: JournalAnchor.Error.self) {
            _ = try JournalAnchor.list(in: context(of: repo))
        }
        let result = try JournalRebuild.rebuild(in: context(of: repo))
        #expect(result.entries == [good])
        #expect(result.defects == [.foreignRef(name: JournalAnchor.refPrefix + "not-an-id")])
    }
}
