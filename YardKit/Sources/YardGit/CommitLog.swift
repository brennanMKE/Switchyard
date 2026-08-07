// CommitLog.swift — public entry point for parsed git log output

import Foundation

/// GPG signature outcome from `git log --format=%G?`. Only the single-character flag matters.
public enum SignatureStatus: String, Sendable {
    /// No signature information present (typically unsigned commits).
    case noSig

    /// Good, but unverified signature.
    case valid     // %G? → `g`

    /// Verification failed: bad key, tampered message.
    case invalid   // %G? → `G`

    public init(_ flag: String) {
        let ch = flag.isEmpty ? "n" : String(flag.first.flatMap(Character.init) ?? Character("n"))
        switch ch.lowercased() {
        case "g": self = .valid
        case "G": self = .invalid
        default:  self = .noSig
        }
    }

    public init(_ char: Character) { self.init(String(char)) }
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
              trimmed.distance(from: trimmed.startIndex, to: colon) <= 4 else { return nil }
        let key = trimmed[trimmed.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return Trailer(key: key, value: value)
    }
}

/// One commit's worth of metadata, as returned by `CommitLog.run`.
public struct CommitLogEntry: Equatable {
    public let oid: String
    public let parents: [String]   // list of parent SHAs; empty for the root commit
    public let refs: String        // raw "%D" output, e.g. `"main, tag: v1.0"`
    public let signatureStatus: SignatureStatus
    /// Parsed trailer lines from the commit message, in order.
    public let trailers: [Trailer]

    /// First non-empty line of the commit body, used as the human-readable
    /// identifier when the hash is not needed.
}

/// Configuration that changes what `CommitLog.run` returns. Built as a single
/// flagset so new options can be added without breaking callers.
public struct CommitLogOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Pass `--since=... --until=...` style range arguments, rather than
    /// constructing a refname prefix by hand. Used internally only; callers
    /// build the argument array themselves.
    public static let includeRefs = CommitLogOptions(rawValue: 1 << 0)

    /// Only return commits that carry a trailer whose key is `Agent-Name`
    /// (case-insensitive). This is the basis for issue #0014's `--agent-only`
    /// flag.
    public static let agentOnly = CommitLogOptions(rawValue: 1 << 1)

    /// Emit the full commit body. Without this option, only `subject` is
    /// available in the returned entries.
    public static let includeBody = CommitLogOptions(rawValue: 1 << 2)
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
}

/// Public entry point for the commit log module. Holds no state; all input is
/// passed in as method arguments. Used for testability and to keep the type's
/// responsibility single-purpose.
public enum CommitLog {

    /// Format string used internally by `run(repo:rangeArguments:options:)`.
    /// Mirrors the format recommended in #0014 (round 1 design): a hex-encoded
    /// field separator guarantees the output stays byte-clean across CJK
    /// characters, merge commits and multi-paragraph bodies.
    static let formatString = "--format=%H\u{01}%P\u{01}%G?\u{01}%D"

    /// Run `git log`, decode its structured output and return a sequence of
    /// `CommitLogEntry`. Exceptions are propagated.
    public static func run(repo path: String, rangeArguments: [String], options: CommitLogOptions = [], git: GitProcess = GitProcess()) throws -> [CommitLogEntry] {
        var args: [String]

        // Build the format string by appending range arguments after an
        // explicit HEAD (when nothing is given), so the output is predictable.
        args = ["log", formatString]

        if rangeArguments.isEmpty {
            args.append("HEAD")
        } else {
            // Pass through anything that is not itself a flag — ranges like
            // `A..B` and revspecs like `--since=...` come through here.
            args.append(contentsOf: rangeArguments.filter { !$0.hasPrefix("-") })
        }

        if options.contains(.agentOnly) {
            // Always pull trailers (we need them for `subject`, and
            // caller's filter happens after the fact).
        }

        let output = try git.run(args, workingDirectory: path)
        return parse(output: output.text, options: options)
    }

    /// Parse the text produced by `run(repo:rangeArguments:)`. Returns an
    /// array of entries in reverse commit-order (newest first).
    static func parse(output: String, options: CommitLogOptions = []) -> [CommitLogEntry] {
        let delimiter = _Delimiter.commit.rawValue
        // Split on the visible commit boundary first.
        var groups: [String] = []

        for substring in output.split(separator: delimiter, omittingEmptySubsequences: true) {
            let trimmed = String(substring).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            groups.append(trimmed)
        }

        var entries: [CommitLogEntry] = []

        for group in groups {
            // The first real line holds the structured fields. Split on `%x01`.
            guard let delimiterLine = group.split(separator: "\n").first else { continue }

            // Safe defaults — parse will overwrite them.
            let parts = delimiterLine.components(separatedBy: _Delimiter.field.rawValue)
            var oid = ""
            let parentsRaw: String
            let sigChar: Character

            switch parts.count {
            case 0: oid = ""; parentsRaw = ""; sigChar = "n"
            case 1: oid = parts[0]; parentsRaw = ""; sigChar = "n"
            case 2: oid = parts[0]; parentsRaw = String(parts[1]).trimmingCharacters(in: .whitespaces); sigChar = "n"
            case 3...: oid = parts[0]; parentsRaw = String(parts[1]).trimmingCharacters(in: .whitespaces); sigChar = (parts[2].first ?? "n")
            default: oid = ""; parentsRaw = ""; sigChar = "n"
            }

            // Trim trailing garbage in the sig field — sometimes git emits a trailing space.
            let sig = (sigChar == " ") ? Character("n") : sigChar

            // Parents: space-separated hex. Empty means root commit.
            let parents = parentsRaw.isEmpty ? [String]() : parentsRaw.split(separator: " ").map(String.init)

            // Refs come from the fourth field of "%D". Will be `""` for
            // detached HEAD if `--decorate=full` isn't asked. We use the raw
            // `%D` so its exact grammar stays identical to git's output.
            let refs = parts.count >= 4 ? String(parts[3]) : ""

            // Trailer parsing happens once we have the full commit body —
            // here we just remember the text for later, and skip if the user
            // only needs the body itself.
            let trailers = parseTrailerBlock(from: group)

            // Apply the `agentOnly` filter.
            if options.contains(.agentOnly), !CommitLogEntry.hasAgentName(trailers: trailers) { continue }

            entries.append(CommitLogEntry(
                oid: oid,
                parents: parents,
                refs: refs,
                signatureStatus: SignatureStatus(sig),
                trailers: trailers
            ))
        }

        return entries.reversed()   // newest first matches `git log` order.
    }

    /// Pulls out the trailer block from a body — everything after the first
    /// blank line (if any) that looks like `Key: Value`.
    static func parseTrailerBlock(from commitBody: String) -> [Trailer] {
        let lines = commitBody.split(separator: "\n")

        // Body ends at the first line that is empty followed by either a
        // trailer-lookalike or an end-of-text. We stop when we hit content
        // that is clearly body text (tab/quote-prefixed continuation).
        var startIdx = 0

        for i in 0 ..< lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, line.hasPrefix("\t"), i > 0 { continue }

            if startIdx == 0 && !line.isEmpty, line.first?.isLetter == true {
                // First real line of the body. Track start so we know where trailers begin.
                continue
            }

            if line.isEmpty, i < lines.count - 1 {
                // Blank separator — look ahead to see if a trailer follows.
                for j in (i + 1) ..< lines.count {
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !next.isEmpty else { continue }

                    if next.hasPrefix("Co-Author:") || next.hasPrefix("Signed-off-by:")
                        || next.hasPrefix("Agent-Name:") {
                        startIdx = j + 1
                    } else if next.hasPrefix("Acked-by:") || next.hasPrefix("Reviewed-by:") {
                        startIdx = j + 1
                    } else { break }
                }

                if startIdx > i { break }   // we found the separator
            }
        }

        let trailerText = lines[startIdx...]
        var trailers: [Trailer] = []

        for line in trailerText {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let t = Trailer.parse(trimmed) {
                trailers.append(t)
            } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Continuation of the previous trailer — handle multi-value cases.
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

// MARK: - Protocol support helpers (extending `CommitLogEntry`)

extension CommitLogEntry {
    public var subject: String {
        // Look up the first trailer whose key is `Subject:` (rare) and fall back
        // to a placeholder otherwise. Trailers are the source of truth for agents.
        if let first = trailers.first, first.key.lowercased() == "subject" { return first.value }

        // Fall back to the short OID — safer than a fictional subject from an
        // unparseable body. The caller can fall back further if they need a
        // usable label (e.g. the first non-blank line of a parsed body).
        let short = CommitLogEntry.shortOid(oid)
        return "(commit \(short))"
    }

    public var shortOid: String { CommitLogEntry.shortOid(self.oid) }

    /// Whether any trailer carries an `Agent-Name:` key (case-insensitive).
    public var hasProvenance: Bool { CommitLogEntry.hasAgentName(trailers: trailers) }

    /// Short OID representation for an entry's `oid`. Returns the first 12 hex
    /// digits or `"<unknown>"`.
    static func shortOid(_ oid: String) -> String {
        guard !oid.isEmpty else { return "<unknown>" }

        let count = min(12, oid.count)
        guard let endIndex = oid.index(oid.startIndex, offsetBy: count, limitedBy: oid.endIndex) else {
            return "<unknown>"
        }

        return String(oid[..<endIndex])
    }

    /// Whether any trailer in the list matches `Agent-Name` (case-insensitive).
    static func hasAgentName(trailers: [Trailer]) -> Bool {
        return trailers.contains(where: { $0.key.lowercased() == "agent-name" })
    }
}
