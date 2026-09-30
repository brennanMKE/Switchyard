// HistorySearch.swift — which of a set of commits touched a path, or changed some text (#0522)

import Foundation

/// Which of a given set of commits changed a path containing some text, or
/// changed how often some text occurs in the diff — `git log` path limiting
/// and pickaxe (`-S`), over exactly the commits the caller names (guide §11
/// decision 40). The History pane passes the commits it has loaded, so the
/// search costs what those commits cost, not what the repository's whole
/// history costs.
///
/// Read-only: no journal entry, no ref written.
public enum HistorySearch {

    /// What the query is matched against.
    public enum Kind: String, Sendable, CaseIterable {
        /// A changed file's path contains the query, case-insensitively.
        case path
        /// The number of occurrences of the query, case-insensitively,
        /// differs between the commit and its parent: the text was added or
        /// removed (`git log -S -i`), renames detected.
        case content
    }

    /// `query` as the body of a `:(icase)` pathspec that matches any path
    /// containing it. The default (non-glob) pathspec lets `*` match `/`, so
    /// `*q*` matches `q` in a directory name as well as a file name — measured.
    /// `*`, `?`, `[`, `]` and `\` are escaped with a backslash, so they match
    /// themselves: unescaped, `*[ird]*` matched every commit in the measuring
    /// repository and `*\[ird\]*` only the one touching `we[ird].txt`.
    static func pathspec(for query: String) -> String {
        var escaped = ""
        for character in query {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return ":(icase)*\(escaped)*"
    }

    /// The argument vector `run` executes; the candidates arrive on stdin.
    /// `--no-walk=unsorted --stdin` limits the log to exactly those commits,
    /// in the order given; `--no-merges` keeps to commits that made a change
    /// themselves (a merge's changes are its branch's commits, which match on
    /// their own); `--no-show-signature` keeps `log.showSignature` from
    /// prepending prose to `%H`. `log.follow` needs no flag: with it set,
    /// the wildcard pathspec below lists the same commits — measured.
    static func arguments(kind: Kind, query: String) -> [String] {
        let common = ["log", "--no-walk=unsorted", "--stdin", "--no-merges",
                      "--no-show-signature", "--format=%H"]
        switch kind {
        case .path:
            return common + ["--", pathspec(for: query)]
        case .content:
            // `-M`: a renamed file is not text added and removed. With
            // `diff.renames=false` and no `-M`, the commit that renamed a
            // file matched every line in it — measured.
            return common + ["-M", "-i", "-S\(query)"]
        }
    }

    /// The oids in `candidates` that match `query`, in `candidates`' order.
    /// A blank query (after trimming whitespace) or no candidates is `[]`
    /// without running `git`.
    ///
    /// Cancelling the calling task terminates `git` (`GitProcess`'s async
    /// path).
    public static func run(
        kind: Kind, query: String, candidates: [String], at path: String,
        git: GitProcess = GitProcess()
    ) async throws -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return [] }
        let input = Data((candidates.joined(separator: "\n") + "\n").utf8)
        let output = try await git.run(
            arguments(kind: kind, query: trimmed), workingDirectory: path, standardInput: input)
        return output.lines.filter { !$0.isEmpty }
    }
}
