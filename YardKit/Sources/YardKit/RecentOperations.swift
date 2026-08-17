// RecentOperations.swift

import Foundation

/// The cross-repository recent-operations index: what happened, where, and
/// when, across every repository Switchyard has touched — the store behind
/// "what did I do everywhere today" (git internals §3).
///
/// Lives beside `repositories.json` in the state directory
/// (`ServiceNames.stateDirectory()`), which the app and the CLI genuinely
/// share — guide §11 decision 5. This is an index and a convenience: the
/// truth about any operation is always in the repository's own journal, and
/// losing this file must never lose work.
///
/// The directory is **required at init, never defaulted**, so no test can
/// reach the real state directory by omission. Production callers go through
/// `RecentOperations.live()`, the one place that passes
/// `ServiceNames.stateDirectory()`. Same shape as `RepositoryRegistry`
/// deliberately: required directory injection, `.atomic` writes, an
/// owner-only directory, a `schemaVersion` on the file, and a missing file
/// that reads as empty rather than as an error.
public struct RecentOperations: Sendable {

    /// Store file name inside the state directory, beside `repositories.json`.
    public static let fileName = "recent-operations.json"

    /// The newest-`limit` records kept by `record(_:limit:)` when none is
    /// given. Matches `JournalPrune.Policy.generous.maxCount` (#0033) — the
    /// bound this issue asks to align with. Count-only, deliberately: this
    /// file is an index whose entries are cheap, and a second, age-based axis
    /// is a second thing to get wrong.
    public static let defaultLimit = 1000

    /// One recorded operation, in one repository.
    public struct Record: Codable, Equatable, Sendable {
        /// `RepositoryIdentity`'s opaque string (YardGit, #0149). Crosses the
        /// layer boundary as a plain `String`, so neither module imports the
        /// other — the same treatment `RepositoryRegistry.Entry.identity` gets.
        public let identity: String
        /// The journal entry this refers to: `JournalEntryID.description`.
        public let entryID: String
        /// `JournalEntryMetadata.operation` — "commit", "fixup", "restore", …
        public let operation: String
        /// `JournalEntryMetadata.timestamp`.
        public let timestamp: Date
        /// `JournalEntryMetadata.Agent.name`, flattened. Nil when the
        /// operation carried no agent.
        public let agentName: String?
        /// `JournalEntryMetadata.Agent.session`, flattened. Nil when the
        /// operation carried no agent.
        public let agentSession: String?

        public init(
            identity: String,
            entryID: String,
            operation: String,
            timestamp: Date,
            agentName: String?,
            agentSession: String?
        ) {
            self.identity = identity
            self.entryID = entryID
            self.operation = operation
            self.timestamp = timestamp
            self.agentName = agentName
            self.agentSession = agentSession
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        /// The file exists but is not a decodable store.
        case unreadable(path: String, detail: String)
        /// The file decodes but declares a schema this build does not know.
        case unsupportedSchema(version: Int, path: String)
    }

    /// The `switchyard` state directory this store reads and writes.
    public let directory: URL

    /// `directory` is deliberately not defaulted; see the type comment.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The store against the real state directory. Production only — tests
    /// construct with an injected scratch directory instead.
    public static func live() -> RecentOperations {
        RecentOperations(directory: ServiceNames.stateDirectory())
    }

    /// Where the store file lives: `<directory>/recent-operations.json`.
    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: - Reading

    /// Every record, **newest first** — the order the question "what did I do
    /// everywhere today" is asked in. A missing file is empty, not an error;
    /// a torn or foreign file is `Error.unreadable`.
    public func records() throws -> [Record] {
        try storedOldestFirst().reversed()
    }

    /// Records for one repository, newest first.
    public func records(identity: String) throws -> [Record] {
        try records().filter { $0.identity == identity }
    }

    // MARK: - Appending

    /// Appends one record, then trims to `limit` newest. Returns the number
    /// of records in the store after the append and trim.
    @discardableResult
    public func record(_ record: Record, limit: Int = RecentOperations.defaultLimit) throws -> Int {
        var current = try storedOldestFirst()
        current.append(record)
        // Trim from the front: the array is oldest-first on disk, so the
        // newest `limit` records are the tail, not the head.
        if current.count > limit {
            current.removeFirst(current.count - limit)
        }
        try save(current)
        return current.count
    }

    // MARK: - Writing

    /// Reads the store in its on-disk order — oldest first — so callers that
    /// append or trim never need to reason about a sort. `records()` reverses
    /// this for the newest-first read order the store is queried in.
    private func storedOldestFirst() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let store: Store
        do {
            let data = try Data(contentsOf: fileURL)
            store = try Self.decoder().decode(Store.self, from: data)
        } catch {
            throw Error.unreadable(path: fileURL.path, detail: String(describing: error))
        }
        guard store.schemaVersion == 1 else {
            throw Error.unsupportedSchema(version: store.schemaVersion, path: fileURL.path)
        }
        return store.records
    }

    private func save(_ records: [Record]) throws {
        try ensureDirectory()
        let data = try Self.encoder().encode(Store(schemaVersion: 1, records: records))
        // `.atomic` is write-to-temp-then-rename: a concurrent reader sees
        // the old complete file or the new complete one, never a torn one.
        // Serializing concurrent WRITERS is explicitly out of scope here, as
        // with `RepositoryRegistry` — this store is self-healing and
        // cross-process locking is the journal's problem (#0032).
        try data.write(to: fileURL, options: .atomic)
    }

    /// Creates the state directory owner-only (0700). An existing directory
    /// keeps whatever permissions it has.
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Wire format

    private struct Store: Codable {
        var schemaVersion: Int
        var records: [Record]
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted and pretty so the file diffs cleanly and tests are
        // deterministic. ISO 8601 drops sub-second precision — several
        // operations in the same second sort equal on timestamp alone, which
        // is why insertion order (oldest-first on disk) is the tiebreaker,
        // not a sort.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
