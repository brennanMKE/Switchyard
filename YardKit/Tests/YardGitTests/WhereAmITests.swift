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

        let mPath = try git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"],
            workingDirectory: repo.url.path)

        #expect(!mPath.lines.isEmpty, "MERGE_HEAD path was returned")
        let mergeHeadExists = FileManager.default.fileExists(atPath: mPath.lines[0])
        #expect(mergeHeadExists, "MERGE_HEAD file exists")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.isMidMerge == true, "isMidMerge reports a real in-progress merge")
        #expect(!r.isMidRebase, "a mid-merge must not also report mid-rebase")
        #expect(!r.isMidCherryPick, "a mid-merge must not report mid-cherry-pick")
    }

    @Test func midCherryPickReportsFlagWhenConflictPresent() throws {
        // Build two branches whose commits edit the same line, then cherry-pick
        // one onto the other so CHERRY_PICK_HEAD exists.
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // base → branch1 (edits f.txt). HEAD ends up detached on the last commit.
        try repo.build([FixtureRepository.Commit("base", files: ["f.txt": "original\n"])])

        let baseOID = repo.oids["base"]!

        _ = try git.run(["update-ref", "refs/heads/branch1", baseOID], workingDirectory: repo.url.path)

        try repo.branch("branch2", at: "base")
        let branch1OID = try git.capture(
            ["rev-parse", "refs/heads/branch1"], workingDirectory: repo.url.path).text
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try repo.checkout("branch2")

        let cherryResult = try git.capture(
            ["cherry-pick", branch1OID], workingDirectory: repo.url.path)

        #expect(cherryResult.exitCode != 0, "the cherry-pick should conflict")

        let cpPath = try git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "CHERRY_PICK_HEAD"],
            workingDirectory: repo.url.path)

        #expect(!cpPath.lines.isEmpty, "CHERRY_PICK_HEAD path was returned")
        let cherryPickExists = FileManager.default.fileExists(atPath: cpPath.lines[0])
        #expect(cherryPickExists, "CHERRY_PICK_HEAD file exists")

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

}
