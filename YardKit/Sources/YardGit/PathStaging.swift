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
