// StashServing.swift — the `stash` arm in `runEngineCommand`
// (guide §11 decisions 36 and 37)

import Foundation
import YardGit
import YardKit

/// One stash, as `stash list` and `stash push` report it.
struct StashItemPayload: Encodable, Sendable, Equatable {
    /// `stash@{n}`, valid until the list changes.
    let name: String
    let index: Int
    /// The stash commit's full oid — the name that stays valid.
    let oid: String
    let baseOID: String
    let includesUntracked: Bool
    /// Committer date, seconds since 1970.
    let date: Int
    let message: String

    init(_ item: Stash.Item) {
        name = item.name
        index = item.index
        oid = item.oid
        baseOID = item.baseOID
        includesUntracked = item.includesUntracked
        date = item.date
        message = item.message
    }
}

/// The `stash list` payload: every stash, `stash@{0}` first.
struct StashListPayload: Encodable, Sendable, Equatable {
    let stashes: [StashItemPayload]
}

/// The `stash apply` / `stash pop` payload. `outcome` is `applied` or
/// `conflicted`; `conflictedPaths` is present only for `conflicted`, which
/// exits 8 with `ok: true` — git applied what it could, left conflict
/// markers, and (for pop) kept the stash.
struct StashApplyPayload: Encodable, Sendable, Equatable {
    let oid: String
    let outcome: String
    let conflictedPaths: [String]?
}

/// The `stash drop` payload: the dropped stash's oid, which `undo` restores.
struct StashDropPayload: Encodable, Sendable, Equatable {
    let dropped: String
}

/// `switchyard stash (list | push [--message <message>] [--include-untracked]
/// | apply <stash> [--index] | pop <stash> [--index] | drop <stash>)`.
///
/// A subcommand is required: bare `stash` is a usage refusal, never git's
/// implicit push. `<stash>` is `stash@{n}`, a bare `n`, or a full oid from
/// `stash list`; it is resolved to an oid once, and the engine acts on that
/// oid, so a list that shifts under the call is refused rather than acting
/// on a neighbour. Each mutating subcommand is one journal entry.
func runStash(arguments: [String], workingDirectory: String) -> EngineReply {
    let subcommand = arguments.dropFirst().first ?? ""
    let tail = Array(arguments.dropFirst(2))
    switch subcommand {
    case "list":
        guard tail.isEmpty else { return engineUsage("stash list takes no arguments.") }
        do {
            let top = try repositoryTop(workingDirectory)
            let items: [Stash.Item] = try Stash.list(at: top)
            return engineSuccess(StashListPayload(stashes: items.map(StashItemPayload.init)))
        } catch {
            return engineFailure(error)
        }
    case "push":
        return runStashPush(tail, workingDirectory: workingDirectory)
    case "apply", "pop", "drop":
        return runStashEntry(subcommand, tail, workingDirectory: workingDirectory)
    default:
        let received = subcommand.isEmpty ? "no subcommand" : "the unknown subcommand '\(subcommand)'"
        return engineUsage("stash requires one of 'list', 'push', 'apply', 'pop', 'drop'; got \(received).")
    }
}

private func runStashPush(_ tail: [String], workingDirectory: String) -> EngineReply {
    var message: String?
    var includeUntracked = false
    var index = 0
    while index < tail.count {
        switch tail[index] {
        case "--message":
            guard index + 1 < tail.count else {
                return engineUsage("stash push's --message requires a value; got none.")
            }
            guard message == nil else { return engineUsage("stash push takes at most one --message flag.") }
            message = tail[index + 1]
            index += 1
        case "--include-untracked":
            guard !includeUntracked else {
                return engineUsage("stash push takes at most one --include-untracked flag.")
            }
            includeUntracked = true
        default:
            return engineUsage(
                "stash push takes the flags --message <message> and --include-untracked; got '\(tail[index])'.")
        }
        index += 1
    }
    do {
        let top = try repositoryTop(workingDirectory)
        try Stash.push(message: message, includeUntracked: includeUntracked, at: top)
        let items: [Stash.Item] = try Stash.list(at: top)
        guard let pushed = items.first else { return engineFailure(Stash.Refusal.nothingToStash) }
        return engineSuccess(StashItemPayload(pushed))
    } catch {
        return engineFailure(error)
    }
}

private func runStashEntry(_ subcommand: String, _ tail: [String], workingDirectory: String) -> EngineReply {
    var positionals: [String] = []
    var restoreIndex = false
    for token in tail {
        if token == "--index", subcommand != "drop", !restoreIndex {
            restoreIndex = true
        } else if token.hasPrefix("-"), Int(token) == nil {
            let flags = subcommand == "drop" ? "no flags" : "the flag --index"
            return engineUsage("stash \(subcommand) takes one <stash> and \(flags); got '\(token)'.")
        } else {
            positionals.append(token)
        }
    }
    guard positionals.count == 1 else {
        return engineUsage(
            "stash \(subcommand) requires exactly one <stash> — stash@{n}, n, or an oid from stash list; "
                + "got \(positionals.isEmpty ? "none" : "'\(positionals.joined(separator: " "))'").")
    }
    do {
        let top = try repositoryTop(workingDirectory)
        let items: [Stash.Item] = try Stash.list(at: top)
        let oid = try resolveStash(positionals[0], in: items)
        switch subcommand {
        case "drop":
            try Stash.drop(oid: oid, at: top)
            return engineSuccess(StashDropPayload(dropped: oid))
        default:
            let outcome = subcommand == "pop"
                ? try Stash.pop(oid: oid, restoreIndex: restoreIndex, at: top)
                : try Stash.apply(oid: oid, restoreIndex: restoreIndex, at: top)
            switch outcome {
            case .applied:
                return engineSuccess(StashApplyPayload(oid: oid, outcome: "applied", conflictedPaths: nil))
            case let .conflicted(paths):
                return engineSuccess(
                    StashApplyPayload(oid: oid, outcome: "conflicted", conflictedPaths: paths),
                    exitCode: .blockedOnConflicts)
            }
        }
    } catch {
        return engineFailure(error)
    }
}

/// `stash@{n}`, `n`, or a full oid → the listed stash's oid; anything the
/// list does not hold is `Stash.Refusal.notFound`, exit 6.
func resolveStash(_ name: String, in items: [Stash.Item]) throws -> String {
    var number = name
    if name.hasPrefix("stash@{"), name.hasSuffix("}") {
        number = String(name.dropFirst("stash@{".count).dropLast())
    }
    if !number.isEmpty, number.allSatisfy({ ("0"..."9").contains($0) }), let index = Int(number) {
        guard index < items.count else { throw Stash.Refusal.notFound(oid: name) }
        return items[index].oid
    }
    guard let item = items.first(where: { $0.oid == name }) else {
        throw Stash.Refusal.notFound(oid: name)
    }
    return item.oid
}
