// WatchSessionStoreTests.swift — the app side's watch sessions (#0058)
//
// The store is the memory criterion's structural half: push-based, no event
// history. These tests drive the real store directly — no XPC — the way
// `PendingAskStoreTests` drives the ask store. No assertion reads a clock
// (Rule 7c): the timeout test uses a SHORT real timeout and asserts the
// typed reason it produced, never elapsed time.

import Foundation
import Testing
@testable import YardKit

// MARK: - Collectors

/// Gathers what one session's push closure received. Lock-guarded because
/// the store calls it from broadcast while tests read from elsewhere.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [WatchEvent] = []
    private var _undecodable = 0

    func append(_ data: Data) {
        guard let event = try? JSONDecoder().decode(WatchEvent.self, from: data) else {
            lock.withLock { _undecodable += 1 }
            return
        }
        lock.withLock { _events.append(event) }
    }

    var events: [WatchEvent] { lock.withLock { _events } }
    var undecodableCount: Int { lock.withLock { _undecodable } }
}

@Suite("watch session store")
struct WatchSessionStoreTests {

    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited state was never reached")
    }

    // MARK: - Ordering and no-drop

    /// The ordering/no-drop contract, end to end at the store level: every
    /// broadcast reaches every session, numbered per session, in order,
    /// nothing dropped. Kills mutation 1 (drop every 10th event) and
    /// mutation 3 (start sequences at 0) of this round when applied to the
    /// store.
    @Test func broadcastNumbersEventsMonotonicallyPerSessionWithNoneDropped() async throws {
        let store = WatchSessionStore()
        let first = EventCollector()
        let second = EventCollector()

        let owner = PendingOwner()
        let firstTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: owner,
                push: { first.append($0) })
        }
        let secondTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: "/repos/a", timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { second.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 2 }

        let count = 200
        for index in 1...count {
            store.broadcast(kind: .appEvent, payload: ["note": .string("event-\(index)")])
        }

        // End both sessions so the registering tasks can complete.
        #expect(store.endAll(reason: .detached) == 2)
        #expect(await firstTask.value == .detached)
        #expect(await secondTask.value == .detached)

        let received = first.events
        #expect(received.count == count,
                "every event must arrive, got \(received.count) of \(count)")
        #expect(first.undecodableCount == 0, "every pushed byte must decode as a WatchEvent")
        // Sequence numbers 1...N, IN ARRIVAL ORDER — the ordering AND the
        // no-drop property in one assertion.
        #expect(received.map(\.sequence) == Array(1...count),
                "sequences must be 1...\(count) in arrival order; got \(received.map(\.sequence).prefix(20))…")
        for event in received {
            #expect(event.kind == .appEvent)
            #expect(event.payload["note"] == .string("event-\(event.sequence)"))
        }

        // The second session sees its OWN 1...N — numbering is per session.
        let secondReceived = second.events
        #expect(secondReceived.count == count)
        #expect(secondReceived.map(\.sequence) == Array(1...count))
    }

    // MARK: - Scoping

    /// `repositoryPath` scopes a broadcast: the all-repositories session
    /// sees every event; a scoped session sees exactly its own path's —
    /// and its sequence numbering only advances for events it receives.
    /// Kills a filter mutation (deliver everything regardless of scope) and
    /// an off-by-one in the per-session counters.
    @Test func scopedBroadcastReachesAllReposAndExactMatchSessionsOnly() async throws {
        let store = WatchSessionStore()
        let allRepos = EventCollector()
        let watchingA = EventCollector()
        let watchingB = EventCollector()

        let allTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { allRepos.append($0) })
        }
        let aTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: "/repos/a", timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { watchingA.append($0) })
        }
        let bTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: "/repos/b", timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { watchingB.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 3 }

        store.broadcast(kind: .appEvent, payload: ["note": .string("a1")], repositoryPath: "/repos/a")
        store.broadcast(kind: .appEvent, payload: ["note": .string("b1")], repositoryPath: "/repos/b")
        store.broadcast(kind: .appEvent, payload: ["note": .string("any")])

        #expect(store.endAll(reason: .detached) == 3)
        #expect(await allTask.value == .detached)
        #expect(await aTask.value == .detached)
        #expect(await bTask.value == .detached)

        // The all-repositories session saw all three, numbered 1, 2, 3.
        #expect(allRepos.events.map(\.payload["note"]) == [.string("a1"), .string("b1"), .string("any")])
        #expect(allRepos.events.map(\.sequence) == [1, 2, 3])

        // The /repos/a session saw its own path's event AND the unscoped
        // one (unscoped is for everyone) — never /repos/b's.
        #expect(watchingA.events.map(\.payload["note"]) == [.string("a1"), .string("any")])
        #expect(watchingA.events.map(\.sequence) == [1, 2])

        // The /repos/b session likewise — never /repos/a's.
        #expect(watchingB.events.map(\.payload["note"]) == [.string("b1"), .string("any")])
        #expect(watchingB.events.map(\.sequence) == [1, 2])
    }

    // MARK: - The no-history bound

    /// The memory criterion's structural half: after a thousand broadcasts
    /// the store holds exactly the registered sessions and nothing else —
    /// events are pushed through, never retained.
    @Test func storeRetainsNoEventHistoryOverABurst() async throws {
        let store = WatchSessionStore()
        let collector = EventCollector()

        let sessionTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { collector.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 1 }
        #expect(store.activeSessions.count == 1)

        let burst = 1000
        for index in 1...burst {
            store.broadcast(kind: .appEvent, payload: ["note": .string("event-\(index)")])
        }

        #expect(store.activeSessions.count == 1,
                "the store must still hold exactly the one session — nothing accumulated")
        #expect(store.activeSessions.first?.request.repositoryPath == nil)
        #expect(collector.events.count == burst, "the burst was delivered, not swallowed")

        #expect(store.endAll(reason: .detached) == 1)
        #expect(await sessionTask.value == .detached)
    }

    // MARK: - Ends

    /// The request's own timeout fires the typed `.timedOut` end.
    @Test func timeoutEndsTheSessionWithTheTypedReason() async throws {
        let store = WatchSessionStore()
        let collector = EventCollector()

        let reason = await store.register(
            request: WatchRequest(repositoryPath: nil, timeoutSeconds: 1),
            owner: PendingOwner(),
            push: { collector.append($0) })

        #expect(reason == .timedOut, "the session's own timer is the typed timedOut end")
        #expect(store.activeSessions.isEmpty, "an ended session is gone")
    }

    /// The store resumes the awaiting body exactly once: a second `end` for
    /// a gone session is a false, not a second resumption.
    @Test func endResumesTheBodyExactlyOnce() async throws {
        let store = WatchSessionStore()
        let collector = EventCollector()

        let sessionTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { collector.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 1 }
        let id = try #require(store.activeSessions.first?.id)

        #expect(store.end(id: id, reason: .appShutdown))
        let reason = await sessionTask.value
        #expect(reason == .appShutdown)

        #expect(!store.end(id: id, reason: .timedOut),
                "a gone session cannot be ended twice")
    }

    /// `endAll` ends every session with the given reason — the app-shutdown
    /// path.
    @Test func endAllEndsEverySessionWithTheGivenReason() async throws {
        let store = WatchSessionStore()
        let first = EventCollector()
        let second = EventCollector()

        let firstTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { first.append($0) })
        }
        let secondTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: "/repos/a", timeoutSeconds: nil),
                owner: PendingOwner(),
                push: { second.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 2 }

        #expect(store.endAll(reason: .appShutdown) == 2)
        #expect(await firstTask.value == .appShutdown)
        #expect(await secondTask.value == .appShutdown)
        #expect(store.activeSessions.isEmpty)
        #expect(store.endAll(reason: .appShutdown) == 0, "ending an empty store ends nothing")
    }

    /// The #0349 shape: a dead CLI's sessions are dropped, and ONLY that
    /// CLI's — another connection's session keeps streaming.
    @Test func dropAllOwnedByRemovesOnlyThatOwnersSessions() async throws {
        let store = WatchSessionStore()
        let deadOwner = PendingOwner()
        let liveOwner = PendingOwner()
        let deadCollector = EventCollector()
        let liveCollector = EventCollector()

        let deadTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: deadOwner,
                push: { deadCollector.append($0) })
        }
        let liveTask = Task {
            await store.register(
                request: WatchRequest(repositoryPath: nil, timeoutSeconds: nil),
                owner: liveOwner,
                push: { liveCollector.append($0) })
        }
        try await waitUntil { store.activeSessions.count == 2 }

        #expect(store.dropAll(ownedBy: deadOwner) == 1)
        #expect(await deadTask.value == .detached,
                "a dropped session resolves detached — the peer is gone")
        #expect(store.activeSessions.count == 1, "only the dead owner's session is gone")
        #expect(store.activeSessions.first?.id != nil)

        #expect(store.dropAll(ownedBy: deadOwner) == 0, "idempotent")
        #expect(store.dropAll(ownedBy: liveOwner) == 1)
        #expect(await liveTask.value == .detached)

        _ = liveCollector
    }

    // MARK: - The serving body

    /// An undecodable request registers nothing and replies the failure
    /// envelope the CLI renders verbatim.
    @Test func undecodableRequestYieldsTheRequestFailedEnvelope() async throws {
        let store = WatchSessionStore()
        let data = await WatchServing.handle(
            requestData: Data("not a request".utf8),
            store: store,
            push: { _ in },
            sessionEnder: { _ in })
        let failure = try #require(try? JSONDecoder().decode(EnvelopeFail.self, from: data))
        #expect(failure.error.code == .requestFailed)
        #expect(store.activeSessions.isEmpty,
                "an undecodable request is never registered as a session")
    }

    /// The session end reaches BOTH channels the wire promises: the client's
    /// `sessionEnded` push, and the reply bytes `performWatch` carries —
    /// same reason, once each.
    @Test func servingBodyDeliversTheEndReasonThroughBothChannels() async throws {
        let store = WatchSessionStore()
        let events = EventCollector()
        let endBox = EndBox()

        let requestData = try JSONEncoder().encode(WatchRequest(repositoryPath: nil, timeoutSeconds: nil))
        let handleTask = Task {
            await WatchServing.handle(
                requestData: requestData,
                store: store,
                push: { events.append($0) },
                sessionEnder: { endBox.set($0) })
        }
        try await waitUntil { store.activeSessions.count == 1 }
        let id = try #require(store.activeSessions.first?.id)
        #expect(store.end(id: id, reason: .appShutdown))

        let replyBytes = await handleTask.value
        let pushedReason = try #require(endBox.reason())
        let replyReason = try #require(try? JSONDecoder().decode(WatchEndReason.self, from: replyBytes))
        #expect(pushedReason == .appShutdown, "the client push carries the reason")
        #expect(replyReason == .appShutdown, "the reply carries the same reason")
        #expect(store.activeSessions.isEmpty)
    }

    /// The end bytes are the SAME bytes the wire tests pin, produced by the
    /// real serving body: a `.timedOut` end encodes `{"timedOut":true}`.
    @Test func endReasonBytesAreTheTaggedWireForm() async throws {
        let endBox = EndBox()
        let store = WatchSessionStore()
        let requestData = try JSONEncoder().encode(WatchRequest(repositoryPath: nil, timeoutSeconds: 1))
        let handleTask = Task {
            await WatchServing.handle(
                requestData: requestData,
                store: store,
                push: { _ in },
                sessionEnder: { endBox.set($0) })
        }
        let replyBytes = await handleTask.value
        let pushed = try #require(endBox.reason())
        #expect(pushed == .timedOut)
        let encoder = JSONEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        let literal = String(decoding: try encoder.encode(pushed), as: UTF8.self)
        #expect(literal == #"{"timedOut":true}"#)
        #expect(replyBytes == Data(#"{"timedOut":true}"#.utf8))
    }
}

/// Carries the `sessionEnded` push bytes out of the serving body's closure.
private final class EndBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _reason: Data?

    func set(_ data: Data) {
        lock.withLock { _reason = data }
    }

    func reason() -> WatchEndReason? {
        lock.withLock {
            _reason.flatMap { try? JSONDecoder().decode(WatchEndReason.self, from: $0) }
        }
    }
}
