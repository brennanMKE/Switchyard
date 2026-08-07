// TryTrapScenarios.swift

import Foundation
import Testing
@testable import YardKit

/// Regression tests for the three shapes identified in issue 0114:
/// encoding failure via jsonString, writing an EnvelopeFail without traps.

struct TryTrapScenarios {

    // MARK: - Scenario 1: jsonString produces valid JSON even if encode fails.

    /// All Encodable values run through `runYard` which uses `jsonString`.
    /// The fix uses `try?` so this never traps.

    @Test func runYardReturnsValidJsonForNoArguments() throws {
        let result = runYard(arguments: [])

        #expect(!result.stdout.isEmpty, "runYard should produce non-empty stdout")
        #expect(result.stdout.first == "{", "no-args output should start with {")

        // Parse and validate the envelope has ok=true with correct version.
        let data = try #require(Data(result.stdout.utf8))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((obj["ok"] as? Bool) == true, "default envelope is ok")
        #expect((obj["schemaVersion"] as? Int) == 1, "default envelope has schema version 1")
    }

    // MARK: - Scenario 2: write() for EnvelopeFail never traps on encoding.

    @Test func envelopeFailWritesJsonToStdoutAndHumanReadableErrorToStderr() throws {
        let env = EnvelopeFail(code: .usage, message: "unknown command 'test'")

        // Redirect stdout and stderr to pipes. We have to redirect via file
        // descriptors because FileHandle.standardOutput/standardError are read-only.
        let stdoutSave = dup(STDOUT_FILENO)
        let stderrSave = dup(STDERR_FILENO)
        defer {
            dup2(stdoutSave, STDOUT_FILENO)
            dup2(stderrSave, STDERR_FILENO)
            close(stdoutSave)
            close(stderrSave)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // Must not throw or trap.
        env.write()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        // The standard error line is human readable.
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        #expect(stderrText.contains("[error]"), "stderr should contain [error]")

        // stdout contains the JSON envelope.
        #expect(!stdoutData.isEmpty, "stdout should not be empty")

        // Use `guard let` pattern per Rule 7b.
        guard let obj = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            Issue.record("failed to parse envelope from stdout")
            return
        }

        #expect((obj["ok"] as? Bool) == false, "failure envelope has ok=false")
        #expect((obj["schemaVersion"] as? Int) == 1, "failure envelope has schema version 1")

        let error = obj["error"] as? [String: Any]
        #expect((error?["code"] as? String) == "usage")
        #expect((error?["message"] as? String) == "unknown command 'test'")
    }

    // MARK: - Scenario 3: the failure envelope is used when encode fails.

    @Test func runYardReturnsUsageEnvelopeForUnknownCommand() throws {
        let result = runYard(arguments: ["bogus-subcommand"])

        // Must be well-formed JSON.
        let data = try #require(Data(result.stdout.utf8))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect((obj["ok"] as? Bool) == false, "unknown command → ok=false")
        #expect((obj["schemaVersion"] as? Int) == 1, "unknown command → schema version 1")

        let error = obj["error"] as? [String: Any]
        #expect((error?["code"] as? String) == "usage", "unknown command → code=usage")
        #expect(result.exitCode == .usage, "runYard exits with usage (1)")
    }

}
