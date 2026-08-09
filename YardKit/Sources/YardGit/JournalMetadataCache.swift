// JournalMetadataCache.swift — the per-repository journal index (#0156)

import Foundation

/// `$GIT_COMMON_DIR/switchyard/journal.json`.
///
/// **An index and a convenience, never the truth.** #0028 stores every entry's
/// metadata inside its anchored snapshot commit, so deleting this file loses
/// nothing: #0030 rebuilds the journal from the anchor refs alone,
/// which is a stated M2 exit criterion. What lives here and nowhere else is
/// `snapshotRef` — the ref that anchors the entry, which is circular inside the
/// commit that ref points at — plus the speed of not walking every anchor.
///
/// The file is addressed relative to `WorktreeContext.commonDir`, never through
/// `git rev-parse --git-path`: for a subpath git does not know, `--git-path`
/// resolves **per-worktree**, so a linked worktree would get its own private
/// journal. Measured at #0149's planning pass. `switchyard/` is our directory,
/// not git's, so reading it directly is not the `$GIT_DIR` rule's concern.
public struct JournalMetadataCache: Sendable {

    /// Relative to `commonDir`. `YardGit` cannot import `YardKit`
    /// (`LayeringTests` forbids both directions), so this is the engine-side
    /// copy of `ServiceNames.journalMetadataRelativePath` — the same
    /// arrangement as `RefSnapshot.switchyardNamespace` beside
    /// `ServiceNames.journalRefPrefix`.
    public static let relativePath = "switchyard/journal.json"

    /// One cached entry: #0155's metadata verbatim, plus the anchor ref.
    public struct Row: Codable, Equatable, Sendable {
        public let metadata: JournalEntryMetadata
        public let snapshotRef: String

        public init(metadata: JournalEntryMetadata, snapshotRef: String) {
            self.metadata = metadata
            self.snapshotRef = snapshotRef
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        /// The file exists but could not be read or decoded. The caller's
        /// remedy is always the same: rebuild from refs (#0030).
        case unreadable(path: String, detail: String)
        /// A schema this build does not know. Probed before decoding, so a
        /// future schema fails as itself rather than as a missing field.
        case unsupportedSchema(version: Int, path: String)

        public var description: String {
            switch self {
            case let .unreadable(path, detail):
                "journal cache at \(path) is unreadable (\(detail)); rebuild it from refs"
            case let .unsupportedSchema(version, path):
                "journal cache at \(path) declares schema version \(version), which this build "
                    + "does not support; rebuild it from refs"
            }
        }
    }

    public let fileURL: URL

    public init(commonDir: String) {
        self.fileURL = URL(fileURLWithPath: commonDir)
            .appendingPathComponent(Self.relativePath)
    }

    public init(context: WorktreeContext) {
        self.init(commonDir: context.commonDir)
    }

    /// Every cached row, oldest first. **A missing file is an empty cache**,
    /// not an error: the cache is derived state and its absence is the
    /// ordinary post-clone condition.
    public func rows() throws -> [Row] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw Error.unreadable(path: fileURL.path, detail: String(describing: error))
        }
        // Probe the version before decoding the whole store, so a future
        // schema reports itself instead of surfacing as a decode failure.
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           probe.schemaVersion != 1 {
            throw Error.unsupportedSchema(version: probe.schemaVersion, path: fileURL.path)
        }
        do {
            return try JSONDecoder().decode(Store.self, from: data).entries
        } catch {
            throw Error.unreadable(path: fileURL.path, detail: String(describing: error))
        }
    }

    /// Appends a row, keeping the file sorted by entry id. Rewrites the whole
    /// file: it is an index of a journal that is pruned, not an append log.
    public func append(_ row: Row) throws {
        var all = try rows()
        all.removeAll { $0.metadata.id == row.metadata.id }
        all.append(row)
        all.sort { $0.metadata.id < $1.metadata.id }
        try write(all)
    }

    /// Removes a row. **Silent when absent** — #0033 deletes the cache row
    /// before the anchor, so a re-run after a crash between the two must not
    /// fail on the row that is already gone.
    public func remove(id: JournalEntryID) throws {
        let all = try rows()
        let kept = all.filter { $0.metadata.id != id }
        guard kept.count != all.count else { return }
        try write(kept)
    }

    private func write(_ entries: [Row]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(Store(schemaVersion: 1, entries: entries))
            // `.atomic` is write-to-temp-then-rename, so a concurrent reader
            // sees either the old file or the new one and never a torn one.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw Error.unreadable(path: fileURL.path, detail: String(describing: error))
        }
    }

    private struct Store: Codable {
        var schemaVersion: Int
        var entries: [Row]
    }

    private struct VersionProbe: Codable {
        var schemaVersion: Int
    }
}

extension JournalMetadataCache.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
