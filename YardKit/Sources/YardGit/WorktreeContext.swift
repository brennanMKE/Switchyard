// WorktreeContext.swift

import Foundation

/// Where a repository actually keeps its state, resolved once per invocation.
///
/// Every path lookup in the engine goes through this type. Nothing anywhere
/// concatenates onto `.git/` — reftable, index format variants, and worktrees
/// each break naive path construction independently, and which of `$GIT_DIR`
/// or `$GIT_COMMON_DIR` applies depends on the ref name, so it cannot be
/// guessed.
///
/// In a linked worktree, `.git` is a *file* containing a `gitdir:` pointer,
/// `$GIT_DIR` is `<main>/.git/worktrees/<name>`, and `$GIT_COMMON_DIR` is
/// `<main>/.git`. In the main worktree the two are the same directory.
public struct WorktreeContext: Sendable, Equatable {

    /// Root of the working tree. Nil for a bare repository.
    public let topLevel: String?

    /// `$GIT_DIR` — per-worktree state: `HEAD`, the index, sequencer state.
    public let gitDir: String

    /// `$GIT_COMMON_DIR` — shared state: `refs/`, the object database, config.
    /// **This is a repository's identity**, and the app keys repository tabs
    /// on it so a worktree resolves to its parent repository (#0079).
    public let commonDir: String

    /// Worktree name as git knows it, i.e. the directory under
    /// `$GIT_COMMON_DIR/worktrees/`. Nil for the main worktree.
    public let worktreeName: String?

    /// True when `$GIT_DIR` and `$GIT_COMMON_DIR` differ.
    public var isLinkedWorktree: Bool { worktreeName != nil }

    /// True when there is no working tree.
    public var isBare: Bool { topLevel == nil }

    // MARK: - Resolution

    /// Resolves the context for a path, which may be the working tree root, any
    /// directory inside it, or a `$GIT_DIR`.
    ///
    /// - Throws: `Error.notARepository` when the path is not in a repository.
    public static func resolve(
        path: String,
        git: GitProcess = GitProcess()
    ) throws -> WorktreeContext {
        // The two directories come from one invocation so they cannot
        // disagree by being sampled at different moments.
        let dirs = try git.capture(
            ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
            workingDirectory: path
        )
        guard dirs.exitCode == 0, dirs.lines.count >= 2 else {
            throw Error.notARepository(path: path, detail: dirs.standardError)
        }
        let gitDir = canonicalize(dirs.lines[0])
        let commonDir = canonicalize(dirs.lines[1])

        // --show-toplevel is asked separately because in a bare repository it
        // *fails* ("this operation must be run in a work tree") rather than
        // printing nothing — which would have failed the combined call and
        // made every bare repo look like "not a repository".
        let top = try git.capture(
            ["rev-parse", "--path-format=absolute", "--show-toplevel"],
            workingDirectory: path
        )
        let topLevel: String? = {
            guard top.exitCode == 0, let line = top.lines.first, !line.isEmpty else { return nil }
            return canonicalize(line)
        }()

        // A linked worktree's $GIT_DIR is <common>/worktrees/<name>. Derive the
        // name from that relationship rather than by parsing a path shape.
        var worktreeName: String?
        if gitDir != commonDir {
            let marker = "/worktrees/"
            if let range = gitDir.range(of: marker, options: .backwards) {
                let tail = String(gitDir[range.upperBound...])
                worktreeName = tail.isEmpty ? nil : tail
            }
        }

        return WorktreeContext(
            topLevel: topLevel,
            gitDir: gitDir,
            commonDir: commonDir,
            worktreeName: worktreeName
        )
    }

    /// Resolves symlinks and standardizes, so `/tmp` and `/private/tmp` — and a
    /// symlinked checkout — do not produce two identities for one repository.
    /// The app depends on this for tab de-duplication (#0079).
    static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Path lookup

    /// Resolves a git path the way git resolves it, choosing `$GIT_DIR` or
    /// `$GIT_COMMON_DIR` correctly for the name given.
    ///
    /// Always prefer this over building a path by hand. `HEAD` is per-worktree;
    /// `refs/heads/main` is shared; `refs/bisect/*`, `refs/worktree/*`, and
    /// `refs/rewritten/*` are per-worktree despite starting with `refs/`.
    public func path(for name: String, git: GitProcess = GitProcess()) throws -> String {
        let base = topLevel ?? gitDir
        let out = try git.run(["rev-parse", "--path-format=absolute", "--git-path", name],
                              workingDirectory: base)
        guard let first = out.lines.first, !first.isEmpty else {
            throw Error.pathNotResolved(name: name)
        }
        // Canonicalized so it compares against gitDir/commonDir, which are.
        // /var and /private/var are the same directory and must not read as
        // different ones.
        return Self.canonicalize(first)
    }

    /// Names the per-worktree ref of another worktree, using git's special
    /// `main-worktree/` and `worktrees/<name>/` prefixes.
    ///
    /// `git rev-parse worktrees/agent-a/HEAD` is the supported way to answer
    /// "what is agent A on right now" — no path games required.
    public static func refName(_ ref: String, inWorktree worktree: String?) -> String {
        guard let worktree else { return "main-worktree/\(ref)" }
        return "worktrees/\(worktree)/\(ref)"
    }

    /// Resolves another worktree's per-worktree ref to an object id.
    /// Returns nil when the ref does not exist.
    public func resolveRef(
        _ ref: String,
        inWorktree worktree: String?,
        git: GitProcess = GitProcess()
    ) throws -> String? {
        let name = Self.refName(ref, inWorktree: worktree)
        let base = topLevel ?? gitDir
        let out = try git.capture(["rev-parse", "--verify", "--quiet", name],
                                  workingDirectory: base)
        guard out.exitCode == 0, let line = out.lines.first, !line.isEmpty else { return nil }
        return line
    }

    // MARK: - Errors

    public enum Error: Swift.Error, CustomStringConvertible, Sendable {
        case notARepository(path: String, detail: String)
        case pathNotResolved(name: String)

        public var description: String {
            switch self {
            case let .notARepository(path, detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return "not a git repository: \(path)" + (trimmed.isEmpty ? "" : " (\(trimmed))")
            case let .pathNotResolved(name):
                return "could not resolve git path: \(name)"
            }
        }
    }
}
