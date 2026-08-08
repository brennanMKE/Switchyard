// WorktreeSparse.swift — sparse worktree creation, cone mode only (#0128)

import Foundation

/// Structured failures from the sparse steps. Failures of the underlying
/// `worktree add` are carried in the add result, not here.
public enum WorktreeSparseError: Error, Equatable, CustomStringConvertible, Sendable {

    /// Cone mode takes directories; git refused an argument containing
    /// pattern metacharacters (`*?[]\`). Measured:
    /// `fatal: specify directories rather than patterns. …`, exit 128.
    case patternRefused(detail: String)

    /// `git sparse-checkout set` failed some other way.
    case sparseSetFailed(code: Int32, stderr: String)

    /// The final `git checkout` that populates the tree failed.
    case checkoutFailed(code: Int32, stderr: String)

    /// Stable machine-readable code for JSON output.
    public var code: String {
        switch self {
        case .patternRefused: "patternRefused"
        case .sparseSetFailed: "sparseSetFailed"
        case .checkoutFailed: "checkoutFailed"
        }
    }

    public var description: String {
        switch self {
        case let .patternRefused(detail):
            "sparse directories must be directory names, not patterns: \(detail)"
        case let .sparseSetFailed(code, stderr):
            "git sparse-checkout set exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .checkoutFailed(code, stderr):
            "git checkout exited \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Result of a sparse worktree creation.
public struct SparseWorktreeResult: Sendable {

    /// The underlying `worktree add` outcome — path, branch, head, lock. When
    /// `add.error` is non-nil the sparse steps never ran.
    public let add: WorktreeAddResult

    /// The cone directories requested.
    public let directories: [String]

    /// Failure of the sparse-configure or populate step. When non-nil the
    /// worktree exists but its tree is not populated as asked.
    public let sparseError: WorktreeSparseError?

    /// True when the worktree was created, configured, and populated.
    public var success: Bool { add.success && sparseError == nil }

    public init(add: WorktreeAddResult, directories: [String],
                sparseError: WorktreeSparseError? = nil) {
        self.add = add
        self.directories = directories
        self.sparseError = sparseError
    }
}

/// Creates a linked worktree that checks out only the named directories
/// (plus files at the repository root — cone mode semantics).
///
/// The sequence, each step measured on git 2.50.1:
///
/// 1. `git worktree add --no-checkout …` — the worktree exists, `HEAD` is
///    set, nothing is populated. Locking (`agentID`) happens atomically here,
///    exactly as in `worktreeAdd`.
/// 2. `git -C <wt> sparse-checkout set --cone <dirs…>` — git enables
///    `extensions.worktreeConfig` itself and writes `core.sparseCheckout` /
///    `core.sparseCheckoutCone` into the worktree's own `config.worktree`, so
///    sibling worktrees are untouched. Nothing here edits config directly.
/// 3. `git -C <wt> checkout` — populates the tree within the sparse cone.
///
/// Cone mode only, passed explicitly. Non-cone patterns are refused by git in
/// this sequence (`fatal: specify directories rather than patterns.`), which
/// surfaces as `.patternRefused` — and per-file pattern support is a
/// different feature with different performance characteristics, deliberately
/// not exposed.
public func worktreeAddSparse(
    at repositoryPath: String,
    path: String,
    target: WorktreeAddTarget,
    directories: [String],
    agentID: String? = nil,
    git: GitProcess = GitProcess()
) throws -> SparseWorktreeResult {
    let add = try worktreeAdd(
        at: repositoryPath, path: path, target: target,
        agentID: agentID, populate: false, git: git)
    guard add.success else {
        return SparseWorktreeResult(add: add, directories: directories)
    }

    let set = try git.capture(
        ["sparse-checkout", "set", "--cone"] + directories,
        workingDirectory: add.worktreePath)
    guard set.exitCode == 0 else {
        let error: WorktreeSparseError
        if set.standardError.contains("specify directories rather than patterns") {
            error = .patternRefused(
                detail: set.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            error = .sparseSetFailed(code: set.exitCode, stderr: set.standardError)
        }
        return SparseWorktreeResult(add: add, directories: directories, sparseError: error)
    }

    let checkout = try git.capture(["checkout"], workingDirectory: add.worktreePath)
    guard checkout.exitCode == 0 else {
        return SparseWorktreeResult(
            add: add, directories: directories,
            sparseError: .checkoutFailed(
                code: checkout.exitCode, stderr: checkout.standardError))
    }

    return SparseWorktreeResult(add: add, directories: directories)
}
