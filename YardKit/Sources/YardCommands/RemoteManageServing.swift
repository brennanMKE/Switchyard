// RemoteManageServing.swift — the `remote` arm in `runEngineCommand`
// (guide §11 decisions 41 and 43)

import Foundation
import YardGit
import YardKit

/// One configured remote, as `remote list` reports it: URLs after
/// `insteadOf` rewriting — what git contacts.
struct RemoteItemPayload: Encodable, Sendable, Equatable {
    let name: String
    /// Absent when the remote has no URL.
    let fetchURL: String?
    /// Every push URL; equal to `[fetchURL]` unless a push URL is set.
    let pushURLs: [String]

    init(_ remote: RemoteConfig.Remote) {
        name = remote.name
        fetchURL = remote.fetchURL
        pushURLs = remote.pushURLs
    }
}

/// The `remote list` payload, sorted by name.
struct RemoteListPayload: Encodable, Sendable, Equatable {
    let remotes: [RemoteItemPayload]
}

/// The `remote add` / `remote set-url` payload: the remote as configured
/// now. `undoable` is always false — a remote is configuration, which no
/// journal entry captures, so `undo` neither reverses this nor stops at it
/// (guide §11 decision 41).
struct RemoteEditPayload: Encodable, Sendable, Equatable {
    let remote: RemoteItemPayload
    let undoable: Bool
}

/// The `remote rename` payload. `trackingBranches` are the remote-tracking
/// branches under the new name; `upstreamOf` the local branches whose
/// upstream followed the rename. `undoable` is false: the rename's journal
/// entry is one `undo` refuses to cross (exit 6), as a push's is.
struct RemoteRenamePayload: Encodable, Sendable, Equatable {
    let name: String
    let previousName: String
    let trackingBranches: [String]
    let upstreamOf: [String]
    let undoable: Bool
}

/// The `remote remove` payload: the remote-tracking branches deleted with
/// it, and the local branches that stopped tracking it. `undoable` is
/// false, as for rename.
struct RemoteRemovePayload: Encodable, Sendable, Equatable {
    let removed: String
    let trackingBranches: [String]
    let upstreamOf: [String]
    let undoable: Bool
}

/// The `remote prune` payload: the remote-tracking branches deleted because
/// the remote no longer has them. `undoable` is true: the `prune` entry is
/// written first, and `undo` brings them back.
struct RemotePrunePayload: Encodable, Sendable, Equatable {
    let remote: String
    let pruned: [String]
    let undoable: Bool
}

/// `switchyard remote (list | add <name> <url> | set-url <name> <url> |
/// rename <old> <new> | remove <name> | prune <name>)`.
///
/// A subcommand is required (git's bare `git remote` lists; this surface
/// never guesses). No subcommand takes a flag, so any `-`-prefixed token is a
/// usage refusal — no remote name or URL may start with `-` anyway
/// (`RemoteConfig.nameProblem`, `urlProblem`). Journaling follows decision
/// 41: add and set-url write nothing; rename and remove write an entry after
/// they succeed that `undo` refuses; prune writes one before it runs that
/// `undo` restores. Each payload says which with `undoable`.
func runRemoteManage(arguments: [String], workingDirectory: String) -> EngineReply {
    let subcommand = arguments.dropFirst().first ?? ""
    let tail = Array(arguments.dropFirst(2))
    let arity = ["list": 0, "add": 2, "set-url": 2, "rename": 2, "remove": 1, "prune": 1]
    guard let expected = arity[subcommand] else {
        let received = subcommand.isEmpty ? "no subcommand" : "the unknown subcommand '\(subcommand)'"
        return engineUsage(
            "remote requires one of 'list', 'add', 'set-url', 'rename', 'remove', 'prune'; got \(received).")
    }
    if let flag = tail.first(where: { $0.hasPrefix("-") }) {
        return engineUsage("remote \(subcommand) takes no flags; got '\(flag)'.")
    }
    guard tail.count == expected else {
        let grammar = switch subcommand {
        case "list": "no arguments"
        case "add", "set-url": "exactly <name> <url>"
        case "rename": "exactly <old> <new>"
        default: "exactly one <name>"
        }
        let received = tail.isEmpty ? "none" : "'\(tail.joined(separator: " "))'"
        return engineUsage("remote \(subcommand) takes \(grammar); got \(received).")
    }
    do {
        let top = try repositoryTop(workingDirectory)
        switch subcommand {
        case "list":
            let remotes: [RemoteConfig.Remote] = try RemoteConfig.list(at: top)
            return engineSuccess(RemoteListPayload(remotes: remotes.map(RemoteItemPayload.init)))
        case "add", "set-url":
            if subcommand == "add" {
                try RemoteConfig.add(name: tail[0], url: tail[1], at: top)
            } else {
                try RemoteConfig.setURL(tail[1], forRemote: tail[0], at: top)
            }
            let remotes: [RemoteConfig.Remote] = try RemoteConfig.list(at: top)
            guard let remote = remotes.first(where: { $0.name == tail[0] }) else {
                return engineFailure(RemoteConfig.Refusal.unknownRemote(tail[0]))
            }
            return engineSuccess(RemoteEditPayload(remote: RemoteItemPayload(remote), undoable: false))
        case "rename":
            try RemoteConfig.rename(tail[0], to: tail[1], at: top)
            let impact = try RemoteConfig.removalImpact(of: tail[1], at: top)
            return engineSuccess(RemoteRenamePayload(
                name: tail[1], previousName: tail[0], trackingBranches: impact.trackingBranches,
                upstreamOf: impact.upstreamOf, undoable: false))
        case "remove":
            let impact = try RemoteConfig.removalImpact(of: tail[0], at: top)
            try RemoteConfig.remove(tail[0], at: top)
            return engineSuccess(RemoteRemovePayload(
                removed: tail[0], trackingBranches: impact.trackingBranches,
                upstreamOf: impact.upstreamOf, undoable: false))
        default:
            let before = try RemoteConfig.removalImpact(of: tail[0], at: top).trackingBranches
            try RemoteSync.prune(remote: tail[0], at: top)
            let after = Set(try RemoteConfig.removalImpact(of: tail[0], at: top).trackingBranches)
            return engineSuccess(RemotePrunePayload(
                remote: tail[0], pruned: before.filter { !after.contains($0) }, undoable: true))
        }
    } catch {
        return engineFailure(error)
    }
}
