// WorktreePrune.swift

import Foundation

/// Reports and optionally prunes stale worktree entries.
///
/// Wraps `git worktree prune -v` for the latter and parses porcelain from
/// `git worktree list --porcelain` to report the former. Reporting is the
/// default; pruning requires an explicit `--prune` flag because git cannot tell
/// a moved worktree from a deleted one, and reaping a moved one is not
/// recoverable. See issue #0096 for the full safety finding that shapes this
/// command.
public enum WorktreePrune {

    /// A single worktree to report, with its classification.
    public struct Report: Sendable, Equatable {

        /// The worktree's absolute working-tree path.
        public let path: String

        /// `reportable` if this is a `prunable` entry. `abandonedSession` is set
        /// for an agent-locked worktree whose directory does not exist.
        public enum Reportable: String, CaseIterable, Sendable {
            case prunable
            case abandonedSession
        }

        /// The reason git reported for this worktree. Always non-nil when the
        /// report type is `.prunable`. Nil for an abandoned session — that is a
        /// conclusion drawn by the engine, not a git-reported reason.
        public let type: Reportable

        /// The raw reason from porcelain (`git worktree list` for prunable
        /// entries) or nil. For prunable entries this is git's own wording and
        /// must be reported verbatim — never paraphrased.
        public let reason: String?

        /// The lock reason for an abandoned session, if available. Nil when no
        /// `locked` line is present — which also means not an abandoned session,
        /// because every abandoned worktree must carry one.
        public let lockReason: String?

        /// True when `git prune` will remove this worktree. False for an
        /// abandoned session — those are never removed, only reported. The user
        /// controls whether any pruning occurs via `--prune`.
        public let removable: Bool

        public init(path: String,
                    type: Reportable,
                    reason: String? = nil,
                    lockReason: String? = nil) {
            self.path = path
            self.type = type
            self.reason = reason
            self.lockReason = lockReason
            switch type {
            case .prunable:
                self.removable = true
            case .abandonedSession:
                self.removable = false
            }
        }

        /// Single-line summary of the entry. One line per reaped prunable
        /// worktree during a prune, formatted to match `git prune -v` output.
        public var description: String {
            switch type {
            case .prunable:
                let reason = reason ?? "no reason recorded"
                return "Removing \(path): \(reason)"
            case .abandonedSession:
                let raw = lockReason ?? "(no reason)"
                return "Abandoned session \(path): agent locked (\(raw))"
            }
        }
    }

    // MARK: - Public surface

    /// The prefix every agent lock reason begins with, so a non-agent-locked
    /// worktree is reported as a plain lock rather than an abandoned session.
    public static let agentLockReasonPrefix = "switchyard-agent:"

    /// All worktrees known to the repository at `path` that are either
    /// prunable or abandoned sessions, in the order they appear on porcelain.
    public static func report(from repositoryPath: String, git: GitProcess = GitProcess()) throws -> [Report] {
        let entries = try worktreeList(path: repositoryPath, git: git)
        return report(entries: entries)
    }

    /// All worktrees known to the repository at `path` that are either
    /// prunable or abandoned sessions, in the order they appear on porcelain.
    public static func report(entries: [WorktreeEntry]) -> [Report] {
        let fm = FileManager.default

        return entries.compactMap { entry -> Report? in
            guard let path = entry.path else { return nil }

            if entry.prunable {
                // A prunable worktree's directory may be gone, but git already
                // classified it — report it with its reason and the user can
                // opt into pruning. Even if the directory still exists on disk,
                // it is prunable by git's definition (moved worktrees fall here).
                return Report(path: path, type: .prunable, reason: entry.prunableReason)
            }

            if entry.locked && isAgentLock(reason: entry.lockReason),
               !fm.fileExists(atPath: path) {
                // An abandoned session is a worktree locked by an agent whose
                // directory no longer exists on disk — git will never prune it,
                // the agent's lock is stale, and removing it has to be a human
                // decision or an explicit flag.
                return Report(path: path, type: .abandonedSession, lockReason: entry.lockReason)
            }

            return nil
        }
    }

    /// Runs `git worktree prune -v` against the repository at `path` and
    /// returns its stderr output, with trailing empty lines removed. The prune
    /// operation only removes entries that are `prunable` in git's eyes — never
    /// a locked worktree, which is preserved by design. Abandoned sessions are
    /// reported separately via `report(entries:)` and must never be touched by
    /// prune.
    @discardableResult
    public static func runPrune(repositoryPath: String, git: GitProcess = GitProcess()) throws -> [String] {
        let output = try git.run(
            ["worktree", "prune", "-v"],
            workingDirectory: repositoryPath
        )
        let lines = output.standardError.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var idx = lines.endIndex
        while idx > lines.startIndex, lines[idx - 1].isEmpty { idx = idx - 1 }
        return Array(lines[lines.startIndex..<idx])
    }

    /// Top-level entry point for `yard wt gc`.
    ///
    /// Reports all prunable and abandoned-session worktrees, then — only when
    /// `prune` is true — runs `git worktree prune -v`. Pruning defaults to
    /// `false` because reporting is the safe default: a moved worktree looks
    /// identical to a deleted one in porcelain, and git's prune reaps it.
    public static func gc(
        repositoryPath: String,
        prune: Bool = false,
        git: GitProcess = GitProcess()
    ) throws -> (reports: [Report], pruned: [String]) {
        let reports = try report(from: repositoryPath, git: git)

        if prune {
            let pruned = try runPrune(repositoryPath: repositoryPath, git: git)
            return (reports, pruned)
        } else {
            return (reports, [])
        }
    }

    // MARK: - Filtering

    /// True when the lock reason begins with the agent prefix — that marks it
    /// as belonging to an agent session rather than a user-initiated lock.
    static func isAgentLock(reason: String?) -> Bool {
        guard let reason else { return false }
        return reason.hasPrefix(agentLockReasonPrefix)
    }
}

// MARK: - Readability helpers

extension WorktreePrune.Report {
    /// Groups the reports by type. The engine always emits all of them on a
    /// single `report` call; the caller decides what to surface or act on.
    var isPrunable: Bool { type == .prunable }
    var isAbandonedSession: Bool { type == .abandonedSession }
}

// MARK: - Wire encoding (#0135)

/// String-raw enum: encodes as its raw value, a single JSON string (#0129
/// Decision 5) — here the raw values are the case names themselves.
extension WorktreePrune.Report.Reportable: Encodable {}

/// `WorktreePrune.Report` is a `schemaVersion: 1` payload component:
/// `report(from:)` returns `[Report]`, which rides as a JSON array in
/// `result`. Plain-stdlib `Encodable` — the engine still imports nothing.
extension WorktreePrune.Report: Encodable {
    /// Stable wire keys, identical to the stored-member names; no raw values.
    /// The computed `description` is not encoded (#0129 Decision 7).
    /// `removable` IS stored (derived once in `init`) and rides the wire —
    /// it is the field an agent branches on to know whether `--prune` would
    /// reap the entry.
    private enum CodingKeys: String, CodingKey {
        case path, type, reason, lockReason, removable
    }
}
