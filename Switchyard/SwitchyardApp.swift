// SwitchyardApp.swift

import SwiftUI
import YardGit
import YardUI

@main
struct SwitchyardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// #0395: the repository path a `-uiTestRepository <path>` launch
    /// argument names, or nil for an ordinary launch. UI tests run in a
    /// disposable VM pass this so the app starts with a repository already
    /// open through the one funnel every entry point uses
    /// (`RepositoryOpener.open(path:)`), no `NSOpenPanel`. Static so the
    /// launch hook below and the window content both read the same parsed
    /// value exactly once.
    static let uiTestRepositoryPath: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiTestRepository"),
              arguments.index(after: index) < arguments.count
        else { return nil }
        return arguments[arguments.index(after: index)]
    }()

    /// #0395 round 2: present when the launch arguments also carry
    /// `-uiTestRealSurfaces`. The UI-test window then renders the REAL
    /// `ContentView` — sidebar, history, the menus the spike questions are
    /// about — fed the fixture repository through the `initialRepositoryPath`
    /// seam, instead of the smoke test's minimal branch view. Round 1's smoke
    /// test passes only `-uiTestRepository` and still gets the minimal view;
    /// an ordinary launch sets neither argument and is unchanged.
    static let uiTestRealSurfaces: Bool = ProcessInfo.processInfo.arguments
        .contains("-uiTestRealSurfaces")

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
        // #0395: the UI-test launch hook. `open(path:)` is the
        // non-interactive gate — it resolves the fixture through the same
        // focus-or-open rule as every other entry point and opens no panel;
        // a refusal presents the shared alert, and the smoke test fails on
        // the missing branch header either way.
        if let path = Self.uiTestRepositoryPath {
            RepositoryOpener.open(path: path)
        }
    }

    var body: some Scene {
        WindowGroup(for: WindowID.self) { _ in
            // #0395: a UI-test launch renders a minimal repository view
            // that loads the fixture through the public engine loader and
            // shows its branch — the value the production repository header
            // (`RepositoryHeaderView`, fed by the same summary) renders.
            // The regular content view keeps showing whatever the user
            // opened in the app itself; its displayed-repository state is
            // internal to YardUI, which a UI-test round does not edit. The
            // view below exists only under `-uiTestRepository`, so an
            // ordinary launch is unchanged.
            if let path = Self.uiTestRepositoryPath {
                // #0395 round 2: with `-uiTestRealSurfaces` the window shows
                // the real panes loaded from the fixture — the surfaces the
                // four spike re-derivations drive. Without the flag the
                // round-1 smoke view renders, unchanged.
                if Self.uiTestRealSurfaces {
                    ContentView(initialRepositoryPath: path)
                } else {
                    UITestRepositoryView(path: path)
                }
            } else {
            // #0216: the transport pane's model lives on the app delegate,
            // which owns both `AgentRegistrar` and `AppXPCServer` — the two
            // app-target objects that know the real status. #0055: the
            // review sheets come from the same server's bridge. #0056: the
            // ask sheets come from its ask bridge. #0057: the resolve panes
            // come from its resolve bridge.
            ContentView(
                transportStatus: appDelegate.transportBridge.model,
                reviews: appDelegate.server.reviewBridge.center,
                asks: appDelegate.server.askBridge.center,
                resolves: appDelegate.server.resolveBridge.center)
            }
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
        // behaviour lives in YardUI. #0359 adds the Commit menu — the same
        // `CommitActionMenuItems` the History row's context menu renders,
        // acting on the focused window's selected commit, which is what
        // makes the menu's key equivalents real (#0382's spike covers the
        // context menu's own equivalents).
        .commands {
            SwitchyardCommands()
            CommitCommands()
            // #0393: Edit ▸ Undo/Redo over the focused window's journal,
            // replacing the system .undoRedo group.
            JournalCommands()
        }

        // #0352: the Settings scene (Cmd-,). The CLI install section and the
        // broker section both funnel into the existing machinery —
        // `CLIInstallActions` (#0222) and the transport bridge's model, the
        // SAME `TransportStatusModel` instance the transport pane binds, so
        // there is one source of truth and no duplicated state. The
        // refresh closure re-reads the registrar when the window appears:
        // the user may have just approved the login item, and there is no
        // notification for that.
        Settings {
            SettingsView(
                transport: appDelegate.transportBridge.model,
                refreshOnAppear: { appDelegate.transportBridge.refresh() })
        }
    }
}

/// #0395: the window content a `-uiTestRepository` launch shows. Minimal by
/// design — it loads the fixture's summary through the public engine loader
/// (the same `loadRepositorySummary` the production repository header's
/// summary comes from) and renders the branch that header shows, so the
/// smoke test asserts a value the engine produced from the real fixture.
/// An ordinary launch never constructs this view.
private struct UITestRepositoryView: View {
    let path: String

    /// The branch the fixture's `WhereAmI` reports, or nil while loading.
    @State private var branch: String?
    /// Set when the summary load throws — shown instead of a branch.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure {
                Text("Couldn't open \(path)")
                    .font(.headline)
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let branch {
                Text(branch)
                    .font(.title2.monospaced())
            } else {
                ProgressView()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: path) {
            do {
                let summary = try await loadRepositorySummary(at: path)
                branch = summary.whereAmI.branch ?? "detached HEAD"
            } catch {
                failure = String(describing: error)
            }
        }
    }
}
