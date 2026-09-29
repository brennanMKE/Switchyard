// SkillProse.swift

import Foundation

/// The hand-written half of `skills/switchyard/SKILL.md` (guide §8, §11
/// decision 31). Judgment lives here — when to use which command, what to do
/// on a given exit code. Flags, exit codes and result fields do **not**: they
/// are generated from `CommandRegistry.all` by `renderSkill()`, and
/// `SkillProseTests` fails if any `switchyard …` line below names a command or
/// flag the registry does not have.
///
/// Edit this file, never `SKILL.md`; then run `scripts/generate-skill.sh`.
nonisolated enum SkillProse {

    /// YAML front matter. `name` and `description` are what Claude Code and
    /// other skill loaders read to decide when to load the skill.
    static let frontMatter = """
        ---
        name: switchyard
        description: Drive the Switchyard git client from the shell with the `switchyard` CLI. Read repository state as JSON (whereami, status, log, graph, hunks, conflicts), rewrite local history without an editor (reword, drop, reorder, split, absorb, rebase-onto), and hand decisions to the human in the Switchyard app (review, ask, resolve). Use in a git repository on a Mac with Switchyard.app installed, instead of raw git for these operations.
        ---

        """

    static let introduction = """
        # switchyard

        `switchyard` is the command-line companion to Switchyard.app, a macOS git client. The app owns \
        the repository engine; the CLI sends each command to it and prints the reply. Every rewrite it \
        performs is recorded in the app's journal, so the human can undo it from the app. \
        `switchyard skill` prints this document.

        ## Before you start

        - Run commands from inside the repository's working tree: the repository is the one containing \
        the current directory. Outside a repository, commands exit 6.
        - Most commands launch Switchyard.app if it is not running. `review`, `ask`, `resolve` and \
        `watch` never launch it: they need a human already at the app, and exit 3 without one. Treat \
        exit 3 from those as "no human available" — do not proceed as if approved.
        - A command's stdout is exactly one JSON envelope. The exceptions are `--help`, `--version` and \
        `switchyard skill`, which print text, and `watch`, which streams one JSON object per line. Parse \
        `ok` and the exit code; do not scrape the human-readable stderr line.
        - Nothing is interactive. No editor or pager ever opens; messages are passed as flags.
        - Undo is not a CLI command in this build. A rewrite that went wrong is undone by the human \
        from the app's Edit menu.

        """

    static let workflows = """
        ## Workflows

        ### Orient yourself

        ```sh
        switchyard whereami
        switchyard status
        switchyard log main..HEAD
        ```

        `whereami` answers branch, upstream, ahead/behind, and whether a rebase, merge, cherry-pick \
        or revert is in progress, in one call. Check `isMidRebase`, `isMidMerge` and `hasConflicts` \
        before starting any rewrite.

        ### Clean up a branch before review

        ```sh
        switchyard reword HEAD~2 --message "Explain the parser change"
        switchyard drop HEAD~1
        switchyard reorder HEAD --before HEAD~2
        switchyard absorb --dry-run
        ```

        Each rewrite is recorded in the app's journal, so the human can undo it. `absorb --dry-run` \
        reports where staged hunks would go without touching anything; run it before `absorb`.

        ### When a command exits 8

        Exit 8 (`blocked_on_conflicts`) means the operation stopped with conflicts and is left in \
        progress. Do not start another rewrite. Either list them and resolve the files yourself:

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

        `review` exits 0 on approve or amend and 7 on reject; `ask` exits 0 with the chosen option \
        (`optionIndex`, `optionText`) and 7 when the human declines. Both exit 10 when `--timeout` \
        expires, which is neither a yes nor a no.

        """
}
