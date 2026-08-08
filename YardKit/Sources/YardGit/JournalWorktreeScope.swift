// JournalWorktreeScope.swift — the undo chain is per-worktree (#0044)

import Foundation

/// Scopes the undo/redo chain to one worktree over the repository-wide
/// journal.
///
/// The journal itself is per-repository: anchors live under shared refs, so
/// every worktree sees one entry list (#0028). But `HEAD` is per-worktree,
/// restore refuses to apply another worktree's snapshot (#0168's gate), and
/// two agents in two worktrees are the intended usage — so **the cursor is
/// per-worktree**: each worktree's undo walks only the entries recorded in
/// that worktree, and one agent's checkpoint neither truncates a sibling's
/// redo tail nor becomes a sibling's undo target.
///
/// The scoping key is the worktree **name** (`WorktreeContext.worktreeName`,
/// nil for the main worktree), which is what entry metadata records (#0155)
/// and what git's `worktrees/<name>/` ref prefix addresses. A re-created
/// worktree reuses its name and therefore inherits the dead chain's cursor —
/// accepted: the first new checkpoint written there resets it to present,
/// and every restore re-checks state through the cross-tool guard anyway.
///
/// Pruning stays repository-wide, so the protected set is the **union** of
/// every *live* worktree's protected ids. A worktree that no longer exists
/// stops protecting: its redo tail and cursor become ordinary prunable
/// history, which is the deleted-worktree policy — an abandoned agent
/// checkout must not pin journal entries forever.
public enum JournalWorktreeScope {

    /// One journal entry as scoping sees it: the chain node plus the
    /// worktree name its metadata recorded (#0155; nil = main worktree).
    public struct Node: Sendable, Equatable {
        public let node: JournalChain.Node
        public let worktree: String?

        public init(node: JournalChain.Node, worktree: String?) {
            self.node = node
            self.worktree = worktree
        }
    }

    /// The chain state one worktree sees: `JournalChain.state(of:)` over the
    /// subsequence of entries recorded in that worktree. Order errors
    /// propagate unchanged — a filtered subsequence of an ascending list is
    /// still ascending, so `.unordered` still means the caller built the
    /// list wrong.
    public static func state(
        of nodes: [Node],
        in worktree: String?
    ) throws -> JournalChain.State {
        try JournalChain.state(
            of: nodes.filter { $0.worktree == worktree }.map(\.node))
    }

    /// The union of protected ids across the given worktrees — the set the
    /// prune composition (#0170) passes to `JournalPrune`. Callers pass the
    /// names of worktrees that currently exist (from `worktreeList`, not
    /// prunable), plus nil for the main worktree; chains of worktrees not
    /// named here protect nothing.
    public static func protectedIDs(
        of nodes: [Node],
        live worktrees: Set<String?>
    ) throws -> Set<JournalEntryID> {
        var union: Set<JournalEntryID> = []
        for worktree in worktrees {
            union.formUnion(try state(of: nodes, in: worktree).protectedIDs)
        }
        return union
    }
}
