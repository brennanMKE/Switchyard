// EngineServing.swift — shared rendering for the working-tree, remote, stash
// and journal arms in `runEngineCommand` (guide §11 decision 37)

import Foundation
import YardGit
import YardKit

/// What every engine arm returns: the same triple `runYard` returns.
typealias EngineReply = (stdout: String, stderr: String, exitCode: ExitCode)

/// A success envelope carrying `payload`, exit 0 — or `exitCode` when the
/// command completed with an outcome the caller must branch on (a stash
/// apply that conflicted is `ok: true` at exit 8, as `resolve` is).
func engineSuccess(
    _ payload: some (Encodable & Sendable),
    exitCode: ExitCode = .success
) -> EngineReply {
    (stdout: engineJSON(Envelope(result: EncodableResult(payload))) + "\n",
     stderr: "", exitCode: exitCode)
}

/// A usage refusal: the envelope on stdout, the human line on stderr, exit 1.
func engineUsage(_ message: String) -> EngineReply {
    engineFailure(code: .usage, message: message)
}

/// Any engine error, classified by the error itself (guide §11 decision 37):
/// an `ExitClassCarrying` error exits with its own §6 class — 6, 8 or 9 —
/// and anything else is request-failed, exit 4. The conversion is the one
/// `ExitClass`'s doc comment names for wiring time; `ExitClassWireTests`
/// pins that every raw value is an `ExitCode`.
func engineFailure(_ error: any Error) -> EngineReply {
    let exitCode: ExitCode = (error as? any ExitClassCarrying)
        .flatMap { ExitCode(rawValue: Int($0.exitClass.rawValue)) } ?? .requestFailed
    let code = EnvelopeErrorCode(rawValue: exitCode.codeLabel) ?? .requestFailed
    return engineFailure(code: code, message: String(describing: error))
}

private func engineFailure(code: EnvelopeErrorCode, message: String) -> EngineReply {
    let fail = EnvelopeFail(code: code, message: message)
    let human = "[error] \(fail.error.code.rawValue): \(fail.error.message)\n"
    return (stdout: engineJSON(fail), stderr: human, exitCode: code.exitCode)
}

/// Mirrors `CommandLineRunner.jsonString(_:)`, which is `internal` to
/// `YardKit` and so not reachable from this target.
private func engineJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return #"{"schemaVersion":1,"ok":false,"error":{"code":"request_failed","message":"Failed to encode the response."}}"#
    }
    return text
}

/// The repository's top-level directory for the caller's working directory.
/// Paths on the CLI are repository-relative — the form `status`, `hunks` and
/// `conflicts` print — so every path-taking arm runs git from here, not from
/// the caller's subdirectory.
func repositoryTop(_ workingDirectory: String) throws -> String {
    try WorktreeContext.resolve(path: workingDirectory).topLevel ?? workingDirectory
}
