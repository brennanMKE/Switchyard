// WorktreeList.swift — porcelain parser for `git worktree list --porcelain -z`

import Foundation

/// A single worktree entry, as reported by `git worktree list --porcelain -z`.
public struct WorktreeEntry: Sendable, Equatable {

    /// Absolute path of the worktree's working tree. `nil` for a bare
    /// repository. May contain newlines; never use the human-readable form of
    /// porcelain to read this.
    public let path: String?

    /// HEAD commit as a full oid string, or nil when detached without a
    /// committish.
    public let head: String?

    /// The symbolic ref `refs/heads/<branch>` if attached, nil for detached.
    public let branch: String?

    /// True when the worktree is locked. The lock reason is surfaced in
    /// `lockReason` — agents encode sessions there (#0021).
    public let locked: Bool

    /// The lock reason, or nil if unlocked or locked without one.
    public let lockReason: String?

    /// True when this is a bare repository with no working tree.
    public let bare: Bool

    /// True when the HEAD is detached (not pointing at a branch).
    public let detached: Bool

    /// True when `git gc` would remove this worktree.
    public let prunable: Bool

    /// The reason string attached to `prunable`, or nil when not prunable.
    public let prunableReason: String?

    /// True if this entry is the primary (main) worktree of the repository.
    public let isMainWorktree: Bool

    public init(path: String?,
                head: String? = nil,
                branch: String? = nil,
                locked: Bool = false,
                lockReason: String? = nil,
                bare: Bool = false,
                detached: Bool = false,
                prunable: Bool = false,
                prunableReason: String? = nil,
                isMainWorktree: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.locked = locked
        self.lockReason = lockReason
        self.bare = bare
        self.detached = detached
        self.prunable = prunable
        self.prunableReason = prunableReason
        self.isMainWorktree = isMainWorktree
    }

    // `prunableReason` is deliberately included: it is not derived from
    // `prunable` (which is a bool) — it is git's own free-text explanation
    // of *why* the worktree is prunable ("gitdir file points to
    // non-existent location", "stale lockfile", ...), and two entries can
    // share `prunable == true` while disagreeing on the reason (#0312).
    public static func == (lhs: WorktreeEntry, rhs: WorktreeEntry) -> Bool {
        lhs.path == rhs.path &&
            lhs.head == rhs.head &&
            lhs.branch == rhs.branch &&
            lhs.locked == rhs.locked &&
            lhs.lockReason == rhs.lockReason &&
            lhs.bare == rhs.bare &&
            lhs.detached == rhs.detached &&
            lhs.prunable == rhs.prunable &&
            lhs.prunableReason == rhs.prunableReason &&
            lhs.isMainWorktree == rhs.isMainWorktree
    }
}

/// Returns every worktree known to the repository at `path`, parsed from the
/// NUL-terminated porcelain form.
public func worktreeList(path: String, git: GitProcess = GitProcess()) throws -> [WorktreeEntry] {
    let output = try git.capture(
        ["worktree", "list", "--porcelain", "-z"],
        workingDirectory: path
    )
    guard output.exitCode == 0 else {
        throw WorktreeListError.couldNotList(detail: output.standardError)
    }
    return parsePorcelain(output.standardOutput, path: path)
}

/// Async twin of `worktreeList(path:git:)` (#0344), for callers already on
/// Swift concurrency's cooperative pool: the `git worktree list` subprocess
/// is awaited on the non-blocking `GitProcess` path, so the pool thread is
/// released while git runs. Same arguments, same parse, same error.
public func worktreeList(path: String, git: GitProcess = GitProcess()) async throws -> [WorktreeEntry] {
    let output = try await git.capture(
        ["worktree", "list", "--porcelain", "-z"],
        workingDirectory: path
    )
    guard output.exitCode == 0 else {
        throw WorktreeListError.couldNotList(detail: output.standardError)
    }
    return parsePorcelain(output.standardOutput, path: path)
}

/// Internal parser used by `worktreeList` and exercised directly by tests.
internal func parsePorcelain(_ data: Data, path: String) -> [WorktreeEntry] {
    let bytes = Array(data)

    var records: [[Data]] = []     // fields of each completed record
    var currentFields: [Data] = []

    var start = bytes.startIndex
    for i in bytes.indices {
        if bytes[i] == 0x00 {
            let range = start..<i

            if !bytes[range].isEmpty {
                currentFields.append(Data(bytes[range]))
            } else {
                // Empty field → record boundary. Push and reset.
                records.append(currentFields)
                currentFields = []
            }

            start = bytes.index(after: i)
        }
    }

    // Drain any trailing fields without a record boundary at EOF.
    if !currentFields.isEmpty {
        records.append(currentFields)
    }

    return records.enumerated().compactMap { index, fields in
        var path: String? = nil
        var head: String? = nil
        var branch: String? = nil
        var locked = false, bare = false, detached = false, prunable = false
        var lockReason: String? = nil
        var prunableReason: String? = nil

        for field in fields {
            let line = String(decoding: field, as: UTF8.self)

            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                if ref.hasPrefix("refs/heads/") {
                    branch = String(ref.dropFirst("refs/heads/".count))
                } else if !ref.isEmpty {
                    branch = ref
                }
            } else if line == "locked" {
                locked = true
            } else if let reason: String = line.removePrefix("locked ") {
                locked = true
                lockReason = reason.isEmpty ? nil : reason
            } else if line == "bare" {
                bare = true
            } else if line == "detached" {
                detached = true
            } else if line == "prunable" {
                prunable = true
            } else if let reason: String = line.removePrefix("prunable ") {
                prunable = true
                prunableReason = reason.isEmpty ? nil : reason
            }
        }

        // A record is usable if it declares a path or is bare.
        guard (path != nil) || bare else { return nil }

        // First usable record is the main worktree.
        let isMain = index == 0 && (path != nil || bare)
        return WorktreeEntry(
            path: path, head: head, branch: branch,
            locked: locked, lockReason: lockReason, bare: bare,
            detached: detached, prunable: prunable, prunableReason: prunableReason,
            isMainWorktree: isMain
        )
    }
}

extension String {
    /// Remove a prefix if present; returns the remainder, or `nil` when the
    /// string does not begin with that prefix.
    internal func removePrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Top-level container for `WorktreeList` errors and related utilities.
public enum WorktreeListError: Swift.Error, CustomStringConvertible, Sendable {
    case couldNotList(detail: String)

    public var description: String {
        switch self {
        case let .couldNotList(detail):
            return "could not list worktrees: \(detail)"
        }
    }
}

// MARK: - Wire encoding (#0130)

/// `WorktreeEntry` is a `schemaVersion: 1` payload: it encodes through
/// `YardKit`'s `Envelope` via `EncodableResult` (`Encodable & Sendable`).
/// Plain-stdlib `Encodable` — the engine still imports nothing.
extension WorktreeEntry: Encodable {
    /// The stable wire keys. Identical to the member names on purpose: the
    /// enum exists so a member rename becomes a compile error here instead of
    /// a silent wire change. No case carries a raw value — the case name IS
    /// the wire key, and `WorktreeIdentityWireTests` pins the encoded bytes.
    private enum CodingKeys: String, CodingKey {
        case path, head, branch
        case locked, lockReason
        case bare, detached
        case prunable, prunableReason
        case isMainWorktree
    }
}

// MARK: - §6 exit class (#0146)

/// An unlistable worktree set is a repository-state failure — guide §6
/// code 6.
extension WorktreeListError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
