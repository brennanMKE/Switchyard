// JournalObserved.swift — observed foreign ref transactions (#0153)

import Foundation

/// Records the ref updates a **foreign** `committed` transaction made, as
/// entries in their own ref namespace.
///
/// **They are not journal entries and must never become undo targets.** Guide
/// §11 decision 12 makes that structural rather than enforced: these live under
/// `refs/switchyard/observed/`, which `JournalAnchor.list` does not read, so
/// nothing downstream — the chain, the listing, undo — can see them however it
/// is later changed. Measured: an entry here is absent from both
/// `JournalAnchor.list` and `JournalList.list`, and is not reported as a defect.
///
/// The cost, taken deliberately and tracked as #0190: `JournalRebuild` scans the
/// journal prefix, so a rebuild does not recover these.
public enum JournalObserved {

    /// Where observed entries live. Deliberately NOT `JournalAnchor.refPrefix`.
    public static let refPrefix = RefSnapshot.switchyardNamespace + "observed/"

    /// What one observed entry stores. `schemaVersion` is pinned separately
    /// from `JournalEntryMetadata`'s: these are a different shape with a
    /// different lifetime, and sharing a version number would tie two formats
    /// together that have no reason to change together.
    public struct Metadata: Sendable, Equatable, Encodable {
        public static let currentSchemaVersion = 1

        public let schemaVersion: Int
        public let updates: [ReferenceTransaction.RefUpdate]

        public init(updates: [ReferenceTransaction.RefUpdate],
                    schemaVersion: Int = Metadata.currentSchemaVersion) {
            self.schemaVersion = schemaVersion
            self.updates = updates
        }
    }

    /// Writes one observed entry. Returns the anchor so a caller can assert on
    /// it; callers in the hook path ignore it (#0191).
    @discardableResult
    public static func record(
        _ updates: [ReferenceTransaction.RefUpdate],
        in context: WorktreeContext,
        now: Date = Date(),
        git: GitProcess = GitProcess()
    ) throws -> JournalAnchor.Entry {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(Metadata(updates: updates))
        return try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: json),
            id: JournalEntryID.generate(now: now, after: try list(in: context, git: git).last?.id),
            in: context,
            namespace: refPrefix,
            git: git)
    }

    /// Every observed entry, oldest first. Mirrors `JournalAnchor.list` but
    /// over this namespace.
    public static func list(
        in context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [JournalAnchor.Entry] {
        let base = context.topLevel ?? context.gitDir
        let output = try git.run(
            ["for-each-ref", "--format=%(objectname) %(refname)", refPrefix],
            workingDirectory: base).text
        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2 else { return nil }
            let name = String(fields[1])
            guard name.hasPrefix(refPrefix),
                  let id = JournalEntryID(String(name.dropFirst(refPrefix.count)))
            else { return nil }
            return JournalAnchor.Entry(id: id, commit: String(fields[0]))
        }.sorted { $0.id.string < $1.id.string }
    }
}
