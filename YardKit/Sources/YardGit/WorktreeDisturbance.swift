// WorktreeDisturbance.swift — sibling checkouts a restore would wreck (#0044)

import Foundation

/// Names every sibling worktree whose checked-out branch a ref-snapshot
/// restore would move or re-create.
///
/// `refs/heads/*` is shared across worktrees, and a sibling's working copy
/// and index are built against the commit its branch points at. Git's own
/// porcelain enforces the exclusivity: `git checkout`, `git branch -f`, and
/// `git branch -d` all refuse to touch a branch another worktree has checked
/// out (measured: exit 128, 128, and 1, each naming the holding worktree's
/// path). But `git update-ref` — including the `--stdin` transactions
/// `RefSnapshot.restore` is built on — moves or deletes the same branch
/// **silently, exit 0**, leaving the sibling's checkout inconsistent with
/// its own `HEAD`. `disturbances` names every sibling checkout a snapshot
/// would disturb; what a caller does with that list is its own decision —
/// `requireUndisturbed` refuses while any exists (#0173's original answer),
/// and `JournalRestore` instead leaves a **live** one alone and reports it
/// (guide §11 decision 23, `leavingLiveDisturbances` below).
///
/// A **prunable** worktree (directory deleted without `git worktree remove`)
/// still holds its branch: porcelain still lists it, and git's porcelain
/// refusals still fire for it (measured), so `disturbances` still names it
/// — with `prunable: true` carried so a refusing caller can say how to
/// release the claim (`git worktree prune` / `switchyard wt gc`). But it
/// holds nothing a live agent is standing on, which is why `JournalRestore`
/// treats it differently from a live disturbance: it is not left alone, and
/// its branch is written back like any other ref the snapshot recorded.
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
    /// would write it to. `target` is never nil here: a branch the snapshot
    /// never recorded is left untouched by restore (guide §11 decision 20)
    /// and so is never a disturbance, whatever its current state — only a
    /// name the snapshot actually carries can move or be re-created. `target`
    /// stays `String?` because it rides the wire (#0130) and dropping the
    /// optional would be a breaking change for no behavioral gain.
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
                    // `d.target` is never nil for a `Disturbance` this type
                    // actually produces (#0244's guard proves it), but the
                    // field stays `String?` for wire stability (#0130), so
                    // this still needs a fallback. "delete it" would be
                    // false — restore no longer deletes anything (guide §11
                    // decision 20) — so the fallback says only what is true
                    // regardless of which of the two real cases applies.
                    let change = d.target.map { "move to \($0)" } ?? "touch it"
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
            // A name the snapshot never recorded is left untouched by
            // restore (guide §11 decision 20 — restore no longer deletes
            // unrecorded refs), so it cannot be disturbed no matter what its
            // current value is. Only a ref the snapshot actually carries can
            // move or be re-created under a sibling's checkout.
            guard let targetOid = recordedByName[ref] else { continue }
            let currentOid = currentByName[ref]
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
    /// snapshot can apply without wrecking one.
    ///
    /// **`JournalRestore` does not call this.** It answers "would applying
    /// the target snapshot wreck a sibling's checkout" the way #0173
    /// originally needed, but guide §11 decision 23 changed what restore
    /// does with that answer: a **live** sibling's held branch is left
    /// alone (`leavingLiveDisturbances` above) rather than refusing the
    /// whole operation. This keeps the strict refusal #0044 decision 2
    /// described, for a caller that still wants it — a future force
    /// surface — and is exercised directly by its own tests today.
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

    // MARK: - Detach on collision (#0211, guide §11 decision 16)

    /// The snapshot to apply, with `HEAD` detached when its branch is checked out
    /// by a live sibling.
    ///
    /// Returns the branch that was given up, or nil when nothing changed, so the
    /// caller can say what it did rather than doing it silently.
    ///
    /// Rules, in order:
    ///
    /// 1. `snapshot.head` must be `.symbolic(target:)`; a `.detached` head is
    ///    returned unchanged.
    /// 2. Some entry in `worktrees` must have `prunable == false`, a
    ///    canonicalized `path != callerPath`, and `"refs/heads/" + branch ==
    ///    target`. A prunable sibling holds nothing — adopting its branch is
    ///    the dead-agent recovery case #0175 exists for, so this keys on
    ///    liveness, never on `allowDifferentWorktree`.
    /// 3. The oid comes from `snapshot.refs` under that name. If the snapshot
    ///    does not carry the branch, it is returned unchanged and the existing
    ///    checks speak — fabricating a detached head from an oid the snapshot
    ///    never recorded would be inventing state.
    public static func detachingHeldHead(
        in snapshot: RefSnapshot,
        worktrees: [WorktreeEntry],
        callerPath: String?
    ) -> (snapshot: RefSnapshot, detachedFrom: String?) {
        guard case let .symbolic(target) = snapshot.head else {
            return (snapshot, nil)
        }
        let heldByLiveSibling = worktrees.contains { entry in
            guard !entry.prunable, let rawPath = entry.path, let branch = entry.branch
            else { return false }
            let path = WorktreeContext.canonicalize(rawPath)
            return path != callerPath && "refs/heads/" + branch == target
        }
        guard heldByLiveSibling else { return (snapshot, nil) }
        guard let oid = snapshot.refs.first(where: { $0.name == target })?.oid else {
            return (snapshot, nil)
        }
        return (RefSnapshot(head: .detached(oid: oid), refs: snapshot.refs), target)
    }

    // MARK: - Leave live siblings alone rather than refuse (guide §11 decision 23)

    /// The snapshot to apply, with each **live** sibling's held branch
    /// dropped so restore leaves it exactly as it stands, and the branches
    /// left alone, sorted the same way `disturbances` is.
    ///
    /// Keyed on liveness, the same field `detachingHeldHead` above already
    /// reads: a **prunable** holder holds nothing (#0211, decision 16), so
    /// `disturbances` still names it here but this function does not drop
    /// its branch — the branch is written back like any other ref the
    /// snapshot recorded (decision 20's ordinary case), which is the
    /// dead-agent recovery #0175 exists for.
    ///
    /// `disturbances` must be computed against the *same* `snapshot` passed
    /// here, and by the caller — not by this function — so a caller that
    /// needs the pre-drop set for something else (the cross-tool guard,
    /// #0251's trap) computes it exactly once and this only ever filters,
    /// never re-derives.
    public static func leavingLiveDisturbances(
        _ disturbances: [Disturbance],
        from snapshot: RefSnapshot
    ) -> (snapshot: RefSnapshot, leftAlone: [String]) {
        let live = disturbances.filter { !$0.prunable }
        guard !live.isEmpty else { return (snapshot, []) }
        let names = Set(live.map(\.branch))
        let filtered = RefSnapshot(
            head: snapshot.head,
            refs: snapshot.refs.filter { !names.contains($0.name) })
        return (filtered, live.map(\.branch))
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
