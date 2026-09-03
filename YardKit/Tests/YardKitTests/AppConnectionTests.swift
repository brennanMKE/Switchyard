// AppConnectionTests.swift

import Foundation
import Testing

@testable import YardKit

// MARK: - In-process fakes

/// Exports `AppServiceProtocol` over `NSXPCListener.anonymous()`, so the real
/// `AppConnection.call` path runs without the app or the broker.
private final class FakeAppService: NSObject, AppServiceProtocol {
    func appPing(reply: @escaping @Sendable (String) -> Void) {
        reply("pong")
    }

    /// Forwards to `performCommand`, the exact function `AppService.perform`
    /// in `Switchyard/AppXPCServer.swift` forwards to. The app target is not
    /// `@testable import`able from a Swift package test target, so this is
    /// not a re-implementation to keep in sync — it is a call to the same
    /// body the app actually runs, which is what makes a mutation to that
    /// body visible to `swift test`.
    func perform(
        arguments: [String],
        workingDirectory: String,
        reply: @escaping @Sendable (Data, Int32) -> Void
    ) {
        let result = performCommand(arguments: arguments, workingDirectory: workingDirectory)
        reply(result.stdout, result.exitCode)
    }

    /// What the last hook request carried, for the wire round-trip test.
    /// The real body (`runReferenceTransactionHook`, app-side in
    /// YardCommands) is total and always exits 0; this fake replies 0 and
    /// captures the request, so the test can assert the wire carried it
    /// intact rather than re-implementing the decision.
    struct CapturedHookRequest: Equatable {
        let state: String
        let environment: [String: String]
        let standardInput: Data
        let workingDirectory: String
    }

    private let hookLock = NSLock()
    private var _capturedHookRequest: CapturedHookRequest?

    var capturedHookRequest: CapturedHookRequest? {
        hookLock.withLock { _capturedHookRequest }
    }

    func performReferenceTransactionHook(
        state: String,
        environment: [String: String],
        standardInput: Data,
        workingDirectory: String,
        reply: @escaping @Sendable (Int32) -> Void
    ) {
        hookLock.withLock {
            _capturedHookRequest = CapturedHookRequest(
                state: state,
                environment: environment,
                standardInput: standardInput,
                workingDirectory: workingDirectory)
        }
        reply(0)
    }
}

private final class AppListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = FakeAppService()

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

/// Owns the listener and its (weakly-held-by-the-listener) delegate so both
/// stay alive for the length of a test.
private struct FakeAppListener {
    let listener: NSXPCListener
    let delegate: AppListenerDelegate

    init() {
        let listener = NSXPCListener.anonymous()
        let delegate = AppListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        self.listener = listener
        self.delegate = delegate
    }

    /// A fresh `AppConnection` pointed at this listener's endpoint.
    func connect() -> AppConnection {
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        connection.resume()
        return AppConnection(connection: connection)
    }
}

/// Exports `BrokerProtocol` over `NSXPCListener.anonymous()`, always
/// replying `nil` to `appEndpoint`. Lets `AppConnection.connect(broker:...)`
/// be tested without launchd or the app registering anything.
private final class FakeBrokerService: NSObject, BrokerProtocol {
    func brokerPing(reply: @escaping @Sendable (String) -> Void) {
        reply("pong")
    }

    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint) {}

    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        reply(nil)
    }
}

private final class BrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = FakeBrokerService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = XPCInterfaces.broker
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private struct FakeBroker {
    let listener: NSXPCListener
    let delegate: BrokerListenerDelegate
    let connection: BrokerConnection

    init() {
        let listener = NSXPCListener.anonymous()
        let delegate = BrokerListenerDelegate()
        listener.delegate = delegate
        listener.resume()

        let xpc = NSXPCConnection(listenerEndpoint: listener.endpoint)
        xpc.remoteObjectInterface = XPCInterfaces.broker
        xpc.resume()

        self.listener = listener
        self.delegate = delegate
        self.connection = BrokerConnection(connection: xpc, defaultTimeout: testTimeout)
    }
}

/// Deadlines in this file are deliberately generous.
///
/// The package runs ~80 suites in parallel and most of them block in `git`
/// subprocesses via `GitProcess.capture`'s unconditional, synchronous
/// `readDataToEndOfFile()`/`waitUntilExit()` (see the comment there) —
/// called from inside `async` test functions across the suite, which blocks
/// whichever cooperative-pool thread happened to be running that test until
/// the subprocess exits. With enough of those running at once the pool has
/// no free thread left to resume *anything* suspended on it, including a
/// `Task.sleep` timer firing or an already-arrived XPC reply's continuation
/// — so a test can sit fully ready to complete while simply waiting for a
/// worker thread.
///
/// **This was 60s (#0240) and that was not enough — #0272 diagnosed why and
/// raised it again, this time with the failure mode identified rather than
/// guessed at.** Reproduced deliberately by running two full `swift test`
/// invocations concurrently (`AGENTS.md` Rule 3c; 12-core machine, ~80
/// suites/1162 tests each): every `AppConnectionTests` test — including
/// ones with no internal wait at all, like `brokerUnreachableMapsToExitCodeTwo`
/// — took 46–79s of **wall-clock** time from "started" to "passed", even
/// though every run in that trial still passed. That is the shape #0240's
/// row in `docs/review-failures.md` predicts and this file's own doc comment
/// already named: starvation, not a slow reply. `poll`'s internal deadlines
/// (`launchTimeout: .milliseconds(200)` in the `--no-launch`/`--require-app`
/// tests, `pollIsBoundedByItsTimeout`'s 300ms bound) are unaffected — those
/// tests still passed at 58–79s wall-clock because the elapsed time is
/// almost entirely the wait *before* the test's `Task` gets a thread at
/// all, not time spent inside `poll`.
///
/// A 60s deadline left under 20% headroom over that measured 79s ceiling;
/// 180s (~2.3x it) gives real margin against the same starvation recurring
/// worse, while still being a bound — a hung app still fails a test, just
/// not inside this file's own noise floor. The production defaults are
/// unchanged: a CLI is one process making one call.
private let testTimeout: Duration = .seconds(180)

// MARK: - Tests

@Suite("AppConnection and BrokerConnection")
struct AppConnectionTests {

    // MARK: Broker unreachable → code 2

    @Test func brokerUnreachableMapsToExitCodeTwo() async throws {
        // A Mach service name embedding a UUID cannot exist, so the error
        // handler fires immediately rather than hanging — measured during
        // planning at 0.000s.
        let broker = BrokerConnection(
            machServiceName: "co.sstools.switchyard.test.\(UUID().uuidString)",
            defaultTimeout: testTimeout)
        defer { broker.close() }

        do {
            _ = try await broker.ping()
            Issue.record("expected CLIError.brokerUnreachable")
        } catch let error as CLIError {
            guard case .brokerUnreachable = error else {
                Issue.record("expected .brokerUnreachable, got \(error)")
                return
            }
            #expect(error.exitCode == .brokerUnreachable)
        }
    }

    // MARK: Request/reply over an anonymous endpoint

    @Test func requestReplyOverAnAnonymousEndpointRoundTrips() async throws {
        let fake = FakeAppListener()
        defer { fake.listener.invalidate() }

        let app = fake.connect()
        defer { app.close() }

        let reply = try await app.appPing(timeout: testTimeout)
        #expect(reply == "pong")
    }

    // MARK: App terminated → code 5

    @Test func appTerminatedMapsToExitCodeFive() async throws {
        let fake = FakeAppListener()
        let app = fake.connect()

        // Prove the connection works before killing it, or a failure below
        // could just as easily mean the setup was wrong.
        let reply = try await app.appPing(timeout: testTimeout)
        #expect(reply == "pong")

        fake.listener.invalidate()

        do {
            _ = try await app.appPing(timeout: testTimeout)
            Issue.record("expected AppConnectionError.appTerminated")
        } catch let error as AppConnectionError {
            guard case .appTerminated = error else {
                Issue.record("expected .appTerminated, got \(error)")
                return
            }
            #expect(error.exitCode == .sessionTerminated)
        }
    }

    // MARK: The poll is bounded

    @Test func pollIsBoundedByItsTimeout() async throws {
        // Deliberately not asserting elapsed wall-clock time: under this
        // suite's full parallel run (70 suites, many launching blocking git
        // subprocesses), Task.sleep can be delayed tens of seconds by
        // cooperative-thread-pool contention that is a property of the
        // machine's scheduling under load, not of `poll`'s own deadline
        // check -- measured, reproducibly, at ~25s against a 300ms bound.
        // What "a broken app cannot hang the CLI forever" actually requires
        // is termination with a bounded number of `fetch` calls, which is
        // deterministic under any scheduling delay: a `poll` that ignored
        // its deadline would call `fetch` forever and this test would never
        // return, which the suite's own per-test timeout turns into a
        // failure rather than a false pass.
        actor CallCounter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let counter = CallCounter()
        let timeout: Duration = .milliseconds(300)
        let interval: Duration = .milliseconds(50)

        let result: Int? = try await AppConnection.poll(timeout: timeout, interval: interval) {
            await counter.increment()
            return nil
        }

        let invocations = await counter.count
        // Computed from the parameters, not hardcoded: the loop sleeps once
        // per iteration and re-checks the deadline afterward, so it can run
        // one interval past the point that would exactly divide the timeout.
        let maxInvocations = Int((timeout.seconds / interval.seconds).rounded(.up)) + 1

        #expect(result == nil)
        #expect(invocations >= 1)
        #expect(invocations <= maxInvocations)
    }

    // MARK: A value on the first attempt needs no wait

    @Test func aValueAvailableOnTheFirstAttemptNeedsNoWait() async throws {
        actor Counter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let fetchCount = Counter()
        let sleepCount = Counter()

        // `poll` checks before it waits: a value that is already there does
        // not pay for an `interval`'s sleep. Pinned by counting real
        // *sleeps*, not fetches -- a fetch-count assertion alone cannot
        // distinguish fetch-before-sleep from sleep-before-fetch when
        // `sleep` is a no-op, since either ordering still calls `fetch`
        // exactly once for a first-try success (moving `sleep` back above
        // `fetch` and re-running this test proves it: fetch count stays 1).
        // Counting sleep invocations does distinguish them -- zero means
        // `fetch` ran and returned before any wait was ever needed, which
        // is the actual claim "needs no wait" makes. Neither count reads a
        // clock (Rule 7c).
        let result: String? = try await AppConnection.poll(
            timeout: .seconds(60),
            sleep: { _ in await sleepCount.increment() }
        ) {
            await fetchCount.increment()
            return "already-registered"
        }

        #expect(result == "already-registered")
        #expect(await fetchCount.count == 1)
        #expect(await sleepCount.count == 0)
    }

    // MARK: A nil result is not a failure

    @Test func aNilResultRightAfterLaunchIsNotAFailure() async throws {
        actor Counter {
            private var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = Counter()

        // The criterion this test exists for is logic, not timing: does a
        // transient nil get treated as fatal, or does polling continue past
        // it to the eventual value? Proving that requires the loop to
        // actually iterate past a nil, which needs `sleep` to return
        // between attempts -- and asserting on the outcome of a *real*
        // sleep completing within any wall-clock deadline is exactly what
        // Rule 7c forbids, just reached through a dependency instead of a
        // direct `#expect(elapsed...)`. Two stacked real sleeps were enough
        // to make this test flake under two concurrent full suites even
        // with a 60s deadline (measured, issue #0240) -- a single delayed
        // `Task.sleep` can run tens of seconds under this suite's
        // contention regardless of the requested duration (#0048), and nothing
        // stops that delay from recurring on every attempt.
        //
        // So `sleep` is a no-op here: the loop's logic — keep going on nil,
        // return the value once `fetch` provides one — is exercised for
        // real, with nothing about the result depending on real time or
        // this machine's scheduling. `timeout` and `interval` stay
        // meaningful to `poll`'s bookkeeping (the deadline check still
        // reads the real clock) but are never actually waited on.
        let result: String? = await AppConnection.poll(
            timeout: .seconds(60),
            interval: .milliseconds(10),
            sleep: { _ in }
        ) {
            let attempt = await counter.next()
            return attempt < 3 ? nil : "registered"
        }

        #expect(result == "registered")
    }

    // MARK: --no-launch and --require-app

    @Test func launchIfNeededFalseDoesNotLaunch() async throws {
        let fake = FakeBroker()
        defer { fake.listener.invalidate() }

        await #expect(throws: AppConnectionError.self) {
            _ = try await AppConnection.connect(
                broker: fake.connection,
                launchIfNeeded: false,
                requireApp: false,
                launchTimeout: .milliseconds(200))
        }
    }

    @Test func requireAppFailsFastWithoutLaunching() async throws {
        let fake = FakeBroker()
        defer { fake.listener.invalidate() }

        await #expect(throws: AppConnectionError.self) {
            _ = try await AppConnection.connect(
                broker: fake.connection,
                launchIfNeeded: true,
                requireApp: true,
                launchTimeout: .milliseconds(200))
        }
    }

    // MARK: - The exit-code table, one assertion per row

    @Test func brokerUnreachableRowMapsToExitCodeTwo() {
        let error = CLIError.brokerUnreachable(URLError(.badURL))
        #expect(error.exitCode == .brokerUnreachable)
    }

    @Test func timedOutRowMapsToExitCodeTwo() {
        let error = CLIError.timedOut(.seconds(5))
        #expect(error.exitCode == .brokerUnreachable)
    }

    @Test func protocolMismatchRowMapsToExitCodeFour() {
        let error = CLIError.protocolMismatch("BrokerProtocol")
        #expect(error.exitCode == .requestFailed)
    }

    @Test func appUnavailableRowMapsToExitCodeThree() {
        let error = AppConnectionError.appUnavailable
        #expect(error.exitCode == .appUnavailable)
    }

    @Test func appNotInstalledRowMapsToExitCodeThree() {
        let error = AppConnectionError.appNotInstalled
        #expect(error.exitCode == .appUnavailable)
    }

    @Test func appTerminatedRowMapsToExitCodeFive() {
        let error = AppConnectionError.appTerminated(URLError(.networkConnectionLost))
        #expect(error.exitCode == .sessionTerminated)
    }

    @Test func undecodableResponseRowMapsToExitCodeFour() {
        let error = AppConnectionError.undecodableResponse
        #expect(error.exitCode == .requestFailed)
    }

    // MARK: - perform round-trips runYard's own output, byte for byte

    /// Argv values to exercise `perform` against, paired with a name for the
    /// test's own bookkeeping. `runYard` already has dedicated tests for the
    /// shape of each of these outputs — this suite only cares that `perform`
    /// delivers the exact same bytes and exit code back across the wire.
    private static let performArgvCases: [[String]] = [
        ["schema"],
        ["noop"],
        ["--version"],
        ["bogus-command-that-does-not-exist"],
    ]

    @Test("perform round-trips runYard's bytes exactly", arguments: performArgvCases)
    func performRoundTripsBytesExactly(arguments: [String]) async throws {
        let fake = FakeAppListener()
        defer { fake.listener.invalidate() }
        let app = fake.connect()
        defer { app.close() }

        let expected = runYard(arguments: arguments)
        let expectedData = Data(expected.stdout.utf8)
        #expect(!expectedData.isEmpty)

        let (data, exitCode) = try await app.perform(
            arguments: arguments,
            workingDirectory: "/",
            timeout: testTimeout)

        #expect(data == expectedData)
        #expect(exitCode == Int32(expected.exitCode.rawValue))
    }

    // MARK: - Unknown exit codes map to requestFailed, never trap

    @Test func unknownExitCodeValueMapsToRequestFailed() {
        let mapped = ExitCode(fromAppReply: 123)
        #expect(mapped == .requestFailed)
    }

    @Test func negativeExitCodeValueMapsToRequestFailed() {
        let mapped = ExitCode(fromAppReply: -1)
        #expect(mapped == .requestFailed)
    }

    @Test func knownExitCodeValueMapsThrough() {
        let mapped = ExitCode(fromAppReply: 3)
        #expect(mapped == .appUnavailable)
    }

    // MARK: - The hook request crosses the wire intact (#0154)

    /// The hook arm ships state + environment + stdin bytes over
    /// `performReferenceTransactionHook`. This asserts all three arrive at
    /// the other side byte-for-byte and the `Int32` reply comes back — the
    /// same round-trip guarantee `performRoundTripsBytesExactly` gives
    /// `perform`, for the request shape argv cannot carry.
    @Test func performReferenceTransactionHookRoundTripsTheRequest() async throws {
        let fake = FakeAppListener()
        defer { fake.listener.invalidate() }
        let app = fake.connect()
        defer { app.close() }

        let environment = ["SWITCHYARD_YARD_INVOCATION": "", "HOME": "/Users/nobody"]
        let standardInput = Data("0000000 1234567 refs/heads/main\n".utf8)

        let exitCode = try await app.performReferenceTransactionHook(
            state: "committed",
            environment: environment,
            standardInput: standardInput,
            workingDirectory: "/tmp/some-repo",
            timeout: testTimeout)

        #expect(exitCode == 0)
        let captured = try #require(
            fake.delegate.service.capturedHookRequest,
            "the hook request must have reached the app side")
        #expect(captured.state == "committed")
        #expect(captured.environment == environment)
        #expect(captured.standardInput == standardInput)
        #expect(captured.workingDirectory == "/tmp/some-repo")
    }
}
