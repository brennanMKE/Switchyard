// CommandRegistry.swift

import Foundation

/// The registry of every `yard` command.
///
/// Pure data: a `static let` containing the `CommandSpec` for every command
/// that `runYard` knows about. No mutable store, no `Atomic`, no global
/// singletons — callers look up a spec by name or iterate `.all` to build
/// help, schema, and tests.
public enum CommandRegistry {

    /// All known `yard` command specifications in the order they should be
    /// rendered in help output.
    public static let all: [CommandSpec] = [switchyardSpec, noopSpec, whereamiSpec, statusSpec]

    // MARK: - The switchyard spec — rendered by `yard --help`

    static let switchyardSpec = CommandSpec(
        name: "switchyard",
        summary: "\(ServiceNames.cliName) CLI — version, help, and command schema.",
        flags: [
            FlagSpec(long: "help", short: "h", argument: nil, help: "Show this help text and exit."),
            FlagSpec(long: "version", short: "v", argument: nil, help: "Print the CLI version and exit."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "Help or version text was printed."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments or unknown subcommand."),
        ],
        schemaName: "switchyard"
    )

    // MARK: - The noop spec — echoes a success envelope.

    static let noopSpec = CommandSpec(
        name: "noop",
        summary: "A no-op command that returns a success envelope.",
        flags: [
            FlagSpec(long: "help", short: "h", argument: nil, help: "Show this command's help and exit."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed successfully."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments or unknown subcommand."),
        ],
        schemaName: "noop"
    )

    // MARK: - The whereami spec — engine-backed, resolved by `YardCommands` (#0124)

    static let whereamiSpec = CommandSpec(
        name: "whereami",
        summary: "Report branch, upstream, ahead/behind, and worktree status in one call.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned repository status."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "whereami",
        payload: PayloadShape(fields: [
            PayloadField(name: "branch", type: .string, optional: true,
                         description: "The branch name, e.g. \"main\". Absent when HEAD is detached."),
            PayloadField(name: "upstream", type: .string, optional: true,
                         description: "The upstream ref, e.g. \"origin/main\". Absent when none is set or on a detached HEAD."),
            PayloadField(name: "ahead", type: .int, optional: true,
                         description: "Number of commits ahead of the upstream. Absent when there is no upstream to compare against."),
            PayloadField(name: "behind", type: .int, optional: true,
                         description: "Number of commits behind the upstream. Absent when there is no upstream to compare against."),
            PayloadField(name: "isMidRebase", type: .bool,
                         description: "True when a rebase is in progress."),
            PayloadField(name: "isMidMerge", type: .bool,
                         description: "True when a merge is in progress."),
            PayloadField(name: "isMidCherryPick", type: .bool,
                         description: "True when a cherry-pick is in progress."),
            PayloadField(name: "stashCount", type: .int,
                         description: "Number of stash entries."),
            PayloadField(name: "untrackedCount", type: .int,
                         description: "Number of untracked files in the working tree."),
            PayloadField(name: "unstagedCount", type: .int,
                         description: "Number of files with unstaged changes."),
            PayloadField(name: "stagedCount", type: .int,
                         description: "Number of files with staged changes."),
            PayloadField(name: "hasConflicts", type: .bool,
                         description: "True when the index contains unmerged (conflicted) entries. Derived from conflictCount."),
            PayloadField(name: "conflictCount", type: .int,
                         description: "Number of paths with unmerged entries in the index — one per conflicted file, regardless of how many stage entries it has."),
            PayloadField(name: "headOID", type: .string,
                         description: "The seven-character short form of HEAD's object id, e.g. \"a1b2c3d\". Not the full SHA — see rawHead for that."),
            PayloadField(name: "rawHead", type: .string,
                         description: "The full form of HEAD's object id, for debugging. A full SHA, or empty on a fresh repository with no commits yet."),
        ])
    )

    // MARK: - The status spec — engine-backed, resolved by `YardCommands` (#0225)

    static let statusSpec = CommandSpec(
        name: "status",
        summary: "Report the per-file worktree status, as `git status --porcelain=v2` sees it.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the worktree status."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "status",
        // No `payload` shape yet (#0225): the result type's only wire key is
        // `entries` — an array of objects — and `PayloadShape` is flat-only
        // (#0194: "nested objects can wait ... do not half-build nesting to
        // fit it in here"). The schema carries the self-reference form until
        // array support is its own issue.
        payload: nil
    )

    /// Look up a `CommandSpec` by its name, returning nil if the spec is not in
    /// the registry. This lets callers (and tests) branch on "do we know it?"
    /// without reaching into `.all`. If a caller wants every spec, they can
    /// still iterate `CommandRegistry.all` — this helper only provides a single lookup.
    public static func lookup(name: String) -> CommandSpec? {
        all.first(where: { $0.name == name })
    }

}
