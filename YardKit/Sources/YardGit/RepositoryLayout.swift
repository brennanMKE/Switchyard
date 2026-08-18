// RepositoryLayout.swift — where switchyard's own state sits inside a repository (#0149)

import Foundation

/// Paths **switchyard** owns inside a repository, relative to
/// `$GIT_COMMON_DIR` — with one deliberate exception,
/// `sequencerEntryIDFileName`, which is per-worktree and lives inside git's
/// own sequencer directory rather than under `stateDirectoryName`; see its
/// own doc comment for why.
///
/// These live in `YardGit` rather than in `ServiceNames` deliberately (guide
/// §11 decision 13): `YardGit` must not import `YardKit`, and per-repository
/// layout is a different concern from the bundle identifier and Mach service
/// name that `ServiceNames` exists for. A test in `Tests/YardWireTests` — the
/// one target that imports both — pins these against `ServiceNames` so a
/// rename on either side fails loudly.
///
/// **Never resolve `repositoryIDRelativePath` or `journalMetadataRelativePath`
/// through `git rev-parse --git-path`.** For a subpath git does not know,
/// `--git-path` answers **per-worktree**: measured, a linked worktree
/// resolves `switchyard/repository-id` to
/// `<repo>/.git/worktrees/<name>/switchyard/repository-id` while the main
/// worktree resolves it to `<repo>/.git/switchyard/repository-id`. Two
/// worktrees would then disagree about the repository's identity. Address
/// them from `WorktreeContext.commonDir`, which both agree on.
/// `sequencerEntryIDFileName` is the opposite case — per-worktree
/// disagreement is exactly what is wanted there — so it alone is resolved
/// through `WorktreeContext.path(for:)`.
public enum RepositoryLayout {

    /// Our per-repository directory, relative to `$GIT_COMMON_DIR`.
    public static let stateDirectoryName = "switchyard"

    /// The repository identity file, relative to `$GIT_COMMON_DIR`.
    public static let repositoryIDRelativePath = stateDirectoryName + "/repository-id"

    /// The journal metadata cache file, relative to `$GIT_COMMON_DIR`.
    public static let journalMetadataRelativePath = stateDirectoryName + "/journal.json"

    /// The in-flight rewrite entry id's filename — written **inside** the
    /// live sequencer directory itself (`rebase-merge/switchyard-entry-id`
    /// or `rebase-apply/switchyard-entry-id`), never beside it (guide §11
    /// decision 24, #0273).
    ///
    /// Measured, git 2.50.1: both `git rebase --continue` and `git rebase
    /// --abort` remove the whole sequencer directory, our file included. So
    /// the id cannot outlive the operation it was written for, and every
    /// staleness rule a file living *beside* the sequencer needed — this
    /// file's previous location, `switchyard/in-flight-entry-id` — is gone
    /// along with it: there is no case where this file names an operation
    /// that has already finished or been abandoned, because finishing or
    /// abandoning the operation is exactly what removes it.
    ///
    /// Not a full relative path: join it onto a live
    /// `SequencerSnapshot.Layout.rawValue`
    /// (`layout.rawValue + "/" + sequencerEntryIDFileName`) and resolve the
    /// result through `WorktreeContext.path(for:)` — never by concatenating
    /// onto `.git/`. `--git-path` answers per-worktree for a subpath it does
    /// not know (this type's own doc comment above), exactly right here
    /// since the sequencer directory itself is per-worktree.
    ///
    /// Contents: the entry id's `description`, nothing else — one line, no
    /// JSON. `JournalCheckpoint.around` writes it only once its body has
    /// thrown *and* a resumable git operation is still live — validated
    /// against `SequencerSnapshot` right there, never assumed from the throw
    /// alone (#0241) — which is exactly `Fixup.run`'s `.blockedOnConflicts`
    /// case. Nothing is ever written on a normal return, so a call that
    /// completes cleanly can never overwrite a slot another, still-resumable
    /// call already occupies. `JournalCheckpoint.attachRewrite` reads it back
    /// when the environment carries no id.
    public static let sequencerEntryIDFileName = "switchyard-entry-id"

    /// Absolute path of our state directory for a resolved context.
    public static func stateDirectory(in context: WorktreeContext) -> String {
        context.commonDir + "/" + stateDirectoryName
    }
}
