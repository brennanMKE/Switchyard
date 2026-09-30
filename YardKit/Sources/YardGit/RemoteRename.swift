// RemoteRename.swift — rename and remove a remote (guide §11 decision 41)

import Foundation

public extension RemoteConfig {

    /// The `operation` a rename's journal entry records. Undo refuses to
    /// restore it (`JournalUndo.Error.remoteChangeNotUndoable`).
    static let renameOperation = "remote-rename"
    /// The `operation` a removal's journal entry records. Undo refuses to
    /// restore it.
    static let removeOperation = "remote-remove"

    /// What Remove Remote… will take with it, for its confirmation.
    struct RemovalImpact: Equatable, Sendable {
        /// The remote's remote-tracking branches, short names
        /// (`origin/main`), sorted; `origin/HEAD` is not listed.
        public let trackingBranches: [String]
        /// Local branches whose upstream is on this remote
        /// (`branch.<b>.remote` is its name), sorted. Removing the remote
        /// unsets their `branch.<b>.remote` and `branch.<b>.merge`.
        public let upstreamOf: [String]

        public init(trackingBranches: [String], upstreamOf: [String]) {
            self.trackingBranches = trackingBranches
            self.upstreamOf = upstreamOf
        }
    }

    /// What removing `name` deletes, read without changing anything.
    static func removalImpact(of name: String, at path: String, git: GitProcess = GitProcess()) throws -> RemovalImpact {
        guard try Self.names(at: path, git: git).contains(name) else { throw Refusal.unknownRemote(name) }
        // No other remote's refs can sit under refs/remotes/<name>/: add and
        // rename refuse a nested name (`conflict(for:among:)`).
        let refs = try git.run(
            ["for-each-ref", "--format=%(refname)", "refs/remotes/\(name)/"], workingDirectory: path).lines
        let tracking = refs
            .filter { $0 != "refs/remotes/\(name)/HEAD" }
            .map { String($0.dropFirst("refs/remotes/".count)) }
            .sorted()
        let out = try git.capture(["config", "--get-regexp", #"^branch\..*\.remote$"#], workingDirectory: path)
        var upstreamOf: [String] = []
        for line in out.exitCode == 0 ? out.lines : [] {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[..<space]
            guard line[line.index(after: space)...] == name else { continue }
            upstreamOf.append(String(key.dropFirst("branch.".count).dropLast(".remote".count)))
        }
        return RemovalImpact(trackingBranches: tracking, upstreamOf: upstreamOf.sorted())
    }

    /// Rename Remote…: `git remote rename -- <old> <new>`, which moves the
    /// remote-tracking branches to `refs/remotes/<new>/` and rewrites every
    /// `branch.<b>.remote` that named it.
    ///
    /// **Journaled after it succeeds, and Undo refuses that entry** — the
    /// push rule (guide §11 decisions 32 and 41). The configuration is not in
    /// any journal entry, so restoring an older entry would bring the old
    /// `refs/remotes/<old>/*` back beside a remote now called `<new>`. A
    /// rename that fails writes no entry.
    static func rename(_ old: String, to new: String, at path: String, git: GitProcess = GitProcess()) throws {
        if let reason = nameProblem(new) { throw Refusal.invalidName(new, reason: reason) }
        let names = try Self.names(at: path, git: git)
        guard names.contains(old) else { throw Refusal.unknownRemote(old) }
        if let refusal = conflict(for: new, among: names.filter { $0 != old }) { throw refusal }
        let context = try WorktreeContext.resolve(path: path, git: git)
        try git.run(["remote", "rename", "--", old, new], workingDirectory: path)
        try JournalCheckpoint.checkpoint(operation: renameOperation, in: context, git: git)
    }

    /// Remove Remote…: `git remote remove -- <name>`, which deletes its
    /// remote-tracking branches and unsets `branch.<b>.remote` and
    /// `branch.<b>.merge` for every branch whose upstream it was (measured,
    /// git 2.54.0). Journaled after it succeeds, and Undo refuses that entry,
    /// for the reason `rename` gives: restoring an older entry would bring
    /// the deleted remote-tracking branches back for a remote that no longer
    /// exists.
    static func remove(_ name: String, at path: String, git: GitProcess = GitProcess()) throws {
        guard try Self.names(at: path, git: git).contains(name) else { throw Refusal.unknownRemote(name) }
        let context = try WorktreeContext.resolve(path: path, git: git)
        try git.run(["remote", "remove", "--", name], workingDirectory: path)
        try JournalCheckpoint.checkpoint(operation: removeOperation, in: context, git: git)
    }
}
