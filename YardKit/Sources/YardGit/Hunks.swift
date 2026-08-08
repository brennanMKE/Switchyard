// Hunks.swift — per-file diffs split into hunks with stable, content-derived ids (#0016)

import CryptoKit
import Foundation

/// Which diff a hunk listing describes.
public enum DiffArea: String, Sendable, CaseIterable {
    /// Index vs worktree — `git diff`.
    case unstaged
    /// HEAD vs index — `git diff --cached`. Works on an unborn branch too;
    /// git diffs the index against the empty tree and exits 0.
    case staged
}

/// One hunk of one file's diff, with a stable content-derived id.
///
/// The id is the first 12 hex characters of SHA-256 over the file path and
/// the hunk's body lines — the `@@` header line is deliberately excluded,
/// because its line numbers shift when an earlier hunk in the same file is
/// staged while the change itself is untouched. Staging a hunk therefore
/// leaves every other hunk's id unchanged, and the staged listing reports
/// the just-staged hunk under the id it had while unstaged. Any edit to the
/// hunk's own lines (including its context lines) produces a different id,
/// which is what makes a stale id detectable: it no longer appears in a
/// fresh listing, and a future stage-by-id must refuse it rather than guess.
public struct Hunk: Sendable, Equatable {

    /// Stable id: 12 lowercase hex characters, plus `-N` (N ≥ 2) when the
    /// same file contains N hunks with identical bodies.
    public let id: String

    /// Path relative to the repository root, as the file's diff reports it.
    public let path: String

    /// Old-side start line from the `@@` header. 0 for a newly added file.
    public let oldStart: Int
    /// Old-side line count. An omitted count in the header means 1.
    public let oldCount: Int
    /// New-side start line from the `@@` header.
    public let newStart: Int
    /// New-side line count. An omitted count in the header means 1.
    public let newCount: Int

    /// The full `@@ -a,b +c,d @@ …` line, exactly as git printed it.
    public let header: String

    /// Body lines, each with its leading marker — ` `, `-`, `+`, or `\`
    /// (the `\ No newline at end of file` marker), exactly as git printed
    /// them.
    public let body: [String]

    public init(id: String, path: String,
                oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                header: String, body: [String]) {
        self.id = id
        self.path = path
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.body = body
    }

    /// The hunk as patch text: the header line, the body lines, and a
    /// trailing newline. Prepending the owning `FileDiff.headerText` yields
    /// input `git apply --cached` accepts byte-for-byte.
    public var patchText: String {
        ([header] + body).joined(separator: "\n") + "\n"
    }
}

/// One file's part of a diff: its hunks, or the binary / mode-only facts
/// when there are none. Binary changes and mode-only changes are represented
/// with an empty `hunks` array, never silently dropped.
public struct FileDiff: Sendable, Equatable {

    /// Path relative to the repository root. Taken from the `+++ b/…` line
    /// (or `--- a/…` for a deletion); for binary and mode-only files, which
    /// have neither, derived from the `diff --git a/P b/P` line.
    public let path: String

    /// From an `old mode` or `deleted file mode` header line. Nil when the
    /// mode did not change and the file was not deleted.
    public let oldMode: String?

    /// From a `new mode` or `new file mode` header line. Nil when the mode
    /// did not change and the file is not new.
    public let newMode: String?

    /// True when git printed `Binary files … differ` (or a binary patch)
    /// instead of hunks.
    public let isBinary: Bool

    /// The raw header lines — `diff --git` through the last line before the
    /// first `@@` — joined with newlines, trailing newline included.
    public let headerText: String

    /// Empty for binary and mode-only changes.
    public let hunks: [Hunk]

    public init(path: String, oldMode: String?, newMode: String?,
                isBinary: Bool, headerText: String, hunks: [Hunk]) {
        self.path = path
        self.oldMode = oldMode
        self.newMode = newMode
        self.isBinary = isBinary
        self.headerText = headerText
        self.hunks = hunks
    }
}

/// Parses `git diff` patch output into per-file hunks.
///
/// Pure function on text — no `Process` construction, no filesystem access.
/// Expects the flags `listHunks(at:area:git:)` passes: no color, no external
/// diff, no rename detection (so the two sides of `diff --git` are always
/// the same path), default `a/`/`b/` prefixes, and `core.quotepath=false`.
public struct HunkParser {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A path git C-quoted despite `core.quotepath=false` — it contains
        /// a double quote or a control character. Refused explicitly rather
        /// than mis-parsed.
        case quotedPath(String)
        /// A `diff --git a/P b/P` line whose two sides do not match.
        case malformedFileHeader(String)
        /// An `@@` line that does not parse as `@@ -a[,b] +c[,d] @@ …`.
        case malformedHunkHeader(String)

        public var description: String {
            switch self {
            case let .quotedPath(line):
                "unsupported quoted path in diff header: \(line)"
            case let .malformedFileHeader(line):
                "malformed diff file header: \(line)"
            case let .malformedHunkHeader(line):
                "malformed hunk header: \(line)"
            }
        }
    }

    public init() {}

    public func parse(_ text: String) throws -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileBuilder?
        var hunk: HunkBuilder?

        func closeHunk() {
            if let done = hunk { file?.hunks.append(done) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let done = file { files.append(done.build()) }
            file = nil
        }

        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)

            if line.hasPrefix("diff --git ") {
                closeFile()
                file = FileBuilder(path: try Self.pathFromDiffGitLine(line),
                                   headerLines: [line])
                continue
            }
            guard file != nil else { continue }  // preamble; git emits none

            if let open = hunk {
                if open.wantsMoreBody(marker: line.first) {
                    hunk?.body.append(line)
                    continue
                }
                closeHunk()
            }

            if line.hasPrefix("@@ ") {
                hunk = try HunkBuilder(header: line)
            } else if line.hasPrefix("old mode ") {
                file?.oldMode = String(line.dropFirst("old mode ".count))
                file?.headerLines.append(line)
            } else if line.hasPrefix("new mode ") {
                file?.newMode = String(line.dropFirst("new mode ".count))
                file?.headerLines.append(line)
            } else if line.hasPrefix("deleted file mode ") {
                file?.oldMode = String(line.dropFirst("deleted file mode ".count))
                file?.headerLines.append(line)
            } else if line.hasPrefix("new file mode ") {
                file?.newMode = String(line.dropFirst("new file mode ".count))
                file?.headerLines.append(line)
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                file?.isBinary = true
                file?.headerLines.append(line)
            } else if line.hasPrefix("--- ") {
                if let path = try Self.path(fromMarkerLine: line, prefix: "--- a/") {
                    file?.path = path
                }
                file?.headerLines.append(line)
            } else if line.hasPrefix("+++ ") {
                if let path = try Self.path(fromMarkerLine: line, prefix: "+++ b/") {
                    file?.path = path
                }
                file?.headerLines.append(line)
            } else if !line.isEmpty {
                // index lines, similarity scores, and anything else git adds.
                file?.headerLines.append(line)
            }
        }
        closeFile()
        return files
    }

    // MARK: - Ids

    /// First 12 hex characters of SHA-256 over the path and the body lines.
    /// The `@@` header is excluded on purpose — see `Hunk.id`.
    static func hunkID(path: String, body: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(path.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(body.joined(separator: "\n").utf8))
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12)
            .lowercased()
    }

    // MARK: - Header parsing

    /// Path from `diff --git a/P b/P`. Rename detection is off, so the two
    /// sides are always the same path and its length is unambiguous even
    /// when it contains spaces: strip `diff --git a/`, and the path is the
    /// first half of the remainder around ` b/`.
    static func pathFromDiffGitLine(_ line: String) throws -> String {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") { throw Failure.quotedPath(line) }
        guard rest.hasPrefix("a/") else { throw Failure.malformedFileHeader(line) }
        let both = String(rest.dropFirst(2))          // "P b/P"
        // both.count = P.count + " b/".count + P.count
        let pathCount = (both.count - 3) / 2
        guard pathCount > 0, (both.count - 3) % 2 == 0 else {
            throw Failure.malformedFileHeader(line)
        }
        let path = String(both.prefix(pathCount))
        guard both == path + " b/" + path else {
            throw Failure.malformedFileHeader(line)
        }
        return path
    }

    /// Path from a `--- a/P` or `+++ b/P` line, nil for `/dev/null`. Git
    /// appends a tab after a path that contains a space; strip it.
    static func path(fromMarkerLine line: String, prefix: String) throws -> String? {
        let body = String(line.dropFirst(4))
        if body == "/dev/null" { return nil }
        if body.hasPrefix("\"") { throw Failure.quotedPath(line) }
        guard line.hasPrefix(prefix) else { throw Failure.malformedFileHeader(line) }
        var path = String(line.dropFirst(prefix.count))
        if path.hasSuffix("\t") { path.removeLast() }
        return path
    }

    // MARK: - Builders

    struct FileBuilder {
        var path: String
        var headerLines: [String]
        var oldMode: String?
        var newMode: String?
        var isBinary = false
        var hunks: [HunkBuilder] = []

        func build() -> FileDiff {
            var seen: [String: Int] = [:]
            let built = hunks.map { hunk -> Hunk in
                let digest = HunkParser.hunkID(path: path, body: hunk.body)
                let occurrence = (seen[digest] ?? 0) + 1
                seen[digest] = occurrence
                return Hunk(
                    id: occurrence == 1 ? digest : "\(digest)-\(occurrence)",
                    path: path,
                    oldStart: hunk.oldStart, oldCount: hunk.oldCount,
                    newStart: hunk.newStart, newCount: hunk.newCount,
                    header: hunk.header, body: hunk.body)
            }
            return FileDiff(path: path, oldMode: oldMode, newMode: newMode,
                            isBinary: isBinary,
                            headerText: headerLines.joined(separator: "\n") + "\n",
                            hunks: built)
        }
    }

    struct HunkBuilder {
        let header: String
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        var body: [String] = [] {
            didSet {
                guard let added = body.last, let marker = added.first else { return }
                switch marker {
                case " ": oldRemaining -= 1; newRemaining -= 1
                case "-": oldRemaining -= 1
                case "+": newRemaining -= 1
                default: break                   // "\" counts on neither side
                }
            }
        }
        private var oldRemaining: Int
        private var newRemaining: Int

        /// Body membership is decided by the header's line counts, not by
        /// line prefixes alone: an added line reading `++ x` prints as
        /// `+++ x`, which prefix-dispatch would swallow as a file header.
        /// After both counts are consumed, only a trailing `\ No newline`
        /// marker still belongs to the hunk.
        func wantsMoreBody(marker: Character?) -> Bool {
            oldRemaining > 0 || newRemaining > 0 || marker == "\\"
        }

        /// Parses `@@ -a[,b] +c[,d] @@ …`. An omitted count means 1.
        init(header: String) throws {
            func range(_ token: Substring) throws -> (Int, Int) {
                let parts = token.split(separator: ",", omittingEmptySubsequences: false)
                guard let start = Int(parts[0]),
                      parts.count <= 2,
                      let count = parts.count == 2 ? Int(parts[1]) : 1 else {
                    throw Failure.malformedHunkHeader(header)
                }
                return (start, count)
            }
            let tokens = header.split(separator: " ")
            guard tokens.count >= 4, tokens[0] == "@@", tokens[3].hasPrefix("@@"),
                  tokens[1].hasPrefix("-"), tokens[2].hasPrefix("+") else {
                throw Failure.malformedHunkHeader(header)
            }
            self.header = header
            (oldStart, oldCount) = try range(tokens[1].dropFirst())
            (newStart, newCount) = try range(tokens[2].dropFirst())
            oldRemaining = oldCount
            newRemaining = newCount
        }
    }
}

/// Lists the hunks of every changed file in the repository at `path`, for
/// one diff area. Empty when that diff is empty.
///
/// The flags pin git's output against user config: `--no-color`,
/// `--no-ext-diff` and `--no-textconv` (drivers would replace or fabricate
/// patch text), `--no-renames` (a rename would put two different paths on
/// the `diff --git` line), `--default-prefix` (overrides `diff.noprefix`
/// and `diff.mnemonicprefix`), `--unified=3` (overrides `diff.context`),
/// and `core.quotepath=false` so non-ASCII paths print raw.
public func listHunks(
    at path: String,
    area: DiffArea,
    git: GitProcess = GitProcess()
) throws -> [FileDiff] {
    var arguments = ["-c", "core.quotepath=false", "diff"]
    if area == .staged { arguments.append("--cached") }
    arguments += ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
                  "--default-prefix", "--unified=3"]
    let output = try git.run(arguments, workingDirectory: path)
    return try HunkParser().parse(output.text)
}
