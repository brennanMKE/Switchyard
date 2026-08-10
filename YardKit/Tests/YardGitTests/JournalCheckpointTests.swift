// JournalCheckpointTests.swift — capture state and write one journal entry (#0167)
//
// Deliberately NOT @testable: the checkpoint flow is the primitive every
// restore-class flow (#0168, #0169) calls as a public caller, so a member
// silently dropping to internal must fail here at compile time (the #0116
// failure class).

import Foundation
import Testing
import YardGit

struct JournalCheckpointTests {

    private let git = GitProcess()

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    /// The entry's decoded metadata, via the same cat-file path #0030 uses.
    private func metadata(
        of entry: JournalAnchor.Entry, in ctx: WorktreeContext
    ) throws -> JournalEntryMetadata {
        try JournalEntryMetadata(
            serialized: JournalAnchor.metadata(for: entry.id, in: ctx))
    }

    /// A commit reachable from nothing — no ref, no reflog — with unique
    /// content, so only the checkpoint's keep-alive parenthood can save it
    /// from `gc --prune=now` once whatever ref the test hangs it on is gone.
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

    // MARK: - One entry, honest metadata

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func checkpointWritesExactlyOneHonestEntry(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        // "fixup", not "checkpoint": an implementation hardcoding the
        // operation string must fail here.
        let entry = try JournalCheckpoint.checkpoint(
            operation: "fixup", label: "before rebase", in: ctx)

        #expect(try JournalAnchor.list(in: ctx) == [entry])
        let meta = try metadata(of: entry, in: ctx)
        #expect(meta.id == entry.id)
        #expect(meta.operation == "fixup")
        #expect(meta.label == "before rebase")
        #expect(meta.command == nil)
        #expect(meta.agent == nil)
        #expect(meta.traversal == nil)
        #expect(meta.worktree.name == nil)
        // #0171 flipped the flags: a checkpoint captures the index and the
        // worktree too, and `captured` must say so or restore's report lies.
        #expect(meta.captured.refs)
        #expect(meta.captured.head)
        #expect(meta.captured.index != .notCaptured)
        #expect(meta.captured.worktree == .stash)
        #expect(meta.captured.untracked)
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func everyPassThroughFieldReachesTheMetadata(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        let restored = JournalEntryID.generate()
        let entry = try JournalCheckpoint.checkpoint(
            operation: "undo",
            command: "switchyard undo",
            agent: .init(name: "claude-code", session: "s-1"),
            traversal: .init(restored: restored, resultingPosition: restored),
            in: ctx)

        let meta = try metadata(of: entry, in: ctx)
        #expect(meta.command == "switchyard undo")
        #expect(meta.agent == .init(name: "claude-code", session: "s-1"))
        #expect(meta.traversal == .init(restored: restored, resultingPosition: restored))
    }

    // MARK: - The refs blob is the captured state

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func theRefsBlobReadsBackToTheCapturedState(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        let before = try RefSnapshot.capture(in: ctx)
        try #require(!before.refs.isEmpty)  // vacuity guard: comparing nothing proves nothing
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)

        let blob = try git.run(
            ["cat-file", "blob",
             JournalAnchor.refName(for: entry.id) + ":" + JournalAnchor.refsTreeEntryName],
            workingDirectory: repo.url.path)
        #expect(try RefSnapshot(serialized: blob.standardOutput) == before)
    }

    // MARK: - Per-repository visibility

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aCheckpointFromALinkedWorktreeIsListedFromTheMain(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wtURL = try repo.addWorktree(named: "agent", branch: "agent-branch")
        let wtCtx = try WorktreeContext.resolve(path: wtURL.path)
        let name = try #require(wtCtx.worktreeName)

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: wtCtx)

        let mainCtx = try context(of: repo)
        #expect(try JournalAnchor.list(in: mainCtx) == [entry])
        #expect(try metadata(of: entry, in: mainCtx).worktree.name == name)
    }

    // MARK: - Id generation is wired through the newest existing entry

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func entryIdsAscendPastAFutureNewestEntry(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        // An existing entry whose timestamp is decades ahead: without the
        // generate(after:) wiring the new id would sort below it.
        let future = JournalEntryID.generate(now: Date(timeIntervalSince1970: 4_000_000_000))
        try JournalAnchor.write(
            .init(metadataJSON: Data("stub".utf8)), id: future, in: ctx)

        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        #expect(entry.id > future)
        #expect(try JournalAnchor.list(in: ctx).map(\.id) == [future, entry.id])
    }

    // MARK: - Keep-alive parenthood

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func deletedBranchHistorySurvivesAggressiveGC(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let victim = try unreachableCommit(in: repo, marker: "branch \(format.rawValue)")
        try git.run(["update-ref", "refs/heads/doomed", victim], workingDirectory: repo.url.path)

        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try git.run(["update-ref", "-d", "refs/heads/doomed", victim],
                    workingDirectory: repo.url.path)
        try aggressivelyCollect(repo)
        #expect(try exists(victim, in: repo))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func annotatedTagHistoryIsKeptByItsPeeledCommit(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let victim = try unreachableCommit(in: repo, marker: "tag \(format.rawValue)")
        try git.run(["tag", "-a", "keepme", "-m", "annotated", victim],
                    workingDirectory: repo.url.path,
                    extraEnvironment: ["GIT_COMMITTER_NAME": "v", "GIT_COMMITTER_EMAIL": "v@invalid"])
        let tagObject = try #require(try git.run(
            ["rev-parse", "refs/tags/keepme"], workingDirectory: repo.url.path).lines.first)
        try #require(tagObject != victim)  // annotated: the ref holds a tag object

        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try git.run(["tag", "-d", "keepme"], workingDirectory: repo.url.path)
        try aggressivelyCollect(repo)

        // The peeled commit is kept; the tag *object* is not — nothing can
        // parent a tag, so restoring this ref after gc fails atomically
        // (measured at the planning pass; #0168 documents the surface).
        #expect(try exists(victim, in: repo))
        #expect(try !exists(tagObject, in: repo))
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aTagPointingAtABlobDoesNotBreakTheCheckpoint(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let blob = try #require(try git.run(
            ["hash-object", "-w", "--stdin"], workingDirectory: repo.url.path,
            standardInput: Data("just bytes\n".utf8)).lines.first)
        try git.run(["tag", "-a", "blobtag", "-m", "tagged blob", blob],
                    workingDirectory: repo.url.path,
                    extraEnvironment: ["GIT_COMMITTER_NAME": "v", "GIT_COMMITTER_EMAIL": "v@invalid"])

        // Unpeelable to a commit: skipped from keep-alive, never handed to
        // commit-tree as a parent (which would be fatal, exit 128).
        let entry = try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        #expect(try JournalAnchor.list(in: ctx) == [entry])
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aDetachedHeadCommitIsKeptAlive(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let victim = try unreachableCommit(in: repo, marker: "detached \(format.rawValue)")
        try repo.checkoutDetached(victim)
        let ctx = try context(of: repo)

        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        try repo.checkout("main")
        try aggressivelyCollect(repo)
        #expect(try exists(victim, in: repo))
    }

    // MARK: - The lock wraps the whole flow

    /// Single format on purpose: the lock is `flock(2)` on a file under the
    /// common dir — filesystem behavior, nothing the ref backend touches.
    @Test func checkpointContendsForTheJournalLockAndFailsTyped() throws {
        let repo = try FixtureRepository.linear(refFormat: .files)
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        try JournalLock(context: ctx).withLock {
            #expect(throws: JournalLockError.self) {
                try JournalCheckpoint.checkpoint(
                    operation: "checkpoint", lockTimeout: .milliseconds(50), in: ctx)
            }
        }
        // Nothing was written while the lock was held, and a released lock
        // lets the same call through.
        #expect(try JournalAnchor.list(in: ctx).isEmpty)
        try JournalCheckpoint.checkpoint(operation: "checkpoint", in: ctx)
        #expect(try JournalAnchor.list(in: ctx).count == 1)
    }
}
