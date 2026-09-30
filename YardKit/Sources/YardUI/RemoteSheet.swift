// RemoteSheet.swift
//
// #0531: Add Remote…, Edit URL… and Rename Remote… (guide §11 decision 41)
// — one sheet, three shapes. It validates as the user types
// (`RemoteSheetRules`) and returns a `RemoteAction`; `ContentView` runs it,
// so the busy flag, the alert and the refresh stay there.

import SwiftUI

public struct RemoteSheet: View {
    private let request: RemoteSheetRequest
    /// Every configured remote's name, for the name checks.
    private let existingNames: [String]
    private let onSubmit: (RemoteAction) -> Void
    private let onCancel: () -> Void

    @State private var name: String
    @State private var url: String
    /// Add only: fetch the new remote's branches right away. On by default:
    /// a remote with no branches listed looks like one that did not work.
    @State private var fetchNow = true

    public init(
        request: RemoteSheetRequest,
        existingNames: [String],
        onSubmit: @escaping (RemoteAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.existingNames = existingNames
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        switch request {
        case .add:
            _name = State(initialValue: "")
            _url = State(initialValue: "")
        case let .editURL(_, current, _):
            _name = State(initialValue: "")
            _url = State(initialValue: current)
        case let .rename(remote):
            _name = State(initialValue: remote)
            _url = State(initialValue: "")
        }
    }

    private var nameMessage: String? {
        switch request {
        case .add: RemoteSheetRules.nameMessage(name, existing: existingNames)
        case let .rename(remote): RemoteSheetRules.nameMessage(name, existing: existingNames, renaming: remote)
        case .editURL: nil
        }
    }

    private var urlMessage: String? {
        if case .rename = request { return nil }
        return RemoteSheetRules.urlMessage(url)
    }

    /// What the confirm button sends; nil (the button disabled) while a
    /// field is invalid.
    private var action: RemoteAction? {
        guard nameMessage == nil, urlMessage == nil else { return nil }
        return switch request {
        case .add: .add(name: name, url: url, fetch: fetchNow)
        case let .editURL(remote, _, _): .setURL(remote: remote, url: url)
        case let .rename(remote): .rename(remote: remote, to: name)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title)
                .font(.headline)
            if case .editURL = request {} else {
                field("Name", text: $name, message: nameMessage, identifier: "remote-name")
            }
            if case .rename = request {} else {
                field("URL", text: $url, message: urlMessage, identifier: "remote-url")
            }
            if case let .editURL(_, _, pushURLs) = request, !pushURLs.isEmpty {
                Text("Pushes go to \(pushURLs.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .add = request {
                Toggle("Fetch its branches now", isOn: $fetchNow)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("remote-fetch-now")
            }
            Text(request.footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle) {
                    if let action { onSubmit(action) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(action == nil)
                .accessibilityIdentifier("remote-confirm")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// A labelled field with its validation message under it. The message
    /// shows once the field has text, so an empty sheet is not all red; the
    /// confirm button is disabled either way.
    private func field(
        _ label: String, text: Binding<String>, message: String?, identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifier)
            if let message, !text.wrappedValue.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

#Preview("Add") {
    RemoteSheet(request: .add, existingNames: ["origin"], onSubmit: { _ in }, onCancel: {})
}

#Preview("Edit URL") {
    RemoteSheet(
        request: .editURL(remote: "gh", url: "https://example.invalid/a.git",
                          pushURLs: ["git@example.invalid:a.git"]),
        existingNames: ["gh"], onSubmit: { _ in }, onCancel: {})
}
