// StashActions.swift
//
// #0495: the data layer behind the sidebar's stash rows and the stash
// detail pane (guide §11 decision 36) — what Apply, Pop and Drop… send,
// what the header says while one runs, what a failure or a conflict
// presents, and the Drop… confirmation. Pure values, so StashActionsTests
// reach them without a view; the loaders follow RepositoryLoader.swift's
// `@concurrent` shape.

import Foundation
import YardGit

/// One stash mutation the sidebar or the stash detail pane asks for. Each
/// runs inside exactly one journal checkpoint in the engine, so Edit ▸ Undo
/// reverts it. A stash is named by its oid (`Stash.Item.oid`).
public nonisolated enum StashAction: Equatable, Sendable {
    case apply(oid: String, restoreIndex: Bool)
    case pop(oid: String, restoreIndex: Bool)
    case drop(oid: String)

    /// The header's progress line while this action runs.
    public var progressLabel: String {
        switch self {
        case .apply: "Applying stash…"
        case .pop: "Popping stash…"
        case .drop: "Dropping stash…"
        }
    }

    /// The alert a failure presents: git's own stderr for a git refusal,
    /// without the argument vector, as `WorkingChange.failure` does. An
    /// apply or pop that git refused may still have changed files (an
    /// untracked file in the way stops git after the tracked changes are
    /// applied, measured), so those say how to put things back.
    public func failure(for error: any Error) -> CommitActionFailure {
        let title = switch self {
        case .apply: "Couldn’t Apply Stash"
        case .pop: "Couldn’t Pop Stash"
        case .drop: "Couldn’t Drop Stash"
        }
        var message = String(describing: error)
        if case let .exited(_, stderr, _) = error as? GitProcess.Failure {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty { message = detail }
            switch self {
            case .apply: message += "\n\nIf anything changed, Edit ▸ Undo Apply Stash puts it back."
            case .pop: message += "\n\nThe stash was kept. If anything changed, Edit ▸ Undo Pop Stash puts it back."
            case .drop: break
            }
        }
        return CommitActionFailure(title: title, message: message)
    }

    /// The informational alert an apply or pop that conflicted presents,
    /// or `nil` when it applied cleanly. git keeps the stash on a conflict,
    /// so Pop says so.
    public func conflictNotice(for outcome: Stash.Outcome) -> CommitActionFailure? {
        guard case let .conflicted(paths) = outcome else { return nil }
        let files = paths.count == 1 ? paths[0] : "\(paths.count) files"
        let kept = if case .pop = self { " The stash was kept." } else { "" }
        return CommitActionFailure(
            title: "The stash conflicts with \(files)",
            message: "Its changes were applied with conflict markers.\(kept) "
                + "Use Resolve Conflicts… in the header, or Edit ▸ Undo to put everything back.")
    }
}

/// The Drop… confirmation: what the dialog says. Every drop asks first
/// (decision 36); Undo brings it back.
public nonisolated struct StashDropConfirmation: Equatable, Sendable, Identifiable {
    public let title: String
    public let message: String
    public let action: StashAction
    public var id: String { title }

    public init(item: Stash.Item) {
        title = "Drop stash “\(StashRowText.label(for: item))”?"
        message = "\(item.name) is removed from the stash list. Edit ▸ Undo Drop Stash brings it back."
        action = .drop(oid: item.oid)
    }
}

/// The text a stash row and the detail pane show.
public nonisolated enum StashRowText {
    /// The message without git's `On <branch>: ` prefix, which the caption
    /// carries instead. A stash with no message keeps git's `WIP on
    /// <branch>: <oid> <subject>` whole: that is its only name.
    public static func label(for item: Stash.Item) -> String {
        guard item.message.hasPrefix("On "),
              let colon = item.message.range(of: ": ") else { return item.message }
        return String(item.message[colon.upperBound...])
    }

    /// `stash@{n} · <relative date>`.
    public static func caption(for item: Stash.Item, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.date))
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        return "\(item.name) · \(relative)"
    }
}

/// Runs one stash action. The engine calls are synchronous and block in
/// git subprocesses; `@concurrent` keeps them off the main actor, as
/// `performWorkingChange` does. Each engine call writes its own journal
/// checkpoint, so this writes none. A drop has no outcome and reports
/// `.applied`.
@concurrent @discardableResult
public func performStashAction(_ action: StashAction, at path: String) async throws -> Stash.Outcome {
    switch action {
    case let .apply(oid, restoreIndex):
        return try Stash.apply(oid: oid, restoreIndex: restoreIndex, at: path)
    case let .pop(oid, restoreIndex):
        return try Stash.pop(oid: oid, restoreIndex: restoreIndex, at: path)
    case let .drop(oid):
        try Stash.drop(oid: oid, at: path)
        return .applied
    }
}

/// What one stash holds, for the stash detail pane (`stashDiff`). #0541:
/// drawn with `options` (guide §11 decision 42).
@concurrent
public func loadStashDiff(
    at path: String, oid: String, options: DiffOptions = .standard
) async throws -> [FileDiff] {
    try await stashDiff(at: path, oid: oid, options: options)
}
