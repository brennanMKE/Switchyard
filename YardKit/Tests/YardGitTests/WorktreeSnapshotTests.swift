// WorktreeSnapshotTests.swift — worktree capture and restore round-trip exactly (#0152)
//
// Deliberately NOT @testable: #0171 composes this primitive through its
// public surface, so a member silently dropping to internal must fail here
// at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct WorktreeSnapshotTests {

    private let git = GitProcess()

    private func context(of repo: FixtureRepository) throws -> WorktreeContext {
        try WorktreeContext.resolve(path: repo.url.path)
    }

    private func fileBytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func indexBytes(in context: WorktreeContext) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: context.path(for: "index")))
    }

    private func unmergedListing(at path: String) throws -> String {
        try git.run(["ls-files", "--unmerged"], workingDirectory: path).text
    }

    private func treeListing(_ oid: String, at path: String) throws -> String {
        try git.run(["ls-tree", "-r", oid], workingDirectory: path).text
    }

    /// The captured bytes of one path inside a tree-ish, via `<oid>:<path>`.
    private func capturedBytes(
        of path: String, in oid: String, at repoPath: String
    ) throws -> Data {
        try git.run(["cat-file", "blob", "\(oid):\(path)"],
                    workingDirectory: repoPath).standardOutput
    }

    // MARK: - Capture form

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func captureOfADirtyWorktreeIsAStashFormCommit(
        format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        try "modified, unstaged\n".write(
            to: repo.url.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8)
        try repo.writeUntracked(["u.txt": "untracked\n"])
        let refsBefore = try repo.refNames()
        #expect(!refsBefore.isEmpty, "fixture must have refs to compare")

        let snap = try WorktreeSnapshot.capture(in: context(of: repo))

        // The commit's tree carries the tracked file's WORKTREE bytes, and
        // no untracked file.
        let tracked = try capturedBytes(
            of: "a.txt", in: snap.commit, at: repo.url.path)
        #expect(tracked == Data("modified, unstaged\n".utf8))
        #expect(!(try treeListing(snap.commit, at: repo.url.path).contains("u.txt")),
                "untracked files belong to the untracked tree, not the stash form")
        let untracked = try capturedBytes(
            of: "u.txt", in: snap.untrackedTree, at: repo.url.path)
        #expect(untracked == Data("untracked\n".utf8))

        // No stash entry, no ref of any kind: capture is invisible to the
        // journal's own ref scans.
        #expect(try git.run(["stash", "list"],
                            workingDirectory: repo.url.path).text.isEmpty)
        #expect(try repo.refNames() == refsBefore)
    }

    /// Capture must aim `add -u` at a temporary copy, never the real index:
    /// staging a path collapses its conflict stages, so the real index
    /// would have the user's conflict silently resolved (measured).
    @Test func worktreeCaptureLeavesTheRepositoryUntouched() throws {
        var repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let unmergedBefore = try unmergedListing(at: repo.url.path)
        #expect(!unmergedBefore.isEmpty, "fixture must actually be conflicted")
        let indexBefore = try indexBytes(in: ctx)
        let worktreeBefore = try fileBytes(repo.url.appendingPathComponent("f.txt"))

        _ = try WorktreeSnapshot.capture(in: ctx)

        #expect(try unmergedListing(at: repo.url.path) == unmergedBefore,
                "capture must not resolve the user's conflict")
        #expect(try indexBytes(in: ctx) == indexBefore,
                "capture must not modify the real index file")
        #expect(try fileBytes(repo.url.appendingPathComponent("f.txt")) == worktreeBefore,
                "capture must not modify the worktree")
    }

    /// `git stash create` fails outright here (measured: exit 1, `Cannot
    /// save the current index state`) — the reason this primitive is built
    /// from plumbing. The captured blob is the worktree's conflict-marker
    /// bytes, exactly.
    @Test func captureOnAConflictedWorktreePreservesConflictMarkerBytes() throws {
        var repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }
        let worktreeBytes = try fileBytes(repo.url.appendingPathComponent("f.txt"))
        #expect(String(decoding: worktreeBytes, as: UTF8.self).contains("<<<<<<<"),
                "fixture worktree must carry conflict markers")

        let snap = try WorktreeSnapshot.capture(in: context(of: repo))

        #expect(try capturedBytes(of: "f.txt", in: snap.commit,
                                  at: repo.url.path) == worktreeBytes)
    }

    // MARK: - Round trips

    /// The M2 exit criterion's combination: a worktree snapshot taken over
    /// an unmerged index survives a wreck and restores the conflict-marker
    /// bytes exactly.
    @Test func aConflictedWorktreeRoundTrips() throws {
        var repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let file = repo.url.appendingPathComponent("f.txt")
        let before = try fileBytes(file)

        let snap = try WorktreeSnapshot.capture(in: ctx)

        try "resolved\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try fileBytes(file) != before,
                "the wreck must have replaced the conflicted bytes")

        try snap.restore(in: ctx)
        #expect(try fileBytes(file) == before,
                "the conflict-marker bytes must be back, exactly")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func aTrackedModificationRoundTripsThroughWorktreeRestore(
        format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let a = repo.url.appendingPathComponent("a.txt")
        let staged = repo.url.appendingPathComponent("staged.txt")
        try "modified, unstaged\n".write(to: a, atomically: true, encoding: .utf8)
        try "staged, not committed\n".write(to: staged, atomically: true, encoding: .utf8)
        try git.run(["add", "staged.txt"], workingDirectory: repo.url.path)

        let snap = try WorktreeSnapshot.capture(in: ctx)

        try "wrecked\n".write(to: a, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: staged)
        #expect(!FileManager.default.fileExists(atPath: staged.path),
                "the wreck must have deleted the staged-new file")

        try snap.restore(in: ctx)
        #expect(try fileBytes(a) == Data("modified, unstaged\n".utf8))
        #expect(try fileBytes(staged) == Data("staged, not committed\n".utf8),
                "a staged-new file is tracked state and must restore")
    }

    @Test func anUntrackedFileSurvivesTheWorktreeRoundTrip() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        try repo.writeUntracked([
            "u.txt": "untracked\n",
            "sub/n.txt": "nested untracked\n",
        ])

        let snap = try WorktreeSnapshot.capture(in: ctx)

        try FileManager.default.removeItem(
            at: repo.url.appendingPathComponent("u.txt"))
        try FileManager.default.removeItem(
            at: repo.url.appendingPathComponent("sub"))
        #expect(!FileManager.default.fileExists(
            atPath: repo.url.appendingPathComponent("u.txt").path),
                "the wreck must have deleted the untracked files")

        try snap.restore(in: ctx)
        #expect(try fileBytes(repo.url.appendingPathComponent("u.txt"))
                == Data("untracked\n".utf8))
        #expect(try fileBytes(repo.url.appendingPathComponent("sub/n.txt"))
                == Data("nested untracked\n".utf8),
                "restore must recreate directories for nested untracked files")
    }

    /// The destructive half of the scope contract: a non-ignored file that
    /// did not exist at capture is deleted, because the capture recorded
    /// its absence.
    @Test func aFileCreatedAfterCaptureIsRemovedByRestore() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ctx = try context(of: repo)

        let snap = try WorktreeSnapshot.capture(in: ctx)

        let later = repo.url.appendingPathComponent("later.txt")
        try "created after the capture\n".write(
            to: later, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: later.path),
                "the wreck must have created the file")

        try snap.restore(in: ctx)
        #expect(!FileManager.default.fileExists(atPath: later.path),
                "restore must remove what the capture recorded as absent")
    }

    /// `add -u` records a deletion into the temporary index (measured), so
    /// a file deleted at capture is absent from the stash-form tree — and
    /// restore must re-delete it after it came back.
    @Test func aTrackedFileDeletedAtCaptureStaysDeletedAfterRestore() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let b = repo.url.appendingPathComponent("b.txt")
        try FileManager.default.removeItem(at: b)

        let snap = try WorktreeSnapshot.capture(in: ctx)
        #expect(!(try treeListing(snap.commit, at: repo.url.path).contains("b.txt")),
                "a file deleted in the worktree must be absent from the capture")

        try "came back\n".write(to: b, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: b.path),
                "the wreck must have recreated the file")

        try snap.restore(in: ctx)
        #expect(!FileManager.default.fileExists(atPath: b.path))
    }

    /// Guide §11 decision 3: ignored files ride in neither tree and are
    /// outside restore's deletion scope — never captured, never restored,
    /// never deleted.
    @Test func anIgnoredFileIsNeitherCapturedNorDeleted() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit(
            "ignore", files: [".gitignore": "build.log\n"])])
        let ctx = try context(of: repo)
        let ignored = repo.url.appendingPathComponent("build.log")
        try "ignored bytes\n".write(to: ignored, atomically: true, encoding: .utf8)
        #expect(try git.capture(["check-ignore", "-q", "build.log"],
                                workingDirectory: repo.url.path).exitCode == 0,
                "fixture must actually ignore the file")

        let snap = try WorktreeSnapshot.capture(in: ctx)
        #expect(!(try treeListing(snap.commit, at: repo.url.path).contains("build.log")))
        #expect(!(try treeListing(snap.untrackedTree, at: repo.url.path).contains("build.log")))

        try "wrecked ignored bytes\n".write(to: ignored, atomically: true, encoding: .utf8)
        try snap.restore(in: ctx)
        #expect(try fileBytes(ignored) == Data("wrecked ignored bytes\n".utf8),
                "restore must not rewrite an ignored file")
        #expect(FileManager.default.fileExists(atPath: ignored.path),
                "restore must not delete an ignored file")
    }

    /// The silent-loss case #0151 flagged as binding on this issue: an
    /// intent-to-add file is invisible to `ls-files --others`, so only the
    /// index-copy seeding captures its real bytes (measured — seeding from
    /// `HEAD` would drop it from both trees).
    @Test func anIntentToAddFilesContentSurvivesTheWorktreeRoundTrip() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let ctx = try context(of: repo)
        let ita = repo.url.appendingPathComponent("ita.txt")
        try "promised content\n".write(to: ita, atomically: true, encoding: .utf8)
        try git.run(["add", "-N", "ita.txt"], workingDirectory: repo.url.path)

        let snap = try WorktreeSnapshot.capture(in: ctx)
        #expect(try capturedBytes(of: "ita.txt", in: snap.commit,
                                  at: repo.url.path) == Data("promised content\n".utf8),
                "the capture must carry the ita file's real bytes, not the empty blob")

        try "wrecked\n".write(to: ita, atomically: true, encoding: .utf8)
        try snap.restore(in: ctx)
        #expect(try fileBytes(ita) == Data("promised content\n".utf8))
    }

    /// Both sides of the path-resolution rule at once (#0184's asymmetry,
    /// closed here from day one): capture in a linked worktree reads that
    /// worktree's index and files, and restore writes that worktree's files
    /// — with the main worktree byte-identical throughout, which is the
    /// failure a concatenated `.git/` path or a mis-derived base actually
    /// produces.
    @Test func aWorktreeRoundTripInALinkedWorktreeLeavesTheMainWorktreeUntouched() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        let mainA = repo.url.appendingPathComponent("a.txt")
        let mainBefore = try fileBytes(mainA)
        let mainCtx = try context(of: repo)
        let mainIndexBefore = try indexBytes(in: mainCtx)

        let wtA = wt.appendingPathComponent("a.txt")
        try "linked worktree edit\n".write(to: wtA, atomically: true, encoding: .utf8)
        try "linked untracked\n".write(
            to: wt.appendingPathComponent("wtonly.txt"),
            atomically: true, encoding: .utf8)
        let wtCtx = try WorktreeContext.resolve(path: wt.path)

        let snap = try WorktreeSnapshot.capture(in: wtCtx)
        #expect(try capturedBytes(of: "a.txt", in: snap.commit,
                                  at: wt.path) == Data("linked worktree edit\n".utf8),
                "capture must see the linked worktree's own modification")

        try "wrecked\n".write(to: wtA, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: wt.appendingPathComponent("wtonly.txt"))

        try snap.restore(in: wtCtx)
        #expect(try fileBytes(wtA) == Data("linked worktree edit\n".utf8))
        #expect(try fileBytes(wt.appendingPathComponent("wtonly.txt"))
                == Data("linked untracked\n".utf8))

        // The failure a wrong base actually produces is here, not above:
        // the main worktree gained or lost nothing.
        #expect(try fileBytes(mainA) == mainBefore,
                "the main worktree's files must be untouched")
        #expect(try indexBytes(in: mainCtx) == mainIndexBefore,
                "the main worktree's index must be untouched")
        #expect(!FileManager.default.fileExists(
            atPath: repo.url.appendingPathComponent("wtonly.txt").path),
                "the linked worktree's untracked file must not appear in the main worktree")
    }

    // MARK: - The wire mapping and the error contract

    /// `Captured.worktree`'s wire values are `false` / `"stash"` (#0155
    /// decision 4); a snapshot always maps to `"stash"` and always captures
    /// untracked files — the `false` cases belong to entries carrying no
    /// snapshot at all.
    @Test func worktreeCapturedMapsOntoTheMetadataWireValues() {
        let snap = WorktreeSnapshot(commit: "x", untrackedTree: "y")
        #expect(snap.captured == .stash)
        #expect(snap.capturedUntracked)
    }

    @Test func worktreeSnapshotErrorsCarryTheRepositoryExitClassAndNameTheirSubject() {
        let unreadable = WorktreeSnapshot.Error.indexFileUnreadable(
            path: "/r/.git/index", detail: "gone")
        let malformed = WorktreeSnapshot.Error.malformedPlumbingOutput(
            command: "commit-tree")
        let unremovable = WorktreeSnapshot.Error.worktreeFileUnremovable(
            path: "/r/later.txt", detail: "denied")
        let bare = WorktreeSnapshot.Error.noWorktree(gitDir: "/r/bare.git")
        for error in [unreadable, malformed, unremovable, bare] {
            #expect(error.exitClass == .repositoryError)
        }
        #expect(unreadable.description.contains("/r/.git/index"))
        #expect(unreadable.description.contains("gone"))
        #expect(malformed.description.contains("commit-tree"))
        #expect(unremovable.description.contains("/r/later.txt"))
        #expect(unremovable.description.contains("denied"))
        #expect(bare.description.contains("/r/bare.git"))
    }

    // MARK: - #0187 — extraEnvironment actually reaches git

    /// #0152 decision 3 claims an unchanged worktree dedupes because the
    /// snapshot commit's oid is a pure function of its tree. That holds only
    /// while the identity and both dates are pinned. Dropping
    /// `extraEnvironment: Self.commitEnvironment` from the `commit-tree` call
    /// leaves the whole suite green — measured in #0152's review: `ca60e77…`
    /// then `93d3b18…` for the same unchanged tree, versus `897ebfb…` twice
    /// as shipped — while authoring the commit with the machine's real git
    /// identity, which a --mirror clone then carries.
    ///
    /// This asserts the observable effect — determinism of the oid across
    /// two captures and the pinned anonymous author line, not that a
    /// dictionary was passed.
    @Test func theSnapshotCommitIsDeterministicAndAnonymous() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        // First capture — make a real change so the snapshot has content.
        let filepath = repo.url.appendingPathComponent("a.txt")
        try "initial\n".write(to: filepath, atomically: true, encoding: .utf8)
        let first = try WorktreeSnapshot.capture(in: context)

        // Second capture — identical tree, deterministic oid.
        let second = try WorktreeSnapshot.capture(in: context)
        #expect(first.commit == second.commit,
                "an unchanged worktree must produce the same commit oid")

        // The pinned anonymous author line, not the machine's identity.
        let showOutput = try GitProcess().run(
            ["show", "-s", "--format=%an <%ae> %ad", "--date=iso-strict",
             first.commit],
            workingDirectory: repo.url.path).text
        #expect(showOutput.contains("switchyard <journal@switchyard.invalid>"),
                "snapshot commits must be authored as switchyard, not the user")

        // The PINNED DATE is what actually carries the dedup claim (#0152
        // decision 3, binding on #0171). The equality above passes even with
        // the environment dropped, because two captures a fraction of a
        // second apart still share a wall-clock timestamp — so without this
        // assertion the determinism half proves identity and nothing else.
        #expect(showOutput.contains("2000-01-01"),
                "the author date must be pinned, or the oid is time-dependent")

        let realName = try GitProcess().run(
            ["config", "user.name"],
            workingDirectory: repo.url.path).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!realName.isEmpty,
                "the fixture must set user.name; else the check below is vacuous")

        #expect(!showOutput.contains(realName),
                "the machine's real identity must not appear on the snapshot commit")
    }
}
