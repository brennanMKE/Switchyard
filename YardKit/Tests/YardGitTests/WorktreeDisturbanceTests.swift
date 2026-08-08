// WorktreeDisturbanceTests.swift — restore refuses to wreck a sibling (#0044)
//
// Deliberately NOT @testable: the restore flow (#0168) calls this as a public
// caller, so a member silently dropping to internal must fail here at
// compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct WorktreeDisturbanceTests {

    private let git = GitProcess()

    private func capture(at path: String) throws -> RefSnapshot {
        try RefSnapshot.capture(in: WorktreeContext.resolve(path: path))
    }

    private func disturbances(
        restoring recorded: RefSnapshot, at path: String
    ) throws -> [WorktreeDisturbance.Disturbance] {
        try WorktreeDisturbance.disturbances(
            restoring: recorded, in: WorktreeContext.resolve(path: path))
    }

    private func line(
        of arguments: [String], at path: String
    ) throws -> String {
        try #require(try git.run(arguments, workingDirectory: path).lines.first)
    }

    // MARK: - HEAD is per-worktree; restoring it never moves a sibling

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func restoreLeavesTheSiblingsHeadAndBranchAlone(
        _ format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        let name = try #require(
            try WorktreeContext.resolve(path: wt.path).worktreeName)
        let c = try #require(repo.oids["c"])
        let a = try #require(repo.oids["a"])

        let recorded = try capture(at: repo.url.path)
        // Nothing the snapshot would apply disturbs the sibling.
        #expect(try disturbances(restoring: recorded, at: repo.url.path).isEmpty)

        // Wreck the main worktree only: detach HEAD and rewind main.
        try repo.checkoutDetached(a)
        try git.run(["update-ref", "refs/heads/main", a],
                    workingDirectory: repo.url.path)

        try recorded.restore(in: WorktreeContext.resolve(path: repo.url.path))

        // The caller's worktree is back exactly; the capture proves it.
        #expect(try capture(at: repo.url.path) == recorded)
        // The sibling's per-worktree HEAD never moved: still on its branch,
        // still at the same commit — read via the worktrees/<name>/ prefix,
        // the supported cross-worktree address for per-worktree refs.
        #expect(try line(of: ["rev-parse", "--symbolic-full-name",
                              "worktrees/\(name)/HEAD"],
                         at: repo.url.path) == "refs/heads/agent-branch")
        #expect(try line(of: ["rev-parse", "worktrees/\(name)/HEAD"],
                         at: repo.url.path) == c)
    }

    // MARK: - A sibling's checked-out branch is a named disturbance

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func rewindingTheSiblingsBranchIsReportedByName(
        _ format: FixtureRepository.RefFormat
    ) throws {
        var repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        let c = try #require(repo.oids["c"])

        let recorded = try capture(at: repo.url.path)

        // The sibling commits; its shared branch moves past the snapshot.
        try "w\n".write(to: wt.appendingPathComponent("w.txt"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: wt.path)
        try git.run(["commit", "-qm", "sibling work"], workingDirectory: wt.path)
        let moved = try line(of: ["rev-parse", "refs/heads/agent-branch"],
                             at: repo.url.path)

        // Applying the snapshot would rewind the branch under the sibling's
        // checkout — reported with the worktree named, and refused.
        let report = try disturbances(restoring: recorded, at: repo.url.path)
        #expect(report == [WorktreeDisturbance.Disturbance(
            worktreePath: wt.path, branch: "refs/heads/agent-branch",
            current: moved, target: c, prunable: false)])

        let error = try #require(throws: WorktreeDisturbance.Error.self) {
            try WorktreeDisturbance.requireUndisturbed(
                by: recorded,
                in: WorktreeContext.resolve(path: repo.url.path))
        }
        #expect(error == .wouldDisturb(disturbances: report))
        #expect(error.description.contains("refs/heads/agent-branch"))
        #expect(error.description.contains(wt.path))
        #expect(error.exitClass == .repositoryError)
    }

    @Test func aSnapshotPredatingTheWorktreeReportsTheDeletion() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let recorded = try capture(at: repo.url.path)
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        let c = try #require(repo.oids["c"])

        // Restore would DELETE refs/heads/agent-branch (#0027's union
        // restore) — under the sibling's checkout.
        let report = try disturbances(restoring: recorded, at: repo.url.path)
        #expect(report == [WorktreeDisturbance.Disturbance(
            worktreePath: wt.path, branch: "refs/heads/agent-branch",
            current: c, target: nil, prunable: false)])
        #expect(report[0].target == nil)
    }

    // MARK: - What is deliberately not a disturbance

    @Test func aDetachedSiblingHoldsNoBranchAndIsNeverDisturbed() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let recorded = try capture(at: repo.url.path)
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        try git.run(["checkout", "-q", "--detach"], workingDirectory: wt.path)

        // The snapshot predates agent-branch, so restore would delete it —
        // but no worktree has it checked out any more.
        #expect(try disturbances(restoring: recorded, at: repo.url.path).isEmpty)
    }

    @Test func theCallersOwnCheckedOutBranchIsNotADisturbance() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        let a = try #require(repo.oids["a"])

        let recorded = try capture(at: repo.url.path)
        // Move the caller's own branch; restoring it back is what undoing
        // one's own operation IS, not a sibling casualty.
        try git.run(["update-ref", "refs/heads/main", a],
                    workingDirectory: repo.url.path)

        #expect(try disturbances(restoring: recorded, at: repo.url.path).isEmpty)
    }

    // MARK: - A deleted worktree still holds its claim

    @Test func aPrunableWorktreeStillRefusesAndSaysHowToRelease() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        let recorded = try capture(at: repo.url.path)
        try "w\n".write(to: wt.appendingPathComponent("w.txt"),
                        atomically: true, encoding: .utf8)
        try git.run(["add", "-A"], workingDirectory: wt.path)
        try git.run(["commit", "-qm", "sibling work"], workingDirectory: wt.path)

        // The agent's directory vanishes without `git worktree remove`.
        // Its administrative entry — and its claim on the branch — survive
        // until `git worktree prune`, and git's own porcelain still refuses
        // to touch the branch (measured), so the engine does too.
        try FileManager.default.removeItem(at: wt)

        let report = try disturbances(restoring: recorded, at: repo.url.path)
        try #require(report.count == 1)
        #expect(report[0].branch == "refs/heads/agent-branch")
        #expect(report[0].prunable)

        let error = try #require(throws: WorktreeDisturbance.Error.self) {
            try WorktreeDisturbance.requireUndisturbed(
                by: recorded,
                in: WorktreeContext.resolve(path: repo.url.path))
        }
        #expect(error.description.contains("git worktree prune"))
    }

    // MARK: - The pure diff: order and the dangling edge

    @Test func reportIsSortedAndSeesADanglingCheckout() throws {
        let x = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let y = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        func entry(_ path: String, branch: String) -> WorktreeEntry {
            WorktreeEntry(path: path, head: x, branch: branch,
                          locked: false, lockReason: nil, bare: false,
                          detached: false, prunable: false,
                          prunableReason: nil, isMainWorktree: false)
        }
        // Input deliberately reverse-ordered; zebra's branch does not exist
        // on the current side (a dangling checkout) and the snapshot would
        // re-create it — that is a disturbance too.
        let recorded = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [.init(name: "refs/heads/z-branch", oid: y),
                   .init(name: "refs/heads/a-branch", oid: y)])
        let current = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [.init(name: "refs/heads/a-branch", oid: x)])
        let report = WorktreeDisturbance.disturbances(
            restoring: recorded, current: current,
            worktrees: [entry("/w/zebra", branch: "z-branch"),
                        entry("/w/apple", branch: "a-branch")],
            callerPath: "/w/caller")
        #expect(report == [
            .init(worktreePath: "/w/apple", branch: "refs/heads/a-branch",
                  current: x, target: y, prunable: false),
            .init(worktreePath: "/w/zebra", branch: "refs/heads/z-branch",
                  current: nil, target: y, prunable: false),
        ])
    }
}
