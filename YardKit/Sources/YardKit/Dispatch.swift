// Dispatch.swift

import Foundation

/// Decides whether `arguments` can be answered locally and, if not, runs it
/// through the app. `connect` is injectable so the decision is testable
/// without an app, a broker, or a launch agent.
///
/// "Locally" is derived from `isAnsweredLocally(_:)` in
/// `CommandLineRunner.swift` — the same predicate `runYard` itself uses —
/// rather than a second, hand-maintained list of command names next to
/// `CommandRegistry`. Two lists drift silently; one predicate consulted
/// twice cannot.
///
/// The remote path writes back exactly what the app sent: `AppConnection
/// .perform` already returns `runYard`'s own bytes unmodified (see guide
/// §11 decision 15 and `AppConnectionTests.performRoundTripsBytesExactly`),
/// so nothing here re-encodes them — only `Data` → `String` to match this
/// function's return shape, which is lossless for the UTF-8 JSON every
/// command emits.
public func dispatch(
    arguments: [String],
    workingDirectory: String,
    connect: () async throws -> AppConnection = { try await AppConnection.connect() }
) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
    guard !isAnsweredLocally(arguments) else {
        return runYard(arguments: arguments)
    }

    do {
        let app = try await connect()
        defer { app.close() }
        let (data, exitCode) = try await app.perform(
            arguments: arguments, workingDirectory: workingDirectory)
        return (stdout: String(decoding: data, as: UTF8.self), stderr: "", exitCode: ExitCode(fromAppReply: exitCode))
    } catch let error as AppConnectionError {
        return connectionFailureResult(exitCode: error.exitCode, message: String(describing: error))
    } catch let error as CLIError {
        return connectionFailureResult(exitCode: error.exitCode, message: String(describing: error))
    } catch {
        return connectionFailureResult(exitCode: .requestFailed, message: String(describing: error))
    }
}

/// Builds the same structured failure envelope `runYard`'s own error paths
/// emit — schemaVersion 1, `ok: false`, `error.code`/`error.message` — from
/// an `ExitCode` the app-connection layer already computed. `AppConnection
/// Error.exitCode` and `CLIError.exitCode` are switched exhaustively over
/// codes 2-5 (#0048), so this only has to turn that code back into the
/// matching `EnvelopeErrorCode` string; `ExitCode.codeLabel` and
/// `EnvelopeErrorCode.rawValue` are the same closed set of strings by
/// construction (`SchemaGoldenTests` pins that both surfaces agree), so the
/// round-trip through `rawValue` cannot land on the wrong code.
private func connectionFailureResult(
    exitCode: ExitCode, message: String
) -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let code = EnvelopeErrorCode(rawValue: exitCode.codeLabel) ?? .requestFailed
    let env = EnvelopeFail(code: code, message: message)
    let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
    return (stdout: jsonString(env), stderr: human, exitCode: exitCode)
}
