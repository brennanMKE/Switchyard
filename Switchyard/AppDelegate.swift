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

    func applicationDidFinishLaunching(_ notification: Notification) {
        server.start()
        server.registerWithBroker()
    }
}
