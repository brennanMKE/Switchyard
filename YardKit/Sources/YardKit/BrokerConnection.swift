// BrokerConnection.swift
//
// Ported from ../../RemoteControl/BridgeKit/Sources/remotectl/BrokerConnection.swift
// (MIT, same author — see CLAUDE.md and issue #0048's planning update).
// Copyright the original author; substantial portions retained here under
// the same MIT terms as this project.

import Foundation

/// Errors reachable from the CLI's connection to the broker.
///
/// Declares its own ``ExitCode`` mapping so a caller never has to guess which
/// code a given failure maps to — see issue #0048's exit-code table.
public enum CLIError: Error, CustomStringConvertible, Sendable {
    case brokerUnreachable(any Error)
    case protocolMismatch(String)
    case timedOut(Duration)

    public var description: String {
        switch self {
        case .brokerUnreachable(let underlying):
            "cannot reach the broker: \(underlying.localizedDescription)"
        case .protocolMismatch(let detail):
            "XPC proxy did not conform to \(detail) — interfaces are out of sync"
        case .timedOut(let duration):
            "timed out after \(duration.seconds)s"
        }
    }

    /// The `ExitCode` this failure maps to. Switched exhaustively — no
    /// `default` — so a new case is a compile error rather than a silently
    /// wrong code.
    public var exitCode: ExitCode {
        switch self {
        case .brokerUnreachable: .brokerUnreachable
        case .timedOut: .brokerUnreachable
        case .protocolMismatch: .requestFailed
        }
    }
}

/// The CLI's connection to the broker launch agent.
///
/// `@unchecked Sendable` because it wraps an `NSXPCConnection`, which is not
/// `Sendable` but is safe to use from multiple queues — which is exactly what
/// XPC does when it invokes reply blocks and error handlers on its own queues.
public final class BrokerConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    /// - Parameter machServiceName: overridable so a test can point this at a
    ///   name that cannot exist and exercise the real `call` failure path —
    ///   see `AppConnectionTests.brokerUnreachableMapsToExitCodeTwo`. Real
    ///   callers never pass this.
    /// The deadline every call on this connection uses when the caller does
    /// not name one. Five seconds is right for a CLI, which is one process
    /// making one call; the package's own tests raise it, because 70 suites of
    /// blocking `git` subprocesses can starve the cooperative pool for tens of
    /// seconds and a reply that arrives late is not a reply that failed.
    let defaultTimeout: Duration

    public init(machServiceName: String = ServiceNames.machServiceName,
                defaultTimeout: Duration = .seconds(5)) {
        self.defaultTimeout = defaultTimeout
        connection = NSXPCConnection(machServiceName: machServiceName)
        // Before resume(), or calls silently do nothing.
        connection.remoteObjectInterface = XPCInterfaces.broker
        connection.resume()
    }

    /// Wraps an already-configured, already-resumed connection — the seam a
    /// test uses to hand `AppConnection.connect(broker:...)` an in-process
    /// fake broker (`NSXPCListener.anonymous()`) instead of the real
    /// `machServiceName` broker, so `launchIfNeeded`/`requireApp` are
    /// testable without launchd or the app.
    init(connection: NSXPCConnection, defaultTimeout: Duration = .seconds(5)) {
        self.defaultTimeout = defaultTimeout
        self.connection = connection
    }

    public func close() {
        connection.invalidate()
    }

    public func ping(timeout: Duration? = nil) async throws -> String {
        let timeout = timeout ?? defaultTimeout
        return try await call(timeout: timeout) { broker, complete in
            broker.brokerPing { complete(.success($0)) }
        }
    }

    /// Fetches the app's listener endpoint, or `nil` if no app has registered.
    public func appEndpoint(timeout: Duration? = nil) async throws -> NSXPCListenerEndpoint? {
        let timeout = timeout ?? defaultTimeout
        return try await call(timeout: timeout) { broker, complete in
            broker.appEndpoint { complete(.success(Transferred($0))) }
        }.value
    }

    // MARK: - Reply-block bridging

    /// Bridges a one-shot XPC reply block into async/await, with a timeout.
    ///
    /// Reply blocks arrive on an XPC queue and the error handler may fire
    /// instead of the reply, or neither may fire at all — so resumption is
    /// funnelled through ``ResumeOnce`` and raced against a sleeping task.
    private func call<T: Sendable>(
        timeout: Duration,
        _ invoke: @escaping @Sendable (any BrokerProtocol, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let once = ResumeOnce<T>()

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    once.attach(continuation)

                    let proxy = self.connection.remoteObjectProxyWithErrorHandler { error in
                        once.finish(.failure(CLIError.brokerUnreachable(error)))
                    }
                    guard let broker = proxy as? any BrokerProtocol else {
                        once.finish(.failure(CLIError.protocolMismatch("BrokerProtocol")))
                        return
                    }
                    invoke(broker) { once.finish($0) }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                // Invalidating makes the in-flight call's error handler fire,
                // which resumes the continuation above. Without this the losing
                // task would abandon a checked continuation and the runtime
                // would report a continuation leak.
                self.connection.invalidate()
                throw CLIError.timedOut(timeout)
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

/// Guarantees a continuation is resumed exactly once, from whichever of the
/// reply block, the error handler, or the timeout gets there first.
///
/// Shared by ``BrokerConnection`` and ``AppConnection``.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var finished = false

    func attach(_ continuation: CheckedContinuation<T, any Error>) {
        let ready: Result<T, any Error>? = lock.withLock {
            // The reply can beat `attach` if XPC is very fast, so a result that
            // arrived early is stashed and delivered here.
            if let pending {
                finished = true
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let ready {
            continuation.resume(with: ready)
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let target: CheckedContinuation<T, any Error>? = lock.withLock {
            guard !finished else { return nil }
            guard let continuation else {
                pending = result
                return nil
            }
            finished = true
            self.continuation = nil
            return continuation
        }
        target?.resume(with: result)
    }
}

/// Carries a non-`Sendable` value out of an XPC reply block.
///
/// `NSXPCListenerEndpoint` is not `Sendable`, but it has to cross from the XPC
/// reply queue to the awaiting task. Confining the unchecked-ness to one named
/// type keeps it auditable.
struct Transferred<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
