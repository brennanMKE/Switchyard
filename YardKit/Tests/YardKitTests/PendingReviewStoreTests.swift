// PendingReviewStoreTests.swift — the app side's pending review state (#0055)
//
// The store is package-side precisely so these run without the app: one
// pending per repository, supersede semantics, the typed timeout, and
// resolution. No assertion reads a clock (Rule 7c) — the timeout test uses
// a SHORT real timeout (1 s) and asserts the typed outcome, never elapsed
// time; registration waits are bounded polls, not sleeps.

import Foundation
import Testing
@testable import YardKit

@Suite("PendingReviewStore")
struct PendingReviewStoreTests {

    private let commonDir = "/repos/fixture/.git"

    private func reply(decision: ReviewDecision) -> ReviewReply {
        ReviewReply(decision: decision, message: "looks good", comments: [], editedPatch: nil)
    }

    /// Bounded wait for a store state, in the same shape
    /// `AppConnectionTests` waits for XPC replies. Fails the test when the
    /// state never arrives, rather than hanging.
    private func waitUntil(
        timeout: Duration = .seconds(300),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited store state was never reached")
    }

    @Test func decidedReplyIsDeliveredToTheWaiter() async throws {
        let store = PendingReviewStore()
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingReviews.isEmpty }

        #expect(store.pendingReviews.count == 1, "one pending review per repository")
        let pending = try #require(store.pendingReviews.first,
                                   "the pending review must be observable for the sheet")
        #expect(pending.request == request)

        #expect(store.resolve(commonDir: commonDir, decision: reply(decision: .approve)))
        #expect(await outcome == .decided(reply(decision: .approve)))
        #expect(store.pendingReviews.isEmpty, "a resolved request leaves nothing pending")
    }

    @Test func resolveByIDDeliversToTheSameWaiter() async throws {
        let store = PendingReviewStore()
        let request = ReviewRequest(commonDir: commonDir, selector: .range("main..HEAD"), timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingReviews.isEmpty }

        let pending = try #require(store.pendingReviews.first)
        #expect(store.resolve(id: pending.id, decision: reply(decision: .amend)))
        #expect(await outcome == .decided(reply(decision: .amend)))
        #expect(store.pendingReviews.isEmpty)
    }

    /// A SHORT real timeout (1 s). What is asserted is the typed outcome and
    /// the cleanup — never elapsed time.
    @Test func timeoutFiresTheTypedOutcomeAndCleansUp() async throws {
        let store = PendingReviewStore()
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 1)

        let outcome = await store.awaitDecision(for: request)

        #expect(outcome == .timedOut, "an unanswered wait is a typed timeout, not a decision")
        #expect(store.pendingReviews.isEmpty, "a timed-out request leaves nothing pending")
    }

    /// The supersede rule: a second request for the same repository replaces
    /// the first, and the FIRST waiter receives a typed superseded outcome —
    /// not a timeout lie, not a decision. Both requests carry a 3 s timeout
    /// so that even a mutation leaving two pendings concurrent fails this
    /// test in seconds (the orphaned waiter times out into a wrong outcome)
    /// rather than hanging the suite.
    @Test func secondRequestForTheSameRepositorySupersedesTheFirst() async throws {
        let store = PendingReviewStore()
        let first = ReviewRequest(commonDir: commonDir, selector: .range("main..HEAD"), timeoutSeconds: 3)
        let second = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 3)

        async let firstOutcome = store.awaitDecision(for: first)
        try await waitUntil { store.pendingReviews.contains { $0.request == first } }

        async let secondOutcome = store.awaitDecision(for: second)
        try await waitUntil { store.pendingReviews.contains { $0.request == second } }

        #expect(store.pendingReviews.count == 1,
                "exactly one pending remains per repository; got \(store.pendingReviews.count)")
        let pending = try #require(store.pendingReviews.first)
        #expect(pending.request == second, "the pending that remains is the newer request")

        let supersededOutcome = await firstOutcome
        #expect(supersededOutcome == .superseded,
                "the superseded waiter must receive the superseded outcome, got \(supersededOutcome)")

        let pendingID = try #require(store.pendingReviews.first?.id)
        #expect(store.resolve(id: pendingID, decision: reply(decision: .reject)))
        #expect(await secondOutcome == .decided(reply(decision: .reject)))
        #expect(store.pendingReviews.isEmpty)
    }

    @Test func requestsForDifferentRepositoriesAreIndependent() async throws {
        let store = PendingReviewStore()
        let a = ReviewRequest(commonDir: "/repos/a/.git", selector: .staged, timeoutSeconds: 60)
        let b = ReviewRequest(commonDir: "/repos/b/.git", selector: .staged, timeoutSeconds: 60)

        async let outcomeA = store.awaitDecision(for: a)
        try await waitUntil { store.pendingReviews.count == 1 }

        async let outcomeB = store.awaitDecision(for: b)
        try await waitUntil { store.pendingReviews.count == 2 }

        #expect(store.resolve(commonDir: "/repos/a/.git", decision: reply(decision: .approve)))
        #expect(await outcomeA == .decided(reply(decision: .approve)))
        #expect(store.pendingReviews.count == 1, "resolving a must not touch b")

        #expect(store.resolve(commonDir: "/repos/b/.git", decision: reply(decision: .reject)))
        #expect(await outcomeB == .decided(reply(decision: .reject)))
        #expect(store.pendingReviews.isEmpty)
    }

    @Test func resolvingAnUnknownRepositoryOrIDReturnsFalse() {
        let store = PendingReviewStore()
        #expect(store.resolve(commonDir: "/repos/none/.git", decision: reply(decision: .approve)) == false)
        #expect(store.resolve(id: UUID(), decision: reply(decision: .approve)) == false)
        #expect(store.pendingReviews.isEmpty)
    }

    // MARK: - The change hook (round 2's sheet observation seam)

    /// Collects `(pending, outcome)` events on the hook's own queue; reads
    /// are bounded polls, so no test reads a clock.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(PendingReviewStore.Pending, ReviewOutcome?)] = []
        func record(_ pending: PendingReviewStore.Pending, _ outcome: ReviewOutcome?) {
            lock.lock()
            items.append((pending, outcome))
            lock.unlock()
        }
        var all: [(PendingReviewStore.Pending, ReviewOutcome?)] {
            lock.withLock { items }
        }
    }

    @Test func registrationFiresTheHookWithNoOutcome() async throws {
        let store = PendingReviewStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingReviews.isEmpty }

        let registered = try #require(events.all.last, "registration must fire the hook")
        #expect(registered.0.request == request)
        #expect(registered.1 == nil, "a registration carries no outcome")

        #expect(store.resolve(commonDir: commonDir, decision: reply(decision: .approve)))
        #expect(await outcome == .decided(reply(decision: .approve)))
    }

    @Test func resolutionFiresTheHookWithTheTypedOutcome() async throws {
        let store = PendingReviewStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let expected = reply(decision: .reject)
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingReviews.isEmpty }
        #expect(store.resolve(commonDir: commonDir, decision: expected))
        #expect(await outcome == .decided(expected))

        let finished = try #require(events.all.last, "resolution must fire the hook")
        #expect(finished.0.request == request)
        #expect(finished.1 == .decided(expected))
    }

    @Test func supersedeFiresTheHookWithSupersededForTheOlderPending() async throws {
        let store = PendingReviewStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 60)

        async let first = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingReviews.isEmpty }
        let oldPending = try #require(store.pendingReviews.first)
        let secondRequest = ReviewRequest(commonDir: commonDir, selector: .range("main..HEAD"), timeoutSeconds: 60)
        async let secondOutcome = store.awaitDecision(for: secondRequest)
        try await waitUntil { store.pendingReviews.count == 1 }

        #expect(await first == .superseded)
        let superseded = try #require(
            events.all.last(where: { $0.1 == .superseded }),
            "the replaced request must be reported as superseded")
        #expect(superseded.0.id == oldPending.id)
        #expect(superseded.0.request == oldPending.request)

        #expect(store.resolve(commonDir: commonDir, decision: reply(decision: .approve)))
        #expect(await secondOutcome == .decided(reply(decision: .approve)))
    }

    @Test func timeoutFiresTheHookWithTimedOut() async throws {
        let store = PendingReviewStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ReviewRequest(commonDir: commonDir, selector: .staged, timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: request)
        #expect(await outcome == .timedOut)

        let timedOut = try await AppConnection.poll(timeout: .seconds(300), interval: .milliseconds(10)) {
            events.all.last { $0.1 == .timedOut }
        }
        let event = try #require(timedOut, "the typed timeout must fire the hook")
        #expect(event.0.request == request)
        #expect(store.pendingReviews.isEmpty)
    }
}
