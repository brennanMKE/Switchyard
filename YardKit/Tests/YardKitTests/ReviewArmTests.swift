// ReviewArmTests.swift — the `review --wait` arm's blocking semantics (#0055)
//
// The arm is exercised against real anonymous XPC listeners, the way
// `AppConnectionTests` exercises the connection: the serve mode runs the REAL
// app-side body (`ReviewServing.handle`) against a REAL `PendingReviewStore`,
// so the typed timeout below is produced by the store, not faked. No
// assertion reads a clock (Rule 7c): the timeout test uses a SHORT real
// timeout and asserts the typed outcome and exit code, never elapsed time.

import Foundation
import Testing
@testable import YardKit

// MARK: - In-process fakes

private final class ReviewFakeAppService: NSObject, AppServiceProtocol {

    /// What the fake does with a review request.
    enum Mode: Sendable {
        /// Runs the real serving body against a real store — the same body
        /// the app's `AppService` runs, minus the engine's common-dir
        /// resolution (passed in directly).
        case serving(store: PendingReviewStore, commonDir: String)
        /// Captures the request and replies the encoded outcome immediately.
        case replying(ReviewOutcome)
        /// Captures the request and replies raw bytes — the undecodable-reply
        /// path.
        case replyingRaw(Data)
        /// Captures the request (and the reply block) and never replies —
        /// the app-death test invalidates the listener while the CLI waits.
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
        lock.withLock {
            _capturedRequest = (request, workingDirectory)
            _replyCaptured = true
        }
        switch mode {
        case .serving(let store, let commonDir):
            Task {
                let outcomeData = await ReviewServing.handle(
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

    func performAsk(
        request: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        reply(Data())
    }
}

private final class ReviewListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: ReviewFakeAppService

    init(service: ReviewFakeAppService) {
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

/// Owns the listener and its delegate so both stay alive for the length of a
/// test. `@unchecked Sendable` for the same reason as `AppConnection`: it
/// wraps non-Sendable NS objects but is only ever used from one test flow.
private final class ReviewFakeAppListener: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: ReviewFakeAppService
    private let delegate: ReviewListenerDelegate

    init(mode: ReviewFakeAppService.Mode) {
        self.service = ReviewFakeAppService(mode: mode)
        self.delegate = ReviewListenerDelegate(service: service)
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

@Suite("review arm")
struct ReviewArmTests {

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

    /// Kills mutation 3 (drop `reviewSpec` from `CommandRegistry.all`): the
    /// spec must be registered, with a non-empty summary, the right schema
    /// name, the three flags, and every documented exit code.
    @Test func reviewSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "review"),
                                "review must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "review")
        let flags = Set(spec.flags.map(\.long))
        #expect(flags == ["staged", "wait", "timeout"],
                "the review spec must document --staged, --wait, and --timeout; got \(flags.sorted())")
        let codes = Set(spec.exitCodes.map(\.code))
        for required: Int32 in [0, 1, 3, 4, 5, 7, 10] {
            #expect(codes.contains(required), "the review spec must document exit \(required)")
        }
    }

    // MARK: - The exit-code vocabulary

    @Test func timedOutIsTenAndDistinctFromAppDownAppDeathAndRejection() {
        #expect(ExitCode.timedOut.rawValue == 10)
        #expect(ExitCode.timedOut.codeLabel == "timed_out")
        #expect(ExitCode.timedOut != .appUnavailable, "3 is the app not running")
        #expect(ExitCode.timedOut != .sessionTerminated, "5 is the app dying")
        #expect(ExitCode.timedOut != .humanDeclined, "7 is the human rejecting")
        #expect(ExitCode.timedOut != .blockedOnConflicts, "8 was taken; the timeout code must not collide")
    }

    @Test func envelopeErrorCodeTimedOutMapsToExitTen() {
        #expect(EnvelopeErrorCode.timedOut.exitCode == .timedOut)
        #expect(EnvelopeErrorCode(rawValue: ExitCode.timedOut.codeLabel) == .timedOut)
    }

    // MARK: - Usage refusals

    @Test func nonWaitFormIsRefusedAsUsage() async throws {
        // The connect closure would exit 3 if it were ever reached — it is
        // not: a refusal is decided in argv, before any connection.
        let result = await ReviewArm.run(
            arguments: ["review", "main..HEAD"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "usage")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("--wait"), "the refusal must say the blocking form requires --wait")
    }

    @Test func missingSelectorIsRefusedAsUsage() async throws {
        let result = await ReviewArm.run(
            arguments: ["review", "--wait"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
        let message = try #require(try errorBody(ofJSON: result.stdout)["message"] as? String)
        #expect(message.contains("range") || message.contains("staged"))
    }

    @Test func rangeAndStagedTogetherIsRefusedAsUsage() async throws {
        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "main..HEAD", "--staged"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func malformedTimeoutIsRefusedAsUsage() async throws {
        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--timeout", "abc", "main..HEAD"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func unknownFlagIsRefusedAsUsage() async throws {
        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--bogus", "main..HEAD"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    // MARK: - Parse acceptance

    @Test func acceptedInvocationDefaultsToTheJudgementTimeout() throws {
        switch ReviewArm.parseInvocation(["review", "--wait", "main..HEAD"]) {
        case .refused(let message):
            Issue.record("expected a run invocation, got refused: \(message)")
        case .run(let invocation):
            #expect(invocation.timeoutSeconds == 3600, "the default timeout is a judgement, 3600 s")
            #expect(invocation.selector == .range("main..HEAD"))
        }
    }

    @Test func acceptedInvocationCarriesStagedAndExplicitTimeout() throws {
        switch ReviewArm.parseInvocation(["review", "--wait", "--staged", "--timeout", "30"]) {
        case .refused(let message):
            Issue.record("expected a run invocation, got refused: \(message)")
        case .run(let invocation):
            #expect(invocation.timeoutSeconds == 30)
            #expect(invocation.selector == .staged)
        }
    }

    // MARK: - The app is down → exit 3, never a fallback

    @Test func appDownExitsThreeWithTheAppUnavailableEnvelope() async throws {
        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--staged"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .appUnavailable)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "app_unavailable")
    }

    /// The dispatch-level guarantee: `review` is intercepted with its OWN
    /// connector (`launchIfNeeded: false` — review never launches the app),
    /// and the ordinary remote `connect` is never reached for it.
    @Test func dispatchRoutesReviewToTheArmWithItsOwnConnector() async throws {
        actor Counter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let remoteCounter = Counter()
        let reviewCounter = Counter()

        let result = await dispatch(
            arguments: ["review", "--wait", "--staged"],
            workingDirectory: "/",
            connect: {
                await remoteCounter.increment()
                throw AppConnectionError.appUnavailable
            },
            connectReview: {
                await reviewCounter.increment()
                throw AppConnectionError.appUnavailable
            })

        #expect(await remoteCounter.count == 0,
                "review must never go down the generic perform path")
        #expect(await reviewCounter.count == 1,
                "review must use its own launchIfNeeded:false connector exactly once")
        #expect(result.exitCode == .appUnavailable)
    }

    // MARK: - The typed timeout → exit 10

    /// The full loop, through a real listener and the REAL serving body and
    /// store: the CLI asks for a 1-second wait, the store fires its typed
    /// timeout, and the arm maps it to exit 10 with the `timed_out` envelope.
    /// Kills mutation 1 (map a timeout to exit 0 instead).
    @Test func storeTimeoutArrivesAsExitTenWithTheTypedEnvelope() async throws {
        let fake = ReviewFakeAppListener(
            mode: .serving(store: PendingReviewStore(), commonDir: "/repos/fixture/.git"))
        defer { fake.invalidate() }

        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--staged", "--timeout", "1"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .timedOut, "a timed-out wait is exit 10, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "timed_out")
    }

    // MARK: - App death → exit 5, never a decision

    /// The listener dies while the CLI is mid-wait: the connection's error
    /// path must surface as exit 5 — never as a decision, never as a timeout.
    @Test func appDeathMidReviewExitsFive() async throws {
        let fake = ReviewFakeAppListener(mode: .neverReplying)

        let runner = Task {
            await ReviewArm.run(
                arguments: ["review", "--wait", "--staged", "--timeout", "60"],
                workingDirectory: "/",
                connect: { fake.connect() },
                backstopMargin: .milliseconds(500))
        }

        // The request must have reached the app before the listener dies, or
        // a failure below could just as easily mean the setup was wrong.
        // The wait outlives the arm's own deadline (timeout + backstop) by a
        // wide margin, so under suite load the death, not the timeout, wins.
        try await waitUntil(timeout: .seconds(120)) { fake.service.replyCaptured }
        fake.invalidate()

        let result = await runner.value
        #expect(result.exitCode == .sessionTerminated,
                "app death mid-review is exit 5, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "session_terminated")
    }

    // MARK: - Decided outcomes

    /// The decision→exit mapping: approve and amend exit 0 (amend is NOT a
    /// rejection), reject exits 7 — and in every row the envelope itself
    /// carries the decision. Kills mutation 3b (treat amend as a rejection).
    @Test(
        "decided replies map to their exit codes",
        arguments: [
            (ReviewDecision.approve, ExitCode.success),
            (ReviewDecision.reject, ExitCode.humanDeclined),
            (ReviewDecision.amend, ExitCode.success),
        ] as [(ReviewDecision, ExitCode)]
    )
    func decidedRepliesMapToTheirExitCodes(decision: ReviewDecision, expected: ExitCode) async throws {
        let reply = ReviewReply(decision: decision, message: nil, comments: [], editedPatch: nil)
        let fake = ReviewFakeAppListener(mode: .replying(.decided(reply)))
        defer { fake.invalidate() }

        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--staged"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == expected,
                "\(decision) must exit \(expected.rawValue), got \(result.exitCode.rawValue)")

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true,
                "even a rejection is a completed review: the envelope says ok:true")
        let payload = try #require(object["result"] as? [String: Any],
                                   "the payload IS the reply, per the wire contract")
        #expect(payload["decision"] as? String == decision.rawValue)
    }

    /// Amend's whole point: the edited patch survives into the envelope.
    @Test func amendCarriesTheEditedPatchInTheEnvelope() async throws {
        let reply = ReviewReply(
            decision: .amend, message: nil, comments: [], editedPatch: "patch-bytes")
        let fake = ReviewFakeAppListener(mode: .replying(.decided(reply)))
        defer { fake.invalidate() }

        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--staged"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .success)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["editedPatch"] as? String == "patch-bytes")
    }

    // MARK: - Superseded and undecodable

    @Test func supersededOutcomeIsRequestFailedAndNeverADecision() async throws {
        let fake = ReviewFakeAppListener(mode: .replying(.superseded))
        defer { fake.invalidate() }

        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--staged"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .requestFailed,
                "a superseded wait received no decision; it is not a rejection either")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "request_failed")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("superseded"))
    }

    @Test func undecodableReplyIsRequestFailed() async throws {
        let fake = ReviewFakeAppListener(mode: .replyingRaw(Data("not json".utf8)))
        defer { fake.invalidate() }

        let result = await ReviewArm.run(
            arguments: ["review", "--wait", "--staged"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .requestFailed)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "request_failed")
    }

    // MARK: - The serving body's degenerate paths

    @Test func undecodableRequestYieldsTheRequestFailedEnvelope() async throws {
        let data = await ReviewServing.handle(
            requestData: Data("not a request".utf8),
            commonDir: "/repos/fixture/.git",
            store: PendingReviewStore())
        let failure = try #require(try? JSONDecoder().decode(EnvelopeFail.self, from: data))
        #expect(failure.error.code == .requestFailed)
    }

    @Test func unresolvableRepositoryYieldsTheRepositoryErrorEnvelope() async throws {
        let store = PendingReviewStore()
        let request = ReviewRequest(commonDir: "", selector: .staged, timeoutSeconds: 60)
        let data = await ReviewServing.handle(
            requestData: try JSONEncoder().encode(request),
            commonDir: nil,
            store: store)
        let failure = try #require(try? JSONDecoder().decode(EnvelopeFail.self, from: data))
        #expect(failure.error.code == .repositoryError)
        #expect(store.pendingReviews.isEmpty,
                "an unresolvable repository is never registered as a pending review")
    }
}
