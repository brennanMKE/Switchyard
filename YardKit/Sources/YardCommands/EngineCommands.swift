import Foundation
import YardGit
import YardKit

/// Runs a command that needs the engine, returning the rendered envelope and
/// the exit code — the same pair `runYard` returns, so the app can try this
/// first and fall back to `runYard` for the commands that need no repository.
///
/// Returning `nil` means "not one of mine": it is what lets the app compose
/// this with `runYard` without either side enumerating the other's commands.
public func runEngineCommand(
    arguments: [String],
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode)? {
    guard let command = arguments.first else { return nil }

    switch command {
    case "whereami":
        return runWhereAmI(workingDirectory: workingDirectory)
    default:
        return nil
    }
}

/// `switchyard whereami` — resolves `WorktreeContext` for the **caller's**
/// working directory first, before calling `whereAmI`.
///
/// Measured on this branch (mutation 1, round 1): dropping this explicit
/// call does **not** make the not-a-repository test fail any more, because
/// `whereAmI` itself now resolves `WorktreeContext` internally as of #0140
/// (`WhereAmI.swift:149`) — the `do`/`catch` below already catches that. The
/// original justification here ("`whereAmI` does not throw outside a
/// repository") is stale; it predates #0140 and was corrected in the issue's
/// Given 2 on 2026-08-17.
///
/// The call stays anyway: it is still correct per CLAUDE.md ("every path
/// lookup goes through `WorktreeContext`"), and it documents the gate at
/// this call site for a reader who has not read `whereAmI`'s internals —
/// it is just not load-bearing today, since `whereAmI` would throw on its
/// own either way.
private func runWhereAmI(
    workingDirectory: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    do {
        _ = try WorktreeContext.resolve(path: workingDirectory)
        let result = try whereAmI(path: workingDirectory)
        let envelope = Envelope(result: EncodableResult(result))
        return (stdout: encodeJSON(envelope), stderr: "", exitCode: .success)
    } catch {
        let message = String(describing: error)
        let fail = EnvelopeFail(code: .repositoryError, message: message)
        let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
        return (stdout: encodeJSON(fail), stderr: human, exitCode: .repositoryError)
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
