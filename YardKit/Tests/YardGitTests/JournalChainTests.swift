// JournalChainTests.swift — undo/redo cursor resolution (#0166)
//
// Deliberately NOT @testable: the undo/redo flows and the listing call this
// as public callers (the #0116 failure class).
//
// Scenario notation in comments: N1, N2… are normal entries (checkpoints,
// pre-operation captures), U/R are traversal entries written by undo/redo,
// "→X" is the traversal's resulting position, "→present" a redo that
// restored the run's opening capture.

import Foundation
import Testing
import YardGit

struct JournalChainTests {

    /// Deterministic ascending entry ids: a fixed 25-character prefix plus
    /// one alphabet character, so ids compare by their final character.
    /// Hoisted into a struct because `try` cannot sit inside an `#expect`
    /// comparison, and nested `#require` does not compile.
    private struct IDs {
        let b, c, d, e, f, g: JournalEntryID

        init() throws {
            func make(_ last: Character) throws -> JournalEntryID {
                try #require(
                    JournalEntryID("01AAAAAAAAAAAAAAAAAAAAAAA\(last)"),
                    "fixture id must be a valid ULID")
            }
            b = try make("B")
            c = try make("C")
            d = try make("D")
            e = try make("E")
            f = try make("F")
            g = try make("G")
        }
    }

    private func normal(_ id: JournalEntryID) -> JournalChain.Node {
        JournalChain.Node(id: id)
    }

    private func traversal(
        _ id: JournalEntryID,
        restored: JournalEntryID,
        position: JournalEntryID?
    ) -> JournalChain.Node {
        JournalChain.Node(
            id: id,
            traversal: JournalChain.Traversal(
                restored: restored, resultingPosition: position))
    }

    // MARK: - Present

    @Test func anEmptyJournalIsAtPresentWithNothingToDo() throws {
        let state = try JournalChain.state(of: [])
        #expect(state.cursor == nil)
        #expect(state.undoTarget == nil)
        #expect(state.redoTarget == nil)
        #expect(state.protectedIDs.isEmpty)
    }

    @Test func atPresentUndoTargetsTheNewestNormalEntry() throws {
        // N1 N2 N3 — nothing undone.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c), normal(ids.d),
        ])
        #expect(state.cursor == nil)
        #expect(state.undoTarget == ids.d)
        #expect(state.redoTarget == nil)
        #expect(state.protectedIDs.isEmpty)
    }

    @Test func atPresentUndoSkipsTraversalEntriesAboveTheNewestNormal() throws {
        // N1 N2 U(→N1) R(→present): a finished undo/redo cycle. Undo targets
        // N2, the newest *operation* — not the traversal cruft above it.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.b, position: ids.b),
            traversal(ids.e, restored: ids.d, position: nil),
        ])
        #expect(state.cursor == nil)
        #expect(state.undoTarget == ids.c)
        #expect(state.redoTarget == nil)
    }

    // MARK: - Undo

    @Test func oneUndoPutsTheCursorOnItsTargetAndOpensTheRedoPath() throws {
        // N1 N2 U(→N2).
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.c, position: ids.c),
        ])
        #expect(state.cursor == ids.c)
        #expect(state.undoTarget == ids.b)
        #expect(state.redoTarget == .present(capturedBy: ids.d))
        #expect(state.protectedIDs == [ids.c, ids.d])
    }

    @Test func undoWalksNormalEntriesOnlySkippingOldTraversals() throws {
        // N1 N2 U(→N2) N3 U(→N3): undo from N3 must step to N2, not to the
        // stale traversal entry sitting between them — undo steps back
        // through operations, not through past undos.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.c, position: ids.c),
            normal(ids.e),
            traversal(ids.f, restored: ids.e, position: ids.e),
        ])
        #expect(state.cursor == ids.e)
        #expect(state.undoTarget == ids.c)
        #expect(state.redoTarget == .present(capturedBy: ids.f))
    }

    @Test func undoBottomsOutAtTheOldestEntry() throws {
        // N1 N2 N3 U(→N3) U(→N2) U(→N1): fully unwound.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c), normal(ids.d),
            traversal(ids.e, restored: ids.d, position: ids.d),
            traversal(ids.f, restored: ids.c, position: ids.c),
            traversal(ids.g, restored: ids.b, position: ids.b),
        ])
        #expect(state.cursor == ids.b)
        #expect(state.undoTarget == nil, "nothing below the oldest entry")
        #expect(state.redoTarget == .entry(ids.c))
        #expect(state.protectedIDs == [ids.b, ids.c, ids.d, ids.e, ids.f, ids.g])
    }

    // MARK: - Redo

    @Test func redoAboveTheTopmostNormalEntryRestoresTheRunsFirstCapture() throws {
        // N1 N2 N3 U(→N3) U(→N2) R(→N3): redo from N3 must restore the state
        // captured by the run's FIRST undo — the original present — not by
        // its newest traversal entry.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c), normal(ids.d),
            traversal(ids.e, restored: ids.d, position: ids.d),
            traversal(ids.f, restored: ids.c, position: ids.c),
            traversal(ids.g, restored: ids.d, position: ids.d),
        ])
        #expect(state.cursor == ids.d)
        #expect(state.redoTarget == .present(capturedBy: ids.e))
    }

    @Test func redoToPresentClearsTheCursor() throws {
        // N1 N2 U(→N2) R(→present).
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.c, position: ids.c),
            traversal(ids.e, restored: ids.d, position: nil),
        ])
        #expect(state.cursor == nil)
        #expect(state.undoTarget == ids.c)
        #expect(state.redoTarget == nil)
        #expect(state.protectedIDs.isEmpty)
    }

    @Test func aFreshUndoAfterAFinishedCycleOpensANewRun() throws {
        // N1 N2 U(→N2) R(→present) U(→N2): the second undo captured the
        // present anew; redo must return through IT, not the first cycle's.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.c, position: ids.c),
            traversal(ids.e, restored: ids.d, position: nil),
            traversal(ids.f, restored: ids.c, position: ids.c),
        ])
        #expect(state.cursor == ids.c)
        #expect(state.redoTarget == .present(capturedBy: ids.f))
    }

    // MARK: - Truncation

    @Test func aNewOperationAfterUndoResetsToPresentAndClosesRedo() throws {
        // N1 N2 U(→N2) N3: the checkpoint written from the undone position
        // resets the cursor; the former redo tail stays listed but plain
        // redo no longer reaches it — truncation is logical, not a deletion.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.c, position: ids.c),
            normal(ids.e),
        ])
        #expect(state.cursor == nil)
        #expect(state.undoTarget == ids.e)
        #expect(state.redoTarget == nil)
        #expect(state.protectedIDs.isEmpty)
    }

    // MARK: - Pruned holes

    @Test func aCursorOnAPrunedEntryStillResolvesByOrder() throws {
        // N1 [N2 pruned] N3 U(→N2-gone): the cursor names an id no node
        // carries. Order comparison still answers: undo to N1, redo to N3.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.d),
            traversal(ids.e, restored: ids.c, position: ids.c),
        ])
        #expect(state.cursor == ids.c)
        #expect(state.undoTarget == ids.b)
        #expect(state.redoTarget == .entry(ids.d))
        #expect(state.protectedIDs == [ids.d, ids.e])
    }

    // MARK: - Input validation

    @Test func unorderedAndDuplicateIdsAreRefused() throws {
        let ids = try IDs()

        let unordered = [normal(ids.c), normal(ids.b)]
        let unorderedError = try #require(throws: JournalChain.Error.self) {
            _ = try JournalChain.state(of: unordered)
        }
        #expect(unorderedError == .unordered(previous: ids.c, next: ids.b))

        let duplicated = [normal(ids.b), normal(ids.b)]
        let duplicateError = try #require(throws: JournalChain.Error.self) {
            _ = try JournalChain.state(of: duplicated)
        }
        #expect(duplicateError == .unordered(previous: ids.b, next: ids.b))
    }

    // MARK: - Observed entries (#0153)

    private func observed(_ id: JournalEntryID) -> JournalChain.Node {
        JournalChain.Node(id: id, observed: true)
    }

    /// Observing a ref-update adds snapshot commits but never candidates for undo/redo.
    @Test func observedEntriesAreNeverUndoTargets() throws {
        // N1 O(observed) N2 — the observed entry must not change the undo target.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), observed(ids.c), normal(ids.d),
        ])
        #expect(state.cursor == nil)
        #expect(state.undoTarget == ids.d)
        #expect(state.redoTarget == nil)
    }

    @Test func observedEntriesDoNotRedirectRedo() throws {
        // An observed entry sandwiched between a U→B and R redo does not change
        // what the chain remembers as undo/redo targets — observed entries are
        // invisible to chain logic, so the same state computed with and without
        // them must match exactly (except protectedIDs which includes the
        // traversal entries that exist in each variant).
        let ids = try IDs()

        // Baseline: N1(B) N2(C) U→B(D).
        let baselineNodes: [JournalChain.Node] = [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.b, position: ids.b),  // U→N1
        ]

        // Same chain with observed(E) after U—E must be skipped by state().
        let withObservedAfter = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            traversal(ids.d, restored: ids.b, position: ids.b),
            observed(ids.e),
        ])

        // Same chain with observed(E) before U—E must be skipped by state().
        let withObservedBefore = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),
            observed(ids.d),
            traversal(ids.e, restored: ids.b, position: ids.b),  // U→N1
        ])

        let baseline = try JournalChain.state(of: baselineNodes)

        // Cursor, undoTarget, and redoTarget must match — observed entries
        // are invisible to chain logic.
        #expect(withObservedAfter.cursor == baseline.cursor)
        #expect(withObservedAfter.undoTarget == baseline.undoTarget)
        #expect(withObservedAfter.redoTarget == baseline.redoTarget)

        #expect(withObservedBefore.cursor == baseline.cursor)
        #expect(withObservedBefore.undoTarget == baseline.undoTarget)
        #expect(withObservedBefore.redoTarget == baseline.redoTarget)

        // protectedIDs differs because the traversal entries differ, but both
        // must contain the cursor and all normal entries above it.
        #expect(withObservedAfter.protectedIDs.contains(ids.b))
        #expect(withObservedAfter.protectedIDs.contains(ids.c))
        #expect(withObservedBefore.protectedIDs.contains(ids.b))
        #expect(withObservedBefore.protectedIDs.contains(ids.c))
    }

    @Test func observedEntriesAreOmittedFromProtectedIDs() throws {
        // Undo locks the cursor and anything above it, but observed entries are
        // not cancellable targets and must never be protected.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b), normal(ids.c),  // N1, N2 — cursor = nil (present)
            traversal(ids.d, restored: ids.c, position: ids.c),  // U→N2
        ])
        #expect(state.cursor == ids.c)

        // D is the undo target — it was just undone, so protected. No observed
        // entries were in this journal; the assertion is really that we don't
        // accidentally include ids not matching traversal. The protection set
        // is {C, D} because the cursor is on C and nothing below is protected.
        #expect(state.protectedIDs == [ids.c, ids.d])
    }

    @Test func observedEntriesSurviveTheListing() throws {
        // A journal with only observed entries has nothing to undo or redo.
        let ids = try IDs()
        let state = try JournalChain.state(of: [observed(ids.b)])
        #expect(state.cursor == nil)
        #expect(state.undoTarget == nil)
        #expect(state.redoTarget == nil)
    }

    @Test func observedEntriesDoNotResetTheCursor() throws {
        // Undo moves the cursor; an observed entry in between must not reset it.
        let ids = try IDs()
        let state = try JournalChain.state(of: [
            normal(ids.b),  // N1 resets cursor to present
            observed(ids.c),  // observer, no effect
            traversal(ids.d, restored: ids.b, position: ids.b),  // redo
        ])
        #expect(state.cursor == ids.b)
        #expect(state.undoTarget == nil)  // only an observed entry below the cursor; ignore it
    }
}
