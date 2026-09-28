// PathStaging.swift — stage and unstage whole paths, journaled (#0438, #0439)

import Foundation

/// Stages every change to `paths` — modified, deleted, untracked, a
/// mode change, a binary file — exactly as `git add -A -- <paths>` does.
///
/// Whole-file staging is not `stageHunks` with every id: an untracked file
/// has no hunks in `listHunks(.unstaged)` (`git diff` does not list
/// untracked files), and neither does a mode-only change, so a path-level
/// primitive is the only one that covers every row the Changes view shows.
///
/// `--literal-pathspecs` is load-bearing: without it git reads each path as
/// a pathspec, and a file literally named `*.txt` stages every `.txt` file
/// in the repository (measured, git 2.54.0, #0438). With it, only that one
/// file is staged.
///
/// An empty `paths` array is a no-op: git is not invoked and no journal
/// entry is written. A path git cannot match at all (neither in the index
/// nor on disk) fails with git's own `fatal: pathspec '…' did not match any
/// files`, exit 128, as `GitProcess.Failure.exited`; git stages nothing in
/// that case (measured).
///
/// **Writes exactly one journal entry per call**, via
/// `JournalCheckpoint.around(operation: "stage")` — the same operation
/// string `stageHunks` writes, so Edit ▸ Undo reads "Undo Stage" for both.
public func stagePaths(
    _ paths: [String],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    guard !paths.isEmpty else { return }
    try JournalCheckpoint.around(operation: "stage", at: path, git: git) { git in
        _ = try git.run(["--literal-pathspecs", "add", "-A", "--"] + paths, workingDirectory: path)
    }
}

/// Removes every staged change to `paths` from the index, leaving the
/// worktree untouched — `git reset -q -- <paths>`.
///
/// `git reset`, not `git restore --staged`: restore resolves `HEAD` first
/// and fails on an unborn branch (`fatal: could not resolve 'HEAD'`, exit
/// 128), while `reset -q -- <path>` unstages there too, leaving a newly
/// added file untracked (both measured, git 2.54.0, #0439). On a born
/// branch the two agree. `-q` because without it git prints "Unstaged
/// changes after reset:" — on stdout, exit 0, but noise.
///
/// **A staged rename needs both of its paths.** `git status` reports it as
/// one `R.` record whose `path` is the new name and `originalPath` the old;
/// resetting only the new path leaves the old one staged as a deletion
/// (measured). Callers pass both — `WorkingChanges.unstagePaths(for:)`
/// does (#0441).
///
/// `--literal-pathspecs`, for the reason `stagePaths` gives. An empty
/// `paths` array is a no-op. A path the index and `HEAD` both lack is a
/// silent no-op in git (exit 0, measured) and so here.
///
/// **Writes exactly one journal entry per call**, via
/// `JournalCheckpoint.around(operation: "unstage")` — the string
/// `unstageHunks` writes.
public func unstagePaths(
    _ paths: [String],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    guard !paths.isEmpty else { return }
    try JournalCheckpoint.around(operation: "unstage", at: path, git: git) { git in
        _ = try git.run(["--literal-pathspecs", "reset", "-q", "--"] + paths, workingDirectory: path)
    }
}
