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

    /// An unclean worktree (with a modified tracked file) is refused without
    /// --force. The error names the dirty path, and the directory still exists
    /// afterwards.
    @Test("refuses to remove a dirty worktree without force", arguments: FixtureRepository.RefFormat.supported())
    func refusesDirtyWorktreeWithoutForce(format: FixtureRepository.RefFormat) throws {
        var fixture = try FixtureRepository(refFormat: format)

        let worktreeURL: URL = try fixture.addWorktree(named: "dirty-wt", branch: "main")

        // Write an untracked file in the worktree to make it dirty.
        let dirtFile = worktreeURL.appendingPathComponent("dirty.txt")
        try "this is dirty content".write(to: dirtFile, atomically: true, encoding: .utf8)

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
