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
    public static let all: [CommandSpec] = [switchyardSpec, noopSpec, whereamiSpec, statusSpec, conflictsSpec, wtSpec, wtWhereSpec, hunksSpec, logSpec, graphSpec, verifySpec, absorbSpec, splitSpec, rewordSpec, dropSpec, reorderSpec, revertSpec, cherryPickSpec, mergeSpec, rewriteDiffSpec, rerereSpec, reviewSpec, askSpec, resolveSpec, watchSpec, tagSpec, branchSpec, rebaseOntoSpec, setTipSpec]

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
            PayloadField(name: "isMidRevert", type: .bool,
                         description: "True when a revert is in progress."),
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

    // MARK: - The conflicts spec — engine-backed, resolved by `YardCommands` (#0226)

    static let conflictsSpec = CommandSpec(
        name: "conflicts",
        summary: "Report every conflicted path in the index, with the blob id and mode of each stage.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the conflicts surface: the conflicted paths, plus rerereReplayed — the paths where a recorded rerere resolution has been replayed into the working file during the live conflict (#0065)."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "conflicts",
        // No `payload` shape (#0226): the result is an object whose `files`
        // is an array of objects, each carrying nested stage entries
        // (`oid`/`mode`), and `PayloadShape` is flat-only (#0194: "nested
        // objects and arrays are not supported ... do not half-build nesting
        // to fit it in here"). Same precedent as `statusSpec` (#0225): the
        // schema carries the self-reference form until array support is its
        // own issue. #0065 changed the result from the bare array to the
        // object — an object can gain sibling fields additively, a bare
        // array cannot (the reason `statusSpec` got its `entries` object).
        payload: nil
    )

    // MARK: - The wt spec — engine-backed, resolved by `YardCommands` (#0227)

    /// The spec is named `wt`, not `wt list`: `route(_:)` in
    /// `CommandLineRunner.swift` classifies a command line by its **first
    /// token** (`isKnownRemoteCommand(arguments.first)`), so a spec named
    /// "wt list" would be unreachable from the router — `switchyard wt list`
    /// would classify as `.unknown` and be answered "Unknown subcommand"
    /// even though the registry knows it. Naming it `wt` keeps the router
    /// and the registry in agreement for the whole `wt` group; the engine
    /// arm dispatches on the second token (`list` today, `where` in #0228).
    static let wtSpec = CommandSpec(
        name: "wt",
        summary: "Report the repository's worktrees, as `git worktree list --porcelain` sees them.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the worktree list."),
            ExitCodeSpec(code: 1, meaning: "Missing or unknown wt subcommand."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "wt-list",
        // No `payload` shape (#0227): the result is an array of objects with
        // optional fields, and `PayloadShape` is flat-only (#0194: "nested
        // objects and arrays are not supported ... do not half-build nesting
        // to fit it in here"). Same precedent as `statusSpec` (#0225) and
        // `conflictsSpec` (#0226): the schema carries the self-reference form
        // until array support is its own issue.
        payload: nil
    )

    // MARK: - The wt where spec — engine-backed, resolved by `YardCommands` (#0228)

    /// The spec is named `wt where`, distinct from `wt`: the distinct-names
    /// guarantee is what lets `lookup(name:)` hand back this spec's own
    /// schema (`wt-where.json`) instead of `wt`'s. Routing stays safe —
    /// `route(_:)` in `CommandLineRunner.swift` classifies by the **first**
    /// token, and `wt` is already a known command, so `switchyard wt where`
    /// reaches the engine arm regardless of this name; the engine arm
    /// dispatches on the second token beside `list`.
    static let wtWhereSpec = CommandSpec(
        name: "wt where",
        summary: "Report the current worktree's name, path, git dir, common dir, and the main worktree's path.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the worktree context."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "wt-where",
        // No `payload` shape (#0228): the result is a single object whose
        // fields are flat strings/optionals, which `PayloadShape` could
        // express — but the engine commands' established precedent
        // (`statusSpec` #0225, `conflictsSpec` #0226, `wtSpec` #0227) is
        // `payload: nil` with the schema's self-reference form, and no
        // precedent yet supports adding a shape for one command alone.
        // `WorktreeWhereCommandTests` pins the encoded keys instead.
        payload: nil
    )

    // MARK: - The hunks spec — engine-backed, resolved by `YardCommands` (#0345)

    static let hunksSpec = CommandSpec(
        name: "hunks",
        summary: "Report the per-file diff hunks for one area, staged or unstaged.",
        flags: [
            FlagSpec(long: "staged", argument: nil, help: "Diff HEAD against the index, as `git diff --cached` sees it."),
            FlagSpec(long: "unstaged", argument: nil, help: "Diff the index against the worktree."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the hunks."),
            ExitCodeSpec(code: 1, meaning: "The area flag is missing, unknown, or duplicated — pass exactly one of --staged or --unstaged."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "hunks",
        // No `payload` shape (#0345): the result is an array of objects with
        // optional fields and nested hunk arrays, and `PayloadShape` is
        // flat-only (#0194: "nested objects and arrays are not supported ...
        // do not half-build nesting to fit it in here"). Same precedent as
        // `statusSpec` (#0225), `conflictsSpec` (#0226), `wtSpec` (#0227),
        // and `wtWhereSpec` (#0228): the schema carries the self-reference
        // form, and the wire tests pin the encoded keys instead.
        payload: nil
    )

    // MARK: - The log spec — engine-backed, resolved by `YardCommands` (#0346)

    static let logSpec = CommandSpec(
        name: "log",
        summary: "List the commit history reachable from HEAD (or a given range), newest first.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the commit log."),
            ExitCodeSpec(code: 1, meaning: "An option flag was passed; log takes only range arguments, e.g. main..HEAD."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "log",
        // No `payload` shape (#0346): the result is an array of objects with
        // optional fields and nested trailer arrays, and `PayloadShape` is
        // flat-only (#0194: "nested objects and arrays are not supported ...
        // do not half-build nesting to fit it in here"). Same precedent as
        // `statusSpec` (#0225), `conflictsSpec` (#0226), `wtSpec` (#0227),
        // `wtWhereSpec` (#0228), and `hunksSpec` (#0345): the schema carries
        // the self-reference form, and the wire tests pin the encoded keys
        // instead.
        payload: nil
    )

    // MARK: - The graph spec — engine-backed, resolved by `YardCommands` (#0347)

    static let graphSpec = CommandSpec(
        name: "graph",
        summary: "List the commit DAG as lane-assigned rows, one per commit, newest first.",
        flags: [
            FlagSpec(long: "limit", argument: "n", help: "Cap the number of rows, newest first (git rev-list --max-count)."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the graph rows."),
            ExitCodeSpec(code: 1, meaning: "A flag was malformed, unknown, or repeated — the only accepted form is --limit <n> with a positive integer value."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "graph",
        // No `payload` shape (#0347): the result is an array of objects whose
        // `parents` and `parentLanes` are nested arrays, and `PayloadShape`
        // is flat-only (#0194: "nested objects and arrays are not supported
        // ... do not half-build nesting to fit it in here"). Same precedent
        // as `statusSpec` (#0225), `conflictsSpec` (#0226), `wtSpec` (#0227),
        // `wtWhereSpec` (#0228), `hunksSpec` (#0345), and `logSpec` (#0346):
        // the schema carries the self-reference form, and the wire tests pin
        // the encoded keys instead.
        payload: nil
    )

    // MARK: - The verify spec — engine-backed, resolved by `YardCommands` (#0348)

    static let verifySpec = CommandSpec(
        name: "verify",
        summary: "Report git's verification verdict for the signature on one commit (default HEAD).",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the verification verdict. A bad or missing signature is still a completed command — the verdict is in the payload."),
            ExitCodeSpec(code: 1, meaning: "The revision argument is missing, duplicated, or looks like a flag — pass exactly one revision, e.g. verify HEAD."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository, or the revision could not be read."),
        ],
        schemaName: "verify",
        // No `payload` shape (#0348): the result is a single object whose
        // `state` is a nested object (`code`, plus `reason` on one case) with
        // absent-when-nil optionals, and `PayloadShape` is flat-only (#0194:
        // "nested objects and arrays are not supported ... do not half-build
        // nesting to fit it in here"). Same precedent as `statusSpec`
        // (#0225), `conflictsSpec` (#0226), `wtSpec` (#0227), `wtWhereSpec`
        // (#0228), `hunksSpec` (#0345), `logSpec` (#0346), and `graphSpec`
        // (#0347): the schema carries the self-reference form, and the wire
        // tests pin the encoded keys instead.
        payload: nil
    )

    // MARK: - The absorb spec — engine-backed, resolved by `YardCommands` (#0061)

    static let absorbSpec = CommandSpec(
        name: "absorb",
        summary: "Distribute the staged hunks into the commits that last touched their lines.",
        flags: [
            FlagSpec(long: "dry-run", argument: nil, help: "Report the planned distribution without touching anything."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed — hunks were absorbed, or there was nothing to do (nothing staged, no confident hunk, or a --dry-run plan). The payload reports the distribution either way; hunks with no confident target stay staged and are reported, never guessed."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — an unknown or duplicated flag. The only accepted form is an optional --dry-run."),
            ExitCodeSpec(code: 4, meaning: "The absorb could not be completed for a reason the other codes do not name — a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the autosquash rebase could not apply cleanly and is left in progress, resumable."),
        ],
        schemaName: "absorb",
        // No `payload` shape (#0061): the result is per-hunk outcome objects
        // with absent-when-nil optionals, and `PayloadShape` is flat-only
        // (#0194: "nested objects and arrays are not supported ... do not
        // half-build nesting to fit it in here"). Same precedent as
        // `statusSpec` (#0225) through `verifySpec` (#0348): the schema
        // carries the self-reference form, and `AbsorbTests` pins the
        // encoded keys instead.
        payload: nil
    )

    // MARK: - The split spec — engine-backed, resolved by `YardCommands` (#0062)

    static let splitSpec = CommandSpec(
        name: "split",
        summary: "Split one commit into two commits along a hunk boundary.",
        flags: [
            FlagSpec(long: "first", argument: "message", help: "The first half's commit message (default: the original commit's)."),
            FlagSpec(long: "second", argument: "message", help: "The second half's commit message (default: the original commit's)."),
            FlagSpec(long: "sign", argument: nil, help: "Sign both halves and the replayed descendants, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The split completed; the payload carries both new commit oids. The second half's tree equals the original commit's tree, and any descendants were replayed onto the new pair."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — split requires exactly two positional arguments <commit> <hunkID>; an unknown, duplicated, or value-missing flag; or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The split could not be completed for a reason the other codes do not name — an unknown hunk id, a commit with fewer than two hunks, a commit not on the caller's branch, or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the descendant cherry-pick could not apply cleanly and is left in progress, resumable."),
        ],
        schemaName: "split",
        // No `payload` shape (#0062): the result is a single object whose
        // fields are the two new oids, and `PayloadShape` is flat-only
        // (#0194: "nested objects and arrays are not supported ... do not
        // half-build nesting to fit it in here"). Same precedent as
        // `statusSpec` (#0225) through `absorbSpec` (#0061): the schema
        // carries the self-reference form, and the wire tests pin the
        // encoded keys instead.
        payload: nil
    )

    // MARK: - The reword spec — engine-backed, resolved by `YardCommands` (#0063)

    static let rewordSpec = CommandSpec(
        name: "reword",
        summary: "Rewrite one commit's message without invoking an editor.",
        flags: [
            FlagSpec(long: "message", argument: "message", help: "The commit's new message, passed as a flag — GIT_EDITOR is never invoked."),
            FlagSpec(long: "sign", argument: nil, help: "Sign the rebuilt commit and the replayed descendants, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The reword completed; the payload carries the branch's new head oid. The commit was rebuilt with its original tree and parents, and any descendants were replayed onto it."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — reword requires exactly one positional argument <commit> and one --message <message>; an unknown, duplicated, or value-missing flag; or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The reword could not be completed for a reason the other codes do not name — an unknown commit, a commit not on the caller's branch, an already-matching message, or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the descendant cherry-pick could not apply cleanly and is left in progress, resumable."),
        ],
        schemaName: "reword",
        // No `payload` shape (#0063): the result is a single object whose
        // only field is the branch's new head oid — flat and expressible,
        // but the engine commands' established precedent (`statusSpec`
        // #0225 through `splitSpec` #0062) is `payload: nil` with the
        // schema's self-reference form, and the wire tests pin the encoded
        // keys instead.
        payload: nil
    )

    // MARK: - The drop spec — engine-backed, resolved by `YardCommands` (#0063)

    static let dropSpec = CommandSpec(
        name: "drop",
        summary: "Remove one commit from the branch, its changes and all.",
        flags: [
            FlagSpec(long: "sign", argument: nil, help: "Sign the replayed descendants, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The drop completed; the payload carries the branch's new head oid. The commit's changes are gone, and its descendants were replayed onto its parent."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — drop requires exactly one positional argument <commit>; an unknown, duplicated, or value-missing flag (drop takes no --message or --before/--after); or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The drop could not be completed for a reason the other codes do not name — an unknown commit, a commit not on the caller's branch, a merge commit (dropping one would silently lose its second parent), the chain's root, or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the descendant cherry-pick could not apply cleanly and is left in progress, resumable."),
        ],
        schemaName: "drop",
        payload: nil
    )

    // MARK: - The reorder spec — engine-backed, resolved by `YardCommands` (#0063)

    static let reorderSpec = CommandSpec(
        name: "reorder",
        summary: "Move one commit to immediately before or after another commit on the branch.",
        flags: [
            FlagSpec(long: "before", argument: "ref", help: "Move the commit to immediately before this reference commit."),
            FlagSpec(long: "after", argument: "ref", help: "Move the commit to immediately after this reference commit."),
            FlagSpec(long: "sign", argument: nil, help: "Sign the replayed commits, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The reorder completed; the payload carries the branch's new head oid. The commit now sits immediately before or after the reference, and the commits between were replayed in the new order. The branch's final tree is unchanged."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — reorder requires exactly one positional argument <commit> and exactly one of --before <ref> or --after <ref>; an unknown, duplicated, or value-missing flag (reorder takes no --message); or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The reorder could not be completed for a reason the other codes do not name — an unknown commit or reference, a target off the branch's first-parent chain (a cross-branch reorder is a rebase, not a reorder), the chain's root, a commit already at the requested position, or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the replay could not apply cleanly and is left in progress, resumable."),
        ],
        schemaName: "reorder",
        payload: nil
    )

    // MARK: - The revert spec — engine-backed, resolved by `YardCommands` (#0360)

    static let revertSpec = CommandSpec(
        name: "revert",
        summary: "Apply the inverse of one commit to the current branch as a new commit.",
        flags: [
            FlagSpec(long: "sign", argument: nil, help: "Sign the inverse commit, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The revert completed; the payload carries the branch's new head oid — the inverse commit git created, with git's default Revert \"<subject>\" message."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — revert requires exactly one positional argument <commit>; an unknown or duplicated flag (revert takes no --message or --before/--after); or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The revert could not be completed for a reason the other codes do not name — an unknown commit, a merge commit (reverting one needs git's -m parent selection, not offered here), or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the inverse change could not apply cleanly and the revert is left in progress, resumable (REVERT_HEAD and the conflicted stages left in place)."),
        ],
        schemaName: "revert",
        payload: nil
    )

    // MARK: - The cherry-pick spec — engine-backed, resolved by `YardCommands` (#0360)

    static let cherryPickSpec = CommandSpec(
        name: "cherry-pick",
        summary: "Replay one commit from elsewhere onto the current branch as a new commit.",
        flags: [
            FlagSpec(long: "sign", argument: nil, help: "Sign the replayed commit, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The pick completed; the payload carries the branch's new head oid — the replayed commit git created, with the picked commit's own message."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — cherry-pick requires exactly one positional argument <commit>; an unknown or duplicated flag (cherry-pick takes no --message or --before/--after); or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The pick could not be completed for a reason the other codes do not name — an unknown commit, a commit already reachable from the current branch, a merge commit (picking one needs git's -m parent selection, not offered here), or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the commit could not apply cleanly and the pick is left in progress, resumable (CHERRY_PICK_HEAD and the conflicted stages left in place)."),
        ],
        schemaName: "cherry-pick",
    )

    // MARK: - The merge spec — engine-backed, resolved by `YardCommands` (#0361)

    static let mergeSpec = CommandSpec(
        name: "merge",
        summary: "Merge a branch into the current branch, stating the fast-forward intent explicitly.",
        flags: [
            FlagSpec(long: "ff-only", argument: nil, help: "Refuse unless the target can be reached by fast-forward; never creates a merge commit."),
            FlagSpec(long: "no-ff", argument: nil, help: "Always create a merge commit, even when a fast-forward is possible."),
            FlagSpec(long: "message", argument: "message", help: "The merge commit's message, passed as a flag — GIT_EDITOR is never invoked. A fast-forward creates no commit and ignores it."),
            FlagSpec(long: "allow-unrelated", argument: nil, help: "Allow merging histories that share no common ancestor."),
            FlagSpec(long: "sign", argument: nil, help: "Sign the merge commit, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The merge completed; the payload carries the new head oid and whether the merge fast-forwarded. A fast-forward moved the branch straight to the target commit; --no-ff created a merge commit with two parents."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — merge requires exactly one positional argument <branch> and exactly one of --ff-only or --no-ff (git's fast-forward guess is never a default); an unknown, duplicated, or value-missing flag; or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The merge could not be completed for a reason the other codes do not name — an unknown branch, an already-up-to-date target, unrelated histories without --allow-unrelated, a target --ff-only cannot reach, or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries (refused, nothing touched), or the merge itself conflicted and is left in progress, resumable with MERGE_HEAD present."),
        ],
        schemaName: "merge",
        // No `payload` shape (#0361): the result is a single object whose
        // fields are the new head oid and a fast-forward flag — flat and
        // expressible, but the engine commands' established precedent
        // (`statusSpec` #0225 through `reorderSpec` #0063) is `payload: nil`
        // with the schema's self-reference form, and the wire tests pin the
        // encoded keys instead.
    )

    // MARK: - The tag spec — engine-backed, resolved by `YardCommands` (#0363)

    static let tagSpec = CommandSpec(
        name: "tag",
        summary: "Create a lightweight or annotated tag at a commit.",
        flags: [
            FlagSpec(long: "annotate", argument: nil, help: "Create an annotated tag (implied by --message). Requires a message."),
            FlagSpec(long: "message", argument: "message", help: "The tag's message, passed as a flag — implies an annotated tag; GIT_EDITOR is never invoked."),
            FlagSpec(long: "sign", argument: nil, help: "Sign the annotated tag, even when tag.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when tag.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The tag was created; the payload carries the ref, the object it names (the tag object when annotated, the commit when lightweight), and whether it is annotated."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — tag requires exactly two positional arguments <name> <commit>; an unknown, duplicated, or value-missing flag; or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The tag could not be created for a reason the other codes do not name — an invalid name, an existing tag name, a `/`-boundary clash with an existing tag, an unknown commit, a missing message on an annotated tag, a signing intent on a lightweight tag, or a signing failure among them."),
        ],
        schemaName: "tag",
        // No `payload` shape (#0363): the result is a single object whose
        // fields are flat strings and a bool, and the engine commands'
        // established precedent (`statusSpec` #0225 through `reorderSpec`
        // #0063) is `payload: nil` with the schema's self-reference form,
        // and the wire tests pin the encoded keys instead.
        payload: nil
    )

    // MARK: - The branch spec — engine-backed, resolved by `YardCommands` (#0363)

    /// The spec is named `branch`, covering the whole `branch` group: the
    /// engine arm dispatches on the second token (`create`, `rename`,
    /// `delete`, `upstream`), the way `wt` dispatches on `list`/`where`.
    static let branchSpec = CommandSpec(
        name: "branch",
        summary: "Create, rename, or delete a local branch, or set its upstream.",
        flags: [
            FlagSpec(long: "force", argument: nil, help: "With delete: delete an unmerged branch, whose commits would otherwise be lost (the journal records the deletion)."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The operation completed; the payload carries the ref, the branch's tip (for delete, the tip the deleted ref held), and for rename whether HEAD's symref followed, for upstream the upstream's full ref name."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — branch requires create, rename, delete, or upstream with its own positional grammar (create <name> [<start>], rename <old> <new>, delete <name> [--force], upstream <name> <upstream>); an unknown flag is refused too (only delete takes --force)."),
            ExitCodeSpec(code: 4, meaning: "The operation could not be completed for a reason the other codes do not name — an invalid name, an existing name, a `/`-boundary clash, an unknown revision or branch or upstream, deleting the checked-out branch or one a linked worktree holds, or an unmerged branch without --force among them."),
        ],
        schemaName: "branch",
    )

    // MARK: - The rebase-onto spec — engine-backed, resolved by `YardCommands` (#0362)

    static let rebaseOntoSpec = CommandSpec(
        name: "rebase-onto",
        summary: "Replay the current branch's commits onto the named base commit.",
        flags: [
            FlagSpec(long: "sign", argument: nil, help: "Sign the replayed commits, even when commit.gpgsign is false."),
            FlagSpec(long: "no-sign", argument: nil, help: "Never sign, even when commit.gpgsign is true."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The rebase completed; the payload carries the branch's new head oid. The branch's commits after the merge-base with the base were replayed onto the base, and the branch ref moved once at the end. The commits the two lines share keep their original oids."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — rebase-onto requires exactly one positional argument <commit>; an unknown, duplicated, or value-missing flag (rebase-onto takes no --message or --before/--after); or both --sign and --no-sign."),
            ExitCodeSpec(code: 4, meaning: "The rebase could not be completed for a reason the other codes do not name — an unknown base, a detached HEAD, a base that already contains the branch or that the branch is already based on, a base with no common history, or a signing failure among them."),
            ExitCodeSpec(code: 8, meaning: "Blocked on conflicts (blocked_on_conflicts) — the replay could not apply cleanly and is left in progress, resumable."),
        ],
        schemaName: "rebase-onto",
        // No `payload` shape (#0362): the result is a single object whose
        // only field is the branch's new head oid — the same shape as
        // reword/drop/reorder, whose established precedent (#0063) is
        // `payload: nil` with the schema's self-reference form, and the
        // wire tests pin the encoded keys instead.
        payload: nil
    )

    // MARK: - The set-tip spec — engine-backed, resolved by `YardCommands` (#0362)

    static let setTipSpec = CommandSpec(
        name: "set-tip",
        summary: "Move the current branch's tip to the named commit without replaying anything.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The tip was set; the payload carries the branch's new head oid. The branch ref moved transactionally inside one journal checkpoint; the index and working tree were not touched, and yard undo restores the pre-state exactly."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — set-tip requires exactly one positional argument <commit> and takes no flags."),
            ExitCodeSpec(code: 4, meaning: "The tip could not be set for a reason the other codes do not name — an unknown commit, a detached HEAD, a tip that already names the target, or a target no local branch names among them."),
        ],
        schemaName: "set-tip",
        // No `payload` shape (#0362): the result is the same single-oid
        // object the other rewrites produce, and the same precedent applies.
        payload: nil
    )

    // MARK: - The rewrite-diff spec — engine-backed, resolved by `YardCommands` (#0064)

    static let rewriteDiffSpec = CommandSpec(
        name: "rewrite-diff",
        summary: "Compare one journal entry's rewritten commits against their originals with git range-diff.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The diff computed; the payload carries the entry id, which storage shape served the mapping, the ranges compared, and the parsed pair rows (identical, modified, dropped, added). Read-only: nothing was touched."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — rewrite-diff requires exactly one positional argument <journal-entry-id>, a 26-character journal entry id, and takes no flags."),
            ExitCodeSpec(code: 4, meaning: "The diff could not be served — the id names no journal or observed entry, the entry stores no rewrite mapping, git range-diff failed or its output did not parse, or the working directory is not a repository."),
        ],
        schemaName: "rewrite-diff",
        // No `payload` shape (#0064): the result carries a nested `ranges`
        // object and a `rows` array of objects with absent-when-nil sides,
        // and `PayloadShape` is flat-only (#0194: "nested objects and arrays
        // are not supported ... do not half-build nesting to fit it in
        // here"). Same precedent as `statusSpec` (#0225) through
        // `reorderSpec` (#0063): the schema carries the self-reference form,
        // and `RewriteDiffTests` pins the encoded keys instead.
        payload: nil
    )

    // MARK: - The rerere spec — engine-backed, resolved by `YardCommands` (#0065)

    static let rerereSpec = CommandSpec(
        name: "rerere",
        summary: "Report what git rerere has recorded: the repository's recorded conflict resolutions and whether rerere is enabled.",
        flags: [
            FlagSpec(long: "json", argument: nil, help: "Accepted for command-line consistency; the default output is already the JSON envelope payload, so this changes nothing."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The status computed; the payload carries whether rerere is enabled and one entry per recorded or known resolution — its conflict id, the live paths attributed to it, and which of them currently carry the replay. Read-only: no git rerere subcommand is invoked, nothing was touched."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — rerere requires exactly one subcommand, status, and takes at most the --json flag; an unknown subcommand or flag, a bare rerere, or a duplicated --json."),
            ExitCodeSpec(code: 4, meaning: "The status could not be served — the working directory is not a repository, or the rerere state (rr-cache, MERGE_RR) could not be read or parsed."),
        ],
        schemaName: "rerere-status",
        // No `payload` shape (#0065): the result carries an `entries` array
        // of objects with `paths`/`replayedPaths` arrays, and `PayloadShape`
        // is flat-only (#0194). Same precedent as `statusSpec` (#0225)
        // through `rewriteDiffSpec` (#0064): the schema carries the
        // self-reference form, and `RerereTests` pins the encoded keys.
        payload: nil
    )

    // MARK: - The review spec — remote over XPC, answered by `ReviewArm` (#0055)

    /// The spec is named `review`; `dispatch` intercepts it before the
    /// generic `perform` path because the call does not round-trip like a
    /// command — it stays open while the human decides, which the argv-in/
    /// envelope-out shape cannot carry. The engine never runs CLI-side: the
    /// app resolves the diff from the request's range (rounds 2/3), which is
    /// the same layering rule `HookArm` follows.
    static let reviewSpec = CommandSpec(
        name: "review",
        summary: "Push a diff to the app and block until the human decides, returning the decision as structured data.",
        flags: [
            FlagSpec(long: "staged", argument: nil, help: "Review the staged changes (HEAD against the index) instead of a range."),
            FlagSpec(long: "wait", argument: nil, help: "Block until the human decides. Required in this build; a non-blocking form does not exist yet."),
            FlagSpec(long: "timeout", argument: "seconds", help: "Give up the wait after this many seconds (default 3600). On expiry the CLI exits 10 with a typed timeout outcome — never a rejection."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The human approved or amended; the payload is the review reply. Amend is not a rejection — its editedPatch carries the edited patch."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — missing --wait, no selector, both a range and --staged, or a malformed --timeout."),
            ExitCodeSpec(code: 3, meaning: "The Switchyard app is not running. Review never launches the app."),
            ExitCodeSpec(code: 4, meaning: "The request was superseded by a newer review for the same repository, or the app could not serve it — no decision was received."),
            ExitCodeSpec(code: 5, meaning: "The app quit before the human decided — never reported as a decision."),
            ExitCodeSpec(code: 7, meaning: "The human rejected the review; the payload still carries the full reply with ok:true."),
            ExitCodeSpec(code: 10, meaning: "No decision arrived within --timeout — a typed timeout outcome, never a rejection and never an app failure."),
        ],
        schemaName: "review",
        // No `payload` shape (#0055): the result is the review reply — an
        // object whose `comments` is an array of objects — and `PayloadShape`
        // is flat-only (#0194: "nested objects and arrays are not supported
        // ... do not half-build nesting to fit it in here"). Same precedent
        // as `statusSpec` (#0225) through `verifySpec` (#0348): the schema
        // carries the self-reference form, and `ReviewWireTests` pins the
        // encoded keys instead.
        payload: nil
    )

    // MARK: - The ask spec — remote over XPC, answered by `AskArm` (#0056)

    /// The spec is named `ask`; `dispatch` intercepts it before the generic
    /// `perform` path for the same reason it intercepts `review`: the call
    /// stays open while the human decides, which the argv-in/envelope-out
    /// shape cannot carry. The question is positional, the options are a
    /// comma-separated `--options` list presented in the order given. A
    /// second ask for a repository with one already pending queues behind
    /// it rather than replacing it (#0056) — so unlike `reviewSpec` there
    /// is no superseded exit code.
    static let askSpec = CommandSpec(
        name: "ask",
        summary: "Ask the human a question in the app and block until they pick an option, decline, or the wait times out.",
        flags: [
            FlagSpec(long: "options", argument: "a,b,c", help: "The answer options, comma-separated, presented in this order. Required; an empty list or an empty option is a usage refusal."),
            FlagSpec(long: "timeout", argument: "seconds", help: "Give up the wait after this many seconds (default 3600). On expiry the CLI exits 10 with a typed timeout outcome — never a decline. A queued ask's timer starts when it reaches the head of its repository's queue."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The human picked an option; the payload is the ask reply (optionIndex, optionText, optional message)."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — no question, no --options, an empty option in the list, or a malformed --timeout."),
            ExitCodeSpec(code: 3, meaning: "The Switchyard app is not running. Ask never launches the app."),
            ExitCodeSpec(code: 5, meaning: "The app quit before the human decided — never reported as a decision."),
            ExitCodeSpec(code: 7, meaning: "The human declined to answer; the payload still carries the declined reply with ok:true."),
            ExitCodeSpec(code: 10, meaning: "No answer arrived within --timeout — a typed timeout outcome, never a decline and never an app failure."),
        ],
        schemaName: "ask",
        // No `payload` shape (#0056): the result is the ask reply — an
        // object carrying `options`-indexed data — and the command's input
        // options are an array, which `PayloadShape` is flat-only about
        // (#0194: "nested objects and arrays are not supported ... do not
        // half-build nesting to fit it in here"). Same precedent as
        // `statusSpec` (#0225) through `reviewSpec` (#0055): the schema
        // carries the self-reference form, and `AskWireTests` pins the
        // encoded keys instead.
        payload: nil
    )

    // MARK: - The resolve spec — remote over XPC, answered by `ResolveArm` (#0057)

    /// The spec is named `resolve`; `dispatch` intercepts it before the
    /// generic `perform` path for the same reason it intercepts `review` and
    /// `ask`: the call stays open while the human resolves conflicted paths
    /// one card at a time, which the argv-in/envelope-out shape cannot
    /// carry. The optional positional pathspec narrows the conflicts the
    /// sheet presents; a second resolve for the same repository SUPERSEDES
    /// the first (the review semantics, not ask's queue), so unlike
    /// `askSpec` there is a superseded exit code.
    static let resolveSpec = CommandSpec(
        name: "resolve",
        summary: "Open the three-way merge UI for the repository's conflicts and block until the human resolves them, cancels, or the wait times out.",
        flags: [
            FlagSpec(long: "wait", argument: nil, help: "Block until the human resolves or cancels. Required in this build; a non-blocking form does not exist yet."),
            FlagSpec(long: "timeout", argument: "seconds", help: "Give up the wait after this many seconds (default 3600). On expiry the CLI exits 10 with a typed timeout outcome — never a cancellation."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The human resolved every conflicted path; the payload is the resolve reply (per-path resolutions)."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — missing --wait, more than one pathspec, an empty pathspec, or a malformed --timeout."),
            ExitCodeSpec(code: 3, meaning: "The Switchyard app is not running. Resolve never launches the app."),
            ExitCodeSpec(code: 4, meaning: "The request was superseded by a newer resolve for the same repository, or the app could not serve it — no reply was received."),
            ExitCodeSpec(code: 5, meaning: "The app quit before the human decided — never reported as a decision."),
            ExitCodeSpec(code: 7, meaning: "The human cancelled; nothing was staged and nothing was touched; the payload still carries the cancelled reply with ok:true."),
            ExitCodeSpec(code: 8, meaning: "Conflicts remain after the reply (blocked_on_conflicts) — some paths were left unresolved; the payload still carries the reply with ok:true."),
            ExitCodeSpec(code: 10, meaning: "No reply arrived within --timeout — a typed timeout outcome, never a cancellation and never an app failure."),
        ],
        schemaName: "resolve",
        // No `payload` shape (#0057): the result is the resolve reply — an
        // object whose `resolutions` is an array of objects — and
        // `PayloadShape` is flat-only (#0194: "nested objects and arrays are
        // not supported ... do not half-build nesting to fit it in here").
        // Same precedent as `statusSpec` (#0225) through `askSpec` (#0056):
        // the schema carries the self-reference form, and `ResolveWireTests`
        // pins the encoded keys instead.
        payload: nil
    )

    // MARK: - The watch spec — remote over XPC, streamed by `WatchArm` (#0058)

    /// The spec is named `watch`; `dispatch` intercepts it before the
    /// generic `perform` path for the same reason it intercepts `review`,
    /// `ask`, and `resolve` — and here the call also reverses direction
    /// mid-flight: the CLI exports a client the app pushes to, which the
    /// argv-in/envelope-out shape cannot carry. The events ARE the output —
    /// newline-delimited JSON on stdout as each arrives — so unlike every
    /// other command there is no payload shape and no final result envelope
    /// on a clean end; the exit code is the whole end-of-session contract.
    static let watchSpec = CommandSpec(
        name: "watch",
        summary: "Stream repository and app events as newline-delimited JSON until detached.",
        flags: [
            FlagSpec(long: "timeout", argument: "seconds", help: "Detach after this many seconds, exiting 0. Without it the session runs until the CLI detaches (Ctrl-C) or the app ends it."),
        ],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The session ended cleanly — Ctrl-C, the --timeout deadline, or the app's detached/timedOut reply."),
            ExitCodeSpec(code: 1, meaning: "Invalid arguments — a malformed --timeout, an unknown flag, or more than one repository path."),
            ExitCodeSpec(code: 3, meaning: "The Switchyard app is not running. Watch never launches the app."),
            ExitCodeSpec(code: 5, meaning: "The app terminated the session (shutting down) or quit mid-stream — never reported as a detach."),
        ],
        schemaName: "watch",
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
