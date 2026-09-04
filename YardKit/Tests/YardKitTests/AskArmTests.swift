// AskArmTests.swift — the `ask` arm's blocking semantics (#0056)
//
// The arm is exercised against real anonymous XPC listeners, the way
// `ReviewArmTests` exercises review: the serve mode runs the REAL app-side
// body (`AskServing.handle`) against a REAL `PendingAskStore`, so the typed
// timeout below is produced by the store, not faked. No assertion reads a
// clock (Rule 7c): the timeout test uses a SHORT real timeout and asserts
// the typed outcome and exit code, never elapsed time.

import Foundation
import Testing
@testable import YardKit

// MARK: - In-process fakes

private final class AskFakeAppService: NSObject, AppServiceProtocol {

    /// What the fake does with an ask request.
    enum Mode: Sendable {
        /// Runs the real serving body against a real store — the same body
        /// the app's `AppService` runs, minus the engine's common-dir
        /// resolution (passed in directly).
        case serving(store: PendingAskStore, commonDir: String)
        /// Captures the request and replies the encoded outcome immediately.
        case replying(AskOutcome)
        /// Captures the request and replies raw bytes — the undecodable-reply
        /// path.
        case replyingRaw(Data)
        /// Captures the request and never replies — the app-death test
        /// invalidates the listener while the CLI waits.
        case neverReplying
    }

    private let mode: Mode

    private let lock = NSLock()
    private var _capturedRequest: (requestData: Data, workingDirectory: String)?
    private var _replyCaptured = false

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    var capturedRequest: (requestData: Data, workingDirectory: String)? {
        lock.withLock { _capturedRequest }
    }

    var replyCaptured: Bool {
        lock.withLock { _replyCaptured }
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
        lock.withLock {
            _capturedRequest = (request, workingDirectory)
            _replyCaptured = true
        }
        switch mode {
        case .serving(let store, let commonDir):
            Task {
                let outcomeData = await AskServing.handle(
                    requestData: request,
                    commonDir: commonDir,
                    store: store)
                reply(outcomeData)
            }
        case .replying(let outcome):
            let encoder = JSONEncoder()
            encoder.outputFormatting.insert(.sortedKeys)
            reply((try? encoder.encode(outcome)) ?? Data())
        case .replyingRaw(let data):
            reply(data)
        case .neverReplying:
            break
        }
    }
}

private final class AskListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: AskFakeAppService

    init(service: AskFakeAppService) {
        self.service = service
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = XPCInterfaces.appService
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

/// Owns the listener and its delegate so both stay alive for the length of
/// a test. `@unchecked Sendable` for the same reason as
/// `ReviewFakeAppListener`: it wraps non-Sendable NS objects but is only
/// ever used from one test flow.
private final class AskFakeAppListener: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: AskFakeAppService
    private let delegate: AskListenerDelegate

    init(mode: AskFakeAppService.Mode) {
        self.service = AskFakeAppService(mode: mode)
        self.delegate = AskListenerDelegate(service: service)
        listener.delegate = delegate
        listener.resume()
    }

    func connect() -> AppConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        connection.resume()
        return AppConnection(connection: connection)
    }

    func invalidate() {
        listener.invalidate()
    }
}

// MARK: - Tests

@Suite("ask arm")
struct AskArmTests {

    private func errorBody(ofJSON stdout: String) throws -> [String: Any] {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any],
            "stdout must decode as a JSON object: \(stdout)")
        return try #require(object["error"] as? [String: Any],
                            "stdout must carry an error object: \(stdout)")
    }

    private func waitUntil(
        timeout: Duration = .seconds(60),
        _ fetch: @escaping @Sendable () -> Bool
    ) async throws {
        let reached = try await AppConnection.poll(timeout: timeout, interval: .milliseconds(10)) {
            fetch() ? true : nil
        }
        try #require(reached == true, "the awaited state was never reached")
    }

    // MARK: - The registry spec

    /// Kills mutation 3 (drop `askSpec` from `CommandRegistry.all`): the
    /// spec must be registered, with a non-empty summary, the right schema
    /// name, the two flags, and every documented exit code.
    @Test func askSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "ask"),
                                "ask must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "ask")
        let flags = Set(spec.flags.map(\.long))
        #expect(flags == ["options", "timeout"],
                "the ask spec must document --options and --timeout; got \(flags.sorted())")
        let codes = Set(spec.exitCodes.map(\.code))
        for required: Int32 in [0, 1, 3, 5, 7, 10] {
            #expect(codes.contains(required), "the ask spec must document exit \(required)")
        }
    }

    // MARK: - Usage refusals

    @Test func missingQuestionIsRefusedAsUsage() async throws {
        let result = await AskArm.run(
            arguments: ["ask", "--options", "a,b"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
        let message = try #require(try errorBody(ofJSON: result.stdout)["message"] as? String)
        #expect(message.contains("question"))
    }

    @Test func missingOptionsIsRefusedAsUsage() async throws {
        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
        let message = try #require(try errorBody(ofJSON: result.stdout)["message"] as? String)
        #expect(message.contains("--options"))
    }

    @Test func emptyOptionInsideTheListIsRefusedAsUsage() async throws {
        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--options", "yes,,no"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func emptyOptionsListIsRefusedAsUsage() async throws {
        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--options", ","],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func malformedTimeoutIsRefusedAsUsage() async throws {
        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--options", "a", "--timeout", "abc"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func unknownFlagIsRefusedAsUsage() async throws {
        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--bogus", "--options", "a"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    // MARK: - Parse acceptance

    @Test func acceptedInvocationCarriesQuestionOptionsAndDefaultTimeout() throws {
        switch AskArm.parseInvocation(["ask", "Deploy now?", "--options", "yes,no"]) {
        case .refused(let message):
            Issue.record("expected a run invocation, got refused: \(message)")
        case .run(let invocation):
            #expect(invocation.question == "Deploy now?")
            #expect(invocation.options == ["yes", "no"], "options keep the order given")
            #expect(invocation.timeoutSeconds == 3600, "the default timeout is a judgement, 3600 s")
        }
    }

    @Test func acceptedInvocationCarriesExplicitTimeoutAndFlagOrder() throws {
        switch AskArm.parseInvocation(["ask", "--timeout", "30", "--options", "b,a", "Go?"]) {
        case .refused(let message):
            Issue.record("expected a run invocation, got refused: \(message)")
        case .run(let invocation):
            #expect(invocation.question == "Go?")
            #expect(invocation.options == ["b", "a"])
            #expect(invocation.timeoutSeconds == 30)
        }
    }

    // MARK: - The app is down → exit 3, never a fallback

    @Test func appDownExitsThreeWithTheAppUnavailableEnvelope() async throws {
        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--options", "yes,no"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .appUnavailable)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "app_unavailable")
    }

    /// The dispatch-level guarantee: `ask` is intercepted with its OWN
    /// connector (`launchIfNeeded: false` — ask never launches the app),
    /// and the ordinary remote `connect` is never reached for it.
    @Test func dispatchRoutesAskToTheArmWithItsOwnConnector() async throws {
        actor Counter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let remoteCounter = Counter()
        let askCounter = Counter()

        let result = await dispatch(
            arguments: ["ask", "Deploy now?", "--options", "yes,no"],
            workingDirectory: "/",
            connect: {
                await remoteCounter.increment()
                throw AppConnectionError.appUnavailable
            },
            connectAsk: {
                await askCounter.increment()
                throw AppConnectionError.appUnavailable
            })

        #expect(await remoteCounter.count == 0,
                "ask must never go down the generic perform path")
        #expect(await askCounter.count == 1,
                "ask must use its own launchIfNeeded:false connector exactly once")
        #expect(result.exitCode == .appUnavailable)
    }

    // MARK: - The typed timeout → exit 10

    /// The full loop, through a real listener and the REAL serving body and
    /// store: the CLI asks for a 1-second wait, the store fires its typed
    /// timeout, and the arm maps it to exit 10 with the `timed_out`
    /// envelope. Kills mutation 1 (map a timeout to exit 0 instead).
    @Test func storeTimeoutArrivesAsExitTenWithTheTypedEnvelope() async throws {
        let fake = AskFakeAppListener(
            mode: .serving(store: PendingAskStore(), commonDir: "/repos/fixture/.git"))
        defer { fake.invalidate() }

        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--options", "yes,no", "--timeout", "1"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .timedOut, "a timed-out wait is exit 10, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "timed_out")
    }

    // MARK: - App death → exit 5, never a decision

    /// The listener dies while the CLI is mid-wait: the connection's error
    /// path must surface as exit 5 — never as a decision, never as a
    /// timeout.
    @Test func appDeathMidAskExitsFive() async throws {
        let fake = AskFakeAppListener(mode: .neverReplying)

        let runner = Task {
            await AskArm.run(
                arguments: ["ask", "Deploy now?", "--options", "yes,no", "--timeout", "2"],
                workingDirectory: "/",
                connect: { fake.connect() },
                backstopMargin: .milliseconds(500))
        }

        // The request must have reached the app before the listener dies, or
        // a failure below could just as easily mean the setup was wrong.
        try await waitUntil { fake.service.replyCaptured }
        fake.invalidate()

        let result = await runner.value
        #expect(result.exitCode == .sessionTerminated,
                "app death mid-ask is exit 5, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "session_terminated")
    }

    // MARK: - Decided outcomes

    /// The full loop to an answer, through a real listener and the REAL
    /// serving body and store: the CLI blocks, the store registers, the
    /// "human" (the test) resolves the head, and the arm maps the decided
    /// outcome to exit 0 with the reply as the payload.
    @Test func pickedOptionRoundTripsAsExitZeroWithTheReplyAsPayload() async throws {
        let store = PendingAskStore()
        let fake = AskFakeAppListener(
            mode: .serving(store: store, commonDir: "/repos/fixture/.git"))
        defer { fake.invalidate() }

        let runner = Task {
            await AskArm.run(
                arguments: ["ask", "Deploy now?", "--options", "yes,no"],
                workingDirectory: "/",
                connect: { fake.connect() })
        }

        try await waitUntil { !store.pendingAsks.isEmpty }
        let head = try #require(store.pendingAsks.first, "the ask must be registered as the head")
        #expect(head.request.question == "Deploy now?")
        #expect(head.request.options == ["yes", "no"])
        let reply = AskReply.chosen(index: 1, text: "no", message: "not yet")
        #expect(store.resolve(id: head.id, answer: reply))

        let result = await runner.value
        #expect(result.exitCode == .success, "a picked option is exit 0, got \(result.exitCode)")

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["result"] as? [String: Any],
                                   "the payload IS the reply, per the wire contract")
        #expect(payload["optionIndex"] as? Int == 1)
        #expect(payload["optionText"] as? String == "no")
        #expect(payload["message"] as? String == "not yet")
    }

    /// A decline is a decided reply with declined semantics: exit 7 — and
    /// the envelope still carries the declined reply, `"ok":true`. Kills
    /// mutation 3b (treat a decline as a success or as a timeout).
    @Test func declinedAnswerExitsSevenWithTheReplyInTheEnvelope() async throws {
        let fake = AskFakeAppListener(mode: .replying(.decided(AskReply.declined(message: "not my call"))))
        defer { fake.invalidate() }

        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--options", "yes,no"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .humanDeclined,
                "a decline is exit 7, got \(result.exitCode)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true,
                "even a decline is a completed ask: the envelope says ok:true")
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["declined"] as? Bool == true)
        #expect(payload["message"] as? String == "not my call")
    }

    @Test func undecodableReplyIsRequestFailed() async throws {
        let fake = AskFakeAppListener(mode: .replyingRaw(Data("not json".utf8)))
        defer { fake.invalidate() }

        let result = await AskArm.run(
            arguments: ["ask", "Deploy now?", "--options", "yes,no"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .requestFailed)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "request_failed")
    }

    // MARK: - The serving body's degenerate paths

    @Test func undecodableRequestYieldsTheRequestFailedEnvelope() async throws {
        let data = await AskServing.handle(
            requestData: Data("not a request".utf8),
            commonDir: "/repos/fixture/.git",
            store: PendingAskStore())
        let failure = try #require(try? JSONDecoder().decode(EnvelopeFail.self, from: data))
        #expect(failure.error.code == .requestFailed)
    }

    @Test func unresolvableRepositoryYieldsTheRepositoryErrorEnvelope() async throws {
        let store = PendingAskStore()
        let request = AskRequest(commonDir: "", question: "Q?", options: ["a"], timeoutSeconds: 60)
        let data = await AskServing.handle(
            requestData: try JSONEncoder().encode(request),
            commonDir: nil,
            store: store)
        let failure = try #require(try? JSONDecoder().decode(EnvelopeFail.self, from: data))
        #expect(failure.error.code == .repositoryError)
        #expect(store.pendingAsks.isEmpty,
                "an unresolvable repository is never registered as a pending ask")
    }
}
