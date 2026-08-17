// XPCProtocols.swift
//
// Ported from ../../RemoteControl/BridgeKit/Sources/BridgeKit/XPCProtocols.swift
// and ../../RemoteControl/BrokerAgent/main.swift (MIT, same author — see
// CLAUDE.md and issue #0046's planning update). Copyright the original
// author; substantial portions retained here under the same MIT terms as
// this project.

import Foundation

// MARK: - Broker

/// What the broker launch agent exposes on its mach service.
///
/// The agent is a bootstrap broker and nothing more: it holds the app's
/// anonymous listener endpoint so a CLI can find it. Once the CLI has the
/// endpoint, traffic goes directly to the app and the agent is out of the
/// path.
@objc public protocol BrokerProtocol {
    /// Liveness check that does not depend on the app running at all.
    ///
    /// This is the acceptance probe for #0048: it should succeed when
    /// launchd starts the agent on demand, with the app never having been
    /// launched.
    func brokerPing(reply: @escaping @Sendable (String) -> Void)

    /// Called by the app after it creates its anonymous listener.
    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint)

    /// Called by the CLI. Replies `nil` when no app has registered.
    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void)
}

/// What the app exposes to a CLI over the direct connection.
///
/// Scoped to a liveness check only. The app's listener declines every
/// connection until #0215 exports a real service interface, so nothing here
/// is reachable end to end yet — this issue tests it against an in-process
/// listener instead. `perform`/`startSession` shapes belong with the command
/// wiring (#0115, #0124) and the session work (#0213).
@objc public protocol AppServiceProtocol {
    /// Liveness check on the app itself, distinct from `brokerPing`: this one
    /// only answers when the direct connection is live.
    func appPing(reply: @escaping @Sendable (String) -> Void)
}

/// `NSXPCInterface` values for ``BrokerProtocol`` and ``AppServiceProtocol``.
///
/// Both sides of a connection must configure `remoteObjectInterface` and
/// `exportedInterface` with matching interfaces *before* calling `resume()`.
/// Get it wrong and calls fail silently — no error, no reply, no crash. This
/// factory is the cheapest available defense against that.
public enum XPCInterfaces {
    public static var broker: NSXPCInterface {
        NSXPCInterface(with: BrokerProtocol.self)
    }

    public static var appService: NSXPCInterface {
        NSXPCInterface(with: AppServiceProtocol.self)
    }
}

// MARK: - Endpoint registry

/// Holds the most recently registered value, tracking which owner registered
/// it so only that owner can clear it.
///
/// Generic over both the stored value and the owner token so the type has no
/// dependency on XPC and is testable without a live connection. The broker
/// instantiates this as `EndpointRegistry<NSXPCListenerEndpoint>`, minting an
/// ``Owner`` per connection.
///
/// Guarded by a lock, not an actor: XPC invokes each connection's methods on
/// its own queue, so this is reachable from several queues concurrently, and
/// the `@objc` protocol methods it backs are synchronous — an actor would
/// force every accessor to be `async`, which `@objc` will not express.
public final class EndpointRegistry<Value: Sendable>: @unchecked Sendable {

    /// Identifies the party that registered a value, so a later `clear(owner:)`
    /// from a different party is rejected rather than silently discarding a
    /// live registration.
    public struct Owner: Hashable, Sendable {
        private let id = UUID()

        public init() {}
    }

    private let lock = NSLock()
    private var value: Value?
    private var owner: Owner?

    public init() {}

    /// The currently registered value, or `nil` if nothing has registered.
    public var current: Value? {
        lock.withLock { value }
    }

    /// Stores `newValue` and records `owner` as the party that registered it.
    /// A later `store` from a different owner replaces both the value and the
    /// owner — the registry only ever holds one registration.
    public func store(_ newValue: Value, owner: Owner) {
        lock.withLock {
            value = newValue
            self.owner = owner
        }
    }

    /// Clears the registration if `owner` is the party that registered it.
    ///
    /// Returns whether the clear happened. A CLI connection invalidating must
    /// not be able to discard a live app registration, so a clear from any
    /// owner other than the registering one is rejected rather than applied.
    @discardableResult
    public func clear(owner: Owner) -> Bool {
        lock.withLock {
            guard self.owner == owner else { return false }
            value = nil
            self.owner = nil
            return true
        }
    }
}
