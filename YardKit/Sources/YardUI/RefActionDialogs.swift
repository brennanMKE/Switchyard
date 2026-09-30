// RefActionDialogs.swift
//
// #0510: the ref actions' two presentations (guide §11 decision 38), as a
// modifier so `ContentView.body` stays inside the type-checker's budget —
// the shape `StashDropDialog` took.
//
// - Delete Branch… / Delete Tag…, and the second question an unmerged
//   branch asks: a destructive button with no Return shortcut (#0359's
//   rule for Delete Commit…), and Cancel.
// - A checkout the engine refused because it would overwrite local changes:
//   Stash Changes and Switch, or Cancel.

import SwiftUI

struct RefActionDialogs: ViewModifier {
    @Binding var pendingDelete: RefDeleteConfirmation?
    @Binding var blocked: CheckoutBlocked?
    let onConfirm: (RefAction) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                pendingDelete?.title ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { confirmation in
                Button(confirmation.confirmTitle, role: .destructive) {
                    pendingDelete = nil
                    onConfirm(confirmation.action)
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { confirmation in
                Text(confirmation.message)
            }
            .alert(
                blocked?.title ?? "",
                isPresented: Binding(
                    get: { blocked != nil },
                    set: { if !$0 { blocked = nil } }),
                presenting: blocked
            ) { notice in
                Button("Stash Changes and Switch") {
                    blocked = nil
                    onConfirm(notice.retry)
                }
                Button("Cancel", role: .cancel) { blocked = nil }
            } message: { notice in
                Text(notice.message)
            }
    }
}
