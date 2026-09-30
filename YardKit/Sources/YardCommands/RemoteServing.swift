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

/// `switchyard fetch [<remote>]`, `switchyard pull`, `switchyard push`.
/// Fetch is `git fetch --all`, or `git fetch -- <remote>` for one configured
/// remote (guide §11 decision 43); pull fetches the upstream's remote and
/// fast-forwards only; push sends the current branch with an explicit
/// refspec and never forces (guide §11 decision 32). Credentials come from
/// the app's environment and nothing ever prompts: a missing credential is
/// git's own "terminal prompts disabled" failure, exit 6.
func runRemote(arguments: [String], workingDirectory: String) -> EngineReply {
    let command = arguments.first ?? "fetch"
    if command == "fetch", arguments.count == 2 {
        return runFetchRemote(arguments[1], workingDirectory: workingDirectory)
    }
    guard arguments.count == 1 else {
        if command == "fetch" {
            return engineUsage("fetch takes at most one <remote>; got '\(arguments.dropFirst().joined(separator: " "))'.")
        }
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

/// `switchyard fetch <remote>`: one configured remote, one `fetch` journal
/// entry. A name that starts with `-` is a usage refusal (no remote can have
/// one: `RemoteConfig.nameProblem`); a name no remote has is exit 6.
private func runFetchRemote(_ name: String, workingDirectory: String) -> EngineReply {
    guard !name.hasPrefix("-") else {
        return engineUsage("fetch takes at most one <remote>, a configured remote's name; got the flag '\(name)'.")
    }
    do {
        let top = try repositoryTop(workingDirectory)
        try RemoteSync.fetch(remote: name, at: top)
        return engineSuccess(FetchPayload(remotes: [name]))
    } catch {
        return engineFailure(error)
    }
}
