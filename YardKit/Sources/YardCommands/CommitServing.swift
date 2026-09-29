// CommitServing.swift — the `commit` arm in `runEngineCommand`
// (guide §11 decision 37)

import Foundation
import YardGit
import YardKit

/// The `commit` payload: the new commit's full oid, and whether it replaced
/// `HEAD` (`--amend`) rather than adding a child of it.
struct CommitPayload: Encodable, Sendable, Equatable {
    let oid: String
    let amended: Bool
}

/// `switchyard commit --message <message> [--amend] [--sign | --no-sign]`.
///
/// Commits the index as it stands (`commitStaged`, one `commit` journal
/// entry), or with `--amend` rewrites `HEAD` (`AmendHead.run`, one `amend`
/// entry; refused typed, before the entry, when `HEAD` is on a
/// remote-tracking ref). `--message` is required without `--amend`; with
/// it, a missing `--message` keeps `HEAD`'s full message, as `git commit
/// --amend --no-edit` does. Hooks run and `commit.gpgsign` decides signing
/// unless `--sign`/`--no-sign` says otherwise; `GIT_EDITOR` is never run.
func runCommit(arguments: [String], workingDirectory: String) -> EngineReply {
    var message: String?
    var amend = false
    var signChoices: Set<String> = []
    let tail = Array(arguments.dropFirst())
    var index = 0
    while index < tail.count {
        let token = tail[index]
        switch token {
        case "--message":
            guard index + 1 < tail.count else {
                return engineUsage("commit's --message requires a value; got none.")
            }
            guard message == nil else { return engineUsage("commit takes at most one --message flag.") }
            message = tail[index + 1]
            index += 1
        case "--amend":
            guard !amend else { return engineUsage("commit takes at most one --amend flag.") }
            amend = true
        case "--sign", "--no-sign":
            guard signChoices.insert(token).inserted else {
                return engineUsage("commit takes at most one \(token) flag.")
            }
        default:
            return engineUsage(
                "commit takes the flags --message <message>, --amend, --sign, --no-sign "
                    + "and no positional arguments; got '\(token)'.")
        }
        index += 1
    }
    guard signChoices.count < 2 else { return engineUsage("commit takes --sign or --no-sign, not both.") }
    guard amend || message != nil else {
        return engineUsage("commit requires --message <message>; only --amend may omit it.")
    }
    let signing: CommitCreate.Signing =
        signChoices.contains("--sign") ? .sign : signChoices.contains("--no-sign") ? .noSign : .config

    do {
        let top = try repositoryTop(workingDirectory)
        let created: CommitCreate
        if amend {
            let text = try message ?? AmendHead.target(at: top).message
            created = try AmendHead.run(message: text, signing: signing, at: top)
        } else {
            created = try commitStaged(message: message ?? "", signing: signing, at: top)
        }
        return engineSuccess(CommitPayload(oid: created.oid, amended: amend))
    } catch {
        return engineFailure(error)
    }
}
