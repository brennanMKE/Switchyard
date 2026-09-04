// AskSheetBridge.swift
//
// #0056, app-target adapter — the ReviewSheetBridge pattern: the ask
// sheet's model layer lives in YardUI; this is the only place the app's
// real `PendingAskStore` and engine-resolved requests meet it.
// `AppXPCServer` owns both the store and this bridge so every CLI
// connection feeds the same sheets; `SwitchyardApp` hands the bridge's
// centre to `ContentView`.

import Foundation
import YardCommands
import YardGit
import YardKit
import YardUI

@MainActor
final class AskSheetBridge {
    /// Handed to `ContentView`; the sheets this bridge fills.
    let center: AskCenter

    private let store: PendingAskStore

    init(store: PendingAskStore) {
        self.store = store
        self.center = AskCenter(store: store)
    }

    /// Called when `runAskRequest` has resolved the request's repository —
    /// before the store's registration event lands. Routes the ask to the
    /// repository's tab (#0084 focus-or-open) and attaches the resolved
    /// origin so the sheet presents on the tab the repository is shown in.
    ///
    /// The app service hops to the main actor before calling this: the
    /// serving body delivers off the XPC queues.
    func pendingDidRegister(request: AskRequest, context: WorktreeContext) {
        center.routeToTab(for: context)
        center.attachOrigin(
            commonDir: request.commonDir,
            originPath: context.topLevel ?? context.commonDir)
    }
}
