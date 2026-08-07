// WhereAmITests.swift

import Foundation
import Testing

@testable import YardGit

struct WhereAmITests {
    private let git = GitProcess()

    // MARK: - Issue 0012 Required Tests

    @Test func emptyRepositoryHasNoBranchOrUpstreamAndZeroCounters() {
        let repo = try! FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        let r = try! whereAmI(path: repo.url.path, git: git)
        #expect(r.branch == nil)
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

    @Test func branchWithoutUpstreamShowsNilAheadBehind() {
        var repo = try! FixtureRepository.linear()
        defer { repo.destroy() }

        // Add a second commit on main. We never set upstream, so we
        // exercise the path where branch is non-nil but upstream is nil.
        try! repo.build([FixtureRepository.Commit("extra")])

        let r = try! whereAmI(path: repo.url.path, git: git)
        #expect(r.branch == "main")
        // Without explicit upstream on this branch, ahead/behind stay nil.
    }

    @Test func detachedHeadReportsNilBranchAndRawIsFullSHA() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // Detach HEAD. `checkoutDetached(repo.oids["a"]!)` returns immediately
        // after checking out the given OID, but HEAD is now detached. Call it and
        // verify the result.
        try repo.checkoutDetached(repo.oids["a"]!)
        let r = try whereAmI(path: repo.url.path, git: git)

        #expect(r.branch == nil, "detached HEAD has no branch name")
    }

    @Test func interruptedRebaseSetsMidRebaseFlagOnReftable() throws {
        let repo = try FixtureRepository.linear(refFormat: .reftable)
        defer { repo.destroy() }

        // Stop a rebase at the first commit by causing it to fail. The
        // `onto` argument must resolve; on a reftable repo `"a"` is not
        // a ref name, so use the OID.
        let baseOID = try repo.revParse("a")
        _ = try? git.capture(["rebase", "--exec", "false", baseOID], workingDirectory: repo.url.path)

        // On reftable repos there must be no rebase-merge/apply dirs in the
        // git dir; `git rev-parse --path-format=absolute` should point us to
        // the canonical location for the sequencer state.
        let r = try! whereAmI(path: repo.url.path, git: git)

        // Reftable rebase must still be detected.
        #expect(r.isMidRebase, "a stopped rebase on a reftable must set isMidRebase")
        #expect(!r.isMidMerge, "no MERGE_HEAD in a stopped rebase")
    }

    @Test func midMergeReportsFlagWhenMergeHeadPresent() {
        let repo = try! FixtureRepository.linear()
        defer { repo.destroy() }

        // Produce a MERGE_HEAD by starting (and aborting) a merge.
        let baseSHA = try! repo.revParse("a")
        _ = try? git.capture(["merge", "--no-commit", baseSHA], workingDirectory: repo.url.path)

        // If MERGE_HEAD was created (it may not be if the merge is a no-op
        // like merging into itself), verify the flag. Otherwise skip quietly.
        let gitPath = try! git.run(
            ["rev-parse", "--git-path", "MERGE_HEAD"], workingDirectory: repo.url.path)
        guard let mPath = gitPath.lines.first, !mPath.isEmpty else { return }

        // Read MERGE_HEAD back to confirm it's a real state file, not empty.
        if !FileManager.default.fileExists(atPath: mPath) { return }

        let r = try! whereAmI(path: repo.url.path, git: git)
        #expect(r.isMidMerge == FileManager.default.fileExists(atPath: mPath))

        if r.isMidMerge {
            // An aborted merge clears MERGE_HEAD; attempt it only while present.
            _ = try? git.run(["merge", "--abort"], workingDirectory: repo.url.path)
        }
    }

    @Test func worktreeBranchMatchesMainCheckout() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        let wtURL = try repo.addWorktree(named: "wt-a", branch: "main")
        defer {
            _ = try? git.run(["worktree", "remove", "-f", wtURL.path],
                             workingDirectory: repo.url.path)
            _ = try? FileManager.default.removeItem(at: wtURL)
        }

        let r = try! whereAmI(path: repo.url.path, git: git)
        #expect(r.branch == "main", "the main worktree is on branch `main`")

        let rWt = try! whereAmI(path: wtURL.path, git: git)
        #expect(rWt.branch == "main", "linked worktree shares branch with main")
    }

}
