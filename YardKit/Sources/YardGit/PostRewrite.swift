// PostRewrite.swift

import Foundation

/// The decision core of the `post-rewrite` hook handler (#0043).
///
/// `post-rewrite` supplies the one thing git gives you no other way: the
/// old→new commit mapping of a rewrite. Measured on git 2.50.1, it fires for
/// `git commit --amend` (argument `amend`) and at the successful completion
/// of `git rebase` (argument `rebase`) — and for nothing else: not plain
/// commits, not `cherry-pick`, not `filter-branch`, not a fast-forward or
/// up-to-date rebase, and never on `rebase --abort`.
///
/// Two rules govern this type, both safety properties:
///
/// - **`decide` is total.** It never throws and its exit code is 0 for every
///   input. The hook runs *after* the rewrite has happened — a non-zero exit
///   cannot undo anything (measured: `git commit --amend` and `git rebase`
///   both exit 0 and move HEAD with a hook that exits 1) — and under #0041's
///   chaining our status feeds a wrapper whose aggregate is what callers see.
///   Malformed stdin lines are counted and dropped, not thrown.
/// - **Own invocations are routed, not skipped.** Unlike the
///   `reference-transaction` handler (#0042), the marker does not suppress
///   parsing: when `switchyard` itself runs a rebase, this hook is the only
///   source of the mapping the journal entry needs, so dropping own
///   invocations would lose exactly the data the journal exists to keep.
///   `decide` parses every invocation and reports `isOwnInvocation` so the
///   persistence layer (#0160) can attach the mapping to the in-flight
///   journal entry or record it as an observed one.
///
/// Persisting the mapping is #0160's work, on top of #0028's store; the CLI
/// arm and installation are #0154 and #0041. This type only decides.
public enum PostRewrite {

    /// The command git passes as the hook's single argument — `amend` or
    /// `rebase` on git 2.50.1 ("further command-dependent arguments may be
    /// passed in the future", so `unrecognized` absorbs anything new and is
    /// still parsed: a mapping from an unknown rewriter is still a mapping).
    public enum Source: Equatable, Sendable {
        case amend
        case rebase
        case unrecognized(String)

        public init(argument: String) {
            switch argument {
            case "amend": self = .amend
            case "rebase": self = .rebase
            default: self = .unrecognized(argument)
            }
        }
    }

    /// One `<old-object-name> SP <new-object-name> [ SP <extra-info> ] LF`
    /// stdin line: this commit was rewritten to that one.
    ///
    /// The object names are 40 hex chars under SHA-1, 64 under SHA-256, both
    /// measured. `extraInfo` is the optional third field — "currently, no
    /// commands pass any extra-info" (githooks(5)), so it is `nil` in
    /// practice, but the parser must tolerate it or the first git that emits
    /// it turns every line malformed.
    public struct Rewrite: Equatable, Sendable {
        public let oldOid: String
        public let newOid: String
        public let extraInfo: String?

        public init(oldOid: String, newOid: String, extraInfo: String? = nil) {
            self.oldOid = oldOid
            self.newOid = newOid
            self.extraInfo = extraInfo
        }
    }

    /// The many-to-one view a human is shown: "these commits became this
    /// one". A squash lists several old oids against one new; a dropped
    /// commit appears in no replacement at all, because git omits it from
    /// the mapping entirely (measured — absence is the representation).
    public struct Replacement: Equatable, Sendable {
        public let newOid: String
        /// In the order rebase processed them, which githooks(5) guarantees.
        public let oldOids: [String]

        public init(newOid: String, oldOids: [String]) {
            self.newOid = newOid
            self.oldOids = oldOids
        }
    }

    /// What `parse` understood, and what it had to drop.
    public struct ParseResult: Equatable, Sendable {
        public let rewrites: [Rewrite]
        /// Lines without at least two non-empty fields. Counted rather than
        /// thrown: the handler must not fail, but must not pretend either.
        public let malformedLineCount: Int

        public init(rewrites: [Rewrite], malformedLineCount: Int) {
            self.rewrites = rewrites
            self.malformedLineCount = malformedLineCount
        }
    }

    /// The handler's verdict for one hook invocation.
    public struct Decision: Equatable, Sendable {
        /// Always 0 — see the type comment.
        public let exitCode: Int32
        /// What invoked the rewrite, from the hook's argument.
        public let source: Source
        /// Whether the invoking git command was run by `switchyard` itself
        /// (the environment marker, present and non-empty). Routing, not a
        /// skip: own mappings attach to the in-flight journal entry, foreign
        /// ones become observed entries.
        public let isOwnInvocation: Bool
        /// The mapping, in the order git listed it.
        public let rewrites: [Rewrite]
        /// Malformed stdin lines dropped while parsing.
        public let malformedLineCount: Int
    }

    /// Decides what one hook invocation carries.
    ///
    /// - Parameters:
    ///   - sourceArgument: the hook's single argument, verbatim.
    ///   - environment: the hook process's environment. Git propagates its
    ///     invoker's environment into the hook (measured), and `GitProcess`
    ///     sets `markerVariable` to `"1"` on every invocation, so
    ///     `switchyard`'s own rewrites are identifiable here. Present but
    ///     empty counts as foreign — the escape hatch tests use through
    ///     `GitProcess.extraEnvironment`, since the base environment always
    ///     carries the marker.
    ///   - markerVariable: the environment variable naming our own
    ///     invocations. Defaults to `GitProcess.markerVariable`.
    ///   - readStandardInput: called exactly once, whatever the source —
    ///     the mapping is wanted for own and foreign rewrites alike.
    public static func decide(
        sourceArgument: String,
        environment: [String: String],
        markerVariable: String = GitProcess.markerVariable,
        readStandardInput: () -> Data
    ) -> Decision {
        let marker = environment[markerVariable]
        let parsed = parse(readStandardInput())
        return Decision(
            exitCode: 0,
            source: Source(argument: sourceArgument),
            isOwnInvocation: marker.map { !$0.isEmpty } ?? false,
            rewrites: parsed.rewrites,
            malformedLineCount: parsed.malformedLineCount
        )
    }

    /// Parses hook stdin: `<old> SP <new> [ SP <extra-info> ] LF` per line.
    /// `maxSplits: 2` keeps a future extra-info field whole, including any
    /// spaces inside it. Decoding is lossy UTF-8 — the fields are hex object
    /// names, and a mangled extra-info in a record is recoverable where a
    /// crashed hook is not.
    public static func parse(_ input: Data) -> ParseResult {
        var rewrites: [Rewrite] = []
        var malformed = 0
        for line in input.split(separator: UInt8(ascii: "\n")) {
            let text = String(decoding: line, as: UTF8.self)
            let fields = text.split(
                separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                malformed += 1
                continue
            }
            rewrites.append(Rewrite(
                oldOid: String(fields[0]),
                newOid: String(fields[1]),
                extraInfo: fields.count == 3 ? String(fields[2]) : nil
            ))
        }
        return ParseResult(rewrites: rewrites, malformedLineCount: malformed)
    }

    /// Groups a mapping into its many-to-one view, preserving both the order
    /// in which new oids first appear and the order of the old oids within
    /// each group — the processing order git guarantees.
    public static func replacements(of rewrites: [Rewrite]) -> [Replacement] {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for rewrite in rewrites {
            if groups[rewrite.newOid] == nil { order.append(rewrite.newOid) }
            groups[rewrite.newOid, default: []].append(rewrite.oldOid)
        }
        return order.map { Replacement(newOid: $0, oldOids: groups[$0] ?? []) }
    }
}
