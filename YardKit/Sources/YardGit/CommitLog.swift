// CommitLog.swift — public entry point for parsed git log output

import Foundation

/// GPG signature outcome from `git log --format=%G?`. Only the single-character flag matters.
public enum SignatureStatus: String, Sendable {
    /// No signature information present (typically unsigned commits).
    case noSig

    /// Good, but unverified signature.
    case valid     // %G? -> `g`

    /// Verification failed: bad key, tampered message.
    case invalid   // %G? -> `G`

    public init(_ flag: String) {
        let ch = flag.isEmpty ? "n" : String(flag.first.flatMap(Character.init) ?? Character("n"))
        switch ch {
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
        args = ["log", "--format=\(fmt)"]

        if rangeArguments.isEmpty {
            args.append("HEAD")
        } else {
            // Pass through anything that is not itself a flag -- ranges like
            // `A..B` and revspecs like `--since=...` come through here.
            args.append(contentsOf: rangeArguments.filter { !$0.hasPrefix("-") })
        }

        let output = try git.run(args, workingDirectory: path)
        var entries = parse(output: output.text, options: options)

        if options.contains(.agentOnly) {
            entries = entries.filter { $0.hasAgentName }
        }

        return entries.reversed()   // newest first matches `git log` order.
    }

    /// Parse the text produced by `run(path:rangeArguments:)`. Returns an
    /// array of entries in reverse commit-order (newest first).
    static func parse(output: String, options: CommitLogOptions = []) -> [CommitLogEntry] {
        var entries: [CommitLogEntry] = []

        // Split on NUL first -- each non-empty piece is one commit record.
        let records = output.split(separator: "\u{0}", omittingEmptySubsequences: false)

        for record in records {
            let trimmed = String(record).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Split each record on SOH into fields. The body (last field)
            // may contain newlines and anything except NUL, so split with
            // limit 6 so the trailing field gets everything after the 5th separator.
            let parts = trimmed.split(separator: "\u{01}", omittingEmptySubsequences: false)

            guard parts.count >= 5 else { continue }

            let oid = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !oid.isEmpty else { continue }

            let parentsRaw = String(parts[1]).trimmingCharacters(in: .whitespaces)
            let author = String(parts[2])
            let sigFlag = String(parts[3]).trimmingCharacters(in: .whitespaces)
            let refs = String(parts[4])

            // The body is everything after the 5th SOH. `git log --format=%B`
            // emits newlines literally, so the body arrives as one string with
            // actual \n chars in it. We only need to guard against the empty
            // case (i.e., no body at all), but since we split with
            // `omittingEmptySubsequences: false`, an empty body yields a single
            // empty string at parts[5], which is exactly what we want.
            let message = parts.count > 5 ? String(parts[5]) : ""

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

    /// Pulls out the trailer block from a body -- everything after the first
    /// blank line (if any) that looks like `Key: Value`.
    static func parseTrailerBlock(from commitBody: String) -> [Trailer] {
        let lines = commitBody.split(separator: "\n", omittingEmptySubsequences: false)

        // Find the first blank-line separator between body and trailers.
        var separatorIndex: Int? = nil
        for i in 0 ..< lines.count - 1 {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // Look ahead -- is the next non-blank line a trailer?
                for j in (i + 1) ..< lines.count {
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty { continue }
                    // A trailer starts at word boundary, no leading whitespace.
                    if next.first?.isWhitespace == false && next.firstIndex(of: ":") != nil {
                        separatorIndex = i
                    }
                    break
                }
                if separatorIndex != nil { break }
            }
        }

        let startIdx = max(separatorIndex.map { $0 + 1 } ?? lines.count, 0)
        var trailers: [Trailer] = []

        for i in startIdx ..< lines.count {
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

// MARK: - Convenience for parse output in tests

extension CommitLog {
    /// Parse output without range filtering. Exposed for testability; production code uses `run(path:rangeArguments:)`.
    static func parseClean(output: String) -> [CommitLogEntry] {
        return CommitLog.parse(output: output, options: [])
    }
}

