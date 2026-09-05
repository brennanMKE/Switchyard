// ReviewAbandonmentTests.swift — the CLI's connection dying mid-review
// marks the pending abandoned and the decision still resolves (#0349)
//
// The `appDeathMidReviewExitsFive` machinery, mirrored to the CLI-death
// direction: a real anonymous listener serves the REAL app-side body
// (`ReviewServing.handle`) against a REAL `PendingReviewStore`, and the
// fake's per-connection wiring is the app's `ListenerDelegate` wiring in
// miniature — one `PendingOwner` per accepted connection, the connection's
// invalidation handler abandoning exactly the pendings that owner registered.
// Killing the CLIENT side of the connection is how "the CLI is killed"
// arrives at the app: the peer death invalidates the app-side connection,
// whose handler fires the abandonment hook. No assertion reads a clock
// (Rule 7c); every wait is a bounded poll.

import Foundation
import Testing
@testable import YardKit

// MARK: - In-process fakes (the app's per-connection wiring in miniature)

private final class AbandonableAppService: NSObject, AppServiceProtocol {

    let store: PendingReviewStore
    let owner: PendingOwner

    /// What the serving body ultimately produced — the proof that the
    /// waiter kept waiting through the abandonment and received the late
    /// decision. A Sendable box, so the serving Task captures only
    /// Sendable values.
    private let outcomeBox = OutcomeBox()

    var outcomeData: Data? {
        outcomeBox.data
    }

    init(store: PendingReviewStore, owner: PendingOwner) {
        self.store = store
        self.owner = owner
        super.init()
    }

    func appPing(reply: @escaping @Sendable (String) -> Void) {
        reply("pong")
    }

    func perform(
        arguments: [String],
        workingDirectory: String,
        reply: @escaping @Sendable (Data, Int32) -> Void
    ) {
        reply(Data(), 1)
    }

    func performReferenceTransactionHook(
        state: String,
        environment: [String: String],
        standardInput: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        reply(0)
    }

    func performReview(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        let store = store
        let owner = owner
        let outcomeBox = outcomeBox
        Task {
            let outcomeData = await ReviewServing.handle(
                requestData: request,
                commonDir: "/repos/fixture/.git",
                store: store,
                owner: owner)
            outcomeBox.data = outcomeData
            reply(outcomeData)
        }
    }

    func performAsk(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        reply(Data())
    }

    func performResolve(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        reply(Data())
    }
}

/// A thread-safe slot the serving task writes its outcome into.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    var data: Data? {
        get { lock.withLock { _data } }
        set { lock.withLock { _data = newValue } }
    }
}

private final class AbandonableListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: AbandonableAppService

    init(service: AbandonableAppService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let store = service.store
        let owner = service.owner
        connection.exportedInterface = XPCInterfaces.appService
        connection.exportedObject = service
        // The app's `ListenerDelegate` wiring (#0349), verbatim in shape:
        // the connection death abandons exactly this connection's pendings.
        connection.invalidationHandler = { @Sendable in
            store.abandonAll(ownedBy: owner)
        }
        connection.resume()
        return true
    }
}

private final class AbandonableFakeAppListener: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: AbandonableAppService
    private let delegate: AbandonableListenerDelegate

    init(store: PendingReviewStore) {
        self.service = AbandonableAppService(store: store, owner: PendingOwner())
        self.delegate = AbandonableListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
    }

    /// Connects a client and records the client-side connection so the test
    /// can kill it — standing in for the CLI process being killed.
    func connect(into box: ConnectionBox) -> AppConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        connection.resume()
        let app = AppConnection(connection: connection)
        box.connection = app
        return app
    }
}

/// A thread-safe slot for the client-side connection the test kills.
private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _connection: AppConnection?
    var connection: AppConnection? {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }
}

// MARK: - Tests

@Suite("review abandonment over the wire (#0349)")
struct ReviewAbandonmentTests {

    /// Bounded wait for a store state, the `PendingReviewStoreTests` shape.
    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited store state was never reached")
    }

    /// The full loop: the CLI registers a review over a real connection,
    /// the CLI's connection dies (the killed-CLI path), the app-side hook
    /// fires `.abandoned` — and the human's late decision still resolves
    /// and reaches the serving body.
    @Test func connectionDeathMarksThePendingAbandonedAndTheDecisionStillResolves() async throws {
        let store = PendingReviewStore()
        let events = AbandonmentEventCollector()
        store.onPendingChange = { pending, outcome in events.record(pending, outcome) }
        let fake = AbandonableFakeAppListener(store: store)
        let box = ConnectionBox()

        let runner = Task {
            await ReviewArm.run(
                arguments: ["review", "--wait", "--staged", "--timeout", "60"],
                workingDirectory: "/",
                connect: { fake.connect(into: box) })
        }

        // The request must have reached the app before the connection dies.
        try await waitUntil { !store.pendingReviews.isEmpty }

        // Kill the CLI's end of the very connection the review rides.
        let client = try #require(box.connection, "the connect closure must have run")
        client.close()

        // The CLI's side: its blocking call dies with the connection —
        // exit 5, never a decision, never a timeout lie.
        let result = await runner.value
        #expect(result.exitCode == .sessionTerminated,
                "a dead connection is exit 5, got \(result.exitCode)")

        // The app's side: the invalidation handler abandoned the pending.
        try await waitUntil { events.hasAbandoned }
        let abandoned = try #require(events.abandoned, "the hook must fire .abandoned")
        #expect(store.pendingReviews.count == 1,
                "abandonment is not a resolution — the pending stays for the sheet")

        // The human decides anyway; the decision still resolves and the
        // serving body receives it.
        let reply = ReviewReply(decision: .approve, message: nil, comments: [], editedPatch: nil)
        #expect(store.resolve(id: abandoned.0.id, decision: reply),
                "a decision after abandonment still resolves")
        try await waitUntil { fake.service.outcomeData != nil }
        let outcomeData = try #require(fake.service.outcomeData)
        let outcome = try #require(
            try? JSONDecoder().decode(ReviewOutcome.self, from: outcomeData),
            "the serving body must receive the late decision, got \(String(decoding: outcomeData, as: UTF8.self))")
        #expect(outcome == .decided(reply))
    }
}

private final class AbandonmentEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(PendingReviewStore.Pending, ReviewOutcome?)] = []

    func record(_ pending: PendingReviewStore.Pending, _ outcome: ReviewOutcome?) {
        lock.withLock { items.append((pending, outcome)) }
    }

    var hasAbandoned: Bool {
        lock.withLock { items.contains { $0.1 == .abandoned } }
    }

    var abandoned: (PendingReviewStore.Pending, ReviewOutcome?)? {
        lock.withLock { items.first { $0.1 == .abandoned } }
    }
}
