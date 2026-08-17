// DispatchTests.swift — the CLI's local-vs-remote decision (#0124)

import Foundation
import Testing
@testable import YardKit

/// Counts calls without ever needing a real broker, launch agent, or
/// `NSXPCConnection` — the actor makes it safe to touch from the
/// `@Sendable` `connect` closure `dispatch` invokes.
private actor ConnectCallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("dispatch: local vs. remote vs. unknown")
struct DispatchTests {

    // MARK: - route(_:) classifies every case, switched over exhaustively

    /// One row per `Route` case, including the edge case that motivated the
    /// enum: `CommandRegistry.all` contains `switchyardSpec`, whose name is
    /// the literal string "switchyard" -- a naive "is this name anywhere in
    /// the registry?" check would misclassify `switchyard switchyard` as
    /// `.remote`, when it is not an invocable subcommand at all. `wehreami`
    /// is the coordinator's own example of the exact typo this issue exists
    /// to stop from launching the app.
    @Test(
        "route classifies local, remote, and unknown commands",
        arguments: [
            (["--help"], "local"),
            (["--version"], "local"),
            (["-v"], "local"),
            (["schema"], "local"),
            (["noop"], "local"),
            ([], "local"),
            (["whereami"], "remote"),
            (["switchyard"], "unknown"),
            (["bogus-command"], "unknown"),
            (["wehreami"], "unknown"),
        ] as [([String], String)]
    )
    func routeClassifiesArguments(arguments: [String], expected: String) {
        // Switched exhaustively: a case added to `Route` without a branch
        // here is a compile error, not a silently-skipped row.
        let classification: String
        switch route(arguments) {
        case .local: classification = "local"
        case .remote: classification = "remote"
        case .unknown: classification = "unknown"
        }
        #expect(classification == expected, "route(\(arguments)) should be \(expected), got \(classification)")
    }

    // MARK: - The assertion that matters: a local command never reaches for the connector

    /// A regression here breaks the CLI for everyone with no app installed:
    /// `--version` must work without ever touching `AppConnection`, because
    /// `connect` in production actually launches the app.
    @Test func versionCommandNeverCallsConnect() async throws {
        let counter = ConnectCallCounter()
        let result = await dispatch(arguments: ["--version"], workingDirectory: "/") {
            await counter.increment()
            throw AppConnectionError.appUnavailable
        }

        let calls = await counter.count
        #expect(calls == 0, "the connector must never be invoked for a locally-answered command")
        #expect(result.exitCode == .success)
        #expect(result.stdout == runYard(arguments: ["--version"]).stdout,
                "the local path must produce exactly what runYard produces on its own")
    }

    /// Every command `runYard` answers locally, one row per case so a case
    /// silently dropped from `localCommandNames` fails its own row rather
    /// than being skipped by a loop that only checks the first mismatch.
    @Test(
        "local commands never call connect",
        arguments: [["--help"], ["--version"], ["-v"], ["schema"], ["noop"], []]
    )
    func localCommandsNeverCallConnect(arguments: [String]) async throws {
        let counter = ConnectCallCounter()
        let result = await dispatch(arguments: arguments, workingDirectory: "/") {
            await counter.increment()
            throw AppConnectionError.appUnavailable
        }

        let calls = await counter.count
        #expect(calls == 0, "\(arguments) must be answered locally")
        #expect(result.stdout == runYard(arguments: arguments).stdout)
        #expect(result.exitCode == runYard(arguments: arguments).exitCode)
    }

    // MARK: - whereami: not local, so it must reach for the connector

    @Test func whereamiRoutesToTheAppAndExitsThreeWhenUnreachable() async throws {
        let counter = ConnectCallCounter()
        let result = await dispatch(arguments: ["whereami"], workingDirectory: "/") {
            await counter.increment()
            throw AppConnectionError.appUnavailable
        }

        let calls = await counter.count
        #expect(calls == 1, "a non-local command must call the connector exactly once")
        #expect(result.exitCode == .appUnavailable)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "app_unavailable")
    }

    // MARK: - An unknown command (a typo) must never reach the connector

    /// The assertion that catches a regression into launching the app for a
    /// misspelling: `connect`'s production implementation is
    /// `AppConnection.connect()`, which launches Switchyard.app if it is
    /// not already running. A command this build has never heard of --
    /// "wehreami", not "whereami" -- must be answered locally with the
    /// usage envelope, exit 1, the same way `runYard` has always answered
    /// an unrecognized subcommand, and must never touch `connect` at all.
    @Test func unknownCommandNeverCallsConnectAndExitsWithUsage() async throws {
        let counter = ConnectCallCounter()
        let result = await dispatch(arguments: ["wehreami"], workingDirectory: "/") {
            await counter.increment()
            throw AppConnectionError.appUnavailable
        }

        let calls = await counter.count
        #expect(calls == 0, "an unknown command must never reach for the connector")
        #expect(result.exitCode == .usage)
        #expect(result.stdout == runYard(arguments: ["wehreami"]).stdout,
                "the unknown path must produce exactly what runYard produces on its own")

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage")
    }

    // MARK: - The connection-failure exit-code table, reused from #0048's own mapping

    @Test(
        "connection failures map through AppConnectionError/CLIError's own exitCode, unchanged",
        arguments: [
            (AppConnectionError.appUnavailable, ExitCode.appUnavailable),
            (AppConnectionError.appNotInstalled, ExitCode.appUnavailable),
            (AppConnectionError.appTerminated(CancellationError()), ExitCode.sessionTerminated),
            (AppConnectionError.undecodableResponse, ExitCode.requestFailed),
        ] as [(AppConnectionError, ExitCode)]
    )
    func appConnectionErrorsMapToTheirOwnExitCode(error: AppConnectionError, expected: ExitCode) async throws {
        let result = await dispatch(arguments: ["whereami"], workingDirectory: "/") { throw error }
        #expect(result.exitCode == expected)
        #expect(result.stderr.hasPrefix("[error]"))
        #expect(result.stderr.hasSuffix("\n"))
    }

    @Test func cliErrorBrokerUnreachableMapsToExitCodeTwo() async throws {
        let result = await dispatch(arguments: ["whereami"], workingDirectory: "/") {
            throw CLIError.brokerUnreachable(URLError(.badURL))
        }
        #expect(result.exitCode == .brokerUnreachable)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? String == "broker_unreachable")
    }

    /// An error type neither `AppConnectionError` nor `CLIError` (unrealistic
    /// in production, since `connect`'s only real implementation throws one
    /// of those two) still degrades to `.requestFailed` rather than the
    /// function trapping or losing the failure.
    @Test func unrecognizedThrownErrorTypeMapsToRequestFailed() async throws {
        let result = await dispatch(arguments: ["whereami"], workingDirectory: "/") {
            throw URLError(.notConnectedToInternet)
        }
        #expect(result.exitCode == .requestFailed)
    }
}
