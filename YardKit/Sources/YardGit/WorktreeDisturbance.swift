// WorktreeDisturbance.swift — sibling checkouts a restore would wreck (#0044)

import Foundation

/// Names every sibling worktree whose checked-out branch a ref-snapshot
/// restore would move, delete, or re-create.
///
/// `refs/heads/*` is shared across worktrees, and a sibling's working copy
/// and index are built against the commit its branch points at. Git's own
/// porcelain enforces the exclusivity: `git checkout`, `git branch -f`, and
/// `git branch -d` all refuse to touch a branch another worktree has checked
/// out (measured: exit 128, 128, and 1, each naming the holding worktree's
/// path). But `git update-ref` — including the `--stdin` transactions
/// `RefSnapshot.restore` is built on — moves or deletes the same branch
/// **silently, exit 0**, leaving the sibling's checkout inconsistent with
/// its own `HEAD`. So the engine adds the refusal git's plumbing does not:
/// before applying a snapshot, name every sibling checkout it would disturb,
/// and refuse while any exists.
///
/// A **prunable** worktree (directory deleted without `git worktree remove`)
/// still holds its branch: porcelain still lists it, and git's porcelain
/// refusals still fire for it (measured). The refusal here matches, with
/// `prunable: true` carried so the caller can say how to release the claim
/// (`git worktree prune` / `switchyard wt gc`). Honesty over recovery.
///
/// A **detached** sibling holds no branch and is never disturbed — restoring
/// shared refs cannot move a detached `HEAD`, which is per-worktree state.
/// The calling worktree's own checked-out branch is deliberately not a
/// disturbance: moving it is what restoring one's own checkpoint *is*, and
/// the caller's index and files are the checkpoint's business, not a
/// sibling casualty.
public enum WorktreeDisturbance {

    /// One sibling checkout the restore would leave inconsistent.
    ///
    /// `current` is the branch's oid now (nil when the branch does not
    /// currently exist — a dangling checkout); `target` is what restore
    /// would write (nil when restore deletes the branch). They differ by
    /// construction.
    public struct Disturbance: Sendable, Equatable {
        /// Canonicalized path of the sibling worktree, as porcelain reports
        /// it — the same identity git's own refusal messages use.
        public let worktreePath: String
        /// Full ref name of the checked-out branch, `refs/heads/<name>`.
        public let branch: String
        public let current: String?
        public let target: String?
        /// The sibling's directory is gone but its claim survives until
        /// `git worktree prune`.
        public let prunable: Bool

        public init(worktreePath: String, branch: String,
                    current: String?, target: String?, prunable: Bool) {
            self.worktreePath = worktreePath
            self.branch = branch
            self.current = current
            self.target = target
            self.prunable = prunable
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// Applying the snapshot would leave these sibling checkouts
        /// inconsistent with their own `HEAD`s. Carries every disturbance:
        /// the refusal must name the worktree, the branch, and both values,
        /// or whoever hits it cannot act on it.
        case wouldDisturb(disturbances: [Disturbance])

        public var description: String {
            switch self {
            case let .wouldDisturb(disturbances):
                let details = disturbances.map { d in
                    let change = d.target.map { "move to \($0)" } ?? "delete it"
                    let claim = d.prunable
                        ? " (worktree directory is gone; release with git worktree prune)"
                        : ""
                    return "\(d.branch) is checked out in \(d.worktreePath)\(claim); "
                        + "restore would \(change)"
                }
                .joined(separator: "; ")
                return "restore would disturb another worktree: \(details)"
            }
        }
    }

    // MARK: - Detection

    /// Pure core: which sibling checkouts does applying `recorded` disturb,
    /// given the current refs and the worktree list. Deterministic order:
    /// sorted by worktree path, then branch.
    ///
    /// `callerPath` is the calling worktree's canonicalized top level (nil in
    /// a bare repository); the entry whose path matches is the caller and is
    /// never a disturbance.
    public static func disturbances(
        restoring recorded: RefSnapshot,
        current: RefSnapshot,
        worktrees: [WorktreeEntry],
        callerPath: String?
    ) -> [Disturbance] {
        let recordedByName = Dictionary(
            uniqueKeysWithValues: recorded.refs.map { ($0.name, $0.oid) })
        let currentByName = Dictionary(
            uniqueKeysWithValues: current.refs.map { ($0.name, $0.oid) })

        var result: [Disturbance] = []
        for entry in worktrees {
            // Holding a branch is the only thing that matters: a detached or
            // bare record carries no `branch` attribute (measured — porcelain
            // emits `detached` with no `branch` line), so both fall out here.
            guard let rawPath = entry.path, let branch = entry.branch
            else { continue }
            // Canonicalized like every other path comparison in the engine:
            // /var and /private/var are one directory, and the caller's
            // topLevel is already canonical.
            let path = WorktreeContext.canonicalize(rawPath)
            guard path != callerPath else { continue }
            let ref = "refs/heads/" + branch
            let currentOid = currentByName[ref]
            let targetOid = recordedByName[ref]
            guard currentOid != targetOid else { continue }
            result.append(Disturbance(
                worktreePath: path, branch: ref,
                current: currentOid, target: targetOid,
                prunable: entry.prunable))
        }
        return result.sorted {
            ($0.worktreePath, $0.branch) < ($1.worktreePath, $1.branch)
        }
    }

    /// Captures the current state and worktree list, then diffs. The listing
    /// and capture run in the calling context — shared refs are visible from
    /// any worktree, so the sibling comparison is worktree-independent.
    public static func disturbances(
        restoring recorded: RefSnapshot,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [Disturbance] {
        let base = context.topLevel ?? context.gitDir
        return disturbances(
            restoring: recorded,
            current: try RefSnapshot.capture(in: context, git: git),
            worktrees: try worktreeList(path: base, git: git),
            callerPath: context.topLevel)
    }

    /// Throws `Error.wouldDisturb` naming every disturbed sibling unless the
    /// snapshot can apply without wrecking one. Restore flows (#0168) call
    /// this on the snapshot **being applied**, after the cross-tool guard
    /// and regardless of whether the guard was bypassed — the guard answers
    /// "did refs move behind the journal's back", this answers "would
    /// applying the target snapshot wreck a sibling's checkout", and neither
    /// question substitutes for the other.
    public static func requireUndisturbed(
        by recorded: RefSnapshot,
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws {
        let found = try disturbances(restoring: recorded, in: context, git: git)
        guard found.isEmpty else {
            throw Error.wouldDisturb(disturbances: found)
        }
    }
}

// MARK: - §6 exit class (#0141)

/// The repository is in a state the operation cannot safely work with —
/// guide §6 code 6, the same class as the cross-tool guard's refusal.
extension WorktreeDisturbance.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

// MARK: - Wire encoding (#0130)

/// A disturbance rides the wire inside the structured error payload: agents
/// branch on `worktreePath`/`branch`/`prunable`, so the shape is contract.
extension WorktreeDisturbance.Disturbance: Encodable {
    /// Stable wire keys, identical to the member names; no raw values. The
    /// enum is rename-safety; byte pinning lands with the undo envelope (M3).
    private enum CodingKeys: String, CodingKey {
        case worktreePath, branch, current, target, prunable
    }
}
