// MergeServing.swift — the `merge` arm in `runEngineCommand` (#0361)

import Foundation
import YardGit
import YardKit

/// `switchyard merge` — parses the subcommand's positionals and flags, then
/// resolves `WorktreeContext` for the **caller's** working directory before
/// calling `Merge`. The passed path is the caller's, never
/// `FileManager.default.currentDirectoryPath`, which is the app's.
///
/// The grammar is strict: `merge <branch> (--ff-only|--no-ff)
/// [--message <message>] [--allow-unrelated] [--sign|--no-sign]` — exactly
/// one positional, **exactly one of the two intent flags** (git's silent
/// fast-forward guess is never a default, #0361), at most one `--message`,
/// at most one `--allow-unrelated`, and at most one of `--sign`/`--no-sign`.
/// An unknown flag, a duplicated flag, a flag missing its value, a missing
/// or doubled intent flag, a wrong positional count — any tail that is not
/// exactly one well-formed invocation — is refused the way `runYard`'s
/// unknown-subcommand path refuses (`EnvelopeFail(code: .usage, …)`, the
/// human-readable line on stderr, exit 1), before any repository access, so
/// the refusal does not depend on where the command was run.
///
/// The exit code is the issue's contract, four values: **0** — the merge
/// completed; the payload carries the new head oid and whether it was a
/// fast-forward. **1** — usage. **4** — request-failed: every failure the
/// issue's table does not name — an unknown branch, an already-up-to-date
/// target, unrelated histories without `--allow-unrelated`, a target
/// `--ff-only` cannot reach, a signing failure among them. **8** — blocked
/// on conflicts: the index already held unmerged entries (refused, nothing
/// touched), or the merge itself conflicted and is left in progress,
/// resumable with `MERGE_HEAD` present.
func runMerge(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    var positionals: [String] = []
    var message: String?
    var ffOnly = false
    var noFF = false
    var allowUnrelated = false
    var allowUnrelatedCount = 0
    var signChoices: [String] = []
    var usageMessage: String?

    var index = 0
    while index < tail.count, usageMessage == nil {
        let token = tail[index]
        switch token {
        case "--ff-only":
            if ffOnly {
                usageMessage = "merge takes at most one --ff-only flag."
            } else {
                ffOnly = true
            }
        case "--no-ff":
            if noFF {
                usageMessage = "merge takes at most one --no-ff flag."
            } else {
                noFF = true
            }
        case "--allow-unrelated":
            allowUnrelatedCount += 1
            if allowUnrelatedCount > 1 {
                usageMessage = "merge takes at most one --allow-unrelated flag."
            } else {
                allowUnrelated = true
            }
        case "--message":
            guard index + 1 < tail.count else {
                usageMessage = "merge's --message requires a value; got none."
                break
            }
            if message == nil {
                message = tail[index + 1]
                index += 1
            } else {
                usageMessage = "merge takes at most one --message flag."
            }
        case "--sign", "--no-sign":
            if signChoices.contains(token) {
                usageMessage = "merge takes at most one \(token) flag."
            } else {
                signChoices.append(token)
            }
        default:
            if token.hasPrefix("-") {
                usageMessage = "merge takes exactly one positional argument, <branch>, and the "
                    + "flags \(flagGrammar); got the unknown flag '\(token)'."
            } else {
                positionals.append(token)
            }
        }
        index += 1
    }

    if usageMessage == nil, ffOnly, noFF {
        usageMessage = "merge takes --ff-only or --no-ff, not both."
    }
    if usageMessage == nil, !ffOnly, !noFF {
        usageMessage = "merge requires exactly one of --ff-only or --no-ff; "
            + "git's fast-forward guess is never a default. Got neither."
    }
    if usageMessage == nil, Set(signChoices).count > 1 {
        usageMessage = "merge takes --sign or --no-sign, not both."
    }
    if usageMessage == nil {
        if positionals.count != 1 {
            let received = positionals.isEmpty
                ? "no arguments"
                : "'\(positionals.joined(separator: " "))'"
            usageMessage = "merge requires exactly one positional argument, <branch>; got \(received)."
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
    let intent: Merge.Intent = ffOnly ? .fastForwardOnly : .noFastForward

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try Merge.run(
            branch: positionals[0], intent: intent, message: message,
            signing: signing, allowUnrelated: allowUnrelated, at: workingDirectory)
        return (stdout: encodeJSON(Envelope(result: EncodableResult(result))) + "\n",
                stderr: "", exitCode: .success)
    } catch let error as MergeError {
        switch error {
        case let .blockedOnConflicts(files):
            let message = "merge blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
                + " — the merge is left in progress and resumable"
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

/// The flag grammar the merge arm documents in its unknown-flag refusals.
private let flagGrammar =
    "--ff-only, --no-ff, --message <message>, --allow-unrelated, --sign, --no-sign"

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
