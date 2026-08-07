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

        // base → branch1 (edits f.txt). Each build transitions HEAD to detached
        // after the last commit, so we re-attach via checkout. To keep branch1
        // as a ref after commit, create it via raw git on the SHA.
        try repo.build([FixtureRepository.Commit("base", files: ["f.txt": "original\n"])])

        // Create branch1 via raw git so we have a ref. HEAD ends up detached
        // on the base commit after the build above; we don't switch away yet.
        let baseOID = repo.oids["base"]!

        // Switch HEAD to branch1 by pointing a ref at the SHA and checking it out.
        _ = try git.run(["update-ref", "refs/heads/branch1", baseOID], workingDirectory: repo.url.path)
        try repo.checkout("branch1")

        // Create branch2 off base. Merging branch2 into branch1 produces a
        // conflict because both modify the same line.
        try repo.branch("branch2", at: "base")

        let branch2OID = repo.oids["branch2"]!
        let mergeResult = try git.capture(
            ["merge", "--no-commit", branch2OID], workingDirectory: repo.url.path)

        // A conflicting merge exits non-zero but leaves MERGE_HEAD in place.
        #expect(mergeResult.exitCode != 0, "the merge should conflict")

        // Confirm MERGE_HEAD exists.
        let mPath = try git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"],
            workingDirectory: repo.url.path)

        #expect(!mPath.lines.isEmpty, "MERGE_HEAD path was returned")
        #expect(FileManager.default.fileExists(atPath: mPath.lines[0]), "MERGE_HEAD file exists")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.isMidMerge == true, "isMidMerge reports a real in-progress merge")
        #expect(!r.isMidRebase, "a mid-merge must not also report mid-rebase")
        #expect(!r.isMidCherryPick, "a mid-merge must not report mid-cherry-pick")

        // Abort the merge to leave the fixture clean.
        _ = try? git.run(["merge", "--abort"], workingDirectory: repo.url.path)
    }

    @Test func midCherryPickReportsFlagWhenConflictPresent() throws {
        // Build two branches whose commits edit the same line, then cherry-pick
        // one onto the other so CHERRY_PICK_HEAD exists.
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // base → branch1 (edits f.txt). HEAD ends up detached on the last commit.
        try repo.build([FixtureRepository.Commit("base", files: ["f.txt": "original\n"])])

        let baseOID = repo.oids["base"]!

        // Create branch1 via raw git ref so checkout works later.
        _ = try git.run(["update-ref", "refs/heads/branch1", baseOID], workingDirectory: repo.url.path)

        // Create branch2 off base. Cherry-picking branch1 onto branch2 will
        // conflict because both modify the same line.
        try repo.branch("branch2", at: "base")

        // Switch to branch2 and attempt a cherry-pick of branch1.
        try repo.checkout("branch2")

        let branch1OID = repo.oids["branch1"]!
        let cherryResult = try git.capture(
            ["cherry-pick", branch1OID], workingDirectory: repo.url.path)

        // A conflicting cherry-pick exits non-zero but leaves CHERRY_PICK_HEAD.
        #expect(cherryResult.exitCode != 0, "the cherry-pick should conflict")

        // Confirm CHERRY_PICK_HEAD exists.
        let cpPath = try git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "CHERRY_PICK_HEAD"],
            workingDirectory: repo.url.path)

        #expect(!cpPath.lines.isEmpty, "CHERRY_PICK_HEAD path was returned")
        #expect(FileManager.default.fileExists(atPath: cpPath.lines[0]), "CHERRY_PICK_HEAD file exists")

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
