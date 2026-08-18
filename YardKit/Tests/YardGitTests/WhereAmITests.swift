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
        #expect(r.upstream == nil, "no remote configured means no upstream")
        #expect(r.ahead == nil, "no upstream means ahead cannot be computed")
        #expect(r.behind == nil, "no upstream means behind cannot be computed")
    }

    @Test func branchWithUpstreamReportsAsymmetricAheadAndBehind() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        // linear() leaves HEAD attached to main at commit "c". Add a real
        // upstream now, so origin/main starts out equal to local main.
        _ = try repo.addUpstream(branch: "main")

        // Diverge the upstream by one commit the local branch never sees:
        // build a commit off "c" that lands on no local branch, push it
        // straight into the bare repo's main ref, then fetch so the local
        // remote-tracking ref picks it up.
        try repo.checkoutDetached(repo.oids["c"]!)
        try repo.build([FixtureRepository.Commit("upstreamOnly", parents: ["c"])])
        let upstreamOnlyOID = repo.oids["upstreamOnly"]!
        try git.run(["push", "-q", "origin", "\(upstreamOnlyOID):refs/heads/main", "--force"],
                    workingDirectory: repo.url.path)
        try git.run(["fetch", "-q", "origin"], workingDirectory: repo.url.path)

        // Advance local main by two commits the upstream never sees, so the
        // branch is ahead by 2 and behind by 1 -- deliberately asymmetric,
        // so a mutation that transposes ahead and behind fails.
        try repo.build([
            FixtureRepository.Commit("ahead1", parents: ["c"]),
            FixtureRepository.Commit("ahead2", parents: ["ahead1"]),
        ])
        try repo.branch("main", at: "ahead2")
        try repo.checkout("main")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.branch == "main")
        #expect(r.upstream == "origin/main")
        #expect(r.ahead == 2)
        #expect(r.behind == 1)
        #expect(r.ahead != r.behind, "asymmetric on purpose -- a transposed ahead/behind must fail")
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

    // MARK: - Issue 0259 Required Test — asymmetric working-tree counts

    /// `stashCount`, `untrackedCount`, `unstagedCount`, and `stagedCount` were
    /// only ever asserted `== 0` against a fixture with no commits, so a
    /// mutation zeroing all four at the return site (or transposing any two
    /// of them) left the full suite green. This builds a fixture with four
    /// distinct, non-zero counts.
    ///
    /// **Revised for #0262.** `unstagedCount`'s probe changed from
    /// `git diff-index HEAD` (HEAD vs. working tree, so a file staged and
    /// then left alone was double-counted as "unstaged" too) to
    /// `git diff --name-only` (index vs. working tree, the correct meaning).
    /// Under the old probe, every staged path always also landed in
    /// `unstagedCount`, so this fixture's original 3-staged/4-unstaged pair
    /// only existed *because of* that defect (see #0262's issue text for the
    /// old measurements). Under the new probe the staged-only paths are
    /// invisible to `unstagedCount`, so the fixture now uses 3 staged-only
    /// files and 4 *disjoint* unstaged-only files to keep all four counts
    /// distinct — `unstagedCount` no longer needs to include the staged
    /// paths, and asserting it here confirms it does not.
    @Test func asymmetricWorkingTreeCountsReportDistinctValues() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        // Base commit: three files that become staged-only changes, four
        // that become unstaged-only changes, and one used solely to produce
        // the stash entry.
        try repo.build([FixtureRepository.Commit("base", files: [
            "s1.txt": "s1\n",
            "s2.txt": "s2\n",
            "s3.txt": "s3\n",
            "u1.txt": "u1\n",
            "u2.txt": "u2\n",
            "u3.txt": "u3\n",
            "u4.txt": "u4\n",
            "stashfile.txt": "stashfile\n",
        ])])

        // 1 stash: modify stashfile only, then stash it with a targeted
        // pathspec so the push does not also sweep up the staged and
        // unstaged changes built below.
        try "stashfile\nstashed-change\n".write(
            to: repo.url.appendingPathComponent("stashfile.txt"),
            atomically: true, encoding: .utf8)
        try git.run(["stash", "push", "-q", "-m", "probe", "--", "stashfile.txt"],
                    workingDirectory: repo.url.path)

        // 3 staged: modify and `git add` three distinct files, with no
        // further edit afterward -- so their working tree matches the index
        // and the new `unstagedCount` probe must not see them.
        for name in ["s1", "s2", "s3"] {
            try "\(name)\nstaged-change\n".write(
                to: repo.url.appendingPathComponent("\(name).txt"),
                atomically: true, encoding: .utf8)
            try git.run(["add", "\(name).txt"], workingDirectory: repo.url.path)
        }

        // 4 unstaged-only files, never staged, disjoint from the staged set.
        for name in ["u1", "u2", "u3", "u4"] {
            try "\(name)\nunstaged-change\n".write(
                to: repo.url.appendingPathComponent("\(name).txt"),
                atomically: true, encoding: .utf8)
        }

        // 2 untracked.
        try repo.writeUntracked([
            "new1.txt": "untracked1\n",
            "new2.txt": "untracked2\n",
        ])

        // Confirm the fixture actually reached the intended state before
        // trusting whereAmI's report of it.
        let stashList = try git.capture(["stash", "list"], workingDirectory: repo.url.path)
        #expect(stashList.text.split(separator: "\n", omittingEmptySubsequences: true).count == 1,
                "exactly one stash entry")

        let status = try git.capture(["status", "--porcelain"], workingDirectory: repo.url.path)
        let statusLines = status.text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(statusLines.count == 9, "3 staged + 4 unstaged-only + 2 untracked")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.stashCount == 1, "one stash entry")
        #expect(r.untrackedCount == 2, "two untracked files")
        #expect(r.stagedCount == 3, "three files staged only")
        #expect(r.unstagedCount == 4,
                "the four unstaged-only files -- the three staged-only paths must not be counted")
        #expect(
            Set([r.stashCount, r.untrackedCount, r.stagedCount, r.unstagedCount]).count == 4,
            "all four counts are pairwise distinct -- a mutation transposing any two must fail"
        )
    }

    // MARK: - Issue 0262 Required Test — staged file, clean working tree

    /// The state the old `diff-index HEAD` probe could never report: a file
    /// staged via `git add` with the working tree otherwise matching the
    /// index. Measured, git 2.50.1: `git diff --name-only` (the new probe)
    /// is empty here while `git diff-index --name-status HEAD` (the old one)
    /// still reports the file as `M`. This is the whole criterion for #0262.
    @Test func stagedFileWithCleanWorkingTreeReportsZeroUnstaged() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        try repo.build([FixtureRepository.Commit("base", files: [
            "f.txt": "f\n",
        ])])

        try "f\nstaged-change\n".write(
            to: repo.url.appendingPathComponent("f.txt"),
            atomically: true, encoding: .utf8)
        try git.run(["add", "f.txt"], workingDirectory: repo.url.path)

        // Confirm the fixture state directly before trusting whereAmI's
        // report of it: the true unstaged probe is empty, and status shows
        // the change staged only ("M ", not " M" or "MM").
        let trueUnstaged = try git.capture(["diff", "--name-only"], workingDirectory: repo.url.path)
        #expect(trueUnstaged.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "git diff --name-only reports nothing -- the working tree matches the index")

        let status = try git.capture(["status", "--porcelain"], workingDirectory: repo.url.path)
        #expect(status.text.trimmingCharacters(in: .whitespacesAndNewlines) == "M  f.txt",
                "staged only, not also modified in the working tree")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.unstagedCount == 0, "the staged file must not be counted as unstaged")
        #expect(r.stagedCount == 1, "the file is staged")
    }

    /// `unstagedCount`'s probe, plain `git diff --name-only -z`, lists a
    /// conflicted path *twice* -- once against each side of the conflict.
    /// Measured directly below: the raw probe returns `f.txt` twice while
    /// `conflictCount`'s `--diff-filter=U` returns it once. `unstagedCount`
    /// deduplicates through a `Set` before counting so the doubled entry does
    /// not inflate it; this test pins that so the dedup cannot silently
    /// regress. `plain.txt` is an ordinary unstaged file, unrelated to the
    /// conflict, so the assertion distinguishes "deduplicated to one" from
    /// "only happened to see one path" -- if the dedup were dropped,
    /// `unstagedCount` would read 3 (f.txt twice + plain.txt), not 2.
    @Test func conflictedPathIsNotDoubleCountedInUnstaged() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }

        try repo.build([FixtureRepository.Commit("base", files: [
            "f.txt": "original\n",
            "plain.txt": "plain\n",
        ])])
        try repo.build([FixtureRepository.Commit("ours", parents: ["base"], files: [
            "f.txt": "ours\n",
        ])])
        try repo.build([FixtureRepository.Commit("theirs", parents: ["base"], files: [
            "f.txt": "theirs\n",
        ])])
        try repo.checkoutDetached(repo.oids["ours"]!)
        _ = try? git.run(["merge", "--no-commit", repo.oids["theirs"]!],
                         workingDirectory: repo.url.path)

        // +1 ordinary unstaged path, never part of the conflict.
        try "plain\nunstaged-change\n".write(
            to: repo.url.appendingPathComponent("plain.txt"),
            atomically: true, encoding: .utf8)

        // Confirm the fixture actually reached the state this test depends
        // on: the raw probe really does list the conflicted path twice, and
        // the conflict machinery reports exactly one conflicted path.
        let rawProbe = try git.capture(["diff", "--name-only", "-z"], workingDirectory: repo.url.path)
        let rawFields = rawProbe.text.split(separator: "\0", omittingEmptySubsequences: true)
        #expect(rawFields.filter { $0 == "f.txt" }.count == 2,
                "git diff --name-only -z lists the conflicted path twice -- the defect this test guards")
        #expect(rawFields.contains("plain.txt"),
                "the ordinary unstaged file is also present in the raw probe")

        let r = try whereAmI(path: repo.url.path, git: git)
        #expect(r.conflictCount == 1, "one conflicted path")
        #expect(r.unstagedCount == 2,
                "the conflicted path counted once, plus the one ordinary unstaged path -- would read 3 if the doubled conflict entry were not deduplicated")
    }

}
