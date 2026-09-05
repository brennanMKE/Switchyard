// ResolveArmTests.swift — the `resolve --wait` arm's blocking semantics (#0057)
//
// The arm is exercised against real anonymous XPC listeners, the way
// `ReviewArmTests` exercises the review arm: the serve mode runs the REAL
// app-side body (`ResolveServing.handle`) against a REAL `PendingResolveStore`,
// so the typed timeout below is produced by the store, not faked. No
// assertion reads a clock (Rule 7c): the timeout test uses a SHORT real
// timeout and asserts the typed outcome and exit code, never elapsed time.

import Foundation
import Testing
@testable import YardKit

// MARK: - In-process fakes

private final class ResolveFakeAppService: NSObject, AppServiceProtocol {

    /// What the fake does with a resolve request.
    enum Mode: Sendable {
        /// Runs the real serving body against a real store — the same body
        /// the app's `AppService` runs, minus the engine's common-dir
        /// resolution (passed in directly).
        case serving(store: PendingResolveStore, commonDir: String)
        /// Captures the request and replies the encoded outcome immediately.
        case replying(ResolveOutcome)
        /// Captures the request and replies raw bytes — the undecodable-reply
        /// path.
        case replyingRaw(Data)
        /// Captures the request (and the reply block) and never replies —
        /// the app-death test invalidates the listener while the CLI waits.
        case neverReplying
    }

    private let mode: Mode

    /// How many conflicted paths the fake's `conflicts` command reports —
    /// the canned envelope the arm's post-reply re-check reads. When
    /// `malformedConflicts` is set the envelope carries no result array at
    /// all, the unreadable-re-check path.
    private let conflictCount: Int
    private let malformedConflicts: Bool

    private let lock = NSLock()
    private var _capturedRequest: (requestData: Data, workingDirectory: String)?
    private var _replyCaptured = false
    private var _performedArguments: [String] = []

    init(mode: Mode, conflictCount: Int = 0, malformedConflicts: Bool = false) {
        self.mode = mode
        self.conflictCount = conflictCount
        self.malformedConflicts = malformedConflicts
        super.init()
    }

    var capturedRequest: (requestData: Data, workingDirectory: String)? {
        lock.withLock { _capturedRequest }
    }

    var replyCaptured: Bool {
        lock.withLock { _replyCaptured }
    }

    var performedArguments: [String] {
        lock.withLock { _performedArguments }
    }

    func appPing(reply: @escaping @Sendable (String) -> Void) {
        reply("pong")
    }

    func perform(
        arguments: [String],
        workingDirectory: String,
        reply: @escaping @Sendable (Data, Int32) -> Void
    ) {
        lock.withLock { _performedArguments = arguments }
        if malformedConflicts {
            reply(Data(#"{"schemaVersion":1,"ok":true}"#.utf8), 0)
            return
        }
        // A canned `conflicts` envelope: the real command's result is an
        // array of conflicted-path objects, and the arm counts the array —
        // so the fake synthesizes exactly that many one-key entries.
        let entries = Array(repeating: #"{"path":"f.txt","kind":"UU"}"#, count: conflictCount)
        let envelope = #"{"schemaVersion":1,"ok":true,"result":[\#(entries.joined(separator: ","))]}"#
        reply(Data(envelope.utf8), 0)
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
        lock.withLock {
            _capturedRequest = (request, workingDirectory)
            _replyCaptured = true
        }
        switch mode {
        case .serving(let store, let commonDir):
            Task {
                let outcomeData = await ResolveServing.handle(
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

private final class ResolveListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: ResolveFakeAppService

    init(service: ResolveFakeAppService) {
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
private final class ResolveFakeAppListener: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: ResolveFakeAppService
    private let delegate: ResolveListenerDelegate

    init(mode: ResolveFakeAppService.Mode, conflictCount: Int = 0, malformedConflicts: Bool = false) {
        self.service = ResolveFakeAppService(
            mode: mode, conflictCount: conflictCount, malformedConflicts: malformedConflicts)
        self.delegate = ResolveListenerDelegate(service: service)
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

@Suite("resolve arm")
struct ResolveArmTests {

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

    /// The spec must be registered, with a non-empty summary, the right
    /// schema name, the two flags, and every documented exit code.
    @Test func resolveSpecIsRegisteredWithRequiredMetadata() throws {
        let spec = try #require(CommandRegistry.lookup(name: "resolve"),
                                "resolve must be in CommandRegistry.all")
        #expect(!spec.summary.isEmpty)
        #expect(spec.schemaName == "resolve")
        let flags = Set(spec.flags.map(\.long))
        #expect(flags == ["wait", "timeout"],
                "the resolve spec must document --wait and --timeout; got \(flags.sorted())")
        let codes = Set(spec.exitCodes.map(\.code))
        for required: Int32 in [0, 1, 3, 4, 5, 7, 8, 10] {
            #expect(codes.contains(required), "the resolve spec must document exit \(required)")
        }
    }

    // MARK: - The exit-code vocabulary

    @Test func timedOutIsTenAndDistinctFromAppDownAppDeathCancellationAndConflicts() {
        #expect(ExitCode.timedOut.rawValue == 10)
        #expect(ExitCode.timedOut.codeLabel == "timed_out")
        #expect(ExitCode.timedOut != .appUnavailable, "3 is the app not running")
        #expect(ExitCode.timedOut != .sessionTerminated, "5 is the app dying")
        #expect(ExitCode.timedOut != .humanDeclined, "7 is the human cancelling")
        #expect(ExitCode.timedOut != .blockedOnConflicts, "8 is conflicts remaining")
    }

    @Test func blockedOnConflictsIsEightAndMapsFromTheEnvelopeCode() {
        #expect(ExitCode.blockedOnConflicts.rawValue == 8)
        #expect(EnvelopeErrorCode.blockedOnConflicts.exitCode == .blockedOnConflicts)
        #expect(EnvelopeErrorCode(rawValue: ExitCode.blockedOnConflicts.codeLabel) == .blockedOnConflicts)
    }

    // MARK: - Usage refusals

    @Test func nonWaitFormIsRefusedAsUsage() async throws {
        // The connect closure would exit 3 if it were ever reached — it is
        // not: a refusal is decided in argv, before any connection.
        let result = await ResolveArm.run(
            arguments: ["resolve", "f.txt"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "usage")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("--wait"), "the refusal must say the blocking form requires --wait")
    }

    @Test func secondPathspecIsRefusedAsUsage() async throws {
        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait", "f.txt", "g.txt"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func emptyPathspecIsRefusedAsUsage() async throws {
        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait", ""],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func malformedTimeoutIsRefusedAsUsage() async throws {
        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait", "--timeout", "abc"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    @Test func unknownFlagIsRefusedAsUsage() async throws {
        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait", "--bogus"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .usage)
    }

    // MARK: - Parse acceptance

    @Test func acceptedInvocationDefaultsToTheJudgementTimeout() throws {
        switch ResolveArm.parseInvocation(["resolve", "--wait"]) {
        case .refused(let message):
            Issue.record("expected a run invocation, got refused: \(message)")
        case .run(let invocation):
            #expect(invocation.timeoutSeconds == 3600, "the default timeout is a judgement, 3600 s")
            #expect(invocation.pathspec == nil, "no pathspec means every conflicted path")
        }
    }

    @Test func acceptedInvocationCarriesPathspecAndExplicitTimeout() throws {
        switch ResolveArm.parseInvocation(["resolve", "--wait", "--timeout", "30", "Sources"]) {
        case .refused(let message):
            Issue.record("expected a run invocation, got refused: \(message)")
        case .run(let invocation):
            #expect(invocation.timeoutSeconds == 30)
            #expect(invocation.pathspec == "Sources")
        }
    }

    // MARK: - The app is down → exit 3, never a fallback

    @Test func appDownExitsThreeWithTheAppUnavailableEnvelope() async throws {
        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/") {
            throw AppConnectionError.appUnavailable
        }
        #expect(result.exitCode == .appUnavailable)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "app_unavailable")
    }

    /// The dispatch-level guarantee: `resolve` is intercepted with its OWN
    /// connector (`launchIfNeeded: false` — resolve never launches the app),
    /// and the ordinary remote `connect` is never reached for it.
    @Test func dispatchRoutesResolveToTheArmWithItsOwnConnector() async throws {
        actor Counter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let remoteCounter = Counter()
        let resolveCounter = Counter()

        let result = await dispatch(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/",
            connect: {
                await remoteCounter.increment()
                throw AppConnectionError.appUnavailable
            },
            connectResolve: {
                await resolveCounter.increment()
                throw AppConnectionError.appUnavailable
            })

        #expect(await remoteCounter.count == 0,
                "resolve must never go down the generic perform path")
        #expect(await resolveCounter.count == 1,
                "resolve must use its own launchIfNeeded:false connector exactly once")
        #expect(result.exitCode == .appUnavailable)
    }

    // MARK: - The typed timeout → exit 10

    /// The full loop, through a real listener and the REAL serving body and
    /// store: the CLI asks for a 1-second wait, the store fires its typed
    /// timeout, and the arm maps it to exit 10 with the `timed_out` envelope.
    @Test func storeTimeoutArrivesAsExitTenWithTheTypedEnvelope() async throws {
        let fake = ResolveFakeAppListener(
            mode: .serving(store: PendingResolveStore(), commonDir: "/repos/fixture/.git"))
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait", "--timeout", "1"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .timedOut, "a timed-out wait is exit 10, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "timed_out")
    }

    // MARK: - App death → exit 5, never a decision

    /// The listener dies while the CLI is mid-wait: the connection's error
    /// path must surface as exit 5 — never as a decision, never as a timeout.
    @Test func appDeathMidResolveExitsFive() async throws {
        let fake = ResolveFakeAppListener(mode: .neverReplying)

        let runner = Task {
            await ResolveArm.run(
                arguments: ["resolve", "--wait", "--timeout", "60"],
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
                "app death mid-resolve is exit 5, got \(result.exitCode)")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "session_terminated")
    }

    // MARK: - Decided outcomes

    /// Cancel → exit 7, with the envelope still carrying the cancelled reply
    /// and ok:true — the same contract as a rejected review. Kills mutation 3
    /// (map a cancellation to exit 0).
    @Test func cancelledReplyExitsSevenWithTheCancelledPayload() async throws {
        let fake = ResolveFakeAppListener(mode: .replying(.decided(.cancelled)))
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .humanDeclined,
                "a cancelled resolve is exit 7, got \(result.exitCode)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true,
                "a cancellation is a completed resolve: the envelope says ok:true")
        let payload = try #require(object["result"] as? [String: Any],
                                   "the payload IS the reply, per the wire contract")
        #expect(payload["cancelled"] as? Bool == true)
    }

    /// Decided with resolutions and conflicts remaining → exit 8, envelope
    /// still carrying the reply with ok:true. Kills mutation 2 (map
    /// conflicts-remaining to exit 0).
    @Test func conflictsRemainingAfterTheReplyExitsEight() async throws {
        let resolutions = ResolveReply.resolutions([
            PathResolution(path: "f.txt", kind: .bothModified, choice: .useOurs)])
        let fake = ResolveFakeAppListener(
            mode: .replying(.decided(resolutions)), conflictCount: 1)
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/somewhere",
            connect: { fake.connect() })

        #expect(result.exitCode == .blockedOnConflicts,
                "conflicts remaining after the reply is exit 8, got \(result.exitCode)")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["resolutions"] != nil, "the reply rides the envelope even at exit 8")
        #expect(fake.service.performedArguments == ["conflicts"],
                "the re-check must run the app's conflicts command")
    }

    /// Decided with resolutions and a clean repository → exit 0.
    @Test func allConflictsResolvedAfterTheReplyExitsZero() async throws {
        let resolutions = ResolveReply.resolutions([
            PathResolution(path: "f.txt", kind: .bothModified, choice: .useOurs)])
        let fake = ResolveFakeAppListener(
            mode: .replying(.decided(resolutions)), conflictCount: 0)
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/somewhere",
            connect: { fake.connect() })

        #expect(result.exitCode == .success, "a clean repository after the reply is exit 0")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let payload = try #require(object["result"] as? [String: Any])
        let entries = try #require(payload["resolutions"] as? [[String: Any]])
        #expect(!entries.isEmpty, "the payload carries the per-path resolutions")
        #expect(entries.first?["path"] as? String == "f.txt")
    }

    /// A decided reply that staged nothing still checks the index: conflicts
    /// remaining → 8, the same as any other incomplete resolution.
    @Test func emptyResolutionsWithConflictsRemainingExitsEight() async throws {
        let fake = ResolveFakeAppListener(
            mode: .replying(.decided(.resolutions([]))), conflictCount: 2)
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/somewhere",
            connect: { fake.connect() })

        #expect(result.exitCode == .blockedOnConflicts)
    }

    // MARK: - Superseded and undecodable

    @Test func supersededOutcomeIsRequestFailedAndNeverADecision() async throws {
        let fake = ResolveFakeAppListener(mode: .replying(.superseded))
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .requestFailed,
                "a superseded wait received no reply; it is not a cancellation either")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "request_failed")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("superseded"))
    }

    @Test func undecodableReplyIsRequestFailed() async throws {
        let fake = ResolveFakeAppListener(mode: .replyingRaw(Data("not json".utf8)))
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/",
            connect: { fake.connect() })

        #expect(result.exitCode == .requestFailed)
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "request_failed")
    }

    /// A malformed `conflicts` envelope after the reply cannot be read as
    /// "clean" — an unreadable re-check is a request failure (4), never a
    /// fabricated exit 0.
    @Test func malformedConflictsEnvelopeAfterTheReplyIsRequestFailed() async throws {
        let fake = ResolveFakeAppListener(
            mode: .replying(.decided(.resolutions([]))),
            malformedConflicts: true)
        defer { fake.invalidate() }

        let result = await ResolveArm.run(
            arguments: ["resolve", "--wait"],
            workingDirectory: "/somewhere",
            connect: { fake.connect() })

        #expect(result.exitCode == .requestFailed,
                "an unreadable re-check must not be reported as success")
        let error = try errorBody(ofJSON: result.stdout)
        #expect(error["code"] as? String == "request_failed")
    }

    // MARK: - The serving body's degenerate paths

    @Test func undecodableRequestYieldsTheRequestFailedEnvelope() async throws {
        let data = await ResolveServing.handle(
            requestData: Data("not a request".utf8),
            commonDir: "/repos/fixture/.git",
            store: PendingResolveStore())
        let failure = try #require(try? JSONDecoder().decode(EnvelopeFail.self, from: data))
        #expect(failure.error.code == .requestFailed)
    }

    @Test func unresolvableRepositoryYieldsTheRepositoryErrorEnvelope() async throws {
        let store = PendingResolveStore()
        let request = ResolveRequest(commonDir: "", timeoutSeconds: 60)
        let data = await ResolveServing.handle(
            requestData: try JSONEncoder().encode(request),
            commonDir: nil,
            store: store)
        let failure = try #require(try? JSONDecoder().decode(EnvelopeFail.self, from: data))
        #expect(failure.error.code == .repositoryError)
        #expect(store.pendingResolves.isEmpty,
                "an unresolvable repository is never registered as a pending resolve")
    }
}
