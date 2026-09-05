// ResolveApply.swift — the engine apply half of the resolve exchange (#0057)
//
// What the engine does when a human stages one conflicted path's resolution:
// write the chosen content to the working file and stage the path — one path
// per action, individually undoable through #0027's checkpoint machinery.
// Nothing stages until this is called: the pending request, the store, and
// the serving body are all read-only over the repository; this file is the
// only writer in the resolve flow, and it runs only on a human action.

import Foundation

/// What to write and stage for one conflicted path. The engine-level
/// vocabulary behind the wire's `PathChoice` (YardKit): the wire type maps
/// onto this one in `YardCommands`, where both sides of the boundary are
/// visible — YardGit links nothing, so the wire vocabulary cannot live here.
public enum ResolveResolution: Sendable, Equatable {

    /// Write ours' stage-2 blob content to the working file and stage the
    /// path. Also the apply form of the wire's `renameTakeOurs`: on a rename
    /// conflict the porcelain record carrying ours' content IS ours' new
    /// path, so taking ours' path+content means staging exactly this record.
    case useOurs

    /// Write theirs' stage-3 blob content to the working file and stage the
    /// path. Also the apply form of `renameTakeTheirs`, symmetrically.
    case useTheirs

    /// Write the human's edited text to the working file and stage the path.
    /// What they saved is what stages — no reinterpretation.
    case editedContent(String)

    /// Keep the deletion (delete/modify): remove the working file when it
    /// exists, then stage the path — `git add` records the deletion and
    /// clears the unmerged entries. This is also how a rename group's other
    /// records resolve: the old path (`DD`, both deleted) and the rejected
    /// side's new path (`UA`/`AU`) are each "keep the deletion" cards.
    case keepDeletion

    /// Keep the surviving side (delete/modify): write the surviving stage's
    /// blob content to the working file — ours' when it exists, theirs'
    /// otherwise — and stage the path. Writing the blob (rather than staging
    /// whatever the worktree happens to hold) makes the outcome deterministic
    /// regardless of what the merge checked out.
    case keepModification

    /// Take ours' path and content on a rename conflict. At the per-record
    /// granularity this file applies, this stages the record that carries
    /// ours' content — the same write as `useOurs`, kept as its own case so
    /// the record the human's choice produced stays distinguishable in the
    /// journal and in any future audit of how a rename group was resolved.
    case renameTakeOurs

    /// Take theirs' path and content on a rename conflict — symmetric with
    /// `renameTakeOurs`.
    case renameTakeTheirs
}

/// Why an apply refused rather than staging something wrong. All three are
/// repository-state refusals: the index no longer holds what the resolution
/// refers to.
public enum ResolveApplyError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The path has no unmerged entries — already resolved by an earlier
    /// card action, or never conflicted. Refused by name rather than
    /// guessed at: staging an arbitrary path under a resolve banner would
    /// let a stale double-click stage something the human never saw.
    case pathNotConflicted(path: String)

    /// The side the resolution names has no stage entry for this path —
    /// e.g. `useOurs` on a `UA` record, which carries only theirs.
    case stageAbsent(path: String, side: String)

    /// Neither side has a stage entry, so no content survives to keep —
    /// `keepModification` on a `DD` record, whose resolution is
    /// `keepDeletion`.
    case bothStagesAbsent(path: String)

    public var description: String {
        switch self {
        case let .pathNotConflicted(path):
            "\(path) has no unmerged entries — it is not a conflicted path in this index"
        case let .stageAbsent(path, side):
            "\(path) has no \(side) stage entry to apply"
        case let .bothStagesAbsent(path):
            "\(path) has neither an ours nor a theirs stage entry — there is no modification to keep"
        }
    }
}

public enum ResolveApply {

    /// Applies one path's resolution: content written from a stage blob (via
    /// `git cat-file blob <stage-oid>`, the #0017 `ConflictedFile` oids) or
    /// from the human's edited text lands in the working file, then the path
    /// is staged with one `git add` — clearing the unmerged entries exactly
    /// the way git means a conflict resolved. The conflicted-path lookup,
    /// the blob read, and the write all happen INSIDE the checkpoint body,
    /// so the pre-apply state the journal captures is the state the apply
    /// actually saw.
    ///
    /// - Parameters:
    ///   - resolution: what to write and stage.
    ///   - path: the conflicted path, repository-relative — exactly the string
    ///     `conflictedFiles` reports. A path that is not currently conflicted
    ///     throws `ResolveApplyError.pathNotConflicted` before anything is
    ///     touched; the lookup is also what keeps an arbitrary path from
    ///     being staged under a resolve banner.
    ///   - repoPath: the worktree's top level (or a bare repository's root) —
    ///     `path` resolves against it.
    ///   - git: the process runner; a checkpoint-scoped one is handed to the
    ///     body so every subprocess exports the entry id (#0221).
    ///
    /// Writes exactly one journal entry per call, via
    /// `JournalCheckpoint.around` — the same discipline `stageHunks` follows
    /// (#0212), so `undo` steps over whole per-path resolutions, never
    /// halves of one.
    public static func apply(
        resolution: ResolveResolution,
        path: String,
        at repoPath: String,
        git: GitProcess = GitProcess()
    ) throws {
        try JournalCheckpoint.around(operation: "resolve", at: repoPath, git: git) { git in
            try applyWithoutCheckpoint(resolution: resolution, path: path, at: repoPath, git: git)
        }
    }

    /// The non-checkpointing primitive, for the same reason
    /// `stageHunksWithoutCheckpoint` exists: a caller composing several
    /// per-path applies into one user-level action writes ONE entry by
    /// wrapping them in a single `around` itself.
    static func applyWithoutCheckpoint(
        resolution: ResolveResolution,
        path: String,
        at repoPath: String,
        git: GitProcess
    ) throws {
        let files = try conflictedFiles(at: repoPath, git: git)
        guard let entry = files.first(where: { $0.path == path }) else {
            throw ResolveApplyError.pathNotConflicted(path: path)
        }

        switch resolution {
        case .useOurs, .renameTakeOurs:
            guard let stage = entry.ours else {
                throw ResolveApplyError.stageAbsent(path: path, side: "ours")
            }
            try writeAndStage(readBlob(oid: stage.oid, at: repoPath, git: git), path: path, at: repoPath, git: git)

        case .useTheirs, .renameTakeTheirs:
            guard let stage = entry.theirs else {
                throw ResolveApplyError.stageAbsent(path: path, side: "theirs")
            }
            try writeAndStage(readBlob(oid: stage.oid, at: repoPath, git: git), path: path, at: repoPath, git: git)

        case .editedContent(let text):
            try writeAndStage(Data(text.utf8), path: path, at: repoPath, git: git)

        case .keepDeletion:
            let fileURL = URL(fileURLWithPath: repoPath).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try git.run(["add", "--", path], workingDirectory: repoPath)

        case .keepModification:
            // The surviving side: ours when it exists (`UD` — deleted by
            // them), theirs' otherwise (`DU` — deleted by us).
            guard let stage = entry.ours ?? entry.theirs else {
                throw ResolveApplyError.bothStagesAbsent(path: path)
            }
            try writeAndStage(readBlob(oid: stage.oid, at: repoPath, git: git), path: path, at: repoPath, git: git)
        }
    }

    /// Reads one object's raw bytes. The resolve surface's only object read:
    /// the serving body uses it for the per-stage contents that ride to the
    /// UI, and `apply` uses it for the chosen side's content. Raw bytes, not
    /// text — a blob this returns may not be UTF-8, and the caller decides
    /// how to decode.
    public static func readBlob(oid: String, at path: String, git: GitProcess = GitProcess()) throws -> Data {
        try git.run(["cat-file", "blob", oid], workingDirectory: path).standardOutput
    }

    /// Writes `data` over the working file (creating parent directories for
    /// a conflicted path inside a subdirectory) and stages it — the one
    /// `git add` that turns the unmerged entries into a resolved stage 0.
    private static func writeAndStage(_ data: Data, path: String, at repoPath: String, git: GitProcess) throws {
        let fileURL = URL(fileURLWithPath: repoPath).appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try git.run(["add", "--", path], workingDirectory: repoPath)
    }
}

// MARK: - §6 exit class

/// Every refusal here is a repository-state refusal — the index no longer
/// holds what the resolution refers to — guide §6 code 6, the same class
/// `StagingError` carries.
extension ResolveApplyError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
