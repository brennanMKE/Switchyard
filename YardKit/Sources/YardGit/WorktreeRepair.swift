// WorktreeRepair.swift — reestablish links after a main or linked worktree moved

import Foundation

/// Reestablishes the reverse pointer that links between a main worktree and
/// its linked worktrees — broken whenever either end is moved on disk.
///
/// Wraps `git worktree repair` and parses its report lines from stderr, which
/// is the only place git says what was touched. The command exits 0 in both
/// cases, so "nothing reported" means nothing needed repairing — never failure.
public enum WorktreeRepair {

    /// The prefix git prepends to every "I touched this" report line on stderr.
    /// A line beginning `repair: ` is a success report; a line beginning
    /// `error: ` is a failure and the exit code will be non-zero.
    public static let repairReportPrefix = "repair: "

    /// All paths the porcelain report named. Empty when nothing changed — that
    /// is meaningful, not an error. Each entry preserves the literal string
    /// git wrote after `repair: <reason>: ` on stderr.
    public static func run(
        repositoryPath: String,
        atPaths paths: [String] = [],
        git: GitProcess = GitProcess()
    ) throws -> [Repaired] {
        var args: [String] = ["worktree", "repair"]
        if !paths.isEmpty {
            args += paths
        }

        let output = try git.capture(
            args,
            workingDirectory: repositoryPath
        )

        guard output.exitCode == 0 else {
            throw Error.notRepaired(
                detail: output.standardError,
                exitCode: Int(output.exitCode)
            )
        }

        return parseReport(from: output.standardError)
    }

    /// Parses the porcelain report lines from `git worktree repair` stderr. A line is included only when
    /// it begins with the `repairReportPrefix`. Empty input produces an empty array — that is the "nothing
    /// to do" case, not a failure.
    /// One repaired link, as git reported it.
    ///
    /// git's `report_repair` (builtin/worktree.c) writes `repair: <reason>: <path>`
    /// to stderr. There are exactly three reasons — `gitdir incorrect`,
    /// `.git file broken`, and `gitdir unreadable` — and which one appears
    /// changes what `path` means: `gitdir incorrect` names the administrative
    /// `worktrees/<name>/gitdir` file, while `.git file broken` names the linked
    /// worktree itself. Callers that care can branch on `reason`; callers that
    /// just want to say what moved can use `path`.
    public struct Repaired: Sendable, Equatable {
        public let reason: String
        public let path: String

        public init(reason: String, path: String) {
            self.reason = reason
            self.path = path
        }
    }

    public static func parseReport(from stderr: String) -> [Repaired] {
        var repaired: [Repaired] = []
        for line in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard stripped.hasPrefix(repairReportPrefix) else { continue }

            let rest = String(stripped.dropFirst(repairReportPrefix.count))
            // Split on the FIRST ": " only -- a path may contain one, a reason
            // never does.
            guard let sep = rest.range(of: ": ") else { continue }
            let reason = String(rest[rest.startIndex..<sep.lowerBound])
            let path = String(rest[sep.upperBound...])
            guard !reason.isEmpty, !path.isEmpty else { continue }

            repaired.append(Repaired(reason: reason, path: path))
        }
        return repaired
    }

/// Top-level errors produced by `WorktreeRepair.run`. Tests must distinguish "the command failed"
    /// from "git ran and exited 0 but reported no repairs."
    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case notRepaired(detail: String, exitCode: Int)

        public var description: String {
            switch self {
            case let .notRepaired(detail, exitCode):
                return "git worktree repair exited \(exitCode)"
                    + (detail.isEmpty ? "" : ": \(detail)")
            }
        }
    }
}

// MARK: - Wire encoding (#0135)

/// `WorktreeRepair.Repaired` is a `schemaVersion: 1` payload component:
/// `run(repositoryPath:atPaths:)` returns `[Repaired]`, which rides as a JSON
/// array in `result`. Plain-stdlib `Encodable` — the engine still imports
/// nothing. (`WorktreeRepair.Error` is thrown, not a payload member, and gets
/// no conformance — error-envelope mapping is an M3 registration concern.)
extension WorktreeRepair.Repaired: Encodable {
    /// Stable wire keys, identical to the member names; no raw values.
    private enum CodingKeys: String, CodingKey {
        case reason, path
    }
}
