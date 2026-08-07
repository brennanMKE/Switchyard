// CommandLineRunner.swift

import Foundation

internal let encodingFailureEnvelope =
    #"{"schemaVersion":1,"ok":false,"error":{"code":"request_failed","message":"Failed to encode the response."}}"#

/// Pure, testable entry-point logic. Takes the argument array *after* the
/// executable name and returns what `switchyard` would write to stdout, any
/// human-readable line for stderr, and the exit code — no I/O of its own.
/// That is what makes it testable: `main.swift` cannot be `@testable import`ed
/// because SwiftPM does not allow that on an executable target.
public func runYard(arguments: [String]) -> (stdout: String, stderr: String, exitCode: ExitCode) {

    guard !arguments.isEmpty else {
        let summary = "\(ServiceNames.cliName) \(YardKit.version)"
        let env = Envelope(result: EncodableResult(summary))
        return (stdout: jsonString(env), stderr: "", exitCode: .success)
    }

    let command = arguments[0]

    switch command {
    case "--help":
        return helpForTopLevel()
    case "--version", "-v":
        let summary = "\(ServiceNames.cliName) \(YardKit.version)"
        return (stdout: summary + "\n", stderr: "", exitCode: .success)

    case "schema":
        return runSchema()

    case "noop":
        return (stdout: jsonString(Envelope()), stderr: "", exitCode: .success)

    default:
        break
    }

    let env = EnvelopeFail(code: .usage, message: "Unknown subcommand '\(command)'.")
    let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
    return (stdout: jsonString(env), stderr: human, exitCode: .usage)
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

internal func jsonString<T: Encodable>(_ value: T) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return encodingFailureEnvelope
    }
    return text
}
