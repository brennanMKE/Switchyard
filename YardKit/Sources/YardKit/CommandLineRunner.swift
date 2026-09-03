// CommandLineRunner.swift

import Foundation

internal let encodingFailureEnvelope =
    #"{"schemaVersion":1,"ok":false,"error":{"code":"request_failed","message":"Failed to encode the response."}}"#

/// Command names the CLI answers on its own — no repository, no app. For
/// every name here except `hook`, `runYard` answers it directly; `hook` is
/// intercepted by `dispatch` (`Dispatch.swift`) and answered by
/// `HookArm.run`, which is asynchronous (it drains stdin, then reaches the
/// app over XPC) and so cannot live in the pure `runYard`. `runYard` keeps a
/// `hook` case that refuses with usage, so a stray remote request never
/// falls through to the unknown-command shape by accident.
/// `dispatch(arguments:workingDirectory:connect:)` is the only other reader
/// of this set (via `isAnsweredLocally` below): that is what lets it decide
/// "local or app?" without keeping a second, independently-maintained list
/// that could silently drift from this one. Bare invocation (no arguments at
/// all) is local too, but has no command name to put in a set — `runYard`
/// and `isAnsweredLocally` each handle that case (`arguments.isEmpty`)
/// directly.
let localCommandNames: Set<String> = ["--help", "--version", "-v", "schema", "noop", "hook"]

/// True when `dispatch` can answer `arguments` without reaching the app —
/// either `arguments` is empty (bare invocation) or its first element is in
/// `localCommandNames`. `runYard`'s own dispatch below is built on the same
/// two checks, so the two cannot disagree about what counts as local.
func isAnsweredLocally(_ arguments: [String]) -> Bool {
    guard let command = arguments.first else { return true }
    return localCommandNames.contains(command)
}

/// True when `command` names a real, invocable subcommand this build knows
/// about — i.e. it appears in `CommandRegistry.all`, **excluding**
/// `CommandRegistry.switchyardSpec`. That entry documents the top-level
/// program itself (its `--help`/`--version` flags, rendered by `switchyard
/// schema`) rather than naming a subcommand a caller can type; "switchyard"
/// is not a thing to route anywhere, local or remote.
func isKnownRemoteCommand(_ command: String) -> Bool {
    command != CommandRegistry.switchyardSpec.name
        && CommandRegistry.all.contains { $0.name == command }
}

/// The three ways `dispatch` (`Dispatch.swift`) can answer a command:
///
/// - `.local` — answered by `runYard` on its own, no app.
/// - `.remote` — a real subcommand named in `CommandRegistry.all`, so it
///   needs the app (a repository, or other app-owned state).
/// - `.unknown` — neither: a typo, or a command this build has genuinely
///   never heard of.
///
/// The distinction between `.remote` and `.unknown` is the whole point:
/// only a *known* command may reach for `connect`, whose production
/// implementation launches the app if it is not already running. Routing
/// `.unknown` there too would mean a typo (`wehreami`) launches a GUI
/// application to be told "unknown subcommand" — the app's own `runYard`
/// would say exactly that, just after paying for a process launch to hear
/// it. `.unknown` is answered the same way `.local` is: by `runYard`
/// directly, which produces the identical usage envelope for a name it
/// does not recognize either (it has no case for "whereami" any more than
/// for "wehreami").
enum Route: Equatable {
    case local
    case remote
    case unknown
}

/// Classifies `arguments` into exactly one `Route`. The only reader is
/// `dispatch`; keeping the classification here, built on `isAnsweredLocally`
/// and `isKnownRemoteCommand` above, is what keeps the three cases from
/// being decided by two independently-drifting predicates.
func route(_ arguments: [String]) -> Route {
    if isAnsweredLocally(arguments) { return .local }
    if let command = arguments.first, isKnownRemoteCommand(command) { return .remote }
    return .unknown
}

/// Pure, testable entry-point logic. Takes the argument array *after* the
/// executable name and returns what `switchyard` would write to stdout, any
/// human-readable line for stderr, and the exit code — no I/O of its own.
/// That is what makes it testable: `main.swift` cannot be `@testable import`ed
/// because SwiftPM does not allow that on an executable target.
public func runYard(arguments: [String]) -> (stdout: String, stderr: String, exitCode: ExitCode) {

    guard !arguments.isEmpty else {
        let env = Envelope(result: EncodableResult(VersionResolver.cliVersionSummary(
            forExecutableAt: currentExecutableURL())))
        return (stdout: jsonString(env), stderr: "", exitCode: .success)
    }

    let command = arguments[0]

    guard isAnsweredLocally(arguments) else {
        let env = EnvelopeFail(code: .usage, message: "Unknown subcommand '\(command)'.")
        let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
        return (stdout: jsonString(env), stderr: human, exitCode: .usage)
    }

    switch command {
    case "--help":
        return helpForTopLevel()
    case "--version", "-v":
        let summary = VersionResolver.cliVersionSummary(forExecutableAt: currentExecutableURL())
        return (stdout: summary + "\n", stderr: "", exitCode: .success)

    case "schema":
        return runSchema()

    case "noop":
        return (stdout: jsonString(Envelope()), stderr: "", exitCode: .success)

    case HookArm.commandName:
        // Answered by dispatch → `HookArm.run`, which reads stdin and
        // reaches the app over XPC — neither of which the pure `runYard`
        // may do. Reaching this case means a direct call or a stray remote
        // request (`perform(arguments: ["hook", …])`): refuse with the same
        // usage shape as an unknown subcommand. Hook logic never runs
        // app-side, where no hook process's stdin or environment exists.
        let env = EnvelopeFail(
            code: .usage,
            message: "'hook' is answered by the local hook arm and is never a remote command.")
        let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
        return (stdout: jsonString(env), stderr: human, exitCode: .usage)

    default:
        // Unreachable: isAnsweredLocally(arguments) admits exactly
        // localCommandNames, which lists precisely the cases above. Falls
        // back to the same "unknown subcommand" shape rather than trapping,
        // matching how the rest of this file degrades (e.g.
        // ExitCode(fromAppReply:) never traps on an unrecognized value).
        let env = EnvelopeFail(code: .usage, message: "Unknown subcommand '\(command)'.")
        let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
        return (stdout: jsonString(env), stderr: human, exitCode: .usage)
    }
}

/// Runs a command and returns exactly what the CLI must print, plus the exit
/// code as it crosses the XPC boundary — `Data` because `NSXPCInterface`
/// carries no Swift `String`/`enum` guarantees, `Int32` because `ExitCode` is
/// `Int`-backed. See guide §11 decision 15.
///
/// This is the single body both sides of the wire run: `AppService.perform`
/// in `Switchyard/AppXPCServer.swift` is a thin forwarder to this function
/// plus `reply(...)`, and a test's in-process fake calls this same function
/// rather than reimplementing its encoding — so a bug here is caught by the
/// package test suite, which `swift test` builds, instead of living only in
/// the app target, which it does not.
public func performCommand(
    arguments: [String],
    workingDirectory: String
) -> (stdout: Data, exitCode: Int32) {
    // workingDirectory is threaded through the wire now so a future
    // engine-backed command (#0124) can resolve paths relative to the CLI's
    // cwd rather than the app's; runYard does not consume it yet.
    let result = runYard(arguments: arguments)
    let data = result.stdout.data(using: .utf8) ?? Data()
    return (stdout: data, exitCode: Int32(result.exitCode.rawValue))
}

// MARK: - --help / --version helpers

private func helpForTopLevel() -> (stdout: String, stderr: String, exitCode: ExitCode) {
    let rendered = renderHelp(for: CommandRegistry.switchyardSpec)
    return (stdout: rendered, stderr: "", exitCode: .success)
}

// MARK: - schema

private func runSchema() -> (stdout: String, stderr: String, exitCode: ExitCode) {
    do {
        var pieces: [String] = []
        for spec in CommandRegistry.all {
            let rendered = try renderSchema(for: spec)
            pieces.append(rendered.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let schemaBody = pieces.joined(separator: ",")
        // Parse the raw JSON body into a typed [String: Any] value so that
        // .sortedKeys and .prettyPrinted can work on the *outer* envelope too.
        let raw = "{\"schemaVersion\":1,\"ok\":true,\"result\":{\"commands\":[\(schemaBody)]}}"
            .data(using: .utf8)
        guard let raw = raw else {
            return (stdout: encodingFailureEnvelope, stderr: "", exitCode: .requestFailed)
        }
        let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        guard let root = root else {
            return (stdout: encodingFailureEnvelope, stderr: "", exitCode: .requestFailed)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let payload = String(data: data, encoding: .utf8) else {
            return (stdout: encodingFailureEnvelope, stderr: "", exitCode: .requestFailed)
        }
        return (stdout: payload, stderr: "", exitCode: .success)
    } catch {
        let env = EnvelopeFail(code: .requestFailed, message: "Failed to render schema: \(error.localizedDescription)")
        let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
        return (stdout: jsonString(env), stderr: human, exitCode: .requestFailed)
    }
}

// MARK: - Internal helpers (exposed for testing)

/// The executable the version resolver walks up from. `Bundle.main` is the
/// honest answer for a real CLI process — a bundled binary, or a bare one —
/// with the raw `argv[0]` as the fallback when there is no bundle at all.
/// `VersionResolver` takes this as a parameter rather than reading
/// `Bundle.main` internally, which is what keeps its two branches testable.
internal func currentExecutableURL() -> URL {
    if let executable = Bundle.main.executableURL { return executable }
    return URL(fileURLWithPath: CommandLine.arguments.first ?? "")
}

internal func jsonString<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return encodingFailureEnvelope
    }
    return text
}
