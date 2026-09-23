// ConflictHandoff.swift — continue or abort the hand-off state an in-app
// operation leaves behind when it stops on a conflict (#0394)

import Foundation

/// The two ways the conflict hand-off is concluded once the human has
/// resolved the index (the resolve pane's Submit stages it) — or decided
/// against resolving at all:
///
/// - **Continue** — the operation completes itself, exactly as it would
///   from a terminal. The argv is per kind, measured on git 2.54.0
///   (#0394): a revert or cherry-pick continues through its own porcelain
///   carrying the same signing intent the original invocation rode
///   (`revert --continue` measured accepted with `--no-gpg-sign`;
///   cherry-pick rides the same porcelain); a merge completes as the
///   commit git was stopped from making (`commit --no-edit`, git's own
///   `MERGE_MSG`); a rebase continues bare, replaying its own recorded
///   flags. One exclusion, measured: the `Rewrite` family's replay picks
///   run detached (`Rewrite.swift`'s own `checkout --detach`) and the ref
///   move lives in `Rewrite.perform`'s memory — `cherry-pick --continue`
///   would finish the picks with HEAD still detached and the branch
///   unmoved, so `continuableKind(for:)` answers nil for exactly that
///   state and Continue is never offered there.
///
/// - **Abort** — back out entirely: one journal undo restores the
///   pre-operation entry `JournalCheckpoint.around` wrote, then the
///   operation's own `--abort` clears what the restore does not touch.
///   The undo alone cannot clear a merge/revert/pick stop:
///   `JournalRestore`'s restore (steps 8–8c) restores refs/HEAD/index/
///   worktree and the rebase-merge/rebase-apply layouts only — it never
///   removes `MERGE_HEAD`, `REVERT_HEAD`, `CHERRY_PICK_HEAD`, or
///   cherry-pick's own `.git/sequencer/` (#0394, measured on git 2.54.0,
///   where every `--abort` removes all of its state files, leaving only
///   `ORIG_HEAD`).
public enum ConflictHandoff {

    /// The git operation a conflict hand-off can conclude.
    public enum Kind: Equatable, Sendable, CaseIterable {
        case revert
        case cherryPick
        case merge
        case rebase
    }

    /// The human-readable operation name — the word git itself uses for
    /// the subcommand, which is what the header's Continue button and the
    /// Abort dialog speak: "revert", "cherry-pick", "merge", "rebase".
    public static func name(of kind: Kind) -> String {
        switch kind {
        case .revert: "revert"
        case .cherryPick: "cherry-pick"
        case .merge: "merge"
        case .rebase: "rebase"
        }
    }

    /// The in-progress operation `state` shows, or `nil` when none holds.
    /// The precedence is `TrackingSummary.operationInProgress`'s (#0369) —
    /// rebase, merge, cherry-pick, revert — so the header's Abort and the
    /// disabled row-menu items always name the same operation.
    public static func inProgressKind(for state: WhereAmI) -> Kind? {
        if state.isMidRebase { return .rebase }
        if state.isMidMerge { return .merge }
        if state.isMidCherryPick { return .cherryPick }
        if state.isMidRevert { return .revert }
        return nil
    }

    /// The operation Continue may complete, or `nil` when none holds. Same
    /// precedence as `inProgressKind`, with the one measured exclusion: a
    /// cherry-pick continues only when HEAD is attached to a branch
    /// (`state.branch != nil`). A detached pick is the `Rewrite` family's
    /// own scratch replay — the branch move lives in `Rewrite.perform`'s
    /// memory and no git command finishes it — while a foreign multi-pick
    /// on a branch is git-owned and `cherry-pick --continue` completes it
    /// correctly, branch and all.
    public static func continuableKind(for state: WhereAmI) -> Kind? {
        if state.isMidRebase { return .rebase }
        if state.isMidMerge { return .merge }
        if state.isMidCherryPick { return state.branch == nil ? nil : .cherryPick }
        if state.isMidRevert { return .revert }
        return nil
    }

    /// Continues `kind`'s in-flight operation and returns `rev-parse HEAD`
    /// afterwards — the oid the operation's own ref move landed on.
    ///
    /// A non-zero exit throws `GitProcess.Failure` carrying git's stderr:
    /// the pane's Submit stages the index first, so "nothing to commit"
    /// from a merge's `commit --no-edit` is a real condition worth
    /// surfacing, not one to swallow.
    @discardableResult
    public static func runContinue(
        kind: Kind,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess()
    ) throws -> String {
        // The #0060 explicit flag rides the porcelain that commits, exactly
        // as the original invocation did; the rebase spells none of its own
        // and replays what it recorded.
        let flag = CommitCreate.arguments(for: signing)
        let arguments: [String]
        switch kind {
        case .revert:
            arguments = ["revert", "--continue"] + flag
        case .cherryPick:
            arguments = ["cherry-pick", "--continue"] + flag
        case .merge:
            arguments = ["commit", "--no-edit"] + flag
        case .rebase:
            arguments = ["rebase", "--continue"]
        }
        _ = try git.run(arguments, workingDirectory: path)
        return try git.run(["rev-parse", "HEAD"], workingDirectory: path).lines.first ?? ""
    }

    /// Aborts the in-flight operation at `path`: one journal undo restores
    /// the pre-operation entry `JournalCheckpoint.around` wrote, then the
    /// still-live conflict state's own `--abort` clears what the restore
    /// does not touch.
    ///
    /// The probe asks git where each state file lives (`rev-parse
    /// --git-path`, `--path-format=absolute` — worktree- and
    /// reftable-correct, the same probe `WhereAmI`'s flags read) and checks
    /// it on disk, in the order `MERGE_HEAD` → `REVERT_HEAD` →
    /// `CHERRY_PICK_HEAD` → the rebase directories, and the first live
    /// state's own subcommand aborts it. The abort itself is tolerated
    /// (`try?`), the same shape `Replay.abort`'s callers use: a state whose
    /// worktree the undo already restored needs no successful abort to
    /// leave the repository where the user asked, and one that refuses
    /// cannot undo the restore that already happened.
    public static func runAbort(at path: String, git: GitProcess = GitProcess()) throws {
        let context = try WorktreeContext.resolve(path: path, git: git)
        try JournalUndo.undo(steps: 1, in: context, git: git)
        let base = context.topLevel ?? context.gitDir
        // (state name to probe, the subcommand that aborts it). Order
        // pinned by #0394's plan; the two rebase layouts both answer to
        // `rebase --abort`.
        let states: [(name: String, aborts: String)] = [
            ("MERGE_HEAD", "merge"),
            ("REVERT_HEAD", "revert"),
            ("CHERRY_PICK_HEAD", "cherry-pick"),
            ("rebase-merge", "rebase"),
            ("rebase-apply", "rebase"),
        ]
        for state in states {
            guard let out = try? git.capture(
                ["rev-parse", "--path-format=absolute", "--git-path", state.name],
                workingDirectory: base),
                let probePath = out.lines.first, !probePath.isEmpty,
                FileManager.default.fileExists(atPath: probePath)
            else { continue }
            _ = try? git.run([state.aborts, "--abort"], workingDirectory: base)
            clearLeftoverPickState(at: base, git: git)
            return
        }
    }

    /// Measured on git 2.54.0 (#0394, scratch under the issue's build/):
    /// when the journal undo has already moved HEAD back, a multi-pick
    /// replay's `cherry-pick --abort` warns "You seem to have moved HEAD.
    /// Not rewinding" — it removes the sequencer but leaves
    /// `CHERRY_PICK_HEAD`, the one file `WhereAmI.isMidCherryPick` reads,
    /// so the repository would report a pick in progress forever.
    /// `--quit` is the sequencer-cleanup form that rewinds nothing: it
    /// clears both `.git/sequencer` and the pick head, and is a no-op
    /// (exit 0) when nothing is live, so the sweep is safe after every
    /// matched abort.
    private static func clearLeftoverPickState(at base: String, git: GitProcess) {
        guard let out = try? git.capture(
            ["rev-parse", "--path-format=absolute", "--git-path", "CHERRY_PICK_HEAD"],
            workingDirectory: base),
            let probePath = out.lines.first, !probePath.isEmpty,
            FileManager.default.fileExists(atPath: probePath)
        else { return }
        _ = try? git.run(["cherry-pick", "--quit"], workingDirectory: base)
    }
}
