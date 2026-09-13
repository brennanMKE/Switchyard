// Squash.swift — fold HEAD into its first parent, keeping both messages (#0374)

import Foundation

/// Folds `HEAD` into its first parent as a single commit (#0374), the engine
/// behind #0359's "Squash into Parent…" menu item.
///
/// Because `HEAD` is the branch tip, no replay is needed — measured with
/// git 2.50.1: `commit-tree` with `HEAD`'s tree and the parent's parents,
/// then `update-ref` moving the branch once, leaves the index and working
/// tree untouched (the tree does not change, so staged and unstaged work
/// needs no refusal and rides through). The messages are the user's job —
/// the UI prefills `combinedMessage(parent:child:)` and the caller passes
/// the edited result in.
///
/// 1. **Refuse first** — every impossible operation is detected before the
///    first object is written and before any journal entry is written: an
///    unmerged index, a root `HEAD` (nothing to fold into), a root parent
///    (the fold would create a new root commit, the same refusal a dropped
///    chain root gets), a merge on either side (a squash would silently
///    lose the merge's second parent's line), and a message that is empty
///    after trimming.
/// 2. **Build once** — `git commit-tree` with `HEAD`'s tree, the parent's
///    parents, and the caller's message on stdin. Plumbing: no hooks, no
///    editor, and the explicit signing flag — `commit-tree` ignores
///    `commit.gpgsign` (measured, git 2.50.1), so the #0060 rule applies
///    exactly as `Rewrite`'s reword spells it.
/// 3. **Move the ref once** — `update-ref --stdin` with the old value
///    pinned, the single commit point of the fold. Until it moves, any
///    failure leaves history untouched.
///
/// The whole fold runs inside one `JournalCheckpoint.around`, so `yard undo`
/// reverses it as a single step. `GIT_EDITOR` is pinned `false` by
/// `GitProcess` and is never invoked: the message rides stdin.
public enum Squash {

    /// The message the UI pre-fills: the parent's message and HEAD's, each
    /// with trailing newlines trimmed, joined by one blank line, ending in
    /// one newline. A side that is empty after trimming contributes nothing,
    /// so the join never leaves a dangling blank line.
    public static func combinedMessage(parent: String, child: String) -> String {
        let parts = [parent, child]
            .map { part -> String in
                var trimmed = part
                while trimmed.hasSuffix("\n") { trimmed.removeLast() }
                return trimmed
            }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Folds `HEAD` into its first parent as one commit with `HEAD`'s tree
    /// and `message`, moving the branch once. One journal checkpoint — one
    /// undo step.
    ///
    /// - Parameter signing: the explicit-flag rule (#0060). `commit-tree`
    ///   ignores `commit.gpgsign`, so the resolved intent is spelled on it
    ///   explicitly: `.config` reads `commit.gpgsign` and forwards the
    ///   answer as `--gpg-sign`/`--no-gpg-sign`.
    /// - Throws: `SquashError.blockedOnConflicts` when the index already
    ///   holds unmerged entries (refused before anything is touched);
    ///   `.headIsRoot` when `HEAD` has no parent to fold into;
    ///   `.parentIsRoot` when `HEAD`'s parent is the root commit (the fold
    ///   would have to create a new root commit); `.mergeRefused` when
    ///   `HEAD` or its parent is a merge commit; `.emptyMessage` when
    ///   `message` is empty after trimming; `.signingFailed` when a
    ///   signature was attempted and could not be produced;
    ///   `GitProcess.Failure` for every other non-zero exit.
    public static func run(
        message: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Rewrite.Result {
        // 1. An unmerged index is refused before anything is read or touched,
        //    the same contract Rewrite refuses under, in the same place.
        let conflicts = try conflictedFiles(at: path, git: git)
        guard conflicts.isEmpty else {
            throw SquashError.blockedOnConflicts(files: conflicts)
        }

        // 2. Resolve HEAD: the branch it names, or HEAD itself when detached —
        //    the same resolution Rewrite performs.
        let head = try Rewrite.resolveHead(
            at: path, git: git, extraEnvironment: extraEnvironment)

        // 3. The shape refusals. A root HEAD has no parent to fold into; a
        //    root parent would make the fold a new root commit; a merge on
        //    either side would silently lose its second parent's line.
        let headParents = try Rewrite.parentOids(
            of: head.tip, at: path, git: git, extraEnvironment: extraEnvironment)
        guard let parent = headParents.first else {
            throw SquashError.headIsRoot
        }
        guard headParents.count == 1 else {
            throw SquashError.mergeRefused(commit: head.tip)
        }
        let grandParents = try Rewrite.parentOids(
            of: parent, at: path, git: git, extraEnvironment: extraEnvironment)
        guard grandParents.count <= 1 else {
            throw SquashError.mergeRefused(commit: parent)
        }
        guard !grandParents.isEmpty else {
            throw SquashError.parentIsRoot
        }

        // 4. An empty message has nothing to combine.
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SquashError.emptyMessage
        }

        // 5. Build the folded commit and move the ref once, inside one
        //    checkpoint — one undo step for the whole fold.
        let tree = try git.run(
            ["rev-parse", "\(head.tip)^{tree}"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.first ?? ""
        return try JournalCheckpoint.around(operation: "squash", at: path, git: git) { scoped in
            let inEffect = try CommitCreate.signingInEffect(
                signing, in: path, git: scoped, extraEnvironment: extraEnvironment)
            var arguments = ["commit-tree", tree]
            for grandParent in grandParents { arguments += ["-p", grandParent] }
            arguments += Rewrite.commitTreeArguments(signingInEffect: inEffect)
            let foldedOid: String
            do {
                foldedOid = try Rewrite.commitTree(
                    arguments,
                    message: message,
                    signingInEffect: inEffect,
                    at: path, git: scoped, extraEnvironment: extraEnvironment)
            } catch let error as RewriteError {
                // The shared commit-tree types its signing failure as a
                // RewriteError; this operation speaks SquashError.
                guard case let .signingFailed(reason) = error else { throw error }
                throw SquashError.signingFailed(reason: reason)
            }
            try Rewrite.moveRef(
                refName: head.refName, from: head.tip, to: foldedOid,
                at: path, git: scoped, extraEnvironment: extraEnvironment)
            return Rewrite.Result(head: foldedOid)
        }
    }
}

// MARK: - Errors

/// Why `Squash.run` refused, or could not finish. Raised before anything is
/// touched unless it says otherwise.
public enum SquashError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `HEAD` is the branch's root commit — there is no parent to fold it
    /// into. Raised before anything is touched.
    case headIsRoot
    /// `HEAD`'s parent is the root commit: the fold would have to create a
    /// new root commit. Raised before anything is touched.
    case parentIsRoot
    /// `HEAD` or its parent is a merge commit: squashing it would silently
    /// lose the merge's second parent's line of history. Raised before
    /// anything is touched.
    case mergeRefused(commit: String)
    /// The combined message is empty after trimming.
    case emptyMessage
    /// The index already holds unmerged entries, refused before anything was
    /// touched; `files` names the conflicted paths.
    case blockedOnConflicts(files: [ConflictedFile])
    /// A signature was attempted and could not be produced.
    case signingFailed(reason: String)

    public var description: String {
        switch self {
        case .headIsRoot:
            "HEAD is the branch's root commit — there is no parent to fold it into"
        case .parentIsRoot:
            "squash refused: HEAD's parent is the branch's root commit — folding into it "
                + "would create a new root commit"
        case let .mergeRefused(commit):
            "squash refused: \(commit) is a merge commit and squashing it would silently "
                + "lose its second parent's line of history"
        case .emptyMessage:
            "nothing to do — the message is empty"
        case let .blockedOnConflicts(files):
            "squash blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
        case let .signingFailed(reason):
            "signing failed: \(reason)"
        }
    }
}

// MARK: - §6 exit class

extension SquashError: ExitClassCarrying {
    public var exitClass: ExitClass {
        switch self {
        case .headIsRoot, .parentIsRoot, .mergeRefused, .emptyMessage:
            .repositoryError
        case .blockedOnConflicts: .blockedOnConflicts
        case .signingFailed: .signingFailed
        }
    }
}