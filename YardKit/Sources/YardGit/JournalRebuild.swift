// JournalRebuild.swift — the journal, recovered from the repository alone (#0030)

import Foundation

/// Rebuilds the journal from the anchor refs (`JournalAnchor.refPrefix`)
/// and the object database, reading nothing else — no `journal.json`, no
/// state directory, no cache of any kind. This is the path that keeps the
/// design honest about which store is authoritative: #0028 puts every
/// entry's metadata inside the anchored snapshot commit itself, so the
/// repository always suffices and everything outside it is derived.
///
/// Two subprocesses recover the whole journal, however many entries exist:
/// one `for-each-ref` over the anchor namespace, then one `cat-file --batch`
/// resolving `<commit>:metadata.json` for every anchor. Per-entry `cat-file`
/// spawns were measured at ~20ms each — 1.0s for a 50-entry journal against
/// 0.04s for the batch — so batching is load-bearing, not a nicety.
///
/// Rebuild is the disaster-recovery path, and that dictates its failure
/// policy: **an unrecoverable entry is skipped and reported, never fatal.**
/// `JournalAnchor.list` throws on a foreign ref in the namespace because in
/// normal operation that means state confusion; rebuild instead records it
/// as a `Defect` and recovers everything else, because a recovery that dies
/// on the first oddity recovers nothing. The defect list is how an agent
/// knows it got a partial journal rather than a complete one.
///
/// **Observed entries are out of scope, deliberately** (#0190, guide §11
/// decision 12). They live in `JournalObserved.refPrefix`, outside the
/// namespace this scans, because they are a record of *foreign* ref activity
/// and never undo targets. Rebuild reconstructs the chain; they are not on
/// it. Widening the scan to all of `refs/switchyard/` would report every one
/// of them as a `Defect` — a healthy repository declaring itself partial,
/// once per foreign transaction.
public enum JournalRebuild {

    /// One journal entry as recovered from the repository: its id, the
    /// snapshot commit its anchor points at, and the entry's metadata bytes
    /// exactly as `JournalAnchor.write` stored them. Decoding the bytes is
    /// the metadata shape's job (#0155); rebuild returns them verbatim so
    /// recovery never destroys evidence it merely failed to parse.
    public struct RecoveredEntry: Sendable, Equatable {
        public let id: JournalEntryID
        public let commit: String
        public let metadataJSON: Data

        public init(id: JournalEntryID, commit: String, metadataJSON: Data) {
            self.id = id
            self.commit = commit
            self.metadataJSON = metadataJSON
        }
    }

    /// An anchor that could not be recovered, with why. Reported, not
    /// thrown: the caller decides whether a partial journal is acceptable,
    /// and an agent-facing listing (#0034) surfaces these rather than
    /// inventing defaults for what is missing.
    public enum Defect: Sendable, Equatable, CustomStringConvertible {
        /// A ref in the journal namespace whose last component is not a
        /// valid entry id. `JournalAnchor.list` throws on this; rebuild
        /// reports it and keeps going.
        case foreignRef(name: String)
        /// The anchor's commit object does not exist in the object
        /// database. `for-each-ref` lists dangling refs without complaint
        /// (measured, both ref formats), so this surfaces only when the
        /// entry's content is actually fetched.
        case missingSnapshotCommit(id: JournalEntryID, commit: String)
        /// The anchor points at an object that is not a commit at all.
        case anchorNotACommit(id: JournalEntryID, oid: String, type: String)
        /// The snapshot commit exists but carries no `metadata.json` blob
        /// in its tree.
        case missingMetadata(id: JournalEntryID, commit: String)

        public var description: String {
            switch self {
            case let .foreignRef(name):
                "ref in the journal namespace is not a journal entry: \(name)"
            case let .missingSnapshotCommit(id, commit):
                "journal entry \(id): snapshot commit \(commit) is missing from the object database"
            case let .anchorNotACommit(id, oid, type):
                "journal entry \(id): anchor points at a \(type) (\(oid)), not a snapshot commit"
            case let .missingMetadata(id, commit):
                "journal entry \(id): snapshot commit \(commit) has no metadata.json blob"
            }
        }
    }

    /// What a rebuild found: every recoverable entry, oldest first, plus a
    /// defect per anchor that could not be recovered. `defects` empty means
    /// the journal was rebuilt in full.
    public struct Result: Sendable, Equatable {
        public let entries: [RecoveredEntry]
        public let defects: [Defect]

        public init(entries: [RecoveredEntry], defects: [Defect]) {
            self.entries = entries
            self.defects = defects
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        /// A plumbing command produced output this git should not produce —
        /// not a bad entry (those are `Defect`s) but the plumbing itself
        /// misbehaving, which no amount of skipping can recover from.
        case malformedPlumbingOutput(command: String, detail: String)

        public var description: String {
            switch self {
            case let .malformedPlumbingOutput(command, detail):
                "unparseable \(command) output: \(detail)"
            }
        }
    }

    // MARK: - Rebuild

    /// Recovers every journal entry from the repository alone.
    ///
    /// Anchor refs are shared, so the result is the same from any worktree;
    /// a bare repository (including a `--mirror` clone, the one clone shape
    /// that carries anchors) works identically.
    public static func rebuild(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> Result {
        let base = context.topLevel ?? context.gitDir

        // Same command and format as `JournalAnchor.list`, different failure
        // policy — list halts on a foreign ref, recovery must not.
        let listing = try git.run(
            ["for-each-ref", "--format=%(objectname) %(refname)", JournalAnchor.refPrefix],
            workingDirectory: base)

        var anchors: [(id: JournalEntryID, oid: String)] = []
        var defects: [Defect] = []
        for line in listing.lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw Error.malformedPlumbingOutput(command: "for-each-ref", detail: line)
            }
            let name = String(fields[1])
            guard name.hasPrefix(JournalAnchor.refPrefix),
                  let id = JournalEntryID(String(name.dropFirst(JournalAnchor.refPrefix.count)))
            else {
                defects.append(.foreignRef(name: name))
                continue
            }
            anchors.append((id: id, oid: String(fields[0])))
        }
        guard !anchors.isEmpty else {
            return Result(entries: [], defects: defects)
        }

        // One batch resolves every entry's metadata blob. Requests go by the
        // commit OID `for-each-ref` just reported, not by ref name, so the
        // ref backend is consulted exactly once. Responses come back in
        // request order; a request that cannot resolve — commit gone, anchor
        // not a commit, tree without the entry — is `<request> missing`
        // (all three shapes measured), classified afterwards at one or two
        // extra subprocesses per defect, which are rare by construction.
        let requests = anchors
            .map { "\($0.oid):\(JournalAnchor.metadataTreeEntryName)\n" }
            .joined()
        let batch = try git.run(["cat-file", "--batch"], workingDirectory: base,
                                standardInput: Data(requests.utf8))

        var entries: [RecoveredEntry] = []
        var cursor = batch.standardOutput.startIndex
        for anchor in anchors {
            switch try nextBatchResponse(in: batch.standardOutput, from: &cursor) {
            case .missing:
                defects.append(try classify(anchor, at: base, git: git))
            case let .object(type: "blob", content: content):
                entries.append(RecoveredEntry(
                    id: anchor.id, commit: anchor.oid, metadataJSON: content))
            case .object:
                // metadata.json resolved to a tree or something else odd —
                // there is no metadata *blob* to recover.
                defects.append(.missingMetadata(id: anchor.id, commit: anchor.oid))
            }
        }
        return Result(entries: entries, defects: defects)
    }

    // MARK: - Batch output

    private enum BatchResponse {
        case missing
        case object(type: String, content: Data)
    }

    /// Parses the next `cat-file --batch` response at `cursor`, advancing it.
    ///
    /// Measured framing, both ref formats: a resolvable request answers
    /// `<oid> SP <type> SP <size> LF <size bytes> LF`; an unresolvable one
    /// answers `<request> SP missing LF`. Content is raw bytes — a tree's is
    /// binary — so the parse is by byte count, never by lines.
    private static func nextBatchResponse(
        in data: Data,
        from cursor: inout Data.Index
    ) throws -> BatchResponse {
        let newline = UInt8(ascii: "\n")
        guard cursor < data.endIndex,
              let headerEnd = data[cursor...].firstIndex(of: newline) else {
            throw Error.malformedPlumbingOutput(
                command: "cat-file --batch", detail: "truncated response header")
        }
        let header = String(decoding: data[cursor..<headerEnd], as: UTF8.self)
        cursor = data.index(after: headerEnd)

        let fields = header.split(separator: " ")
        if fields.count == 2, fields[1] == "missing" {
            return .missing
        }
        guard fields.count == 3, let size = Int(fields[2]), size >= 0,
              data.distance(from: cursor, to: data.endIndex) > size else {
            throw Error.malformedPlumbingOutput(
                command: "cat-file --batch", detail: header)
        }
        let contentEnd = data.index(cursor, offsetBy: size)
        let content = Data(data[cursor..<contentEnd])
        guard data[contentEnd] == newline else {
            throw Error.malformedPlumbingOutput(
                command: "cat-file --batch", detail: "content not LF-terminated: \(header)")
        }
        cursor = data.index(after: contentEnd)
        return .object(type: String(fields[1]), content: content)
    }

    /// Says why an anchor's metadata request came back `missing`, from the
    /// most fundamental cause up: no object, wrong object type, or a real
    /// snapshot commit that simply has no metadata blob.
    private static func classify(
        _ anchor: (id: JournalEntryID, oid: String),
        at base: String,
        git: GitProcess
    ) throws -> Defect {
        let exists = try git.capture(["cat-file", "-e", anchor.oid], workingDirectory: base)
        guard exists.exitCode == 0 else {
            return .missingSnapshotCommit(id: anchor.id, commit: anchor.oid)
        }
        let type = try git.run(["cat-file", "-t", anchor.oid], workingDirectory: base)
        let typeName = type.lines.first ?? ""
        guard typeName == "commit" else {
            return .anchorNotACommit(id: anchor.id, oid: anchor.oid, type: typeName)
        }
        return .missingMetadata(id: anchor.id, commit: anchor.oid)
    }
}

// MARK: - §6 exit class (#0141)

/// Plumbing output the engine cannot parse is a repository-state failure —
/// guide §6 code 6, the same class as every other failure to read this
/// repository. Per-entry problems are `Defect` values, not errors.
extension JournalRebuild.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
