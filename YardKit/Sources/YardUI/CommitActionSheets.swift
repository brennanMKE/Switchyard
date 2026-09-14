// CommitActionSheets.swift
//
// #0359: the sheets the commit action menu opens for the actions that ask
// for input — Edit Message, Squash with Parent, Add Tag, Create Branch and
// Edit Local Branch. Delete Commit… confirms through a
// `confirmationDialog` in `ContentView` instead, and Split… opens #0375's
// `SplitCommitSheet`. The composed `CommitActionRequest`s are pure statics
// here so every validation rule is testable without the view.

import Foundation
import SwiftUI
import YardGit

/// #0359: one pending prompt from the commit action menu — the action the
/// sheet feeds and the node it acts on. The subject and message are
/// resolved from the History pane's entries at menu time (the same rule
/// #0375's `SplitCommitRequest` pins) so a refresh while the sheet is open
/// cannot change them.
public nonisolated enum CommitActionPrompt: Identifiable, Equatable, Sendable {
    case editMessage(commit: String, subject: String, message: String)
    case squash(commit: String, subject: String, message: String)
    case addTag(commit: String, subject: String)
    case createBranch(commit: String, subject: String)
    case renameBranch(old: String, commit: String, subject: String)

    public var id: String {
        switch self {
        case let .editMessage(commit, _, _): "editMessage-\(commit)"
        case let .squash(commit, _, _): "squash-\(commit)"
        case let .addTag(commit, _): "addTag-\(commit)"
        case let .createBranch(commit, _): "createBranch-\(commit)"
        case let .renameBranch(old, commit, _): "rename-\(old)-\(commit)"
        }
    }

    /// The sheet's title.
    public var title: String {
        switch self {
        case .editMessage: "Edit Commit Message"
        case .squash: "Squash with Parent"
        case .addTag: "Add Tag"
        case .createBranch: "Create Branch"
        case .renameBranch: "Edit Local Branch"
        }
    }

    /// The commit the prompt acts on.
    public var commit: String {
        switch self {
        case let .editMessage(commit, _, _): commit
        case let .squash(commit, _, _): commit
        case let .addTag(commit, _): commit
        case let .createBranch(commit, _): commit
        case let .renameBranch(_, commit, _): commit
        }
    }
}

/// #0359: the pending Delete Commit… confirmation — the commit and the
/// subject the dialog names, truncated so a long subject cannot stretch the
/// dialog.
public nonisolated struct PendingDelete: Identifiable, Equatable, Sendable {
    public let commit: String
    public let subject: String

    public var id: String { commit }

    public init(commit: String, subject: String) {
        self.commit = commit
        self.subject = subject
    }

    /// The subject truncated to about 60 characters with an ellipsis — the
    /// HIG length a dialog title reads at.
    public var dialogTitle: String {
        let subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard subject.count > 60 else { return "Delete “\(subject)”?" }
        let cut = subject.index(subject.startIndex, offsetBy: 57)
        return "Delete “\(subject[..<cut])…?”"
    }
}

/// The requests the two sheet shapes compose, or `nil` while the input does
/// not satisfy the engine's typed refusals yet: an empty message or name,
/// an unchanged Edit Message (the engine's `.nothingToDo`), an annotated tag
/// without a message (`RefManageError.messageRequired`).
public nonisolated enum CommitPromptRequest {
    /// The Edit Message and Squash sheets' request. The message rides
    /// verbatim — the engine trims for its own refusals.
    public static func message(_ prompt: CommitActionPrompt, _ message: String) -> CommitActionRequest? {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch prompt {
        case let .editMessage(commit, _, original):
            guard message != original else { return nil }
            return .editMessage(commit: commit, message: message)
        case let .squash(commit, _, _):
            return .squashIntoParent(message: message)
        case .addTag, .createBranch, .renameBranch:
            return nil
        }
    }

    /// The Add Tag, Create Branch and Edit Local Branch sheets' request.
    /// A lightweight tag carries no message; an annotated one requires one.
    public static func name(
        _ prompt: CommitActionPrompt, _ name: String, annotated: Bool, message: String
    ) -> CommitActionRequest? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch prompt {
        case let .addTag(commit, _):
            if annotated {
                guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .addTag(commit: commit, name: name, annotated: true, message: message)
            }
            return .addTag(commit: commit, name: name, annotated: false, message: nil)
        case let .createBranch(commit, _):
            return .createBranch(name: name, start: commit)
        case let .renameBranch(old, _, _):
            return .renameBranch(old: old, new: name)
        case .editMessage, .squash:
            return nil
        }
    }
}

/// One sheet for all five prompts: a monospaced message editor for the two
/// message actions, a name field — with the annotated toggle and message
/// editor for a tag — for the three name actions. The Save/Create button
/// hands the composed `CommitActionRequest` to `onRequest`; the caller
/// dismisses the sheet first, then runs the engine call. Cancel is Esc.
public struct CommitActionPromptSheet: View {
    public let prompt: CommitActionPrompt
    public var onRequest: (CommitActionRequest) -> Void
    public var onCancel: () -> Void

    @State private var message: String = ""
    @State private var name: String = ""
    @State private var annotated = false

    public init(
        prompt: CommitActionPrompt, onRequest: @escaping (CommitActionRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.prompt = prompt
        self.onRequest = onRequest
        self.onCancel = onCancel
        switch prompt {
        case let .editMessage(_, _, original):
            _message = State(initialValue: original)
        case let .squash(_, _, combined):
            _message = State(initialValue: combined)
        case .addTag, .createBranch, .renameBranch:
            _message = State(initialValue: "")
        }
        if case let .renameBranch(old, _, _) = prompt {
            _name = State(initialValue: old)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title)
                    .font(.headline)
                Text(subject)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding()
            Divider()
            form
            Divider()
            buttons
        }
        .frame(minWidth: 460, minHeight: 180)
    }

    private var subject: String {
        switch prompt {
        case let .editMessage(_, subject, _), let .squash(_, subject, _),
             let .addTag(_, subject), let .createBranch(_, subject),
             let .renameBranch(_, _, subject):
            subject
        }
    }

    @ViewBuilder private var form: some View {
        switch prompt {
        case .editMessage, .squash:
            VStack(alignment: .leading, spacing: 4) {
                Text("Message")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextEditor(text: $message)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
            }
            .padding()
        case .addTag:
            VStack(alignment: .leading, spacing: 8) {
                TextField("Tag name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Toggle("Annotated", isOn: $annotated)
                if annotated {
                    TextEditor(text: $message)
                        .font(.body.monospaced())
                        .frame(minHeight: 72)
                        .overlay(alignment: .topLeading) {
                            if message.isEmpty {
                                Text("Tag message")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(8)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .padding()
        case .createBranch, .renameBranch:
            VStack(alignment: .leading, spacing: 4) {
                Text(isCreateBranch ? "Starts at this commit" : "New name")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Branch name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()
        }
    }

    private var isCreateBranch: Bool {
        if case .createBranch = prompt { return true }
        return false
    }

    private var composedRequest: CommitActionRequest? {
        switch prompt {
        case .editMessage, .squash:
            return CommitPromptRequest.message(prompt, message)
        case .addTag:
            return CommitPromptRequest.name(prompt, name, annotated: annotated, message: message)
        case .createBranch, .renameBranch:
            return CommitPromptRequest.name(prompt, name, annotated: false, message: "")
        }
    }

    private var confirmTitle: String {
        switch prompt {
        case .editMessage: "Save"
        case .squash: "Squash"
        case .addTag: "Add Tag"
        case .createBranch: "Create"
        case .renameBranch: "Rename"
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) {
                guard let request = composedRequest else { return }
                onRequest(request)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(composedRequest == nil)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
