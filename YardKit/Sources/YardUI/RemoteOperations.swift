// RemoteOperations.swift
//
// #0456: the toolbar's Fetch, Pull and Push (guide §11 decision 32) as
// values — when each is available, what its progress line says, and the
// alert a failure presents — plus the `@concurrent` calls into the engine.
// Pure, so RemoteOperationsTests reaches every rule without a window.

import YardGit

/// One network operation the toolbar offers.
public nonisolated enum RemoteOperation: String, CaseIterable, Sendable {
    case fetch, pull, push

    /// The toolbar button's title.
    public var title: String {
        switch self {
        case .fetch: "Fetch"
        case .pull: "Pull"
        case .push: "Push"
        }
    }

    /// The toolbar button's SF Symbol.
    public var systemImage: String {
        switch self {
        case .fetch: "arrow.triangle.2.circlepath"
        case .pull: "arrow.down.circle"
        case .push: "arrow.up.circle"
        }
    }

    /// The progress line while this operation runs.
    public var progressLabel: String {
        switch self {
        case .fetch: "Fetching…"
        case .pull: "Pulling…"
        case .push: "Pushing…"
        }
    }

    /// Why the button is disabled, or nil when it is enabled. The reason is
    /// the button's help text, so a greyed button always says why.
    ///
    /// - `remotes`: the repository's configured remote names.
    public func disabledReason(for state: WhereAmI, remotes: [String]) -> String? {
        if remotes.isEmpty { return "This repository has no remotes." }
        switch self {
        case .fetch:
            return nil
        case .pull:
            guard state.branch != nil else { return "HEAD is detached." }
            guard state.upstream != nil else { return "This branch has no upstream to pull from." }
            if let busy = TrackingSummary.operationInProgress(for: state) { return busy + "." }
            return nil
        case .push:
            guard state.branch != nil else { return "HEAD is detached." }
            guard !state.headOID.isEmpty else { return "This branch has no commits yet." }
            if let busy = TrackingSummary.operationInProgress(for: state) { return busy + "." }
            if state.upstream != nil, (state.ahead ?? 0) == 0 { return "Nothing to push." }
            return nil
        }
    }

    /// The alert a failure presents, or nil for a cancellation — the user
    /// asked for that, so it is not an error.
    ///
    /// A git refusal shows git's own stderr without its `hint:` lines (they
    /// suggest terminal commands) and with one sentence of our own for the
    /// three failures a user can act on: a diverged pull, a rejected push,
    /// and a missing credential.
    public func failure(for error: any Error) -> CommitActionFailure? {
        if error is CancellationError { return nil }
        let title = "Couldn’t \(self.title)"
        if let refusal = error as? RemoteSync.Refusal {
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
        if let advice = Self.advice(for: stderr) { message += "\n\n" + advice }
        return CommitActionFailure(title: title, message: message)
    }

    /// The sentence appended for a failure the user can act on, matched on
    /// git's stderr (`GitProcess` pins `LC_ALL=C`, so it is English).
    static func advice(for stderr: String) -> String? {
        if stderr.contains("Not possible to fast-forward") {
            return "This branch and its upstream have diverged. Pull only fast-forwards, "
                + "so the branch was not changed. Merge or rebase it from the history instead."
        }
        if stderr.contains("[rejected]") {
            return "The remote has commits this branch does not. Pull first. "
                + "Switchyard never force-pushes."
        }
        let credentialMarkers = [
            "terminal prompts disabled", "Permission denied (publickey",
            "Host key verification failed", "Authentication failed",
        ]
        if credentialMarkers.contains(where: stderr.contains) {
            return "Switchyard never asks for a password. Add the credential to your git "
                + "credential helper or ssh-agent, then try again."
        }
        return nil
    }
}

/// Runs one network operation. `@concurrent` keeps the engine's
/// synchronous probes and journal write off the main actor; the network
/// child itself runs through `GitProcess`'s async path, so cancelling the
/// calling task terminates it.
@concurrent
public func performRemoteOperation(_ operation: RemoteOperation, at path: String) async throws {
    switch operation {
    case .fetch: try await RemoteSync.fetch(at: path)
    case .pull: try await RemoteSync.pull(at: path)
    case .push: try await RemoteSync.push(at: path)
    }
}

/// The repository's configured remote names, for the toolbar's enabled
/// state. `@concurrent` like every loader in `RepositoryLoader.swift`.
@concurrent
public func loadRemoteNames(at path: String) async throws -> [String] {
    try await RemoteSync.remoteNames(at: path)
}
