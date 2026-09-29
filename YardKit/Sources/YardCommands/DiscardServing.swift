// DiscardServing.swift — the `discard` arm in `runEngineCommand`
// (guide §11 decision 37)

import Foundation
import YardGit
import YardKit

/// `switchyard discard (<path>... | --hunk <id>...)`.
///
/// Throws away unstaged changes: a tracked path goes back to its index
/// version, an untracked path is deleted, a hunk (id from `switchyard hunks
/// --unstaged`) is reverse-applied to the worktree. Staged changes are never
/// touched. Paths are repository-relative, exactly as `switchyard status`
/// prints them — an untracked directory keeps its trailing `/`. No
/// confirmation flag: the call is one `discard` journal entry, and `switchyard
/// undo` brings every byte back (guide §11 decisions 34 and 37). The engine
/// refuses, before the entry, a conflicted, intent-to-add, nested-repository,
/// submodule or unchanged path (exit 6).
func runDiscard(arguments: [String], workingDirectory: String) -> EngineReply {
    let selection: ChangeSelection
    switch parseChangeSelection(Array(arguments.dropFirst()), command: "discard") {
    case let .success(parsed): selection = parsed
    case let .failure(usage): return engineUsage(usage.text)
    }
    do {
        let top = try repositoryTop(workingDirectory)
        switch selection {
        case let .paths(paths): try DiscardChanges.discardPaths(paths, at: top)
        case let .hunks(ids): try DiscardChanges.discardHunks(ids: ids, at: top)
        }
        return engineSuccess(ChangeSelectionPayload(selection))
    } catch {
        return engineFailure(error)
    }
}
