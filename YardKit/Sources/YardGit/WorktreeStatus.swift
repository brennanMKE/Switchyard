// WorktreeStatus.swift

import Foundation

/// A per-file snapshot from `git status --porcelain=v2 -z`.
///
/// Each field is the index/staged state and the worktree (disk) state of a single path.
/// Paths with spaces are preserved — `--porcelain=v2` emits one NUL-terminated record per
/// file and a fixed number of leading space-separated tokens before the path.
public struct WorktreeStatusEntry {
    /// Path relative to the repository root (one of many names git uses for it).
    public var path: String

    /// Raw bytes of the path, losslessly preserved. For display use `path`
    /// (which decodes lossy via UTF-8) or reconstruct from `pathBytes`.
    public var pathBytes: [UInt8]

    /// The state of the index side — what would be committed next.
    public var staged: State = .unmodified

    /// The state of the worktree — what is on disk.
    public var worktree: State = .unmodified

    /// For a rename (`R` in staged), the pre-rename path. `nil` for every other
    /// change type. Emits from the second NUL-terminated field of a `2` record.
    public var originalPath: String?

    /// Raw bytes of the original path, if present.
    public var originalPathBytes: [UInt8]?

    /// Submodule state, parsed from the `S<c><m><u>` token in the third field.
    /// `nil` when git reports `N...`.
    public var submodule: SubmoduleState?

    /// One of the two porcelain-character meanings for a single field.
    public enum State: String, CaseIterable {
        case unmodified = "."
        case added = "A"
        case deleted = "D"
        case modified = "M"
        case untracked = "?"
        case ignored = "!"
        case conflicted = "u"
        /// Typechange: a tracked path swapped kind on disk — regular file to
        /// symlink or the reverse. Only appears in the XY field of an ordinary
        /// (`1`) or renamed/copied (`2`) record; `git status --porcelain=v2 -z`
        /// never emits `T` on an unmerged (`u`) record. Measured 2026-08-17:
        /// `git add` after `ln -sf` over a tracked file prints
        /// `1 T. N... 100644 120000 120000 <h1> <h2> file.txt`.
        case typechange = "T"
        /// Unmerged: the literal porcelain `U` half of a conflict combination
        /// (`UU`, `AU`, `UA`, `DU`, `UD`). Only appears in the XY field of an
        /// unmerged (`u`) record. Measured 2026-08-17 from a real content
        /// conflict: `u UU N... 100644 100644 100644 100644 <b> <o> <t> f.txt`.
        case unmerged = "U"

        /// Path is tracked in the index (`A`-`M`) — not `untracked`.
        ///
        /// The alphabets of ordinary/rename records (`. M T A D R C`) and
        /// unmerged records (`D A U`) are disjoint apart from `D`/`A`, which
        /// mean the same thing on both — deleted or added — so one mapping
        /// serves every record type without knowing which one it came from.
        init?(char: Character) {
            switch char {
            case ".": self = .unmodified
            case "A", "+": self = .added
            case "D", "-": self = .deleted
            case "M": self = .modified
            // "C" (copy) maps here alongside "R" (rename), the same as every
            // other rename/copy status character. There is no separate
            // `.copied` case: `gitStatus` pins `-c status.renames=true`
            // (above), and a command-line `-c` always beats a
            // repository-level `status.renames=copies`, so no production
            // path can emit a `C` record through `gitStatus` for any
            // repository, however the user configures it (#0329, #0334).
            // `EnumVocabularyCoverageTests`' hand-built `C.` record (#0316)
            // is what keeps this mapping tested even though it is otherwise
            // unreachable.
            case "R", "C": self = .modified
            case "T": self = .typechange
            case "U": self = .unmerged
            default: return nil
            }
        }

        /// Path is untracked, ignored, or conflicted.
        public static func special(char: Character) -> State {
            switch char {
            case "?": return .untracked
            case "!": return .ignored
            case "u": return .conflicted
            default:  return .unmodified
            }
        }
    }

    /// State of a submodule, parsed from the `S<c><m><u>` token.
    public struct SubmoduleState: Equatable, Sendable {

        /// Submodule commit changed (e.g. new SHA is recorded in the index).
        public let commitChanged: Bool

        /// Submodule has modifications to tracked files (dirty submodule).
        public let hasModifications: Bool

        /// Submodule has untracked files inside it.
        public let hasUntracked: Bool

        /// Parse a `SubmoduleState` from the 4-char `<sub>` token that git
        /// emits for submodule records: `S<c><m><u>`. Plain paths emit `N...`,
        /// which parses as the "clean" submodule. Callers treat that as nil.
        public init?(subToken: String) {
            guard subToken.count == 4, subToken.first == "S" else { return nil }
            let chars = Array(subToken.dropFirst())
            guard chars.count == 3 else { return nil }
            self.commitChanged   = chars[0] == "C"
            self.hasModifications = chars[1] == "M"
            self.hasUntracked    = chars[2] == "U"
        }

        public static let clean = SubmoduleState(subToken: "S...")!

        public static func == (lhs: SubmoduleState, rhs: SubmoduleState) -> Bool {
            lhs.commitChanged == rhs.commitChanged
                && lhs.hasModifications == rhs.hasModifications
                && lhs.hasUntracked == rhs.hasUntracked
        }
    }

    public init(path: String,
                pathBytes: [UInt8],
                originalPath: String? = nil,
                originalPathBytes: [UInt8]? = nil) {
        self.path = path
        self.pathBytes = pathBytes
        self.originalPath = originalPath
        self.originalPathBytes = originalPathBytes
    }

    /// Initializer for call sites that don't need raw bytes yet.
    public init(path: String) {
        self.path = path
        self.pathBytes = Array(path.utf8)
    }
}

/// The full status of a worktree. Value type, no printing, no side effects.
public struct WorktreeStatus {
    public let entries: [WorktreeStatusEntry]

    public init(entries: [WorktreeStatusEntry]) {
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

    /// Malformed input on the `git status --porcelain=v2 -z` byte stream.
    /// Mirrors `ConflictParser.Failure` on the same stream: a record git did
    /// not describe, or one truncated before its fixed fields end, is a
    /// correctness bug to surface, not a record to silently drop.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A record's leading token was not one of the record types
        /// `git status --porcelain=v2 -z` documents (`1`, `2`, `u`, `?`, `!`).
        case unrecognizedRecordType(leading: String)
        /// A record had fewer space-separated tokens than its type requires.
        case truncatedRecord(String)
        /// An XY status character git did not document for either alphabet —
        /// `. M T A D R C` (ordinary/rename) or `D A U` (unmerged). A genuinely
        /// unknown character is a sign this parser is behind a future git, not
        /// something to fold into `.unmodified` (#0207).
        case unrecognizedStatusCharacter(Character)

        public var description: String {
            switch self {
            case let .unrecognizedRecordType(leading):
                "unrecognized porcelain v2 record type \"\(leading)\""
            case let .truncatedRecord(record):
                "malformed porcelain v2 record: \(record)"
            case let .unrecognizedStatusCharacter(char):
                "unrecognized porcelain v2 status character \"\(char)\""
            }
        }
    }

    public init() {}

    /// Number of space-separated tokens before the path, keyed on record type.
    /// Tokens are zero-indexed into `tokens[]` after splitting the raw record, so a
    /// field count of 7 means `tokens[0]` is the leading tag and `tokens[8..]`
    /// is the path — the comment says `"1": 7`, meaning "skip 7 tokens before the
    /// path token". The parser loop starts at `expectedFields` because the leading
    /// tag is already counted: `1 XY sub mH mI mW hH hI path` = 9 tokens, but only
    /// 7 follow the leading tag. Each record type above lists how many tokens (not
    /// including the leading tag) precede the path.
    private static let fieldCount: [String: Int] = [
        "1": 7,   // XY sub mH mI mW hH hI — path at token index 8
        "2": 8,   // XY sub m1 m2 m3 h1 h2 h3 — path at token index 10
        "u": 9,   // XY sub m1 m2 m3 h1 h2 h3 — unmerged/conflict variant
        "?": 0,   // bare "?" token
        "!": 0,   // bare "!" — ignored records (need --ignored)
    ]

    /// Split `data` into NUL-delimited records, returning one `[UInt8]` per
    /// record (with the NUL itself dropped). Paths may contain newlines or
    /// arbitrary bytes, so a `String` split is unsafe. A `2` record carries
    /// two NUL-terminated paths — the second one is the original path and
    /// must be merged back into that record rather than being parsed as a
    /// separate (and skipped) entry. We do this by consuming the original-
    /// path NUL inline while we build each record.
    private static func splitRecords(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var records: [[UInt8]] = []
        var i = 0, n = bytes.count
        while i < n {
            // Find the start of the next record.
            var start = i
            while start < n && bytes[start] == 0x00 { start += 1 }
            if start >= n { break }
            // Find the first NUL.
            var p = start
            while p < n && bytes[p] != 0x00 { p += 1 }
            var record = Array(bytes[start..<p])
            if !record.isEmpty {
                let leadingByte = record.first ?? 0
                // `2` records own a second NUL-terminated field: the original
                // path. Consume it now so downstream code sees a single record.
                if leadingByte == UInt8(ascii: "2") {
                    p += 1 // skip the first NUL
                    let origStart = p
                    while p < n && bytes[p] != 0x00 { p += 1 }
                    if p < n {
                        let origBytes = Array(bytes[origStart..<p])
                        if !origBytes.isEmpty { record.append(contentsOf: [0x00] + origBytes) }
                        p += 1 // skip the second NUL
                    }
                } else {
                    p += 1 // skip the single NUL after this record.
                }
                records.append(record)
            }
            i = p
        }
        return records
    }

    /// Split a `[UInt8]` record's space-delimited tokens.
    private static func splitSpaces(_ bytes: [UInt8]) -> [[UInt8]] {
        var parts: [[UInt8]] = []
        var current: [UInt8] = []
        for byte in bytes {
            if byte == 0x20 {
                parts.append(current)
                current = []
            } else {
                current.append(byte)
            }
        }
        parts.append(current)
        return parts
    }

    public func parse(_ data: Data) throws -> WorktreeStatus {
        let records = Self.splitRecords(data)

        var entries: [WorktreeStatusEntry] = []

        for rawRecord in records {
            guard let firstByte = rawRecord.first,
                  let leading = String(bytes: [firstByte], encoding: .ascii) else { continue }

            let expectedFields = Self.fieldCount[leading]
            guard let expectedFields else {
                throw Failure.unrecognizedRecordType(leading: leading)
            }

            // A `2` record has the original path appended after a NUL by
            // splitRecords. Tokenize only up to that NUL, or the new path comes
            // back as "renamed.txt\0orig.txt" glued into one token.
            let headSlice: [UInt8]
            if leading == "2", let nul = rawRecord.firstIndex(of: 0x00) {
                headSlice = Array(rawRecord[..<nul])
            } else {
                headSlice = rawRecord
            }

            let tokens = Self.splitSpaces(headSlice)
            guard tokens.count > expectedFields else {
                throw Failure.truncatedRecord(String(decoding: rawRecord, as: UTF8.self))
            }

            // The path starts at index `expectedFields + 1` (after the leading tag
            // and its fixed fields) and runs to the end, joined by single spaces.
            // It is kept raw until display time so we can expose both lossy (UTF-8)
            // and lossless bytes. The "+ 1" skips the leading tag which is already at
            // index 0 — so for "1" with field count 7 we start at index 8.
            var pathBytes: [UInt8] = []
            let pathStartIndex = expectedFields + 1
            for i in pathStartIndex..<tokens.count {
                if pathBytes.isEmpty == false { pathBytes.append(0x20) }
                pathBytes.append(contentsOf: tokens[i])
            }

            let path = String(decoding: pathBytes, as: UTF8.self)
            guard !path.isEmpty else { continue }

            var entry = WorktreeStatusEntry(path: path, pathBytes: pathBytes)

            if expectedFields == 0 {
                // `? path` and `! path` carry no XY field — the leading token IS
                // the status, and allTokens[1] is the path itself.
                entry.staged = .unmodified
                entry.worktree = WorktreeStatusEntry.State.special(char: leading.first ?? ".")
            } else {
                // `1`, `2` and `u` all carry XY as the second token.
                let statusBytes = tokens[1]
                guard let statusStr = String(bytes: statusBytes, encoding: .ascii),
                      let stagedChar = statusStr.first else { continue }

                guard let staged = WorktreeStatusEntry.State(char: stagedChar) else {
                    throw Failure.unrecognizedStatusCharacter(stagedChar)
                }

                let workChar: WorktreeStatusEntry.State
                if let secondChar = statusStr.dropFirst().first {
                    guard let mapped = WorktreeStatusEntry.State(char: secondChar) else {
                        throw Failure.unrecognizedStatusCharacter(secondChar)
                    }
                    workChar = mapped
                } else {
                    workChar = .unmodified
                }

                entry.staged = staged
                entry.worktree = workChar

                // The third token is the `<sub>` field (e.g. "S123", "N...").
                // `N...` means an ordinary path (not a submodule) — we store nil.
                // `S<c><m><u>` means a submodule and we populate entry.submodule.
                if tokens.count > 2 {
                    let subStr = String(bytes: tokens[2], encoding: .ascii) ?? ""
                    entry.submodule = WorktreeStatusEntry.SubmoduleState(subToken: subStr)
                }

                // Conflict is signalled by the LEADING token being `u`, never by
                // the XY field — on a `u` record XY is e.g. "AA".
                if leading == "u" {
                    entry.staged = WorktreeStatusEntry.State.special(char: "u")
                }

                // A `2` record carries two NUL-terminated paths: original, then new.
                // splitRecords merged the original-path fragment into the end of rawRecord as a single
                // NUL-delimited suffix. We extract both paths by splitting the record on NULs:
                // everything before the first (space-delimited) token slice is unchanged, and
                // everything after the NUL is the original path.
                if leading == "2", let nulPos = rawRecord.firstIndex(of: 0x00) {
                    // Everything from nulPos onwards is "<NUL><orig-path>" (may include a trailing NUL
                    // that follows the original path — splitRecords does not strip it). The true
                    // original-path bytes are from nulPos+1 to the next NUL (or end of data).
                    var origEnd = rawRecord.count
                    for j in (nulPos + 1)..<rawRecord.count {
                        if rawRecord[j] == 0x00 { origEnd = j; break }
                    }

                    let rawOriginalBytes = Array(rawRecord[(nulPos + 1)..<origEnd])
                    if !rawOriginalBytes.isEmpty {
                        entry.originalPathBytes = rawOriginalBytes
                        entry.originalPath = String(decoding: rawOriginalBytes, as: UTF8.self)
                    }

                    // If everything from nulPos onwards was a bare NUL terminator (path is empty), the
                    // original path would be nil. We only write to entry.originalPath when we got real
                    // bytes above; otherwise the optional defaults stay nil. The path itself (new path)
                    // is already set from the tokens loop above. We do not throw if the raw bytes are
                    // non-UTF-8 — `originalPathBytes` preserves them exactly.
                }
            }

            entries.append(entry)
        }

        return WorktreeStatus(entries: entries)
    }

}

// MARK: - §6 exit class

/// A malformed porcelain record is a repository-state failure — guide §6
/// code 6 — matching `ConflictParser.Failure` on the same byte stream.
extension WorktreeStatusParser.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}

/// Runs `git status --porcelain=v2 -z` against a repository and parses the result.
///
/// `includeIgnored` controls whether ignored files are reported via `--ignored`.
public func gitStatus(
    at repositoryPath: String,
    includeIgnored: Bool = false,
    git: GitProcess = GitProcess()
) throws -> WorktreeStatus {
    // `-c status.showUntrackedFiles=normal`: `--porcelain=v2` exists to be a
    // stable machine format, and every other format-stability lever here is
    // pinned explicitly (`--no-color`, `--no-ext-diff`, `-c
    // core.quotepath=false`, …). This one was the exception (#0318):
    // measured, git 2.50.1 — under `status.showUntrackedFiles = no`, plain
    // `git status --porcelain=v2` omits every untracked file, so `gitStatus`
    // silently dropped them under ordinary user configuration while
    // `whereAmI`'s `untrackedCount` (`ls-files -o --exclude-standard`,
    // plumbing, config-blind) kept counting them — the two engine functions
    // disagreeing about the same worktree, same shape as #0296.
    //
    // `color.ui`, `core.quotepath` (under `-z`), and `status.relativePaths`
    // were measured to leave this output byte-identical, so they are not
    // pinned here (unlike #0319's `wt rm`, where `--force` bypasses git's
    // dirty check entirely rather than relaxing it, a `-c` there would look
    // meaningful and do nothing). That enumeration was measured on a fixture
    // with no rename in it, which is exactly why `status.renames` was not on
    // it — it is fixture-bounded, not exhaustive.
    //
    // `-c status.renames=true`: measured, git 2.50.1 (#0329) — under a user's
    // `status.renames=false` or `diff.renames=false` (`status.renames` falls
    // back to `diff.renames`), a staged `git mv old.txt new.txt` changes
    // shape entirely: one `2 R.` entry with `originalPath` becomes two
    // separate entries, `1 A.` and `1 D.`, with no rename correlation at all.
    // `true` is git's own default (`status.renames` falls back to
    // `diff.renames`, which defaults to true), so pinning it preserves
    // today's behaviour exactly and changes only what happens under a
    // non-default user config — the same reasoning as
    // `status.showUntrackedFiles` above.
    //
    // Decided (#0334): kept `true` rather than `copies`, so a command-line
    // `-c` here always beats a repository-level `status.renames=copies` and
    // `gitStatus` can no longer report a copy (`C`) record for any
    // repository, however the user configures it.
    let output = try git.run(
        gitStatusArguments(includeIgnored: includeIgnored),
        workingDirectory: repositoryPath
    )

    return try WorktreeStatusParser().parse(output.standardOutput)
}

/// The arguments `gitStatus` runs, shared byte-for-byte by the synchronous
/// and async paths (#0344) so the pinned config levers above can never drift
/// between them.
private func gitStatusArguments(includeIgnored: Bool) -> [String] {
    var args: [String] = [
        "-c", "status.showUntrackedFiles=normal",
        "-c", "status.renames=true",
        "status", "--porcelain=v2", "-z",
    ]
    if includeIgnored { args.append("--ignored") }
    return args
}

/// Async twin of `gitStatus(at:includeIgnored:git:)` (#0344), for callers
/// already on Swift concurrency's cooperative pool: the `git status`
/// subprocess is awaited on the non-blocking `GitProcess` path, so the pool
/// thread is released while git runs. Same arguments (shared
/// `gitStatusArguments`), same parser, same result.
public func gitStatus(
    at repositoryPath: String,
    includeIgnored: Bool = false,
    git: GitProcess = GitProcess()
) async throws -> WorktreeStatus {
    let output = try await git.run(
        gitStatusArguments(includeIgnored: includeIgnored),
        workingDirectory: repositoryPath
    )

    return try WorktreeStatusParser().parse(output.standardOutput)
}

// MARK: - Wire encoding (#0131)

/// `WorktreeStatusEntry` is a `schemaVersion: 1` payload component: it encodes
/// through `YardKit`'s `Envelope` via `EncodableResult` (`Encodable &
/// Sendable`). Plain-stdlib `Encodable` — the engine still imports nothing.
/// `Sendable` is added here too: public structs get no implicit `Sendable`
/// across module boundaries, and `EncodableResult`'s bound needs it.
extension WorktreeStatusEntry: Encodable, Sendable {
    /// The stable wire keys. Identical to the member names on purpose; no raw
    /// values — the case name IS the wire key, and `StatusConflictsWireTests`
    /// pins the encoded bytes. `pathBytes` and `originalPathBytes` are
    /// deliberately absent (#0129 Decision 6): a JSON string must be valid
    /// UTF-8, so the wire carries the lossily-decoded `path` /
    /// `originalPath`; raw bytes never ride the wire.
    private enum CodingKeys: String, CodingKey {
        case path, staged, worktree, originalPath, submodule
    }
}

/// String-raw enum: encodes as its raw value, a single JSON string — the
/// porcelain character itself (#0129 Decision 5).
extension WorktreeStatusEntry.State: Encodable, Sendable {}

extension WorktreeStatusEntry.SubmoduleState: Encodable {
    /// Stable wire keys, identical to the member names; no raw values.
    private enum CodingKeys: String, CodingKey {
        case commitChanged, hasModifications, hasUntracked
    }
}

/// `WorktreeStatus` is the whole-status payload: an object with one `entries`
/// key, not a bare array — an object can gain sibling fields additively under
/// `YardKit/Schemas/README.md`'s rule; a bare array cannot.
extension WorktreeStatus: Encodable, Sendable {
    /// Stable wire keys, identical to the member names; no raw values.
    private enum CodingKeys: String, CodingKey {
        case entries
    }
}
