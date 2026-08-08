// JournalPrune.swift — expiry policy and pruning of journal entries (#0033)

import Foundation

extension JournalEntryID {

    /// The creation instant encoded in the id's first ten characters — the
    /// ULID 48-bit millisecond timestamp. The age policy reads this, so
    /// pruning decides expiry from the anchor list alone and never opens an
    /// entry's metadata.
    ///
    /// `generate(now:)` truncates to the millisecond, so the decoded instant
    /// is at most 1ms before the `now` it was minted from. A monotonic-
    /// clamped id (`generate(now:after:)` in the same millisecond) increments
    /// the random half only, so its decoded instant is unchanged.
    public var creationDate: Date {
        var milliseconds: UInt64 = 0
        for character in string.prefix(10) {
            milliseconds = milliseconds << 5 | UInt64(Self.alphabetIndex[character] ?? 0)
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }
}

/// Journal entry expiry and pruning (#0033).
///
/// Pruning is a **ref** operation, never an object operation: deleting an
/// entry's anchor makes its snapshot objects unreachable, and ordinary git
/// maintenance reclaims them on its own schedule (measured — see #0033's
/// Givens: the objects still exist immediately after the anchor delete and
/// are gone after a reflog-expire plus gc run *by the fixture*).
/// `switchyard` itself never runs `git gc` — deciding when to repack
/// someone's repository is not this tool's business — and nothing in this
/// file constructs a git invocation at all: the only repository writes go
/// through `JournalAnchor.delete`, whose guarded form refuses to "delete"
/// a ref that is not there.
///
/// The flow is plan-then-execute, and the seam is deliberate:
///
/// - `plan` is a pure function over the anchor list. It is the whole of
///   `--dry-run`: what it returns is exactly what `execute` would delete.
/// - The plan is computed from `JournalAnchor.list` — the repository, the
///   truth — never from the `journal.json` cache. A crash-orphaned anchor
///   with no cache row is therefore still seen, still ages, and is still
///   pruned; nothing leaks because a cache row went missing.
/// - Per entry, `execute` removes the cache row **first**, then deletes the
///   anchor. A crash between the two leaves an anchor without a row, which
///   #0030 rebuilds from the anchor's own `metadata.json` — full recovery.
///   The other order would leave a cache row naming a deleted anchor: a
///   journal that lists an entry undo can no longer restore, with nothing
///   on disk to rebuild the truth from.
public enum JournalPrune {

    /// When entries expire. Both limits are optional; `nil` means that axis
    /// never expires anything, and a `Policy()` with neither set prunes
    /// nothing at all.
    ///
    /// Whatever the limits say, **the newest entry is never pruned** — a
    /// non-empty journal stays non-empty, so the most recent operation
    /// always remains undoable. Entries an in-flight undo/redo chain still
    /// needs are excluded per call via `protected:`, which the undo layer
    /// (#0034) supplies; the policy cannot know them.
    public struct Policy: Sendable, Equatable {

        /// Keep at most this many entries; the oldest beyond it expire.
        /// Values below 1 behave as 1, because the newest entry is never
        /// pruned.
        public var maxCount: Int?

        /// Entries created strictly more than this many seconds before
        /// `now` expire. Age is read from the entry id's embedded timestamp
        /// (`JournalEntryID.creationDate`), not from metadata.
        public var maxAge: TimeInterval?

        public init(maxCount: Int? = nil, maxAge: TimeInterval? = nil) {
            self.maxCount = maxCount
            self.maxAge = maxAge
        }

        /// The default: deliberately generous, because a snapshot's marginal
        /// cost is a few small objects. 1000 entries, 90 days — the age
        /// matching git's own default expiry for reachable reflog entries.
        public static let generous = Policy(maxCount: 1000, maxAge: 90 * 24 * 60 * 60)
    }

    // MARK: - Planning

    /// The entries `execute` would delete, oldest first: every entry expired
    /// by count or by age, except protected ids and the newest entry.
    ///
    /// Pure, so it *is* the dry run — callers preview a prune by passing
    /// `JournalAnchor.list` output here and going no further. `entries`
    /// must be in `list` order (oldest first, which the id ordering
    /// guarantees); the returned deletions preserve that order, so a prune
    /// interrupted partway leaves the newest entries intact.
    public static func plan(
        _ entries: [JournalAnchor.Entry],
        policy: Policy,
        protected: Set<JournalEntryID> = [],
        now: Date = Date()
    ) -> [JournalAnchor.Entry] {
        guard let newest = entries.last?.id else { return [] }

        var expired = Set<JournalEntryID>()
        if let maxCount = policy.maxCount {
            let over = entries.count - max(maxCount, 0)
            for entry in entries.prefix(max(over, 0)) {
                expired.insert(entry.id)
            }
        }
        if let maxAge = policy.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            for entry in entries where entry.id.creationDate < cutoff {
                expired.insert(entry.id)
            }
        }
        return entries.filter {
            expired.contains($0.id) && $0.id != newest && !protected.contains($0.id)
        }
    }

    // MARK: - Executing

    /// Deletes the planned entries, oldest first. For each entry the cache
    /// row goes first — `removeCacheEntry`, when the caller has a cache
    /// (#0156) — and the anchor second, through `JournalAnchor.delete`,
    /// which names the expected commit: an anchor that vanished or moved
    /// underneath the plan is a thrown `GitProcess.Failure`, never a silent
    /// no-op (a bare `update-ref -d` on a missing ref exits 0 silently —
    /// measured — which is why the guarded form exists).
    ///
    /// Any throw stops the prune where it stands. Both interrupted states
    /// are safe: a removed row with a surviving anchor is rebuilt by #0030,
    /// and the remaining expired entries are simply re-planned next time.
    /// Cross-process serialization is #0032's lock, not this function's job.
    public static func execute(
        _ deletions: [JournalAnchor.Entry],
        in context: WorktreeContext,
        git: GitProcess = GitProcess(),
        removeCacheEntry: ((JournalEntryID) throws -> Void)? = nil
    ) throws {
        for entry in deletions {
            try removeCacheEntry?(entry.id)
            try JournalAnchor.delete(entry, in: context, git: git)
        }
    }

    /// Plan against the live anchor list, execute, and report what was
    /// deleted. The one-call form for callers that are not previewing.
    @discardableResult
    public static func prune(
        policy: Policy,
        protected: Set<JournalEntryID> = [],
        now: Date = Date(),
        in context: WorktreeContext,
        git: GitProcess = GitProcess(),
        removeCacheEntry: ((JournalEntryID) throws -> Void)? = nil
    ) throws -> [JournalAnchor.Entry] {
        let deletions = plan(
            try JournalAnchor.list(in: context, git: git),
            policy: policy, protected: protected, now: now)
        try execute(deletions, in: context, git: git, removeCacheEntry: removeCacheEntry)
        return deletions
    }
}
