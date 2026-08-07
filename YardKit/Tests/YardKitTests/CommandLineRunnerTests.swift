// CommandLineRunnerTests.swift

import Foundation
import Testing
@testable import YardKit

struct CommandLineRunnerTests {

    // MARK: - No arguments → version envelope, exit 0

    @Test func noArgumentsReturnsVersionEnvelopeWithExitSuccess() throws {
        let result = runYard(arguments: [])

        #expect(result.exitCode == .success)
        assertJsonIsWellFormed(result.stdout, message: "no-args output should be valid JSON")

        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8), options: []) as! [String: Any]
        #expect((json["ok"] as? Bool) == true, "no-args should emit a success envelope")

        let payload = json["result"]
        #expect(payload != nil, "no-args result should be a non-nil EncodableResult")

        #expect(json["schemaVersion"] as? Int == 1, "no-args should use schemaVersion 1")
    }

    // MARK: - No arguments → stdout is the raw envelope bytes, first { last }

    @Test func noArgumentsStdoutFirstByteIsOpenBrace() {
        let result = runYard(arguments: [])
        #expect(result.stdout.first == "{", "no-args stdout first byte should be {, got '\(result.stdout.prefix(30))'")
    }

    @Test func noArgumentsStdoutLastByteIsCloseBrace() {
        let result = runYard(arguments: [])
        #expect(result.stdout.last == "}", "no-args stdout last byte should be }, got '\(result.stdout.suffix(30))'")
    }

    // MARK: - Unrecognised command → usage envelope, exit 1

    @Test func unknownCommandEmitsUsageEnvelopeWithExitOne() throws {
        let result = runYard(arguments: ["bogus-command"])

        #expect(result.exitCode == .usage, "unknown command should exit with usage (1), got \(result.exitCode.rawValue)")
        assertJsonIsWellFormed(result.stdout, message: "unknown-command output should be valid JSON")

        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8), options: []) as! [String: Any]
        #expect((json["ok"] as? Bool) == false, "unknown command should emit ok=false")

        let error = json["error"] as! [String: Any]
        #expect((error["code"] as? String) == "usage", "unknown command error code should be usage")
    }

    @Test func unknownCommandStdoutFirstByteIsOpenBrace() {
        let result = runYard(arguments: ["bogus-command"])
        #expect(result.stdout.first == "{", "unknown-command stdout first byte should be {")
    }

    @Test func unknownCommandStdoutLastByteIsCloseBrace() {
        let result = runYard(arguments: ["bogus-command"])
        #expect(result.stdout.last == "}", "unknown-command stdout last byte should be }")
    }

    // MARK: - Recognised no-op command → success envelope, exit 0

    @Test func noopCommandEmitsSuccessEnvelopeWithExitZero() throws {
        let result = runYard(arguments: ["noop"])

        #expect(result.exitCode == .success, "noop should exit with success (0), got \(result.exitCode.rawValue)")
        assertJsonIsWellFormed(result.stdout, message: "noop output should be valid JSON")

        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8), options: []) as! [String: Any]
        #expect((json["ok"] as? Bool) == true, "noop envelope should have ok=true")

        let schema = json["schemaVersion"] as? Int
        #expect(schema == 1, "noop should use schemaVersion 1")
    }

    @Test func noopStdoutFirstByteIsOpenBrace() {
        let result = runYard(arguments: ["noop"])
        #expect(result.stdout.first == "{", "noop stdout first byte should be {")
    }

    @Test func noopStdoutLastByteIsCloseBrace() {
        let result = runYard(arguments: ["noop"])
        #expect(result.stdout.last == "}", "noop stdout last byte should be }")
    }

    // MARK: - Guard against args.first! — empty array is safe

    @Test func runYardHandlesEmptyArgumentsArraySafely() {
        // This is the "no subscript ahead of guard" case. If anything in runYard
        // evaluates arguments[0] before the isEmpty check, this throws.
        let result = runYard(arguments: [])
        #expect(result.exitCode == .success)
    }

    // MARK: - Unrecognised command also distinguishes from noop via exit code

    @Test func unknownCommandExitCodeIsOneNotZero() {
        let result = runYard(arguments: ["not-a-real-command"])
        #expect(result.exitCode == .usage)
        #expect(result.exitCode != .success, "unknown command should NOT exit 0")
    }

    @Test func noopExitCodeIsZeroNotOne() {
        let result = runYard(arguments: ["noop"])
        #expect(result.exitCode == .success)
        #expect(result.exitCode != .usage, "noop should NOT exit 1")
    }

    // MARK: - Helpers

    private func assertJsonIsWellFormed(_ text: String, message: @autoclosure () -> String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(trimmed.first == "{", "expected JSON object to start with {, got '\(trimmed.prefix(40))'; \(message())")
        #expect(trimmed.last == "}", "expected JSON object to end with }, got '\(trimmed.suffix(40))'; \(message())")

        guard let data = trimmed.data(using: .utf8) else {
            Issue.record("could not re-encode stdout as utf-8; \(message())")
            return
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            Issue.record("JSON parse failed on output; \(message()): \(error)")
        }
    }

}
