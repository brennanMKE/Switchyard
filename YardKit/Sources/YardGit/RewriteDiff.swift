// RewriteDiff.swift — range-diff over a stored rewrite mapping (#0064)

import Foundation

/// Answers "what changed in the changes" after a rewrite: given one journal
/// entry id, reads the old→new commit mapping the entry stores (#0043's
/// `post-rewrite` data, own or observed), computes the ranges to compare
/// from it, and runs `git range-diff --no-color` over them, returning typed
/// rows instead of raw text.
///
/// Two entry shapes carry a mapping, and both are read (the "works for
/// rewrites performed by git directly" criterion):
///
/// - An **own** entry's `JournalEntryMetadata.rewrite`
///   (`JournalEntryMetadata.RewriteMapping`, composed per #0234) — the
///   mapping `switchyard`'s own rewrite attached to its in-flight entry
///   (#0221).
/// - An **observed** entry (`JournalObserved.Metadata`, kind `.rewrites`,
///   #0220) — the mapping a *foreign* `post-rewrite` invocation recorded,
///   which is how git-direct rewrites (`git rebase`, `git commit --amend`
///   run by a human) land in the journal.
///
/// An id that resolves to neither shape is a typed refusal, never an empty
/// diff: a reviewer who asks for the delta must be told there is none to
/// serve, not shown a meaningless one.
///
/// The ranges come from `PostRewrite.replacements(of:)` — the many-to-one
/// view that makes a squash mapping a sensible comparison rather than a
/// broken one. In git's processing order (oldest rewritten commit first):
/// old tip = the newest old oid, new tip = the newest new oid, base = the
/// parent of the oldest old oid. A mapping whose oldest old oid is a root
/// commit has no parent; the empty tree takes its place (measured, git
/// 2.50.1: `git range-diff --no-color <empty-tree> <root> <tip>` renders the
/// root commit's own diff, the shape Split measured from the index side).
///
/// The command is read-only: no journal entry is written, no ref moves, no
/// conflict class exists on its surface.
public enum RewriteDiff {

    /// The well-known SHA-1 empty tree. Never spelled inline at use sites:
    /// `base` is computed once, here, so a future object-format change has
    /// exactly one place to account for.
    private static let emptyTreeOID = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// Which stored shape served the mapping.
    public enum Source: String, Equatable, Sendable, Encodable {
        /// The entry's own `JournalEntryMetadata.rewrite` — a rewrite
        /// `switchyard` itself performed.
        case own
        /// An observed entry (`JournalObserved.Metadata` kind `.rewrites`) —
        /// a rewrite git performed directly.
        case observed
    }

    /// One side of a parsed pair, as range-diff printed it.
    public struct Side: Equatable, Sendable, Encodable {
        /// The pair's position within its own range, 1-based.
        public let number: Int
        /// The short object id exactly as the output carried it — the parse
        /// never invents a length git did not print.
        public let oid: String

        public init(number: Int, oid: String) {
            self.number = number
            self.oid = oid
        }

        /// The stable wire keys, identical to the stored-member names on
        /// purpose; no raw values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case number, oid
        }
    }

    /// What the pair marker said. Wire: the case names verbatim —
    /// `identical`, `modified`, `oldOnly`, `newOnly` — the same camelCase
    /// key convention the surrounding payload uses.
    public enum PairStatus: String, Equatable, Sendable, Encodable {
        /// `=` — same patch, same message.
        case identical
        /// `!` — the patch or the message changed.
        case modified
        /// `<` — on the old side only: the commit was dropped by the rewrite.
        case oldOnly
        /// `>` — on the new side only: the commit is new in the rewritten
        /// range.
        case newOnly
    }

    /// One range-diff pair row, parsed: the marker, both sides where each
    /// exists, and the trailing subject. Rows carry the short oids the
    /// output printed — the mapping's full oids are in `Ranges`, and the
    /// short forms are what a reviewer sees.
    ///
    /// A side absent from the pair (`<`/`>` rows) is `nil` in memory and
    /// **absent from the wire** — synthesized `Codable`'s `encodeIfPresent`
    /// convention, the same optional-field shape every engine result
    /// carries. The absence is information, never a default.
    public struct Row: Equatable, Sendable, Encodable {
        public let status: PairStatus
        public let old: Side?
        public let new: Side?
        public let subject: String

        public init(status: PairStatus, old: Side?, new: Side?, subject: String) {
            self.status = status
            self.old = old
            self.new = new
            self.subject = subject
        }

        /// `old`/`new` encode as `null` when the side is absent — a dropped
        /// (`<`) or added (`>`) pair has exactly one side, and the absence
        /// is information, never a default.
        private enum CodingKeys: String, CodingKey {
            case status, old, new, subject
        }
    }

    /// The three ranges the comparison ran over, all full oids.
    public struct Ranges: Equatable, Sendable, Encodable {
        /// The parent of the mapping's oldest old commit — or the empty
        /// tree when that oldest old oid is a root commit.
        public let base: String
        /// The newest old oid in the mapping.
        public let oldTip: String
        /// The newest new oid in the mapping.
        public let newTip: String

        public init(base: String, oldTip: String, newTip: String) {
            self.base = base
            self.oldTip = oldTip
            self.newTip = newTip
        }

        /// The stable wire keys, identical to the stored-member names on
        /// purpose; no raw values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case base, oldTip, newTip
        }
    }

    /// What one completed diff carries.
    public struct Result: Equatable, Sendable, Encodable {
        /// The journal entry the mapping was read from.
        public let entryID: JournalEntryID
        /// Which shape served the mapping.
        public let source: Source
        /// The git argument the mapping was recorded as arriving from
        /// (`"rebase"`, `"amend"`, …) — the same string both storage shapes
        /// persist.
        public let rewriteSource: String
        /// The ranges the comparison ran over.
        public let ranges: Ranges
        /// The parsed pairs, in range-diff's order.
        public let rows: [Row]

        public init(
            entryID: JournalEntryID, source: Source, rewriteSource: String,
            ranges: Ranges, rows: [Row]
        ) {
            self.entryID = entryID
            self.source = source
            self.rewriteSource = rewriteSource
            self.ranges = ranges
            self.rows = rows
        }

        /// The stable wire keys, identical to the stored-member names on
        /// purpose; no raw values — the case name IS the wire key.
        private enum CodingKeys: String, CodingKey {
            case entryID, source, rewriteSource, ranges, rows
        }
    }
}

// MARK: - Parsing

extension RewriteDiff {

    /// The pair marker's four measured spellings.
    private static let markers: [String: PairStatus] = [
        "=": .identical, "!": .modified, "<": .oldOnly, ">": .newOnly,
    ]

    /// Parses `git range-diff --no-color` output into rows.
    ///
    /// Measured line shape (git 2.50.1), one pair per row, at column 0:
    ///
    /// ```
    /// 1:  bfc8637 ! 1:  1350d9c c2
    /// 2:  e4953bc < -:  ------- c3
    /// -:  ------- > 1:  9fbc3d2 c1 amended
    /// 1:  bfc8637 = 1:  bfc8637 c2
    /// ```
    ///
    /// `<counter> <short-oid> <marker> <counter> <short-oid> <subject…>`,
    /// where an absent side is the sentinel `-:  -------`. Each pair line is
    /// followed by an indented diff body (lines beginning with whitespace),
    /// which never parses as a row: a row is recognized only at column 0
    /// with a counter field, a marker field, and both side fields present —
    /// and the marker must agree with which sides are present, so a format
    /// drift fails typed instead of mis-parsing. Diff body lines are
    /// prefixed with `-`, `+`, or four spaces, so none reaches the marker
    /// check; a column-0 line that *starts* like a row but fails the
    /// contract throws rather than being skipped, because guessing at what
    /// the reviewer is shown is exactly the raw-text passthrough this type
    /// exists to prevent.
    ///
    /// - Throws: `.unparseableOutput` naming the offending line.
    public static func parseRows(_ text: String) throws -> [Row] {
        var rows: [Row] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(line)
            guard !raw.hasPrefix(" "), !raw.hasPrefix("\t") else { continue }
            let fields = raw.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard looksLikeRowCounter(fields[0]) else {
                // Column-0 prose is not a row and not an error — the
                // measured output carries none, but a prefix git could add
                // must not wedge the parse into a refusal either.
                continue
            }
            guard fields.count >= 5 else {
                throw RewriteDiffError.unparseableOutput(
                    detail: "truncated pair row in line: \(raw)")
            }
            guard let status = markers[fields[2]] else {
                throw RewriteDiffError.unparseableOutput(detail: "unknown pair marker "
                    + "'\(fields[2])' in line: \(raw)")
            }
            let old = try side(counter: fields[0], oid: fields[1], line: raw)
            let new = try side(counter: fields[3], oid: fields[4], line: raw)
            // The marker and the sides must agree: an old-only pair has no
            // new side and vice versa; a paired marker has both. Enforcing
            // it here is what keeps a drifted format from decoding as
            // silently wrong rows.
            switch status {
            case .identical, .modified:
                if old == nil || new == nil {
                    throw RewriteDiffError.unparseableOutput(
                        detail: "paired marker with a missing side in line: \(raw)")
                }
            case .oldOnly:
                if new != nil {
                    throw RewriteDiffError.unparseableOutput(
                        detail: "old-only pair carries a new side in line: \(raw)")
                }
            case .newOnly:
                if old != nil {
                    throw RewriteDiffError.unparseableOutput(
                        detail: "new-only pair carries an old side in line: \(raw)")
                }
            }
            let subject = fields.dropFirst(5).joined(separator: " ")
            rows.append(Row(status: status, old: old, new: new, subject: subject))
        }
        return rows
    }

    /// One side of a pair line, three ways: present (`<digits>:` with a hex
    /// oid), absent (the `-:` `-------` sentinel pair), or malformed — any
    /// other combination, which the row contract turns into a typed
    /// refusal rather than a guessed side.
    private enum ParsedSide {
        case present(Side)
        case absent
        case malformed
    }

    private static func parseSide(counter: String, oid: String) -> ParsedSide {
        if counter == "-:" {
            return oid == "-------" ? .absent : .malformed
        }
        guard looksLikeRowCounter(counter), let number = Int(counter.dropLast()),
              number >= 1,
              oid != "-------",
              !oid.isEmpty, oid.allSatisfy(\.isHexDigit)
        else { return .malformed }
        return .present(Side(number: number, oid: oid))
    }

    /// A parsed side with its refusal attached — the row contract's
    /// "malformed is a typed error, absent is information".
    private static func side(counter: String, oid: String, line: String) throws -> Side? {
        switch parseSide(counter: counter, oid: oid) {
        case .present(let side): return side
        case .absent: return nil
        case .malformed:
            throw RewriteDiffError.unparseableOutput(
                detail: "unrecognized pair fields in line: \(line)")
        }
    }

    /// Whether a field can be a pair counter: `<digits>:` or the absent
    /// sentinel `-:`. This is the gate that separates row lines from
    /// column-0 body text, so it must not accept anything looser than the
    /// measured shape. The sentinel matters: a new-only (`>`) row *starts*
    /// with `-:` — measured — so rejecting it here would silently skip
    /// every added commit's row.
    private static func looksLikeRowCounter(_ field: String) -> Bool {
        guard field.hasSuffix(":") else { return false }
        let digits = field.dropLast()
        return digits == "-" || (!digits.isEmpty && digits.allSatisfy(\.isNumber))
    }
}

// MARK: - Errors

/// Why `RewriteDiff.run` refused.
public enum RewriteDiffError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The id names no journal entry and no observed entry — there is
    /// nothing to diff, and guessing would be worse than refusing.
    case unknownEntry(id: JournalEntryID)
    /// The id resolves to a real entry, but neither storage shape on it
    /// carries a rewrite mapping — nothing about that entry's history was
    /// rewritten, so there is no comparison to serve.
    case noRewriteMapping(id: JournalEntryID)
    /// `git range-diff` exited 0 but its output does not parse as the
    /// measured line shape — a git whose format this build does not know,
    /// or output that is not a row listing. Never passed through raw.
    case unparseableOutput(detail: String)

    public var description: String {
        switch self {
        case let .unknownEntry(id):
            "no journal entry and no observed entry has id \(id)"
        case let .noRewriteMapping(id):
            "journal entry \(id) exists but stores no rewrite mapping, "
                + "so there is no rewrite to diff"
        case let .unparseableOutput(detail):
            "git range-diff output did not parse: \(detail)"
        }
    }
}

// MARK: - The range-diff comparison

extension RewriteDiff {

    /// One stored mapping's source and pairs — the two shapes an entry can
    /// carry, normalized to what the range computation needs.
    private struct StoredMapping: Equatable {
        let source: Source
        let rewriteSource: String
        let rewrites: [PostRewrite.Rewrite]
    }

    /// Computes the ranges a stored mapping compares, and runs
    /// `git range-diff --no-color` over them.
    ///
    /// - Parameters:
    ///   - entryID: the journal (or observed) entry whose stored mapping
    ///     names the comparison.
    ///   - path: the caller's working directory, resolved through
    ///     `WorktreeContext` — never assumed to be a repository.
    ///   - git: the process to run every git invocation through.
    ///   - extraEnvironment: merged over the process environment for every
    ///     invocation. Tests use it to neutralize global and system config
    ///     scope; production callers leave it empty.
    /// - Throws: `RewriteDiffError.unknownEntry` when the id names no entry
    ///   in either namespace; `.noRewriteMapping` when it names one but
    ///   neither shape on it stores a mapping; `.unparseableOutput` when
    ///   range-diff's output does not parse; `GitProcess.Failure` for every
    ///   non-zero git exit; `WorktreeContext`/decode errors for
    ///   repository-state damage.
    public static func run(
        entryID: JournalEntryID,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        let context = try WorktreeContext.resolve(path: path, git: git)
        let base = context.topLevel ?? context.gitDir
        let mapping = try storedMapping(for: entryID, in: context, at: base, git: git,
                                        extraEnvironment: extraEnvironment)

        // The ranges, read off the many-to-one view `replacements(of:)`
        // already groups: git lists pairs oldest-rewritten-first, so within
        // the grouped view the first old oid is the oldest rewritten commit
        // and the last old oid (of the last group, whose new oid is the
        // newest) is the newest. A squash — two old oids against one new —
        // lands here as old tip = the second old oid, new tip = the single
        // new oid, which is what makes the comparison cover both old
        // commits instead of breaking on the first.
        let replacements = PostRewrite.replacements(of: mapping.rewrites)
        guard let oldestOld = replacements.first?.oldOids.first,
              let newestOld = replacements.last?.oldOids.last,
              let newestNew = replacements.last?.newOid,
              !oldestOld.isEmpty, !newestOld.isEmpty, !newestNew.isEmpty
        else {
            throw RewriteDiffError.noRewriteMapping(id: entryID)
        }

        // The base: the oldest old commit's parent, or the empty tree when
        // the oldest old commit is a root commit. The probe is the same
        // quiet shape Split's root check uses.
        let parentProbe = try git.capture(
            ["rev-parse", "--verify", "--quiet", "\(oldestOld)^"],
            workingDirectory: base, extraEnvironment: extraEnvironment)
        let baseOID = parentProbe.exitCode == 0
            ? (parentProbe.lines.first ?? "")
            : try emptyTreeOID(at: base, git: git, extraEnvironment: extraEnvironment)

        // The three-arg form, measured (git 2.50.1) against a many-to-one
        // squash and an empty-tree root before this call was written: it
        // renders the squash as one modified pair plus one old-only row,
        // and the root shape through the empty tree. The two-range form is
        // not used and no fallback exists: the probe found nothing it
        // misbehaves on.
        let output = try git.run(
            ["range-diff", "--no-color", baseOID, newestOld, newestNew],
            workingDirectory: base, extraEnvironment: extraEnvironment)

        let rows = try parseRows(output.text)
        guard !rows.isEmpty else {
            throw RewriteDiffError.unparseableOutput(
                detail: "exit 0 but no pair rows in the output")
        }
        return Result(
            entryID: entryID, source: mapping.source,
            rewriteSource: mapping.rewriteSource,
            ranges: Ranges(base: baseOID, oldTip: newestOld, newTip: newestNew),
            rows: rows)
    }

    /// The empty tree, as the repository's own object format spells it —
    /// `git mktree` over empty input materializes it in whichever format
    /// the repository uses, so no object-format constant is spelled at a
    /// call site. Only a mapping whose oldest old commit is a root commit
    /// reaches here.
    private static func emptyTreeOID(
        at base: String, git: GitProcess, extraEnvironment: [String: String]
    ) throws -> String {
        try git.run(
            ["mktree"], workingDirectory: base, standardInput: Data(),
            extraEnvironment: extraEnvironment).lines.first ?? ""
    }

    /// Reads the mapping an entry stores, from whichever shape it carries —
    /// own first, observed second. An id in neither namespace is
    /// `.unknownEntry`; an id whose entries carry neither shape is
    /// `.noRewriteMapping`.
    private static func storedMapping(
        for entryID: JournalEntryID,
        in context: WorktreeContext,
        at base: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> StoredMapping {
        var foundAnyEntry = false

        // The own shape: the journal namespace's `metadata.json`, decoded
        // as #0155's schema, carrying a #0221-attached mapping.
        if refExists(JournalAnchor.refPrefix + entryID.string, at: base, git: git,
                     extraEnvironment: extraEnvironment) {
            foundAnyEntry = true
            let metadata = try JournalEntryMetadata(
                serialized: try JournalAnchor.metadata(for: entryID, in: context, git: git))
            if let rewrite = metadata.rewrite {
                return StoredMapping(
                    source: .own, rewriteSource: rewrite.source, rewrites: rewrite.rewrites)
            }
        }

        // The observed shape: a foreign rewrite's entry in the observed
        // namespace (#0220), kind `.rewrites`.
        if refExists(JournalObserved.refPrefix + entryID.string, at: base, git: git,
                     extraEnvironment: extraEnvironment) {
            foundAnyEntry = true
            let metadata = try JournalObserved.Metadata(
                serialized: try JournalAnchor.metadata(
                    for: entryID, in: context, namespace: JournalObserved.refPrefix, git: git))
            if metadata.kind == .rewrites,
               let source = metadata.source, let rewrites = metadata.rewrites {
                return StoredMapping(
                    source: .observed, rewriteSource: source, rewrites: rewrites)
            }
        }

        if foundAnyEntry {
            throw RewriteDiffError.noRewriteMapping(id: entryID)
        }
        throw RewriteDiffError.unknownEntry(id: entryID)
    }

    /// Whether a ref exists — a quiet `rev-parse --verify` probe, the same
    /// shape every other existence check in the engine uses.
    private static func refExists(
        _ ref: String, at base: String, git: GitProcess, extraEnvironment: [String: String]
    ) -> Bool {
        (try? git.capture(
            ["rev-parse", "--verify", "--quiet", ref],
            workingDirectory: base, extraEnvironment: extraEnvironment))?
            .exitCode == 0
    }
}

// MARK: - §6 exit class

extension RewriteDiffError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
