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
/// An empty `ids` array is a no-op; git is not invoked.
public func unstageHunks(
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
