// RemoteActionDialogs.swift
//
// #0531: remote management's two presentations (guide §11 decision 41), as
// a modifier so `ContentView.body` stays inside the type-checker's budget —
// the shape `RefActionDialogs` took.
//
// - The Add Remote… / Edit URL… / Rename Remote… sheet.
// - Remove Remote…'s confirmation: a destructive button with no Return
//   shortcut (#0359's rule), and Cancel.

import SwiftUI

struct RemoteActionDialogs: ViewModifier {
    @Binding var sheet: RemoteSheetRequest?
    @Binding var pendingRemoval: RemoteRemovalConfirmation?
    let existingNames: [String]
    let onAction: (RemoteAction) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet) { request in
                RemoteSheet(
                    request: request,
                    existingNames: existingNames,
                    onSubmit: { action in
                        sheet = nil
                        onAction(action)
                    },
                    onCancel: { sheet = nil })
            }
            .confirmationDialog(
                pendingRemoval?.title ?? "",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { confirmation in
                Button(confirmation.confirmTitle, role: .destructive) {
                    pendingRemoval = nil
                    onAction(.remove(remote: confirmation.remote))
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { confirmation in
                Text(confirmation.message)
            }
    }
}
