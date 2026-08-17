// JournalEntryMetadata.swift — the typed shape of a journal entry's metadata bytes (#0155)

import Foundation

/// What one journal entry records about itself: the decoded form of the
/// `metadata.json` blob in every snapshot commit's tree (#0028 stores the
/// bytes verbatim; #0030 recovers them from refs alone; this type owns their
/// shape). The wire form is JSON with sorted keys, ISO 8601 whole-second
/// timestamps, and unescaped slashes — deterministic for a given entry, so
/// byte comparison of two serializations of the same entry is meaningful.
///
/// Two shape decisions carried from planning:
///
/// - **An entry's kind is decided by the presence of `traversal`, never by
///   matching the `operation` string** (#0034 decision 7). `operation` is
///   free text describing the command; `chainNode` is the one bridge into
///   `JournalChain`, and it consults only `traversal`.
/// - `snapshotRef` is deliberately absent: the reader just resolved the
///   anchor ref to get these bytes, so recording it here would be circular.
///   The journal.json cache row (#0156) carries it instead.
public struct JournalEntryMetadata: Sendable, Equatable, Codable {

    /// The schema this build writes and the only one it reads. A future
    /// version 2 must be a new number, never a silent reinterpretation.
    public static let currentSchemaVersion = 1

    /// Always `currentSchemaVersion` on entries this build creates; checked
    /// first at decode so a future schema fails typed, not field-by-field.
    public let schemaVersion: Int

    /// The entry's id — also the last component of its anchor ref name.
    public let id: JournalEntryID

    /// Free text naming the operation that wrote the entry ("checkpoint",
    /// "fixup", "undo", …). Display only: nothing may branch on it.
    public let operation: String

    /// The full invoking command line, when one exists ("switchyard fixup
    /// HEAD~2"). Engine-level callers have none; M3's CLI supplies it.
    public let command: String?

    /// Human- or agent-supplied checkpoint description (#0034 decision 7).
    public let label: String?

    /// Capture moment, whole seconds. The memberwise initializer floors
    /// sub-second inputs because the ISO 8601 wire form cannot carry them
    /// (measured: 0.5s encodes "…T00:00:00Z" and decodes 0.0) — flooring at
    /// construction keeps round trips exact. The id already carries
    /// milliseconds.
    public let timestamp: Date

    /// Where the entry was written. `name` is
    /// `WorktreeContext.worktreeName` — nil for the main worktree.
    public let worktree: Worktree

    /// What the snapshot actually captured — how undo reports honestly what
    /// it can and cannot restore.
    public let captured: Captured

    /// Ref name → oid at capture, for display. The engine's cross-tool
    /// guard (#0031) compares the union of recorded and current refs via
    /// the refs blob, never this subset (internals §3 correction).
    public let guardRefs: [String: String]

    /// The agent that wrote the entry, when one did.
    public let agent: Agent?

    /// Present exactly on entries written by undo/redo — the field whose
    /// presence makes the entry a traversal entry. The type is
    /// `JournalChain.Traversal` itself, so the chain and the wire cannot
    /// disagree about what a traversal records.
    public let traversal: JournalChain.Traversal?

    /// The wire names. `guardRefs` maps to "guard", which Swift reserves;
    /// everything else matches its property.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, operation, command, label, timestamp
        case worktree, captured, agent, traversal
        case guardRefs = "guard"
    }

    public init(
        id: JournalEntryID,
        operation: String,
        command: String? = nil,
        label: String? = nil,
        timestamp: Date,
        worktree: Worktree,
        captured: Captured,
        guardRefs: [String: String] = [:],
        agent: Agent? = nil,
        traversal: JournalChain.Traversal? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.operation = operation
        self.command = command
        self.label = label
        self.timestamp = Date(
            timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down))
        self.worktree = worktree
        self.captured = captured
        self.guardRefs = guardRefs
        self.agent = agent
        self.traversal = traversal
    }

    // MARK: - Nested pieces

    /// The writing worktree. `name` nil means the main worktree.
    public struct Worktree: Sendable, Equatable, Codable {
        public let name: String?
        public let path: String

        public init(name: String?, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// The agent that wrote the entry.
    public struct Agent: Sendable, Equatable, Codable {
        public let name: String
        public let session: String?

        public init(name: String, session: String?) {
            self.name = name
            self.session = session
        }
    }

    /// Per-piece capture record. Wire values: booleans for `refs`, `head`,
    /// `untracked`; `index` is `false`, `"tree"`, or `"raw"`; `worktree` is
    /// `false` or `"stash"`.
    public struct Captured: Sendable, Equatable, Codable {
        public let refs: Bool
        public let head: Bool
        public let index: IndexCapture
        public let worktree: WorktreeCapture
        public let untracked: Bool
        /// The sequencer capture state. Wire: `false` or `"merge"`.
        public let sequencer: SequencerCapture

        public init(refs: Bool, head: Bool, index: IndexCapture,
                    worktree: WorktreeCapture, untracked: Bool,
                    sequencer: SequencerCapture = .notCaptured) {
            self.refs = refs
            self.head = head
            self.index = index
            self.worktree = worktree
            self.untracked = untracked
            self.sequencer = sequencer
        }

        /// What checkpoint writes until #0171 wires the index and worktree
        /// snapshots in (#0034 decision 3).
        public static let refsOnly = Captured(
            refs: true, head: true, index: .notCaptured,
            worktree: .notCaptured, untracked: false)

        /// The sequencer capture state. Wire: `false` / `"merge"`.
        public enum SequencerCapture: Sendable, Equatable, Codable {
            /// Not captured. Wire: `false`.
            case notCaptured
            /// Captured as a rebase-merge state. Wire: `"merge"`.
            case merge
            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let flag = try? container.decode(Bool.self) {
                    guard !flag else {
                        throw DecodingError.dataCorrupted(.init(
                            codingPath: decoder.codingPath,
                            debugDescription:
                                "captured.sequencer true is not a wire value; expected false or \"merge\""))
                    }
                    self = .notCaptured
                    return
                }
                switch try container.decode(String.self) {
                case "merge": self = .merge
                case let other:
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "unknown captured.sequencer value: \(other)"))
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .notCaptured: try container.encode(false)
                case .merge: try container.encode("merge")
                }
            }
        }
    }

    /// How the index was captured. Encoded by hand as `false` / `"tree"` /
    /// `"raw"`: a bare `Codable` on a payload-free enum synthesizes the
    /// SE-0295 object form (measured: `{"tree":{}}`), which round-trips and
    /// still breaks the wire — the golden-bytes tests pin the real form.
    public enum IndexCapture: Sendable, Equatable, Codable {
        /// Not captured. Wire: `false`.
        case notCaptured
        /// Captured as a tree via `write-tree`. Wire: `"tree"`.
        case tree
        /// Unmerged; the index file itself snapshotted as a blob
        /// (`index.raw`, internals §3). Wire: `"raw"`.
        case raw
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                guard !flag else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "captured.index true is not a wire value; expected false, \"tree\", or \"raw\""))
                }
                self = .notCaptured
                return
            }
            switch try container.decode(String.self) {
            case "tree": self = .tree
            case "raw": self = .raw
            case let other:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown captured.index value: \(other)"))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .notCaptured: try container.encode(false)
            case .tree: try container.encode("tree")
            case .raw: try container.encode("raw")
            }
        }
    }

    /// How the working tree was captured. Wire: `false` / `"stash"`.
    public enum WorktreeCapture: Sendable, Equatable, Codable {
        /// Not captured. Wire: `false`.
        case notCaptured
        /// Captured as a stash-style commit. Wire: `"stash"`.
        case stash
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                guard !flag else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription:
                            "captured.worktree true is not a wire value; expected false or \"stash\""))
                }
                self = .notCaptured
                return
            }
            switch try container.decode(String.self) {
            case "stash": self = .stash
            case let other:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown captured.worktree value: \(other)"))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .notCaptured: try container.encode(false)
            case .stash: try container.encode("stash")
            }
        }
    }

    // MARK: - The chain bridge

    /// This entry as `JournalChain` sees it. The one place entry kind is
    /// decided, and it is decided by `traversal`'s presence alone.
    public var chainNode: JournalChain.Node {
        JournalChain.Node(id: id, traversal: traversal)
    }

    // MARK: - Wire form

    public enum SerializationError: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        /// The bytes do not decode as this schema — not JSON, missing or
        /// mistyped fields, an invalid id, an unknown capture value. The
        /// blob is #0030-recoverable evidence either way; failing to decode
        /// it is this layer's error, never a rebuild defect.
        case undecodable(detail: String)
        /// The bytes are JSON with a `schemaVersion` this build does not
        /// read.
        case unsupportedSchemaVersion(Int)

        public var description: String {
            switch self {
            case let .undecodable(detail):
                "journal entry metadata does not decode: \(detail)"
            case let .unsupportedSchemaVersion(version):
                "journal entry metadata has unsupported schemaVersion \(version)"
            }
        }
    }

    /// The entry as `metadata.json` bytes, ready for
    /// `JournalAnchor.Contents.metadataJSON`. Sorted keys make the bytes
    /// deterministic; unescaped slashes keep paths and ref names readable
    /// in `git cat-file` output (the default escapes "/" as "\/", measured).
    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(self)
        } catch {
            // Unreachable for any value this type can hold; surfaced typed
            // rather than trapped so the contract has no crash path.
            throw SerializationError.undecodable(detail: String(describing: error))
        }
    }

    /// Decodes bytes `serialized()` wrote — or whatever actually sits in a
    /// snapshot commit's `metadata.json`. The schema version is checked
    /// before the full decode, so a future schema fails as
    /// `.unsupportedSchemaVersion`, not as a missing-field error.
    public init(serialized data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probe: SchemaProbe
        do {
            probe = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            throw SerializationError.undecodable(detail: Self.detail(of: error))
        }
        guard probe.schemaVersion == Self.currentSchemaVersion else {
            throw SerializationError.unsupportedSchemaVersion(probe.schemaVersion)
        }
        do {
            self = try decoder.decode(JournalEntryMetadata.self, from: data)
        } catch {
            throw SerializationError.undecodable(detail: Self.detail(of: error))
        }
    }

    /// Just the version field, decoded ahead of the full shape.
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    /// A one-line account of a `DecodingError`, for the typed error.
    private static func detail(of error: any Error) -> String {
        guard let decoding = error as? DecodingError else {
            return String(describing: error)
        }
        switch decoding {
        case let .dataCorrupted(context),
             let .typeMismatch(_, context),
             let .valueNotFound(_, context):
            return context.debugDescription
        case let .keyNotFound(key, _):
            return "missing key: \(key.stringValue)"
        @unknown default:
            return String(describing: decoding)
        }
    }
}

// MARK: - Ids and traversals on the wire

/// A journal entry id encodes as its 26-character string and decodes only
/// through the validating parser — an id JSON smuggled in must satisfy the
/// same rules `generate` guarantees.
extension JournalEntryID: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = JournalEntryID(raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "not a journal entry id: \(raw)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}


// MARK: - §6 exit class (#0141)

/// Metadata that will not decode is repository-state damage — guide §6
/// code 6, the same class as an unreadable refs blob.
extension JournalEntryMetadata.SerializationError: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
