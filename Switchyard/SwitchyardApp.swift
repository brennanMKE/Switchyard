// SwitchyardApp.swift

import SwiftUI
import YardUI

@main
struct SwitchyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(for: WindowID.self) { _ in
            ContentView()
        } defaultValue: {
            // Return the WindowID already seeded in WindowStore.shared, so
            // SwiftUI's first content window reuses the existing runtime
            // rather than creating a phantom second one. A phantom second
            // window makes CLI/XPC-delivered work land in an invisible
            // window while the visible one shows an empty model (#0078;
            // Batty hit this as its #0251).
            WindowStore.shared.initialWindowID
        }
        // Suppress SwiftUI's default behaviour of opening a new window for
        // OS-delivered URL events (switchyard://). Without this, a URL open
        // both reaches the app's own handler (correct) AND is matched by
        // this scene, which spawns an extra empty window. An empty set means
        // the scene volunteers for no external events, so no window opens
        // for them. Cmd-N and `openWindow(value:)` are internal SwiftUI
        // actions and are unaffected -- only OS URL opens are suppressed
        // (#0078; Batty #0251's second root cause).
        .handlesExternalEvents(matching: Set())
    }
}
