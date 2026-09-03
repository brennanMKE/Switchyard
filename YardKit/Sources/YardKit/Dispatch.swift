// Dispatch.swift

import Foundation

/// Decides how `arguments` should be answered and, for the one case that
/// needs it, runs the command through the app. `connect` is injectable so
/// the decision is testable without an app, a broker, or a launch agent.
///
/// The decision is `route(_:)` in `CommandLineRunner.swift` — a three-way
/// classification (`.local`, `.remote`, `.unknown`), not a single boolean.
/// The three-way split matters: `connect`'s production implementation
/// launches the app if it is not already running, so only a *known*
/// command (`.remote`) may reach it. Collapsing `.remote` and `.unknown`
/// into one "not local" case — the two-way split this function used before
/// — means a typo (`wehreami`) launches a GUI application to be told
/// "unknown subcommand" it could have been told locally, for free.
/// `.unknown` is answered exactly like `.local`: by calling `runYard`
/// directly, which produces the same usage envelope for a name it does not
/// recognize either, without this function building a second copy of that
/// shape.
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
    connect: () async throws -> AppConnection = { try await AppConnection.connect() },
    connectHook: () async throws -> AppConnection = {
        try await AppConnection.connect(launchIfNeeded: false)
    }
) async -> (stdout: String, stderr: String, exitCode: ExitCode) {
    switch route(arguments) {
    case .local, .unknown:
        // The hook arm (#0154) is local but not pure — it drains stdin and
        // reaches the app over XPC — so dispatch intercepts it before the
        // synchronous `runYard`. Its connector is a second injectable with
        // `launchIfNeeded: false` baked in: a hook must never launch the
        // app, which the ordinary remote `connect` above would do. (`route`
        // can only classify `hook` as `.local`, never `.unknown` — it is in
        // `localCommandNames` — so the name check below is exact.)
        if arguments.first == HookArm.commandName {
            return await HookArm.run(
                arguments: arguments,
                workingDirectory: workingDirectory,
                connect: connectHook)
        }
        return runYard(arguments: arguments)

    case .remote:
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
