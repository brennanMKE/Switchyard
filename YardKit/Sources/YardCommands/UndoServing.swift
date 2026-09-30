// UndoServing.swift — the `undo` and `redo` arms in `runEngineCommand`
// (guide §11 decision 37)

import Foundation
import YardGit
import YardKit

/// One step of an undo or redo walk.
struct JournalStepPayload: Encodable, Sendable, Equatable {
    /// The journal entry whose snapshot this step restored.
    let entry: String
    /// Undo only: the operation this step undid (`commit`, `stage`,
    /// `stash-drop`, …), read from the entry's metadata. Absent on redo,
    /// and on an entry that carries no metadata.
    let operation: String?
    /// The pieces the restore applied (`refs`, `head`, `index`, `worktree`,
    /// `untracked`, `sequencer`, `stash`).
    let restored: [String]
    /// The pieces it did not apply, as `piece:reason`.
    let notRestored: [String]
    /// The branch `HEAD` did not adopt because a sibling worktree holds it;
    /// absent in the ordinary case (guide §11 decision 16).
    let detachedFrom: String?
    /// Branches a sibling worktree holds, left where they were (decision 23).
    let leftAlone: [String]
}

/// The `undo` / `redo` payload: one step per `--steps`, in walk order.
struct JournalWalkPayload: Encodable, Sendable, Equatable {
    let steps: [JournalStepPayload]
}

/// `switchyard undo [--steps <n>]` and `switchyard redo [--steps <n>]`.
///
/// Walks this worktree's journal chain (`JournalUndo`), restoring each step
/// and recording it as a traversal entry, exactly as Edit ▸ Undo and Redo do.
/// A walk longer than what remains, or one that would cross a `push` entry,
/// is refused whole, before anything is written (exit 6). `<n>` is a
/// positive integer, default 1.
func runUndo(arguments: [String], workingDirectory: String) -> EngineReply {
    let command = arguments.first ?? "undo"
    let tail = Array(arguments.dropFirst())
    var steps = 1
    switch tail.count {
    case 0:
        break
    case 2 where tail[0] == "--steps":
        let value = tail[1]
        guard !value.isEmpty, value.allSatisfy({ ("0"..."9").contains($0) }),
              let parsed = Int(value), parsed > 0 else {
            return engineUsage("\(command)'s --steps takes a positive integer; got '\(value)'.")
        }
        steps = parsed
    default:
        return engineUsage(
            "\(command) takes at most one --steps <n> flag; got '\(tail.joined(separator: " "))'.")
    }

    do {
        let context = try WorktreeContext.resolve(path: workingDirectory)
        let commandLine = ([ServiceNames.cliName] + arguments).joined(separator: " ")
        let reports: [JournalRestore.Report]
        var operations: [String: String] = [:]
        if command == "undo" {
            for item in try JournalList.list(in: context).items {
                if let operation = item.metadata?.operation { operations[item.entry.id.string] = operation }
            }
            reports = try JournalUndo.undo(steps: steps, command: commandLine, in: context)
        } else {
            reports = try JournalUndo.redo(steps: steps, command: commandLine, in: context)
        }
        return engineSuccess(JournalWalkPayload(steps: reports.map { report in
            JournalStepPayload(
                entry: report.entry.id.string,
                operation: operations[report.entry.id.string],
                restored: report.restored.map(\.rawValue),
                notRestored: report.notRestored.map { "\($0.piece.rawValue):\($0.reason.rawValue)" },
                detachedFrom: report.detachedFrom,
                leftAlone: report.leftAlone)
        }))
    } catch {
        return engineFailure(error)
    }
}
