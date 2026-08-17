// main.swift
//
// Ported from ../../RemoteControl/BrokerAgent/main.swift (MIT, same author --
// see CLAUDE.md and issue #0046's planning update). Copyright the original
// author; substantial portions retained here under the same MIT terms as
// this project.

import Foundation
import OSLog
import YardKit

// Broker launch agent.
//
// This process exists for one reason: a plain double-clicked app cannot publish
// a named mach service. `NSXPCListener(machServiceName:)` only works when
// launchd owns the name, and launchd only learns a name from a launchd plist.
// So the name is declared in the launch agent plist named by
// `ServiceNames.agentPlistName` (under `Support/`), launchd reserves it, and
// starts this process on demand when anything connects. Every identifier
// involved lives in `ServiceNames.swift` -- nothing here spells one out.
//
// Having done that, the agent's whole job is to hold the app's anonymous
// listener endpoint so a CLI can find it. `NSXPCListenerEndpoint` is a live
// mach right -- it can be passed over an existing XPC connection and nowhere
// else, never written to disk -- which is why a broker has to exist rather
// than the app just leaving its endpoint somewhere for the CLI to read.
//
// After the handoff, CLI <-> app traffic goes direct. Nothing flows through
// here -- see the Expected behavior box in #0046: "Holds no traffic after
// the handoff."
//
// This issue (#0045) delivered the target itself -- built, embedded at
// Contents/MacOS/BrokerAgent, and registered with launchd via the embedded
// plist. The broker's behaviour below is #0046. `EndpointRegistry` is the
// testable half, in `YardKit/Sources/YardKit/XPCProtocols.swift`.

private let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "broker")

// MARK: - Exported object

private final class BrokerService: NSObject, BrokerProtocol {
    let registry: EndpointRegistry<NSXPCListenerEndpoint>

    /// This connection's registration token. Minted once per connection so
    /// only the connection that registered an endpoint can later clear it --
    /// `EndpointRegistry.clear(owner:)` rejects any other owner.
    private let owner = EndpointRegistry<NSXPCListenerEndpoint>.Owner()

    init(registry: EndpointRegistry<NSXPCListenerEndpoint>) {
        self.registry = registry
        super.init()
    }

    func brokerPing(reply: @escaping @Sendable (String) -> Void) {
        let hasEndpoint = registry.current != nil
        logger.info("brokerPing (endpoint registered: \(hasEndpoint, privacy: .public))")
        reply("broker pid \(ProcessInfo.processInfo.processIdentifier), app endpoint \(hasEndpoint ? "registered" : "absent")")
    }

    func registerAppEndpoint(_ endpoint: NSXPCListenerEndpoint) {
        registry.store(endpoint, owner: owner)
        logger.info("app endpoint registered")
    }

    func appEndpoint(reply: @escaping @Sendable (NSXPCListenerEndpoint?) -> Void) {
        let endpoint = registry.current
        logger.info("appEndpoint requested, returning \(endpoint == nil ? "nil" : "endpoint", privacy: .public)")
        reply(endpoint)
    }

    /// Called from the connection's invalidation handler. Clears the
    /// registry only if this connection is the one that registered --
    /// `registry.clear(owner:)` itself enforces that, so a CLI disconnecting
    /// can never discard a live app registration.
    func clearIfRegistered() {
        if registry.clear(owner: owner) {
            logger.info("registering peer went away, clearing endpoint")
        } else {
            logger.info("connection invalidated")
        }
    }
}

// MARK: - Listener delegate

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let registry: EndpointRegistry<NSXPCListenerEndpoint>

    init(registry: EndpointRegistry<NSXPCListenerEndpoint>) {
        self.registry = registry
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // The interface is configured before resume(). Setting it afterwards is
        // the documented way to get calls that silently do nothing.
        let service = BrokerService(registry: registry)
        connection.exportedInterface = XPCInterfaces.broker
        connection.exportedObject = service

        // When the app quits, the endpoint it registered becomes a dead mach
        // right. Drop it, or the next CLI is handed a corpse and fails in a far
        // more confusing way than "app not running".
        connection.invalidationHandler = { [service] in
            service.clearIfRegistered()
        }

        connection.resume()
        logger.info("accepted connection from pid \(connection.processIdentifier, privacy: .public)")
        return true
    }
}

// MARK: - Start

// `private` because the types above are private and top-level bindings in
// main.swift are internal by default.
private let registry = EndpointRegistry<NSXPCListenerEndpoint>()
private let delegate = ListenerDelegate(registry: registry)

let listener = NSXPCListener(machServiceName: ServiceNames.machServiceName)
listener.delegate = delegate
listener.resume()

logger.info(
    "listening on \(ServiceNames.machServiceName, privacy: .public) (pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public))"
)

// launchd started this process and decides when it ends. Park the main thread;
// XPC callbacks arrive on its own queues.
dispatchMain()
