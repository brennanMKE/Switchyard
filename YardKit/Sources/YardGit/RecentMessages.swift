// RecentMessages.swift — the commit messages the Changes view offers to reuse (#0561)

import Foundation

/// The messages of the commits recently made in this worktree, read from
/// `HEAD`'s reflog (guide §11 decision 45). The reflog, not the log: it
/// still holds a commit that Undo Commit took back or an amend replaced,
/// which is exactly when a message is worth reusing.
public enum RecentMessages {

    /// How many reflog entries `list` reads.
    public static let scannedEntries = 100

    /// At most `limit` full messages, newest first, each once (trailing
    /// whitespace ignored when comparing). Only entries git wrote for a
    /// commit count — `commit:`, `commit (amend):`, `commit (initial):`,
    /// `commit (merge):` — not checkouts, resets, rebases or merges. Empty
    /// on an unborn branch or with no reflog (`git log -g` exits 128 then,
    /// measured).
    public static func list(
        at path: String,
        limit: Int = 10,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> [String] {
        let head = try git.capture(
            ["rev-parse", "--verify", "-q", "HEAD^{commit}"],
            workingDirectory: path, extraEnvironment: extraEnvironment)
        guard head.exitCode == 0 else { return [] }
        let reflog = try git.run(
            ["log", "-g", "-n", "\(scannedEntries)", "--no-show-signature",
             "--format=%gs%x00%B%x1e", "HEAD", "--"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).text
        return parse(reflog, limit: limit)
    }

    /// `list`'s parser: records end in U+001E, the reflog subject and the
    /// message are split by NUL.
    static func parse(_ reflog: String, limit: Int) -> [String] {
        var seen: Set<String> = []
        var messages: [String] = []
        for record in reflog.split(separator: "\u{1E}") {
            guard messages.count < limit else { break }
            let fields = record.drop { $0 == "\n" }.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].hasPrefix("commit:") || fields[0].hasPrefix("commit (") else { continue }
            var message = Substring(fields[1])
            while let last = message.last, last.isWhitespace { message = message.dropLast() }
            guard !message.isEmpty, seen.insert(String(message)).inserted else { continue }
            messages.append(String(message))
        }
        return messages
    }
}
