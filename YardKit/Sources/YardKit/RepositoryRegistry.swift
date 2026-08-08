// RepositoryRegistry.swift

import Foundation

/// The cross-repository registry: which repositories Switchyard has seen and
/// where they are now.
///
/// Lives in the state directory (`ServiceNames.stateDirectory()`), which the
/// app and the CLI genuinely share — guide §11 decision 5. The registry is an
/// index and a convenience: the truth about any repository is always in the
/// repository itself, and losing this file must never lose work (git
/// internals §3).
///
/// The directory is **required at init, never defaulted**, so no test can
/// reach the real state directory by omission. Production callers go through
/// `RepositoryRegistry.live()`, the one place that passes
/// `ServiceNames.stateDirectory()`.
public struct RepositoryRegistry: Sendable {

    /// Registry file name inside the state directory.
    public static let fileName = "repositories.json"

    /// One known repository.
    public struct Entry: Codable, Equatable, Sendable {
        /// Durable identity — an opaque string that survives a move on disk.
        /// `RepositoryIdentity` (YardGit, #0149) produces it; it crosses the layer
        /// boundary as a plain `String`, so neither module imports the other.
        public let identity: String
        /// Canonical `$GIT_COMMON_DIR` the last time the repository was seen —
        /// the same string the app keys repository tabs on.
        public var commonDir: String
        /// Working-tree root. Nil for a bare repository.
        public var workingTree: String?
        /// When this identity was first registered. Preserved across moves.
        public let firstRegistered: Date
        /// Last time the repository was registered (opened or operated on).
        public var lastSeen: Date
    }

    /// What `register` did, so a caller can surface a move rather than
    /// swallow it.
    public enum Outcome: Equatable, Sendable {
        case added
        /// The identity was already registered and its entry was updated in
        /// place — a moved repository updates its one entry, it never becomes
        /// a second one. `previousCommonDir` names where it was.
        case updated(previousCommonDir: String)
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        /// The file exists but is not a decodable registry.
        case unreadable(path: String, detail: String)
        /// The file decodes but declares a schema this build does not know.
        case unsupportedSchema(version: Int, path: String)
    }

    /// The `switchyard` state directory this registry reads and writes.
    public let directory: URL

    /// `directory` is deliberately not defaulted; see the type comment.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The registry against the real state directory. Production only —
    /// tests construct with an injected scratch directory instead.
    public static func live() -> RepositoryRegistry {
        RepositoryRegistry(directory: ServiceNames.stateDirectory())
    }

    /// Where the registry file lives: `<directory>/repositories.json`.
    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: - Reading

    /// Every known repository. A missing file is an empty registry, not an
    /// error; a torn or foreign file is `Error.unreadable`.
    public func entries() throws -> [Entry] {
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
        return store.repositories
    }

    // MARK: - Registration

    /// Records a repository, keyed on `identity`. Registering a known
    /// identity updates its entry in place — new paths, `lastSeen` bumped,
    /// `firstRegistered` preserved — and reports the previous location.
    @discardableResult
    public func register(
        identity: String,
        commonDir: String,
        workingTree: String?,
        now: Date = Date()
    ) throws -> Outcome {
        var current = try entries()
        let outcome: Outcome
        if let index = current.firstIndex(where: { $0.identity == identity }) {
            let previous = current[index]
            current[index] = Entry(
                identity: identity,
                commonDir: commonDir,
                workingTree: workingTree,
                firstRegistered: previous.firstRegistered,
                lastSeen: now
            )
            outcome = .updated(previousCommonDir: previous.commonDir)
        } else {
            current.append(Entry(
                identity: identity,
                commonDir: commonDir,
                workingTree: workingTree,
                firstRegistered: now,
                lastSeen: now
            ))
            outcome = .added
        }
        try save(current)
        return outcome
    }

    /// Forgets a repository. Returns false when the identity was not
    /// registered, so callers can report a no-op honestly.
    @discardableResult
    public func remove(identity: String) throws -> Bool {
        var current = try entries()
        let before = current.count
        current.removeAll { $0.identity == identity }
        guard current.count != before else { return false }
        try save(current)
        return true
    }

    // MARK: - Writing

    private func save(_ entries: [Entry]) throws {
        try ensureDirectory()
        let data = try Self.encoder().encode(Store(schemaVersion: 1, repositories: entries))
        // `.atomic` is write-to-temp-then-rename: a concurrent reader sees the
        // old complete file or the new complete one, never a torn one.
        // Serializing concurrent WRITERS is explicitly out of scope here —
        // the registry is self-healing (a lost registration reappears on the
        // next open) and cross-process locking is the journal's problem (#0032).
        try data.write(to: fileURL, options: .atomic)
    }

    /// Creates the state directory owner-only (0700): it records repository
    /// paths and, later, agent session records. An existing directory keeps
    /// whatever permissions it has.
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
        var repositories: [Entry]
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted and pretty so the file diffs cleanly and tests are
        // deterministic. ISO 8601 drops sub-second precision — fine for
        // "when was this last opened", and tests use whole-second dates.
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
