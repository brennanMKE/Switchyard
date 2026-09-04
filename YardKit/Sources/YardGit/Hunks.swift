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
    /// For a combined (`@@@`) hunk: the **first parent** column's range;
    /// the remaining parent columns ride only in the verbatim `header`.
    public let oldStart: Int
    /// Old-side line count. An omitted count in the header means 1. For a
    /// combined (`@@@`) hunk: the first parent column's count.
    public let oldCount: Int
    /// New-side start line from the `@@` header. For a combined (`@@@`)
    /// hunk: the result column's range.
    public let newStart: Int
    /// New-side line count. An omitted count in the header means 1. For a
    /// combined (`@@@`) hunk: the result column's count.
    public let newCount: Int

    /// The full `@@ -a,b +c,d @@ …` line -- or, for a combined diff, the
    /// full `@@@ -a,b -c,d +e,f @@@ …` line -- exactly as git printed it.
    /// Combined hunks keep every column verbatim here; the single-column
    /// members above carry only the first parent column and the result
    /// column, and reading the rest is the pane's job.
    public let header: String

    /// Body lines, each with its leading marker -- ` `, `-`, `+`, or `\`
    /// (the `\ No newline at end of file` marker), exactly as git printed
    /// them. For a combined hunk each line keeps its raw two-character
    /// (one per parent) prefix verbatim, e.g. `-- old`, ` -theirs`,
    /// `++resolved` -- no mangled or dropped lines (#0342).
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
    /// input `git apply --cached` accepts byte-for-byte for an ordinary
    /// `@@` hunk. A combined `@@@` hunk also reconstructs byte-for-byte,
    /// but `git apply` refuses combined patches outright (measured, exit
    /// 128, "No valid patches in input") -- which is what keeps a
    /// conflicted file's content unstitchable even though it now lists.
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
    /// have neither, derived from the `diff --git a/P b/P` line. A combined
    /// block names its path on the `diff --cc P` line itself -- no `a/`
    /// or `b/` prefixes (measured) -- and its `+++ b/…` line confirms it.
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
/// Expects the flags `listHunks(at:area:git:)` and `commitDiff` pass: no
/// color, no external diff, no rename detection (so the two sides of
/// `diff --git` are always the same path), default `a/`/`b/` prefixes, and
/// `core.quotepath=false`.
///
/// Combined diffs parse too (#0342): a `diff --cc` block becomes its own
/// `FileDiff`, whose hunks carry verbatim `@@@` headers and verbatim
/// two-column bodies — no mangling, no silently dropped lines. Reading the
/// per-parent columns is the pane's job.
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
            if line.hasPrefix("diff --cc ") {
                // A combined diff -- the `--cc` output `commitDiff` requests
                // for every commit (#0342), and the block `git diff` prints
                // for an unmerged path during a conflict. Both parse now:
                // the `@@@` hunks below are stored with verbatim headers
                // and verbatim two-column bodies, and the per-parent
                // columns are the pane's job to read. The open file is
                // still closed first so none of this block's lines
                // (`--- a/…`, `@@@ …`, `++<<<<<<<`) are mis-attributed to
                // a neighbouring file. Measured: git prints all `diff
                // --cc` blocks ahead of every `diff --git` block, but
                // correctness here must not depend on that ordering.
                closeFile()
                file = FileBuilder(path: try Self.pathFromDiffCCLine(line),
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

            if line.hasPrefix("@@@ ") {
                hunk = try HunkBuilder(combinedHeader: line)
            } else if line.hasPrefix("@@ ") {
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
            } else if line.hasPrefix("* Unmerged path ") {
                // `git diff --cached` prints this at the unmerged path's
                // sorted position, so it can land between two file blocks.
                // Appended to headerText it poisons the reconstructed patch:
                // measured, `git apply` refuses it with "patch with only
                // garbage". It belongs to no file; drop it.
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

    /// Path from `diff --cc P`. Combined diffs print the single path with
    /// no `a/`/`b/` prefixes (measured), and a path containing a space is
    /// simply the rest of the line (`diff --cc my file.txt`). Rename
    /// detection is off, so no two-path form is produced.
    static func pathFromDiffCCLine(_ line: String) throws -> String {
        let rest = String(line.dropFirst("diff --cc ".count))
        if rest.hasPrefix("\"") { throw Failure.quotedPath(line) }
        var path = rest
        if path.hasSuffix("\t") { path.removeLast() }
        guard !path.isEmpty else { throw Failure.malformedFileHeader(line) }
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
                guard let added = body.last else { return }
                if isCombined {
                    consumeCombined(added)
                } else {
                    consumePlain(added)
                }
            }
        }
        /// Line budgets still unconsumed, one entry per side the header
        /// counts: old and new for an ordinary `@@` hunk; one per parent,
        /// in header order, and then the result side, for a combined
        /// `@@@` hunk.
        private var remaining: [Int]
        /// How many leading status characters a body line carries: 1 for
        /// `@@` (its ` `/`-`/`+` marker), one per parent for `@@@`.
        private let statusColumns: Int
        private let isCombined: Bool

        /// Body membership is decided by the header's line counts, not by
        /// line prefixes alone: an added line reading `++ x` prints as
        /// `+++ x`, which prefix-dispatch would swallow as a file header.
        /// After every side's count is consumed, only a trailing `\ No
        /// newline` marker still belongs to the hunk.
        ///
        /// For a combined hunk the counts and the line's own shape must
        /// *both* say "body": a line that does not start with a status
        /// character (`@@@`, `diff`, `index`) can never be body text, so a
        /// header can never be swallowed even if its counts were not fully
        /// consumed by some future output shape. Every measured shape
        /// consumes its counts exactly, so the conjunction never truncates
        /// a real body (#0342).
        func wantsMoreBody(marker: Character?) -> Bool {
            if marker == "\\" { return true }
            if isCombined {
                guard let marker else { return false }
                return remaining.contains { $0 > 0 }
                    && (marker == " " || marker == "-" || marker == "+")
            }
            return remaining[0] > 0 || remaining[1] > 0
        }

        /// The ordinary `@@` consumption rule, keyed on the single status
        /// marker: context consumes both sides, `-` the old side, `+` the
        /// new, `\` neither.
        private mutating func consumePlain(_ line: String) {
            guard let marker = line.first else { return }
            switch marker {
            case " ": remaining[0] -= 1; remaining[1] -= 1
            case "-": remaining[0] -= 1
            case "+": remaining[1] -= 1
            default: break                            // "\" counts on neither side
            }
        }

        /// The combined `@@@` consumption rule, derived from measured git
        /// output and exact on every measured shape (#0342). The prefix is
        /// one status character per parent: a line carrying `-` in column
        /// k is deleted relative to parent k and consumes only that
        /// parent's budget -- its other columns are padding, not shared
        /// content (measured: ` -theirs` in a merge where parent 1 has no
        /// such line still prints a space in parent 1's column). A line
        /// with no `-` at all is in the result: it consumes the result
        /// budget once, and each parent whose column reads ` ` (the line
        /// is shared with that parent). A `\ No newline` marker consumes
        /// neither side.
        private mutating func consumeCombined(_ line: String) {
            let columns = Array(line.prefix(statusColumns))
            guard columns.count == statusColumns,
                  columns.allSatisfy({ " -+\\".contains($0) }) else { return }
            if columns.contains("-") {
                for index in columns.indices where columns[index] == "-" {
                    remaining[index] -= 1
                }
            } else {
                remaining[statusColumns] -= 1
                for index in columns.indices where columns[index] == " " {
                    remaining[index] -= 1
                }
            }
        }

        /// Parses `@@ -a[,b] +c[,d] @@ …`. An omitted count means 1.
        init(header: String) throws {
            let tokens = header.split(separator: " ")
            guard tokens.count >= 4, tokens[0] == "@@", tokens[3].hasPrefix("@@"),
                  tokens[1].hasPrefix("-"), tokens[2].hasPrefix("+") else {
                throw Failure.malformedHunkHeader(header)
            }
            self.header = header
            (oldStart, oldCount) = try Self.range(tokens[1].dropFirst(), of: header)
            (newStart, newCount) = try Self.range(tokens[2].dropFirst(), of: header)
            remaining = [oldCount, newCount]
            isCombined = false
            statusColumns = 1
        }

        /// Parses `@@@ -a[,b] -c[,d] … +e[,f] @@@ …` -- one `-` range per
        /// parent, then the result range. An omitted count means 1, as in
        /// a `@@` header. The header is stored verbatim;
        /// `oldStart`/`oldCount` carry the **first parent** column and
        /// `newStart`/`newCount` the result column -- the remaining parent
        /// columns ride only in the verbatim header (see `Hunk.header`).
        init(combinedHeader header: String) throws {
            let tokens = header.split(separator: " ")
            guard tokens.count >= 4, tokens[0] == "@@@" else {
                throw Failure.malformedHunkHeader(header)
            }
            var parents: [(start: Int, count: Int)] = []
            var index = 1
            while index < tokens.count, tokens[index].hasPrefix("-") {
                parents.append(try Self.range(tokens[index].dropFirst(), of: header))
                index += 1
            }
            guard !parents.isEmpty, index < tokens.count,
                  tokens[index].hasPrefix("+") else {
                throw Failure.malformedHunkHeader(header)
            }
            let result = try Self.range(tokens[index].dropFirst(), of: header)
            index += 1
            // The closing `@@@`; anything after it is a section heading,
            // ignored exactly as a `@@` header's trailing text is.
            guard index < tokens.count, tokens[index].hasPrefix("@@@") else {
                throw Failure.malformedHunkHeader(header)
            }
            self.header = header
            (oldStart, oldCount) = (parents[0].start, parents[0].count)
            (newStart, newCount) = result
            remaining = parents.map(\.count) + [result.1]
            isCombined = true
            statusColumns = parents.count
        }

        /// `-a[,b]` → (a, b). An omitted count means 1.
        private static func range(_ token: Substring,
                                  of header: String) throws -> (Int, Int) {
            let parts = token.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]),
                  parts.count <= 2,
                  let count = parts.count == 2 ? Int(parts[1]) : 1 else {
                throw Failure.malformedHunkHeader(header)
            }
            return (start, count)
        }
    }
}

/// The `-c` config overrides pinned in every diff-producing command in this
/// file (`listHunks`, `commitDiff`): `core.quotepath=false` so non-ASCII
/// paths print raw, and `diff.suppressBlankEmpty=false` (there is no
/// command-line flag for this one -- with it set to `true`, git drops the
/// leading space git otherwise prints on a blank context line, and
/// `HunkBuilder.body.didSet` decrements its remaining-line budget from that
/// space, so a blank context line under the config would consume no budget,
/// `wantsMoreBody` would keep reporting true, and the next hunk's `@@`
/// header would be swallowed as body text (#0323)). Passed before the
/// subcommand (`diff` or `diff-tree`), as `git -c k=v -c k=v <subcommand>`.
private let pinnedDiffConfigOverrides = ["-c", "core.quotepath=false",
                                          "-c", "diff.suppressBlankEmpty=false"]

/// The flags pinned in every diff-producing command in this file
/// (`listHunks`, `commitDiff`), for seven separately measured reasons
/// (#0267, #0283, #0293, #0294, #0323, #0328, #0336), against user config:
/// `--no-color`, `--no-ext-diff` and `--no-textconv` (drivers would replace
/// or fabricate patch text), `--no-renames` (a rename would put two
/// different paths on the `diff --git` line), `--default-prefix` (overrides
/// `diff.noprefix` and `diff.mnemonicprefix`), `--full-index` (overrides
/// `core.abbrev`, which otherwise changes the length of the `headerText`
/// `index` line -- measured, git 2.50.1: `core.abbrev=4` prints `index
/// e45c..6319` while `--full-index` always prints the full 40-hex blob ids,
/// and `headerText` is both a `schemaVersion: 1` wire field and the byte
/// `Staging.swift` hands to `git apply`, so it cannot vary with a user's
/// config -- and the same holds for the combined blocks a merge commit's
/// `--cc` output contains: measured, `core.abbrev=4` shortens a `diff --cc`
/// block's `index` line to `a238,0bf9..fe05` without `--full-index`, and
/// with it the line is full 40-hex regardless of `core.abbrev`),
/// `--unified=3` (overrides `diff.context`), `--inter-hunk-context=0`
/// (overrides `diff.interHunkContext`, git's own default when it is unset --
/// measured, git 2.50.1, on a 20-line file with an insertion after line 3
/// and an edit at line 17: at the default, `git diff` prints two hunks,
/// `@@ -1,6 +1,7 @@` and `@@ -14,7 +15,7 @@ line 13`; with
/// `diff.interHunkContext=10` and no override, it prints one merged
/// `@@ -1,20 +1,21 @@`; `--inter-hunk-context=0` restores the two-hunk
/// output. `--unified=3` bounds the context *within* a hunk;
/// `--inter-hunk-context` bounds the gap at which two hunks *merge* -- the
/// same defect as `diff.context` above, one flag over (#0336). Appended
/// after the subcommand and its own arguments, e.g. `diff --cached` or
/// `diff-tree --root -p --cc --no-commit-id <rev>`, both of which accept these as
/// ordinary diff-machinery flags.
///
/// **One shared copy for #0330's config-immunity sweep to guard**: two
/// separately-maintained lists would diverge, and the sweep only checks
/// what it is pointed at (#0341).
private let pinnedDiffFlags = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
                                "--default-prefix", "--full-index", "--unified=3",
                                "--inter-hunk-context=0"]

/// Lists the hunks of every changed file in the repository at `path`, for
/// one diff area. Empty when that diff is empty.
///
/// See `pinnedDiffConfigOverrides` and `pinnedDiffFlags` for why each flag
/// here is pinned.
public func listHunks(
    at path: String,
    area: DiffArea,
    git: GitProcess = GitProcess()
) throws -> [FileDiff] {
    var arguments = pinnedDiffConfigOverrides + ["diff"]
    if area == .staged { arguments.append("--cached") }
    arguments += pinnedDiffFlags
    let output = try git.run(arguments, workingDirectory: path)
    return try HunkParser().parse(output.text)
}

/// Async twin of `listHunks(at:area:git:)` (#0344), for callers already on
/// Swift concurrency's cooperative pool: the `git diff` subprocess is
/// awaited on the non-blocking `GitProcess` path, so the pool thread is
/// released while git runs. Same arguments, same parser, same result.
public func listHunks(
    at path: String,
    area: DiffArea,
    git: GitProcess = GitProcess()
) async throws -> [FileDiff] {
    var arguments = pinnedDiffConfigOverrides + ["diff"]
    if area == .staged { arguments.append("--cached") }
    arguments += pinnedDiffFlags
    let output = try await git.run(arguments, workingDirectory: path)
    return try HunkParser().parse(output.text)
}

/// The diff a single commit introduced -- what `#0082`'s detail pane shows
/// for a selected commit. Empty when the commit introduced no changes
/// (e.g. an `--allow-empty` commit, or a **clean merge** -- see below).
///
/// `git diff <rev>^!` is the obvious spelling and is wrong: on a **root**
/// commit it has no parent, so `<rev>^` does not resolve and `git diff`
/// prints nothing at all, exit 0 -- indistinguishable from a genuinely empty
/// commit. Measured, git 2.50.1, fresh repository with one commit:
/// `git diff …flags… 'HEAD^!'` prints nothing, exit 0.
///
/// `git diff-tree --root -p --cc --no-commit-id` handles all four shapes
/// this function needs to tell apart. `--cc` is what `git show` prints for
/// a merge by default -- the combined diff -- and it changes nothing for the
/// other shapes: measured byte-identical output for an ordinary commit with
/// and without it. It is passed for every revision so the argument vector
/// does not fork on the commit's parent count:
///
/// - **Root commit**: `--root` makes `diff-tree` diff it against the empty
///   tree instead of refusing for lack of a parent -- measured, same
///   fixture: the file appears with `--- /dev/null`, i.e. `oldMode == nil`.
/// - **Ordinary commit**: an unremarkable one-parent diff; `--cc` is inert
///   for it (measured: identical bytes).
/// - **Merge commit, clean**: when the merge introduced no changes of its
///   own -- no file it holds differs from every parent -- the combined
///   diff is **empty**, and that emptiness is the honest verdict "this
///   merge introduced no changes of its own" rather than diff-tree's
///   refusal to pick a parent (the state #0341 pinned, indistinguishable
///   from an `--allow-empty` commit). Measured, git 2.50.1, a merge of two
///   branches that each added their own file with nothing contributed by
///   the merge itself: zero bytes, exit 0.
/// - **Merge commit, dirty**: a merge whose content differs from *all*
///   parents somewhere -- a hand-resolved conflict, or a file the merge
///   itself added -- shows exactly that, and only that. A merge that adds
///   its own file (`FixtureRepository.merged` adds `merge.txt`, in neither
///   parent) yields just that file's block: `diff --cc merge.txt`,
///   `new file mode 100644`, `@@@ -1,0 -1,0 +1,1 @@@` over `++merge` --
///   measured. A conflict resolved to a fourth value yields a `@@@`
///   hunk with two-character-prefixed body lines: `@@@ -1,1 -1,1 +1,1 @@@`
///   over `- ours`, ` -theirs`, `++resolved` -- measured. The two
///   branches' own additions never appear (each matches a parent, which
///   `--cc` omits by design). `HunkParser` stores such hunks verbatim --
///   header and body -- and the per-parent reading belongs to the pane.
///
/// The alternatives measured against that same fixture: without any of
/// `-m`/`-c`/`--cc`, `diff-tree` picks no parent for a merge and prints
/// **nothing** (the state #0341 pinned, indistinguishable from an
/// `--allow-empty` commit); `--first-parent -m` shows only parent 1's side
/// and silently hides what came from the other side -- untruthful in a
/// bug-report context; plain `-m` yields one diff per parent and needs a
/// parent-picker UI that does not exist.
///
/// `--no-commit-id` removes the bare 40-hex oid line `diff-tree` otherwise
/// prints first. Measured (mutation, #0341): dropping the flag does **not**
/// currently redden any test here -- `HunkParser.parse`'s preamble handling
/// (`guard file != nil else { continue }`) already discards every line
/// before the first `diff --git`, so the stray oid line is silently
/// swallowed as preamble rather than mis-parsed. Pinned anyway: it is the
/// exact command this function's doc comment measured, it keeps this
/// output identical line-for-line to a plain `git diff`'s, and it removes a
/// dependence on that guard's incidental coverage of a line it was not
/// written to handle.
///
/// See `pinnedDiffConfigOverrides` and `pinnedDiffFlags` for why each flag
/// here is pinned -- the same vector `listHunks` carries, so the two cannot
/// diverge. Note for combined blocks specifically: `--full-index` is what
/// keeps their `index` line config-stable -- measured, `core.abbrev=4`
/// shortens it to `a238,0bf9..fe05` without `--full-index`, and with it the
/// line is full 40-hex regardless of `core.abbrev`.
public func commitDiff(
    at path: String,
    revision: String,
    git: GitProcess = GitProcess()
) throws -> [FileDiff] {
    let output = try git.run(commitDiffArguments(revision: revision), workingDirectory: path)
    return try HunkParser().parse(output.text)
}

/// Async twin of `commitDiff(at:revision:git:)` (#0344), for callers already
/// on Swift concurrency's cooperative pool: the `git diff-tree` subprocess
/// is awaited on the non-blocking `GitProcess` path, so the pool thread is
/// released while git runs. Same arguments (shared `commitDiffArguments`),
/// same parser, same result.
public func commitDiff(
    at path: String,
    revision: String,
    git: GitProcess = GitProcess()
) async throws -> [FileDiff] {
    let output = try await git.run(commitDiffArguments(revision: revision), workingDirectory: path)
    return try HunkParser().parse(output.text)
}

/// The arguments `commitDiff` runs, shared by the synchronous and async
/// paths (#0344) so the pinned config overrides and flags cannot drift
/// between them.
private func commitDiffArguments(revision: String) -> [String] {
    var arguments = pinnedDiffConfigOverrides
    arguments += ["diff-tree", "--root", "-p", "--cc", "--no-commit-id"]
    arguments += pinnedDiffFlags
    arguments.append(revision)
    return arguments
}

// MARK: - Wire encoding (#0132)

/// `Hunk` is a `schemaVersion: 1` payload component: it encodes through
/// `YardKit`'s `Envelope` via `EncodableResult` (`Encodable & Sendable`).
/// Plain-stdlib `Encodable` — the engine still imports nothing.
extension Hunk: Encodable {
    /// The stable wire keys. Identical to the stored-member names on purpose;
    /// no raw values — the case name IS the wire key, and `DiffBlameWireTests`
    /// pins the encoded bytes. The computed `patchText` is not encoded
    /// (#0129 Decision 7): it is a pure join of `header` and `body`, which
    /// both ride the wire, so a reader can reconstruct it losslessly.
    private enum CodingKeys: String, CodingKey {
        case id, path, oldStart, oldCount, newStart, newCount, header, body
    }
}

extension FileDiff: Encodable {
    /// Stable wire keys, identical to the stored-member names; no raw values.
    /// An empty `hunks` array (binary or mode-only change) encodes as `[]`,
    /// never omitted — only nil optionals (`oldMode`, `newMode`) are omitted.
    private enum CodingKeys: String, CodingKey {
        case path, oldMode, newMode, isBinary, headerText, hunks
    }
}

// MARK: - §6 exit class (#0147)

/// A path or header this parser refuses to mis-parse is a repository-state
/// failure — guide §6 code 6.
extension HunkParser.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
