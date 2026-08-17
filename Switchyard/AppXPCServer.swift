// AppXPCServer.swift
//
// Ported from ../../RemoteControl/RemoteControl/AppXPCServer.swift (MIT,
// same author — see CLAUDE.md and issue #0047's planning update). Copyright
// the original author; substantial portions retained here under the same
// MIT terms as this project.
//
// Scoped to the anonymous listener and broker registration only. Serving
// accepted connections, long-lived sessions, heartbeats, teardown, and
// orphan reaping are #0213 — this file does not implement any of them.

import Foundation
import YardKit
import os

/// The app's side of the direct CLI connection.
///
/// The app publishes an *anonymous* listener — it cannot publish a named
/// one, which is the entire reason the broker agent exists — and hands the
/// resulting endpoint to the broker. A CLI then asks the broker for that
/// endpoint and connects straight to the app. Nothing after the handoff
/// travels through the broker.
@MainActor
final class AppXPCServer {
    private static let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "xpc")

    /// Anonymous listener. A named `NSXPCListener(machServiceName:)` would
    /// fail here: only launchd can own a service name.
    private let listener = NSXPCListener.anonymous()

    /// Must be held strongly — `NSXPCListener.delegate` is weak, and a
    /// delegate that is only locally owned is deallocated and connections
    /// are silently refused.
    private var listenerDelegate: ListenerDelegate?

    /// The app's connection to the broker, kept open for the process
    /// lifetime so the broker can detect the app going away and drop the
    /// stale endpoint.
    private var brokerConnection: NSXPCConnection?

    /// Claimed the first time the broker connection's error handler observes
    /// an actual failure, so repair runs at most once per launch.
    ///
    /// `nonisolated` and backed by a lock (see `RepairGate`), not an actor:
    /// the error handler closure below is `@Sendable` and fires on XPC's own
    /// queue, not the main actor, so the claim must be checkable synchronously
    /// from there without a hop.
    nonisolated private let repairGate = RepairGate()

    /// Runs the agent repair (unregister + re-register with `SMAppService`).
    /// Set by whoever owns the `AgentRegistrar` — `AppXPCServer` has no
    /// dependency on `ServiceManagement` itself, so it stays testable without
    /// one. Called at most once per launch, driven by `repairGate`.
    var repairHandler: (() -> Void)?

    init() {}

    // MARK: - Lifecycle

    /// Resumes the anonymous listener.
    ///
    /// Accepting a connection is declined for now — exporting a real service
    /// interface to accepted CLIs is #0213. The listener still needs to be
    /// live so its `endpoint` is a real, resumed one by the time it is
    /// handed to the broker.
    func start() {
        let delegate = ListenerDelegate()
        listenerDelegate = delegate
        listener.delegate = delegate
        listener.resume()
        Self.logger.info("anonymous listener resumed")
    }

    // MARK: - Broker registration

    /// Hands the anonymous listener's endpoint to the broker.
    ///
    /// Called at launch and again whenever the broker connection is
    /// interrupted. The broker can be killed and restarted independently of
    /// the app, and an endpoint registered with a dead broker is worth
    /// nothing, so re-registering is not optional.
    func registerWithBroker() {
        // Reuse the existing connection if there is one: after an
        // *interruption* the connection object is still usable, and
        // recreating it needlessly loses the invalidation handler wiring.
        let connection = brokerConnection ?? makeBrokerConnection()

        // `@Sendable` is load-bearing, not decoration. Foundation types this
        // parameter as a plain `(any Error) -> Void`, so a closure written
        // inside this @MainActor method inherits main-actor isolation and
        // Swift emits an isolation assertion at its entry. XPC then calls it
        // on its own queue and the process dies with SIGTRAP in
        // _swift_task_checkIsolatedSwift. Marking the closure @Sendable
        // makes it nonisolated, which is what it must be.
        let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                Self.logger.error("broker connection error: \(message, privacy: .public)")
            }

            // This is where a *failed call* is actually observed — repair is
            // driven from here, at most once per launch, never from
            // `service.status`. The claim itself must happen synchronously,
            // on whatever queue XPC calls this on, so two overlapping
            // failures cannot both win it.
            guard let self, self.repairGate.claim() else { return }
            Task { @MainActor [weak self] in
                Self.logger.notice("broker call failed — repairing agent registration")
                self?.repairHandler?()
                self?.registerWithBroker()
            }
        }

        guard let broker = proxy as? BrokerProtocol else {
            Self.logger.error("broker proxy does not conform to BrokerProtocol")
            return
        }

        // registerAppEndpoint is a one-way call: no reply block, so it
        // returns immediately whether or not the broker received it, and
        // failures only surface asynchronously through the error handler
        // above. Do not treat a successful return here as proof that
        // registration happened.
        broker.registerAppEndpoint(listener.endpoint)
        Self.logger.info("endpoint handed to broker")
    }

    private func makeBrokerConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: ServiceNames.machServiceName)
        // Set before resume(), or calls silently do nothing.
        connection.remoteObjectInterface = XPCInterfaces.broker

        // Interruption: the broker died but this connection object can be
        // reused. Re-register, because the restarted broker has an empty
        // registry.
        //
        // @Sendable for the same reason as the error handler above — these
        // are plain `() -> Void` in Foundation, and without it they inherit
        // main-actor isolation and trap when XPC calls them off the main
        // queue.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                Self.logger.notice("broker connection interrupted, re-registering")
                self?.registerWithBroker()
            }
        }

        // Invalidation: permanently dead. The connection object cannot be
        // reused, so drop it; the next registerWithBroker() builds a fresh
        // one.
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                Self.logger.notice("broker connection invalidated")
                self?.brokerConnection = nil
            }
        }

        connection.resume()
        brokerConnection = connection
        return connection
    }
}

// MARK: - Listener delegate

/// `nonisolated` because XPC invokes this on its own queues, and the app
/// target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
private nonisolated final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Exporting a real service interface to accepted CLIs, and the
        // session machinery behind it, is #0213. Decline for now rather than
        // accept a connection nothing will ever serve.
        false
    }
}
