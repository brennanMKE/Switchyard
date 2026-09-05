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
    public static let all: [CommandSpec] = [switchyardSpec, noopSpec, whereamiSpec, statusSpec, conflictsSpec, wtSpec, wtWhereSpec, hunksSpec, logSpec, graphSpec, verifySpec, reviewSpec, askSpec, resolveSpec]

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

    // MARK: - The conflicts spec — engine-backed, resolved by `YardCommands` (#0226)

    static let conflictsSpec = CommandSpec(
        name: "conflicts",
        summary: "Report every conflicted path in the index, with the blob id and mode of each stage.",
        flags: [],
        exitCodes: [
            ExitCodeSpec(code: 0, meaning: "The command completed and returned the conflicted paths."),
            ExitCodeSpec(code: 6, meaning: "The working directory is not inside a git repository."),
        ],
        schemaName: "conflicts",
        // No `payload` shape (#0226): the result is an array of objects, each
        // carrying nested stage entries (`oid`/`mode`), and `PayloadShape` is
        // flat-only (#0194: "nested objects and arrays are not supported ...
        // do not half-build nesting to fit it in here"). Same precedent as
        // `statusSpec` (#0225): the schema carries the self-reference form
        // until array support is its own issue.
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

    /// Look up a `CommandSpec` by its name, returning nil if the spec is not in
    /// the registry. This lets callers (and tests) branch on "do we know it?"
    /// without reaching into `.all`. If a caller wants every spec, they can
    /// still iterate `CommandRegistry.all` — this helper only provides a single lookup.
    public static func lookup(name: String) -> CommandSpec? {
        all.first(where: { $0.name == name })
    }

}
