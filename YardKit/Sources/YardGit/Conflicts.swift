// Conflicts.swift — conflicted paths with per-stage blob ids (#0017)

import Foundation

/// One conflicted path in the index, with the blob id and mode of every
/// index stage that exists for it.
///
/// Backed by the `u` records of `git status --porcelain=v2 -z`, which carry
/// the conflict kind, the three stage modes, and the three stage oids in a
/// single NUL-terminated record per path — one record per conflicted file,
/// however many stages it has.
public struct ConflictedFile: Sendable, Equatable {

    /// A blob id and file mode for one index stage.
    public struct StageEntry: Sendable, Equatable {
        /// Full object id of the blob, as git printed it.
        public let oid: String
        /// Octal mode string as git printed it, e.g. `"100644"`.
        public let mode: String

        public init(oid: String, mode: String) {
            self.oid = oid
            self.mode = mode
        }
    }

    /// How the two sides collided — the XY pair of the porcelain v2 `u`
    /// record. These seven values are the complete vocabulary git emits;
    /// there is no rename kind, because a rename conflict surfaces as
    /// add/delete/modify records at the paths involved.
    public enum Kind: String, Sendable, CaseIterable {
        case bothModified  = "UU"
        case bothAdded     = "AA"
        case bothDeleted   = "DD"
        case addedByUs     = "AU"
        case addedByThem   = "UA"
        case deletedByUs   = "DU"
        case deletedByThem = "UD"
    }

    /// Path relative to the repository root, decoded lossily as UTF-8.
    public let path: String

    /// Raw bytes of the path, losslessly preserved.
    public let pathBytes: [UInt8]

    public let kind: Kind

    /// Stage 1 — the merge base. Nil when that side has no entry, e.g. an
    /// add/add conflict.
    public let base: StageEntry?

    /// Stage 2 — ours. Nil when that side has no entry, e.g. deleted by us.
    /// During a rebase, git's "ours" is the side being rebased **onto**.
    public let ours: StageEntry?

    /// Stage 3 — theirs. Nil when that side has no entry.
    public let theirs: StageEntry?

    public init(path: String,
                pathBytes: [UInt8],
                kind: Kind,
                base: StageEntry?,
                ours: StageEntry?,
                theirs: StageEntry?) {
        self.path = path
        self.pathBytes = pathBytes
        self.kind = kind
        self.base = base
        self.ours = ours
        self.theirs = theirs
    }
}

/// Parses the `u` records out of `git status --porcelain=v2 -z` bytes.
///
/// Pure function on data — no `Process` construction, no filesystem access.
/// Records other than `u` are skipped. A malformed `u` record throws rather
/// than being dropped: silently losing a conflict is a correctness bug, not
/// a simplification.
public struct ConflictParser {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A `u` record had fewer than its ten fixed tokens, or no path.
        case truncatedRecord(String)
        /// A `u` record's XY pair was none of the seven git emits.
        case unrecognizedKind(xy: String, path: String)

        public var description: String {
            switch self {
            case let .truncatedRecord(record):
                "malformed porcelain v2 u record: \(record)"
            case let .unrecognizedKind(xy, path):
                "unrecognized conflict kind \"\(xy)\" for \(path)"
            }
        }
    }

    public init() {}

    public func parse(_ data: Data) throws -> [ConflictedFile] {
        var files: [ConflictedFile] = []
        for record in Self.records(data) {
            guard record.first == UInt8(ascii: "u") else { continue }

            // Fixed layout: `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3>
            // <path>` — ten space-delimited tokens including the tag, then
            // the path, which may itself contain spaces and is therefore
            // everything after the tenth space rather than a split token.
            var tokens: [String] = []
            var rest = record[record.startIndex...]
            for _ in 0..<10 {
                guard let space = rest.firstIndex(of: 0x20) else {
                    throw Failure.truncatedRecord(String(decoding: record, as: UTF8.self))
                }
                tokens.append(String(decoding: rest[..<space], as: UTF8.self))
                rest = rest[rest.index(after: space)...]
            }
            let pathBytes = Array(rest)
            guard !pathBytes.isEmpty else {
                throw Failure.truncatedRecord(String(decoding: record, as: UTF8.self))
            }
            let path = String(decoding: pathBytes, as: UTF8.self)

            guard let kind = ConflictedFile.Kind(rawValue: tokens[1]) else {
                throw Failure.unrecognizedKind(xy: tokens[1], path: path)
            }

            // Mode 000000 (equivalently the zero oid) means the side has no
            // stage entry — delete/modify has no ours, add/add no base.
            func stage(mode: Int, oid: Int) -> ConflictedFile.StageEntry? {
                guard tokens[mode] != "000000" else { return nil }
                return ConflictedFile.StageEntry(oid: tokens[oid], mode: tokens[mode])
            }

            files.append(ConflictedFile(
                path: path,
                pathBytes: pathBytes,
                kind: kind,
                base:   stage(mode: 3, oid: 7),
                ours:   stage(mode: 4, oid: 8),
                theirs: stage(mode: 5, oid: 9)))
        }
        return files
    }

    /// Splits porcelain v2 `-z` bytes into records. A `2` (rename) record
    /// carries a second NUL-terminated field — the original path — which is
    /// consumed with its record here, so a path that happens to begin with
    /// `u ` is never scanned as a record of its own.
    static func records(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var records: [[UInt8]] = []
        var i = 0
        while i < bytes.count {
            var end = i
            while end < bytes.count, bytes[end] != 0x00 { end += 1 }
            let record = Array(bytes[i..<end])
            i = end + 1
            guard !record.isEmpty else { continue }
            records.append(record)
            if record.first == UInt8(ascii: "2") {
                var skip = i
                while skip < bytes.count, bytes[skip] != 0x00 { skip += 1 }
                i = skip + 1
            }
        }
        return records
    }
}

/// Reports every conflicted path in the repository at `path`, in the order
/// git emits them (sorted by path). Empty when the index has no unmerged
/// entries. Works identically during a merge, a rebase, and a cherry-pick —
/// unmerged index stages are the same mechanism in all three.
public func conflictedFiles(
    at path: String,
    git: GitProcess = GitProcess()
) throws -> [ConflictedFile] {
    let output = try git.run(
        ["status", "--porcelain=v2", "-z"],
        workingDirectory: path
    )
    return try ConflictParser().parse(output.standardOutput)
}
