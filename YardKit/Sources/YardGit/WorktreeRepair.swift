// WorktreeRepair.swift — reestablish links after a main or linked worktree moved

import Foundation

/// Reestablishes the reverse pointer that links between a main worktree and
/// its linked worktrees — broken whenever either end is moved on disk.
///
/// Wraps `git worktree repair` and parses its `repair: gitdir incorrect: …`
/// report from stderr, which is the only place git says what was touched. The
/// command exits 0 in both cases, so "nothing reported" means nothing needed
/// repairing — never failure. A round would otherwise assert on stdout, which is
/// empty for a successful repair and silently report no links were touched.
public enum WorktreeRepair {

    /// The prefix git prepends to every "I touched this" line on stderr.
    public static let repairReportPrefix = "repair: gitdir incorrect:"

    /// All paths the porcelain report named. Empty when nothing changed — that
    /// is meaningful, not an error. Each entry is the literal string git wrote
    /// after "repair: gitdir incorrect:" on stderr.
    public static func run(
        repositoryPath: String,
        atPaths paths: [String] = [],
        git: GitProcess = GitProcess()
    ) throws -> [String] {
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

    /// Splits the literal "repair: gitdir incorrect:" lines out of a stderr
    /// string. Empty input produces an empty array — that is the "nothing to do"
    /// case, not a failure. Each line's path component is the value git restored.
    public static func parseReport(from stderr: String) -> [String] {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lines = stderr.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map(String.init)

        var repairedPaths: [String] = []
        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard stripped.hasPrefix(repairReportPrefix) else { continue }

            let rest = String(stripped.dropFirst(repairReportPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !rest.isEmpty {
                repairedPaths.append(rest)
            }
        }

        return repairedPaths
    }

    /// Top-level errors produced by `WorktreeRepair.run`. The test suite must be
    /// able to distinguish "the command failed" from "git ran and exited 0 but
    /// reported no repairs".
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

// MARK: - Readability helpers

extension WorktreeRepair {
    /// True when the repair touched no links. Meaningful in itself, but tests
    /// must assert it explicitly so that a "make repair do nothing" mutation is
    /// caught by the post-repair porcelain check, not this assertion.
    public static func hasNoRepairs(_ reports: [String]) -> Bool {
        reports.isEmpty
    }

    /// The first line of the report, or nil. Tests use this to confirm a
    /// specific entry was touched on a single-move scenario — that is the
    /// simplest verification, and the one most likely to look right while the
    /// mutation hides the real behaviour.
    public static func firstReportedPath(_ reports: [String]) -> String? {
        reports.first
    }
}
