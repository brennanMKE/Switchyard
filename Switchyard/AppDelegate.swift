// AppDelegate.swift

import AppKit

/// AppKit delegate for the app.
///
/// SwiftUI's `App` protocol has no launch-time hook that fires exactly once
/// before any window is shown, which is what XPC registration needs.
/// `NSApplicationDelegateAdaptor` in `SwitchyardApp` wires this in.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = AppXPCServer()
    let agentRegistrar = AgentRegistrar()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the launch agent before handing the endpoint to the
        // broker — launchd cannot own the Mach service name until the agent
        // is registered.
        agentRegistrar.registerIfNeeded()

        server.repairHandler = { [weak self] in
            self?.agentRegistrar.repair()
        }

        server.start()
        server.registerWithBroker()
    }
}
