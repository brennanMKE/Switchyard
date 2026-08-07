// WhereAmI.swift

import Foundation

/// The output of `yard whereami`. One call returns every field; no
/// follow-up command is required.
public struct WhereAmI: Sendable, Equatable {

    /// The branch name, e.g. `"main"`. Nil when HEAD is detached.
    public let branch: String?

    /// The upstream ref, e.g. `"origin/main"`. Nil when none is set or on a
    /// detached HEAD.
    public let upstream: String?

    /// Number of commits ahead of the upstream. Nil when there is no
    /// upstream to compare against.
    public let ahead: Int?

    /// Number of commits behind the upstream. Nil when there is no upstream
    /// to compare against.
    public let behind: Int?

    /// True when a rebase is in progress. Tests this via `git rev-parse
    /// --git-path` for both rebase state directories so it is correct in a
    /// linked worktree and on a reftable repository.
    public let isMidRebase: Bool

    /// True when a merge is in progress.
    public let isMidMerge: Bool

    /// True when a cherry-pick is in progress.
    public let isMidCherryPick: Bool

    /// Number of stash entries, as returned by `git stash list`.
    public let stashCount: Int

    /// Number of untracked files in the working tree, as returned by
    /// `git ls-files --others --exclude-standard`.
    public let untrackedCount: Int

    /// Number of files with unstaged changes, as returned by
    /// `git diff-index --name-status HEAD`. The code splits stdout on `\n` and
    /// counts non-empty lines; a non-zero exit on a fresh repository (no HEAD)
    /// is treated as zero files.
    public let unstagedCount: Int

    /// Number of files with staged changes, as returned by
    /// `git diff-index --name-status --cached HEAD`. The code splits stdout on
    /// `\n` and counts non-empty lines.
    public let stagedCount: Int

    /// True when the index contains unmerged (conflicted) entries.
    public let hasConflicts: Bool

    /// The short form of HEAD's object id, e.g. `"a1b2c3d"`.
    public let headOID: String

    /// The raw form of HEAD, for debugging. Always a SHA or empty (the code
    /// runs `git rev-parse HEAD`), never the symbolic `"ref: refs/heads/main"`
    /// form. Empty on a fresh repository with no commits yet.
    public let rawHead: String

    public init(
        branch: String?,
        upstream: String?,
        ahead: Int?,
        behind: Int?,
        isMidRebase: Bool,
        isMidMerge: Bool,
        isMidCherryPick: Bool,
        stashCount: Int,
        untrackedCount: Int,
        unstagedCount: Int,
        stagedCount: Int,
        hasConflicts: Bool,
        headOID: String,
        rawHead: String
    ) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isMidRebase = isMidRebase
        self.isMidMerge = isMidMerge
        self.isMidCherryPick = isMidCherryPick
        self.stashCount = stashCount
        self.untrackedCount = untrackedCount
        self.unstagedCount = unstagedCount
        self.stagedCount = stagedCount
        self.hasConflicts = hasConflicts
        self.headOID = headOID
        self.rawHead = rawHead
    }
}

/// Resolves every piece of "where am I" state for a repository rooted at `path`.
///
/// Shells out to `git` for each field, using `WorktreeContext` and the
/// `path(for:)` helper to find state files in a way that is correct for
/// linked worktrees and reftable repositories.
public func whereAmI(
    path: String,
    git: GitProcess = GitProcess()
) throws -> WhereAmI {

    // HEAD's raw form: a full SHA or empty. An empty repository has no HEAD
    // yet, so fall back to ""; callers can still check the branch via
    // `symbolic-ref -q`, whose exit code is checked below.
    let rawHead: String = {
        guard let out = try? git.run(
            ["rev-parse", "HEAD"], workingDirectory: path) else { return "" }
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "HEAD" else { return "" }
        return text
    }()

    // Branch: the short ref name if HEAD points at a branch, nil on detached.
    let branch = try git.capture(
        ["symbolic-ref", "-q", "--short", "HEAD"], workingDirectory: path
    )
    let branchName: String? = {
        guard branch.exitCode == 0, !branch.text.isEmpty else { return nil }
        return branch.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    // Upstream via the reflog entry `@{upstream}`. Only resolved when we are
    // on a branch; detached HEADs have no upstream by convention.
    var upstream: String? = nil
    var ahead: Int? = nil
    var behind: Int? = nil
    if branchName != nil {
        let upstreamOut = try git.capture(
            ["rev-parse", "--abbrev-ref", "@{upstream}"], workingDirectory: path
        )
        if upstreamOut.exitCode == 0, !upstreamOut.text.isEmpty {
            upstream = upstreamOut.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // ahead/behind via merge-base against the upstream.
            let abOut = try git.capture(
                ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
                workingDirectory: path
            )
            if abOut.exitCode == 0, let firstTwo = abOut.lines.prefix(2).first {
                // Output is "<ahead> <behind>\n", but the first line may
                // contain both numbers on separated lines, so split by any
                // whitespace and grab two ints.
                let parts = firstTwo.split(omittingEmptySubsequences: true) { $0.isWhitespace }
                if parts.count >= 2,
                   let a = Int(parts[0]), let b = Int(parts[1]) {
                    ahead = a; behind = b
                }
            }
        }
    }

    // Rebase / merge / cherry-pick state. Use `git rev-parse --git-path`
    // so this is correct in a linked worktree (where state lives under
    // $GIT_DIR) and on reftable repositories (where refs/ does not exist).
    let isMidRebase = {
        for name in ["rebase-merge", "rebase-apply"] {
            guard let p = try? git.run(
                ["rev-parse", "--path-format=absolute", "--git-path", name],
                workingDirectory: path
            ), let dir = p.lines.first, !dir.isEmpty else { continue }
            if FileManager.default.fileExists(atPath: dir) { return true }
        }
        return false
    }()

    let mergePath: Bool = {
        guard let out = try? git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD"],
            workingDirectory: path), let p = out.lines.first, !p.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: p)
    }()

    let cherryPath: Bool = {
        guard let out = try? git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "CHERRY_PICK_HEAD"],
            workingDirectory: path), let p = out.lines.first, !p.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: p)
    }()

    // Stash count via `git stash list`. Each line is one entry. Empty output
    // (or a non-zero exit on an old git without stash) means zero. This does
    // not read state files directly, so it is correct in a linked worktree.
    let stashCount: Int = {
        guard let out = try? git.capture(["stash", "list"], workingDirectory: path),
              out.exitCode == 0 else { return 0 }
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? 0 : text.split(separator: "\n").count
    }()

    // Untracked: `ls-files -o --exclude-standard` lists one path per line.
    // We count lines after stripping trailing empty ones, which matches what
    // a caller would see in the status bar.
    let untrackedCount: Int = {
        let out = try! git.capture(
            ["ls-files", "-o", "--exclude-standard"], workingDirectory: path)
        let text = out.text.split(separator: "\n", omittingEmptySubsequences: true)
        return text.count
    }()

    // Unstaged: `diff-index HEAD --name-status` lists entries with unstaged
    // changes, one per line. Each line is a file in modified state.
    let unstagedCount: Int = {
        let out = try! git.capture(
            ["diff-index", "--name-status", "HEAD"], workingDirectory: path)
        let text = out.text.split(separator: "\n", omittingEmptySubsequences: true)
        return text.count
    }()

    // Staged: `diff-index --cached HEAD` lists entries with staged changes.
    let stagedCount: Int = {
        let out = try! git.capture(
            ["diff-index", "--name-status", "--cached", "HEAD"], workingDirectory: path)
        let text = out.text.split(separator: "\n", omittingEmptySubsequences: true)
        return text.count
    }()

    // Conflicts come from `ls-files --unmerged`. An empty output means no
    // conflicts. The entry line format is "<mode> <sha>\t<stage>\t<name>",
    // so a non-empty file means at least one conflict.
    let hasConflicts: Bool = {
        guard let out = try? git.capture(
            ["ls-files", "-u"], workingDirectory: path) else { return false }
        let text = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
    }()

    let shortOID = {
        // `git rev-parse --short HEAD` returns a short hash and canonicalizes.
        guard let out = try? git.run(
            ["rev-parse", "--short=7", "HEAD"], workingDirectory: path),
              let line = out.lines.first, !line.isEmpty else { return "" }
        return line
    }()

    return WhereAmI(
        branch: branchName,
        upstream: upstream,
        ahead: ahead,
        behind: behind,
        isMidRebase: isMidRebase,
        isMidMerge: mergePath,
        isMidCherryPick: cherryPath,
        stashCount: stashCount,
        untrackedCount: untrackedCount,
        unstagedCount: unstagedCount,
        stagedCount: stagedCount,
        hasConflicts: hasConflicts,
        headOID: shortOID,
        rawHead: rawHead
    )
}
