// RerereServing.swift — the `rerere status` arm in `runEngineCommand` (#0065)

import Foundation
import YardGit
import YardKit

/// `switchyard rerere status` — reports what git's rerere has recorded for
/// the repository at the **caller's** working directory, which is never
/// `FileManager.default.currentDirectoryPath` (that is the app's).
///
/// The grammar is strict: exactly one subcommand, `status`, plus at most its
/// `--json` flag. The default output IS the JSON envelope payload — `--json`
/// is accepted and documented for command-line consistency, and produces
/// byte-identical output, so neither form is ever a second format. An
/// unknown subcommand (`rerere forget f.txt`), an unknown flag, a bare
/// `rerere`, or a duplicated `--json` is refused the way every engine arm
/// refuses (`EnvelopeFail(code: .usage, …)`, the human-readable line on
/// stderr, exit 1), before any repository access, so the refusal does not
/// depend on where the command was run.
///
/// The surface is READ-ONLY in the strongest form: no `git rerere`
/// subcommand is invoked in any spelling — mutating ones never, and not the
/// text-reading ones either, because after a replay they print nothing
/// (measured, git 2.50.1: `status`/`diff`/`remaining` are all empty once a
/// recorded resolution has been applied to the working file). The payload
/// comes from the rr-cache, MERGE_RR, the index, and the working files
/// instead — see `Rerere` for the measured shapes. Nothing here mutates the
/// repository; recording and replaying stay with git's own machinery.
///
/// The exit code is the contract, three values: **0** — the status computed;
/// the payload carries whether `rerere.enabled` is set and one entry per
/// recorded or known resolution, with its conflict id, the live paths
/// attributed to it, and which of them currently carry the replay. **1** —
/// usage. **4** — request-failed: every failure the table does not name — a
/// working directory outside a repository, unreadable or unparseable rerere
/// state among them.
func runRerere(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    let usage: String?
    switch tail.count {
    case 1 where tail[0] == "status":
        usage = nil
    case 2 where tail[0] == "status" && tail[1] == "--json":
        usage = nil
    default:
        if tail.first != "status" {
            let received = tail.isEmpty ? "no subcommand" : "'\(tail.joined(separator: " "))'"
            usage = "rerere requires exactly one subcommand, status (optionally with --json, "
                + "which is the default output); got \(received)."
        } else {
            usage = "rerere status takes at most the --json flag; "
                + "got '\(tail.dropFirst().joined(separator: " "))'."
        }
    }
    if let usage {
        return finishUsage(usage)
    }

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try Rerere.status(at: workingDirectory)
        return (stdout: encodeJSON(Envelope(result: EncodableResult(result))) + "\n",
                stderr: "", exitCode: .success)
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
