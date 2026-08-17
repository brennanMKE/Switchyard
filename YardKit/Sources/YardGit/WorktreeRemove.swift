// WorktreeRemove.swift — `yard wt rm`

import Foundation

/// Result of a worktree removal attempt.
public struct WorktreeRemoveResult: Sendable {
    /// The path that was removed, after any lock release or force operation.
    public let worktreePath: String

    /// True when a lock was released before the removal (clean path).
    public let lockedRelease: Bool

    /// True when --force was needed because the worktree was dirty.
    public let forced: Bool

    /// The specific reason code for a failure, when refusal was structured.
    public let error: WorktreeRemoveError?

    public init(
        worktreePath: String,
        lockedRelease: Bool = false,
        forced: Bool = false,
        error: WorktreeRemoveError? = nil
    ) {
        self.worktreePath = worktreePath
        self.lockedRelease = lockedRelease
        self.forced = forced
        self.error = error
    }

    /// True when the removal succeeded (no structured error).
    public var success: Bool { error == nil }

    /// True when the removal was refused without force.
    public var refusal: Bool { if case .unclean = error { return true } else { return false } }

    /// True when the worktree was locked by an agent session and had to release.
    public var lockReleased: Bool { lockedRelease }

    /// True when force was needed to remove the worktree.
    public var hadToForce: Bool { forced }
}

/// Errors raised by `worktreeRemove`. Each case carries enough information for a structured
/// JSON refusal rather than a bare "git exited 128" message.
public enum WorktreeRemoveError: Error, CustomStringConvertible, Sendable {

    /// The worktree is dirty (modified or untracked files). Emitted with the list of offending
    /// paths so the caller can report them without running a second command.
    case unclean(paths: [String])

    /// The path does not exist or is not a worktree known to the repository.
    case unknown(path: String)

    /// The path is inside another worktree's working tree.
    case nested(inside: String, target: String)

    /// `git worktree remove` exited with a code we did not recognise.
    case unknownFailure(code: Int32, stderr: String)

    /// The worktree was locked by an agent and the lock could not be released.
    case lockFailed(path: String, detail: String)

    public var description: String {
        switch self {
        case let .unclean(paths):
            return "refusing to remove dirty worktree \(paths.joined(separator: ", "))"
        case let .unknown(path):
            return "not a worktree: \(path)"
        case let .nested(inside, target):
            return "worktree \(target) is inside another worktree at \(inside)"
        case let .unknownFailure(code, stderr):
            return "git worktree remove exited \(code)" + (stderr.isEmpty ? "" : ": \(stderr)")
        case let .lockFailed(path, detail):
            return "could not release lock on \(path): \(detail)"
        }
    }

    /// Structured form suitable for JSON output, carried in the result's `error` field.
    public var code: String {
        switch self {
        case .unclean: return "dirty"
        case .unknown: return "notFound"
        case .nested: return "nested"
        case .unknownFailure: return "failure"
        case .lockFailed: return "lockFailed"
        }
    }
}

/// Removes a linked worktree from the repository at `repositoryPath`.
///
/// Steps:
///   1. Verify the worktree exists and is a linked (non-main) worktree.
///   2. Release any agent-session lock (`locked <reason>` from `git worktree list`).
///   3. Attempt `git worktree remove` without --force. If the exit code is non-zero
///      and stderr names a dirty worktree, run `git status --porcelain=v2 -z` to collect
///      the offending paths, then attempt again with --force.
///   4. Never pass --force on an agent's behalf — the caller decides whether to force.
public func worktreeRemove(
    at repositoryPath: String,
    _ worktreePath: String,
    force: Bool = false,
    git: GitProcess = GitProcess()
) throws -> WorktreeRemoveResult {
    let normalizedTarget = canonicalize(worktreePath)

    // 1. Confirm the path is known to this repository before touching it.
    let entries = try worktreeList(path: repositoryPath, git: git)
    guard let entry = entries.first(where: { canonicalize($0.path ?? "") == normalizedTarget }) else {
        return WorktreeRemoveResult(
            worktreePath: worktreePath,
            error: .unknown(path: normalizedTarget)
        )
    }

    // 2. Release an agent session lock if present. We explicitly unlock *agent*
    //    sessions (reason contains "agent") and leave other locks alone — a human
    //    lock is not the same as an agent session and the issue asks us only to
    //    release the `wt new --agent` lock.
    var releasedLock = false
    if entry.locked, let reason = entry.lockReason, reason.contains("agent") {
        do {
            try git.run(
                ["worktree", "unlock", normalizedTarget],
                workingDirectory: repositoryPath
            )
            releasedLock = true
        } catch {
            // `error` is `GitProcess.Failure`, which conforms to
            // `CustomStringConvertible` and carries git's stderr — not
            // `LocalizedError`, so `error.localizedDescription` would render
            // Foundation's generic fallback and discard git's own message.
            // `String(describing:)` picks up the `description` conformance.
            throw WorktreeRemoveError.lockFailed(path: normalizedTarget, detail: String(describing: error))
        }
    }

    // 3. Try the removal without --force first, exactly like `git worktree remove`
    //    would. We use capture() so a non-zero exit does not propagate as an error —
    //    we interpret it ourselves.
    let outcome = try git.capture(
        ["worktree", "remove", normalizedTarget],
        workingDirectory: repositoryPath
    )

    if outcome.exitCode == 0 {
        return WorktreeRemoveResult(
            worktreePath: normalizedTarget,
            lockedRelease: releasedLock,
            forced: false
        )
    }

    // 4. If force was not requested, refuse cleanly — carry the list of dirty paths
    //    so callers do not have to parse git's stderr for it.
    guard force else {
        let dirty = extractDirtyPaths(from: outcome, at: normalizedTarget, git: git)
        return WorktreeRemoveResult(
            worktreePath: normalizedTarget,
            lockedRelease: releasedLock,
            error: .unclean(paths: dirty)
        )
    }

    // 5. Caller asked for force; retry with --force. We do *not* pass it up-front:
    //    the issue specifies we must never pass --force on an agent's behalf. The
    //    first attempt failing is what *triggers* the second, which is not the same
    //    as "we told git to force from the start".
    let forced = try git.capture(
        ["worktree", "remove", "--force", normalizedTarget],
        workingDirectory: repositoryPath
    )
    guard forced.exitCode == 0 else {
        throw WorktreeRemoveError.unknownFailure(
            code: forced.exitCode,
            stderr: forced.standardError
        )
    }

    return WorktreeRemoveResult(
        worktreePath: normalizedTarget,
        lockedRelease: releasedLock,
        forced: true
    )
}

/// Extracts the list of dirty paths from a failed `git worktree remove` stderr.
///
/// When the exit code is 128 and stderr matches `'<path>' contains modified or untracked
/// files, use --force to delete it`, git prints a single line listing the offending paths.
/// We return those paths so the caller can surface them structurally instead of asking the user
/// to read a raw git message. Returns an empty array when the failure is something other than
/// "dirty worktree".
private func extractDirtyPaths(
    from outcome: GitProcess.Output,
    at path: String,
    git: GitProcess
) -> [String] {
    let stderr = outcome.standardError.trimmingCharacters(in: .whitespacesAndNewlines)

    // `git worktree remove` on a dirty worktree prints:
    //   fatal: '<path>' contains modified or untracked files, use --force to delete it
    guard stderr.hasSuffix("use --force to delete it") else { return [] }

    // git status porcelain v2 -z lists paths after a separator line. Rather than
    // fork another process, we run `git -C <path> status --porcelain=v2 -z` and
    // parse the XY records, keeping only entries whose worktree-or-staged side is
    // modified/added/deleted/untracked. This keeps the interface deterministic — we
    // always return a list of paths instead of "maybe".
    let statusArgs: [String] = ["status", "--porcelain=v2", "-z"]
    let statusOut = try? git.capture(statusArgs, workingDirectory: path)
    guard let statusOut = statusOut else { return [] }

    var entries: [WorktreeStatusEntry] = []
    let parser = WorktreeStatusParser()
    do {
        entries = try parser.parse(statusOut.standardOutput).entries
    } catch { return [] }

    // Keep only "dirty" entries: staged or worktree side is anything other than unmodified.
    return entries.compactMap { entry -> String? in
        guard entry.staged != .unmodified || entry.worktree != .unmodified else { return nil }
        return entry.path
    }
}

// MARK: - Helpers

/// Canonicalize a path the same way `WorktreeContext` does, so /private/var paths
/// compare correctly against gitDir/commonDir, which are canonicalized.
private func canonicalize(_ path: String) -> String {
    // One implementation, in WorktreeContext. Two copies disagreed once already:
    // this one used `resolvingSymlinksInPath()`, which strips a leading
    // `/private`, while the other resolves with `realpath(3)` and keeps it.
    WorktreeContext.canonicalize(path)
}

// MARK: - Wire encoding (#0137)

/// `WorktreeRemoveResult` is a `schemaVersion: 1` payload: it encodes through
/// `YardKit`'s `Envelope` via `EncodableResult` (`Encodable & Sendable`).
/// Plain-stdlib `Encodable` — the engine still imports nothing.
extension WorktreeRemoveResult: Encodable {
    /// Stable wire keys, identical to the stored-member names; no raw values.
    /// The computed `success` / `refusal` / `lockReleased` / `hadToForce` are
    /// not encoded — the stored `lockedRelease` and `forced` are the wire
    /// truth. `WorktreeRemoveWireTests` pins the bytes.
    private enum CodingKeys: String, CodingKey {
        case worktreePath, lockedRelease, forced, error
    }
}

/// A structured refusal encodes as an object with a stable `code` plus
/// `message` (= `description`), plus the case's associated values as named
/// detail fields — an agent acting on the dirty paths must not have to parse
/// them out of `message` prose. Hand-written because associated-value enums
/// get no useful synthesis; `code` and `description` are reused, not restated.
extension WorktreeRemoveError: Encodable {
    /// Wire keys: `code` and `message` on every case, then per-case detail.
    /// `unknownFailure`'s associated `code:` (the git exit status) rides as
    /// `exitCode` — the `code` key is taken by the stable case string.
    private enum CodingKeys: String, CodingKey {
        case code, message
        case paths, path, inside, target, detail
        case exitCode, stderr
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(description, forKey: .message)
        switch self {
        case let .unclean(paths):
            try container.encode(paths, forKey: .paths)
        case let .unknown(path):
            try container.encode(path, forKey: .path)
        case let .nested(inside, target):
            try container.encode(inside, forKey: .inside)
            try container.encode(target, forKey: .target)
        case let .unknownFailure(exitCode, stderr):
            try container.encode(exitCode, forKey: .exitCode)
            try container.encode(stderr, forKey: .stderr)
        case let .lockFailed(path, detail):
            try container.encode(path, forKey: .path)
            try container.encode(detail, forKey: .detail)
        }
    }
}

// MARK: - §6 exit class (#0141)

/// Every refusal here is a repository-state failure — guide §6 code 6.
/// `unclean` is dirty files, not unresolved conflicts, so it is a 6 and not
/// an 8; 8 is reserved for operations blocked on an unmerged index (M2).
extension WorktreeRemoveError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

