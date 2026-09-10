// SplitServing.swift — the `split` arm in `runEngineCommand` (#0062)

import Foundation
import YardGit
import YardKit

/// The payload that closes a split: one JSON line carrying both new commit
/// oids, parented `C^ → first → second`, where `second`'s tree equals the
/// original commit's tree.
private struct SplitPayloadSummary: Encodable, Sendable {
    let first: String
    let second: String

    /// The stable wire keys, identical to the stored-member names.
    private enum CodingKeys: String, CodingKey {
        case first, second
    }
}

/// `switchyard split` — parses the required `<commit> <hunkID>` positionals
/// and the optional flags, then resolves `WorktreeContext` for the
/// **caller's** working directory before calling `Split.run`. The passed
/// path is the caller's, never `FileManager.default.currentDirectoryPath`,
/// which is the app's.
///
/// The argument grammar is strict: exactly two positional arguments, at most
/// one of each of `--first <message>` and `--second <message>` (each takes a
/// value), and at most one of `--sign` / `--no-sign` (which are
/// contradictory together). An unknown flag, a duplicated flag, a flag
/// missing its value, a wrong positional count — any tail that is not
/// exactly one well-formed invocation — is refused the way `runYard`'s
/// unknown-subcommand path refuses (`EnvelopeFail(code: .usage, …)`, the
/// human-readable line on stderr, exit 1), before any repository access, so
/// the refusal does not depend on where the command was run.
///
/// The exit code is the issue's contract, four values: **0** — the split
/// completed; the payload carries both new oids. **1** — usage. **4** —
/// request-failed: every failure the issue's table does not name — an
/// unknown hunk id, a commit with fewer than two hunks, a signing failure
/// among them. **8** — blocked on conflicts, with the conflicted paths named
/// in the envelope and the cherry-pick replay left in progress, resumable.
func runSplit(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    var positionals: [String] = []
    var firstMessage: String?
    var secondMessage: String?
    var signChoices: [String] = []
    var usageMessage: String?

    var index = 0
    while index < tail.count, usageMessage == nil {
        let token = tail[index]
        switch token {
        case "--first", "--second":
            guard index + 1 < tail.count else {
                usageMessage = "split's \(token) requires a message value; got none."
                break
            }
            if token == "--first" {
                if firstMessage == nil {
                    firstMessage = tail[index + 1]
                    index += 1
                } else {
                    usageMessage = "split takes at most one --first flag."
                }
            } else {
                if secondMessage == nil {
                    secondMessage = tail[index + 1]
                    index += 1
                } else {
                    usageMessage = "split takes at most one --second flag."
                }
            }
        case "--sign", "--no-sign":
            if signChoices.contains(token) {
                usageMessage = "split takes at most one \(token) flag."
            } else {
                signChoices.append(token)
            }
        default:
            if token.hasPrefix("-") {
                usageMessage = "split takes <commit> <hunkID> and the flags --first <message>, "
                    + "--second <message>, --sign, --no-sign; got the unknown flag '\(token)'."
            } else {
                positionals.append(token)
            }
        }
        index += 1
    }
    if usageMessage == nil, Set(signChoices).count > 1 {
        usageMessage = "split takes --sign or --no-sign, not both."
    }
    if usageMessage == nil, positionals.count != 2 {
        let received = positionals.isEmpty
            ? "no arguments"
            : "'\(positionals.joined(separator: " "))'"
        usageMessage = "split requires exactly two positional arguments, <commit> <hunkID>; got \(received)."
    }
    if let usageMessage {
        let fail = EnvelopeFail(code: .usage, message: usageMessage)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .usage)
    }

    let signing: CommitCreate.Signing
    switch Set(signChoices) {
    case ["--sign"]: signing = .sign
    case ["--no-sign"]: signing = .noSign
    default: signing = .config
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try Split.run(
            commit: positionals[0],
            hunkID: positionals[1],
            first: firstMessage,
            second: secondMessage,
            signing: signing,
            at: workingDirectory
        )
        let summary = SplitPayloadSummary(first: result.first, second: result.second)
        return (stdout: encodeJSON(Envelope(result: EncodableResult(summary))) + "\n",
                stderr: "", exitCode: .success)
    } catch let error as SplitError {
        switch error {
        case let .blockedOnConflicts(files):
            let message = "split blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
                + " — the cherry-pick replay is left in progress and resumable"
            let fail = EnvelopeFail(code: .blockedOnConflicts, message: message)
            let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
            return (stdout: encodeJSON(fail), stderr: human, exitCode: .blockedOnConflicts)
        case let .signingFailed(reason):
            let fail = EnvelopeFail(code: .requestFailed, message: "signing failed: \(reason)")
            let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
            return (stdout: encodeJSON(fail), stderr: human, exitCode: .requestFailed)
        case .unknownHunkID, .nothingToDo, .commitNotOnRef, .treeMismatch:
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
