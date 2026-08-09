// IndexSnapshotTests.swift — index capture and restore round-trip exactly (#0151)
//
// Deliberately NOT @testable: #0171 composes this primitive through its
// public surface, so a member silently dropping to internal must fail here
// at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct IndexSnapshotTests {

    private let git = GitProcess()

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    /// The real index file's bytes — the test-side use of the same
    /// sanctioned exception the production code documents.
    private func indexBytes(in context: WorktreeContext) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: context.path(for: "index")))
    }

    private func stageListing(at path: String) throws -> String {
        try git.run(["ls-files", "-s"], workingDirectory: path).text
    }

    private func unmergedListing(at path: String) throws -> String {
        try git.run(["ls-files", "--unmerged"], workingDirectory: path).text
    }

    // MARK: - Capture form

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func captureOfAMergedIndexIsATree(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try "staged, not committed\n".write(
            to: repo.url.appendingPathComponent("staged.txt"),
            atomically: true, encoding: .utf8)
        try git.run(["add", "staged.txt"], workingDirectory: repo.url.path)

        let snap = try IndexSnapshot.capture(in: context(of: repo))
        guard case let .tree(oid) = snap else {
            Issue.record("expected .tree, got \(snap)")
            return
        }
        let listing = try git.run(["ls-tree", "-r", oid],
                                  workingDirectory: repo.url.path)
        #expect(listing.text.contains("staged.txt"),
                "the captured tree must carry the staged-but-uncommitted entry")
    }

    /// Capture must never aim `write-tree` at the real index: a successful
    /// `write-tree` writes a cache-tree extension back into its index file
    /// (measured), so anything but a temporary copy corrupts the capture
    /// guarantee that nothing mutated.
    @Test func captureDoesNotTouchTheRealIndex() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try "staged\n".write(
            to: repo.url.appendingPathComponent("staged.txt"),
            atomically: true, encoding: .utf8)
        try git.run(["add", "staged.txt"], workingDirectory: repo.url.path)
        let ctx = try context(of: repo)

        let before = try indexBytes(in: ctx)
        _ = try IndexSnapshot.capture(in: ctx)
        #expect(try indexBytes(in: ctx) == before,
                "capture must not modify the real index file")
    }

    @Test func captureOfAConflictedIndexIsARawBlobByteIdenticalToTheIndexFile() throws {
        var repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        #expect(repo.hasConflicts, "fixture must actually be conflicted")

        let snap = try IndexSnapshot.capture(in: ctx)
        guard case let .raw(blob) = snap else {
            Issue.record("expected .raw for an unmerged index, got \(snap)")
            return
        }
        let stored = try git.run(["cat-file", "blob", blob],
                                 workingDirectory: repo.url.path).standardOutput
        #expect(stored == (try indexBytes(in: ctx)),
                "the blob must be the index file's bytes, exactly")
    }

    // MARK: - Round trips

    @Test func aConflictedIndexRoundTripsExactly() throws {
        var repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let before = try unmergedListing(at: repo.url.path)
        let beforeBytes = try indexBytes(in: ctx)
        #expect(!before.isEmpty, "fixture must actually be conflicted")

        let snap = try IndexSnapshot.capture(in: ctx)

        // Wreck: resolve the conflict, the way an agent would.
        try "resolved\n".write(to: repo.url.appendingPathComponent("f.txt"),
                               atomically: true, encoding: .utf8)
        try git.run(["add", "f.txt"], workingDirectory: repo.url.path)
        #expect(try unmergedListing(at: repo.url.path).isEmpty,
                "the wreck must have cleared the conflict")

        try snap.restore(in: ctx)
        #expect(try unmergedListing(at: repo.url.path) == before)
        #expect(try indexBytes(in: ctx) == beforeBytes,
                "an unmerged index restores byte-for-byte")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aMergedIndexWithStagedChangesRoundTrips(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try "staged edit\n".write(
            to: repo.url.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8)
        try git.run(["add", "a.txt"], workingDirectory: repo.url.path)
        let ctx = try context(of: repo)
        let before = try stageListing(at: repo.url.path)

        let snap = try IndexSnapshot.capture(in: ctx)

        try git.run(["read-tree", "HEAD"], workingDirectory: repo.url.path)
        #expect(try stageListing(at: repo.url.path) != before,
                "the wreck must have discarded the staged edit")

        try snap.restore(in: ctx)
        #expect(try stageListing(at: repo.url.path) == before)
    }

    /// The undo direction: the entry captured a clean index, and by the
    /// time it is restored the repository is mid-conflict. `read-tree`
    /// replaces an unmerged index without complaint (measured).
    @Test func restoringATreeOverAConflictedIndexClearsIt() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("base", files: ["f.txt": "original\n"])])
        try repo.build([FixtureRepository.Commit("ours", parents: ["base"],
                                                 files: ["f.txt": "ours\n"])])
        try repo.build([FixtureRepository.Commit("theirs", parents: ["base"],
                                                 files: ["f.txt": "theirs\n"])])
        let ours = try #require(repo.oids["ours"])
        let theirs = try #require(repo.oids["theirs"])
        try repo.checkoutDetached(ours)
        let ctx = try context(of: repo)
        let before = try stageListing(at: repo.url.path)

        let snap = try IndexSnapshot.capture(in: ctx)

        _ = try git.capture(["merge", "--no-commit", theirs],
                            workingDirectory: repo.url.path)
        #expect(!(try unmergedListing(at: repo.url.path).isEmpty),
                "the wreck must have produced a real conflict")

        try snap.restore(in: ctx)
        #expect(try unmergedListing(at: repo.url.path).isEmpty)
        #expect(try stageListing(at: repo.url.path) == before)
    }

    // MARK: - Index state a tree cannot carry

    /// A tree round trip clears skip-worktree and assume-unchanged bits
    /// (measured: `S` became `H`), so their presence must force the raw
    /// form, which preserves them.
    @Test func aSkipWorktreeFlagForcesRawCaptureAndSurvivesTheRoundTrip() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try git.run(["update-index", "--skip-worktree", "b.txt"],
                    workingDirectory: repo.url.path)
        let ctx = try context(of: repo)
        let before = try git.run(["ls-files", "-v"], workingDirectory: repo.url.path).text
        #expect(before.contains("S b.txt"), "fixture must carry the flag")

        let snap = try IndexSnapshot.capture(in: ctx)
        guard case .raw = snap else {
            Issue.record("expected .raw for a flagged index, got \(snap)")
            return
        }

        try git.run(["update-index", "--no-skip-worktree", "b.txt"],
                    workingDirectory: repo.url.path)
        #expect(!(try git.run(["ls-files", "-v"],
                              workingDirectory: repo.url.path).text.contains("S b.txt")),
                "the wreck must have cleared the flag")

        try snap.restore(in: ctx)
        #expect(try git.run(["ls-files", "-v"],
                            workingDirectory: repo.url.path).text == before)
    }

    /// `write-tree` succeeds on an index with an intent-to-add entry and
    /// silently drops the entry from the tree (measured) — the case the
    /// entry-count comparison exists for. Raw capture preserves it.
    @Test func anIntentToAddEntryForcesRawCaptureAndSurvivesTheRoundTrip() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try "promised\n".write(to: repo.url.appendingPathComponent("ita.txt"),
                               atomically: true, encoding: .utf8)
        try git.run(["add", "-N", "ita.txt"], workingDirectory: repo.url.path)
        let ctx = try context(of: repo)
        let before = try stageListing(at: repo.url.path)
        #expect(before.contains("ita.txt"), "the ita entry must be in the index")

        let snap = try IndexSnapshot.capture(in: ctx)
        guard case .raw = snap else {
            Issue.record("expected .raw for an intent-to-add index, got \(snap)")
            return
        }

        try git.run(["read-tree", "HEAD"], workingDirectory: repo.url.path)
        #expect(!(try stageListing(at: repo.url.path).contains("ita.txt")),
                "the wreck must have dropped the ita entry")

        try snap.restore(in: ctx)
        #expect(try stageListing(at: repo.url.path) == before)
    }

    /// A raw snapshot of a split index must not reference
    /// `sharedindex.<sha>`, which git prunes on its own schedule: capture
    /// normalizes the copy to the self-contained form, so the snapshot
    /// stays restorable after the shared file is gone (a dangling link is
    /// fatal, exit 128 — measured).
    @Test func aSplitIndexIsCapturedSelfContained() throws {
        var repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let before = try unmergedListing(at: repo.url.path)
        #expect(!before.isEmpty, "fixture must actually be conflicted")
        try git.run(["update-index", "--split-index"],
                    workingDirectory: repo.url.path)

        let snap = try IndexSnapshot.capture(in: ctx)
        let blob = try #require({ if case let .raw(blob) = snap { blob } else { nil } }(),
                                "expected .raw for an unmerged index")
        let stored = try git.run(["cat-file", "blob", blob],
                                 workingDirectory: repo.url.path).standardOutput
        #expect(stored != (try indexBytes(in: ctx)),
                "the snapshot must be the merged form, not the split link file")

        // Wreck: back to a normal index, conflict resolved.
        try git.run(["update-index", "--no-split-index"],
                    workingDirectory: repo.url.path)
        try "resolved\n".write(to: repo.url.appendingPathComponent("f.txt"),
                               atomically: true, encoding: .utf8)
        try git.run(["add", "f.txt"], workingDirectory: repo.url.path)

        try snap.restore(in: ctx)
        #expect(try unmergedListing(at: repo.url.path) == before)

        // Simulate git's own expiry: with every sharedindex gone, the
        // restored index must still read — the self-containment claim.
        let gitDir = ctx.gitDir
        for name in try FileManager.default.contentsOfDirectory(atPath: gitDir)
        where name.hasPrefix("sharedindex.") {
            try FileManager.default.removeItem(
                atPath: gitDir + "/" + name)
        }
        #expect(try unmergedListing(at: repo.url.path) == before,
                "the restored index must not depend on a sharedindex file")
    }

    // MARK: - Edges

    /// A fresh repository has no index file at all; git reads that as an
    /// empty index (measured: `write-tree` prints the empty tree, exit 0).
    @Test func aMissingIndexFileCapturesAsTheEmptyTree() throws {
        let repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        #expect(!FileManager.default.fileExists(atPath: try ctx.path(for: "index")))

        let snap = try IndexSnapshot.capture(in: ctx)
        let emptyTree = try #require(
            git.run(["mktree"], workingDirectory: repo.url.path,
                    standardInput: Data()).lines.first)
        #expect(snap == .tree(oid: emptyTree))

        // Restoring the empty capture empties an index that gained entries.
        try "x\n".write(to: repo.url.appendingPathComponent("x.txt"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "x.txt"], workingDirectory: repo.url.path)
        try snap.restore(in: ctx)
        #expect(try stageListing(at: repo.url.path).isEmpty)
    }

    /// The index is per-worktree: capture in a linked worktree must read
    /// that worktree's index — resolved via `--git-path`, which points into
    /// `$GIT_DIR/worktrees/<name>/` there (measured), not at
    /// `<topLevel>/.git/index`, which in a linked worktree is not even a
    /// directory path.
    @Test func captureInALinkedWorktreeSeesItsOwnIndex() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        try "worktree only\n".write(to: wt.appendingPathComponent("wtonly.txt"),
                                    atomically: true, encoding: .utf8)
        try git.run(["add", "wtonly.txt"], workingDirectory: wt.path)

        let inWorktree = try IndexSnapshot.capture(
            in: WorktreeContext.resolve(path: wt.path))
        let inMain = try IndexSnapshot.capture(in: context(of: repo))
        let wtTree = try #require({ if case let .tree(oid) = inWorktree { oid } else { nil } }())
        let mainTree = try #require({ if case let .tree(oid) = inMain { oid } else { nil } }())
        #expect(try git.run(["ls-tree", "-r", wtTree],
                            workingDirectory: wt.path).text.contains("wtonly.txt"))
        #expect(!(try git.run(["ls-tree", "-r", mainTree],
                              workingDirectory: repo.url.path).text.contains("wtonly.txt")))
    }

    // MARK: - The wire mapping and the error contract

    /// `Captured.index`'s wire values are `false` / `"tree"` / `"raw"`
    /// (#0155 decision 4); this primitive's two cases map onto the two
    /// captured ones and nothing else.
    @Test func capturedMapsOntoTheMetadataWireValues() {
        #expect(IndexSnapshot.tree(oid: "x").captured == .tree)
        #expect(IndexSnapshot.raw(blob: "y").captured == .raw)
    }

    @Test func errorsCarryTheRepositoryExitClassAndNameTheirSubject() {
        let unreadable = IndexSnapshot.Error.indexFileUnreadable(
            path: "/r/.git/index", detail: "gone")
        let unwritable = IndexSnapshot.Error.indexFileUnwritable(
            path: "/r/.git/index", detail: "denied")
        let malformed = IndexSnapshot.Error.malformedPlumbingOutput(
            command: "hash-object")
        for error in [unreadable, unwritable, malformed] {
            #expect(error.exitClass == .repositoryError)
        }
        #expect(unreadable.description.contains("/r/.git/index"))
        #expect(unreadable.description.contains("gone"))
        #expect(unwritable.description.contains("denied"))
        #expect(malformed.description.contains("hash-object"))
    }

    /// #0151 pinned the `$GIT_DIR` rule on the CAPTURE side only: its row 6
    /// concatenates `.git/index` in `capture` and dies here. The mirror
    /// mutation in `restore` left all 13 tests green, because no test ever
    /// took the RAW path inside a linked worktree — capture there returns
    /// `.tree`. #0171 composes exactly that path, and an unmerged index in an
    /// agent worktree is what M2's criterion names.
    ///
    /// Measured: in a linked worktree `.git` is a FILE, so a concatenated
    /// `.git/index` is unreachable (`ENOTDIR`) rather than wrongly reachable.
    @Test func rawRestoreInALinkedWorktreeWritesItsOwnIndex() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-b", branch: "agent-b-branch")
        defer { try? FileManager.default.removeItem(at: wt) }

        // Force the raw path: skip-worktree makes `ls-files -v` print `S`,
        // which #0151 treats as raw even though write-tree would succeed.
        try "raw path\n".write(to: wt.appendingPathComponent("skipped.txt"),
                                atomically: true, encoding: .utf8)
        try git.run(["add", "skipped.txt"], workingDirectory: wt.path)
        try git.run(["update-index", "--skip-worktree", "skipped.txt"],
                    workingDirectory: wt.path)

        let ctx = try WorktreeContext.resolve(path: wt.path)
        let snapshot = try IndexSnapshot.capture(in: ctx)
        guard case .raw = snapshot else {
            Issue.record("expected a raw capture, got \(snapshot)")
            return
        }

        let wtIndexPath = try ctx.path(for: "index", git: git)
        let before = try Data(contentsOf: URL(fileURLWithPath: wtIndexPath))
        let mainCtx = try WorktreeContext.resolve(path: repo.url.path)
        let mainIndexPath = try mainCtx.path(for: "index", git: git)
        let mainBefore = try Data(contentsOf: URL(fileURLWithPath: mainIndexPath))

        // Wreck the linked worktree's index, and prove the wreck took effect.
        try git.run(["read-tree", "--empty"], workingDirectory: wt.path)
        #expect(try git.run(["ls-files"], workingDirectory: wt.path).text.isEmpty)

        try snapshot.restore(in: ctx)

        #expect(try Data(contentsOf: URL(fileURLWithPath: wtIndexPath)) == before)
        #expect(try git.run(["ls-files", "-v"], workingDirectory: wt.path)
            .text.contains("S skipped.txt"))
        // The main worktree's index must be untouched by any of this.
        #expect(try Data(contentsOf: URL(fileURLWithPath: mainIndexPath)) == mainBefore)
    }
}
