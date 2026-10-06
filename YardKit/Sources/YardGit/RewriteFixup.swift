// RewriteFixup.swift — Fixup with Parent: fold any commit into its parent,
// keeping the parent's message, and copy every descendant onto the result
// (guide §11 decision 46, #0581).

import Foundation

extension Rewrite {

    /// Folds `commit` into its first parent — GitUp's Fixup, and Brennan's
    /// `fixup` alias generalized from `HEAD` to any commit on the branch.
    ///
    /// The folded commit is the parent rebuilt with **`commit`'s tree**: the
    /// parent's own parents, message and author (name, email and date) are
    /// kept, `commit`'s message is dropped, and the committer is the current
    /// identity — exactly what `git reset --soft HEAD~1 && git commit --amend
    /// --no-edit` produces (measured, git 2.54.0).
    ///
    /// Descendants are **copied, not cherry-picked**: the fold changes no
    /// tree from `commit` upward, so each commit on `commit..HEAD`'s ancestry
    /// path is rebuilt with `commit-tree` — its own tree, message and author,
    /// its parents remapped. No patch is applied, so the replay cannot
    /// conflict, a merge above is carried with its other parents intact, and
    /// the index and working tree are never touched: staged and unstaged
    /// work rides through. The ref moves once, old value pinned, inside one
    /// `JournalCheckpoint.around(operation: "fixup")` — one undo step.
    ///
    /// - Throws: `RewriteError.unknownCommit` when `commit` does not resolve;
    ///   `.blockedOnConflicts` when the index holds unmerged entries;
    ///   `.commitNotOnRef` when `commit` is not an ancestor of the ref `HEAD`
    ///   names; `.rootRewriteRefused` when `commit` is a root commit (there
    ///   is no parent); `.foldMergeRefused` when `commit` is a merge (the
    ///   fold would drop its other parents); `.signingFailed` when a
    ///   signature was attempted and could not be produced. Every refusal is
    ///   raised before any object or journal entry is written.
    public static func fixup(
        commit: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        let commitOid = try resolve(commit, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
        let head = try resolveHead(at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseOffRef(commitOid, head, at: path, git: git, extraEnvironment: extraEnvironment)
        let parents = try parentOids(of: commitOid, at: path, git: git,
                                     extraEnvironment: extraEnvironment)
        if parents.count > 1 {
            throw RewriteError.foldMergeRefused(commit: commitOid)
        }
        guard let parent = parents.first else {
            throw RewriteError.rootRewriteRefused(operation: "fixup", commit: commitOid)
        }
        // Every commit that has `commitOid` as an ancestor and is reachable
        // from the tip, parents before children, each line `oid parent...`.
        let descendants = try git.run(
            ["rev-list", "--topo-order", "--reverse", "--ancestry-path", "--parents",
             "\(commitOid)..\(head.tip)"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.map { $0.split(separator: " ").map(String.init) }

        return try JournalCheckpoint.around(operation: "fixup", at: path, git: git) { scoped in
            let inEffect = try CommitCreate.signingInEffect(
                signing, in: path, git: scoped, extraEnvironment: extraEnvironment)
            let grandParents = try parentOids(of: parent, at: path, git: scoped,
                                              extraEnvironment: extraEnvironment)
            let folded = try copyCommit(
                parent, tree: "\(commitOid)^{tree}", parents: grandParents,
                signingInEffect: inEffect, at: path, git: scoped,
                extraEnvironment: extraEnvironment)
            var mapping = [commitOid: folded]
            for line in descendants {
                guard let oid = line.first else { continue }
                let remapped = line.dropFirst().map { mapping[$0] ?? $0 }
                mapping[oid] = try copyCommit(
                    oid, tree: "\(oid)^{tree}", parents: remapped,
                    signingInEffect: inEffect, at: path, git: scoped,
                    extraEnvironment: extraEnvironment)
            }
            let newTip = mapping[head.tip] ?? folded
            try moveRef(refName: head.refName, from: head.tip, to: newTip,
                        at: path, git: scoped, extraEnvironment: extraEnvironment)
            return Result(head: newTip)
        }
    }

    /// Folds every commit newer than `commit` on the branch into `commit` —
    /// Brennan's "good message first, then `wip` commits" workflow in one
    /// step (guide §11 decision 48, #0602).
    ///
    /// The result is `commit` rebuilt with **the tip's tree**: `commit`'s own
    /// parents, message and author (name, email and date) are kept, every
    /// newer commit's message is dropped, and the committer is the current
    /// identity. Nothing sits above the result, so nothing is copied; the
    /// ref `HEAD` names moves once, old value pinned, inside one
    /// `JournalCheckpoint.around(operation: "fixup-newer")` — one undo step.
    /// The index and working tree are never touched.
    ///
    /// `commit` may be the root (the result is a new root) or a merge (the
    /// result keeps all its parents).
    ///
    /// - Throws: `RewriteError.unknownCommit` when `commit` does not resolve;
    ///   `.blockedOnConflicts` when the index holds unmerged entries;
    ///   `.commitNotOnRef` when `commit` is not an ancestor of the ref `HEAD`
    ///   names; `.nothingToDo` when `commit` is the tip; `.foldMergeRefused`
    ///   naming the newest merge in `commit..HEAD` when there is one (folding
    ///   it would drop its other parents); `.signingFailed` when a signature
    ///   was attempted and could not be produced. Every refusal is raised
    ///   before any object or journal entry is written.
    public static func fixupNewer(
        into commit: String,
        signing: CommitCreate.Signing = .config,
        at path: String,
        git: GitProcess = GitProcess(),
        extraEnvironment: [String: String] = [:]
    ) throws -> Result {
        let commitOid = try resolve(commit, at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseUnmergedIndex(at: path, git: git, extraEnvironment: extraEnvironment)
        let head = try resolveHead(at: path, git: git, extraEnvironment: extraEnvironment)
        try refuseOffRef(commitOid, head, at: path, git: git, extraEnvironment: extraEnvironment)
        if commitOid == head.tip { throw RewriteError.nothingToDo }
        // Every commit being folded, newest first, each line `oid parent...`.
        // With no merge among them, `commit` is on the tip's first-parent
        // chain and these are exactly the commits above it.
        let newer = try git.run(
            ["rev-list", "--parents", "\(commitOid)..\(head.tip)"],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).lines.map { $0.split(separator: " ").map(String.init) }
        if let merge = newer.first(where: { $0.count > 2 }), let oid = merge.first {
            throw RewriteError.foldMergeRefused(commit: oid)
        }
        let parents = try parentOids(of: commitOid, at: path, git: git,
                                     extraEnvironment: extraEnvironment)

        return try JournalCheckpoint.around(operation: "fixup-newer", at: path, git: git) { scoped in
            let inEffect = try CommitCreate.signingInEffect(
                signing, in: path, git: scoped, extraEnvironment: extraEnvironment)
            let folded = try copyCommit(
                commitOid, tree: "\(head.tip)^{tree}", parents: parents,
                signingInEffect: inEffect, at: path, git: scoped,
                extraEnvironment: extraEnvironment)
            try moveRef(refName: head.refName, from: head.tip, to: folded,
                        at: path, git: scoped, extraEnvironment: extraEnvironment)
            return Result(head: folded)
        }
    }

    /// Rebuilds `source` with `tree` and `parents`, keeping its message
    /// bytes and its author identity and date. `tree` is any revision that
    /// names a tree (`<oid>^{tree}`); `commit-tree` peels it itself.
    static func copyCommit(
        _ source: String,
        tree: String,
        parents: [String],
        signingInEffect: Bool,
        at path: String,
        git: GitProcess,
        extraEnvironment: [String: String]
    ) throws -> String {
        let object = try git.run(
            ["cat-file", "commit", source],
            workingDirectory: path, extraEnvironment: extraEnvironment
        ).text
        let stored = StoredCommit(object)
        var arguments = ["commit-tree", tree]
        for parent in parents { arguments += ["-p", parent] }
        arguments += commitTreeArguments(signingInEffect: signingInEffect)
        return try commitTree(
            arguments, message: stored.message, signingInEffect: signingInEffect,
            at: path, git: git,
            extraEnvironment: extraEnvironment.merging(stored.authorEnvironment) { _, kept in kept })
    }
}

/// The two parts of a raw commit object (`git cat-file commit`) a copy
/// keeps: the message bytes after the header block, and the author line as
/// the `GIT_AUTHOR_*` environment `commit-tree` reads.
struct StoredCommit: Equatable {
    let message: String
    let authorEnvironment: [String: String]

    init(_ object: String) {
        let split = object.range(of: "\n\n")
        message = split.map { String(object[$0.upperBound...]) } ?? ""
        let header = split.map { String(object[..<$0.lowerBound]) } ?? object
        var environment: [String: String] = [:]
        if let line = header.split(separator: "\n").first(where: { $0.hasPrefix("author ") }),
           let open = line.firstIndex(of: "<"),
           let close = line.lastIndex(of: ">") {
            let name = line[line.index(line.startIndex, offsetBy: 7)..<open]
            environment["GIT_AUTHOR_NAME"] = name.trimmingCharacters(in: .whitespaces)
            environment["GIT_AUTHOR_EMAIL"] = String(line[line.index(after: open)..<close])
            environment["GIT_AUTHOR_DATE"] =
                "@" + line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
        authorEnvironment = environment
    }
}
