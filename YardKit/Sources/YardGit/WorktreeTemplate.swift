// WorktreeTemplate.swift — untracked-file setup for fresh worktrees (#0023)

import Foundation

/// The repo-level recipe that makes a fresh worktree usable: which untracked
/// paths to copy or symlink from an existing worktree, and which commands to
/// run afterwards. Stored in the repository at
/// `.switchyard/worktree-template.json`, so it is versioned and every agent
/// and teammate gets the same treatment.
///
/// This type never logs and its reports never carry file contents — entries
/// routinely name secrets (`.env`), and a secret's path is reportable where
/// its bytes are not.
public struct WorktreeTemplate: Sendable, Equatable {

    /// Repo-relative location of the template document.
    public static let configPath = ".switchyard/worktree-template.json"

    /// The one schema version this engine reads.
    public static let schemaVersion = 1

    public enum Action: String, Sendable, Codable, Equatable {
        /// Copy `path` from the source worktree — per-worktree state, such as
        /// an `.env` the agent may edit without affecting siblings.
        case copy
        /// Symlink `path` in the new worktree to the source worktree's copy —
        /// shared caches (`node_modules`, `.venv`) that are expensive to
        /// rebuild and safe to share.
        case symlink
        /// Run `command` with the new worktree as the working directory —
        /// regeneration, `npm install`-shaped work.
        case run
    }

    public struct Entry: Sendable, Codable, Equatable {
        public let action: Action
        /// Repo-relative path, required for `copy` and `symlink`.
        public let path: String?
        /// Shell command, required for `run`.
        public let command: String?

        public init(action: Action, path: String? = nil, command: String? = nil) {
            self.action = action
            self.path = path
            self.command = command
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    // MARK: - Loading

    public enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        /// The file exists but is not valid JSON for the schema.
        case unreadable(path: String, detail: String)
        /// The document's `schemaVersion` is not one this engine reads.
        case unsupportedVersion(Int)
        /// An entry is missing the field its action requires.
        case invalidEntry(index: Int, reason: String)

        public var description: String {
            switch self {
            case let .unreadable(path, detail):
                "could not read worktree template at \(path): \(detail)"
            case let .unsupportedVersion(version):
                "worktree template schemaVersion \(version) is not supported (expected \(WorktreeTemplate.schemaVersion))"
            case let .invalidEntry(index, reason):
                "worktree template entry \(index): \(reason)"
            }
        }
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let entries: [Entry]
    }

    /// Reads the template from a worktree's top level. Nil when the repository
    /// has no template — which is not an error; most repositories will not.
    ///
    /// `worktreeTopLevel` is a working-tree path (`WorktreeContext.topLevel`),
    /// never `$GIT_DIR` — the template is an ordinary versioned file.
    public static func load(fromWorktree worktreeTopLevel: String) throws -> WorktreeTemplate? {
        let url = URL(fileURLWithPath: worktreeTopLevel)
            .appendingPathComponent(configPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(path: configPath, detail: String(describing: error))
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw Failure.unreadable(path: configPath, detail: String(describing: error))
        }
        guard document.schemaVersion == schemaVersion else {
            throw Failure.unsupportedVersion(document.schemaVersion)
        }
        for (index, entry) in document.entries.enumerated() {
            switch entry.action {
            case .copy, .symlink:
                guard let path = entry.path, !path.isEmpty else {
                    throw Failure.invalidEntry(
                        index: index, reason: "\(entry.action.rawValue) requires a path")
                }
            case .run:
                guard let command = entry.command, !command.isEmpty else {
                    throw Failure.invalidEntry(index: index, reason: "run requires a command")
                }
            }
        }
        return WorktreeTemplate(entries: document.entries)
    }

    // MARK: - Applying

    /// What happened to one entry. Warnings leave the worktree usable and the
    /// remaining entries still run; nothing here aborts the creation that
    /// triggered it.
    public struct Report: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            case applied
            /// The source worktree has no item at the entry's path. A warning:
            /// the path may simply not exist yet in the source either.
            case missingSource(String)
            /// The destination already has an item at the entry's path; it is
            /// left untouched rather than overwritten.
            case destinationExists(String)
            /// A `run` command exited non-zero. Carries the exit code and
            /// stderr so the caller can surface why.
            case commandFailed(exitCode: Int32, stderr: String)
            /// A filesystem operation failed.
            case failed(String)
        }

        public let entry: Entry
        public let outcome: Outcome

        public var succeeded: Bool { outcome == .applied }
    }

    /// Applies every entry, in order, from an existing worktree to a fresh
    /// one. Both paths are working-tree top levels. Failures are reported per
    /// entry, never thrown, and never stop the entries after them.
    ///
    /// `shell` exists so tests can inject; the default runs each `run` entry
    /// through `/bin/sh -c` with the destination worktree as its working
    /// directory. It reuses `GitProcess` as the process plumbing because that
    /// is the one type in `YardGit` allowed to construct a `Process` (asserted
    /// by `noOtherEngineSourceConstructsAProcess`), and its environment
    /// already suppresses editors, pagers, and prompts — a template command
    /// must never hang an unattended run.
    public func apply(
        from sourceWorktree: String,
        to destinationWorktree: String,
        shell: GitProcess = GitProcess(executablePath: "/bin/sh")
    ) -> [Report] {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: sourceWorktree)
        let destination = URL(fileURLWithPath: destinationWorktree)

        return entries.map { entry in
            switch entry.action {
            case .copy, .symlink:
                // Validated non-nil by `load`; entries built in code could
                // still omit it, and that is a per-entry failure, not a trap.
                guard let path = entry.path else {
                    return Report(entry: entry, outcome: .failed("entry has no path"))
                }
                let from = source.appendingPathComponent(path)
                let to = destination.appendingPathComponent(path)
                guard fm.fileExists(atPath: from.path) else {
                    return Report(entry: entry, outcome: .missingSource(path))
                }
                // `fileExists` follows symlinks; a dangling link at the
                // destination still occupies the path, so probe with the
                // link-aware attributes call instead.
                if (try? fm.attributesOfItem(atPath: to.path)) != nil {
                    return Report(entry: entry, outcome: .destinationExists(path))
                }
                do {
                    try fm.createDirectory(
                        at: to.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if entry.action == .copy {
                        try fm.copyItem(at: from, to: to)
                    } else {
                        try fm.createSymbolicLink(
                            atPath: to.path, withDestinationPath: from.path)
                    }
                    return Report(entry: entry, outcome: .applied)
                } catch {
                    return Report(entry: entry, outcome: .failed(String(describing: error)))
                }

            case .run:
                guard let command = entry.command else {
                    return Report(entry: entry, outcome: .failed("entry has no command"))
                }
                do {
                    // `sh -c '<script>' <arg0> <arg1>` binds the worktree path
                    // to $0 and the command to $1 — no quoting of either is
                    // needed, and the command runs with the new worktree as
                    // its working directory.
                    let output = try shell.capture(
                        [#"-c"#, #"cd "$0" && eval "$1""#,
                         destinationWorktree, command])
                    guard output.exitCode == 0 else {
                        return Report(entry: entry, outcome: .commandFailed(
                            exitCode: output.exitCode, stderr: output.standardError))
                    }
                    return Report(entry: entry, outcome: .applied)
                } catch {
                    return Report(entry: entry, outcome: .failed(String(describing: error)))
                }
            }
        }
    }
}
