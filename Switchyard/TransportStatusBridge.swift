// TransportStatusBridge.swift
//
// #0216, app-target adapter: feeds YardUI's value-driven
// `TransportStatusModel` from the real `AgentRegistrar`. This is the only
// place the registration state meets the transport pane — the model and
// the pane live in YardUI and never import ServiceManagement, so package
// tests can construct every pane state without the system being asked
// about a real agent, and registering stays app-target work the UI cannot
// do.
//
// #0354: the bridge now also carries the registrar's captured error text
// and owns the pane's Repair action, and the pane's reachability claim is
// written only from a real broker ping round-trip (see `pingBroker`) —
// never from the registration state, which is belief about launchd, not
// health of the broker.

import os
import YardKit
import YardUI

/// Maps the controller's four-state registration vocabulary onto YardUI's
/// own. Lives in the app target because that is where the state type
/// lives; `.unknown` has no better pane reading than `.notFound`.
extension BrokerAgentRegistrationState {
    var transportStatus: AgentStatus {
        switch self {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .unknown: .notFound
        }
    }
}

/// Owns the pane's model for the app and writes into it from app-target
/// state. One instance, owned by `AppDelegate` alongside the
/// `AgentRegistrar` it reads.
@MainActor
final class TransportStatusBridge {
    private static let logger = Logger(subsystem: ServiceNames.logSubsystem, category: "transport-bridge")

    /// Handed to `ContentView` by `SwitchyardApp`.
    let model = TransportStatusModel()

    private let registrar: AgentRegistrar

    /// The app-target ping source. Set once by `AppDelegate` to a closure
    /// that runs a real broker round-trip (`AppXPCServer.pingBroker`); the
    /// bridge writes the outcome into the model. Nothing else may write
    /// `model.brokerPingSucceeded`.
    var ping: (() -> Void)?

    init(registrar: AgentRegistrar) {
        self.registrar = registrar
        // The approval button's action. The model carries the closure; the
        // app target supplies the one that actually touches SMAppService.
        model.openLoginItems = { [registrar] in
            registrar.openLoginItemsSettings()
        }
        // The Repair button's action (#0354): re-register
        // (unregister-then-register), write the fresh state through, and
        // re-probe the broker so "Reachable" reflects the repaired world.
        model.repair = { [weak self] in
            guard let self else { return }
            self.registrar.repair()
            self.refresh()
            self.ping?()
        }
        refresh()
    }

    /// Writes the app's current transport facts into the model.
    ///
    /// Live wiring points for the two values with no exported source yet:
    /// - `model.endpointRegistered` — set `true` where
    ///   `AppXPCServer.registerWithBroker()` hands the endpoint to the
    ///   broker (`broker.registerAppEndpoint`), and `false` from that
    ///   connection's invalidation handler.
    /// - `model.clientCount` — written by the accepted-connection
    ///   accounting (#0213/#0215) as connections are accepted and torn
    ///   down.
    func refresh() {
        model.agentStatus = registrar.state.transportStatus
        model.lastErrorDescription = registrar.lastErrorDescription
    }

    /// Writes a completed ping round-trip into the model — the pane's ONLY
    /// source for any reachability claim. `detail` is the broker's ping
    /// reply on success or the connection error's text on failure; it is
    /// logged, never rendered as registration state.
    func setPingOutcome(reachable: Bool, detail: String?) {
        model.brokerPingSucceeded = reachable
        Self.logger.info("broker ping \(reachable ? "succeeded" : "failed", privacy: .public)\(detail.map { " — \($0)" } ?? "", privacy: .public)")
    }
}
