// CommitActionRunner.swift
//
// #0359: the one place a commit action reaches the engine. Every engine
// call here already runs inside its own `JournalCheckpoint.around`
// (`Rewrite.swift`, `Fixup.swift`, `Squash.swift`, `Split.swift`,
// `Replay.swift`, `Merge.swift`, `RefManage.swift`), so this file writes no
// checkpoint of its own — one user action is one undo step, exactly as the
// CLI verbs are.

import Foundation
import YardGit

/// `YardUI` sets `.defaultIsolation(MainActor.self)` (`Package.swift`), so
/// this needs `@concurrent` for the same reason `splitCommit` does
/// (`RepositoryLoader.swift`): the engine calls are synchronous and block in
/// git subprocesses, and `@concurrent` keeps all of it off the main actor
/// while the UI awaits.
@concurrent
public func performCommitAction(_ request: CommitActionRequest, at path: String) async throws {
    switch request {
    case let .editMessage(commit, message):
        _ = try Rewrite.reword(commit: commit, message: message, at: path)
    case let .fixupIntoParent(parent):
        _ = try Fixup.run(source: "HEAD", target: parent, at: path)
    case let .squashIntoParent(message):
        _ = try Squash.run(message: message, at: path)
    case let .split(commit, hunkID, first, second):
        _ = try Split.run(commit: commit, hunkID: hunkID, first: first, second: second, at: path)
    case let .swapWithParent(commit, parent):
        _ = try Rewrite.reorder(commit: commit, position: .before, reference: parent, at: path)
    case let .swapWithChild(commit, child):
        _ = try Rewrite.reorder(commit: commit, position: .after, reference: child, at: path)
    case let .delete(commit):
        _ = try Rewrite.drop(commit: commit, at: path)
    case let .revert(commit):
        _ = try Replay.revert(commit: commit, at: path)
    case let .cherryPick(commit):
        _ = try Replay.cherryPick(commit: commit, at: path)
    case let .merge(branch):
        _ = try Merge.run(branch: branch, intent: .noFastForward, at: path)
    case let .rebaseOnto(base):
        _ = try Rewrite.rebaseOnto(base: base, at: path)
    case let .setBranchTip(commit):
        _ = try Rewrite.setTip(commit: commit, at: path)
    case let .addTag(commit, name, annotated, message):
        _ = try Tag.create(
            name: name, commit: commit, annotated: annotated, message: message, at: path)
    case let .createBranch(name, start):
        _ = try Branch.create(name: name, start: start, at: path)
    case let .renameBranch(old, new):
        _ = try Branch.rename(old: old, new: new, at: path)
    }
}
