// Blame.swift — structured, range-limited blame (#0018)

import Foundation

/// One line of a file, attributed to the commit that last touched it.
///
/// Backed by `git blame --porcelain`, which emits full commit headers once
/// per commit and refers back to them for every later line of the same
/// commit — the parser carries that cache so each `BlameLine` is complete.
public struct BlameLine: Sendable, Equatable {

    /// The oid git reports for a line whose current content is not yet
    /// committed — 40 zeros.
    public static let uncommittedOID = String(repeating: "0", count: 40)

    /// Full object id of the commit that last touched this line, exactly as
    /// git printed it. `Self.uncommittedOID` when the line's content comes
    /// from the worktree or index rather than any commit.
    public let oid: String

    /// 1-based line number in the file as it is now.
    public let finalLine: Int

    /// 1-based line number this line had in `originalPath` as of `oid` —
    /// not the current file. Lines above it added since then shift the two
    /// apart.
    public let originalLine: Int

    /// The path the line lived at in `oid`. Differs from the blamed path
    /// when git followed the content across a rename.
    public let originalPath: String

    /// `author` header value. `"Not Committed Yet"` for uncommitted lines.
    public let author: String

    /// `author-mail` header value with the surrounding angle brackets
    /// removed, e.g. `"fixture@example.invalid"`.
    public let authorEmail: String

    /// `author-time`: seconds since the Unix epoch.
    public let authorTime: Int

    /// `author-tz`, e.g. `"-0700"`.
    public let authorTimeZone: String

    /// First line of the commit message. For uncommitted lines git
    /// fabricates `"Version of <file> from <file>"`.
    public let summary: String

    /// True when git marked the commit a boundary — by default, a root
    /// commit, whose lines it can only attribute "no earlier than here".
    public let isBoundary: Bool

    /// The line's current content, without the tab `--porcelain` prefixes.
    public let content: String

    /// True when the line's content is not in any commit — the worktree or
    /// index version differs from HEAD at this line.
    public var isUncommitted: Bool { oid == Self.uncommittedOID }

    public init(oid: String, finalLine: Int, originalLine: Int,
                originalPath: String, author: String, authorEmail: String,
                authorTime: Int, authorTimeZone: String, summary: String,
                isBoundary: Bool, content: String) {
        self.oid = oid
        self.finalLine = finalLine
        self.originalLine = originalLine
        self.originalPath = originalPath
        self.author = author
        self.authorEmail = authorEmail
        self.authorTime = authorTime
        self.authorTimeZone = authorTimeZone
        self.summary = summary
        self.isBoundary = isBoundary
        self.content = content
    }
}

/// Parses `git blame --porcelain` output.
///
/// Pure function on text — no `Process` construction, no filesystem access.
/// Porcelain prints each commit's header fields (`author`, `summary`,
/// `filename`, …) only for the first line attributed to it; every later
/// entry is just `<oid> <origLine> <finalLine>` plus the content line, so
/// the parser keeps a per-commit cache and a malformed or unresolvable
/// entry throws rather than producing a half-filled line.
public struct BlameParser {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A `filename` git C-quoted despite `core.quotepath=false` — it
        /// contains a double quote or a control character. Refused
        /// explicitly rather than mis-parsed.
        case quotedPath(String)
        /// A line where an entry header `<oid> <origLine> <finalLine>` was
        /// expected but did not parse.
        case malformedEntryHeader(String)
        /// An entry referred to a commit whose header fields were never
        /// emitted — porcelain output out of order or truncated.
        case missingCommitHeader(oid: String)
        /// Output ended inside an entry, before its tab-prefixed content
        /// line.
        case truncatedEntry(oid: String)

        public var description: String {
            switch self {
            case let .quotedPath(line):
                "unsupported quoted path in blame output: \(line)"
            case let .malformedEntryHeader(line):
                "malformed blame entry header: \(line)"
            case let .missingCommitHeader(oid):
                "blame entry for \(oid) has no commit header"
            case let .truncatedEntry(oid):
                "blame output ended inside an entry for \(oid)"
            }
        }
    }

    /// What porcelain's per-commit header lines carry. Filled in over the
    /// course of one commit's first entry, then reused from the cache.
    struct CommitInfo {
        var author: String?
        var authorEmail: String?
        var authorTime: Int?
        var authorTimeZone: String?
        var summary: String?
        var path: String?
        var isBoundary = false
    }

    public init() {}

    public func parse(_ text: String) throws -> [BlameLine] {
        var lines: [BlameLine] = []
        var commits: [String: CommitInfo] = [:]
        // The entry whose header lines are being collected, until its
        // tab-prefixed content line closes it.
        var entry: (oid: String, originalLine: Int, finalLine: Int)?

        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if rawLines.last == "" { rawLines = rawLines.dropLast() }

        for rawLine in rawLines {
            let line = String(rawLine)

            if let open = entry {
                if line.hasPrefix("\t") {
                    let info = commits[open.oid]
                    guard let info,
                          let author = info.author,
                          let authorEmail = info.authorEmail,
                          let authorTime = info.authorTime,
                          let authorTimeZone = info.authorTimeZone,
                          let summary = info.summary,
                          let path = info.path else {
                        throw Failure.missingCommitHeader(oid: open.oid)
                    }
                    lines.append(BlameLine(
                        oid: open.oid,
                        finalLine: open.finalLine,
                        originalLine: open.originalLine,
                        originalPath: path,
                        author: author,
                        authorEmail: authorEmail,
                        authorTime: authorTime,
                        authorTimeZone: authorTimeZone,
                        summary: summary,
                        isBoundary: info.isBoundary,
                        content: String(line.dropFirst())))
                    entry = nil
                } else {
                    try Self.applyHeaderLine(line, to: &commits[open.oid, default: CommitInfo()])
                }
                continue
            }

            let parsed = try Self.parseEntryStart(line)
            if commits[parsed.oid] == nil { commits[parsed.oid] = CommitInfo() }
            entry = parsed
        }

        if let open = entry { throw Failure.truncatedEntry(oid: open.oid) }
        return lines
    }

    /// Parses `<40-hex oid> <origLine> <finalLine>[ <groupLineCount>]`. The
    /// fourth token appears only on the first line of a group and adds
    /// nothing per-line, so it is validated and dropped.
    static func parseEntryStart(_ line: String) throws
        -> (oid: String, originalLine: Int, finalLine: Int) {
        let tokens = line.split(separator: " ")
        guard tokens.count == 3 || tokens.count == 4,
              tokens[0].count == 40,
              tokens[0].allSatisfy({ $0.isHexDigit }),
              let originalLine = Int(tokens[1]),
              let finalLine = Int(tokens[2]),
              tokens.count == 3 || Int(tokens[3]) != nil else {
            throw Failure.malformedEntryHeader(line)
        }
        return (String(tokens[0]), originalLine, finalLine)
    }

    /// Applies one header line to the entry's commit. Unknown keys are
    /// ignored on purpose — porcelain is allowed to grow fields.
    static func applyHeaderLine(_ line: String, to info: inout CommitInfo) throws {
        func value(after prefix: String) -> String {
            String(line.dropFirst(prefix.count))
        }
        if line.hasPrefix("author ") {
            info.author = value(after: "author ")
        } else if line.hasPrefix("author-mail ") {
            var mail = value(after: "author-mail ")
            if mail.hasPrefix("<") { mail.removeFirst() }
            if mail.hasSuffix(">") { mail.removeLast() }
            info.authorEmail = mail
        } else if line.hasPrefix("author-time ") {
            info.authorTime = Int(value(after: "author-time "))
        } else if line.hasPrefix("author-tz ") {
            info.authorTimeZone = value(after: "author-tz ")
        } else if line.hasPrefix("summary ") {
            info.summary = value(after: "summary ")
        } else if line == "boundary" {
            info.isBoundary = true
        } else if line.hasPrefix("filename ") {
            let path = value(after: "filename ")
            if path.hasPrefix("\"") { throw Failure.quotedPath(line) }
            info.path = path
        }
        // committer*, previous, and anything new: deliberately skipped.
    }
}

/// Blames one file in the repository at `path`, worktree content included,
/// returning one entry per blamed line in final-line order.
///
/// `lines` bounds the *computation*, not just the output: git stops walking
/// history for everything outside the range (measured 0.68s → 0.37s on a
/// 7,881-line file with 731 blamed commits), and a range past the end of
/// the file is an error from git (`fatal: file X has only N lines`), which
/// surfaces as `GitProcess.Failure.exited`. Line numbers are 1-based;
/// `-c core.quotepath=false` keeps non-ASCII filenames unquoted, matching
/// `listHunks`.
public func blameFile(
    at path: String,
    file: String,
    lines: ClosedRange<Int>? = nil,
    git: GitProcess = GitProcess()
) throws -> [BlameLine] {
    var arguments = ["-c", "core.quotepath=false", "blame", "--porcelain"]
    if let lines {
        arguments += ["-L", "\(lines.lowerBound),\(lines.upperBound)"]
    }
    arguments += ["--", file]
    let output = try git.run(arguments, workingDirectory: path)
    return try BlameParser().parse(output.text)
}
