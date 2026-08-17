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
/// The package runs 70 suites in parallel and most of them block in `git`
/// subprocesses, which starves the cooperative thread pool badly enough that a
/// reply can arrive tens of seconds late. **A late reply is not a failed
/// reply**, and a test that says otherwise measures the machine — two tests
/// asserting elapsed time cost a round on 2026-08-17, and five more failed on
/// `main` the same day for the same reason with a 5-second deadline. The
/// production defaults are unchanged: a CLI is one process making one call.
private let testTimeout: Duration = .seconds(60)

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

        let result: Int? = await AppConnection.poll(timeout: timeout, interval: interval) {
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

        // A generous timeout, not a tight one: this test asserts the poll
        // returns the value the moment it appears, not how fast it appears.
        // Under this suite's full parallel run a scheduling stall costs the
        // test wall-clock time, not correctness -- 60s is comfortably more
        // than any stall observed (~25s, see pollIsBoundedByItsTimeout above).
        let result: String? = await AppConnection.poll(
            timeout: .seconds(60),
            interval: .milliseconds(10)
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
}
