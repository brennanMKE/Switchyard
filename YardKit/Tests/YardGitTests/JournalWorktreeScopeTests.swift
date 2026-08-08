// JournalWorktreeScopeTests.swift — the undo chain is per-worktree (#0044)
//
// Deliberately NOT @testable: the undo/redo and prune compositions call this
// scoping as public callers, so a member silently dropping to internal must
// fail here at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct JournalWorktreeScopeTests {

    // MARK: - Fixture ids

    /// Six ascending ids. Fixed literals so ordering is visible in the test.
    private let ids: [JournalEntryID]

    init() throws {
        var parsed: [JournalEntryID] = []
        for suffix in ["01", "02", "03", "04", "05", "06"] {
            parsed.append(try Self.id(suffix))
        }
        ids = parsed
    }

    private static func id(_ suffix: String) throws -> JournalEntryID {
        let base = "010000000000000000000000"
        return try #require(JournalEntryID(base + suffix))
    }

    private func normal(_ index: Int, in worktree: String?) -> JournalWorktreeScope.Node {
        JournalWorktreeScope.Node(
            node: JournalChain.Node(id: ids[index]), worktree: worktree)
    }

    private func traversal(
        _ index: Int, restored: Int, resultingPosition: Int?, in worktree: String?
    ) -> JournalWorktreeScope.Node {
        JournalWorktreeScope.Node(
            node: JournalChain.Node(
                id: ids[index],
                traversal: JournalChain.Traversal(
                    restored: ids[restored],
                    resultingPosition: resultingPosition.map { ids[$0] })),
            worktree: worktree)
    }

    // MARK: - Scoping

    @Test func scopedStateWalksOnlyTheCallersWorktreeEntries() throws {
        // Interleaved checkpoints from two worktrees: main, agent-a, main,
        // agent-a. Each worktree's undo must target its own newest entry.
        let nodes = [
            normal(0, in: nil), normal(1, in: "agent-a"),
            normal(2, in: nil), normal(3, in: "agent-a"),
        ]
        let main = try JournalWorktreeScope.state(of: nodes, in: nil)
        #expect(main.undoTarget == ids[2])
        let agent = try JournalWorktreeScope.state(of: nodes, in: "agent-a")
        #expect(agent.undoTarget == ids[3])
    }

    @Test func aSiblingsCheckpointDoesNotTruncateTheCallersRedoRun() throws {
        // Main checkpoints twice, undoes once (cursor on entry 1, redo run
        // open), then the agent-a sibling checkpoints. A repository-wide
        // chain would read that newer normal entry as a truncation and
        // main's redo would be gone; the per-worktree chain must not.
        let nodes = [
            normal(0, in: nil),
            normal(1, in: nil),
            traversal(2, restored: 1, resultingPosition: 1, in: nil),
            normal(3, in: "agent-a"),
        ]
        let main = try JournalWorktreeScope.state(of: nodes, in: nil)
        #expect(main.cursor == ids[1])
        #expect(main.undoTarget == ids[0])
        #expect(main.redoTarget == .present(capturedBy: ids[2]))

        // And the sibling's own chain is untouched by main's run.
        let agent = try JournalWorktreeScope.state(of: nodes, in: "agent-a")
        #expect(agent.cursor == nil)
        #expect(agent.undoTarget == ids[3])
        #expect(agent.redoTarget == nil)
    }

    @Test func singleWorktreeJournalMatchesTheUnscopedChain() throws {
        // Degeneracy: with every entry in the main worktree, scoping must
        // change nothing against JournalChain on the same list.
        let nodes = [
            normal(0, in: nil), normal(1, in: nil),
            traversal(2, restored: 1, resultingPosition: 1, in: nil),
        ]
        let scoped = try JournalWorktreeScope.state(of: nodes, in: nil)
        let unscoped = try JournalChain.state(of: nodes.map(\.node))
        #expect(scoped == unscoped)
    }

    @Test func foreignWorktreeSeesAnEmptyChain() throws {
        let nodes = [normal(0, in: nil), normal(1, in: "agent-a")]
        let state = try JournalWorktreeScope.state(of: nodes, in: "agent-b")
        #expect(state.cursor == nil)
        #expect(state.undoTarget == nil)
        #expect(state.redoTarget == nil)
        #expect(state.protectedIDs.isEmpty)
    }

    @Test func unorderedNodesStillThrowTheChainsOrderError() throws {
        let nodes = [normal(1, in: nil), normal(0, in: nil)]
        #expect(throws: JournalChain.Error.unordered(
            previous: ids[1], next: ids[0])
        ) {
            try JournalWorktreeScope.state(of: nodes, in: nil)
        }
    }

    // MARK: - Protection across worktrees

    @Test func protectedIDsUnionEveryLiveWorktreesRun() throws {
        // Both worktrees are mid-run: each protects its own cursor and the
        // traversal above it. Pruning is repository-wide, so the prune
        // composition needs the union.
        let nodes = [
            normal(0, in: nil),
            normal(1, in: "agent-a"),
            traversal(2, restored: 0, resultingPosition: 0, in: nil),
            traversal(3, restored: 1, resultingPosition: 1, in: "agent-a"),
        ]
        let protected = try JournalWorktreeScope.protectedIDs(
            of: nodes, live: [nil, "agent-a"])
        #expect(protected == [ids[0], ids[1], ids[2], ids[3]])
    }

    @Test func aDeletedWorktreesRunStopsProtecting() throws {
        // Same journal, but agent-a's worktree no longer exists: its open
        // run must not pin entries forever, so only main's run protects.
        let nodes = [
            normal(0, in: nil),
            normal(1, in: "agent-a"),
            traversal(2, restored: 0, resultingPosition: 0, in: nil),
            traversal(3, restored: 1, resultingPosition: 1, in: "agent-a"),
        ]
        let protected = try JournalWorktreeScope.protectedIDs(
            of: nodes, live: [nil])
        #expect(protected == [ids[0], ids[2]])
    }
}
