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
    ///
    /// Two payload shapes share this type (#0220), discriminated by `kind`:
    /// a foreign `reference-transaction` carries ref updates, a foreign
    /// rewrite (`commit --amend` / `rebase`) carries an old→new commit
    /// mapping. `kind` is added additively as a new required key on both
    /// shapes — an existing reader that only looks at `updates` is
    /// unaffected by a `rewrites`-kind entry appearing, so no
    /// `schemaVersion` bump accompanies it. One namespace, not two: a second
    /// ref namespace would keep each shape single-purpose at the cost of a
    /// second `list` on every read, for a distinction `kind` already makes.
    ///
    /// Modeled as `kind` plus two optional payload fields rather than a
    /// nested `enum Payload`: Swift's synthesized `Codable` already emits an
    /// `Optional` property via `encodeIfPresent` on write and
    /// `decodeIfPresent` on read, so the field that does not apply to a
    /// given `kind` is simply absent from the JSON on both sides with no
    /// custom `encode(to:)` or `init(from:)` needed, and `Metadata` stays a
    /// plain struct rather than growing a second type to duplicate against.
    ///
    /// `Codable`, not `Encodable`-only (#0236): a foreign rewrite's stored
    /// mapping was write-only until this — nothing in the tree could read
    /// one back. No `schemaVersion` guard on decode, unlike
    /// `JournalEntryMetadata`: every field this schema has ever added
    /// (`kind`, `timestamp`, `worktree`) arrived as a new required key
    /// alongside `schemaVersion` staying at `1` (see the doc comment above),
    /// so there is no older wire shape a version check would need to reject
    /// -- `schemaVersion` decodes as an ordinary field and a future bump
    /// gets the same probe-first treatment `JournalEntryMetadata` uses, once
    /// there is a second version to distinguish from.
    public struct Metadata: Sendable, Equatable, Codable {
        public static let currentSchemaVersion = 1

        /// Discriminates the two payload shapes an observed entry can carry.
        public enum Kind: String, Sendable, Equatable, Codable {
            case refUpdates = "ref_updates"
            case rewrites
        }

        public let schemaVersion: Int
        public let kind: Kind

        /// Present only when `kind == .refUpdates`.
        public let updates: [ReferenceTransaction.RefUpdate]?
        /// Present only when `kind == .rewrites`: the git argument the
        /// rewrite arrived as (`PostRewrite.Source.gitArgument`).
        public let source: String?
        /// Present only when `kind == .rewrites`, in `PostRewrite.parse`'s
        /// order -- order is part of the contract, a rebase's mapping is a
        /// sequence, not a set.
        public let rewrites: [PostRewrite.Rewrite]?

        /// Capture moment. Present on both kinds (#0235) -- a `ref_updates`
        /// entry has the same need as a `rewrites` one. New required key,
        /// no `schemaVersion` bump: observed entries reach no agent yet.
        public let timestamp: Date
        /// The worktree the foreign transaction happened in. Present on
        /// both kinds (#0235); reuses `JournalEntryMetadata.Worktree`
        /// rather than defining a second `{name, path}` shape. Observed
        /// refs are shared, not per-worktree, so this is the only way a
        /// consumer can tell which worktree a foreign rewrite happened in.
        public let worktree: JournalEntryMetadata.Worktree

        public init(updates: [ReferenceTransaction.RefUpdate],
                    timestamp: Date,
                    worktree: JournalEntryMetadata.Worktree,
                    schemaVersion: Int = Metadata.currentSchemaVersion) {
            self.schemaVersion = schemaVersion
            self.kind = .refUpdates
            self.updates = updates
            self.source = nil
            self.rewrites = nil
            self.timestamp = timestamp
            self.worktree = worktree
        }

        public init(source: PostRewrite.Source, rewrites: [PostRewrite.Rewrite],
                    timestamp: Date,
                    worktree: JournalEntryMetadata.Worktree,
                    schemaVersion: Int = Metadata.currentSchemaVersion) {
            self.schemaVersion = schemaVersion
            self.kind = .rewrites
            self.updates = nil
            self.source = source.gitArgument
            self.rewrites = rewrites
            self.timestamp = timestamp
            self.worktree = worktree
        }
    }

    /// Writes one observed entry for a foreign `reference-transaction`.
    /// Returns the anchor so a caller can assert on it; callers in the hook
    /// path ignore it (#0191).
    @discardableResult
    public static func record(
        _ updates: [ReferenceTransaction.RefUpdate],
        in context: WorktreeContext,
        now: Date = Date(),
        git: GitProcess = GitProcess()
    ) throws -> JournalAnchor.Entry {
        let base = context.topLevel ?? context.gitDir
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(Metadata(
            updates: updates,
            timestamp: now,
            worktree: .init(name: context.worktreeName, path: base)))
        return try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: json),
            id: JournalEntryID.generate(now: now, after: try list(in: context, git: git).last?.id),
            in: context,
            namespace: refPrefix,
            git: git)
    }

    /// **Mid-rebase dedup, shared by both the foreign and own paths
    /// (#0233).** A rebase step that squashes, fixes up, or rewords
    /// internally amends, raising its own `post-rewrite amend` invocation
    /// whose old oid is an intermediate commit that never existed in the
    /// pre-rewrite history (measured, #0043's Givens). The rebase's own
    /// final `rebase`-sourced invocation repeats that pair alongside the
    /// rest of its mapping, so skipping the mid-rebase amend loses nothing
    /// and the final invocation alone is authoritative.
    ///
    /// Detected the way git itself exposes the state: `git rev-parse
    /// --git-path rebase-merge` resolved through `WorktreeContext.path(for:)`,
    /// then a `FileManager` existence check on *that resolved path* — never
    /// a path built by string concatenation onto `.git/`. Measured to hold
    /// for a real `post-rewrite amend` invocation; see `JournalObservedTests`.
    ///
    /// Called **before** the own/foreign split in both `record(_
    /// decision:)` below and `JournalCheckpoint.attachRewrite`, so the rule
    /// is one implementation enforced on both paths rather than two, one of
    /// which can silently drift from the other.
    static func isMidRebaseAmend(
        _ decision: PostRewrite.Decision,
        in context: WorktreeContext,
        git: GitProcess = GitProcess(),
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard decision.source == .amend else { return false }
        let rebaseMergePath = try context.path(for: "rebase-merge", git: git)
        return fileManager.fileExists(atPath: rebaseMergePath)
    }

    /// Writes one observed entry for a **foreign** rewrite decision (#0220).
    ///
    /// Only `isOwnInvocation == false` lands here — attaching an **own**
    /// invocation's mapping to its in-flight journal entry is #0221's job,
    /// not this one. Passing an own-invocation decision writes nothing and
    /// returns `nil`, a guard rather than a `precondition`: the hook must
    /// never crash, and this keeps the two halves from both firing once
    /// #0221 lands, whichever routes to this function by mistake.
    ///
    /// The mid-rebase dedup (`isMidRebaseAmend` above) is checked first, so
    /// a mid-rebase amend is skipped whether the invocation turns out to be
    /// foreign or own.
    ///
    /// Throws on a persistence failure exactly as the ref-update `record`
    /// does; the totality invariant (#0043) — a failure here must never
    /// surface as a non-zero hook exit — is upheld by the caller, which
    /// swallows the throw the way `ReferenceTransaction.runHook` already
    /// does for `@discardableResult` callers of the ref-update `record`
    /// (#0191). `decide`'s exit code is total by construction and is
    /// unaffected either way.
    @discardableResult
    public static func record(
        _ decision: PostRewrite.Decision,
        in context: WorktreeContext,
        now: Date = Date(),
        git: GitProcess = GitProcess(),
        fileManager: FileManager = .default
    ) throws -> JournalAnchor.Entry? {
        if try isMidRebaseAmend(decision, in: context, git: git, fileManager: fileManager) {
            return nil
        }

        guard !decision.isOwnInvocation else { return nil }

        let base = context.topLevel ?? context.gitDir
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(
            Metadata(
                source: decision.source, rewrites: decision.rewrites,
                timestamp: now,
                worktree: .init(name: context.worktreeName, path: base)))
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
