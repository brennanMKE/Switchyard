// Command.swift - Registry of yard commands.

import Foundation

public enum CommandGroup: String, Sendable {
    case read_ = "read"
    case worktree_ = "worktree"
    case mutate_ = "mutate"
    case undo_ = "undo"
    case hooks_ = "hooks"
}

public enum CommandName: String, Sendable, CaseIterable {
    case whereami_ = "whereami"

    case graph__ = "graph"
    case log__ = "log"
    case status_ = "status"
    case hunks_ = "hunks"
    case conflicts__ = "conflicts"
    case blame_ = "blame"
    case verify_ = "verify"

    case wt_list__ = "wt list"
    case wt_new_ = "wt new"
    case wt_rm__ = "wt rm"
    case wt_where_ = "wt where"
    case wt_gc__ = "wt gc"
    case wt_repair_ = "wt repair"

    case commit__ = "commit"
    case fixup_ = "fixup"
    case absorb_ = "absorb"
    case split__ = "split"
    case reword_ = "reword"
    case reorder__ = "reorder"
    case drop__ = "drop"
    case stage_ = "stage"
    case unstage_ = "unstage"

    case checkpoint__ = "checkpoint"
    case undo__ = "undo"
    case redo__ = "redo"
    case journal__ = "journal"
    case restore_ = "restore"

    case hooks_install__ = "hooks install"
    case hook_ref_txn_ = "hook ref-txn"
    case hooks_status__ = "hooks status"

    var group: CommandGroup? {
        switch self {
        case .whereami_, .graph__, .log__, .status_, .hunks_, .conflicts__, .blame_, .verify_:
            return .read_
        case .wt_list__, .wt_new_, .wt_rm__, .wt_where_, .wt_gc__, .wt_repair_:
            return .worktree_
        case .commit__, .fixup_, .absorb_, .split__, .reword_, .reorder__,
             .drop__, .stage_, .unstage_:
            return .mutate_
        case .checkpoint__, .undo__, .redo__, .journal__, .restore_:
            return .undo_
        case .hooks_install__, .hook_ref_txn_, .hooks_status__:
            return .hooks_
        }
    }

    var summary: String {
        switch self {
        case .whereami_: return "Print structured repo state"
        case .graph__: return "The commit DAG with lane assignment"
        case .log__: return "Commits in a range"
        case .status_: return "Worktree state, per-file with staged and unstaged hunks"
        case .hunks_: return "Staged and unstaged hunks with stable hunk IDs"
        case .conflicts__: return "Per-file, per-hunk conflicts with ours/base/their blob IDs"
        case .blame_: return "Structured blame, range-limited"
        case .verify_: return "Signature verification result for a commit"
        case .wt_list__: return "Structured list of worktrees with details"
        case .wt_new_: return "Create a new worktree"
        case .wt_rm__: return "Remove an existing worktree"
        case .wt_where_: return "Resolve the current context"
        case .wt_gc__: return "Prune and garbage-collect worktrees"
        case .wt_repair_: return "Repair a moved-directory worktree"
        case .commit__: return "Create a commit, optionally from hunks and signed"
        case .fixup_: return "Squash staged changes into a target commit"
        case .absorb_: return "Distribute staged hunks into prior commits automatically"
        case .split__: return "Split a commit along a hunk boundary"
        case .reword_: return "Non-interactive message rewrite of a commit"
        case .reorder__: return "Move a commit within the branch"
        case .drop__: return "Remove a commit and adjust ancestry"
        case .stage_: return "Stage hunks by stable ID"
        case .unstage_: return "Unstage hunks by stable ID"
        case .checkpoint__: return "Explicit snapshot of repository state"
        case .undo__: return "Reverse the last N journaled operations"
        case .redo__: return "Replay reversed operations"
        case .journal__: return "List journaled operations"
        case .restore_: return "Restore a previous checkpoint"
        case .hooks_install__: return "Install observer hooks"
        case .hook_ref_txn_: return "The reference-transaction handler"
        case .hooks_status__: return "What hooks are installed and chained"
        }
    }

    var description: String { rawValue }

    var flagSet: [Flag] {
        let base: [Flag] = [.opt("--json")]

        switch self {
        case .wt_new_, .wt_rm__, .commit__: return base + [.opt("--name"), .opt("--path")]
        case .hunks_, .status_: return base + [.opt("--diff") = "--no-color", .opt("--raw")]
        case .commit__: return base + [.opt("--sign"), .opt("--no-edit")]
        default: return base
        }
    }

    var exitCodeSet: [ExitCode] { [.success(), .init(1, "non-zero")] }
}

public struct CommandMeta: Sendable {
    public let command: CommandName
    public var flags: [Flag] { command.flagSet }
    public var exitCodes: [ExitCode] { command.exitCodeSet }
    public let group: CommandGroup?
    public let summary: String

    init(_ c: CommandName) {
        self.command = c
        self.group = c.group
        summary = c.summary
    }

    var dict: [String: Any] {
        return ["command": command.rawValue, "summary": summary, "group": group?.rawValue as Any?,
                "flags": flags.map(\.dict), "exitCodes": exitCodes.map { ["code": Int($0.code)] }]
    }

    var help: String { "\((command.rawValue) + (usageSuffix ?? ""))" }
}

public func listCommands() -> [CommandMeta] { CommandName.allCases.map(CommandMeta.init) }
public func commandByName(_ name: String) -> CommandMeta? { CommandName(rawValue: name).map(CommandMeta.init) }
