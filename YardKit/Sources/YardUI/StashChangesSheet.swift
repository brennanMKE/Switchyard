// StashChangesSheet.swift
//
// #0494: Stash Changes… (guide §11 decision 36) — an optional message and
// Include untracked files, then Stash. The Changes view presents it and
// sends what it returns through `runWorkingChange`, like every other
// Changes-view mutation, so the busy flag, the alert and the refresh stay
// in `ContentView`.

import SwiftUI

public struct StashChangesSheet: View {
    /// Whether the working tree has untracked files; the checkbox's help
    /// says what it would take.
    private let hasUntracked: Bool
    private let onStash: (WorkingChange) -> Void
    private let onCancel: () -> Void

    @State private var message = ""
    /// On by default: Stash Changes should empty the Changes list, and the
    /// list shows untracked files (decision 36).
    @State private var includeUntracked = true

    public init(
        hasUntracked: Bool,
        onStash: @escaping (WorkingChange) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.hasUntracked = hasUntracked
        self.onStash = onStash
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Changes")
                .font(.headline)
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .accessibilityIdentifier("stash-message")
            Toggle("Include untracked files", isOn: $includeUntracked)
                .toggleStyle(.checkbox)
                .help(hasUntracked
                    ? "Untracked files are stashed and removed from the working tree"
                    : "There are no untracked files")
                .accessibilityIdentifier("stash-include-untracked")
            Text("Staged and unstaged changes are saved and the working tree goes back to the last commit. Edit ▸ Undo Stash Changes puts them back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Stash") {
                    onStash(.stash(message: message, includeUntracked: includeUntracked))
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("stash-confirm")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

#Preview {
    StashChangesSheet(hasUntracked: true, onStash: { _ in }, onCancel: {})
}
