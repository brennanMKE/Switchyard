// PendingResolveStoreTests.swift — the app side's pending resolve state (#0057)
//
// The store is package-side precisely so these run without the app: one
// pending per repository, supersede (NOT queue — the review semantics), the
// typed timeout, and resolution. No assertion reads a clock (Rule 7c) — the
// timeout test uses a SHORT real timeout (1 s) and asserts the typed outcome,
// never elapsed time; registration waits are bounded polls, not sleeps.

import Foundation
import Testing
@testable import YardKit

@Suite("PendingResolveStore")
struct PendingResolveStoreTests {

    private let commonDir = "/repos/fixture/.git"

    private func resolution(path: String, choice: PathChoice) -> PathResolution {
        PathResolution(path: path, kind: .bothModified, choice: choice)
    }

    private func reply(resolutions: [PathResolution]) -> ResolveReply {
        .resolutions(resolutions)
    }

    /// Bounded wait for a store state, in the same shape
    /// `PendingReviewStoreTests` waits. Fails the test when the state never
    /// arrives, rather than hanging.
    private func waitUntil(
        timeout: Duration = .seconds(60),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited store state was never reached")
    }

    @Test func decidedReplyIsDeliveredToTheWaiter() async throws {
        let store = PendingResolveStore()
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingResolves.isEmpty }

        #expect(store.pendingResolves.count == 1, "one pending resolve per repository")
        let pending = try #require(store.pendingResolves.first,
                                   "the pending resolve must be observable for the pane")
        #expect(pending.request == request)

        let answer = reply(resolutions: [resolution(path: "f.txt", choice: .useOurs)])
        #expect(store.resolve(commonDir: commonDir, answer: answer))
        #expect(await outcome == .decided(answer))
        #expect(store.pendingResolves.isEmpty, "a resolved request leaves nothing pending")
    }

    @Test func cancelledReplyIsADecidedOutcome() async throws {
        let store = PendingResolveStore()
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingResolves.isEmpty }

        #expect(store.resolve(id: store.pendingResolves.first!.id, answer: .cancelled))
        #expect(await outcome == .decided(.cancelled),
                "cancel rides the decided case — it is a human decision, not a failure")
        #expect(store.pendingResolves.isEmpty)
    }

    @Test func resolveByIDDeliversToTheSameWaiter() async throws {
        let store = PendingResolveStore()
        let request = ResolveRequest(commonDir: commonDir, pathspec: "f.txt", timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingResolves.isEmpty }

        let pending = try #require(store.pendingResolves.first)
        #expect(pending.request.pathspec == "f.txt", "the pane must see the request's scope")
        let answer = reply(resolutions: [resolution(path: "f.txt", choice: .useTheirs)])
        #expect(store.resolve(id: pending.id, answer: answer))
        #expect(await outcome == .decided(answer))
        #expect(store.pendingResolves.isEmpty)
    }

    /// A SHORT real timeout (1 s). What is asserted is the typed outcome and
    /// the cleanup — never elapsed time.
    @Test func timeoutFiresTheTypedOutcomeAndCleansUp() async throws {
        let store = PendingResolveStore()
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 1)

        let outcome = await store.awaitDecision(for: request)

        #expect(outcome == .timedOut, "an unanswered wait is a typed timeout, not a decision")
        #expect(store.pendingResolves.isEmpty, "a timed-out request leaves nothing pending")
    }

    /// The supersede rule — the review semantics, not ask's queue: a second
    /// request for the same repository replaces the first, and the FIRST
    /// waiter receives a typed superseded outcome. Both requests carry a 3 s
    /// timeout so that even a mutation leaving two pendings concurrent fails
    /// this test in seconds rather than hanging the suite.
    @Test func secondRequestForTheSameRepositorySupersedesTheFirst() async throws {
        let store = PendingResolveStore()
        let first = ResolveRequest(commonDir: commonDir, timeoutSeconds: 3)
        let second = ResolveRequest(commonDir: commonDir, pathspec: "f.txt", timeoutSeconds: 3)

        async let firstOutcome = store.awaitDecision(for: first)
        try await waitUntil { store.pendingResolves.contains { $0.request == first } }

        async let secondOutcome = store.awaitDecision(for: second)
        try await waitUntil { store.pendingResolves.contains { $0.request == second } }

        #expect(store.pendingResolves.count == 1,
                "exactly one pending remains per repository; got \(store.pendingResolves.count)")
        let pending = try #require(store.pendingResolves.first)
        #expect(pending.request == second, "the pending that remains is the newer request")

        let supersededOutcome = await firstOutcome
        #expect(supersededOutcome == .superseded,
                "the superseded waiter must receive the superseded outcome, got \(supersededOutcome)")

        let pendingID = try #require(store.pendingResolves.first?.id)
        #expect(store.resolve(id: pendingID, answer: .cancelled))
        #expect(await secondOutcome == .decided(.cancelled))
        #expect(store.pendingResolves.isEmpty)
    }

    @Test func requestsForDifferentRepositoriesAreIndependent() async throws {
        let store = PendingResolveStore()
        let a = ResolveRequest(commonDir: "/repos/a/.git", timeoutSeconds: 60)
        let b = ResolveRequest(commonDir: "/repos/b/.git", timeoutSeconds: 60)

        async let outcomeA = store.awaitDecision(for: a)
        try await waitUntil { store.pendingResolves.count == 1 }

        async let outcomeB = store.awaitDecision(for: b)
        try await waitUntil { store.pendingResolves.count == 2 }

        let answerA = reply(resolutions: [resolution(path: "a.txt", choice: .useOurs)])
        #expect(store.resolve(commonDir: "/repos/a/.git", answer: answerA))
        #expect(await outcomeA == .decided(answerA))
        #expect(store.pendingResolves.count == 1, "resolving a must not touch b")

        #expect(store.resolve(commonDir: "/repos/b/.git", answer: .cancelled))
        #expect(await outcomeB == .decided(.cancelled))
        #expect(store.pendingResolves.isEmpty)
    }

    @Test func resolvingAnUnknownRepositoryOrIDReturnsFalse() {
        let store = PendingResolveStore()
        #expect(store.resolve(commonDir: "/repos/none/.git", answer: .cancelled) == false)
        #expect(store.resolve(id: UUID(), answer: .cancelled) == false)
        #expect(store.pendingResolves.isEmpty)
    }

    // MARK: - The change hook (round 2's pane observation seam)

    /// Collects `(pending, outcome)` events on the hook's own queue; reads
    /// are bounded polls, so no test reads a clock.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(PendingResolveStore.Pending, ResolveOutcome?)] = []
        func record(_ pending: PendingResolveStore.Pending, _ outcome: ResolveOutcome?) {
            lock.lock()
            items.append((pending, outcome))
            lock.unlock()
        }
        var all: [(PendingResolveStore.Pending, ResolveOutcome?)] {
            lock.withLock { items }
        }
    }

    @Test func registrationFiresTheHookWithNoOutcome() async throws {
        let store = PendingResolveStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingResolves.isEmpty }

        let registered = try #require(events.all.last, "registration must fire the hook")
        #expect(registered.0.request == request)
        #expect(registered.1 == nil, "a registration carries no outcome")

        #expect(store.resolve(commonDir: commonDir, answer: .cancelled))
        #expect(await outcome == .decided(.cancelled))
    }

    @Test func resolutionFiresTheHookWithTheTypedOutcome() async throws {
        let store = PendingResolveStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let expected = reply(resolutions: [resolution(path: "f.txt", choice: .keepDeletion)])
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 60)

        async let outcome = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingResolves.isEmpty }
        #expect(store.resolve(commonDir: commonDir, answer: expected))
        #expect(await outcome == .decided(expected))

        let finished = try #require(events.all.last, "resolution must fire the hook")
        #expect(finished.0.request == request)
        #expect(finished.1 == .decided(expected))
    }

    @Test func supersedeFiresTheHookWithSupersededForTheOlderPending() async throws {
        let store = PendingResolveStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 60)

        async let first = store.awaitDecision(for: request)
        try await waitUntil { !store.pendingResolves.isEmpty }
        let oldPending = try #require(store.pendingResolves.first)
        let secondRequest = ResolveRequest(commonDir: commonDir, pathspec: "g.txt", timeoutSeconds: 60)
        async let secondOutcome = store.awaitDecision(for: secondRequest)
        try await waitUntil { store.pendingResolves.count == 1 }

        #expect(await first == .superseded)
        let superseded = try #require(
            events.all.last(where: { $0.1 == .superseded }),
            "the replaced request must be reported as superseded")
        #expect(superseded.0.id == oldPending.id)
        #expect(superseded.0.request == oldPending.request)

        #expect(store.resolve(commonDir: commonDir, answer: .cancelled))
        #expect(await secondOutcome == .decided(.cancelled))
    }

    @Test func timeoutFiresTheHookWithTimedOut() async throws {
        let store = PendingResolveStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let request = ResolveRequest(commonDir: commonDir, timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: request)
        #expect(await outcome == .timedOut)

        let timedOut = try await AppConnection.poll(timeout: .seconds(60), interval: .milliseconds(10)) {
            events.all.last { $0.1 == .timedOut }
        }
        let event = try #require(timedOut, "the typed timeout must fire the hook")
        #expect(event.0.request == request)
        #expect(store.pendingResolves.isEmpty)
    }
}
