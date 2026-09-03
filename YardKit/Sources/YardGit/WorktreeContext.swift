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

    /// Builds a context directly from already-known values. This exists for
    /// the persistence-restore path (#0083): a tab restored from saved state
    /// must carry its stored identity (`commonDir`) without invoking git --
    /// the repository may not even exist any more, which is the normal case
    /// for torn-down agent worktrees. The values are stored as given: they
    /// are **not** canonicalized and **not** verified. Do not use this where
    /// `resolve(path:)` would work; a fabricated `topLevel` or `worktreeName`
    /// would misreport a repository the engine could have asked git about.
    public init(topLevel: String?, gitDir: String, commonDir: String, worktreeName: String?) {
        self.topLevel = topLevel
        self.gitDir = gitDir
        self.commonDir = commonDir
        self.worktreeName = worktreeName
    }

    // MARK: - Resolution

    /// Resolves the context for a path, which may be the working tree root, any
    /// directory inside it, or a `$GIT_DIR`.
    ///
    /// - Throws: `Error.notARepository` when the path is not in a repository.
    public static func resolve(
        path: String,
        git: GitProcess = GitProcess()
    ) throws -> WorktreeContext {
        // One call per value, not the combined `--git-dir --git-common-dir`
        // call this used to make (#0285). `git rev-parse` has no `-z`
        // (confirmed against git 2.50.1's own help text), so a combined
        // call's two-line output cannot be split apart safely: a newline
        // inside `gitDir` does not just truncate it, it shifts `commonDir`
        // onto the wrong line entirely. A single-value call has no second
        // line to shift onto — whatever the whole output is, minus its one
        // trailing terminator, *is* the value, embedded newlines included.
        //
        // Measured 2026-08-18 (200 iterations, this machine): the combined
        // two-value call ran ~26ms/call; two single-value calls ran
        // ~50ms/call — roughly double, from one extra subprocess. That
        // matters because `resolve` runs on every invocation, but a wrong
        // `-C` for the rest of the engine costs more than 26ms. The other
        // candidate the issue named — sampling `gitDir` and `commonDir` in
        // one instant so they cannot disagree — is given up here in
        // exchange: two calls a few milliseconds apart could in principle
        // observe a repository mutated between them, but that risk is
        // theoretical, and a newline-truncated or line-shifted path is not.
        let gitDirOutput = try git.capture(
            ["rev-parse", "--path-format=absolute", "--git-dir"],
            workingDirectory: path
        )
        guard gitDirOutput.exitCode == 0, let rawGitDir = singleValue(gitDirOutput) else {
            throw Error.notARepository(path: path, detail: gitDirOutput.standardError)
        }
        let commonDirOutput = try git.capture(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            workingDirectory: path
        )
        guard commonDirOutput.exitCode == 0, let rawCommonDir = singleValue(commonDirOutput) else {
            throw Error.notARepository(path: path, detail: commonDirOutput.standardError)
        }
        let gitDir = canonicalize(rawGitDir)
        let commonDir = canonicalize(rawCommonDir)

        // --show-toplevel is asked separately because in a bare repository it
        // *fails* ("this operation must be run in a work tree") rather than
        // printing nothing — which would have failed the combined call and
        // made every bare repo look like "not a repository".
        let top = try git.capture(
            ["rev-parse", "--path-format=absolute", "--show-toplevel"],
            workingDirectory: path
        )
        let topLevel: String? = {
            guard top.exitCode == 0, let line = singleValue(top) else { return nil }
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

    /// Reads a `rev-parse` call's entire stdout as one value, instead of
    /// `.lines.first` splitting it into lines and keeping only the first.
    ///
    /// That split truncates a value that itself contains a newline at the
    /// first line break — a worktree's path is free to contain one, and
    /// this is the exact bug #0285 fixed. Git terminates a single
    /// requested value with exactly one trailing newline, so stripping
    /// only that terminator recovers the value whole no matter what is
    /// inside it.
    ///
    /// This is only sound for a call that requested **one** value. A call
    /// requesting more than one has no newline-safe way to tell the values
    /// apart without `-z`, which `rev-parse` does not support — which is
    /// why `resolve` above makes two single-value calls instead of the one
    /// two-value call it used to.
    private static func singleValue(_ output: GitProcess.Output) -> String? {
        var text = output.text
        guard text.hasSuffix("\n") else { return text.isEmpty ? nil : text }
        text.removeLast()
        return text.isEmpty ? nil : text
    }

    /// Resolves symlinks while **preserving** a leading `/private`.
    ///
    /// `resolvingSymlinksInPath()` is the obvious call and the wrong one: it is
    /// documented to *strip* a leading `/private`, so `/private/var/...` and
    /// `/var/...` become two identities for one path. Git always reports the
    /// resolved form, and `FixtureRepository.url` is `realpath(3)`-resolved for
    /// the same reason, so this must agree with both.
    ///
    /// `realpath(3)` returns nil for a path that does not exist. The fallback
    /// therefore resolves the deepest existing ancestor and re-appends the rest,
    /// so a not-yet-created path still canonicalizes consistently with a created
    /// one — a plain `standardizedFileURL` would silently leave `/tmp/x` as
    /// `/tmp/x` while `/tmp` alone resolved to `/private/tmp`.
    static func canonicalize(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(validatingCString: resolved) ?? path
        }

        // Walk up to the deepest ancestor that exists, resolve that, and put the
        // missing tail back on.
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while url.path != "/" {
            if let resolved = realpath(url.path, nil) {
                defer { free(resolved) }
                let base = String(validatingCString: resolved) ?? url.path
                return tail.reversed().reduce(URL(fileURLWithPath: base)) {
                    $0.appendingPathComponent($1)
                }.path
            }
            tail.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
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
        guard let first = Self.singleValue(out) else {
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
    /// The prefix addresses **per-worktree** refs only — `HEAD`, and anything
    /// under `refs/bisect/`, `refs/worktree/`, or `refs/rewritten/`. Everything
    /// else is shared and resolves under its plain name; prefixing it returns
    /// nothing.
    ///
    /// `git rev-parse worktrees/agent-a/HEAD` is the supported way to answer
    /// "what is agent A on right now" — no path games required.
    public static func refName(_ ref: String, inWorktree worktree: String?) -> String {
        guard let worktree else { return "main-worktree/\(ref)" }
        return "worktrees/\(worktree)/\(ref)"
    }

    /// Returns true when the ref lives in a worktree's private ref namespace,
    /// i.e. `HEAD` or anything under `refs/bisect/`, `refs/worktree/`, or
    /// `refs/rewritten/`. Everything else is shared and visible from every
    /// worktree under its plain name.
    public static func isPerWorktree(_ ref: String) -> Bool {
        if ref == "HEAD" { return true }
        let prefixes = ["refs/bisect/", "refs/worktree/", "refs/rewritten/"]
        return prefixes.contains(where: { ref.hasPrefix($0) })
    }

    /// Resolves a ref from another worktree (per-worktree refs use the
    /// `main-worktree/` or `worktrees/<name>/` prefix) to an object id.
    /// Returns nil when the ref does not exist.
    public func resolveRef(
        _ ref: String,
        inWorktree worktree: String?,
        git: GitProcess = GitProcess()
    ) throws -> String? {
        let name: String
        if Self.isPerWorktree(ref) {
            name = Self.refName(ref, inWorktree: worktree)
        } else {
            name = ref
        }
        let base = topLevel ?? gitDir
        let out = try git.capture(["rev-parse", "--verify", "--quiet", name],
                                  workingDirectory: base)
        guard out.exitCode == 0, let line = Self.singleValue(out) else { return nil }
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

// MARK: - §6 exit class (#0141)

/// Both cases are repository-state failures — the path is not a repository,
/// or git could not resolve a repo-relative path — guide §6 code 6.
extension WorktreeContext.Error: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
