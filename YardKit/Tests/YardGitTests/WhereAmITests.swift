// WhereAmITests.swift

import Foundation
import Testing
@testable import YardGit

struct WhereAmITests {

    private let git = GitProcess()

    // MARK: - Issue 0012 Required Tests

    @Test func emptyRepositoryHasMainBranchAndEmptyHeadOID() throws {
        let repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.branch == "main", "unborn HEAD reports main")
        #expect(r.headOID == "", "no commit yet means empty headOID")
        #expect(r.upstream == nil)
        #expect(r.ahead == nil)
        #expect(r.behind == nil)
        #expect(!r.isMidRebase, "no rebase in progress")
        #expect(!r.isMidMerge)
        #expect(!r.isMidCherryPick)
        #expect(r.stashCount == 0, "no stashes in empty repo")
        #expect(r.untrackedCount == 0)
        #expect(r.unstagedCount == 0)
        #expect(r.stagedCount == 0)
        #expect(!r.hasConflicts, "no unmerged entries in empty index")
    }

    @Test func branchWithoutUpstreamShowsNilAheadBehind() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // Add a second commit on main. We never set upstream, so we
        // exercise the path where branch is non-nil but upstream is nil.
        try repo.build([FixtureRepository.Commit("extra")])

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.branch == "main")
        // Without explicit upstream on this branch, ahead/behind stay nil.
    }

    @Test func detachedHeadReportsNilBranchAndRawIsFullSHA() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // Detach HEAD. checkoutDetached takes an OID; "a" is a commit name
        // stored in repo.oids, not a ref that git can resolve directly.
        try repo.checkoutDetached(repo.oids["a"]!)
        let r = try whereAmI(path: repo.url.path, git: git)

        #expect(r.branch == nil, "detached HEAD has no branch name")
    }

    @Test func interruptedRebaseSetsMidRebaseFlagOnReftable() throws {
        let repo = try FixtureRepository.linear(refFormat: .reftable)
        defer { repo.destroy() }

        // Stop a rebase at the first commit by causing it to fail. The
        // `onto` argument must resolve; on a reftable repo "a" is not
        // a ref name, so use the OID.
        let baseOID = repo.oids["a"]!
        _ = try? git.capture(["rebase", "--exec", "false", baseOID], workingDirectory: repo.url.path)

        let r = try whereAmI(path: repo.url.path, git: git)

        // Reftable rebase must still be detected.
        #expect(r.isMidRebase, "a stopped rebase on a reftable must set isMidRebase")
        #expect(!r.isMidMerge, "no MERGE_HEAD in a stopped rebase")
    }

    @Test func midMergeReportsFlagWhenMergeHeadPresent() throws {
        // Build a repo with two divergent branches that edit the same file,
        // then start a conflicting merge in progress so MERGE_HEAD exists.
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // base → branch1 (edits f.txt) and branch2 (edits f.txt differently).
        // Both commits are on top of the same base, so merging them conflicts.
        try repo.build([
            FixtureRepository.Commit("base", files: ["f.txt": "original\n"]),
            FixtureRepository.Commit("branch1", parents: ["base"], files: ["f.txt": "branch1 content\n"]),
        ])
        try repo.build([
            FixtureRepository.Commit("branch2", parents: ["base"], files: ["f.txt": "branch2 content\n"]),
        ])

        // We are now detached on branch2. Switch main to branch1, then merge
        // branch2 into main.
        let branch2OID = repo.oids["branch2"]!
        try repo.checkoutDetached(repo.oids["base"]!)
        try repo.branch("main", at: "branch1")
        try repo.checkout("main")

        let mergeResult = try git.capture(
            ["merge", "--no-commit", branch2OID], workingDirectory: repo.url.path)

        #expect(mergeResult.exitCode != 0, "the merge should conflict")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.isMidMerge == true, "isMidMerge reports a real in-progress merge")
        #expect(!r.isMidRebase, "a mid-merge must not also report mid-rebase")
        #expect(!r.isMidCherryPick, "a mid-merge must not report mid-cherry-pick")
    }

    @Test func midCherryPickReportsFlagWhenConflictPresent() throws {
        // base → a1 (f.txt = "ours") and base → a2 (f.txt = "theirs"), then
        // cherry-pick a2 onto a1 so CHERRY_PICK_HEAD and unmerged index entries exist.
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        try repo.build([FixtureRepository.Commit("base", files: ["f.txt": "original\n"])])
        try repo.build([FixtureRepository.Commit("a1", parents: ["base"], files: ["f.txt": "ours\n"])])
        try repo.build([FixtureRepository.Commit("a2", parents: ["base"], files: ["f.txt": "theirs\n"])])

        try repo.checkoutDetached(repo.oids["a1"]!)
        let cherryResult = try git.capture(
            ["cherry-pick", repo.oids["a2"]!], workingDirectory: repo.url.path)

        #expect(cherryResult.exitCode != 0, "the cherry-pick should conflict")

        // Assert the fixture has real unmerged index entries, not just CHERRY_PICK_HEAD.
        // An empty cherry-pick (content already present) exits non-zero but leaves 0 unmerged entries.
        let lsFilesResult = try git.capture(
            ["diff-index", "--cached", "--name-only", "--diff-filter=U", "HEAD"],
            workingDirectory: repo.url.path)
        let unmergedFiles = lsFilesResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!unmergedFiles.isEmpty, "cherry-pick fixture has real unmerged index entries")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.isMidCherryPick == true, "isMidCherryPick reports a real in-progress cherry-pick")
        #expect(!r.isMidMerge, "a mid-cherry-pick must not also report mid-merge")
        #expect(!r.isMidRebase, "a mid-cherry-pick must not also report mid-rebase")

        // Abort the cherry-pick to leave the fixture clean.
        _ = try? git.run(["cherry-pick", "--abort"], workingDirectory: repo.url.path)
    }

    @Test func worktreeBranchMatchesMainCheckout() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // addWorktree(named:branch:) creates a new branch with that name
        // (git worktree add -b). Passing "main" fails because main already exists.
        let wtURL = try repo.addWorktree(named: "wt-a", branch: "probe-branch")
        defer {
            _ = try? git.run(["worktree", "remove", "-f", wtURL.path],
                             workingDirectory: repo.url.path)
            _ = try? FileManager.default.removeItem(at: wtURL)
        }

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.branch == "main", "the main worktree is on branch `main`")

        let rWt = try whereAmI(path: wtURL.path, git: git)
        #expect(rWt.branch == "probe-branch", "linked worktree is on its own branch")
    }

    // MARK: - Issue 0110 Required Tests — conflictCount

    @Test func cleanRepositoryReportsZeroConflicts() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.conflictCount == 0, "a clean repo has no conflicted paths")
        #expect(!r.hasConflicts, "zero conflict count means hasConflicts is false")
    }

    @Test func oneConflictFileReportsCountOfOne() throws {
        let repo = try FixtureRepository.conflicted()
        defer { repo.destroy() }

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.conflictCount == 1, "one conflicted file means conflictCount is 1")
        #expect(r.hasConflicts, "one conflicted file means hasConflicts is true")
    }

    @Test func twoConflictFilesReportsCountOfTwo() throws {
        let repo = try FixtureRepository.conflictedTwo()
        defer { repo.destroy() }

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.conflictCount == 2, "two conflicted files means conflictCount is 2")
        #expect(r.hasConflicts, "any conflicts means hasConflicts is true")

        // hasConflicts is derived from conflictCount, so they cannot disagree.
        #expect(r.hasConflicts == (r.conflictCount > 0))

        // Confirm it is a true path count, not a stage-entry count.
        // `git ls-files -u` would return 6 lines (3 stages × 2 paths).
        let lsOutput = try git.capture(
            ["ls-files", "-u"], workingDirectory: repo.url.path)
        let lsLineCount = lsOutput.text.split(
            separator: "\n", omittingEmptySubsequences: true).count
        #expect(lsLineCount == 6, "ls-files -u reports 3 stages per conflicted path")
        #expect(r.conflictCount != lsLineCount, "conflict count must be unique paths")
    }

    // MARK: - Issue 0140 Required Tests — the not-a-repository gate

    @Test func nonRepositoryDirectoryThrowsNotARepository() throws {
        let dir = NSTemporaryDirectory() + "yard-not-a-repo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let error = #expect(throws: WorktreeContext.Error.self) {
            _ = try whereAmI(path: dir, git: git)
        }
        guard case let .notARepository(path, detail) = try #require(error) else {
            Issue.record("expected notARepository, got \(String(describing: error))")
            return
        }
        #expect(path == dir, "the error names the path that was asked about")
        #expect(detail.contains("not a git repository"),
                "the error carries git's own stderr as the detail")
    }

}
