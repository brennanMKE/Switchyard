// FileHistory.swift — the commits that changed one file, following renames (#0514)

import Foundation

/// The commits that changed one file, newest first, following the file
/// across renames — `git log --follow` (guide §11 decision 39).
///
/// Read-only: no journal entry, no ref written.
public enum FileHistory {

    /// One commit that changed the file.
    public struct Entry: Sendable, Equatable {
        /// Full object id.
        public let oid: String
        /// `%an`.
        public let author: String
        /// `%at`: seconds since the Unix epoch.
        public let authorTime: Int
        /// `%s`: the first line of the message.
        public let subject: String
        /// `--name-status`'s letter without its score: `M`, `A`, `D`, `R`,
        /// `C` or `T`.
        public let status: String
        /// The file's path in this commit — after a rename, the new one;
        /// for a deletion, the path it was deleted from.
        public let path: String
        /// For a rename or a copy, the path before it; `nil` otherwise.
        public let previousPath: String?

        /// True when this commit deleted the file: there is nothing to blame
        /// at it.
        public var isDeletion: Bool { status == "D" }

        public init(oid: String, author: String, authorTime: Int, subject: String,
                    status: String, path: String, previousPath: String?) {
            self.oid = oid
            self.author = author
            self.authorTime = authorTime
            self.subject = subject
            self.status = status
            self.path = path
            self.previousPath = previousPath
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A record that is not `<oid>SOH<author>SOH<time>SOH<subject>`
        /// followed by a `--name-status` entry.
        case malformedRecord(String)

        public var description: String {
            switch self {
            case let .malformedRecord(record):
                "malformed file history record: \(record)"
            }
        }
    }

    /// The argument vector `run` executes. `--follow` takes exactly one
    /// path. `-z` keeps every path raw (no C-quoting, whatever
    /// `core.quotepath` says); `--no-show-signature` keeps
    /// `log.showSignature` from prepending prose to the format;
    /// `--encoding=UTF-8` pins `%an`/`%s` against `i18n.logOutputEncoding`.
    static func arguments(file: String, revision: String) -> [String] {
        ["log", "--follow", "--no-show-signature", "--encoding=UTF-8",
         "--format=%H%x01%an%x01%at%x01%s", "--name-status", "-z",
         revision, "--", file]
    }

    /// The commits reachable from `revision` that changed `file`, newest
    /// first, following renames. Merges are not listed (`--follow` shows
    /// none; measured on git/git). A file no commit touches is `[]`.
    ///
    /// Cancelling the calling task terminates `git` (`GitProcess`'s async
    /// path).
    public static func run(
        path: String, file: String, revision: String = "HEAD",
        git: GitProcess = GitProcess()
    ) async throws -> [Entry] {
        let output = try await git.run(arguments(file: file, revision: revision), workingDirectory: path)
        return try parse(output.text)
    }

    /// Parses `-z` output: each record is the format line, a NUL, then
    /// `\n<status>` NUL `<path>` NUL — two paths for `R` and `C`.
    static func parse(_ text: String) throws -> [Entry] {
        var tokens = text.unicodeScalars
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map { String(Substring($0)) }[...]
        if tokens.last?.isEmpty == true { tokens = tokens.dropLast() }

        var entries: [Entry] = []
        while let header = tokens.popFirst() {
            let fields = header.split(separator: "\u{01}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  fields[0].count == 40, fields[0].allSatisfy(\.isHexDigit),
                  let time = Int(fields[2]),
                  let statusToken = tokens.popFirst(), statusToken.hasPrefix("\n"),
                  let letter = statusToken.dropFirst().first,
                  let first = tokens.popFirst() else {
                throw Failure.malformedRecord(header)
            }
            let status = String(letter)
            var path = first
            var previousPath: String?
            if status == "R" || status == "C" {
                guard let second = tokens.popFirst() else { throw Failure.malformedRecord(header) }
                previousPath = first
                path = second
            }
            entries.append(Entry(
                oid: String(fields[0]), author: String(fields[1]), authorTime: time,
                subject: String(fields[3]), status: status, path: path, previousPath: previousPath))
        }
        return entries
    }
}

// MARK: - §6 exit class

/// A record `git log` printed that does not parse is a repository-state
/// failure — guide §6 code 6, as `BlameParser.Failure` is.
extension FileHistory.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
