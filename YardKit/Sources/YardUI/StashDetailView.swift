// StashDetailView.swift
//
// #0496: the Detail pane's content for a stash selected in the sidebar
// (guide §11 decision 36) — its message, the commit it was made on, and
// its files' diffs, read-only through `FileDiffView`, with Apply, Pop and
// Drop…. `ContentView` owns every mutation and the Drop… confirmation, so
// the busy flag, the alerts and the in-place refresh stay in one place;
// this view only asks, the way `WorkingChangesView` does.

import SwiftUI
import YardGit

public struct StashDetailView: View {
    private let item: Stash.Item
    /// `nil` while loading; the stash's files otherwise (`loadStashDiff`).
    private let files: [FileDiff]?
    private let diffError: String?
    private let isBusy: Bool
    private let perform: (StashAction) -> Void
    private let onDrop: () -> Void

    /// Restore staged changes: Apply and Pop pass `--index`. Off by
    /// default, git's own default (decision 36).
    @State private var restoreIndex = false

    public init(
        item: Stash.Item, files: [FileDiff]?, diffError: String?, isBusy: Bool,
        perform: @escaping (StashAction) -> Void, onDrop: @escaping () -> Void
    ) {
        self.item = item
        self.files = files
        self.diffError = diffError
        self.isBusy = isBusy
        self.perform = perform
        self.onDrop = onDrop
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                diffContent
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(StashRowText.label(for: item))
                .font(.headline)
                .textSelection(.enabled)
            Text(StashRowText.caption(for: item) + " · on " + String(item.baseOID.prefix(7))
                + (item.includesUntracked ? " · includes untracked files" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            // The checkbox has its own line: beside the buttons it wrapped a
            // word per line in a narrow Detail pane (measured in the VM).
            HStack {
                Button("Apply") { perform(.apply(oid: item.oid, restoreIndex: restoreIndex)) }
                    .help("Apply the stash and keep it")
                    .accessibilityIdentifier("stash-apply")
                Button("Pop") { perform(.pop(oid: item.oid, restoreIndex: restoreIndex)) }
                    .help("Apply the stash and drop it")
                    .accessibilityIdentifier("stash-pop")
                Button("Drop…", role: .destructive, action: onDrop)
                    .help("Remove the stash from the list")
                    .accessibilityIdentifier("stash-drop")
            }
            .disabled(isBusy)
            Toggle("Restore staged changes", isOn: $restoreIndex)
                .toggleStyle(.checkbox)
                .help("Put staged changes back staged (git stash apply --index)")
                .accessibilityIdentifier("stash-restore-index")
                .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        if let diffError {
            Text("Couldn't load the stash: \(diffError)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let files {
            VStack(alignment: .leading, spacing: 12) {
                Text(CommitDetailView.changedFilesSummary(count: files.count))
                    .font(.subheadline.weight(.semibold))
                ForEach(files, id: \.path) { file in
                    FileDiffView(file: file)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// #0496: the Drop… confirmation, as a modifier so `ContentView.body` stays
/// inside the type-checker's budget. Return does nothing: the destructive
/// button has no default-action shortcut, #0359's rule for Delete Commit….
struct StashDropDialog: ViewModifier {
    @Binding var pending: StashDropConfirmation?
    let onConfirm: (StashAction) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { confirmation in
            Button("Drop", role: .destructive) {
                pending = nil
                onConfirm(confirmation.action)
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}
