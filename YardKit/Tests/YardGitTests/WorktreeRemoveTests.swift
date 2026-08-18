// WorktreeRemoveTests.swift

import Foundation
import Testing
@testable import YardGit

/// Round 2 tests for `worktreeRemove`. Exercises the real failure path via
/// FixtureRepository (a real git process, not a mock). Uses only the APIs that
/// actually exist on `WorktreeContext` and `FixtureRepository`; see the round-1
/// review for what was wrong in round 1.

struct WorktreeRemoveTests {

    // MARK: - Helpers

    /// Resolves the main repository path from a fixture. Per rule 2 in
    /// `issues/0095.md`, the first entry of `git worktree list --porcelain` is
    /// always the main worktree, even when invoked from inside a linked one.
    private func repoPath(for fixture: FixtureRepository, git: GitProcess) throws -> String {
        let out = try git.capture(
            ["worktree", "list", "--porcelain"],
            workingDirectory: fixture.url.path
        )
        // First `worktree <path>` line is the main worktree.
        for line in out.lines {
            if line.hasPrefix("worktree ") {
                return String(line.dropFirst(9))
            }
        }
        // As a fallback, if the fixture has no linked worktrees yet, its url IS
        // the main repo path.
        return fixture.url.path
    }

    /// Check whether a directory exists at the given URL path. Used before and
    /// after remove to assert existence state without depending on `git worktree
    /// list`.
    private func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Tests

    /// A clean linked worktree is removed cleanly.
    @Test("removes an existing linked worktree without forcing", arguments: FixtureRepository.RefFormat.supported())
    func removesExistingWorktree(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        let worktreeURL: URL = try fixture.addWorktree(named: "clean-wt", branch: "main")

        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        #expect(exists(at: worktreeURL), "worktree should exist before remove")

        let result: WorktreeRemoveResult = try worktreeRemove(
            at: repoPath,
            worktreeURL.path,
            git: git
        )

        #expect(result.success)
        #expect(!result.forced)
        #expect(!result.lockedRelease)
        #expect(!exists(at: worktreeURL), "worktree directory should be gone after clean removal")
    }

    /// An unclean worktree (one modified tracked file, one untracked file) is
    /// refused without --force. The error names both dirty paths by content,
    /// not merely by count — a constant-returning mutation of
    /// `extractDirtyPaths` would slip past a single-file fixture, so this one
    /// carries two distinguishable paths (#0282's lesson). The directory still
    /// exists afterwards.
    @Test("refuses to remove a dirty worktree without force", arguments: FixtureRepository.RefFormat.supported())
    func refusesDirtyWorktreeWithoutForce(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        // A real commit so the worktree checks out a tracked file we can then
        // modify. Without a prior commit `main` is unborn and the worktree
        // starts empty, leaving nothing to modify -- only the untracked case.
        try fixture.build([
            FixtureRepository.Commit("initial", files: ["tracked.txt": "original content\n"])
        ])

        // `main` already names a real branch once the fixture has a commit, so
        // the worktree's new branch must have a different name -- `-b main`
        // would fail with "a branch named 'main' already exists".
        let worktreeURL: URL = try fixture.addWorktree(named: "dirty-wt", branch: "dirty-wt-branch")

        // Modify the tracked file so it is dirty in the worktree side of the
        // index, and add a second, untracked file -- two distinguishable
        // dirty paths, not one.
        let trackedFile = worktreeURL.appendingPathComponent("tracked.txt")
        try "modified content".write(to: trackedFile, atomically: true, encoding: .utf8)

        let untrackedFile = worktreeURL.appendingPathComponent("dirty.txt")
        try "this is dirty content".write(to: untrackedFile, atomically: true, encoding: .utf8)

        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        #expect(exists(at: worktreeURL), "worktree should exist before removal attempt")

        let result: WorktreeRemoveResult = try worktreeRemove(
            at: repoPath,
            worktreeURL.path,
            force: false,
            git: git
        )

        #expect(!result.success)
        if case let .unclean(paths) = result.error {
            #expect(!paths.isEmpty, "error should name dirty paths")
            #expect(paths.contains("tracked.txt"), "error should name the modified tracked file")
            #expect(paths.contains("dirty.txt"), "error should name the untracked file")
            #expect(paths.count == 2, "exactly the two dirty paths should be named, no more")
            #expect(!paths.contains(""), "no path entry should be empty")
        } else {
            Issue.record("expected .unclean error, got \(String(describing: result.error))")
        }

        #expect(exists(at: worktreeURL), "worktree directory should still exist after refusal")
    }

    /// An unclean worktree with --force is removed.
    @Test("removes a dirty worktree when forced", arguments: FixtureRepository.RefFormat.supported())
    func removesDirtyWorktreeWithForce(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        let worktreeURL: URL = try fixture.addWorktree(named: "forced-dirty-wt", branch: "main")

        let dirtFile = worktreeURL.appendingPathComponent("dirty.txt")
        try "forced dirty content".write(to: dirtFile, atomically: true, encoding: .utf8)

        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        #expect(exists(at: worktreeURL))

        let result: WorktreeRemoveResult = try worktreeRemove(
            at: repoPath,
            worktreeURL.path,
            force: true,
            git: git
        )

        #expect(result.success)
        #expect(result.forced, "removal should record that force was used")
        #expect(!exists(at: worktreeURL), "worktree should be gone after forced removal")
    }

    /// A worktree locked by an agent session is unlocked then removed cleanly.
    @Test("releases an agent lock before removing a clean worktree", arguments: FixtureRepository.RefFormat.supported())
    func releasesAgentLock(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        let worktreeURL: URL = try fixture.addWorktree(named: "agent-wt", branch: "main")
        try fixture.lockWorktree(worktreeURL, reason: "agent session id-42")

        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        #expect(exists(at: worktreeURL))

        let result: WorktreeRemoveResult = try worktreeRemove(
            at: repoPath,
            worktreeURL.path,
            git: git
        )

        #expect(result.success)
        #expect(result.lockedRelease, "should have released an agent lock")
        #expect(!exists(at: worktreeURL))

        // A second list confirms the entry is gone, lock and all. Asserting the
        // entry's `locked` flag inside an `if let` would assert nothing: the
        // worktree was just removed, so the binding never succeeds and the block
        // never runs.
        let entries = try worktreeList(path: repoPath, git: git)
        // Without this, `!contains` would pass on an empty list — which is what a
        // broken `worktreeList` returns.
        #expect(!entries.isEmpty, "the main worktree is always listed")
        #expect(!entries.contains { ($0.path ?? "").hasSuffix(worktreeURL.lastPathComponent) },
                "the removed worktree should no longer be listed at all")
    }

    /// A worktree locked with a **non-agent** reason — the kind a human would write,
    /// with no occurrence of the word "agent" — must be left alone.
    /// `worktreeRemove` documents (WorktreeRemove.swift:117-120) that it releases
    /// only agent-session locks and "leave[s] other locks alone — a human lock is
    /// not the same as an agent session." Every other locked-worktree test in this
    /// file locks with an agent reason, so nothing else exercises that half of the
    /// condition. This test reddens under the mutation that replaces
    /// `reason.contains("agent")` with a tautology, while the agent-lock tests
    /// above stay green.
    @Test("leaves a human lock in place and refuses removal", arguments: FixtureRepository.RefFormat.supported())
    func leavesHumanLockAlone(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        let worktreeURL: URL = try fixture.addWorktree(named: "human-locked-wt", branch: "main")
        try fixture.lockWorktree(worktreeURL, reason: "reviewed by Brennan, keep until sign-off")

        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        #expect(exists(at: worktreeURL))

        let result: WorktreeRemoveResult = try worktreeRemove(
            at: repoPath,
            worktreeURL.path,
            git: git
        )

        #expect(!result.success, "a human-locked worktree must not be removed")
        #expect(!result.lockedRelease, "a non-agent lock must not be released")
        #expect(exists(at: worktreeURL), "worktree directory should still exist after refusal")

        // Measured directly: `git worktree remove` on a locked worktree exits 128
        // with "fatal: cannot remove a locked working tree, lock reason: <reason>
        // \nuse 'remove -f -f' to override or unlock first" -- a different message
        // than the dirty-worktree case, and one that does not end in "use --force
        // to delete it", so `extractDirtyPaths` finds no path list to parse and the
        // refusal surfaces as `.unclean` with an empty path array rather than
        // `.unknownFailure`.
        if case let .unclean(paths) = result.error {
            #expect(paths.isEmpty, "git's locked-worktree message carries no dirty-path list to parse")
        } else {
            Issue.record("expected .unclean(paths: []) for a refused locked removal, got \(String(describing: result.error))")
        }

        // The worktree entry is still listed, and still shows the lock in place.
        let entries = try worktreeList(path: repoPath, git: git)
        guard let entry = entries.first(where: { ($0.path ?? "").hasSuffix(worktreeURL.lastPathComponent) }) else {
            Issue.record("worktree entry should still be listed after a refused removal")
            return
        }
        #expect(entry.locked, "the human lock should still be present")
    }

    /// When releasing an agent lock fails for real, the caller sees git's own
    /// stderr in `.lockFailed`'s `detail` — not Foundation's generic
    /// `localizedDescription` fallback (#0195). We force a genuine failure by
    /// making the worktree's private git-dir read-only, so `git worktree
    /// unlock` cannot unlink its `locked` file.
    @Test("lockFailed detail carries git's stderr, not the Foundation fallback", arguments: FixtureRepository.RefFormat.supported())
    func lockFailureSurfacesGitStderr(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        let worktreeURL: URL = try fixture.addWorktree(named: "stuck-lock-wt", branch: "main")
        try fixture.lockWorktree(worktreeURL, reason: "agent session id-99")

        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        // The worktree's private admin directory, e.g.
        // `<main>/.git/worktrees/<name>`, holds the `locked` file that
        // `worktree unlock` deletes. Stripping write permission makes that
        // unlink fail with a real, reproducible error.
        let gitDirOutcome = try git.capture(
            ["rev-parse", "--absolute-git-dir"], workingDirectory: worktreeURL.path)
        let privateGitDir = gitDirOutcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!privateGitDir.isEmpty, "git should report a private git-dir for the linked worktree")

        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: privateGitDir)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateGitDir) }

        let thrown = #expect(throws: WorktreeRemoveError.self) {
            _ = try worktreeRemove(at: repoPath, worktreeURL.path, git: git)
        }
        let failure = try #require(thrown)
        guard case let .lockFailed(_, detail) = failure else {
            Issue.record("expected .lockFailed, got \(failure)")
            return
        }

        // Git's real message (measured): "warning: unable to unlink
        // '.../locked': Permission denied". The Foundation fallback reads
        // "The operation couldn't be completed. (YardGit.GitProcess.Failure
        // error 1.)" and contains no such phrase, so this substring
        // distinguishes the two renderings.
        #expect(detail.contains("Permission denied"))
    }

    /// **Verifies the fixture actually reproduces the bug before trusting it** (#0319).
    /// Plain `git worktree remove` — no `-c` pin, no `--force` — must *destroy* an
    /// untracked file rather than refuse, once the repository has
    /// `status.showUntrackedFiles = no` set. Measured directly against git 2.50.1
    /// (see the issue's Description for the same recipe run by hand). If this ever
    /// stopped reproducing — a git version that refused regardless of the config,
    /// say — the regression test below would be pinning nothing.
    @Test("plain git worktree remove destroys an untracked file under showUntrackedFiles=no")
    func rawGitDestroysUntrackedFileUnderUnpinnedConfig() throws {
        var fixture = try FixtureRepository()
        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        let worktreeURL: URL = try fixture.addWorktree(named: "raw-probe-wt", branch: "raw-probe-branch")
        let untrackedFile = worktreeURL.appendingPathComponent("precious.txt")
        try "do not delete me".write(to: untrackedFile, atomically: true, encoding: .utf8)

        // The config a real user's `.git/config` could carry — set on the
        // repository the removal is invoked against, exactly as `worktreeRemove`
        // does with `workingDirectory: repositoryPath`.
        try git.run(["config", "status.showUntrackedFiles", "no"], workingDirectory: repoPath)

        // Plain, unpinned `git worktree remove` — no --force. This is the exact
        // call the production code used to make at WorktreeRemove.swift:134.
        let outcome = try git.capture(
            ["worktree", "remove", worktreeURL.path],
            workingDirectory: repoPath
        )

        #expect(outcome.exitCode == 0, "unpinned git worktree remove should succeed (not refuse) under this config — that is the bug the fix below must prevent")
        #expect(!exists(at: worktreeURL), "the worktree, and the untracked file inside it, should be gone — this reproduces the finding before the regression test below proves it is fixed")
    }

    /// The regression this issue tracks (#0319): `wt rm` must still refuse a
    /// worktree holding only an untracked file when the repository has
    /// `status.showUntrackedFiles = no` set — honouring the same config
    /// `git worktree remove` itself reads, which the unpinned invocation let
    /// silently destroy the file instead. Assert the file's *survival*, not only
    /// the refusal: a build that refuses and still deletes the file would pass a
    /// test that checked only `result.success == false`. The second assertion
    /// checks #0300's guarantee: the refusal's `paths` list still names the file,
    /// even though the same config would otherwise degrade that scan to `[]`.
    @Test("still refuses and preserves an untracked file under showUntrackedFiles=no", arguments: FixtureRepository.RefFormat.supported())
    func refusesAndPreservesUntrackedFileUnderShowUntrackedFilesNo(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)
        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)

        try git.run(["config", "status.showUntrackedFiles", "no"], workingDirectory: repoPath)

        let worktreeURL: URL = try fixture.addWorktree(named: "untracked-only-wt", branch: "untracked-only-branch")
        let untrackedFile = worktreeURL.appendingPathComponent("precious.txt")
        try "do not delete me".write(to: untrackedFile, atomically: true, encoding: .utf8)

        #expect(exists(at: worktreeURL), "worktree should exist before removal attempt")

        let result: WorktreeRemoveResult = try worktreeRemove(
            at: repoPath,
            worktreeURL.path,
            force: false,
            git: git
        )

        #expect(!result.success, "wt rm must still refuse an untracked-only worktree under showUntrackedFiles=no")

        // The harm this issue tracks is deletion, not merely a wrong return
        // value — so assert survival directly, both the directory and the file.
        #expect(exists(at: worktreeURL), "worktree directory must still exist after refusal")
        #expect(
            FileManager.default.fileExists(atPath: untrackedFile.path),
            "the untracked file itself must survive the refusal"
        )

        if case let .unclean(paths) = result.error {
            #expect(paths.contains("precious.txt"), "refusal's dirty-paths list should still name the untracked file under showUntrackedFiles=no (#0300)")
        } else {
            Issue.record("expected .unclean error, got \(String(describing: result.error))")
        }
    }

    /// Unknown path returns a structured error, not a crash.
    @Test("returns unknown-error for a path that is not a worktree", arguments: FixtureRepository.RefFormat.supported())
    func refusesUnknownPath(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        let git = GitProcess()
        let repoPath = try repoPath(for: fixture, git: git)
        let nonexistent = String(fixture.url.deletingLastPathComponent().path + "/definitely-not-a-worktree")

        let result: WorktreeRemoveResult = try worktreeRemove(
            at: repoPath,
            nonexistent,
            git: git
        )

        #expect(!result.success)
        if case .unknown = result.error {
            // expected
        } else if let err = result.error, case .unclean = err {
            Issue.record("refusal should be .unknown for non-worktree, got .unclean")
        } else {
            Issue.record("expected .unknown error, got \(String(describing: result.error))")
        }
    }
}
