// CommandLineRunner.swift

import Foundation

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

    if command == "noop" {
        return (stdout: jsonString(Envelope()), stderr: "", exitCode: .success)
    }

    let env = EnvelopeFail(code: .usage, message: "Unknown subcommand '\(command)'.")
    let human = "[error] \(env.error.code.rawValue): \(env.error.message)\n"
    return (stdout: jsonString(env), stderr: human, exitCode: .usage)
}

private func jsonString<T: Encodable>(_ value: T) -> String {
    let data = try! JSONEncoder().encode(value)
    return String(data: data, encoding: .utf8)!
}
