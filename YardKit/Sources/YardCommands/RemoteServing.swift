// RemoteServing.swift — the `fetch`, `pull` and `push` arms in
// `runEngineCommand` (guide §11 decisions 32 and 37)

import Foundation
import YardGit
import YardKit

/// The `fetch` payload: the remotes `git fetch --all` fetched, as `git
/// remote` lists them.
struct FetchPayload: Encodable, Sendable, Equatable {
    let remotes: [String]
}

/// The `pull` payload. `outcome` is `upToDate` or `fastForwarded`; `from`
/// and `to` are the branch's full oids before and after, present only when
/// it fast-forwarded.
struct PullPayload: Encodable, Sendable, Equatable {
    let outcome: String
    let from: String?
    let to: String?

    init(_ result: RemoteSync.PullResult) {
        switch result {
        case .upToDate:
            outcome = "upToDate"; from = nil; to = nil
        case let .fastForwarded(before, after):
            outcome = "fastForwarded"; from = before; to = after
        }
    }
}

/// The `push` payload: the remote, the ref updated there, and whether this
/// push set the branch's upstream.
struct PushPayload: Encodable, Sendable, Equatable {
    let remote: String
    let remoteRef: String
    let setUpstream: Bool
}

/// `switchyard fetch`, `switchyard pull`, `switchyard push` — no arguments.
/// Fetch is `git fetch --all`; pull fetches the upstream's remote and
/// fast-forwards only; push sends the current branch with an explicit
/// refspec and never forces (guide §11 decision 32). Credentials come from
/// the app's environment and nothing ever prompts: a missing credential is
/// git's own "terminal prompts disabled" failure, exit 6.
func runRemote(arguments: [String], workingDirectory: String) -> EngineReply {
    let command = arguments.first ?? "fetch"
    guard arguments.count == 1 else {
        return engineUsage("\(command) takes no arguments; got '\(arguments.dropFirst().joined(separator: " "))'.")
    }
    do {
        let top = try repositoryTop(workingDirectory)
        switch command {
        case "fetch":
            try RemoteSync.fetch(at: top)
            let remotes = try GitProcess().run(["remote"], workingDirectory: top).lines.filter { !$0.isEmpty }
            return engineSuccess(FetchPayload(remotes: remotes))
        case "pull":
            return engineSuccess(PullPayload(try RemoteSync.pull(at: top)))
        default:
            let result = try RemoteSync.push(at: top)
            return engineSuccess(PushPayload(
                remote: result.remote, remoteRef: result.remoteRef, setUpstream: result.setUpstream))
        }
    } catch {
        return engineFailure(error)
    }
}
