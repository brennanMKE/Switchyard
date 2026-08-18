// RepositoryLayout.swift — where switchyard's own state sits inside a repository (#0149)

import Foundation

/// Paths **switchyard** owns inside a repository, relative to
/// `$GIT_COMMON_DIR` — with one deliberate exception,
/// `inFlightEntryIDRelativePath`, which is per-worktree; see its own doc
/// comment for why.
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
/// `inFlightEntryIDRelativePath` is the opposite case — per-worktree
/// disagreement is exactly what is wanted there — so it alone is resolved
/// through `WorktreeContext.path(for:)`.
public enum RepositoryLayout {

    /// Our per-repository directory, relative to `$GIT_COMMON_DIR`.
    public static let stateDirectoryName = "switchyard"

    /// The repository identity file, relative to `$GIT_COMMON_DIR`.
    public static let repositoryIDRelativePath = stateDirectoryName + "/repository-id"

    /// The journal metadata cache file, relative to `$GIT_COMMON_DIR`.
    public static let journalMetadataRelativePath = stateDirectoryName + "/journal.json"

    /// The in-flight rewrite entry id file — **the one path in this type
    /// that is per-worktree, not relative to `$GIT_COMMON_DIR`.** Resolved
    /// through `WorktreeContext.path(for:)` (`git rev-parse --git-path`),
    /// never through `stateDirectory(in:)`: an interrupted operation belongs
    /// to the worktree running it, the same reason `HEAD` and the sequencer
    /// are per-worktree, so `--git-path`'s per-worktree answer for a subpath
    /// it does not know (see this type's own doc comment above) is exactly
    /// right here rather than the hazard it is everywhere else (guide §11
    /// decision 19, #0237).
    ///
    /// Contents: the entry id's `description`, nothing else — one line, no
    /// JSON. `JournalCheckpoint.around` writes it right after minting the
    /// entry and removes it when its body returns normally; a body that
    /// throws mid-operation (`Fixup.run`'s `.blockedOnConflicts`) leaves it
    /// behind on purpose, and `JournalCheckpoint.attachRewrite` reads it back
    /// when the environment carries no id.
    public static let inFlightEntryIDRelativePath = stateDirectoryName + "/in-flight-entry-id"

    /// Absolute path of our state directory for a resolved context.
    public static func stateDirectory(in context: WorktreeContext) -> String {
        context.commonDir + "/" + stateDirectoryName
    }
}
