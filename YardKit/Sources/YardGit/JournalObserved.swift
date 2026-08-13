// JournalObserved.swift — observed foreign ref transactions as journal entries (#0153)

import Foundation

/// Records committed `reference-transaction` updates as observed journal entries,
/// but **never** offers them to undo/redo and never runs the live-listing filter.
public enum JournalObserved {

    public static let observedNamespace = RefSnapshot.switchyardNamespace + "observed/"
    public static let refPrefix = observedNamespace + "journal/"
    public static let operation = "observed"

    /// One ref update captured at transaction time.
    public struct RefUpdateRecord: Sendable, Equatable, Encodable {
        public let oldValue: String
        public let newValue: String
        public let refName: String

        private enum CodingKeys: String, CodingKey { case oldValue, newValue, refName }

        public init(oldValue: String, newValue: String, refName: String) {
            self.oldValue = oldValue
            self.newValue = newValue
            self.refName = refName
        }

        public var isCreation: Bool { oldValue.allSatisfy({ $0 == "0" }) && !newValue.isEmpty }
        public var isDeletion: Bool { newValue.allSatisfy({ $0 == "0" }) }
        public var isSymbolic: Bool { oldValue.hasPrefix("ref:") || newValue.hasPrefix("ref:") }
    }

    /// The metadata for one observed entry. Wire form is identical to a normal
    /// entry except `operation`, `payload.schemaVersion` and the new
    /// `payload.refs` field. Kept as a `Codable`-compatible struct because the
    /// same schema version and sorted-keys encoder are used for every entry.
    public struct ObservedMetadata: Sendable, Equatable, Encodable {

        public let payloadSchemaVersion: Int
        public let updates: [RefUpdateRecord]

        /// Alias the worktree shape from `JournalEntryMetadata` so callers can
        /// mix observed and normal entries without distinguishing the type.
        public typealias Worktree = JournalEntryMetadata.Worktree

        private enum CodingKeys: String, CodingKey {
            case payloadSchemaVersion
            case updates
        }

        public init(
            payloadSchemaVersion: Int = 1,
            updates: [RefUpdateRecord]
        ) {
            self.payloadSchemaVersion = payloadSchemaVersion
            self.updates = updates
        }

        public static let currentPayloadSchema: Int = 1
    }

    /// Decodes a metadata blob written by `write(_:)`. Returns `nil` if the
    /// bytes are not JSON or are not for a supported observed schema — no
    /// throwing because test code and rollback callers both need to scan
    /// arbitrary blobs for the matching entry without a failure path.
    public static func metadata(json bytes: Data) -> ObservedMetadata? {
        guard let dict = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let schemaVersion = dict["payloadSchemaVersion"] as? Int,
              let rawUpdates = dict["updates"] as? [[String: Any]],
              schemaVersion == ObservedMetadata.currentPayloadSchema
        else { return nil }

        let updates: [RefUpdateRecord] = rawUpdates.compactMap { refObj in
            guard let old = refObj["oldValue"] as? String,
                  let new = refObj["newValue"] as? String,
                  let name = refObj["refName"] as? String
            else { return nil }
            return RefUpdateRecord(oldValue: old, newValue: new, refName: name)
        }

        return ObservedMetadata(payloadSchemaVersion: schemaVersion, updates: updates)
    }

    /// Writes one observed entry anchoring `updates` at a fresh id. The anchor
    /// lives in the observed namespace, not the active journal's — the result
    /// never reaches undo/redo.
    @discardableResult
    public static func write(
        _ updates: [RefUpdateRecord],
        worktreeContext: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> JournalAnchor.Entry {
        let id: JournalEntryID = try .generate(now: Date())

        let metadata = ObservedMetadata(
            payloadSchemaVersion: ObservedMetadata.currentPayloadSchema,
            updates: updates)

        let metadataData = try JSONEncoder().encode(metadata)
        let contents = JournalAnchor.Contents(metadataJSON: metadataData)

        return try JournalAnchor.write(contents, id: id, in: worktreeContext, git: git)
    }

}
