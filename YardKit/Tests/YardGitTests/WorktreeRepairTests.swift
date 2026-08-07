// WorktreeRepairTests.swift — assertions about git worktree repair behaviour

import Foundation
@testable import YardGit
import Testing

struct WorktreeRepairTests {

    private let git = GitProcess()
    private let fm = FileManager.default

    // MARK: - parseReport (pure function on stderr)

    @Test func emptyStderrProducesEmptyReports() {
        let result = WorktreeRepair.parseReport(from: "")
        #expect(result.isEmpty, "empty stderr should mean nothing to repair")
    }

    @Test func emptyWhitespaceStderrProducesEmptyReports() {
        let result = WorktreeRepair.parseReport(from: "\n\n  \t\n")
        #expect(result.isEmpty)
    }

    @Test func reportContainsLinesMatchingThePrefix() {
        let stderr = """
            repair: gitdir incorrect: /var/folders/a/b/c/main.git/worktrees/w1/gitdir
            some unrelated noise that does not start with repair:
            repair: gitdir incorrect: /var/folders/a/b/c/main.git/worktrees/w2/gitdir
            """
        let result = WorktreeRepair.parseReport(from: stderr)
        #expect(result.count == 2, "expected exactly the two prefixed lines")
    }

    @Test func reportContainsLinesMatchingThePrefixHasAtLeastOneEntry() {
        let stderr = """
            repair: gitdir incorrect: /var/folders/a/b/c/main.git/worktrees/w1/gitdir
            repair: gitdir incorrect: /var/folders/a/b/c/main.git/worktrees/w2/gitdir
            """
        let result = WorktreeRepair.parseReport(from: stderr)
        #expect(!result.isEmpty, "two prefixed lines means the report is non-empty")
    }

    @Test func reportLinesSplitIntoReasonAndPath() throws {
        // git writes `repair: <reason>: <path>`. Keeping them glued together
        // means no caller can get the path without re-parsing.
        let stderr = "repair: gitdir incorrect: /a/b/c/main.git/worktrees/agent/gitdir\n"
        let result = WorktreeRepair.parseReport(from: stderr)
        #expect(result.count == 1, "one prefix-matched line")

        let extracted = try #require(result.first)
        #expect(extracted.reason == "gitdir incorrect")
        #expect(extracted.path == "/a/b/c/main.git/worktrees/agent/gitdir")
    }

    @Test func reportLinesCarryTheMainRepoMovedReasonToo() throws {
        // The other message git emits, and the one a hardcoded
        // `repair: gitdir incorrect:` prefix silently dropped.
        let stderr = "repair: .git file broken: /a/b/c/linked-worktree\n"
        let result = WorktreeRepair.parseReport(from: stderr)

        let extracted = try #require(result.first)
        #expect(extracted.reason == ".git file broken")
        #expect(extracted.path == "/a/b/c/linked-worktree",
                "for this reason the path is the worktree itself, not an admin file")
    }

    @Test func reportLinesKeepAColonInsideAPath() throws {
        // Only the FIRST ": " separates reason from path -- a reason never
        // contains one, a path may.
        let stderr = "repair: gitdir incorrect: /tmp/odd: name/w/gitdir\n"
        let extracted = try #require(WorktreeRepair.parseReport(from: stderr).first)
        #expect(extracted.reason == "gitdir incorrect")
        #expect(extracted.path == "/tmp/odd: name/w/gitdir")
    }

    @Test func reportReportsSinglePrefixedLineWhenOthersAreUnrelated() {
        let stderr = """
            error: something unrecoverable happened to another command

            repair: gitdir incorrect: /a/b/c/main.git/worktrees/foo/gitdir
            warning: an unrelated stdout-style message ended up on stderr by accident
            """
        let result = WorktreeRepair.parseReport(from: stderr)
        #expect(result.count == 1, "only the prefix-matched line should be reported")
        #expect(result.first?.reason == "gitdir incorrect")
        #expect(result.first?.path == "/a/b/c/main.git/worktrees/foo/gitdir")
    }

    // MARK: - Run from the main worktree with each moved path passed as an argument.

    @Test func moveLinkedWorktreeAndRepairByPathExitsZero() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-01", branch: "agent-01")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        let reports = try WorktreeRepair.run(
            repositoryPath: repo.url.path, atPaths: [moved.path]
        )

        #expect(reports.count == 1)
    }

    @Test func moveLinkedWorktreeAndRepairByPathHasNoPrunableEntriesAfterward() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-01", branch: "agent-01")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        let entriesBefore = try worktreeList(path: repo.url.path)
        #expect(!entriesBefore.isEmpty, "the fixture must report at least one worktree entry from the main repo")

        let oldPathEntry = try #require(
            entriesBefore.first(where: { $0.path == added.path })
        )
        #expect(oldPathEntry.prunable, "a moved worktree must appear as prunable from the main repo")

        let _ = try WorktreeRepair.run(
            repositoryPath: repo.url.path, atPaths: [moved.path]
        )

        let entriesAfter = try worktreeList(path: repo.url.path)

        #expect(
            entriesAfter.filter({ $0.prunable }).isEmpty,
            "no prunable entries should remain after repair"
        )

        let entryClaimingNew = try #require(
            entriesAfter.first(where: { $0.path == moved.path }),
            "porcelain should name the new path after repair"
        )

        #expect(entryClaimingNew.prunable == false, "after repair the moved worktree must not be prunable")
    }

    @Test func moveLinkedWorktreeAndRepairByPathReportsTheMovedPath() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-01", branch: "agent-01")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        let reports = try WorktreeRepair.run(
            repositoryPath: repo.url.path, atPaths: [moved.path]
        )

        #expect(!reports.isEmpty, "expected git to report the repaired path on stderr")
    }

    @Test func runFromInsideTheMovedWorktreeExitsZeroRegardlessOfReport() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-inner", branch: "agent-inner")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        let reports = try WorktreeRepair.run(
            repositoryPath: moved.path, atPaths: []
        )

        #expect(!reports.isEmpty, "git worktree repair from inside a moved linked worktree reports at least one repaired path")
    }



    @Test func runFromInsideMovedLinksNewPathAfterward() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-inner", branch: "agent-inner")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        let _ = try WorktreeRepair.run(
            repositoryPath: moved.path, atPaths: []
        )

        // No link should now point at the old path — porcelain is fully consistent
        // with the repository's `.git/worktrees` administrative state.
        let entriesAfter = try worktreeList(path: moved.path)

        #expect(
            !entriesAfter.contains(where: { $0.path == added.path }),
            "no porcelain entry should still point at the old path after repair"
        )

        let newEntry = try #require(
            entriesAfter.first(where: { $0.path == moved.path }),
            "the new path should appear after repair"
        )

        #expect(newEntry.prunable == false)
    }

    @Test func runFromMainWorktreePassingEachMovedPathExitsZero() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let addedA = try repo.addWorktree(named: "first-agent", branch: "branch-a-01")
        let addedB = try repo.addWorktree(named: "second-agent", branch: "branch-b-01")

        let movedA = addedA.deletingLastPathComponent()
            .appendingPathComponent("\(addedA.lastPathComponent)-moved")

        let movedB = addedB.deletingLastPathComponent()
            .appendingPathComponent("\(addedB.lastPathComponent)-moved")

        try fm.moveItem(atPath: addedA.path, toPath: movedA.path)
        try fm.moveItem(atPath: addedB.path, toPath: movedB.path)

        let reports = try WorktreeRepair.run(
            repositoryPath: repo.url.path, atPaths: [movedA.path, movedB.path]
        )

        #expect(reports.count == 2, "the run should have reported both repairs")
    }

    @Test func passEachMovedPathRepairReportsAllOfThem() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let addedA = try repo.addWorktree(named: "pair-a", branch: "branch-pair-a")
        let addedB = try repo.addWorktree(named: "pair-b", branch: "branch-pair-b")

        let movedA = addedA.deletingLastPathComponent()
            .appendingPathComponent("\(addedA.lastPathComponent)-moved")

        let movedB = addedB.deletingLastPathComponent()
            .appendingPathComponent("\(addedB.lastPathComponent)-moved")

        try fm.moveItem(atPath: addedA.path, toPath: movedA.path)
        try fm.moveItem(atPath: addedB.path, toPath: movedB.path)

        let reports = try WorktreeRepair.run(
            repositoryPath: repo.url.path, atPaths: [movedA.path, movedB.path]
        )

        #expect(reports.count == 2, "both moves should be reported as repaired")
    }

    // MARK: - Verify the broken precondition is measured correctly.

    @Test func statusExitsZeroFromInsideMovedWorktreeEvenWhenBroken() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-status", branch: "branch-wt-02")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        let entriesBefore = try worktreeList(path: repo.url.path)
        #expect(!entriesBefore.isEmpty, "fixture should still list a worktree")

        let matchedOld = try #require(
            entriesBefore.first(where: { $0.path == added.path })
        )

        #expect(matchedOld.prunable, "precondition: the main repo still sees the moved entry as prunable")

        // `status` from inside the moved worktree exits 0 regardless of admin state.
        let status = try git.capture(
            ["status", "--porcelain"], workingDirectory: moved.path)

        #expect(status.exitCode == 0, "git status inside a moved linked worktree exits 0 regardless of admin state")
    }

    // MARK: - Position 3 — main repo itself moved.

    @Test func mainRepoMovedLinkedWorktreeIsPrunableThenRepaired() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "left-01", branch: "branch-lt-01")
        defer { try? fm.removeItem(at: added) }

        let beforeRoot = repo.url
        let movedParent = beforeRoot.deletingLastPathComponent()
            .appendingPathComponent("\(beforeRoot.lastPathComponent)-moved")

        try fm.moveItem(atPath: beforeRoot.path, toPath: movedParent.path)
        defer { try? fm.removeItem(at: movedParent) }

        #expect(fm.fileExists(atPath: movedParent.path))
        let afterRoot = movedParent

        // From inside the (still-accessible) main repo at its new location, linked
        // worktree should still appear in porcelain (because .git/worktrees/<name>
        // exists on disk), but its `.git` file contains a gitdir pointer that no longer
        // exists on disk. Looking from the main repo we can't see "prunable" here
        // because the worktrees entry is technically valid from this side — only
        // inside it does git fail to resolve the commondir link.
        let entriesBefore = try worktreeList(path: afterRoot.path)

        #expect(!entriesBefore.isEmpty, "porcelain should still list the linked worktree")

        let claimBefore = try #require(
            entriesBefore.first(where: { $0.path == added.path }),
            "porcelain from the main repo should still show the linked worktree at its disk location"
        )

        #expect(claimBefore.prunable == false, "from the main repo the linked worktree is not prunable — only inside it would git fail to resolve commondir")

        // Repair must run from the moved main repo with linked worktree paths, since
        // `git` commands inside the broken-linked-worktree itself can't resolve commondir.
        let reports = try WorktreeRepair.run(
            repositoryPath: afterRoot.path, atPaths: [added.path]
        )

        #expect(!reports.isEmpty, "git worktree repair must report at least one repaired path")

        // Porcelain from inside the (still-accessible) main repo after repair shows
        // the linked worktree unchanged from its disk location.
        let entriesAfter = try worktreeList(path: afterRoot.path)

        #expect(!entriesAfter.isEmpty, "the linked worktree must still be listed after repair")

        let claimAfter = try #require(
            entriesAfter.first(where: { $0.path == added.path }),
            "porcelain from the main repo should still show the linked worktree after repair"
        )

        #expect(claimAfter.prunable == false, "the worktree is still not prunable from the main repo")
    }



}

// MARK: - Helpers shared by this suite.

private func worktreeList(path: String) throws -> [WorktreeEntry] {
    return try worktreeList(path: path, git: GitProcess())
}
