// HookInstall.swift — install the observer hooks, chaining any existing hook (#0041)

import Foundation

/// The hooks `switchyard hooks install` manages: the two observers the M2
/// journal needs. `reference-transaction` reports every ref update from any
/// tool (#0042); `post-rewrite` supplies the old→new commit mapping nothing
/// else provides (#0043).
public enum ObservedHook: String, CaseIterable, Sendable, Codable {
    case referenceTransaction = "reference-transaction"
    case postRewrite = "post-rewrite"

    /// The `switchyard hook <name>` subcommand the installed script invokes —
    /// guide §6 names `ref-txn`. #0042 and #0043 implement the handlers;
    /// install only writes the script, which guards the invocation with
    /// `command -v`, so the handler (and the binary) need not exist yet.
    public var handlerName: String {
        switch self {
        case .referenceTransaction: "ref-txn"
        case .postRewrite: "post-rewrite"
        }
    }
}

/// Where hooks actually run from, resolved through git, never assembled by
/// hand. `git rev-parse --git-path hooks` honors `core.hooksPath` (measured:
/// an absolute value comes back as-is, a relative one resolves against the
/// worktree top) and resolves to `$GIT_COMMON_DIR/hooks` from a linked
/// worktree — hooks are shared repo-wide, so installing from any worktree
/// installs for all of them.
public struct HooksLocation: Sendable, Equatable {
    /// Absolute path of the effective hooks directory.
    public let directory: String

    /// The raw `core.hooksPath` value when set. The directory is then managed
    /// by another tool (husky, a team config), and writing into it — or into
    /// the silently-dead `$GIT_DIR/hooks` — is exactly the clobbering this
    /// feature exists to avoid.
    public let managedPath: String?

    public var isManaged: Bool { managedPath != nil }

    public init(directory: String, managedPath: String?) {
        self.directory = directory
        self.managedPath = managedPath
    }
}

/// Installs the wrapper scripts for every `ObservedHook`, chaining rather
/// than clobbering anything already there.
///
/// The one place `YardGit` touches hook files with `FileManager`: like the
/// unmerged-index snapshot, the hook file *is* the state, and every path to
/// it comes from `git rev-parse --git-path` via `WorktreeContext`. Nothing
/// here concatenates onto `.git/`.
public enum HookInstall {

    /// A chained-aside previous hook lives beside the wrapper under this
    /// suffix: `reference-transaction.switchyard-chained`. Rename preserves
    /// bytes, mode, and symlink-ness, which is what lets uninstall restore
    /// it exactly.
    public static let chainedSuffix = ".switchyard-chained"

    /// Every script this engine writes starts with exactly these bytes, and
    /// recognition checks only this prefix — version-agnostic on purpose, so
    /// a future v2 script is still recognized as ours rather than chained to.
    public static let markerPrefix = "#!/bin/sh\n# SWITCHYARD-HOOK "

    /// True when the content is a Switchyard-written hook, any version.
    public static func isOurs(_ content: Data) -> Bool {
        String(decoding: content.prefix(64), as: UTF8.self).hasPrefix(markerPrefix)
    }

    /// The wrapper installed as `<hook>`. Measured semantics, git 2.50.1:
    ///
    /// - The chained hook runs first, with the same argv and the same stdin
    ///   (`reference-transaction` and `post-rewrite` both deliver their
    ///   payload on stdin, so it is buffered to a temp file and replayed).
    /// - The chained hook's exit status is the wrapper's exit status. In the
    ///   `prepared` state a non-zero exit aborts the user's transaction —
    ///   `fatal: ref updates aborted by hook`, exit 128, ref not created.
    /// - The `switchyard` handler runs even when the chained hook failed (it
    ///   observes the `aborted` state), and its own failure or absence never
    ///   changes the exit status.
    /// - `$0` is relative (`.git/hooks/…`) when git fires the hook from the
    ///   main worktree and absolute from a linked one; the hook's cwd is the
    ///   invoking worktree's top, so `cd -- "$(dirname -- "$0")" && pwd`
    ///   yields the hooks directory in both cases.
    public static func script(for hook: ObservedHook) -> String {
        """
        #!/bin/sh
        # SWITCHYARD-HOOK v1 \(hook.rawValue)
        # Managed by `switchyard hooks install`; do not edit — edits are
        # overwritten on reinstall, and `switchyard hooks uninstall` removes
        # this file. The hook that was here before install now lives at
        # \(hook.rawValue)\(chainedSuffix), still runs first, and its exit
        # status is still honored.
        hookdir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
        chained="$hookdir/\(hook.rawValue)\(chainedSuffix)"
        payload=$(mktemp) || {
            [ -x "$chained" ] && exec "$chained" "$@"
            exit 0
        }
        cat >"$payload"
        status=0
        if [ -x "$chained" ]; then
            "$chained" "$@" <"$payload" || status=$?
        fi
        if command -v switchyard >/dev/null 2>&1; then
            switchyard hook \(hook.handlerName) "$@" <"$payload" >/dev/null 2>&1 || :
        fi
        rm -f -- "$payload"
        exit "$status"

        """
    }

    // MARK: - Location

    /// Resolves the effective hooks directory and whether `core.hooksPath`
    /// manages it. `git config --get core.hooksPath` exits 1 when unset
    /// (measured), so this uses `capture` and reads the exit code as
    /// information.
    public static func location(
        context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> HooksLocation {
        let base = context.topLevel ?? context.gitDir
        let config = try git.capture(
            ["config", "--get", "core.hooksPath"],
            workingDirectory: base
        )
        let managed = config.exitCode == 0 ? config.lines.first : nil
        let directory = try context.path(for: "hooks", git: git)
        return HooksLocation(directory: directory, managedPath: managed)
    }

    // MARK: - Reports

    public struct Report: Sendable, Equatable {
        public let hook: ObservedHook
        public let outcome: Outcome

        public init(hook: ObservedHook, outcome: Outcome) {
            self.hook = hook
            self.outcome = outcome
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// No hook was present; the script is installed.
        case installed
        /// A foreign hook was present; it moved to the chained name and
        /// still runs first. The script is installed.
        case chained
        /// Ours, byte-identical to the current script. Nothing written.
        case alreadyInstalled
        /// Ours by marker but not byte-identical — an older version, or
        /// hand-edited. Rewritten to the current script; never chained to
        /// itself.
        case refreshed
        /// A foreign hook AND a chained backup both exist, so moving the
        /// hook aside would clobber the backup. Nothing is touched.
        case blockedByExistingBackup
        /// A filesystem operation failed.
        case failed(String)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        /// `core.hooksPath` is set. Hooks in `$GIT_DIR/hooks` are then
        /// completely inert (measured: a failing hook there no longer aborts
        /// anything), and the managed directory belongs to another tool —
        /// possibly checked in, possibly shared across repositories — so
        /// installing anywhere is either dead or a clobber. Switchyard
        /// degrades to polling instead.
        case hooksPathManaged(path: String)

        public var description: String {
            switch self {
            case let .hooksPathManaged(path):
                "core.hooksPath is set to '\(path)': hooks are managed outside "
                    + "the repository, so nothing was installed; Switchyard "
                    + "degrades to polling"
            }
        }
    }

    // MARK: - Installing

    /// Installs every `ObservedHook` into the shared hooks directory.
    /// Per-hook problems are reported, never thrown, and never stop the
    /// hooks after them; the managed-`core.hooksPath` refusal is the one
    /// throw, and it happens before anything is written.
    @discardableResult
    public static func run(
        context: WorktreeContext,
        git: GitProcess = GitProcess()
    ) throws -> [Report] {
        let location = try location(context: context, git: git)
        if let managed = location.managedPath {
            throw Failure.hooksPathManaged(path: managed)
        }
        // A template-less `git init` has no hooks directory at all
        // (measured); creating it is part of installing into it.
        try? FileManager.default.createDirectory(
            atPath: location.directory, withIntermediateDirectories: true)
        return ObservedHook.allCases.map { install($0, in: location.directory) }
    }

    internal static func install(_ hook: ObservedHook, in directory: String) -> Report {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: directory)
        let url = base.appendingPathComponent(hook.rawValue)
        let backup = base.appendingPathComponent(hook.rawValue + chainedSuffix)
        let desired = Data(script(for: hook).utf8)

        // attributesOfItem, not fileExists: fileExists follows symlinks, and
        // a dangling symlink (a removed hook manager) still occupies the
        // path. Same probe as WorktreeTemplate.
        let hookPresent = (try? fm.attributesOfItem(atPath: url.path)) != nil
        let backupPresent = (try? fm.attributesOfItem(atPath: backup.path)) != nil

        do {
            if hookPresent {
                let existing = (try? Data(contentsOf: url)) ?? Data()
                if isOurs(existing) {
                    if existing == desired {
                        return Report(hook: hook, outcome: .alreadyInstalled)
                    }
                    try write(desired, to: url)
                    return Report(hook: hook, outcome: .refreshed)
                }
                guard !backupPresent else {
                    return Report(hook: hook, outcome: .blockedByExistingBackup)
                }
                try fm.moveItem(at: url, to: backup)
                try write(desired, to: url)
                return Report(hook: hook, outcome: .chained)
            }
            try write(desired, to: url)
            return Report(hook: hook, outcome: .installed)
        } catch {
            return Report(hook: hook, outcome: .failed(String(describing: error)))
        }
    }

    /// Writes the script and marks it executable — git ignores a
    /// non-executable hook (measured: `hint: … ignored because it's not set
    /// as executable`), so the mode is part of installing, not a nicety.
    static func write(_ content: Data, to url: URL) throws {
        try content.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

// MARK: - Wire encoding

/// `Report` rides as a JSON array element in a `schemaVersion: 1` envelope
/// `result`, same as `WorktreeTemplate.Report` (#0129, #0138). `ObservedHook`
/// encodes as its raw string.
extension HookInstall.Report: Encodable {
    private enum CodingKeys: String, CodingKey {
        case hook, outcome
    }
}

/// An outcome encodes as `{"code": …}` plus per-case detail (#0129
/// Decision 5). Hand-written: SE-0295 synthesis would emit an object keyed
/// by case name instead.
extension HookInstall.Outcome: Encodable {
    private enum CodingKeys: String, CodingKey {
        case code
        case detail
    }

    /// The stable wire vocabulary, one literal per case. Never replace with
    /// `String(describing: self)`.
    private var wireCode: String {
        switch self {
        case .installed: "installed"
        case .chained: "chained"
        case .alreadyInstalled: "alreadyInstalled"
        case .refreshed: "refreshed"
        case .blockedByExistingBackup: "blockedByExistingBackup"
        case .failed: "failed"
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireCode, forKey: .code)
        if case let .failed(detail) = self {
            try container.encode(detail, forKey: .detail)
        }
    }
}

// MARK: - §6 exit class (#0141)

/// A managed `core.hooksPath` is a repository-state refusal — guide §6
/// code 6.
extension HookInstall.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
