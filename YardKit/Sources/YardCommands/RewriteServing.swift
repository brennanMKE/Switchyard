// RewriteServing.swift — the `reword`/`drop`/`reorder` arms in
// `runEngineCommand` (#0063)

import Foundation
import YardGit
import YardKit

/// `switchyard reword`, `switchyard drop`, and `switchyard reorder` — parses
/// the subcommand's positionals and flags, then resolves `WorktreeContext`
/// for the **caller's** working directory before calling `Rewrite`. The
/// passed path is the caller's, never
/// `FileManager.default.currentDirectoryPath`, which is the app's.
///
/// The grammars are strict, one per subcommand:
///
/// - `reword <commit> --message <message>` — one positional, `--message`
///   required exactly once.
/// - `drop <commit>` — one positional, no other flag but signing.
/// - `reorder <commit> (--before|--after) <ref>` — one positional and
///   exactly one of `--before`/`--after`, whose value names the reference
///   commit the move is measured against.
///
/// All three accept at most one of `--sign` / `--no-sign`, which are
/// contradictory together. An unknown flag, a duplicated flag, a flag
/// missing its value, a flag that belongs to another subcommand (e.g.
/// `--message` on `drop`), a wrong positional count — any tail that is not
/// exactly one well-formed invocation — is refused the way `runYard`'s
/// unknown-subcommand path refuses (`EnvelopeFail(code: .usage, …)`, the
/// human-readable line on stderr, exit 1), before any repository access, so
/// the refusal does not depend on where the command was run.
///
/// The exit code is the issue's contract, four values: **0** — the rewrite
/// completed; the payload carries the branch's new head oid. **1** — usage.
/// **4** — request-failed: every failure the issue's table does not name —
/// an unknown commit, a dropped merge, a cross-branch reorder, a signing
/// failure among them. **8** — blocked on conflicts, with the conflicted
/// paths named in the envelope and the cherry-pick replay left in progress,
/// resumable.
func runRewrite(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let subcommand = arguments.first ?? ""
    let tail = Array(arguments.dropFirst())
    var positionals: [String] = []
    var message: String?
    var before: String?
    var after: String?
    var signChoices: [String] = []
    var usageMessage: String?

    var index = 0
    while index < tail.count, usageMessage == nil {
        let token = tail[index]
        switch token {
        case "--message", "--before", "--after":
            guard index + 1 < tail.count else {
                usageMessage = "\(subcommand)'s \(token) requires a value; got none."
                break
            }
            switch token {
            case "--message":
                if message == nil {
                    message = tail[index + 1]
                    index += 1
                } else {
                    usageMessage = "\(subcommand) takes at most one --message flag."
                }
            case "--before":
                if before == nil {
                    before = tail[index + 1]
                    index += 1
                } else {
                    usageMessage = "\(subcommand) takes at most one --before flag."
                }
            default:
                if after == nil {
                    after = tail[index + 1]
                    index += 1
                } else {
                    usageMessage = "\(subcommand) takes at most one --after flag."
                }
            }
        case "--sign", "--no-sign":
            if signChoices.contains(token) {
                usageMessage = "\(subcommand) takes at most one \(token) flag."
            } else {
                signChoices.append(token)
            }
        default:
            if token.hasPrefix("-") {
                usageMessage = "\(subcommand) takes \(positionalGrammar(subcommand)) and the "
                    + "flags \(flagGrammar(subcommand)); got the unknown flag '\(token)'."
            } else {
                positionals.append(token)
            }
        }
        index += 1
    }

    if usageMessage == nil, Set(signChoices).count > 1 {
        usageMessage = "\(subcommand) takes --sign or --no-sign, not both."
    }
    if usageMessage == nil, subcommand != "reword", message != nil {
        usageMessage = "\(subcommand) takes no --message flag; only reword does."
    }
    if usageMessage == nil, subcommand != "reorder", before != nil || after != nil {
        usageMessage = "\(subcommand) takes no --before/--after flag; only reorder does."
    }
    if usageMessage == nil, subcommand == "reorder", before != nil, after != nil {
        usageMessage = "reorder takes --before or --after, not both."
    }
    if usageMessage == nil, subcommand == "reorder", before == nil, after == nil {
        usageMessage = "reorder requires exactly one of --before <ref> or --after <ref>; got neither."
    }
    if usageMessage == nil, subcommand == "reword", message == nil {
        usageMessage = "reword requires --message <message> naming the commit's new message."
    }
    if usageMessage == nil {
        if positionals.count != 1 {
            let received = positionals.isEmpty
                ? "no arguments"
                : "'\(positionals.joined(separator: " "))'"
            usageMessage = "\(subcommand) requires \(positionalGrammar(subcommand)); got \(received)."
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
        let result: Rewrite.Result
        switch subcommand {
        case "reword":
            guard let message else {
                return finishUsage(
                    "reword requires --message <message> naming the commit's new message.")
            }
            result = try Rewrite.reword(
                commit: positionals[0], message: message,
                signing: signing, at: workingDirectory)
        case "drop":
            result = try Rewrite.drop(
                commit: positionals[0], signing: signing, at: workingDirectory)
        default:
            guard let reference = before ?? after else {
                return finishUsage(
                    "reorder requires exactly one of --before <ref> or --after <ref>; got neither.")
            }
            let position: Rewrite.Position = before != nil ? .before : .after
            result = try Rewrite.reorder(
                commit: positionals[0], position: position,
                reference: reference,
                signing: signing, at: workingDirectory)
        }
        return (stdout: encodeJSON(Envelope(result: EncodableResult(result))) + "\n",
                stderr: "", exitCode: .success)
    } catch let error as RewriteError {
        switch error {
        case let .blockedOnConflicts(files):
            let message = "rewrite blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
                + " — the cherry-pick replay is left in progress and resumable"
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

/// The positional grammar every subcommand documents in its usage refusals.
/// The reorder reference rides the --before/--after flag value, so each
/// subcommand takes exactly one positional, `<commit>`.
private func positionalGrammar(_ subcommand: String) -> String {
    "exactly one positional argument, <commit>"
}

/// The flag grammar each subcommand documents in its unknown-flag refusals.
private func flagGrammar(_ subcommand: String) -> String {
    switch subcommand {
    case "reword": "--message <message>, --sign, --no-sign"
    case "drop": "--sign, --no-sign"
    default: "--before <ref>, --after <ref>, --sign, --no-sign"
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
