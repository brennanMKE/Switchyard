// ReplayServing.swift — the `revert`/`cherry-pick` arms in
// `runEngineCommand` (#0360)

import Foundation
import YardGit
import YardKit

/// `switchyard revert` and `switchyard cherry-pick` — parses the
/// subcommand's positionals and flags, then resolves `WorktreeContext` for
/// the **caller's** working directory before calling `Replay`. The passed
/// path is the caller's, never `FileManager.default.currentDirectoryPath`,
/// which is the app's.
///
/// The grammar is strict and identical for both subcommands:
/// `revert <commit>` / `cherry-pick <commit>` — one positional, and at most
/// one of `--sign` / `--no-sign`, which are contradictory together. An
/// unknown flag, a duplicated flag, a flag missing no value (neither flag
/// takes one), a wrong positional count — any tail that is not exactly one
/// well-formed invocation — is refused the way `runYard`'s
/// unknown-subcommand path refuses (`EnvelopeFail(code: .usage, …)`, the
/// human-readable line on stderr, exit 1), before any repository access, so
/// the refusal does not depend on where the command was run.
///
/// The exit code is the issue's contract, four values: **0** — the replay
/// completed; the payload carries the branch's new head oid. **1** — usage.
/// **4** — request-failed: every failure the issue's table does not name —
/// an unknown commit, a merge revert, an already-reachable pick, a signing
/// failure among them. **8** — blocked on conflicts, with the conflicted
/// paths named in the envelope and git's own resumable state (`REVERT_HEAD`
/// for a revert, `CHERRY_PICK_HEAD` for a pick) left in place.
func runReplay(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let subcommand = arguments.first ?? ""
    let tail = Array(arguments.dropFirst())
    var positionals: [String] = []
    var signChoices: [String] = []
    var usageMessage: String?

    var index = 0
    while index < tail.count, usageMessage == nil {
        let token = tail[index]
        switch token {
        case "--sign", "--no-sign":
            if signChoices.contains(token) {
                usageMessage = "\(subcommand) takes at most one \(token) flag."
            } else {
                signChoices.append(token)
            }
        default:
            if token.hasPrefix("-") {
                usageMessage = "\(subcommand) takes exactly one positional argument, <commit>, "
                    + "and the flags --sign, --no-sign; got the unknown flag '\(token)'."
            } else {
                positionals.append(token)
            }
        }
        index += 1
    }

    if usageMessage == nil, Set(signChoices).count > 1 {
        usageMessage = "\(subcommand) takes --sign or --no-sign, not both."
    }
    if usageMessage == nil {
        if positionals.count != 1 {
            let received = positionals.isEmpty
                ? "no arguments"
                : "'\(positionals.joined(separator: " "))'"
            usageMessage = "\(subcommand) requires exactly one positional argument, <commit>; "
                + "got \(received)."
        }
    }
    if let usageMessage {
        return finishUsage(usageMessage)
    }

    let signing: CommitCreate.Signing
    switch Set(signChoices) {
    case ["--sign"]: signing = .sign
    case ["--no-sign"]: signing = .noSign
    default: signing = .config
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result: Replay.Result
        switch subcommand {
        case "revert":
            result = try Replay.revert(
                commit: positionals[0], signing: signing, at: workingDirectory)
        default:
            result = try Replay.cherryPick(
                commit: positionals[0], signing: signing, at: workingDirectory)
        }
        return (stdout: encodeJSON(Envelope(result: EncodableResult(result))) + "\n",
                stderr: "", exitCode: .success)
    } catch let error as ReplayError {
        switch error {
        case let .blockedOnConflicts(files):
            let message = "\(subcommand) blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
                + " — the operation is left in progress and resumable; finish it with "
                + "git \(subcommand) --continue or back out with git \(subcommand) --abort"
            let fail = EnvelopeFail(code: .blockedOnConflicts, message: message)
            let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
            return (stdout: encodeJSON(fail), stderr: human, exitCode: .blockedOnConflicts)
        default:
            let fail = EnvelopeFail(code: .requestFailed, message: String(describing: error))
            let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
            return (stdout: encodeJSON(fail), stderr: human, exitCode: .requestFailed)
        }
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .requestFailed, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .requestFailed)
    }
}

/// Renders a usage refusal the way every engine arm does: the envelope on
/// stdout, the human-readable line on stderr, exit 1.
private func finishUsage(
    _ message: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let fail = EnvelopeFail(code: .usage, message: message)
    let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
    return (stdout: encodeJSON(fail), stderr: human, exitCode: .usage)
}

/// Mirrors `CommandLineRunner.jsonString(_:)`, which is `internal` to
/// `YardKit` and so not reachable from this target.
private func encodeJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return #"{"schemaVersion":1,"ok":false,"error":{"code":"request_failed","message":"Failed to encode the response."}}"#
    }
    return text
}
