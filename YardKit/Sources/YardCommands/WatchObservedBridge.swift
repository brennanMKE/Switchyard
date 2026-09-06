// WatchObservedBridge.swift — the journal-observed event source (#0058)

import Foundation
import YardGit
import YardKit

/// Bridges the hook layer's journal-observed records (#0042/#0153) into the
/// watch stream (#0058).
///
/// This file exists because the two halves of the conversion live in
/// different targets: `JournalObserved.Metadata` and its `serialized()` bytes
/// live in `YardGit`, while `WatchSessionStore` and `WatchEvent` live in
/// `YardKit`, which does not link the engine (layering). Only the app target
/// — and this YardCommands body, linked by the app alone — sees both. The
/// payload the event carries is the metadata's own JSON, embedded as a
/// nested object, so a watch consumer reads the same shape
/// `metadata.json` stores.
///
/// Round 1 ships the source and this seam; the call site that invokes it as
/// each record lands (alongside `JournalObserved.record` in the hook flow)
/// is wired in round 2 with the app-side session measurement, so the hook's
/// totality path is not touched twice.
public enum WatchObservedBridge {

    /// Broadcasts one journal-observed entry as a `journal_observed` watch
    /// event, scoped to the worktree the transaction happened in — the
    /// event's repository path is the metadata's own worktree path, and the
    /// store matches it exactly against each session's request (#0058).
    /// Throws when the metadata cannot be serialized — the caller (the hook
    /// body) swallows that throw, keeping the totality invariant: a watch
    /// delivery failure must never break a user's transaction.
    public static func broadcast(
        _ metadata: JournalObserved.Metadata,
        store: WatchSessionStore
    ) throws {
        let payload = try WatchJSON.object(fromJSON: metadata.serialized())
        store.broadcast(
            kind: .journalObserved,
            payload: payload,
            repositoryPath: metadata.worktree.path)
    }
}
