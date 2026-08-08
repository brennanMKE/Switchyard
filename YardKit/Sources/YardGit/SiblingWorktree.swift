// SiblingWorktree.swift — which worktree holds a branch (#0109)

import Foundation

/// The worktree that has a branch checked out, found via
/// `git worktree list --porcelain -z` (through `worktreeList`).
public struct SiblingWorktree: Sendable, Equatable {

    /// Absolute, canonicalized path of the worktree holding the branch.
    public let path: String

    /// Short branch name, without `refs/heads/`.
    public let branch: String

    /// HEAD oid of that worktree, when porcelain reported one.
    public let head: String?

    /// True when the holder is the repository's primary worktree.
    public let isMainWorktree: Bool

    /// True when the holder is the same worktree the query ran from —
    /// false when the branch is held by a sibling.
    public let isCurrent: Bool

    public init(path: String, branch: String, head: String?,
                isMainWorktree: Bool, isCurrent: Bool) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMainWorktree = isMainWorktree
        self.isCurrent = isCurrent
    }
}

/// Reports which worktree has `branch` checked out, or nil when none does.
///
/// `branch` may be a short name (`feature`) or a full ref
/// (`refs/heads/feature`). A detached worktree holds no branch and is never
/// reported. Errors from `worktreeList` and `WorktreeContext.resolve`
/// propagate; there is no new error type.
public func siblingWorktree(
    holding branch: String,
    at path: String,
    git: GitProcess = GitProcess()
) throws -> SiblingWorktree? {
    let name = branch.hasPrefix("refs/heads/")
        ? String(branch.dropFirst("refs/heads/".count))
        : branch
    let entries = try worktreeList(path: path, git: git)
    guard let match = entries.first(where: { !$0.detached && $0.branch == name }),
          let matchPath = match.path else {
        return nil
    }
    let holder = WorktreeContext.canonicalize(matchPath)
    let current = try WorktreeContext.resolve(path: path, git: git).topLevel
    return SiblingWorktree(
        path: holder,
        branch: name,
        head: match.head,
        isMainWorktree: match.isMainWorktree,
        isCurrent: current == holder
    )
}

// MARK: - Wire encoding (#0130)

/// `SiblingWorktree` is a `schemaVersion: 1` payload: it encodes through
/// `YardKit`'s `Envelope` via `EncodableResult` (`Encodable & Sendable`).
/// Plain-stdlib `Encodable` — the engine still imports nothing.
extension SiblingWorktree: Encodable {
    /// Stable wire keys, identical to the member names; no raw values. The
    /// enum is rename-safety; `WorktreeIdentityWireTests` pins the bytes.
    private enum CodingKeys: String, CodingKey {
        case path, branch, head, isMainWorktree, isCurrent
    }
}
