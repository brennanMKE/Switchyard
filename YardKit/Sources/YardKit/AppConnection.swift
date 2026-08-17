// AppConnection.swift
//
// Ported from ../../RemoteControl/BridgeKit/Sources/remotectl/AppConnection.swift
// (MIT, same author — see CLAUDE.md and issue #0048's planning update).
// Copyright the original author; substantial portions retained here under
// the same MIT terms as this project.
//
// Scoped to the client side only: connecting, polling, and mapping failures
// to exit codes. The app accepting a connection and exporting a real service
// interface is #0215 — this file is proven against an in-process
// NSXPCListener.anonymous(), not against the running app.

import AppKit
import Foundation

/// A direct connection to the running app.
///
/// Getting one takes three steps, and the middle one is the whole point of the
/// broker: ask the broker for the app's anonymous listener endpoint, then open
/// `NSXPCConnection(listenerEndpoint:)` against it. The endpoint is a live mach
/// right, so it can only arrive over an existing XPC connection — there is no
/// file or defaults key it could have been left in.
///
/// `@unchecked Sendable` for the same reason as ``BrokerConnection``: it wraps an
/// `NSXPCConnection`, which is not `Sendable` but is safe across queues.
public final class AppConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    /// Not `private`: the seam a test uses to construct an `AppConnection`
    /// directly from an in-process `NSXPCConnection(listenerEndpoint:)`
    /// against `NSXPCListener.anonymous()`, exercising the real `call` path
    /// without the app or the broker.
    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Connects to the app, launching it first if it isn't registered yet.
    ///
    /// - Parameters:
    ///   - launchIfNeeded: `--no-launch` passes `false` here. When the broker
    ///     has no endpoint registered and this is `false`, this throws
    ///     ``AppConnectionError/appUnavailable`` instead of launching the app.
    ///   - requireApp: `--require-app` passes `true` here. When the broker has
    ///     no endpoint registered, this fails fast with
    ///     ``AppConnectionError/appUnavailable`` before attempting a launch,
    ///     regardless of `launchIfNeeded`.
    public static func connect(
        launchIfNeeded: Bool = true,
        requireApp: Bool = false,
        launchTimeout: Duration = .seconds(10)
    ) async throws -> AppConnection {
        try await connect(
            broker: BrokerConnection(),
            launchIfNeeded: launchIfNeeded,
            requireApp: requireApp,
            launchTimeout: launchTimeout)
    }

    /// The real body of `connect`, with the broker injectable. Not `public`:
    /// a test hands this an in-process fake broker
    /// (`NSXPCListener.anonymous()` exporting `BrokerProtocol`) to exercise
    /// `launchIfNeeded`/`requireApp` without launchd or the app — see
    /// `AppConnectionTests`.
    static func connect(
        broker: BrokerConnection,
        launchIfNeeded: Bool,
        requireApp: Bool,
        launchTimeout: Duration
    ) async throws -> AppConnection {
        defer { broker.close() }

        // Distinguishing "broker unreachable" from "no endpoint registered"
        // matters: the former means the agent isn't registered or is
        // awaiting approval, which launching the app cannot fix. The latter
        // means the broker is fine and the app simply isn't running.
        var endpoint = try await broker.appEndpoint()

        if endpoint == nil {
            if requireApp {
                throw AppConnectionError.appUnavailable
            }
            if launchIfNeeded {
                try launchApp()
                endpoint = try await poll(timeout: launchTimeout) {
                    try await broker.appEndpoint()
                }
            }
        }

        guard let endpoint else {
            throw AppConnectionError.appUnavailable
        }

        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = XPCInterfaces.appService
        connection.resume()
        return AppConnection(connection: connection)
    }

    /// Polls `fetch` until it returns a value or `timeout` elapses.
    ///
    /// A nil result immediately after launching the app is normal, not a
    /// failure: app registration races app launch. The bound is what
    /// matters — without it a broken app hangs the CLI forever.
    public static func poll<Value: Sendable>(
        timeout: Duration,
        interval: Duration = .milliseconds(250),
        clock: ContinuousClock = ContinuousClock(),
        _ fetch: @Sendable () async throws -> Value?
    ) async rethrows -> Value? {
        let deadline = clock.now + timeout

        while clock.now < deadline {
            // `rethrows` may only throw from `fetch`, so a cancellation from
            // `Task.sleep` itself is swallowed here rather than propagated —
            // the loop's own bound (`clock.now < deadline`) is what ends it.
            try? await Task.sleep(for: interval)
            if let value = try await fetch() {
                return value
            }
        }
        return nil
    }

    private static func launchApp() throws {
        guard
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: ServiceNames.bundleIdentifier
            )
        else {
            throw AppConnectionError.appNotInstalled
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // The point is to get the app's XPC listener up, not to steal focus.
        configuration.activates = false
        configuration.addsToRecentItems = false

        // openApplication is callback-based; this bridges it and is bounded by
        // the caller's poll deadline anyway.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    public func close() {
        connection.invalidate()
    }

    // MARK: - Calls

    public func appPing(timeout: Duration = .seconds(5)) async throws -> String {
        try await call(timeout: timeout) { app, complete in
            app.appPing { complete(.success($0)) }
        }
    }

    private func call<T: Sendable>(
        timeout: Duration,
        _ invoke: @escaping @Sendable (any AppServiceProtocol, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let once = ResumeOnce<T>()

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    once.attach(continuation)

                    // @Sendable is required: Foundation types this parameter as a
                    // plain closure, and without it the closure would inherit the
                    // enclosing isolation and trap when XPC calls it off that
                    // queue.
                    let proxy = self.connection.remoteObjectProxyWithErrorHandler {
                        @Sendable error in
                        once.finish(.failure(AppConnectionError.appTerminated(error)))
                    }
                    guard let app = proxy as? any AppServiceProtocol else {
                        once.finish(.failure(CLIError.protocolMismatch("AppServiceProtocol")))
                        return
                    }
                    invoke(app) { once.finish($0) }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                self.connection.invalidate()
                throw CLIError.timedOut(timeout)
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

public enum AppConnectionError: Error, CustomStringConvertible, Sendable {
    case appUnavailable
    case appNotInstalled
    case appTerminated(any Error)
    case undecodableResponse

    public var description: String {
        switch self {
        case .appUnavailable:
            "the broker is reachable but no app endpoint is registered"
        case .appNotInstalled:
            "no application with bundle identifier \(ServiceNames.bundleIdentifier) is registered with LaunchServices"
        case .appTerminated(let underlying):
            "lost the connection to the app: \(underlying.localizedDescription)"
        case .undecodableResponse:
            "the app replied with something that could not be decoded"
        }
    }

    /// The `ExitCode` this failure maps to. Switched exhaustively — no
    /// `default` — so a new case is a compile error rather than a silently
    /// wrong code.
    public var exitCode: ExitCode {
        switch self {
        case .appUnavailable: .appUnavailable
        case .appNotInstalled: .appUnavailable
        case .appTerminated: .sessionTerminated
        case .undecodableResponse: .requestFailed
        }
    }
}
