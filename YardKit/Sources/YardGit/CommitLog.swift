// CommitLog.swift — public entry point for parsed git log output

import Foundation

/// Signature outcome from `git log --format=%G?`, one case per flag character
/// git documents (git's own source emits exactly `G U B X Y R E N`, all
/// uppercase — gpg-interface.c and pretty.c:1666).
public enum SignatureStatus: Sendable {
    /// `%G?` -> `N`: no signature.
    case noSig

    /// `%G?` -> `G`: good (valid) signature.
    case good

    /// `%G?` -> `U`: good signature with unknown validity.
    case goodUntrusted

    /// `%G?` -> `B`: bad signature.
    case bad

    /// `%G?` -> `X`: good signature that has expired.
    case expiredSignature

    /// `%G?` -> `Y`: good signature made by an expired key.
    case expiredKey

    /// `%G?` -> `R`: good signature made by a revoked key.
    case revokedKey

    /// `%G?` -> `E`: the signature cannot be checked (e.g. missing key).
    case cannotCheck

    /// Anything git does not document, including an empty field. Git never
    /// emits lowercase characters, so the old mapping's `g` lands here.
    case unknown

    public init(_ char: Character) {
        switch char {
        case "G": self = .good
        case "U": self = .goodUntrusted
        case "B": self = .bad
        case "X": self = .expiredSignature
        case "Y": self = .expiredKey
        case "R": self = .revokedKey
        case "E": self = .cannotCheck
        case "N": self = .noSig
        default:  self = .unknown
        }
    }

    public init(_ flag: String) {
        guard let ch = flag.first else {
            self = .unknown
            return
        }
        self.init(ch)
    }
}

/// A trailer line, `Key: Value`.
public struct Trailer: Equatable, CustomStringConvertible, Sendable {
    public let key: String
    public var value: String

    public var description: String { "\(key): \(value)" }

    /// Parse one trailer line. Returns `nil` if the text is a comment, an
    /// indented continuation of a body paragraph, or otherwise malformed.
    public static func parse(_ line: String) -> Trailer? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.first != "#", trimmed.first != "\t" else { return nil }
        guard let colon = trimmed.firstIndex(of: ":"),
              !trimmed[trimmed.startIndex..<colon].contains(where: \.isWhitespace) else { return nil }
        let key = trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return Trailer(key: key, value: value)
    }
}

/// One commit's worth of metadata, as returned by `CommitLog.run`.
public struct CommitLogEntry: Equatable {
    public let oid: String
    public let parents: [String]   // list of parent SHAs; empty for the root commit
    public let author: String      // `%an` output (raw)
    public let refs: String        // raw "%D" output, e.g. `"main, tag: v1.0"`
    public let signatureStatus: SignatureStatus
    public let message: String     // the full commit body, verbatim (first non-empty line = subject)
    /// Parsed trailer lines from the commit message, in order.
    public let trailers: [Trailer]

    /// Public memberwise initializer (#0133). Declaring it replaces the
    /// compiler-provided memberwise init, which is internal — the wire tests
    /// construct entries from a non-`@testable` import, the same way any
    /// public caller would (#0116 failure class).
    public init(
        oid: String,
        parents: [String],
        author: String,
        refs: String,
        signatureStatus: SignatureStatus,
        message: String,
        trailers: [Trailer]
    ) {
        self.oid = oid
        self.parents = parents
        self.author = author
        self.refs = refs
        self.signatureStatus = signatureStatus
        self.message = message
        self.trailers = trailers
    }
}

/// Configuration that changes what `CommitLog.run` returns. Built as a single
/// flagset so new options can be added without breaking callers.
public struct CommitLogOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Only return commits that carry a trailer whose key is `Agent-Name`
    /// (case-insensitive). This is the basis for issue #0014's `--agent-only`
    /// flag. This is the only option `run`/`parse` ever read (#0290).
    public static let agentOnly = CommitLogOptions(rawValue: 1 << 1)
}

/// Internal symbol for `git log --format` delimiters. Used by the parser but
/// not exposed in public API surface.
enum _Delimiter: String {
    /// Record separator between field groups (commit header, body, trailers).
    case commit = "\n\n"

    /// Field separator inside a single-format line, matching git's `%x01`.
    case field = "\u{01}"   // SOH, same as git's %x01

    /// Footer sent to the next parser call.
    case footer = "\n"

    /// NUL record terminator so multi-record output stays unambiguous.
    case recordEnd = "\u{0}"
}

/// Public entry point for the commit log module. Holds no state; all input is
/// passed in as method arguments. Used for testability and to keep the type's
/// responsibility single-purpose.
public enum CommitLog {

    /// Format string used internally by `run(path:rangeArguments:options:)`.
    /// Mirrors the format recommended in #0014 (round 1 design): a hex-encoded
    /// field separator guarantees the output stays byte-clean across CJK
    /// characters, merge commits and multi-paragraph bodies. The trailing
    /// `%B%x00` keeps the body verbatim (newlines and blank lines preserved)
    /// and terminates each record with NUL so the parser can split reliably.
    static let formatString = "--format=%H\u{01}%P\u{01}%an\u{01}%G?\u{01}%D\u{01}%B%x00"

    /// Run `git log`, decode its structured output and return a sequence of
    /// `CommitLogEntry`. Exceptions are propagated.
    public static func run(path: String, rangeArguments: [String], options: CommitLogOptions = [], git: GitProcess = GitProcess()) throws -> [CommitLogEntry] {
        var args: [String]

        // Build the format string by appending range arguments after an
        // explicit HEAD (when nothing is given), so the output is predictable.
        let fmt = String(formatString.dropFirst("--format=".count))
        //
        // `%D` (the `refs` field below) obeys `log.excludeDecoration`, so a repo
        // with e.g. `log.excludeDecoration = refs/tags/*` silently drops tags
        // from `CommitLogEntry.refs` (#0320). `-c log.excludeDecoration=` was
        // assumed to neutralise this but does not: measured on git 2.50.1, an
        // empty-value override does not clear the exclude list, it *adds* an
        // empty pattern to it, which drops every decoration -- `HEAD -> main`
        // reduces to bare `HEAD`, worse than doing nothing.
        //
        // The form that actually works is an explicit `--decorate-refs`
        // pattern, which the man page documents as overriding a
        // `log.excludeDecoration` match. It must list git's own default
        // candidate set (`HEAD`, `refs/heads/`, `refs/remotes/`, `refs/stash`,
        // `refs/tags/`) one prefix at a time rather than the blanket
        // `refs/*` first tried: passing *any* `--decorate-refs` switches git
        // from "default candidate set" mode to "explicit accept-list over all
        // refs" mode -- measured directly, `refs/*` alone reproduced the
        // default output for `main`/`tag: v1` but also decorated Switchyard's
        // own journal anchor refs (`ServiceNames.journalRefPrefix`), which
        // `commitLogDecorationsNeverCarryJournalRefs`
        // (LaneAssignmentTests.swift) pins must never surface. The five
        // explicit prefixes below reproduce the default candidate set
        // byte-for-byte (measured, both with and without
        // `log.excludeDecoration` set) without widening it.
        let decorateRefs = [
            "--decorate-refs=HEAD",
            "--decorate-refs=refs/heads/*",
            "--decorate-refs=refs/remotes/*",
            "--decorate-refs=refs/stash",
            "--decorate-refs=refs/tags/*",
        ]
        // `log.showSignature = true` prepends a human-readable verification
        // line ("Good \"git\" signature for ...") ahead of the requested
        // `--format` output, even with a custom `--format` -- measured
        // 2026-08-18 against a real SSH-signed commit. Without
        // `--no-show-signature`, `oid` below becomes that prose sentence
        // instead of the 40-hex commit id, which is a wire payload field an
        // agent feeds straight back to git (#0325).
        //
        // `i18n.logOutputEncoding` re-encodes `%B`/`%an` out of UTF-8 (default
        // ISO-8859-1 when set), and `GitProcess.Output.text` decodes stdout as
        // UTF-8 lossily rather than failing -- measured 2026-08-18: a non-ASCII
        // subject under that config comes back with U+FFFD replacement
        // characters instead of its real bytes. A `schemaVersion: 1` envelope
        // is UTF-8 by definition, so `--encoding=UTF-8` pins git's output to
        // UTF-8 regardless of `i18n.logOutputEncoding` (#0326).
        args = ["log"] + decorateRefs + ["--no-show-signature", "--encoding=UTF-8", "--format=\(fmt)"]

        if rangeArguments.isEmpty {
            args.append("HEAD")
        } else {
            // Pass everything through. Filtering out anything starting with `-`
            // silently discarded `-1`, `--max-count`, `--since` and `--author`,
            // so a caller asking for one commit got the whole history.
            args.append(contentsOf: rangeArguments)
        }

        let output = try git.run(args, workingDirectory: path)
        let entries = parse(output: output.text, options: options)

        // `agentOnly` is applied once, inside `parse`'s loop (see the comment
        // there) -- a second pass here used to re-check the identical value:
        // `parse` builds each `CommitLogEntry.trailers` from the very same
        // `trailers` array the in-loop filter tests, with no transformation
        // in between, and `parse` is the only site that ever appends to
        // `entries`. The two checks could never disagree, so re-filtering
        // here was dead weight -- see #0302.
        //
        // `git log` already emits newest-first and `parse` preserves that order,
        // so returning it unchanged is what matches the comment. Reversing here
        // made the array oldest-first and broke eight assertions.
        return entries
    }

    /// Parse the text produced by `run(path:rangeArguments:)`. Returns an
    /// array of entries in reverse commit-order (newest first).
    static func parse(output: String, options: CommitLogOptions = []) -> [CommitLogEntry] {
        var entries: [CommitLogEntry] = []

        // Split on NUL first -- each non-empty piece is one commit record.
        let records = output.split(separator: "\u{0}", omittingEmptySubsequences: false)

        for record in records {
            // `git log` writes `<record>\n\0\n` -- the trailing newline of %B,
            // then the %x00 from the format string, then its own separator
            // newline between entries. Splitting on NUL therefore leaves every
            // record after the first beginning with that separator, which is not
            // part of the record. Drop exactly one.
            //
            // The old record-level trimmingCharacters(.whitespacesAndNewlines)
            // removed it -- and also ate %B's trailing newline, which is the bug
            // this change exists to fix. One line was doing both jobs.
            var text = String(record)
            if text.hasPrefix("\n") { text = String(text.dropFirst()) }
            guard text.contains("\u{01}") else { continue }

            // Split each record on SOH into fields. The body is the last field
            // and may contain newlines, and SOH itself -- so this split can
            // produce more than six parts, and the body is rejoined below.
            let parts = text.split(separator: "\u{01}", omittingEmptySubsequences: false)

            guard parts.count >= 5 else { continue }

            let oid = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !oid.isEmpty else { continue }

            let parentsRaw = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let author = String(parts[2])
            let sigFlag = String(parts[3]).trimmingCharacters(in: .whitespaces)
            let refs = String(parts[4])

            // The body is everything after the 5th SOH. `git log --format=%B`
            // emits newlines literally, so the body arrives as one string with
            // actual \n chars in it. Since the format ends with `%B%x00` and
            // `%B` is the last field, joining parts[5...] with SOH preserves any
            // embedded delimiters in the body verbatim. When only five fields
            // are present there is no trailing field and the message is empty.
            let message = parts.count > 5 ? parts[5...].joined(separator: "\u{01}") : ""

            // Parents: space-separated hex. Empty means root commit.
            let parents = parentsRaw.isEmpty ? [String]() : parentsRaw.split(separator: " ").map(String.init)

            // Trailer parsing happens once we have the full commit body.
            let trailers = parseTrailerBlock(from: message)

            // Apply the `agentOnly` filter inside the loop so we skip early.
            if options.contains(.agentOnly), !CommitLogEntry.hasAgentName(trailers: trailers) { continue }

            entries.append(CommitLogEntry(
                oid: oid,
                parents: parents,
                author: author,
                refs: refs,
                signatureStatus: SignatureStatus(sigFlag),
                message: message,
                trailers: trailers
            ))
        }

        return entries
    }

    /// Pulls out the trailer block from a body. Git's rule (`git help
    /// interpret-trailers`) is that the trailer block is the commit's
    /// **last** paragraph -- the run of non-blank lines ending the body,
    /// preceded by one or more blank lines -- not merely the first paragraph
    /// that happens to look trailer-shaped (#0313: a colon-shaped prose
    /// paragraph earlier in the body must not be mistaken for the block and
    /// must not hide a real trailer block that follows it).
    static func parseTrailerBlock(from commitBody: String) -> [Trailer] {
        let lines = commitBody.split(separator: "\n", omittingEmptySubsequences: false)

        func isBlank(_ line: Substring) -> Bool {
            line.trimmingCharacters(in: .whitespaces).isEmpty
        }

        // `%B` commonly ends with its own trailing newline, which
        // `split(omittingEmptySubsequences: false)` turns into a trailing
        // empty element that belongs to no paragraph. Trim it before looking
        // for the last paragraph.
        var end = lines.count
        while end > 0, isBlank(lines[end - 1]) { end -= 1 }
        guard end > 0 else { return [] }

        // Walk backward from the end of the (trimmed) body to the start of
        // its last paragraph -- the run of non-blank lines up to `end`.
        var startIdx = end
        while startIdx > 0, !isBlank(lines[startIdx - 1]) { startIdx -= 1 }

        // Git's rule requires the group to be "preceded by one or more empty
        // lines". `startIdx == 0` means the whole body is one paragraph with
        // no blank line anywhere before it -- not a trailer block.
        guard startIdx > 0 else { return [] }

        var trailers: [Trailer] = []

        for i in startIdx ..< end {
            let trimmed = String(lines[i]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let t = Trailer.parse(trimmed) {
                trailers.append(t)
            } else if trimmed.first?.isWhitespace == true {
                // Continuation of the previous trailer -- handle multi-value cases.
                if var last = trailers.popLast() {
                    // Append the continuation as a space-prefixed suffix, since git
                    // uses `" value"` to extend trailers.
                    last.value = "\(last.value) \(trimmed)"
                    trailers.append(last)
                }
            } else { break }   // body or something else; stop parsing trailers.
        }

        return trailers
    }
}

// MARK: - Convenience helpers (extending `CommitLogEntry`)

extension CommitLogEntry {
    /// First non-empty line of the commit message, used as the human-readable
    /// identifier when the hash is not needed.
    public var subject: String {
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(commit \(shortOid))"
            : firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short OID representation for an entry's `oid`. Returns the first 12 hex
    /// digits or `"<unknown>"`.
    public var shortOid: String { Self.shortOid(oid) }

    /// Whether any trailer carries an `Agent-Name:` key (case-insensitive).
    public var hasProvenance: Bool { CommitLogEntry.hasAgentName(trailers: trailers) }

    /// Whether any trailer in the list matches `Agent-Name` (case-insensitive).
    internal var hasAgentName: Bool { CommitLogEntry.hasAgentName(trailers: trailers) }

    /// Short OID representation for an entry's `oid`. Returns the first 12 hex
    /// digits or `"<unknown>"`.
    public static func shortOid(_ oid: String) -> String {
        guard !oid.isEmpty else { return "<unknown>" }

        let count = min(12, oid.count)
        guard let endIndex = oid.index(oid.startIndex, offsetBy: count, limitedBy: oid.endIndex) else {
            return "<unknown>"
        }

        return String(oid[..<endIndex])
    }

    /// Whether any trailer in the list matches `Agent-Name` (case-insensitive).
    public static func hasAgentName(trailers: [Trailer]) -> Bool {
        return trailers.contains(where: { $0.key.lowercased() == "agent-name" })
    }
}

// MARK: - Wire encoding (#0133)

/// `SignatureStatus` has no raw type (#0127) and no associated values, so its
/// wire form is a **declared** case-name string (#0129 Decision 5, middle
/// clause) — a single JSON string per case, written by an explicit
/// `encode(to:)`. Synthesis would NOT produce this: SE-0295 synthesis for a
/// payload-free enum encodes `{"good":{}}`, an object, not `"good"`.
extension SignatureStatus: Encodable {
    /// The stable wire vocabulary, one literal per case. Renaming a case is a
    /// compile error at this switch while the literal — the wire string —
    /// stays put; `LogGraphWireTests` pins all nine. Never replace this with
    /// `String(describing: self)`: that derives the string from the case name
    /// and a rename would silently change the wire.
    private var wireName: String {
        switch self {
        case .noSig: "noSig"
        case .good: "good"
        case .goodUntrusted: "goodUntrusted"
        case .bad: "bad"
        case .expiredSignature: "expiredSignature"
        case .expiredKey: "expiredKey"
        case .revokedKey: "revokedKey"
        case .cannotCheck: "cannotCheck"
        case .unknown: "unknown"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireName)
    }
}

/// A trailer rides the wire as `{"key":…,"value":…}`. The computed
/// `description` is not encoded (#0129 Decision 7).
extension Trailer: Encodable {
    /// Stable wire keys, identical to the member names; no raw values.
    private enum CodingKeys: String, CodingKey {
        case key, value
    }
}

/// `CommitLogEntry` is a `schemaVersion: 1` payload: it encodes through
/// `YardKit`'s `Envelope` via `EncodableResult` (`Encodable & Sendable`).
/// Plain-stdlib `Encodable` — the engine still imports nothing. `Sendable` is
/// added here too: public structs get no implicit `Sendable` across module
/// boundaries, and `EncodableResult`'s bound needs it.
extension CommitLogEntry: Encodable, Sendable {
    /// Stable wire keys, identical to the stored-member names; no raw values.
    /// The computed `subject` / `shortOid` / `hasProvenance` are not encoded
    /// (#0129 Decision 7) — all three are derivable from `message`, `oid`,
    /// and `trailers`. The enum is rename-safety; `LogGraphWireTests` pins
    /// the bytes.
    private enum CodingKeys: String, CodingKey {
        case oid, parents, author, refs, signatureStatus, message, trailers
    }
}

