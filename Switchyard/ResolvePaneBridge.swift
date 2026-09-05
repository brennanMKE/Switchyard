// ResolvePaneBridge.swift
//
// #0057 round 2, app-target adapter — the ReviewSheetBridge pattern: the
// resolve pane's model layer lives in YardUI; this is the only place the
// app's real `PendingResolveStore` and engine-resolved requests meet it.
// `AppXPCServer` owns both the store and this bridge so every CLI connection
// feeds the same panes; `SwitchyardApp` hands the bridge's centre to
// `ContentView`.

import Foundation
import YardCommands
import YardGit
import YardKit
import YardUI

@MainActor
final class ResolvePaneBridge {
    /// Handed to `ContentView`; the panes this bridge fills.
    let center: ResolveCenter

    private let store: PendingResolveStore

    init(store: PendingResolveStore) {
        self.store = store
        self.center = ResolveCenter(store: store)
        // One card's engine apply: the wire choice maps to the engine's
        // resolution vocabulary in YardCommands (the only module that sees
        // both), and the apply runs through `ResolveApply.apply` — one
        // checkpointed action per path, never a second apply implementation.
        center.applyResolution = { originPath, resolution in
            try ResolveApplyMapping.apply(resolution, at: originPath)
        }
    }

    /// Called when `runResolveRequest` has resolved the request's repository
    /// and enumerated its conflicts — before the store's registration event
    /// lands. Routes the resolve to the repository's tab (#0084
    /// focus-or-open) and attaches the per-path details so the pane renders
    /// real stage content.
    ///
    /// The app service hops to the main actor before calling this: the
    /// serving body delivers off the XPC queues.
    func pendingDidRegister(
        request: ResolveRequest,
        context: WorktreeContext,
        details: [ResolveConflictDetail],
        errorMessage: String?
    ) {
        center.routeToTab(for: context)
        center.attachDetails(
            commonDir: request.commonDir,
            originPath: context.topLevel ?? context.commonDir,
            details: details.map { detail in
                ResolveCardData(
                    path: detail.file.path,
                    kind: ConflictKind(detail.file.kind),
                    baseText: detail.baseText,
                    oursText: detail.oursText,
                    theirsText: detail.theirsText,
                    workingText: detail.workingText)
            },
            errorMessage: errorMessage)
    }
}

/// The porcelain kind's transfer into the wire vocabulary — the two enums
/// share raw values by construction, and this exhaustive switch keeps the
/// transfer total: a new case on either side is a compile error here, not a
/// silent misreport on the wire.
private extension ConflictKind {
    init(_ kind: ConflictedFile.Kind) {
        switch kind {
        case .bothModified: self = .bothModified
        case .bothAdded: self = .bothAdded
        case .bothDeleted: self = .bothDeleted
        case .addedByUs: self = .addedByUs
        case .addedByThem: self = .addedByThem
        case .deletedByUs: self = .deletedByUs
        case .deletedByThem: self = .deletedByThem
        }
    }
}
