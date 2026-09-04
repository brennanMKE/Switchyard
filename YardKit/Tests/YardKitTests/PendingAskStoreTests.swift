// PendingAskStoreTests.swift — the app side's pending ask state (#0056)
//
// The store is package-side precisely so these run without the app: the
// FIFO queue per repository, the head-only timeout (a queued ask's clock
// starts when it reaches the head), the typed timeout, and resolution —
// including the decline, which is a decided reply with declined semantics.
// No assertion reads a clock (Rule 7c): the timeout tests use SHORT real
// timeouts (1-2 s) and assert the typed outcome, never elapsed time;
// registration waits are bounded polls, not sleeps.

import Foundation
import Testing
@testable import YardKit

@Suite("PendingAskStore")
struct PendingAskStoreTests {

    private let commonDir = "/repos/fixture/.git"

    private func request(
        question: String = "Deploy now?",
        options: [String] = ["yes", "no"],
        timeoutSeconds: Int = 60,
        commonDir: String? = nil
    ) -> AskRequest {
        AskRequest(
            commonDir: commonDir ?? self.commonDir,
            question: question,
            options: options,
            timeoutSeconds: timeoutSeconds)
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

    @Test func decidedReplyIsDeliveredToTheHeadWaiter() async throws {
        let store = PendingAskStore()
        let ask = request()

        async let outcome = store.awaitDecision(for: ask)
        try await waitUntil { !store.pendingAsks.isEmpty }

        #expect(store.pendingAsks.count == 1, "one head per repository")
        let pending = try #require(store.pendingAsks.first,
                                   "the head must be observable for the sheet")
        #expect(pending.request == ask)

        let reply = AskReply.chosen(index: 1, text: "no", message: "not yet")
        #expect(store.resolve(commonDir: self.commonDir, answer: reply))
        #expect(await outcome == .decided(reply))
        #expect(store.pendingAsks.isEmpty, "a resolved ask leaves nothing pending")
        #expect(store.queue(for: self.commonDir).isEmpty)
    }

    @Test func resolveByIDDeliversToTheSameHeadWaiter() async throws {
        let store = PendingAskStore()
        let ask = request(question: "Ship?", options: ["a", "b", "c"])

        async let outcome = store.awaitDecision(for: ask)
        try await waitUntil { !store.pendingAsks.isEmpty }

        let pending = try #require(store.pendingAsks.first)
        let reply = AskReply.chosen(index: 2, text: "c")
        #expect(store.resolve(id: pending.id, answer: reply))
        #expect(await outcome == .decided(reply))
        #expect(store.pendingAsks.isEmpty)
    }

    /// The decline: a decided reply whose `declined` marker is what the CLI
    /// maps to exit 7 — never a timeout, never a forged option choice.
    @Test func declineResolvesAsADecidedReplyWithDeclinedSemantics() async throws {
        let store = PendingAskStore()
        let ask = request()

        async let outcome = store.awaitDecision(for: ask)
        try await waitUntil { !store.pendingAsks.isEmpty }

        let decline = AskReply.declined(message: "not my call")
        #expect(store.resolve(commonDir: self.commonDir, answer: decline))
        let resolved = try #require(await outcome, "the decline must resolve the waiter")
        guard case .decided(let reply) = resolved else {
            Issue.record("a decline is a decided reply, got \(resolved)")
            return
        }
        #expect(reply.declined == true)
        #expect(reply.optionIndex == nil, "a decline names no option")
        #expect(reply.optionText == nil)
        #expect(reply.message == "not my call")
        #expect(store.pendingAsks.isEmpty)
    }

    /// A SHORT real timeout (1 s) on the head. What is asserted is the
    /// typed outcome and the cleanup — never elapsed time.
    @Test func timeoutFiresTheTypedOutcomeAndCleansUp() async throws {
        let store = PendingAskStore()
        let ask = request(timeoutSeconds: 1)

        let outcome = await store.awaitDecision(for: ask)

        #expect(outcome == .timedOut, "an unanswered head is a typed timeout, not a decision")
        #expect(store.pendingAsks.isEmpty, "a timed-out ask leaves nothing pending")
    }

    /// THE queue rule — the one that differs from review: three asks for
    /// the same repository queue in order, the head is answered first, and
    /// answering the head presents the next. A queued ask may NOT be
    /// answered out of order.
    @Test func threeAsksForTheSameRepositoryQueueAndAnswerInOrder() async throws {
        let store = PendingAskStore()
        let first = request(question: "First?", timeoutSeconds: 60)
        let second = request(question: "Second?", timeoutSeconds: 60)
        let third = request(question: "Third?", timeoutSeconds: 60)

        async let firstOutcome = store.awaitDecision(for: first)
        try await waitUntil { !store.pendingAsks.isEmpty }
        async let secondOutcome = store.awaitDecision(for: second)
        try await waitUntil { store.queue(for: self.commonDir).count == 2 }
        async let thirdOutcome = store.awaitDecision(for: third)
        try await waitUntil { store.queue(for: self.commonDir).count == 3 }

        // One head, three queued — the second and third did not supersede.
        #expect(store.pendingAsks.count == 1, "one presented ask per repository")
        var queue = store.queue(for: self.commonDir)
        #expect(queue.count == 3, "the second ask must queue, not replace; got \(queue.count)")
        #expect(queue.map(\.request.question) == ["First?", "Second?", "Third?"],
                "the queue preserves registration order")
        #expect(store.pendingAsks.first?.id == queue.first?.id,
                "the presented ask IS the head of the queue")

        // Out of order is refused: only the head may resolve.
        let queuedSecond = try #require(queue[safe: 1])
        let queuedThird = try #require(queue[safe: 2])
        #expect(store.resolve(id: queuedSecond.id, answer: AskReply.chosen(index: 0, text: "yes")) == false,
                "a queued ask must not be answerable ahead of the head")
        #expect(store.resolve(id: queuedThird.id, answer: AskReply.declined()) == false)

        // Answering the head presents the next.
        #expect(store.resolve(id: queue[0].id, answer: AskReply.chosen(index: 0, text: "yes")))
        #expect(await firstOutcome == .decided(AskReply.chosen(index: 0, text: "yes")))
        try await waitUntil { store.queue(for: self.commonDir).count == 2 }
        queue = store.queue(for: self.commonDir)
        #expect(queue.first?.request.question == "Second?", "answering the head presents the next")
        #expect(store.pendingAsks.count == 1)

        #expect(store.resolve(commonDir: self.commonDir, answer: AskReply.declined()))
        #expect(await secondOutcome == .decided(AskReply.declined()))
        try await waitUntil { store.queue(for: self.commonDir).count == 1 }

        #expect(store.resolve(commonDir: self.commonDir, answer: AskReply.chosen(index: 1, text: "no")))
        #expect(await thirdOutcome == .decided(AskReply.chosen(index: 1, text: "no")))
        #expect(store.pendingAsks.isEmpty)
        #expect(store.queue(for: self.commonDir).isEmpty)
    }

    /// The timer rule: a queued ask's clock starts when it reaches the
    /// head, not at registration. B carries a 1 s timeout while queued
    /// behind a 60 s A — it must NOT fire while it waits; once A resolves,
    /// B's clock starts and B times out.
    @Test func aQueuedAsksTimerStartsWhenItReachesTheHead() async throws {
        let store = PendingAskStore()
        let head = request(question: "Head?", timeoutSeconds: 60)
        let queued = request(question: "Queued?", timeoutSeconds: 1)

        async let headOutcome = store.awaitDecision(for: head)
        try await waitUntil { !store.pendingAsks.isEmpty }
        async let queuedOutcome = store.awaitDecision(for: queued)
        try await waitUntil { store.queue(for: self.commonDir).count == 2 }

        // Longer than the queued ask's whole timeout: if its clock had
        // started at registration, it would have fired by now. A bounded
        // poll that must NOT find the queue drained — nil is the pass.
        let firedEarly = try await AppConnection.poll(
            timeout: .seconds(1.3), interval: .milliseconds(20)) {
            store.queue(for: self.commonDir).count < 2 ? true : nil
        }
        #expect(firedEarly == nil,
                "a queued ask's timer must not start until it reaches the head")
        #expect(store.queue(for: self.commonDir).count == 2)

        // The head resolves; the queued ask is promoted and ITS clock
        // starts — it times out on its own 1 s.
        #expect(store.resolve(id: store.pendingAsks.first?.id ?? UUID(),
                              answer: AskReply.chosen(index: 0, text: "yes")))
        #expect(await headOutcome == .decided(AskReply.chosen(index: 0, text: "yes")))
        #expect(await queuedOutcome == .timedOut,
                "the promoted ask's own timeout fires once it is the head")
        #expect(store.pendingAsks.isEmpty)
    }

    @Test func asksForDifferentRepositoriesAreIndependent() async throws {
        let store = PendingAskStore()
        let a = request(commonDir: "/repos/a/.git")
        let b = request(commonDir: "/repos/b/.git")

        async let outcomeA = store.awaitDecision(for: a)
        try await waitUntil { store.pendingAsks.count == 1 }

        async let outcomeB = store.awaitDecision(for: b)
        try await waitUntil { store.pendingAsks.count == 2 }

        #expect(store.resolve(commonDir: "/repos/a/.git", answer: AskReply.chosen(index: 0, text: "yes")))
        #expect(await outcomeA == .decided(AskReply.chosen(index: 0, text: "yes")))
        #expect(store.pendingAsks.count == 1, "resolving a must not touch b")
        #expect(store.queue(for: "/repos/b/.git").count == 1,
                "b keeps its own queue, independent of a's")

        #expect(store.resolve(commonDir: "/repos/b/.git", answer: AskReply.declined()))
        #expect(await outcomeB == .decided(AskReply.declined()))
        #expect(store.pendingAsks.isEmpty)
    }

    @Test func resolvingAnUnknownRepositoryOrIDReturnsFalse() {
        let store = PendingAskStore()
        #expect(store.resolve(commonDir: "/repos/none/.git", answer: AskReply.declined()) == false)
        #expect(store.resolve(id: UUID(), answer: AskReply.declined()) == false)
        #expect(store.pendingAsks.isEmpty)
    }

    // MARK: - The change hook (the sheet's observation seam)

    /// Collects `(pending, outcome)` events on the hook's own queue; reads
    /// are bounded polls, so no test reads a clock.
    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(PendingAskStore.Pending, AskOutcome?)] = []
        func record(_ pending: PendingAskStore.Pending, _ outcome: AskOutcome?) {
            lock.lock()
            items.append((pending, outcome))
            lock.unlock()
        }
        var all: [(PendingAskStore.Pending, AskOutcome?)] {
            lock.withLock { items }
        }
    }

    @Test func registrationAndResolutionFireTheHook() async throws {
        let store = PendingAskStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let ask = request()

        async let outcome = store.awaitDecision(for: ask)
        try await waitUntil { !store.pendingAsks.isEmpty }

        let registered = try #require(events.all.last, "registration must fire the hook")
        #expect(registered.0.request == ask)
        #expect(registered.1 == nil, "a registration carries no outcome")

        let reply = AskReply.chosen(index: 1, text: "no")
        #expect(store.resolve(commonDir: self.commonDir, answer: reply))
        #expect(await outcome == .decided(reply))

        let finished = try #require(events.all.last, "resolution must fire the hook")
        #expect(finished.0.request == ask)
        #expect(finished.1 == .decided(reply))
    }

    @Test func timeoutFiresTheHookWithTimedOut() async throws {
        let store = PendingAskStore()
        let events = EventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let ask = request(timeoutSeconds: 1)

        async let outcome = store.awaitDecision(for: ask)
        #expect(await outcome == .timedOut)

        let timedOut = try await AppConnection.poll(timeout: .seconds(60), interval: .milliseconds(10)) {
            events.all.last { $0.1 == .timedOut }
        }
        let event = try #require(timedOut, "the typed timeout must fire the hook")
        #expect(event.0.request == ask)
        #expect(store.pendingAsks.isEmpty)
    }
}

extension Array {
    /// Bounds-checked index for `try #require` bindings — the queue tests
    /// must fail loudly, not trap, when the queue is shorter than expected.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
