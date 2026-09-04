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

    /// A requested hunk belongs to a combined (`diff --cc`) block — the
    /// shape `git diff` prints for an unmerged path during a conflict
    /// (#0350). `git apply` refuses combined patches outright (measured:
    /// exit 128, "No valid patches in input"), so the hunk cannot be
    /// staged — or unstaged — by id at all; the refusal is raised here,
    /// before git runs, so the caller sees this typed error rather than
    /// git's raw exit 128. The way out is the way git means it: resolve
    /// the conflict, then stage the resolved content.
    case combinedHunkNotStageable(path: String)

    public var description: String {
        switch self {
        case let .unknownHunkIDs(ids, area):
            "unknown hunk id(s) in the \(area.rawValue) listing: "
                + ids.joined(separator: ", ")
                + " — stale (the hunk changed since it was listed) or never valid"
        case let .combinedHunkNotStageable(path):
            "hunk(s) of \(path) belong to a combined diff (`diff --cc`) — a "
                + "conflicted file is not stageable by hunk; resolve the "
                + "conflict, then stage the resolved content"
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
/// Conflicted files stage nothing, and the refusal is typed (#0350): git
/// prints unmerged paths as combined diffs (`diff --cc`, `@@@` hunks),
/// which #0342's parser now lists as their own files — with stable ids —
/// but `git apply` refuses combined patches outright (measured: exit 128,
/// "No valid patches in input"). `selectPatch` therefore refuses a
/// requested combined block **before** git is invoked, throwing
/// `StagingError.combinedHunkNotStageable(path:)` — the error is ours,
/// not git's, and its detail says what to do instead: resolve the
/// conflict, then stage the resolved content. The all-or-none contract
/// covers a mixed selection the same way: one combined id in the request
/// stages nothing at all. Other files stage normally while the index
/// holds unmerged entries (measured).
///
/// An empty `ids` array is a no-op: nothing to resolve, and `git apply` on
/// an empty patch is an error (`No valid patches in input`, exit 128), so
/// git is not invoked at all.
///
/// **Writes exactly one journal entry per call (#0212)**, via
/// `JournalCheckpoint.around`, so `undo` works after staging directly. This
/// is the entry point everything outside this file must call.
public func stageHunks(
    ids: [String],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    try JournalCheckpoint.around(operation: "stage", at: path, git: git) { git in
        try stageHunksWithoutCheckpoint(ids: ids, at: path, git: git)
    }
}

/// The non-checkpointing primitive. Writes no journal entry of its own —
/// `commitHunks` below calls this, not `stageHunks`, so composing staging
/// with a commit inside one `JournalCheckpoint.around` produces exactly one
/// entry rather than two (#0212, the trap #0209 was scoped around).
func stageHunksWithoutCheckpoint(
    ids: [String],
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    let files = try listHunks(at: path, area: .unstaged, git: git)
    let patch = try selectPatch(ids: ids, from: files, area: .unstaged)
    guard !patch.isEmpty else { return }
    try applyPatchToIndex(patch, at: path, git: git)
}

/// The one `git apply --cached` invocation everything that writes a patch to
/// the index goes through — #0140-era staging's apply, reused verbatim by
/// `stagePatch` so there is exactly one place in the codebase that runs it.
func applyPatchToIndex(_ patch: String, at path: String, git: GitProcess) throws {
    try git.run(["apply", "--cached"],
                workingDirectory: path,
                standardInput: Data(patch.utf8))
}

/// Applies an arbitrary patch text to the index: the index gains exactly the
/// patch's changes, through **one** `git apply --cached` invocation — the same
/// apply path `stageHunks` uses, which is atomic (measured under `stageHunks`:
/// a two-file patch whose second file fails leaves the first unstaged), so a
/// patch that cannot apply changes nothing.
///
/// This is #0055 round 3's amend-application primitive: the review sheet's
/// amend decision hands the human's edited patch here, and the amended index
/// becomes the reviewed state the reply refers to. A patch whose context no
/// longer matches the index — a stale patch, or one written against a
/// different preimage — fails here with git's own message ("error: patch
/// failed: …", "does not apply") as `GitProcess.Failure.exited`; the caller
/// surfaces that as a typed outcome to the human, never as a silent success.
/// Note the matching is against the **index**: a patch whose changes are
/// already staged fails ("does not apply") the same way a stale one does —
/// the sheet's amend editor is free text exactly so the human can write the
/// delta they mean rather than resend what is already there.
///
/// Writes exactly one journal entry per call (#0212), via
/// `JournalCheckpoint.around`, so `undo` works after an amend's application
/// the same way it does after staging. An empty patch is a true no-op —
/// nothing to apply, nothing to undo, no journal entry, and no `git apply`
/// invocation (git refuses an empty patch as an error, and "the human sent
/// no patch" is not a failure).
public func stagePatch(
    _ patch: String,
    at path: String,
    git: GitProcess = GitProcess()
) throws {
    guard !patch.isEmpty else { return }
    try JournalCheckpoint.around(operation: "stage", at: path, git: git) { git in
        try applyPatchToIndex(patch, at: path, git: git)
    }
}

/// Builds the patch text for the requested hunk ids: for every file owning
/// at least one requested hunk, its `headerText` followed by the requested
/// hunks' `patchText` in **listing order** — hunks inside one file patch must
/// stay in file order whatever order the caller passed the ids in. Duplicate
/// ids in the request select the hunk once. Throws `unknownHunkIDs` (in
/// caller order, deduplicated) when any id matches nothing, or
/// `combinedHunkNotStageable(path:)` when a requested id belongs to a
/// combined (`diff --cc`) block — the shape `git diff` prints for an
/// unmerged path during a conflict (#0350). That refusal fires before any
/// patch text is assembled, so it precedes `git apply` and the error is
/// ours, not git's; a combined file with none of its hunks requested is
/// skipped untouched, and ordinary files keep staging normally beside a
/// conflict. Returns "" for an empty request.
func selectPatch(ids: [String], from files: [FileDiff], area: DiffArea) throws -> String {
    var wanted = Set(ids)
    var patch = ""
    for file in files {
        let selected = file.hunks.filter { wanted.contains($0.id) }
        guard !selected.isEmpty else { continue }
        // A combined (`diff --cc`) block — what `git diff` prints for an
        // unmerged path during a conflict — is refused here, before any
        // `git apply` can run (#0350): apply rejects combined patches
        // outright (measured exit 128, "No valid patches in input"), so
        // the refusal is moved ahead of it and made typed. Only a
        // *requested* combined block refuses; the all-or-none contract
        // then covers a mixed selection — one combined id in the request
        // stages nothing at all.
        if file.headerText.hasPrefix("diff --cc ") {
            throw StagingError.combinedHunkNotStageable(path: file.path)
        }
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
/// referred to no longer exists — guide §6 code 6. The combined-hunk
/// refusal (#0350) shares the class: the unresolved conflict *is* the
/// repository's state, and the class was already code 6 back when the
/// refusal surfaced as git's own exit 128; this issue changed the error's
/// shape, not its class.
extension StagingError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

// MARK: - Commit a named hunk set (#0208)

/// Why `commitHunks` refused rather than committing.
///
/// `stageHunks` is `git apply --cached`, which is additive: it stages the
/// requested patch and touches nothing else already in the index. Composing
/// it with `CommitCreate.run` naively would therefore silently commit
/// whatever else the caller had staged — the opposite of what asking for
/// specific hunks means. #0208's decision is to refuse rather than guess:
/// it matches `WorktreeDisturbance`, the worktree gate, and `CrossToolGuard`,
/// all of which refuse rather than warn (guide §7).
public enum CommitHunksError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The index already held staged changes when hunk ids were given.
    /// `paths` is `git diff --cached --name-only`, read **before**
    /// `stageHunks` runs — reading it after would always fire, since staging
    /// the named hunks always adds something to the index.
    case indexNotClean(paths: [String])

    public var description: String {
        switch self {
        case let .indexNotClean(paths):
            "refusing to commit named hunks: the index already holds staged changes in "
                + paths.joined(separator: ", ")
                + " — commit or unstage that work first, then retry with only the named hunks"
        }
    }
}

/// Commits exactly the hunks named by `ids`, refusing when the index already
/// holds unrelated staged work (#0208 Decision — refuse, and say what is
/// staged).
///
/// The clean-index check (`git diff --cached --name-only`) runs **before**
/// `stageHunks`, not after: `stageHunks` always adds the requested patch to
/// the index, so a check made afterward would always find something staged
/// and always refuse. `stageHunks` itself resolves every id against a fresh
/// listing and throws `StagingError.unknownHunkIDs` before applying anything
/// (#0040) — this function does not weaken that: an unknown or stale id
/// still stages nothing and commits nothing.
public func commitHunks(
    ids: [String],
    message: String,
    signing: CommitCreate.Signing = .config,
    trailers: [Trailer] = [],
    at path: String,
    git: GitProcess = GitProcess(),
    extraEnvironment: [String: String] = [:]
) throws -> CommitCreate {
    let staged = try git.run(
        ["diff", "--cached", "--name-only"],
        workingDirectory: path,
        extraEnvironment: extraEnvironment
    ).lines
    guard staged.isEmpty else {
        throw CommitHunksError.indexNotClean(paths: staged)
    }
    return try JournalCheckpoint.around(
        operation: "commit", at: path, git: git) { git in
        try stageHunksWithoutCheckpoint(ids: ids, at: path, git: git)
        return try CommitCreate.run(
            message: message,
            signing: signing,
            trailers: trailers,
            in: path,
            git: git,
            extraEnvironment: extraEnvironment
        )
    }
}

/// Guide §6 code 6: an unrelated already-staged path is a repository-state
/// refusal, the same class `StagingError` above carries.
extension CommitHunksError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
