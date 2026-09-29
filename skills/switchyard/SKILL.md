---
name: switchyard
description: Drive the Switchyard git client from the shell with the `switchyard` CLI. Read repository state as JSON (whereami, status, log, graph, hunks, conflicts), rewrite local history without an editor (reword, drop, reorder, split, absorb, rebase-onto), and hand decisions to the human in the Switchyard app (review, ask, resolve). Use in a git repository on a Mac with Switchyard.app installed, instead of raw git for these operations.
---

# switchyard

`switchyard` is the command-line companion to Switchyard.app, a macOS git client. The app owns the repository engine; the CLI sends each command to it and prints the reply. Every rewrite it performs is recorded in the app's journal, so the human can undo it from the app. `switchyard skill` prints this document.

## Before you start

- Run commands from inside the repository's working tree: the repository is the one containing the current directory. Outside a repository, commands exit 6.
- Most commands launch Switchyard.app if it is not running. `review`, `ask`, `resolve` and `watch` never launch it: they need a human already at the app, and exit 3 without one. Treat exit 3 from those as "no human available" — do not proceed as if approved.
- A command's stdout is exactly one JSON envelope. The exceptions are `--help`, `--version` and `switchyard skill`, which print text, and `watch`, which streams one JSON object per line. Parse `ok` and the exit code; do not scrape the human-readable stderr line.
- Nothing is interactive. No editor or pager ever opens; messages are passed as flags.
- Undo is not a CLI command in this build. A rewrite that went wrong is undone by the human from the app's Edit menu.

## Workflows

### Orient yourself

```sh
switchyard whereami
switchyard status
switchyard log main..HEAD
```

`whereami` answers branch, upstream, ahead/behind, and whether a rebase, merge, cherry-pick or revert is in progress, in one call. Check `isMidRebase`, `isMidMerge` and `hasConflicts` before starting any rewrite.

### Clean up a branch before review

```sh
switchyard reword HEAD~2 --message "Explain the parser change"
switchyard drop HEAD~1
switchyard reorder HEAD --before HEAD~2
switchyard absorb --dry-run
```

Each rewrite is recorded in the app's journal, so the human can undo it. `absorb --dry-run` reports where staged hunks would go without touching anything; run it before `absorb`.

### When a command exits 8

Exit 8 (`blocked_on_conflicts`) means the operation stopped with conflicts and is left in progress. Do not start another rewrite. Either list them and resolve the files yourself:

```sh
switchyard conflicts
```

or hand them to the human and wait:

```sh
switchyard resolve --wait --timeout 1800
```

### Ask the human instead of guessing

```sh
switchyard review --staged --wait
switchyard ask "Squash the fixups before pushing?" --options yes,no
```

`review` exits 0 on approve or amend and 7 on reject; `ask` exits 0 with the chosen option (`optionIndex`, `optionText`) and 7 when the human declines. Both exit 10 when `--timeout` expires, which is neither a yes nor a no.

<!-- BEGIN GENERATED from CommandRegistry.all — edit YardKit/Sources/YardKit/CommandRegistry.swift, then run scripts/generate-skill.sh -->

## Command reference

Every command prints one JSON envelope on stdout: `{"schemaVersion":1,"ok":true,"result":…}` on success, `{"schemaVersion":1,"ok":false,"error":{"code":…,"message":…,"hint":…}}` on failure. `--json` is accepted anywhere and changes nothing. `switchyard schema` prints the full JSON Schema for every command.

### `switchyard`

switchyard CLI — version, help, and command schema.

Usage: `switchyard [--help | --version | <command> [<arguments>]]`

| Flag | Meaning |
|---|---|
| `-h, --help` | Show this help text and exit. |
| `-v, --version` | Print the CLI version and exit. |

| Exit | Meaning |
|---|---|
| 0 | Help or version text was printed. |
| 1 | Invalid arguments or unknown subcommand. |

### `switchyard noop`

A no-op command that returns a success envelope.

Usage: `switchyard noop [--help]`

| Flag | Meaning |
|---|---|
| `-h, --help` | Show this command's help and exit. |

| Exit | Meaning |
|---|---|
| 0 | The command completed successfully. |
| 1 | Invalid arguments or unknown subcommand. |

### `switchyard skill`

Print the agent skill, skills/switchyard/SKILL.md, as markdown. Needs no app and no repository.

Usage: `switchyard skill`

| Exit | Meaning |
|---|---|
| 0 | The skill markdown was printed. |
| 1 | Invalid arguments — skill takes no arguments. |

### `switchyard whereami`

Report branch, upstream, ahead/behind, and worktree status in one call.

Usage: `switchyard whereami`

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned repository status. |
| 6 | The working directory is not inside a git repository. |

| Result field | Type | Meaning |
|---|---|---|
| `ahead` | int, optional | Number of commits ahead of the upstream. Absent when there is no upstream to compare against. |
| `behind` | int, optional | Number of commits behind the upstream. Absent when there is no upstream to compare against. |
| `branch` | string, optional | The branch name, e.g. "main". Absent when HEAD is detached. |
| `conflictCount` | int | Number of paths with unmerged entries in the index — one per conflicted file, regardless of how many stage entries it has. |
| `hasConflicts` | bool | True when the index contains unmerged (conflicted) entries. Derived from conflictCount. |
| `headOID` | string | The seven-character short form of HEAD's object id, e.g. "a1b2c3d". Not the full SHA — see rawHead for that. |
| `isMidCherryPick` | bool | True when a cherry-pick is in progress. |
| `isMidMerge` | bool | True when a merge is in progress. |
| `isMidRebase` | bool | True when a rebase is in progress. |
| `isMidRevert` | bool | True when a revert is in progress. |
| `rawHead` | string | The full form of HEAD's object id, for debugging. A full SHA, or empty on a fresh repository with no commits yet. |
| `stagedCount` | int | Number of files with staged changes. |
| `stashCount` | int | Number of stash entries. |
| `unstagedCount` | int | Number of files with unstaged changes. |
| `untrackedCount` | int | Number of untracked files in the working tree. |
| `upstream` | string, optional | The upstream ref, e.g. "origin/main". Absent when none is set or on a detached HEAD. |

### `switchyard status`

Report the per-file worktree status, as `git status --porcelain=v2` sees it.

Usage: `switchyard status`

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the worktree status. |
| 6 | The working directory is not inside a git repository. |

### `switchyard conflicts`

Report every conflicted path in the index, with the blob id and mode of each stage.

Usage: `switchyard conflicts`

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the conflicts surface: the conflicted paths, plus rerereReplayed — the paths where a recorded rerere resolution has been replayed into the working file during the live conflict (#0065). |
| 6 | The working directory is not inside a git repository. |

### `switchyard wt`

Report the repository's worktrees, as `git worktree list --porcelain` sees them.

Usage: `switchyard wt list`

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the worktree list. |
| 1 | Missing or unknown wt subcommand. |
| 6 | The working directory is not inside a git repository. |

### `switchyard wt where`

Report the current worktree's name, path, git dir, common dir, and the main worktree's path.

Usage: `switchyard wt where`

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the worktree context. |
| 6 | The working directory is not inside a git repository. |

### `switchyard hunks`

Report the per-file diff hunks for one area, staged or unstaged.

Usage: `switchyard hunks (--staged | --unstaged)`

| Flag | Meaning |
|---|---|
| `--staged` | Diff HEAD against the index, as `git diff --cached` sees it. |
| `--unstaged` | Diff the index against the worktree. |

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the hunks. |
| 1 | The area flag is missing, unknown, or duplicated — pass exactly one of --staged or --unstaged. |
| 6 | The working directory is not inside a git repository. |

### `switchyard log`

List the commit history reachable from HEAD (or a given range), newest first.

Usage: `switchyard log [<range>...]`

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the commit log. |
| 1 | An option flag was passed; log takes only range arguments, e.g. main..HEAD. |
| 6 | The working directory is not inside a git repository. |

### `switchyard graph`

List the commit DAG as lane-assigned rows, one per commit, newest first.

Usage: `switchyard graph [--limit <n>]`

| Flag | Meaning |
|---|---|
| `--limit <n>` | Cap the number of rows, newest first (git rev-list --max-count). |

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the graph rows. |
| 1 | A flag was malformed, unknown, or repeated — the only accepted form is --limit <n> with a positive integer value. |
| 6 | The working directory is not inside a git repository. |

### `switchyard verify`

Report git's verification verdict for the signature on one commit (default HEAD).

Usage: `switchyard verify <revision>`

| Exit | Meaning |
|---|---|
| 0 | The command completed and returned the verification verdict. A bad or missing signature is still a completed command — the verdict is in the payload. |
| 1 | The revision argument is missing, duplicated, or looks like a flag — pass exactly one revision, e.g. verify HEAD. |
| 6 | The working directory is not inside a git repository, or the revision could not be read. |

### `switchyard absorb`

Distribute the staged hunks into the commits that last touched their lines.

Usage: `switchyard absorb [--dry-run]`

| Flag | Meaning |
|---|---|
| `--dry-run` | Report the planned distribution without touching anything. |

| Exit | Meaning |
|---|---|
| 0 | The command completed — hunks were absorbed, or there was nothing to do (nothing staged, no confident hunk, or a --dry-run plan). The payload reports the distribution either way; hunks with no confident target stay staged and are reported, never guessed. |
| 1 | Invalid arguments — an unknown or duplicated flag. The only accepted form is an optional --dry-run. |
| 4 | The absorb could not be completed for a reason the other codes do not name — a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the autosquash rebase could not apply cleanly and is left in progress, resumable. |

### `switchyard split`

Split one commit into two commits along a hunk boundary.

Usage: `switchyard split <commit> <hunkID> [--first <message>] [--second <message>] [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--first <message>` | The first half's commit message (default: the original commit's). |
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--second <message>` | The second half's commit message (default: the original commit's). |
| `--sign` | Sign both halves and the replayed descendants, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The split completed; the payload carries both new commit oids. The second half's tree equals the original commit's tree, and any descendants were replayed onto the new pair. |
| 1 | Invalid arguments — split requires exactly two positional arguments <commit> <hunkID>; an unknown, duplicated, or value-missing flag; or both --sign and --no-sign. |
| 4 | The split could not be completed for a reason the other codes do not name — an unknown hunk id, a commit with fewer than two hunks, a commit not on the caller's branch, or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the descendant cherry-pick could not apply cleanly and is left in progress, resumable. |

### `switchyard reword`

Rewrite one commit's message without invoking an editor.

Usage: `switchyard reword <commit> --message <message> [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--message <message>` | The commit's new message, passed as a flag — GIT_EDITOR is never invoked. |
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the rebuilt commit and the replayed descendants, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The reword completed; the payload carries the branch's new head oid. The commit was rebuilt with its original tree and parents, and any descendants were replayed onto it. |
| 1 | Invalid arguments — reword requires exactly one positional argument <commit> and one --message <message>; an unknown, duplicated, or value-missing flag; or both --sign and --no-sign. |
| 4 | The reword could not be completed for a reason the other codes do not name — an unknown commit, a commit not on the caller's branch, an already-matching message, or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the descendant cherry-pick could not apply cleanly and is left in progress, resumable. |

### `switchyard drop`

Remove one commit from the branch, its changes and all.

Usage: `switchyard drop <commit> [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the replayed descendants, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The drop completed; the payload carries the branch's new head oid. The commit's changes are gone, and its descendants were replayed onto its parent. |
| 1 | Invalid arguments — drop requires exactly one positional argument <commit>; an unknown, duplicated, or value-missing flag (drop takes no --message or --before/--after); or both --sign and --no-sign. |
| 4 | The drop could not be completed for a reason the other codes do not name — an unknown commit, a commit not on the caller's branch, a merge commit (dropping one would silently lose its second parent), the chain's root, or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the descendant cherry-pick could not apply cleanly and is left in progress, resumable. |

### `switchyard reorder`

Move one commit to immediately before or after another commit on the branch.

Usage: `switchyard reorder <commit> (--before <ref> | --after <ref>) [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--after <ref>` | Move the commit to immediately after this reference commit. |
| `--before <ref>` | Move the commit to immediately before this reference commit. |
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the replayed commits, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The reorder completed; the payload carries the branch's new head oid. The commit now sits immediately before or after the reference, and the commits between were replayed in the new order. The branch's final tree is unchanged. |
| 1 | Invalid arguments — reorder requires exactly one positional argument <commit> and exactly one of --before <ref> or --after <ref>; an unknown, duplicated, or value-missing flag (reorder takes no --message); or both --sign and --no-sign. |
| 4 | The reorder could not be completed for a reason the other codes do not name — an unknown commit or reference, a target off the branch's first-parent chain (a cross-branch reorder is a rebase, not a reorder), the chain's root, a commit already at the requested position, or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the replay could not apply cleanly and is left in progress, resumable. |

### `switchyard revert`

Apply the inverse of one commit to the current branch as a new commit.

Usage: `switchyard revert <commit> [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the inverse commit, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The revert completed; the payload carries the branch's new head oid — the inverse commit git created, with git's default Revert "<subject>" message. |
| 1 | Invalid arguments — revert requires exactly one positional argument <commit>; an unknown or duplicated flag (revert takes no --message or --before/--after); or both --sign and --no-sign. |
| 4 | The revert could not be completed for a reason the other codes do not name — an unknown commit, a merge commit (reverting one needs git's -m parent selection, not offered here), or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the inverse change could not apply cleanly and the revert is left in progress, resumable (REVERT_HEAD and the conflicted stages left in place). |

### `switchyard cherry-pick`

Replay one commit from elsewhere onto the current branch as a new commit.

Usage: `switchyard cherry-pick <commit> [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the replayed commit, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The pick completed; the payload carries the branch's new head oid — the replayed commit git created, with the picked commit's own message. |
| 1 | Invalid arguments — cherry-pick requires exactly one positional argument <commit>; an unknown or duplicated flag (cherry-pick takes no --message or --before/--after); or both --sign and --no-sign. |
| 4 | The pick could not be completed for a reason the other codes do not name — an unknown commit, a commit already reachable from the current branch, a merge commit (picking one needs git's -m parent selection, not offered here), or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries, or the commit could not apply cleanly and the pick is left in progress, resumable (CHERRY_PICK_HEAD and the conflicted stages left in place). |

### `switchyard merge`

Merge a branch into the current branch, stating the fast-forward intent explicitly.

Usage: `switchyard merge <branch> (--ff-only | --no-ff) [--message <message>] [--allow-unrelated] [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--allow-unrelated` | Allow merging histories that share no common ancestor. |
| `--ff-only` | Refuse unless the target can be reached by fast-forward; never creates a merge commit. |
| `--message <message>` | The merge commit's message, passed as a flag — GIT_EDITOR is never invoked. A fast-forward creates no commit and ignores it. |
| `--no-ff` | Always create a merge commit, even when a fast-forward is possible. |
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the merge commit, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The merge completed; the payload carries the new head oid and whether the merge fast-forwarded. A fast-forward moved the branch straight to the target commit; --no-ff created a merge commit with two parents. |
| 1 | Invalid arguments — merge requires exactly one positional argument <branch> and exactly one of --ff-only or --no-ff (git's fast-forward guess is never a default); an unknown, duplicated, or value-missing flag; or both --sign and --no-sign. |
| 4 | The merge could not be completed for a reason the other codes do not name — an unknown branch, an already-up-to-date target, unrelated histories without --allow-unrelated, a target --ff-only cannot reach, or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the index already held unmerged entries (refused, nothing touched), or the merge itself conflicted and is left in progress, resumable with MERGE_HEAD present. |

### `switchyard rewrite-diff`

Compare one journal entry's rewritten commits against their originals with git range-diff.

Usage: `switchyard rewrite-diff <journal-entry-id>`

| Exit | Meaning |
|---|---|
| 0 | The diff computed; the payload carries the entry id, which storage shape served the mapping, the ranges compared, and the parsed pair rows (identical, modified, dropped, added). Read-only: nothing was touched. |
| 1 | Invalid arguments — rewrite-diff requires exactly one positional argument <journal-entry-id>, a 26-character journal entry id, and takes no flags. |
| 4 | The diff could not be served — the id names no journal or observed entry, the entry stores no rewrite mapping, git range-diff failed or its output did not parse, or the working directory is not a repository. |

### `switchyard rerere`

Report what git rerere has recorded: the repository's recorded conflict resolutions and whether rerere is enabled.

Usage: `switchyard rerere status [--json]`

| Flag | Meaning |
|---|---|
| `--json` | Accepted for command-line consistency; the default output is already the JSON envelope payload, so this changes nothing. |

| Exit | Meaning |
|---|---|
| 0 | The status computed; the payload carries whether rerere is enabled and one entry per recorded or known resolution — its conflict id, the live paths attributed to it, and which of them currently carry the replay. Read-only: no git rerere subcommand is invoked, nothing was touched. |
| 1 | Invalid arguments — rerere requires exactly one subcommand, status, and takes at most the --json flag; an unknown subcommand or flag, a bare rerere, or a duplicated --json. |
| 4 | The status could not be served — the working directory is not a repository, or the rerere state (rr-cache, MERGE_RR) could not be read or parsed. |

### `switchyard review`

Push a diff to the app and block until the human decides, returning the decision as structured data.

Usage: `switchyard review (<range> | --staged) --wait [--timeout <seconds>]`

| Flag | Meaning |
|---|---|
| `--staged` | Review the staged changes (HEAD against the index) instead of a range. |
| `--timeout <seconds>` | Give up the wait after this many seconds (default 3600). On expiry the CLI exits 10 with a typed timeout outcome — never a rejection. |
| `--wait` | Block until the human decides. Required in this build; a non-blocking form does not exist yet. |

| Exit | Meaning |
|---|---|
| 0 | The human approved or amended; the payload is the review reply. Amend is not a rejection — its editedPatch carries the edited patch. |
| 1 | Invalid arguments — missing --wait, no selector, both a range and --staged, or a malformed --timeout. |
| 3 | The Switchyard app is not running. Review never launches the app. |
| 4 | The request was superseded by a newer review for the same repository, or the app could not serve it — no decision was received. |
| 5 | The app quit before the human decided — never reported as a decision. |
| 7 | The human rejected the review; the payload still carries the full reply with ok:true. |
| 10 | No decision arrived within --timeout — a typed timeout outcome, never a rejection and never an app failure. |

### `switchyard ask`

Ask the human a question in the app and block until they pick an option, decline, or the wait times out.

Usage: `switchyard ask <question> --options <a,b,c> [--timeout <seconds>]`

| Flag | Meaning |
|---|---|
| `--options <a,b,c>` | The answer options, comma-separated, presented in this order. Required; an empty list or an empty option is a usage refusal. |
| `--timeout <seconds>` | Give up the wait after this many seconds (default 3600). On expiry the CLI exits 10 with a typed timeout outcome — never a decline. A queued ask's timer starts when it reaches the head of its repository's queue. |

| Exit | Meaning |
|---|---|
| 0 | The human picked an option; the payload is the ask reply (optionIndex, optionText, optional message). |
| 1 | Invalid arguments — no question, no --options, an empty option in the list, or a malformed --timeout. |
| 3 | The Switchyard app is not running. Ask never launches the app. |
| 5 | The app quit before the human decided — never reported as a decision. |
| 7 | The human declined to answer; the payload still carries the declined reply with ok:true. |
| 10 | No answer arrived within --timeout — a typed timeout outcome, never a decline and never an app failure. |

### `switchyard resolve`

Open the three-way merge UI for the repository's conflicts and block until the human resolves them, cancels, or the wait times out.

Usage: `switchyard resolve [<pathspec>] --wait [--timeout <seconds>]`

| Flag | Meaning |
|---|---|
| `--timeout <seconds>` | Give up the wait after this many seconds (default 3600). On expiry the CLI exits 10 with a typed timeout outcome — never a cancellation. |
| `--wait` | Block until the human resolves or cancels. Required in this build; a non-blocking form does not exist yet. |

| Exit | Meaning |
|---|---|
| 0 | The human resolved every conflicted path; the payload is the resolve reply (per-path resolutions). |
| 1 | Invalid arguments — missing --wait, more than one pathspec, an empty pathspec, or a malformed --timeout. |
| 3 | The Switchyard app is not running. Resolve never launches the app. |
| 4 | The request was superseded by a newer resolve for the same repository, or the app could not serve it — no reply was received. |
| 5 | The app quit before the human decided — never reported as a decision. |
| 7 | The human cancelled; nothing was staged and nothing was touched; the payload still carries the cancelled reply with ok:true. |
| 8 | Conflicts remain after the reply (blocked_on_conflicts) — some paths were left unresolved; the payload still carries the reply with ok:true. |
| 10 | No reply arrived within --timeout — a typed timeout outcome, never a cancellation and never an app failure. |

### `switchyard watch`

Stream repository and app events as newline-delimited JSON until detached.

Usage: `switchyard watch [<repository-path>] [--timeout <seconds>]`

| Flag | Meaning |
|---|---|
| `--timeout <seconds>` | Detach after this many seconds, exiting 0. Without it the session runs until the CLI detaches (Ctrl-C) or the app ends it. |

| Exit | Meaning |
|---|---|
| 0 | The session ended cleanly — Ctrl-C, the --timeout deadline, or the app's detached/timedOut reply. |
| 1 | Invalid arguments — a malformed --timeout, an unknown flag, or more than one repository path. |
| 3 | The Switchyard app is not running. Watch never launches the app. |
| 5 | The app terminated the session (shutting down) or quit mid-stream — never reported as a detach. |

### `switchyard tag`

Create a lightweight or annotated tag at a commit.

Usage: `switchyard tag <name> <commit> [--annotate] [--message <message>] [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--annotate` | Create an annotated tag (implied by --message). Requires a message. |
| `--message <message>` | The tag's message, passed as a flag — implies an annotated tag; GIT_EDITOR is never invoked. |
| `--no-sign` | Never sign, even when tag.gpgsign is true. |
| `--sign` | Sign the annotated tag, even when tag.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The tag was created; the payload carries the ref, the object it names (the tag object when annotated, the commit when lightweight), and whether it is annotated. |
| 1 | Invalid arguments — tag requires exactly two positional arguments <name> <commit>; an unknown, duplicated, or value-missing flag; or both --sign and --no-sign. |
| 4 | The tag could not be created for a reason the other codes do not name — an invalid name, an existing tag name, a `/`-boundary clash with an existing tag, an unknown commit, a missing message on an annotated tag, a signing intent on a lightweight tag, or a signing failure among them. |

### `switchyard branch`

Create, rename, or delete a local branch, or set its upstream.

Usage: `switchyard branch (create <name> [<start>] | rename <old> <new> | delete <name> [--force] | upstream <name> <upstream>)`

| Flag | Meaning |
|---|---|
| `--force` | With delete: delete an unmerged branch, whose commits would otherwise be lost (the journal records the deletion). |

| Exit | Meaning |
|---|---|
| 0 | The operation completed; the payload carries the ref, the branch's tip (for delete, the tip the deleted ref held), and for rename whether HEAD's symref followed, for upstream the upstream's full ref name. |
| 1 | Invalid arguments — branch requires create, rename, delete, or upstream with its own positional grammar (create <name> [<start>], rename <old> <new>, delete <name> [--force], upstream <name> <upstream>); an unknown flag is refused too (only delete takes --force). |
| 4 | The operation could not be completed for a reason the other codes do not name — an invalid name, an existing name, a `/`-boundary clash, an unknown revision or branch or upstream, deleting the checked-out branch or one a linked worktree holds, or an unmerged branch without --force among them. |

### `switchyard rebase-onto`

Replay the current branch's commits onto the named base commit.

Usage: `switchyard rebase-onto <commit> [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the replayed commits, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The rebase completed; the payload carries the branch's new head oid. The branch's commits after the merge-base with the base were replayed onto the base, and the branch ref moved once at the end. The commits the two lines share keep their original oids. |
| 1 | Invalid arguments — rebase-onto requires exactly one positional argument <commit>; an unknown, duplicated, or value-missing flag (rebase-onto takes no --message or --before/--after); or both --sign and --no-sign. |
| 4 | The rebase could not be completed for a reason the other codes do not name — an unknown base, a detached HEAD, a base that already contains the branch or that the branch is already based on, a base with no common history, or a signing failure among them. |
| 8 | Blocked on conflicts (blocked_on_conflicts) — the replay could not apply cleanly and is left in progress, resumable. |

### `switchyard set-tip`

Move the current branch's tip to the named commit without replaying anything.

Usage: `switchyard set-tip <commit>`

| Exit | Meaning |
|---|---|
| 0 | The tip was set; the payload carries the branch's new head oid. The branch ref moved transactionally inside one journal checkpoint; the index and working tree were not touched, and undo restores the pre-state exactly. |
| 1 | Invalid arguments — set-tip requires exactly one positional argument <commit> and takes no flags. |
| 4 | The tip could not be set for a reason the other codes do not name — an unknown commit, a detached HEAD, a tip that already names the target, or a target no local branch names among them. |

### `switchyard stage`

Stage whole paths, or unstaged hunks by id, into the index.

Usage: `switchyard stage (<path>... | --hunk <id>...)`

| Flag | Meaning |
|---|---|
| `--hunk <id>` | Stage this unstaged hunk, by the id `switchyard hunks --unstaged` prints. Repeatable; not combinable with paths. |

| Exit | Meaning |
|---|---|
| 0 | The paths or hunks were staged; the payload echoes them as paths or hunks. One journal entry, operation stage. |
| 1 | Invalid arguments — no path and no --hunk, both paths and --hunk, --hunk without an id, or an unknown flag. A path that starts with - goes after --. |
| 4 | The request failed for a reason the other codes do not name. |
| 6 | Not a repository, a path git cannot match, or a hunk id that is unknown, stale, or a conflicted file's combined hunk; nothing was staged. |

### `switchyard unstage`

Unstage whole paths, or staged hunks by id, leaving the worktree untouched.

Usage: `switchyard unstage (<path>... | --hunk <id>...)`

| Flag | Meaning |
|---|---|
| `--hunk <id>` | Unstage this staged hunk, by the id `switchyard hunks --staged` prints. Repeatable; not combinable with paths. |

| Exit | Meaning |
|---|---|
| 0 | The paths or hunks were unstaged; the payload echoes them as paths or hunks. A staged rename named by its new path is unstaged whole. One journal entry, operation unstage. |
| 1 | Invalid arguments — no path and no --hunk, both paths and --hunk, --hunk without an id, or an unknown flag. A path that starts with - goes after --. |
| 4 | The request failed for a reason the other codes do not name. |
| 6 | Not a repository, or a hunk id that is unknown or stale; nothing was unstaged. |

### `switchyard commit`

Commit the index as it stands, or amend HEAD, without invoking an editor.

Usage: `switchyard commit [--message <message>] [--amend] [--sign | --no-sign]`

| Flag | Meaning |
|---|---|
| `--amend` | Replace HEAD with a commit of the index and the message. Refused when a remote-tracking branch already contains HEAD. |
| `--message <message>` | The commit message, passed as a flag — GIT_EDITOR is never invoked. Required unless --amend, which otherwise keeps HEAD's message. |
| `--no-sign` | Never sign, even when commit.gpgsign is true. |
| `--sign` | Sign the commit, even when commit.gpgsign is false. |

| Exit | Meaning |
|---|---|
| 0 | The commit was created; the payload carries its full oid and whether it amended HEAD. Hooks ran. One journal entry, operation commit or amend. |
| 1 | Invalid arguments — no --message without --amend, a positional argument, a duplicated or value-missing flag, an unknown flag, or both --sign and --no-sign. |
| 4 | The request failed for a reason the other codes do not name. |
| 6 | Not a repository; git refused the commit (nothing staged, a hook exited non-zero, unresolved conflicts, an empty message); or --amend was refused (no commits yet, or HEAD is already on a remote-tracking branch). |
| 9 | Signing failed (signing_failed); no commit was written. |

| Result field | Type | Meaning |
|---|---|---|
| `amended` | bool | True when --amend replaced HEAD rather than adding a child of it. |
| `oid` | string | The new commit's full object id. |

<!-- END GENERATED -->
