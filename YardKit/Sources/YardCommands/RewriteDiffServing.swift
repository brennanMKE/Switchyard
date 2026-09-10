// RewriteDiffServing.swift — the `rewrite-diff` arm in `runEngineCommand` (#0064)

import Foundation
import YardGit
import YardKit

/// `switchyard rewrite-diff <journal-entry-id>` — parses the one required
/// positional, then resolves `WorktreeContext` for the **caller's** working
/// directory before calling `RewriteDiff.run`. The passed path is the
/// caller's, never `FileManager.default.currentDirectoryPath`, which is the
/// app's.
///
/// The grammar is strict and flagless: exactly one positional argument, the
/// 26-character journal entry id, and nothing else. An unknown flag, a
/// second positional, or an empty tail is refused the way `runYard`'s
/// unknown-subcommand path refuses (`EnvelopeFail(code: .usage, …)`, the
/// human-readable line on stderr, exit 1), before any repository access, so
/// the refusal does not depend on where the command was run. The command is
/// read-only — no journal entry is written and no ref moves — so there is no
/// conflict class on its surface.
///
/// The exit code is the issue's contract, three values: **0** — the diff
/// computed; the payload carries the entry id, the source shape, the ranges,
/// and the rows. **1** — usage. **4** — request-failed: every failure the
/// table does not name — an unknown entry id, an entry with no rewrite
/// mapping, unparseable range-diff output, a non-zero git exit among them.
func runRewriteDiff(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let tail = Array(arguments.dropFirst())
    let positional = tail.first
    let usage: String?
    if tail.isEmpty {
        usage = "rewrite-diff requires exactly one positional argument, "
            + "<journal-entry-id>; got no arguments."
    } else if tail.count > 1 {
        usage = "rewrite-diff requires exactly one positional argument, "
            + "<journal-entry-id>; got '\(tail.joined(separator: " "))'."
    } else if tail[0].hasPrefix("-") {
        usage = "rewrite-diff takes one positional argument, <journal-entry-id>, "
            + "and no flags; got the unknown flag '\(tail[0])'."
    } else {
        usage = nil
    }
    if let usage {
        return finishUsage(usage)
    }
    let idArgument = tail[0]

    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        guard let entryID = JournalEntryID(idArgument) else {
            return finishUsage("rewrite-diff requires a journal entry id — 26 characters "
                + "of Crockford base32; got '\(idArgument)'.")
        }
        let result = try RewriteDiff.run(entryID: entryID, at: workingDirectory)
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
