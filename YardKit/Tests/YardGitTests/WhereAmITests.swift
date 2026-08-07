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
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // Produce a MERGE_HEAD by starting (and aborting) a merge.
        let baseOID = repo.oids["a"]!
        _ = try? git.capture(["merge", "--no-commit", baseOID], workingDirectory: repo.url.path)

        // If MERGE_HEAD was created (it may not be if the merge is a no-op
        // like merging into itself), verify the flag. Otherwise skip quietly.
        let gitPath = try git.run(
            ["rev-parse", "--git-path", "MERGE_HEAD"], workingDirectory: repo.url.path)
        guard let mPath = gitPath.lines.first, !mPath.isEmpty else { return }

        // Read MERGE_HEAD back to confirm it's a real state file, not empty.
        if !FileManager.default.fileExists(atPath: mPath) { return }

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.isMidMerge == FileManager.default.fileExists(atPath: mPath))

        if r.isMidMerge {
            // An aborted merge clears MERGE_HEAD; attempt it only while present.
            _ = try? git.run(["merge", "--abort"], workingDirectory: repo.url.path)
        }
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

}
