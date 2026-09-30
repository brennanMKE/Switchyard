// SwitchServing.swift — the `switch` arm in `runEngineCommand`
// (guide §11 decisions 38 and 43)

import Foundation
import YardGit
import YardKit

/// The `switch` payload: where `HEAD` ended up, and the journal operation
/// that recorded it — `switch`, `switch-track` or `switch-detach` — which
/// `undo` reverses (its step names the same operation).
struct SwitchPayload: Encodable, Sendable, Equatable {
    /// `HEAD`'s full oid after the switch.
    let head: String
    /// The checked-out branch's short name; absent when detached.
    let branch: String?
    let operation: String
}

/// `switchyard switch <branch>`, `switchyard switch --track <remote>/<branch>`
/// and `switchyard switch --detach <commit>` — git's own spelling, over
/// `Checkout.switchBranch`, `.trackRemote` and `.detach`.
///
/// Exactly one positional; `--track` and `--detach` are mutually exclusive and
/// each at most once. `--track origin/x` creates the local branch `x` tracking
/// `origin/x`, as `git switch --track origin/x` does. Local changes follow `git
/// switch`: carried when the target has the same file, otherwise the whole
/// switch is refused before anything is touched (exit 6, no journal entry).
/// A switch that succeeds is one journal entry; `undo` puts `HEAD`, the index
/// and the working tree back.
func runSwitch(arguments: [String], workingDirectory: String) -> EngineReply {
    var positionals: [String] = []
    var mode: String?
    for token in arguments.dropFirst() {
        switch token {
        case "--track", "--detach":
            if let mode {
                return engineUsage("switch takes at most one of --track and --detach; got '\(token)' after '\(mode)'.")
            }
            mode = token
        default:
            guard !token.hasPrefix("-") else {
                return engineUsage(
                    "switch takes one <branch>, --track <remote-branch> or --detach <commit>; got the flag '\(token)'.")
            }
            positionals.append(token)
        }
    }
    guard positionals.count == 1 else {
        let received = positionals.isEmpty ? "none" : "'\(positionals.joined(separator: " "))'"
        return engineUsage("switch requires exactly one <branch>, <remote-branch> or <commit>; got \(received).")
    }
    let target = positionals[0]
    do {
        let top = try repositoryTop(workingDirectory)
        let result: Checkout.Result
        let operation: String
        switch mode {
        case "--track":
            result = try Checkout.trackRemote(remoteBranch: target, at: top)
            operation = Checkout.trackOperation
        case "--detach":
            result = try Checkout.detach(commit: target, at: top)
            operation = Checkout.detachOperation
        default:
            result = try Checkout.switchBranch(name: target, at: top)
            operation = Checkout.switchOperation
        }
        return engineSuccess(SwitchPayload(head: result.head, branch: result.branch, operation: operation))
    } catch {
        return engineFailure(error)
    }
}
