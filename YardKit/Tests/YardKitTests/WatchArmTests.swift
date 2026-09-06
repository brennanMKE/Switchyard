// WatchArmTests.swift — the `watch` arm's streaming session (#0058)
//
// The arm is exercised against real anonymous XPC listeners, the way
// `AskArmTests` exercises ask: the serve mode runs the REAL app-side body
// (`WatchServing.handle`) against a REAL `WatchSessionStore`, and the events
// travel the REAL reverse-direction wire — the CLI exports a
// `WatchClientProtocol` object, the app-side service calls the proxy it was
// handed, and the bytes arrive back at the CLI through the export. If the
// interface whitelisting (`setInterface` for the `client` argument) or the
// pre-resume export were dropped, the events would silently never arrive
// and the round-trip test below would go red. No assertion reads a clock
// (Rule 7c).

import Foundation
import Testing
@testable import YardKit

// MARK: - In-process fakes

private final class WatchFakeAppService: NSObject, AppServiceProtocol {

    /// What the fake does with a watch request.
    enum Mode: Sendable {
        /// Runs the real serving body against a real store — the same body
        /// the app's `AppService` runs. The test drives the store.
        case serving(store: WatchSessionStore)
        /// Captures the request and never replies and never pushes — the
        /// CLI-deadline test needs an app that will not end the session.
        case neverReplying
    }

    private let mode: Mode

    /// This fake connection's ownership token, shared with its listener
    /// delegate's invalidation handler — the real `ListenerDelegate`
    /// wiring's shape (#0349).
    let owner = PendingOwner()

    private let lock = NSLock()
    private var _replyCaptured = false

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    var replyCaptured: Bool {
        lock.withLock { _replyCaptured }
    }

    var store: WatchSessionStore? {
        if case .serving(let store) = mode { return store }
        return nil
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
        reply(Data())
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

    func performWatch(
        request: Data,
        client: any WatchClientProtocol,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        lock.withLock { _replyCaptured = true }
        // The client is a proxy to the CLI's exported object — non-Sendable
        // by type, thread-safe by XPC construction; `Transferred` confines
        // that fact, exactly as the app target's `AppService` does.
        let clientBox = Transferred(client)
        guard let store = store else { return }
        let owner = self.owner
        Task {
            let reasonData = await WatchServing.handle(
                requestData: request,
                store: store,
                push: { data in clientBox.value.event(data) },
                sessionEnder: { data in clientBox.value.sessionEnded(reason: data) },
                owner: owner)
            reply(reasonData)
        }
    }
}

private final class WatchListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: WatchFakeAppService

    init(service: WatchFakeAppService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = XPCInterfaces.appService
        connection.exportedObject = service
        // The app's invalidation wiring (#0349/#0058), verbatim in shape: a
        // CLI death drops exactly this connection's watch sessions.
        let store = service.store
        let owner = service.owner
        connection.invalidationHandler = { @Sendable in
            store?.dropAll(ownedBy: owner)
        }
        connection.resume()
        return true
    }
}

/// Owns the listener and its delegate so both stay alive for the length of
/// a test. `@unchecked Sendable` for the same reason as `AskFakeAppListener`.
private final class WatchFakeAppListener: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: WatchFakeAppService
    private let delegate: WatchListenerDelegate

    init(mode: WatchFakeAppService.Mode) {
        self.service = WatchFakeAppService(mode: mode)
        self.delegate = WatchListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
    }

    /// Connects the way the watch arm's production connector does: the
    /// CLI's exported client is set on the connection BEFORE resume, under
    /// `XPCInterfaces.watchClient`.
    func connect(exporting client: any WatchClientProtocol) -> AppConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        connection.exportedInterface = XPCInterfaces.watchClient
        connection.exportedObject = client
        connection.resume()
        return AppConnection(connection: connection)
    }

    func invalidate() {
        listener.invalidate()
    }
}

/// Counting box for the SIGINT-detach test: the injected `shouldDetach`
/// flips once enough event lines have been EMITTED CLI-side.
private final class DetachCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.withLock { _value += 1 }
    }

    var value: Int {
        lock.withLock { _value }
    }
}

// MARK: - Tests

@Suite("watch arm")
struct WatchArmTests {

    private func errorBody(ofJSON stdout: String) throws -> [String: Any] {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "stdout must decode as a JSON object: \(stdout)")
        return try #require(object["error"] as? [String: Any],
                            "stdout must carry an error object: \(stdout)")
    }

    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited state was never reached")
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (drop `watchSpec` from `CommandRegistry.all`): the
    /// spec must be registered, with a non-empty summary, the right schema
    /// name, the --timeout flag, and every documented exit code.
    @Test func watchSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "watch"),
                                "watch must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "watch")
        let flags = Set(spec.flags.map(\.long))
        #expect(flags == ["timeout"],
                "the watch spec must document --timeout; got \(flags.sorted())")
        let codes = Set(spec.exitCodes.map(\.code))
        for required: Int32 in [0, 1, 3, 5] {
            #expect(codes.contains(required), "the watch spec must document exit \(required)")
        }
    }

    // MARK: - The streaming round trip

    /// THE round trip, over a real anonymous listener and the real
    /// reverse-direction wire: 200 events injected app-side, ALL arrive
    /// CLI-side, IN ORDER (sequences 1...200 in arrival order), each line
    /// parsing as JSON — and every payload intact. Kills mutation 1 (drop
    /// every 10th event in the stream) and mutation 3 (start sequences at
    /// 0) of this round.
    @Test func twoHundredEventsArriveInOrderNoneDroppedEachLineJSON() async throws {
        let store = WatchSessionStore()
        let fake = WatchFakeAppListener(mode: .serving(store: store))
        defer { fake.invalidate() }

        let runner = Task {
            await WatchArm.run(
                arguments: ["watch"],
                workingDirectory: "/",
                connect: { client in fake.connect(exporting: client) },
                // Never consult the production SIGINT latch here: it is a
                // process-global, and the latch-wiring test flips it while
                // this suite's tests run concurrently.
                shouldDetach: { false },
                detachPollInterval: .milliseconds(10))
        }

        // The session must be registered before events can be injected.
        try await waitUntil { store.activeSessions.count == 1 }

        let count = 200
        for index in 1...count {
            store.broadcast(kind: .appEvent, payload: ["note": .string("event-\(index)")])
        }
        // End the session from the app side; the reply is what unblocks the
        // arm, AFTER the events (per-connection order).
        #expect(store.endAll(reason: .detached) == 1)

        let result = await runner.value
        #expect(result.exitCode == .success,
                "an app-detached session is a clean end, got \(result.exitCode)")

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == count,
                "every event is one stdout line; got \(lines.count), wanted \(count)")
        var decoded: [WatchEvent] = []
        for line in lines {
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "each stdout line must parse as a JSON object: \(line)")
            #expect(object["kind"] as? String == "app_event")
            let event = try #require(
                try? JSONDecoder().decode(WatchEvent.self, from: Data(line.utf8)),
                "each line must decode as a WatchEvent: \(line)")
            decoded.append(event)
        }
        #expect(decoded.count == count)
        #expect(decoded.map(\.sequence) == Array(1...count),
                "sequences must be 1...\(count) in arrival order; got \(decoded.map(\.sequence).prefix(20))…")
        for event in decoded {
            #expect(event.payload["note"] == .string("event-\(event.sequence)"),
                    "payloads must arrive intact, in step with their sequence numbers")
        }
    }

    // MARK: - The streaming round trip at scale

    /// The no-drop criterion at the round-2 scale (≥1000, here 5000): the
    /// full reverse-direction wire under a sustained burst, sequences
    /// 1...5000 in arrival order, every line parsing as JSON. The post-reply
    /// drain is what lets the tail arrive; a drop here is the RemoteControl
    /// defect class this issue exists to prevent.
    @Test func fiveThousandEventsArriveInOrderNoneDroppedEachLineJSON() async throws {
        let store = WatchSessionStore()
        let fake = WatchFakeAppListener(mode: .serving(store: store))
        defer { fake.invalidate() }

        let runner = Task {
            await WatchArm.run(
                arguments: ["watch"],
                workingDirectory: "/",
                connect: { client in fake.connect(exporting: client) },
                // Never consult the production SIGINT latch (a process
                // global flipped concurrently by the latch-wiring test).
                shouldDetach: { false },
                detachPollInterval: .milliseconds(10))
        }

        try await waitUntil { store.activeSessions.count == 1 }

        let count = 5000
        for index in 1...count {
            store.broadcast(kind: .appEvent, payload: ["note": .string("event-\(index)")])
        }
        #expect(store.endAll(reason: .detached) == 1)

        let result = await runner.value
        #expect(result.exitCode == .success,
                "an app-detached session is a clean end, got \(result.exitCode)")

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == count,
                "every event is one stdout line; got \(lines.count), wanted \(count)")
        var lastSequence = 0
        for line in lines {
            let event = try #require(
                try? JSONDecoder().decode(WatchEvent.self, from: Data(line.utf8)),
                "each line must decode as a WatchEvent: \(line.prefix(120))")
            #expect(event.sequence == lastSequence + 1,
                    "sequences must arrive 1...\(count) without gaps; got \(event.sequence) after \(lastSequence)")
            lastSequence = event.sequence
        }
        #expect(lastSequence == count, "the stream must end on sequence \(count)")
    }

    // MARK: - Exit 5: the app terminates the session

    /// The app ends the session with `appShutdown` — exit 5, the
    /// `session_terminated` envelope, never reported as a detach. Kills
    /// mutation 2 (map appShutdown to exit 0) of this round.
    @Test func appShutdownReplyExitsFive() async throws {
        let store = WatchSessionStore()
        let fake = WatchFakeAppListener(mode: .serving(store: store))
        defer { fake.invalidate() }

        let runner = Task {
            await WatchArm.run(
                arguments: ["watch"],
                workingDirectory: "/",
                connect: { client in fake.connect(exporting: client) },
                shouldDetach: { false },
                detachPollInterval: .milliseconds(10))
        }
        try await waitUntil { store.activeSessions.count == 1 }
        #expect(store.endAll(reason: .appShutdown) == 1)

        let result = await runner.value
        #expect(result.exitCode == .sessionTerminated,
                "an app-terminated session is exit 5, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "session_terminated")
    }

    /// The app QUITTING mid-stream (no reply at all) is also exit 5, through
    /// the connection's error path.
    @Test func appDeathMidStreamExitsFive() async throws {
        let fake = WatchFakeAppListener(mode: .neverReplying)

        let runner = Task {
            await WatchArm.run(
                arguments: ["watch", "--timeout", "60"],
                workingDirectory: "/",
                connect: { client in fake.connect(exporting: client) },
                shouldDetach: { false },
                detachPollInterval: .milliseconds(10),
                backstopMargin: .seconds(300))
        }

        // The request must have reached the app before the listener dies,
        // or a failure below could just as easily mean the setup was wrong.
        try await waitUntil(timeout: .seconds(120)) { fake.service.replyCaptured }
        fake.invalidate()

        let result = await runner.value
        #expect(result.exitCode == .sessionTerminated,
                "app death mid-stream is exit 5, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "session_terminated")
    }

    // MARK: - Exit 3: the app is down

    @Test func appDownExitsThreeWithTheAppUnavailableEnvelope() async throws {
        let result = await WatchArm.run(
            arguments: ["watch"],
            workingDirectory: "/") {
            _ in throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .appUnavailable)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "app_unavailable")
    }

    // MARK: - Exit 0: the clean ends

    /// The app's own timer — armed from the request's `timeoutSeconds` —
    /// replies `.timedOut`: a detach, exit 0, never an error. The backstop
    /// is injected far out so the STORE's timer is what ends this session.
    @Test func storeTimeoutDetachesWithExitZero() async throws {
        let store = WatchSessionStore()
        let fake = WatchFakeAppListener(mode: .serving(store: store))
        defer { fake.invalidate() }

        let result = await WatchArm.run(
            arguments: ["watch", "--timeout", "1"],
            workingDirectory: "/",
            connect: { client in fake.connect(exporting: client) },
            shouldDetach: { false },
            detachPollInterval: .milliseconds(10),
            backstopMargin: .seconds(300))

        #expect(result.exitCode == .success,
                "a timed-out watch is a detach, exit 0, got \(result.exitCode)")
        #expect(result.stderr.isEmpty)
    }

    /// With an app that will never end the session, the CLI's OWN deadline
    /// (`--timeout` + backstop) detaches it: exit 0. This is the CLI half of
    /// the `--timeout` criterion — the arm never hangs past its contract
    /// even when the reply is lost.
    @Test func cliDeadlineDetachesWithExitZero() async throws {
        let fake = WatchFakeAppListener(mode: .neverReplying)
        defer { fake.invalidate() }

        let result = await WatchArm.run(
            arguments: ["watch", "--timeout", "1"],
            workingDirectory: "/",
            connect: { client in fake.connect(exporting: client) },
            shouldDetach: { false },
            detachPollInterval: .milliseconds(10),
            backstopMargin: .milliseconds(50))

        #expect(result.exitCode == .success,
                "the CLI's own deadline is a detach, exit 0, got \(result.exitCode)")
    }

    /// SIGINT mid-stream: the injected latch flips once enough lines have
    /// been emitted CLI-side, and the arm detaches cleanly with exit 0 —
    /// the Ctrl-C criterion's CLI half.
    @Test func sigintDetachMidStreamExitsZero() async throws {
        let store = WatchSessionStore()
        let fake = WatchFakeAppListener(mode: .serving(store: store))
        defer { fake.invalidate() }

        let counter = DetachCounter()
        let runner = Task {
            await WatchArm.run(
                arguments: ["watch"],
                workingDirectory: "/",
                connect: { client in fake.connect(exporting: client) },
                emit: { _ in counter.increment() },
                shouldDetach: { counter.value >= 10 },
                detachPollInterval: .milliseconds(10))
        }

        try await waitUntil { store.activeSessions.count == 1 }
        let count = 200
        for index in 1...count {
            store.broadcast(kind: .appEvent, payload: ["note": .string("event-\(index)")])
        }

        // The latch can only flip once events actually ARRIVED CLI-side —
        // bounded wait, no clock assertion.
        try await waitUntil { counter.value >= 10 }

        let result = await runner.value
        #expect(result.exitCode == .success,
                "the SIGINT detach is a clean end, exit 0, got \(result.exitCode)")
        #expect(counter.value >= 10, "the detach happened mid-stream, after real events")
        #expect(counter.value <= count)
        await store.endAll(reason: .detached)
    }

    /// The production latch wiring, in the two parts the test runner's
    /// signal environment allows: `watchInstallSIGINTHandler` really swaps
    /// the disposition for a real handler (not SIG_DFL/SIG_IGN), and the
    /// handler body latches the flag the poller reads. Raising SIGINT
    /// in-process is NOT asserted — the runner blocks SIGINT on its own
    /// threads, so delivery would be pending-forever here regardless of the
    /// wiring; the OS-delivery path is the round-2 subprocess test's, where
    /// the CLI owns its own disposition.
    @Test func sigintHandlerLatchesTheFlag() throws {
        watchInstallSIGINTHandler()
        defer { signal(SIGINT, SIG_IGN) }
        watchSIGINTReceived = 0
        defer { watchSIGINTReceived = 0 }

        // Installation took effect: the disposition right before the
        // SIG_IGN restore is a real handler — neither the default (0) nor
        // ignore (1), which is what everything but an install leaves.
        let previous = unsafeBitCast(signal(SIGINT, SIG_IGN), to: Int.self)
        #expect(
            previous != unsafeBitCast(SIG_DFL, to: Int.self)
                && previous != unsafeBitCast(SIG_IGN, to: Int.self),
            "watchInstallSIGINTHandler must install a real handler, got \(previous)")

        // The latch body flips the flag the production poller reads
        // (WatchArm.stream's detach closure).
        watchSIGINTHandler(SIGINT)
        #expect(watchSIGINTReceived != 0, "the handler must latch the flag")
    }

    // MARK: - The dispatch-level guarantee

    /// `watch` is intercepted with its OWN connector (which receives the
    /// exported client — `launchIfNeeded: false` baked in) and the ordinary
    /// remote `connect` is never reached for it.
    @Test func dispatchRoutesWatchToTheArmWithItsOwnConnector() async throws {
        actor Counter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let remoteCounter = Counter()
        let watchCounter = Counter()

        let result = await dispatch(
            arguments: ["watch"],
            workingDirectory: "/",
            connect: {
                await remoteCounter.increment()
                throw AppConnectionError.appUnavailable
            },
            connectWatch: { _ in
                await watchCounter.increment()
                throw AppConnectionError.appUnavailable
            },
            emitWatch: nil)

        #expect(await remoteCounter.count == 0,
                "watch must never go down the generic perform path")
        #expect(await watchCounter.count == 1,
                "watch must use its own launchIfNeeded:false connector exactly once")
        #expect(result.exitCode == .appUnavailable)
    }

    // MARK: - Usage refusals and parsing

    @Test func malformedTimeoutIsRefusedAsUsage() async throws {
        let result = await WatchArm.run(
            arguments: ["watch", "--timeout", "abc"],
            workingDirectory: "/") {
            _ in throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
        let message = try #require(try errorBody(ofJSON: result.stdout)["message"] as? String)
        #expect(message.contains("--timeout"))
    }

    @Test func zeroTimeoutIsRefusedAsUsage() async throws {
        let result = await WatchArm.run(
            arguments: ["watch", "--timeout", "0"],
            workingDirectory: "/") {
            _ in throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func unknownFlagIsRefusedAsUsage() async throws {
        let result = await WatchArm.run(
            arguments: ["watch", "--bogus"],
            workingDirectory: "/") {
            _ in throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func twoRepositoryPathsAreRefusedAsUsage() async throws {
        let result = await WatchArm.run(
            arguments: ["watch", "/repos/a", "/repos/b"],
            workingDirectory: "/") {
            _ in throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func acceptedInvocationCarriesPathAndTimeout() throws {
        switch WatchArm.parseInvocation(["watch", "/repos/a", "--timeout", "5"]) {
        case .refused(let message):
            Issue.record("expected a run invocation, got refused: \(message)")
        case .run(let invocation):
            #expect(invocation.repositoryPath == "/repos/a")
            #expect(invocation.timeoutSeconds == 5)
        }
    }

    @Test func bareWatchIsTheAllReposUntilDetachedSelector() throws {
        switch WatchArm.parseInvocation(["watch"]) {
        case .refused(let message):
            Issue.record("a bare watch is valid — all repos, until detached: \(message)")
        case .run(let invocation):
            #expect(invocation.repositoryPath == nil)
            #expect(invocation.timeoutSeconds == nil)
        }
    }

    @Test func parseRefusesNonWatchInvocations() throws {
        for arguments in [["status"], ["review", "--wait"]] {
            guard case .refused = WatchArm.parseInvocation(arguments) else {
                Issue.record("expected refusal for \(arguments)")
                continue
            }
        }
    }
}
