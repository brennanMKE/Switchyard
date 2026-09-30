// RemoteActions.swift
//
// #0530: the data layer behind remote management (guide §11 decision 41) —
// what each action sends, what the header says while it runs, what a
// failure presents, the Add / Edit URL / Rename sheet's rules and the
// Remove confirmation. Pure values, so RemoteActionsTests reach them
// without a view; the runners follow RefActions.swift's `@concurrent` shape.

import Foundation
import YardGit

/// One remote-management action the sidebar asks for.
public nonisolated enum RemoteAction: Equatable, Sendable {
    /// Add Remote…; `fetch` runs Fetch “name” after it (the sheet's
    /// checkbox), as a second step.
    case add(name: String, url: String, fetch: Bool)
    /// Edit URL…: the fetch URL.
    case setURL(remote: String, url: String)
    /// Rename Remote….
    case rename(remote: String, to: String)
    /// Remove Remote…, after its confirmation.
    case remove(remote: String)
    /// Fetch “name”.
    case fetch(remote: String)
    /// Prune “name”.
    case prune(remote: String)

    /// The step that runs after this one succeeds: an Add with its
    /// checkbox on fetches the new remote.
    public var followUp: RemoteAction? {
        if case let .add(name, _, true) = self { return .fetch(remote: name) }
        return nil
    }

    /// Whether the step talks to the network, so the header's Cancel
    /// reaches it (the toolbar's `remoteTask`, #0458).
    public var usesNetwork: Bool {
        switch self {
        case .fetch, .prune: true
        case .add, .setURL, .rename, .remove: false
        }
    }

    /// The header's progress line while this action runs.
    public var progressLabel: String {
        switch self {
        case let .add(name, _, _): "Adding remote “\(name)”…"
        case let .setURL(remote, _): "Changing the URL of “\(remote)”…"
        case let .rename(remote, _): "Renaming remote “\(remote)”…"
        case let .remove(remote): "Removing remote “\(remote)”…"
        case let .fetch(remote): "Fetching “\(remote)”…"
        case let .prune(remote): "Pruning “\(remote)”…"
        }
    }

    /// The alert a failure presents, or nil for a cancellation. A refusal
    /// shows its sentence; git's stderr shows without `hint:` lines, with
    /// `RemoteOperation`'s advice for a missing credential.
    public func failure(for error: any Error) -> CommitActionFailure? {
        if error is CancellationError { return nil }
        let title = switch self {
        case .add: "Couldn’t Add Remote"
        case .setURL: "Couldn’t Change the URL"
        case .rename: "Couldn’t Rename Remote"
        case .remove: "Couldn’t Remove Remote"
        case let .fetch(remote): "Couldn’t Fetch “\(remote)”"
        case let .prune(remote): "Couldn’t Prune “\(remote)”"
        }
        if let refusal = error as? RemoteConfig.Refusal {
            return CommitActionFailure(title: title, message: refusal.description)
        }
        guard case let .exited(_, stderr, _) = error as? GitProcess.Failure else {
            return CommitActionFailure(title: title, message: String(describing: error))
        }
        var message = stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("hint:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let advice = RemoteOperation.advice(for: stderr) { message += "\n\n" + advice }
        return CommitActionFailure(title: title, message: message)
    }
}

/// Which sheet the sidebar asked for. `Identifiable` for `.sheet(item:)`.
public nonisolated enum RemoteSheetRequest: Identifiable, Equatable, Sendable {
    case add
    /// `url` is the configured fetch URL (before `insteadOf` rewriting);
    /// `pushURLs` are shown when they differ from it.
    case editURL(remote: String, url: String, pushURLs: [String])
    case rename(remote: String)

    public var id: String {
        switch self {
        case .add: "add"
        case let .editURL(remote, _, _): "url:" + remote
        case let .rename(remote): "rename:" + remote
        }
    }

    public var title: String {
        switch self {
        case .add: "Add Remote"
        case let .editURL(remote, _, _): "Edit URL of “\(remote)”"
        case let .rename(remote): "Rename Remote “\(remote)”"
        }
    }

    /// The confirm button's title.
    public var confirmTitle: String {
        switch self {
        case .add: "Add Remote"
        case .editURL: "Change URL"
        case .rename: "Rename"
        }
    }

    /// The sheet's footnote: what happens, and that Edit ▸ Undo cannot take
    /// it back (decision 41 — a remote's configuration is not journaled).
    public var footnote: String {
        switch self {
        case .add:
            "Edit ▸ Undo doesn’t undo adding a remote. Remove it to take it back."
        case .editURL:
            "Only the fetch URL changes. Edit ▸ Undo doesn’t undo this. Edit the URL again to change it back."
        case .rename:
            "Its remote-tracking branches, and the branches that track it, follow the new name. "
                + "Edit ▸ Undo can’t undo a rename. Rename it back instead."
        }
    }
}

/// The sheet's validation, as the user types. Pure.
public nonisolated enum RemoteSheetRules {
    /// Why `name` cannot be used, or nil. `existing` is every configured
    /// remote's name; a rename passes the remote being renamed as
    /// `renaming`, which is not a conflict with itself.
    public static func nameMessage(_ name: String, existing: [String], renaming: String? = nil) -> String? {
        if let problem = RemoteConfig.nameProblem(name) { return problem }
        if name == renaming { return "Enter a new name." }
        switch RemoteConfig.conflict(for: name, among: existing.filter { $0 != renaming }) {
        case let .nameInUse(taken)?: return "A remote named “\(taken)” already exists."
        case let .nestedName(_, other)?: return "Can’t be used beside the remote “\(other)”."
        default: return nil
        }
    }

    /// Why `url` cannot be used, or nil — surrounding whitespace ignored,
    /// as the engine trims it.
    public static func urlMessage(_ url: String) -> String? {
        RemoteConfig.urlProblem(url.trimmingCharacters(in: .whitespaces))
    }
}

/// Remove Remote…'s confirmation: says what goes with the remote.
public nonisolated struct RemoteRemovalConfirmation: Identifiable, Equatable, Sendable {
    public let remote: String
    public let impact: RemoteConfig.RemovalImpact

    public init(remote: String, impact: RemoteConfig.RemovalImpact) {
        self.remote = remote
        self.impact = impact
    }

    public var id: String { remote }
    public var title: String { "Remove the remote “\(remote)”?" }
    public var confirmTitle: String { "Remove Remote" }

    public var message: String {
        var parts: [String] = []
        let tracking = impact.trackingBranches
        switch tracking.count {
        case 0: parts.append("It has no remote-tracking branches.")
        case 1: parts.append("Its remote-tracking branch \(tracking[0]) is deleted.")
        default:
            parts.append("Its \(tracking.count) remote-tracking branches (\(Self.list(tracking))) are deleted.")
        }
        let upstreamOf = impact.upstreamOf
        switch upstreamOf.count {
        case 0: break
        case 1: parts.append("The branch \(upstreamOf[0]) stops tracking it.")
        default: parts.append("\(upstreamOf.count) branches stop tracking it: \(Self.list(upstreamOf)).")
        }
        parts.append("Local branches and commits are kept. Edit ▸ Undo can’t undo this. "
            + "Add the remote again and fetch to get its branches back.")
        return parts.joined(separator: " ")
    }

    /// Up to three names, then "and N more".
    static func list(_ names: [String]) -> String {
        names.count <= 3
            ? names.joined(separator: ", ")
            : names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
}

/// Runs one remote action. `@concurrent` keeps the engine's synchronous
/// `git remote` calls and journal writes off the main actor; Fetch and
/// Prune run their network child through `GitProcess`'s async path, so
/// cancelling the calling task terminates it.
@concurrent
public func performRemoteAction(_ action: RemoteAction, at path: String) async throws {
    switch action {
    case let .add(name, url, _): try RemoteConfig.add(name: name, url: url, at: path)
    case let .setURL(remote, url): try RemoteConfig.setURL(url, forRemote: remote, at: path)
    case let .rename(remote, new): try RemoteConfig.rename(remote, to: new, at: path)
    case let .remove(remote): try RemoteConfig.remove(remote, at: path)
    case let .fetch(remote): try await RemoteSync.fetch(remote: remote, at: path)
    case let .prune(remote): try await RemoteSync.prune(remote: remote, at: path)
    }
}

/// What removing `remote` takes with it, for the confirmation.
@concurrent
public func loadRemoteRemovalImpact(remote: String, at path: String) async throws -> RemoteConfig.RemovalImpact {
    try RemoteConfig.removalImpact(of: remote, at: path)
}

/// The configured fetch URL of `remote`, for Edit URL…'s field; empty when
/// it has none.
@concurrent
public func loadConfiguredURL(remote: String, at path: String) async throws -> String {
    try RemoteConfig.configuredURL(of: remote, at: path) ?? ""
}

/// What a Remotes-section menu item asks `ContentView` for (#0532). The
/// sheets and the confirmation need a read first (the configured URL, the
/// removal's impact), which `ContentView` owns.
public nonisolated enum RemoteMenuCommand: Equatable, Sendable {
    case add
    /// `pushURLs` only when they differ from the fetch URL.
    case editURL(remote: String, pushURLs: [String])
    case rename(remote: String)
    case remove(remote: String)
    /// Fetch or Prune, which run at once.
    case run(RemoteAction)
}
