// Staging.swift — stage hunks by their stable content-derived ids (#0040)

import Foundation

/// Why staging or unstaging by hunk id could not proceed.
public enum StagingError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Ids that do not appear in a fresh listing of the given area. An id
    /// goes stale the moment the hunk's own lines change — the id is a hash
    /// of path and body (#0016) — so a stale id is simply absent from the
    /// fresh listing and is refused by name here rather than guessed at.
    /// `git apply` itself cannot be the detector: measured, a patch whose
    /// `@@` header and `index` line are both stale still applies (git
    /// offset-searches for context), so relying on apply failure would let
    /// a stale id stage the wrong thing silently.
    case unknownHunkIDs(ids: [String], area: DiffArea)

    public var description: String {
        switch self {
        case let .unknownHunkIDs(ids, area):
            "unknown hunk id(s) in the \(area.rawValue) listing: "
                + ids.joined(separator: ", ")
                + " — stale (the hunk changed since it was listed) or never valid"
        }
    }
}

/// Stages the hunks with the given ids: index gains exactly those changes.
///
/// Ids come from `listHunks(at:area:git:)` over the **unstaged** area. The
/// listing is re-taken inside this call, so headers are always fresh — an id
/// survives an earlier hunk being staged (its `@@` line shifts, its body does
/// not), and the patch fed to git is rebuilt from the current listing, never
/// from whatever listing the caller decided from.
///
/// All-or-none: every id is resolved before anything is applied, and the
/// selected hunks go to git as **one** `git apply --cached` invocation, which
/// is atomic — measured: a two-file patch whose second file fails leaves the
/// first unstaged. An unknown or stale id therefore stages nothing.
///
/// Conflicted files are unaddressable: git prints unmerged paths as combined
/// diffs (`diff --cc`), which carry no stable ids, so no id can name a hunk
/// of a conflicted file — staging one fails with `unknownHunkIDs`. Other
/// files stage normally while the index holds unmerged entries (measured).
///
/// An empty `ids` array is a no-op: nothing to resolve, and `git apply` on
/// an empty patch is an error (`No valid patches in input`, exit 128), so
/// git is not invoked at all.
public func stageHunks(
    ids: [String],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    let files = try listHunks(at: path, area: .unstaged, git: git)
    let patch = try selectPatch(ids: ids, from: files, area: .unstaged)
    guard !patch.isEmpty else { return }
    try git.run(["apply", "--cached"],
                workingDirectory: path,
                standardInput: Data(patch.utf8))
}

/// Builds the patch text for the requested hunk ids: for every file owning
/// at least one requested hunk, its `headerText` followed by the requested
/// hunks' `patchText` in **listing order** — hunks inside one file patch must
/// stay in file order whatever order the caller passed the ids in. Duplicate
/// ids in the request select the hunk once. Throws `unknownHunkIDs` (in
/// caller order, deduplicated) when any id matches nothing; returns "" for
/// an empty request.
func selectPatch(ids: [String], from files: [FileDiff], area: DiffArea) throws -> String {
    var wanted = Set(ids)
    var patch = ""
    for file in files {
        let selected = file.hunks.filter { wanted.contains($0.id) }
        guard !selected.isEmpty else { continue }
        for hunk in selected { wanted.remove(hunk.id) }
        patch += file.headerText + selected.map(\.patchText).joined()
    }
    var missing: [String] = []
    for id in ids where wanted.contains(id) {
        missing.append(id)
        wanted.remove(id)
    }
    guard missing.isEmpty else {
        throw StagingError.unknownHunkIDs(ids: missing, area: area)
    }
    return patch
}

// MARK: - §6 exit class (#0141)

/// A stale or unknown id is a repository-state failure — the state the id
/// referred to no longer exists — guide §6 code 6. Not conflicts (8): a
/// conflicted file's hunks are unlisted, so an id for one lands here too,
/// and the caller's recovery is the same either way: re-list.
extension StagingError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
