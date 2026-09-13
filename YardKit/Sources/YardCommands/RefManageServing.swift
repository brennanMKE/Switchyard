// RefManageServing.swift — the `tag` and `branch` arms in `runEngineCommand`
// (#0363)

import Foundation
import YardGit
import YardKit

/// `switchyard tag` and `switchyard branch` — parses the subcommand's
/// positionals and flags, then resolves `WorktreeContext` for the **caller's**
/// working directory before calling `Tag`/`Branch`. The passed path is the
/// caller's, never `FileManager.default.currentDirectoryPath`, which is the
/// app's.
///
/// The grammars are strict:
///
/// - `tag <name> <commit> [--annotate] [--message <message>] [--sign|--no-sign]`
///   — two positionals. `--message` implies an annotated tag; `--annotate`
   ///  states the intent on its own (and then the engine refuses the missing
///   message as the typed `.messageRequired`, not a usage error). `--sign`
///   and `--no-sign` are contradictory together.
/// - `branch create <name> [<start>]` — one required positional, the start
///   point optional (default HEAD).
/// - `branch rename <old> <new>` — exactly two positionals.
/// - `branch delete <name> [--force]` — one positional; `--force` deletes an
///   unmerged branch, journalling the deletion.
/// - `branch upstream <name> <upstream>` — exactly two positionals.
///
/// An unknown flag, a duplicated flag, a flag missing its value, a flag that
/// belongs to another subcommand, a wrong positional count, or an unknown
/// `branch` subcommand — any tail that is not exactly one well-formed
/// invocation — is refused the way `runYard`'s unknown-subcommand path
/// refuses (`EnvelopeFail(code: .usage, …)`, the human-readable line on
/// stderr, exit 1), before any repository access, so the refusal does not
/// depend on where the command was run.
///
/// The exit code follows the rewrite arms' contract, four values: **0** — the
/// operation completed; the payload carries the ref, the object it names, and
/// the operation's own fields. **1** — usage. **4** — request-failed: every
/// typed refusal (an existing name, an unknown revision, the checked-out
/// branch, an unmerged delete without `--force`, an invalid name, a signing
/// failure among them) and every other failure.
func runRefManage(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    switch arguments.first {
    case "tag":
        return runTag(arguments: Array(arguments.dropFirst()),
                      workingDirectory: workingDirectory)
    default:
        return runBranch(arguments: Array(arguments.dropFirst()),
                         workingDirectory: workingDirectory)
    }
}

// MARK: - tag

private func runTag(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    var positionals: [String] = []
    var message: String?
    var annotate = false
    var signChoices: [String] = []
    var usageMessage: String?

    var index = 0
    while index < arguments.count, usageMessage == nil {
        let token = arguments[index]
        switch token {
        case "--annotate":
            annotate = true
        case "--message":
            guard index + 1 < arguments.count else {
                usageMessage = "tag's --message requires a value; got none."
                break
            }
            if message == nil {
                message = arguments[index + 1]
                index += 1
            } else {
                usageMessage = "tag takes at most one --message flag."
            }
        case "--sign", "--no-sign":
            if signChoices.contains(token) {
                usageMessage = "tag takes at most one \(token) flag."
            } else {
                signChoices.append(token)
            }
        default:
            if token.hasPrefix("-") {
                usageMessage = "tag takes exactly two positional arguments, <name> <commit>, "
                    + "and the flags --annotate, --message <message>, --sign, --no-sign; "
                    + "got the unknown flag '\(token)'."
            } else {
                positionals.append(token)
            }
        }
        index += 1
    }

    if usageMessage == nil, Set(signChoices).count > 1 {
        usageMessage = "tag takes --sign or --no-sign, not both."
    }
    if usageMessage == nil, positionals.count != 2 {
        let received = positionals.isEmpty
            ? "no arguments"
            : "'\(positionals.joined(separator: " "))'"
        usageMessage = "tag requires exactly two positional arguments, <name> <commit>; "
            + "got \(received)."
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
        let result = try Tag.create(
            name: positionals[0], commit: positionals[1],
            annotated: annotate || message != nil,
            message: message,
            signing: signing, at: workingDirectory)
        return (stdout: encodeJSON(Envelope(result: EncodableResult(result))) + "\n",
                stderr: "", exitCode: .success)
    } catch {
        return finishRequestFailed(error)
    }
}

// MARK: - branch

private func runBranch(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let subcommand = arguments.first ?? ""
    let tail = Array(arguments.dropFirst())
    let known = ["create", "rename", "delete", "upstream"]
    guard known.contains(subcommand) else {
        let received = arguments.isEmpty
            ? "no subcommand"
            : "the unknown subcommand '\(subcommand)'"
        return finishUsage(
            "branch requires one of \(known.map { "'\($0)'" }.joined(separator: ", ")); "
                + "got \(received).")
    }

    var positionals: [String] = []
    var force = false
    var usageMessage: String?
    var index = 0
    while index < tail.count, usageMessage == nil {
        let token = tail[index]
        switch token {
        case "--force" where subcommand == "delete":
            force = true
        default:
            if token.hasPrefix("-") {
                let allowed = subcommand == "delete" ? "the flag --force" : "no flags"
                usageMessage = "branch \(subcommand) takes \(positionalGrammar(subcommand)), "
                    + "\(allowed); got the unknown flag '\(token)'."
            } else {
                positionals.append(token)
            }
        }
        index += 1
    }
    if usageMessage == nil,
       !acceptsPositionalCount(positionals.count, for: subcommand) {
        let received = positionals.isEmpty
            ? "no arguments"
            : "'\(positionals.joined(separator: " "))'"
        usageMessage = "branch \(subcommand) requires \(positionalGrammar(subcommand)); "
            + "got \(received)."
    }
    if let usageMessage {
        return finishUsage(usageMessage)
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result: Branch.Result
        switch subcommand {
        case "create":
            result = try Branch.create(
                name: positionals[0],
                start: positionals.count > 1 ? positionals[1] : nil,
                at: workingDirectory)
        case "rename":
            result = try Branch.rename(
                old: positionals[0], new: positionals[1], at: workingDirectory)
        case "delete":
            result = try Branch.delete(
                name: positionals[0], force: force, at: workingDirectory)
        default:
            result = try Branch.setUpstream(
                name: positionals[0], upstream: positionals[1], at: workingDirectory)
        }
        return (stdout: encodeJSON(Envelope(result: EncodableResult(result))) + "\n",
                stderr: "", exitCode: .success)
    } catch {
        return finishRequestFailed(error)
    }
}

// MARK: - Grammar tables

/// The positional counts each subcommand accepts: `create` takes the name
/// and an optional start revision, `rename` and `upstream` exactly two, and
/// `delete` exactly one.
private func acceptsPositionalCount(_ count: Int, for subcommand: String) -> Bool {
    switch subcommand {
    case "create": count == 1 || count == 2
    case "rename": count == 2
    case "delete": count == 1
    default: count == 2
    }
}

private func positionalGrammar(_ subcommand: String) -> String {
    switch subcommand {
    case "create": "one positional argument <name> and an optional <start> revision"
    case "rename": "exactly two positional arguments, <old> <new>"
    case "delete": "one positional argument, <name>"
    default: "exactly two positional arguments, <name> <upstream>"
    }
}

// MARK: - Rendering

private func finishUsage(
    _ message: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let fail = EnvelopeFail(code: .usage, message: message)
    let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
    return (stdout: encodeJSON(fail), stderr: human, exitCode: .usage)
}

private func finishRequestFailed(
    _ error: Error
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let message = String(describing: error)
    let fail = EnvelopeFail(code: .requestFailed, message: message)
    let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
    return (stdout: encodeJSON(fail), stderr: human, exitCode: .requestFailed)
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
