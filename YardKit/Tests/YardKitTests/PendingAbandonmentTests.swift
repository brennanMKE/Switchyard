// PendingAbandonmentTests.swift — the reaping policy and the .abandoned
// outcome across the three pending stores (#0349)
//
// An orphaned pending is one whose CLI connection is gone: the store marks
// it, the hook fires `.abandoned`, the pending STAYS registered and
// decidable, and its own timer remains the reaper. No assertion reads a
// clock (Rule 7c) — the reaper tests use SHORT real timeouts and assert the
// typed outcome, never elapsed time.

import Foundation
import Testing
@testable import YardKit

@Suite("Pending abandonment (#0349)")
struct PendingAbandonmentTests {

    private let commonDir = "/repos/fixture/.git"

    /// Bounded wait for a store state, the `PendingReviewStoreTests` shape.
    private func waitUntil(
        timeout: Duration = .seconds(300),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited store state was never reached")
    }

    // MARK: - Wire shape

    /// Each outcome encodes abandonment as the single key `"abandoned"` and
    /// decodes it back — the same one-key rule the other typed outcomes
    /// follow. Pins the wire shape byte-for-byte (sortedKeys).
    @Test func abandonedOutcomeRoundTripsThroughTheOneKeyWireShape() throws {
        let expected = Data(#"{"abandoned":true}"#.utf8)
        for data in [
            try JSONEncoder().encode(ReviewOutcome.abandoned),
            try JSONEncoder().encode(AskOutcome.abandoned),
            try JSONEncoder().encode(ResolveOutcome.abandoned),
        ] {
            #expect(data == expected, "the abandoned wire shape is the one true key, got \(String(decoding: data, as: UTF8.self))")
        }
        #expect(try JSONDecoder().decode(ReviewOutcome.self, from: expected) == .abandoned)
        #expect(try JSONDecoder().decode(AskOutcome.self, from: expected) == .abandoned)
        #expect(try JSONDecoder().decode(ResolveOutcome.self, from: expected) == .abandoned)
    }

    // MARK: - Review store

    @Test func abandonMarksTheReviewPendingAndItStaysDecidable() async throws {
        let store = PendingReviewStore()
        let owner = PendingOwner()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { !store.pendingReviews.isEmpty }

        #expect(store.abandonAll(ownedBy: owner) == 1, "the connection's pending is marked")
        let abandoned = try #require(
            events.reviewEvents.last(where: { $0.1 == .abandoned }),
            "the hook must fire .abandoned the moment the connection dies")
        #expect(abandoned.0.request == request)
        #expect(store.pendingReviews.count == 1,
                "abandonment is not a resolution — the pending stays for the sheet")

        let reply = ReviewReply(decision: .approve, message: nil, comments: [], editedPatch: nil)
        #expect(store.resolve(id: abandoned.0.id, decision: reply),
                "a decision after abandonment still resolves")
        #expect(await outcome == .decided(reply), "the waiter receives the late decision")
        #expect(store.pendingReviews.isEmpty)
    }

    /// The reaping policy's core claim: the per-pending timer is the reaper,
    /// and abandonment does not disarm it. A SHORT real timeout (1 s).
    @Test func abandonedReviewIsStillReapedByItsOwnTimer() async throws {
        let store = PendingReviewStore()
        let owner = PendingOwner()
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { !store.pendingReviews.isEmpty }
        #expect(store.abandonAll(ownedBy: owner) == 1)

        #expect(await outcome == .timedOut, "the abandoned pending's own timer reaps it")
        #expect(store.pendingReviews.isEmpty, "the reaper removes the orphan")
    }

    @Test func abandonNeverTouchesAnotherConnectionOrAnUnownedReview() async throws {
        let store = PendingReviewStore()
        let ownerA = PendingOwner()
        let ownerB = PendingOwner()
        let a = ReviewRequest(commonDir: "/repos/a/.git", selector: .staged, timeoutSeconds: 60)
        let b = ReviewRequest(commonDir: "/repos/b/.git", selector: .staged, timeoutSeconds: 60)
        let unowned = ReviewRequest(commonDir: "/repos/c/.git", selector: .staged, timeoutSeconds: 60)

        async let outcomeA = store.awaitDecision(for: a, owner: ownerA)
        async let outcomeB = store.awaitDecision(for: b, owner: ownerB)
        async let outcomeUnowned = store.awaitDecision(for: unowned)
        try await waitUntil { store.pendingReviews.count == 3 }

        #expect(store.abandonAll(ownedBy: ownerA) == 1,
                "exactly A's pending is marked — not B's, not an unowned one")
        #expect(store.abandonAll(ownedBy: ownerA) == 0, "abandonment is idempotent")
        #expect(store.abandonAll(ownedBy: PendingOwner()) == 0,
                "a fresh token matches nothing")

        let reply = ReviewReply(decision: .approve, message: nil, comments: [], editedPatch: nil)
        #expect(store.resolve(commonDir: "/repos/b/.git", decision: reply))
        #expect(await outcomeB == .decided(reply), "B's pending was never abandoned")
        #expect(store.resolve(commonDir: "/repos/c/.git", decision: reply))
        #expect(await outcomeUnowned == .decided(reply), "the unowned pending was never abandoned")
        #expect(store.resolve(commonDir: "/repos/a/.git", decision: reply))
        #expect(await outcomeA == .decided(reply), "the abandoned pending is still decidable")
    }

    // MARK: - Ask store

    @Test func abandonMarksEveryOwnedAskIncludingQueuedOnes() async throws {
        let store = PendingAskStore()
        let owner = PendingOwner()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let head = AskRequest(commonDir: commonDir, question: "head?", options: ["a", "b"], timeoutSeconds: 60)
        let queued = AskRequest(commonDir: commonDir, question: "queued?", options: ["c"], timeoutSeconds: 60)

        async let headOutcome = store.awaitDecision(for: head, owner: owner)
        try await waitUntil { !store.pendingAsks.isEmpty }
        async let queuedOutcome = store.awaitDecision(for: queued, owner: owner)
        try await waitUntil { store.queue(for: commonDir).count == 2 }

        #expect(store.abandonAll(ownedBy: owner) == 2, "head and queued ask are both marked")
        let abandoned = events.askEvents.filter { $0.1 == .abandoned }
        #expect(abandoned.count == 2, "the hook fires once per marked ask")
        #expect(abandoned.contains { $0.0.request == head })
        #expect(abandoned.contains { $0.0.request == queued })
        #expect(store.queue(for: commonDir).count == 2,
                "abandonment removes nothing — the queue order the sheet presents is unchanged")

        let answer = AskReply.chosen(index: 0, text: "a")
        let headPending = try #require(
            abandoned.first { $0.0.request == head },
            "the head ask must be among the abandoned")
        #expect(store.resolve(id: headPending.0.id, answer: answer))
        #expect(await headOutcome == .decided(answer), "a decision after abandonment still resolves")
        let promoted = try #require(
            store.queue(for: commonDir).first,
            "the queued ask must still be in the queue after the head resolved")
        #expect(store.resolve(id: promoted.id, answer: answer))
        #expect(await queuedOutcome == .decided(answer), "the promoted ask is still answerable")
        #expect(store.pendingAsks.isEmpty)
    }

    /// The abandoned head's timer is the reaper; the next queued ask
    /// promotes and arms ITS timer when the reaper fires. SHORT real
    /// timeouts (1 s each).
    @Test func abandonedAskIsStillReapedByItsOwnTimerAndTheQueueAdvances() async throws {
        let store = PendingAskStore()
        let owner = PendingOwner()
        let head = AskRequest(commonDir: commonDir, question: "head?", options: ["a"], timeoutSeconds: 1)
        let queued = AskRequest(commonDir: commonDir, question: "queued?", options: ["b"], timeoutSeconds: 1)

        async let headOutcome = store.awaitDecision(for: head, owner: owner)
        try await waitUntil { !store.pendingAsks.isEmpty }
        async let queuedOutcome = store.awaitDecision(for: queued, owner: owner)
        try await waitUntil { store.queue(for: commonDir).count == 2 }
        #expect(store.abandonAll(ownedBy: owner) == 2)

        #expect(await headOutcome == .timedOut, "the abandoned head's own timer reaps it")
        #expect(await queuedOutcome == .timedOut,
                "the queued ask promotes when the reaper fires, and ITS timer reaps it too")
        #expect(store.pendingAsks.isEmpty)
    }

    // MARK: - Resolve store

    @Test func abandonMarksTheResolvePendingAndItStaysDecidable() async throws {
        let store = PendingResolveStore()
        let owner = PendingOwner()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { !store.pendingResolves.isEmpty }

        #expect(store.abandonAll(ownedBy: owner) == 1)
        let abandoned = try #require(
            events.resolveEvents.last(where: { $0.1 == .abandoned }),
            "the hook must fire .abandoned the moment the connection dies")
        #expect(abandoned.0.request == request)
        #expect(store.pendingResolves.count == 1,
                "abandonment is not a resolution — the pending stays for the pane")

        let answer = ResolveReply.resolutions([])
        #expect(store.resolve(id: abandoned.0.id, answer: answer))
        #expect(await outcome == .decided(answer))
        #expect(store.pendingResolves.isEmpty)
    }

    @Test func abandonedResolveIsStillReapedByItsOwnTimer() async throws {
        let store = PendingResolveStore()
        let owner = PendingOwner()
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: request, owner: owner)
        try await waitUntil { !store.pendingResolves.isEmpty }
        #expect(store.abandonAll(ownedBy: owner) == 1)

        #expect(await outcome == .timedOut, "the abandoned pending's own timer reaps it")
        #expect(store.pendingResolves.isEmpty)
    }

    // MARK: - Hook event collector (the PendingReviewStoreTests shape)

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var reviewItems: [(PendingReviewStore.Pending, ReviewOutcome?)] = []
        private var askItems: [(PendingAskStore.Pending, AskOutcome?)] = []
        private var resolveItems: [(PendingResolveStore.Pending, ResolveOutcome?)] = []

        func record(_ pending: PendingReviewStore.Pending, _ outcome: ReviewOutcome?) {
            lock.withLock { reviewItems.append((pending, outcome)) }
        }

        func record(_ pending: PendingAskStore.Pending, _ outcome: AskOutcome?) {
            lock.withLock { askItems.append((pending, outcome)) }
        }

        func record(_ pending: PendingResolveStore.Pending, _ outcome: ResolveOutcome?) {
            lock.withLock { resolveItems.append((pending, outcome)) }
        }

        var reviewEvents: [(PendingReviewStore.Pending, ReviewOutcome?)] {
            lock.withLock { reviewItems }
        }

        var askEvents: [(PendingAskStore.Pending, AskOutcome?)] {
            lock.withLock { askItems }
        }

        var resolveEvents: [(PendingResolveStore.Pending, ResolveOutcome?)] {
            lock.withLock { resolveItems }
        }
    }
}
