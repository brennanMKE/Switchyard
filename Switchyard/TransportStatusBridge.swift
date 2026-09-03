// TransportStatusBridge.swift
//
// #0216, app-target adapter: feeds YardUI's value-driven
// `TransportStatusModel` from the real `AgentRegistrar`. This is the only
// place `SMAppService` meets the transport pane — the model and the pane
// live in YardUI and never import ServiceManagement, so package tests can
// construct every pane state without the system being asked about a real
// agent, and registering stays app-target work the UI cannot do.

import ServiceManagement
import YardKit
import YardUI

/// Maps the real `SMAppService.Status` onto YardUI's own vocabulary. Lives
/// in the app target because that is the only place the real type exists.
extension SMAppService.Status {
    var transportStatus: AgentStatus {
        switch self {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}

/// Owns the pane's model for the app and writes into it from app-target
/// state. One instance, owned by `AppDelegate` alongside the
/// `AgentRegistrar` it reads.
@MainActor
final class TransportStatusBridge {
    /// Handed to `ContentView` by `SwitchyardApp`.
    let model = TransportStatusModel()

    private let registrar: AgentRegistrar

    init(registrar: AgentRegistrar) {
        self.registrar = registrar
        // The approval button's action. The model carries the closure; the
        // app target supplies the one that actually touches SMAppService.
        model.openLoginItems = { [registrar] in
            registrar.openLoginItemsSettings()
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
        model.agentStatus = registrar.status.transportStatus
    }
}
