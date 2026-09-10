// AbsorbServing.swift — the `absorb` arm in `runEngineCommand` (#0061)

import Foundation
import YardGit
import YardKit

/// The distribution summary that closes an absorb payload: one JSON line
/// carrying the rewritten `HEAD` (absent when nothing was rewritten — a
/// `--dry-run`, a nothing-staged refusal, or a plan with no confident hunk)
/// and the two counts a caller branches on without re-reading the hunk lines.
private struct AbsorbPayloadSummary: Encodable, Sendable {
    let head: String?
    let absorbed: Int
    let leftStaged: Int

    /// The stable wire keys. `head` is absent when nil — a plan that touched
    /// nothing has no rewritten HEAD to report, and JSON `null` would invite
    /// an unwrapped read.
    private enum CodingKeys: String, CodingKey {
        case head, absorbed, leftStaged
    }
}

/// `switchyard absorb` — parses the optional `--dry-run` flag, then resolves
/// `WorktreeContext` for the **caller's** working directory before calling
/// `Absorb.run`. The passed path is the caller's, never
/// `FileManager.default.currentDirectoryPath`, which is the app's.
///
/// The argument grammar is strict: the only accepted tails are `[]` and
/// `["--dry-run"]`. A duplicated flag, an unknown flag, or any other token is
/// refused the way `runYard`'s unknown-subcommand path refuses
/// (`EnvelopeFail(code: .usage, …)`, the human-readable line on stderr,
/// exit 1) — never a default guess and never a silently ignored argument.
/// The refusal happens before any repository access, so it does not depend
/// on where the command was run.
///
/// The exit code is the issue's contract, four values: **0** — absorbed, or
/// nothing to do (nothing staged, no confident hunk, or a `--dry-run`
/// plan); the payload reports the distribution either way. **1** — usage.
/// **4** — request-failed: every failure the issue's table does not name,
/// signing failure included. **8** — blocked on conflicts, with the rebase
/// (or the refusal) named in the envelope.
///
/// The payload is newline-delimited JSON: one success envelope per hunk
/// outcome, in listing order, then one summary envelope carrying `head` and
/// the absorbed/left-staged counts. Each line is independently parseable,
/// which is what an agent reading the distribution incrementally wants.
func runAbsorb(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    var dryRun = false
    var usageMessage: String?
    switch tail.count {
    case 0:
        break
    case 1 where tail[0] == "--dry-run":
        dryRun = true
    default:
        usageMessage = "absorb takes at most one optional --dry-run flag; got '\(tail.joined(separator: " "))'."
    }
    if let usageMessage {
        let fail = EnvelopeFail(code: .usage, message: usageMessage)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .usage)
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try Absorb.run(dryRun: dryRun, at: workingDirectory)
        return (stdout: renderAbsorbPayload(result), stderr: "", exitCode: .success)
    } catch let error as AbsorbError {
        switch error {
        case .nothingStaged:
            // Nothing to do is a completed command, not a failure — the
            // summary line alone reports the empty distribution.
            let summary = AbsorbPayloadSummary(head: nil, absorbed: 0, leftStaged: 0)
            return (stdout: encodeJSON(Envelope(result: EncodableResult(summary))) + "\n",
                    stderr: "", exitCode: .success)
        case let .blockedOnConflicts(files):
            let message = "absorb blocked on conflicts in "
                + files.map(\.path).joined(separator: ", ")
                + " — the rebase is left in progress and resumable"
            let fail = EnvelopeFail(code: .blockedOnConflicts, message: message)
            let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
            return (stdout: encodeJSON(fail), stderr: human, exitCode: .blockedOnConflicts)
        case let .signingFailed(reason):
            let fail = EnvelopeFail(code: .requestFailed, message: "signing failed: \(reason)")
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

/// Renders `Absorb`'s payload: one success envelope per hunk outcome, then
/// the summary line. Every line is newline-terminated, so the whole payload
/// round-trips through any line-oriented reader.
private func renderAbsorbPayload(_ result: Absorb) -> String {
    var lines = result.plan.hunks.map { encodeJSON(Envelope(result: EncodableResult($0))) }
    let summary = AbsorbPayloadSummary(
        head: result.head,
        absorbed: result.plan.confident.count,
        leftStaged: result.plan.unconfident.count)
    lines.append(encodeJSON(Envelope(result: EncodableResult(summary))))
    return lines.joined(separator: "\n") + "\n"
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
