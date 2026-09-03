// SwitchyardApp.swift

import SwiftUI
import YardUI

@main
struct SwitchyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // #0083, declarations only: both stores restore the persisted
        // layout from the state directory before the first scene is built,
        // so `initialWindowID` (the defaultValue below) names a restored
        // window rather than the fresh-launch placeholder. All of the
        // behaviour lives in YardUI -- `WindowStore.restore(from:tabs:)`
        // and `RepositoryTabs.restoreTab` -- and a missing or corrupt file
        // degrades to the single-window launch, never a crash. A real
        // relaunch is not testable here; the launch smoke test is #0125's.
        WindowStore.shared.restore(from: WindowStore.stateFileURL, tabs: RepositoryTabs.shared)
    }

    var body: some Scene {
        WindowGroup(for: WindowID.self) { _ in
            // #0216: the transport pane's model lives on the app delegate,
            // which owns both `AgentRegistrar` and `AppXPCServer` — the two
            // app-target objects that know the real status.
            ContentView(transportStatus: appDelegate.transportBridge.model)
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
        // #0084: File ▸ Open… and Open Recent, both funnelled through
        // `RepositoryOpener`. Pure menu declarations; the focus-or-open
        // behaviour lives in YardUI.
        .commands {
            SwitchyardCommands()
        }
    }
}
