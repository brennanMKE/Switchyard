// RepositoryLayout.swift — where switchyard's own state sits inside a repository (#0149)

import Foundation

/// Paths **switchyard** owns inside a repository, all relative to
/// `$GIT_COMMON_DIR`.
///
/// These live in `YardGit` rather than in `ServiceNames` deliberately (guide
/// §11 decision 13): `YardGit` must not import `YardKit`, and per-repository
/// layout is a different concern from the bundle identifier and Mach service
/// name that `ServiceNames` exists for. A test in `Tests/YardWireTests` — the
/// one target that imports both — pins these against `ServiceNames` so a
/// rename on either side fails loudly.
///
/// **Never resolve these through `git rev-parse --git-path`.** For a subpath
/// git does not know, `--git-path` answers **per-worktree**: measured, a
/// linked worktree resolves `switchyard/repository-id` to
/// `<repo>/.git/worktrees/<name>/switchyard/repository-id` while the main
/// worktree resolves it to `<repo>/.git/switchyard/repository-id`. Two
/// worktrees would then disagree about the repository's identity. Address
/// them from `WorktreeContext.commonDir`, which both agree on.
public enum RepositoryLayout {

    /// Our per-repository directory, relative to `$GIT_COMMON_DIR`.
    public static let stateDirectoryName = "switchyard"

    /// The repository identity file, relative to `$GIT_COMMON_DIR`.
    public static let repositoryIDRelativePath = stateDirectoryName + "/repository-id"

    /// Absolute path of our state directory for a resolved context.
    public static func stateDirectory(in context: WorktreeContext) -> String {
        context.commonDir + "/" + stateDirectoryName
    }
}
