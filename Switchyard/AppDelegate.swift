// AppDelegate.swift

import AppKit
import YardUI

/// AppKit delegate for the app.
///
/// SwiftUI's `App` protocol has no launch-time hook that fires exactly once
/// before any window is shown, which is what XPC registration needs.
/// `NSApplicationDelegateAdaptor` in `SwitchyardApp` wires this in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = AppXPCServer()
    let agentRegistrar = AgentRegistrar()

    /// #0216: feeds the transport pane's model from `agentRegistrar` (and,
    /// once a source exists, from `server`'s connection accounting).
    let transportBridge: TransportStatusBridge

    override init() {
        transportBridge = TransportStatusBridge(registrar: agentRegistrar)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the launch agent before handing the endpoint to the
        // broker — launchd cannot own the Mach service name until the agent
        // is registered.
        agentRegistrar.registerIfNeeded()
        // The registration above may have moved the status; the pane reads
        // what is in the model, so write it through.
        transportBridge.refresh()

        server.repairHandler = { [weak self] in
            self?.agentRegistrar.repair()
        }

        server.start()
        server.registerWithBroker()
    }

    // #0084: everything the OS delivers — document drops on the Dock icon
    // and `switchyard://` URL opens alike — funnels through the same
    // focus-or-open rule as the other entry points. This delegate method is
    // the app's ONLY URL handler: the scene volunteers for no external
    // events (#0078's `.handlesExternalEvents(matching: Set())`), so no
    // extra window can open for one, and there is no `.onOpenURL` anywhere
    // to volunteer one.
    func application(_ application: NSApplication, open urls: [URL]) {
        RepositoryOpener.openDelivered(urls: urls)
    }
}
