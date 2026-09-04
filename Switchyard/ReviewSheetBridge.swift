// ReviewSheetBridge.swift
//
// #0055 round 2, app-target adapter — the TransportStatusBridge pattern: the
// review sheet's model layer lives in YardUI; this is the only place the
// app's real `PendingReviewStore` and engine-resolved requests meet it.
// `AppXPCServer` owns both the store and this bridge so every CLI connection
// feeds the same sheets; `SwitchyardApp` hands the bridge's centre to
// `ContentView`.

import Foundation
import YardCommands
import YardGit
import YardKit
import YardUI

@MainActor
final class ReviewSheetBridge {
    /// Handed to `ContentView`; the sheets this bridge fills.
    let center: ReviewCenter

    private let store: PendingReviewStore

    init(store: PendingReviewStore) {
        self.store = store
        self.center = ReviewCenter(store: store)
    }

    /// Called when `runReviewRequest` has resolved the request's repository
    /// and computed its diff — before the store's registration event lands.
    /// Routes the review to the repository's tab (#0084 focus-or-open) and
    /// attaches the diff so the sheet renders real content.
    ///
    /// The app service hops to the main actor before calling this: the
    /// serving body delivers off the XPC queues.
    func pendingDidRegister(
        request: ReviewRequest,
        context: WorktreeContext,
        files: [FileDiff],
        errorMessage: String?
    ) {
        center.routeToTab(for: context)
        center.attachDiff(
            commonDir: request.commonDir,
            originPath: context.topLevel ?? context.commonDir,
            files: files,
            errorMessage: errorMessage)
    }
}
