// Unstaging.swift — unstage hunks by their stable content-derived ids (#0162)

import Foundation

/// Removes the hunks with the given ids from the index, leaving the worktree
/// untouched.
///
/// Ids come from `listHunks(at:area:git:)` over the **staged** area, and the
/// listing is re-taken inside this call, so headers are always fresh — the
/// same design as `stageHunks(ids:at:git:)`, sharing its `selectPatch` and
/// its `StagingError`.
///
/// The mechanism is `git apply --cached --reverse` on the reconstructed
/// patch, not `git restore --staged`: restore is **file-level** — measured,
/// it unstages every hunk of the file, so it cannot address one hunk of a
/// partially staged file. For a staged **new** file the two agree (measured:
/// both remove the index entry and leave the worktree file untracked), and
/// reverse-apply handles that case through the `new file mode` header the
/// staged listing already carries.
///
/// All-or-none, same as staging: ids resolve against the fresh listing
/// before anything is applied — a stale or unknown id throws
/// `StagingError.unknownHunkIDs` and unstages nothing — and the selected
/// hunks go to git as one atomic `git apply` invocation.
///
/// A combined (`diff --cc`) hunk is refused typed before apply, exactly as
/// in staging (#0350): the check lives in the shared `selectPatch`, so
/// unstage inherits it for both areas. Git itself never prints a combined
/// block for the *staged* area — an unmerged path is a `* Unmerged path`
/// line there, which the parser drops — so the shared check guards the
/// shape rather than a measured staging-area state.
///
/// An empty `ids` array is a no-op; git is not invoked.
///
/// **Writes exactly one journal entry per call (#0212)**, via
/// `JournalCheckpoint.around`, so `undo` works after unstaging directly.
/// This is the entry point everything outside this file must call — see
/// `stageHunks` in `Staging.swift`, the identical shape.
public func unstageHunks(
    ids: [String],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    try JournalCheckpoint.around(operation: "unstage", at: path, git: git) { git in
        try unstageHunksWithoutCheckpoint(ids: ids, at: path, git: git)
    }
}

/// The non-checkpointing primitive, for any future composed command that
/// needs to unstage inside a single checkpoint of its own (#0212) — the same
/// reason `stageHunksWithoutCheckpoint` exists.
func unstageHunksWithoutCheckpoint(
    ids: [String],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    let files = try listHunks(at: path, area: .staged, git: git)
    let patch = try selectPatch(ids: ids, from: files, area: .staged)
    guard !patch.isEmpty else { return }
    try git.run(["apply", "--cached", "--reverse"],
                workingDirectory: path,
                standardInput: Data(patch.utf8))
}
