// WorktreeRepairTests.swift — assertions about git worktree repair behaviour

import Foundation
import Testing
@testable import YardGit

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
        #expect(!result.isEmpty)
    }

    @Test func reportLinesArePathsAfterThePrefix() {
        let stderr = "repair: gitdir incorrect: /a/b/c/main.git/worktrees/agent/gitdir\n"
        let result = WorktreeRepair.parseReport(from: stderr)
        #expect(result.count == 1, "one prefix-matched line")

        guard let extracted = result.first else {
            Issue.record("expected first element of the parsed report")
            return
        }
        #expect(extracted == "/a/b/c/main.git/worktrees/agent/gitdir")
    }

    @Test func reportDoesNotMixInUnrelatedStderrLines() {
        let stderr = """
            error: something unrecoverable happened to another command

            repair: gitdir incorrect: /a/b/c/main.git/worktrees/foo/gitdir
            warning: an unrelated stdout-style message ended up on stderr by accident
            """
        let result = WorktreeRepair.parseReport(from: stderr)
        #expect(result.count == 1, "only the prefix-matched line should be reported")
        #expect(result.first == "/a/b/c/main.git/worktrees/foo/gitdir")
    }

    // MARK: - Run from the main worktree with each moved path passed as an argument.

    @Test func moveLinkedWorktreeAndRepairByPathPassesPorcelain() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-01", branch: "agent-01")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        // Precondition: the old path is still reported and marked prunable.
        let entriesBefore = try worktreeList(path: repo.url.path)
        #expect(!entriesBefore.isEmpty, "the fixture must report at least one worktree entry from the main repo")
        for e in entriesBefore {
            if #unavailable(macOS 13.0) { continue }
        }
        let oldPathEntry = try #require(
            entriesBefore.first(where: { $0.path == added.path })
        )
        #expect(oldPathEntry.prunable, "a moved worktree must appear as prunable from the main repo")
        #expect(oldPathEntry.path == added.path)

        // Run repair.
        let reports = try WorktreeRepair.run(
            repositoryPath: repo.url.path, atPaths: [moved.path]
        )

        // Postcondition.
        let entriesAfter = try worktreeList(path: repo.url.path)

        #expect(
            entriesAfter.filter({ $0.prunable }).isEmpty,
            "no prunable entries should remain after repair"
        )

        let entryClaimingNew = entriesAfter.first(where: { $0.path == moved.path })
        #expect(entryClaimingNew != nil, "porcelain should name the new path after repair")

        if let newEntry = entryClaimingNew {
            #expect(newEntry.prunable == false, "after repair the moved worktree must not be prunable")
        }

        #expect(!reports.isEmpty, "expected git to report the repaired path on stderr")
    }

    @Test func repairFromInsideTheMovedWorktreeDoesNotChangeLinks() throws {
        var repo = try FixtureRepository(refFormat: .files)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a")])

        let added = try repo.addWorktree(named: "agent-inner", branch: "agent-inner")
        defer { try? fm.removeItem(at: added) }

        let moved = added.deletingLastPathComponent()
            .appendingPathComponent("\(added.lastPathComponent)-moved")

        try fm.moveItem(atPath: added.path, toPath: moved.path)

        // Repair from inside the moved worktree reports no repairs — git works
        // against `./git` directly, so it never sees a mislink. The command exits
        // 0 and produces no repair line in stderr.
        let reports = try WorktreeRepair.run(
            repositoryPath: moved.path, atPaths: []
        )

        #expect(reports.isEmpty, "repair from inside the moved worktree should not report repairs")

        // No link should now point at the old path — porcelain is fully consistent
        // with the repository's `.git/worktrees` administrative state.
        let entriesAfter = try worktreeList(path: moved.path)
        #expect(
            !entriesAfter.contains(where: { $0.path == added.path }),
            "no porcelain entry should still point at the old path after repair"
        )

        let entryClaimingNew = entriesAfter.first(where: { $0.path == moved.path })
        #expect(entryClaimingNew != nil, "the new path should appear after repair")

        if let newEntry = entryClaimingNew {
            #expect(newEntry.prunable == false)
        }
    }

    @Test func runFromMainWorktreePassingEachMovedPathReturnsTheReportedPaths() throws {
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

    // MARK: - Multiple moved worktrees — one repair call touching both paths.

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

    // MARK: - The report prefix constant.

    @Test func hasNoRepairsReturnsTrueForEmptyAndFalseWhenAnyReportsAreMade() {
        #expect(WorktreeRepair.hasNoRepairs([]))
        #expect(!WorktreeRepair.hasNoRepairs(["/a/b/c"]))

        let multiple = ["/one", "/two"]
        #expect(!WorktreeRepair.hasNoRepairs(multiple))

        let emptyLine = [""]
        #expect(!WorktreeRepair.hasNoRepairs(emptyLine))
    }

    @Test func firstReportedPathReturnsTheFirstEntryOrNilWhenEmpty() {
        #expect(WorktreeRepair.firstReportedPath([]) == nil)
        #expect(WorktreeRepair.firstReportedPath(["/a/b/c"]) == "/a/b/c")
        #expect(WorktreeRepair.firstReportedPath(["/one", "/two"]) == "/one")
    }

}

// MARK: - Helpers shared by this suite.

extension WorktreeRepairTests {
    private func listWorktrees(path: String) throws -> [WorktreeEntry] {
        return try worktreeList(path: path, git: GitProcess())
    }
}
