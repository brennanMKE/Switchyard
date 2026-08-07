// WorktreeStatus.swift

import Foundation

/// A per-file snapshot from `git status --porcelain=v2 -z`.
///
/// Each field is the index/staged state and the worktree (disk) state of a single path.
/// Paths with spaces are preserved — `--porcelain=v2` emits one NUL-terminated record per
/// file and a fixed number of leading space-separated tokens before the path.
public struct WorktreeStatusEntry {
    /// Path relative to the repository root (one of many names git uses for it).
    var path: String = ""

    /// The state of the index side — what would be committed next.
    var staged: State = .unmodified

    /// The state of the worktree — what is on disk.
    var worktree: State = .unmodified

    /// One of the two porcelain-character meanings for a single field.
    enum State: String, CaseIterable {
        case unmodified = "."
        case added = "A"
        case deleted = "D"
        case modified = "M"
        case untracked = "?"
        case ignored = "!"
        case conflicted = "u"

        /// Path is tracked in the index (`A`-`M`) — not `untracked`.
        init?(char: Character) {
            switch char {
            case ".": self = .unmodified
            case "A", "+": self = .added
            case "D", "-": self = .deleted
            case "M": self = .modified
            default: return nil
            }
        }

        /// One of: `untracked`, `ignored`, or `conflicted`.
        static func special(char: Character) -> State {
            switch char {
            case "?": return .untracked
            case "!": return .ignored
            case "u": return .conflicted
            default:  return .unmodified
            }
        }

        /// Char-parsed fallback for the worktree side (Y): handles `?`, `!`, and `u`.
        init?(ychar: Character) {
            switch ychar {
            case "?": self = .untracked
            case "!": self = .ignored
            case "u": self = .conflicted
            default:  return nil
            }
        }
    }
}

/// The full status of a worktree. Value type, no printing, no side effects.
public struct WorktreeStatus {
    let entries: [WorktreeStatusEntry]

    init(entries: [WorktreeStatusEntry]) {
        self.entries = entries
    }
}

extension WorktreeStatus: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: WorktreeStatusEntry...) {
        self.entries = elements
    }
}

// MARK: - Parser

/// Parses NUL-terminated porcelain v2 bytes into a `WorktreeStatus`.
///
/// Pure function on data — no `Process` construction, no filesystem access. The
/// thin wrapper in the `YardGit` module that runs it through `git` is kept in
/// its own call site.
public struct WorktreeStatusParser {

    /// Number of leading tokens before the path, keyed on record type.
    private static let fieldCount: [String: Int] = [
        "1": 7,   // XY sub mH mI mW hH hI — 9 tokens total, path at index 8
        "2": 9,   // XY sub m1 m2 m3 h1 h2 h3
        "u": 9,   // XY sub m1 m2 m3 h1 h2 h3 — unmerged/conflict variant
        "?": 0,   // bare "?" token
        "!": 0,   // bare "!" token — ignored records (need --ignored)
    ]

    func parse(_ data: Data) throws -> WorktreeStatus {
        guard let text = String(data: data, encoding: .utf8) else {
            return WorktreeStatus(entries: [])
        }

        var entries: [WorktreeStatusEntry] = []
        let records = text.split(separator: "\0").filter { !$0.isEmpty }

        for record in records {
            let spaceIndex = record.firstIndex(of: " ") ?? record.endIndex
            let leading = String(record[record.startIndex..<spaceIndex])

            guard let expectedFields = Self.fieldCount[leading] else { continue }
            // drop the leading token itself
            let fieldsBeforePath = expectedFields + 1

            guard record.split(separator: " ", omittingEmptySubsequences: false).count >= fieldsBeforePath else {
                continue
            }

            let allTokens = record.split(separator: " ", omittingEmptySubsequences: false)
            guard allTokens.count >= fieldsBeforePath else { continue }

            let path = String(allTokens[fieldsBeforePath...].joined(separator: " "))
            guard !path.isEmpty else { continue }

            var entry = WorktreeStatusEntry(path: path)

            if expectedFields == 0 {
                // `? path` and `! path` carry no XY field — the leading token IS
                // the status, and allTokens[1] is the path itself.
                entry.staged = .unmodified
                entry.worktree = WorktreeStatusEntry.State.special(char: leading.first ?? ".")
            } else {
                // `1`, `2` and `u` all carry XY as the second token.
                let statusStr = String(allTokens[1])
                let staged: WorktreeStatusEntry.State =
                    WorktreeStatusEntry.State(char: statusStr.first ?? ".") ?? .unmodified
                let workChar: WorktreeStatusEntry.State =
                    statusStr.dropFirst().first.map {
                        WorktreeStatusEntry.State(char: $0) ?? .unmodified
                    } ?? .unmodified
                entry.staged = staged
                entry.worktree = workChar

                // Conflict is reported in X (staged): the file has two `u` entries in the index.
                // For conflict records (`u`) that also carry "AA" or similar, the worktree side
                // can be "." (unmerged file never written to disk). Marking staged as .conflicted
                // reflects the data model: "there is a conflict here".
                // Conflict is signalled by the LEADING token being `u`, never by
                // the XY field — on a `u` record XY is e.g. "AA".
                if leading == "u" {
                    entry.staged = WorktreeStatusEntry.State.special(char: "u")
                }
            }

            entries.append(entry)
        }

        return WorktreeStatus(entries: entries)
    }
}

/// Runs `git status --porcelain=v2 -z` against a repository and parses the result.
///
/// `includeIgnored` controls whether ignored files are reported via `--ignored`.
public func gitStatus(
    at repositoryPath: String,
    includeIgnored: Bool = false,
    git: GitProcess = GitProcess()
) throws -> WorktreeStatus {
    var args: [String] = ["status", "--porcelain=v2", "-z"]
    if includeIgnored { args.append("--ignored") }

    let output = try git.run(
        args,
        workingDirectory: repositoryPath
    )

    return try WorktreeStatusParser().parse(output.standardOutput)
}
