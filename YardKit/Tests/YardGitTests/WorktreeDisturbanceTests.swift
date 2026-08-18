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

    // A snapshot taken before the sibling's branch existed never recorded
    // it. Before guide §11 decision 20, restore deleted every ref absent
    // from the snapshot, so this was reported as a disturbance (the
    // deletion); after decision 20, restore leaves an unrecorded ref alone,
    // so a live sibling standing on it is not disturbed at all (#0244).
    @Test func aSnapshotPredatingTheWorktreeNeverDisturbsItsLiveCheckout() throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let recorded = try capture(at: repo.url.path)
        let wt = try repo.addWorktree(named: "agent-a", branch: "agent-branch")
        defer { try? FileManager.default.removeItem(at: wt) }
        let c = try #require(repo.oids["c"])

        // The snapshot never mentions refs/heads/agent-branch, so restoring
        // it cannot move or delete that branch (decision 20) — the sibling's
        // checkout is not a disturbance.
        #expect(try disturbances(restoring: recorded, at: repo.url.path).isEmpty)

        // Restoring for real leaves the branch exactly where it was.
        try recorded.restore(in: WorktreeContext.resolve(path: repo.url.path))
        #expect(try line(of: ["rev-parse", "refs/heads/agent-branch"],
                         at: repo.url.path) == c)
    }

    // MARK: - Error.description's fallback for a nil target (#0250)

    // `disturbances(...)` can never produce a `target: nil` entry (#0244's
    // guard filters unrecorded refs out before construction), but the field
    // stays `String?` for wire stability, so `description` still needs a
    // fallback for one. Before #0250 the fallback claimed "delete it",
    // which restore can no longer do at all (guide §11 decision 20) — this
    // hand-builds the otherwise-unreachable case and pins the honest
    // replacement text.
    @Test func aHandBuiltDisturbanceWithNoTargetGetsATrueDescription() {
        let error = WorktreeDisturbance.Error.wouldDisturb(disturbances: [
            WorktreeDisturbance.Disturbance(
                worktreePath: "/w/sibling", branch: "refs/heads/agent-branch",
                current: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                target: nil, prunable: false),
        ])
        #expect(error.description.contains("touch it"))
        #expect(!error.description.contains("delete it"))
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

    // A ref present on the current side but absent from `recorded` entirely
    // (not merely differing in oid) is never a disturbance: restore only
    // ever writes refs it recorded (decision 20), so it cannot touch this
    // one however live the sibling's checkout is. This exercises the pure
    // function directly, distinct from the empty-repository probe above.
    @Test func aBranchTheSnapshotNeverMentionsIsNeverADisturbance() throws {
        let x = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        func entry(_ path: String, branch: String) -> WorktreeEntry {
            WorktreeEntry(path: path, head: x, branch: branch,
                          locked: false, lockReason: nil, bare: false,
                          detached: false, prunable: false,
                          prunableReason: nil, isMainWorktree: false)
        }
        let recorded = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"), refs: [])
        let current = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [.init(name: "refs/heads/agent-branch", oid: x)])
        let report = WorktreeDisturbance.disturbances(
            restoring: recorded, current: current,
            worktrees: [entry("/w/sibling", branch: "agent-branch")],
            callerPath: "/w/caller")
        #expect(report.isEmpty)
    }

    // MARK: - detachingHeldHead: detach on collision (#0211, guide §11 decision 16)

    private func liveEntry(_ path: String, branch: String) -> WorktreeEntry {
        WorktreeEntry(path: path, head: nil, branch: branch,
                      locked: false, lockReason: nil, bare: false,
                      detached: false, prunable: false,
                      prunableReason: nil, isMainWorktree: false)
    }

    @Test func aLiveSiblingHoldingTheBranchDetachesHeadAtTheRecordedOid() {
        let oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let snapshot = RefSnapshot(
            head: .symbolic(target: "refs/heads/agent-branch"),
            refs: [.init(name: "refs/heads/agent-branch", oid: oid)])
        let result = WorktreeDisturbance.detachingHeldHead(
            in: snapshot,
            worktrees: [liveEntry("/w/sibling", branch: "agent-branch")],
            callerPath: "/w/caller")
        #expect(result.snapshot.head == .detached(oid: oid))
        #expect(result.snapshot.refs == snapshot.refs)
        #expect(result.detachedFrom == "refs/heads/agent-branch")
    }

    @Test func aPrunedSiblingHoldingTheBranchLeavesHeadSymbolic() {
        // This is the dead-agent recovery case #0175 exists for: a pruned
        // record holds nothing, so adopting its HEAD is correct.
        let oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let snapshot = RefSnapshot(
            head: .symbolic(target: "refs/heads/agent-branch"),
            refs: [.init(name: "refs/heads/agent-branch", oid: oid)])
        var pruned = liveEntry("/w/sibling", branch: "agent-branch")
        pruned = WorktreeEntry(path: pruned.path, head: pruned.head, branch: pruned.branch,
                                locked: false, lockReason: nil, bare: false,
                                detached: false, prunable: true,
                                prunableReason: "gitdir file points to non-existent location",
                                isMainWorktree: false)
        let result = WorktreeDisturbance.detachingHeldHead(
            in: snapshot, worktrees: [pruned], callerPath: "/w/caller")
        #expect(result.snapshot == snapshot)
        #expect(result.detachedFrom == nil)
    }

    @Test func theCallerHoldingItsOwnBranchIsNeverDetached() {
        let oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let snapshot = RefSnapshot(
            head: .symbolic(target: "refs/heads/agent-branch"),
            refs: [.init(name: "refs/heads/agent-branch", oid: oid)])
        let result = WorktreeDisturbance.detachingHeldHead(
            in: snapshot,
            worktrees: [liveEntry("/w/caller", branch: "agent-branch")],
            callerPath: "/w/caller")
        #expect(result.snapshot == snapshot)
        #expect(result.detachedFrom == nil)
    }

    @Test func aDetachedHeadInIsReturnedUnchanged() {
        let oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let snapshot = RefSnapshot(head: .detached(oid: oid), refs: [])
        let result = WorktreeDisturbance.detachingHeldHead(
            in: snapshot,
            worktrees: [liveEntry("/w/sibling", branch: "agent-branch")],
            callerPath: "/w/caller")
        #expect(result.snapshot == snapshot)
        #expect(result.detachedFrom == nil)
    }

    @Test func aBranchAbsentFromTheSnapshotsRefsLeavesHeadSymbolic() {
        // No `refs/heads/agent-branch` entry in `refs` -- fabricating a
        // detached head from an oid the snapshot never recorded would be
        // inventing state.
        let snapshot = RefSnapshot(
            head: .symbolic(target: "refs/heads/agent-branch"), refs: [])
        let result = WorktreeDisturbance.detachingHeldHead(
            in: snapshot,
            worktrees: [liveEntry("/w/sibling", branch: "agent-branch")],
            callerPath: "/w/caller")
        #expect(result.snapshot == snapshot)
        #expect(result.detachedFrom == nil)
    }
}
