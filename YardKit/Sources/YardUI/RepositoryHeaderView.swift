// RepositoryHeaderView.swift

import SwiftUI
import YardGit

/// The `whereAmI` summary shown at the top of the window: the one-line
/// tracking status (`TrackingSummary.text(for:)`) with the short OID beside
/// it, any in-progress git operation, and the four working-tree counts —
/// stash, untracked, unstaged, staged — in the order `WhereAmI` declares
/// them. The in-progress line is the same sentence #0359's menu uses to
/// disable a rewrite, so the header explains a disabled menu item.
///
/// #0394: beside #0369's warning line, the way forward. Resolve Conflicts…
/// appears while the index holds unmerged entries and opens the app-side
/// resolve pane; Continue appears only for the operation git completes
/// itself (`ConflictHandoff.continuableKind` — never the `Rewrite` family's
/// detached replay); Abort appears for any in-flight operation, behind a
/// confirmation dialog — the `pendingDelete` rule: no
/// `.keyboardShortcut(.defaultAction)` on the destructive button, which
/// must never sit one accidental Return away from undoing an operation.
/// The gates read `WhereAmI` fields only — what #0369 shipped — so there is
/// no new flag and no wire change. The closures default to nil, so previews
/// and any caller with nothing to hand over keep the warning without
/// actions that do anything.
struct RepositoryHeaderView: View {
    let whereAmI: WhereAmI

    /// Opens the app-side resolve pane for this repository's conflicts.
    /// Rendered iff `whereAmI.hasConflicts`.
    var onResolveConflicts: (() -> Void)?

    /// Continues the in-flight operation git can complete itself. Rendered
    /// iff `ConflictHandoff.continuableKind(for:)` names one.
    var onContinue: (() -> Void)?

    /// Aborts the in-flight operation — one journal undo plus the
    /// operation's own `--abort`. Rendered iff
    /// `ConflictHandoff.inProgressKind(for:)` names one.
    var onAbort: (() -> Void)?

    /// The pending Abort confirmation. The dialog is the destructive
    /// action's only path to the engine; Cancel and the dismissed return
    /// both leave it unrun.
    @State private var confirmingAbort = false

    /// The operation the header is acting on — the same precedence
    /// `TrackingSummary.operationInProgress` reads, so the warning line and
    /// the buttons name the same operation.
    private var operation: ConflictHandoff.Kind? {
        ConflictHandoff.inProgressKind(for: whereAmI)
    }

    /// The lowercase operation name, in the dialog's title and message.
    private var operationName: String? {
        operation.map { ConflictHandoff.name(of: $0) }
    }

    /// The capitalized operation name, on the dialog's destructive button.
    private var operationCapitalized: String? {
        operationName.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(TrackingSummary.text(for: whereAmI))
                    .font(.headline)
                Text(whereAmI.headOID)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let message = TrackingSummary.operationInProgress(for: whereAmI) {
                HStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    actions
                }
            }
            HStack(spacing: 16) {
                countLabel("Stash", whereAmI.stashCount)
                countLabel("Untracked", whereAmI.untrackedCount)
                countLabel("Unstaged", whereAmI.unstagedCount)
                countLabel("Staged", whereAmI.stagedCount)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Abort \(operationName ?? "operation")?",
            isPresented: $confirmingAbort,
            titleVisibility: .visible
        ) {
            Button("Abort \(operationCapitalized ?? "Operation")", role: .destructive) {
                confirmingAbort = false
                onAbort?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The repository returns to where it was before \(operationName ?? "it started")."
            )
        }
    }

    /// The gated actions beside #0369's warning line. Resolve only while
    /// the index holds unmerged entries; Continue only where git finishes
    /// the operation itself; Abort for any in-flight operation.
    private var actions: some View {
        HStack(spacing: 10) {
            if whereAmI.hasConflicts {
                Button("Resolve Conflicts…") { onResolveConflicts?() }
            }
            if let continuable = ConflictHandoff.continuableKind(for: whereAmI) {
                Button("Continue (\(ConflictHandoff.name(of: continuable)))") {
                    onContinue?()
                }
            }
            if operation != nil {
                Button("Abort") { confirmingAbort = true }
            }
        }
        .controlSize(.small)
    }

    private func countLabel(_ name: String, _ count: Int) -> some View {
        Text("\(name): \(count)")
    }
}

#Preview {
    RepositoryHeaderView(whereAmI: WhereAmI(
        branch: "main",
        upstream: "origin/main",
        ahead: 1,
        behind: 0,
        isMidRebase: false,
        isMidMerge: false,
        isMidCherryPick: false,
        isMidRevert: false,
        stashCount: 0,
        untrackedCount: 2,
        unstagedCount: 1,
        stagedCount: 0,
        hasConflicts: false,
        conflictCount: 0,
        headOID: "a1b2c3d",
        rawHead: "a1b2c3d0000000000000000000000000000000"
    ))
    .padding()
}
