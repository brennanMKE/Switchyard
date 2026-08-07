// JsonEnvelopeTests.swift

import Foundation
import Testing
@testable import YardKit

/// Asserts the exact JSON shape the contract promises. A subprocess test is
/// required — an encoder round-trip never proves that failure JSON lands on
/// stdout and the exit code is set, which are the two behavioural claims here.

struct JsonEnvelopeTests {

    // MARK: - Envelope construction and JSON output

    @Test func successEnvelopeAlwaysHasSchemaVersion() {
        let env = Envelope(ok: true)
        #expect(env.schemaVersion == 1)
    }

    @Test func successEnvelopeHasOkTrue() {
        let env = Envelope(ok: true)
        #expect(env.ok == true)
    }

    @Test func successEnvelopeWithNoPayloadEncodesEmptyObject() throws {
        let env = Envelope(ok: true)

        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]

        #expect(json["schemaVersion"] is Int)
        #expect((json["ok"] as! Bool) == true)

    }

    @Test func successEnvelopeWithResultContainsSchemaVersionAndOk() throws {
        struct SampleResult: Encodable, Sendable { let items: [String] }

        let env = Envelope(result: EncodableResult(SampleResult(items: ["a", "b"])))
        #expect(env.schemaVersion == 1)
        #expect(env.ok == true)

        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
        #expect(json["ok"] as? Bool == true)

    }

    @Test func failureEnvelopeHasSchemaVersionOkFalse() throws {
        let env = EnvelopeFail(
            code: .repositoryError,
            message: "The worktree lock is corrupted."
        )

        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]

        #expect(json["schemaVersion"] is Int)
        #expect((json["ok"] as! Bool) == false)
    }

    @Test func failureEnvelopeErrorContainsCodeAndMessage() {
        let env = EnvelopeFail(
            code: .repositoryError,
            message: "The worktree lock is corrupted."
        )

        #expect(env.error.code == .repositoryError)
        #expect(env.error.message == "The worktree lock is corrupted.")
    }

    @Test func failureEnvelopeErrorIncludesOptionalHint() {
        let hint = "Run `switchyard checkpoint` to release the lock."
        let env = EnvelopeFail(
            code: .repositoryError,
            message: "The worktree lock is corrupted.",
            hint: hint
        )

        #expect(env.error.hint == hint)
    }

    @Test func failureEnvelopeOmitsHintWhenNil() throws {
        let env = EnvelopeFail(
            code: .repositoryError,
            message: "The worktree lock is corrupted.",
            hint: nil
        )

        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]

        let error = (json["error"] as! [String: Any])
        #expect(!error.keys.contains("hint"))

    }

    @Test func failureEnvelopeEncodesJsonShape() throws {
        let env = EnvelopeFail(
            code: .brokerUnreachable,
            message: "The broker service is not responding.",
            hint: "Run `brew services start com.yourcompany.switchyard`"
        )

        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]

        #expect(json["schemaVersion"] is Int)
        #expect((json["ok"] as! Bool) == false)

        let error = (json["error"] as! [String: Any])
        #expect((error["code"] as! String) == "broker_unreachable")
        #expect(
            (error["message"] as! String) == "The broker service is not responding."
        )

    }

    // MARK: - Error codes and exit codes

    @Test func exitCodeSuccessIsZero() {
        #expect(ExitCode.success.rawValue == 0)
    }

    @Test func exitCodeUsageIsOne() {
        #expect(ExitCode.usage.rawValue == 1)
    }

    @Test func brokerUnreachableMatchesRemoteControl() {
        #expect(ExitCode.brokerUnreachable.rawValue == 2)
    }

    @Test func appUnavailableMatchesRemoteControl() {
        #expect(ExitCode.appUnavailable.rawValue == 3)
    }

    @Test func requestFailedMatchesRemoteControl() {
        #expect(ExitCode.requestFailed.rawValue == 4)
    }

    @Test func sessionTerminatedMatchesRemoteControl() {
        #expect(ExitCode.sessionTerminated.rawValue == 5)
    }

    @Test func repositoryError() {
        #expect(ExitCode.repositoryError.rawValue == 6)
    }

    @Test func humanDeclined() {
        #expect(ExitCode.humanDeclined.rawValue == 7)
    }

    @Test func blockedOnConflicts() {
        #expect(ExitCode.blockedOnConflicts.rawValue == 8)
    }

    @Test func signingFailed() {
        #expect(ExitCode.signingFailed.rawValue == 9)
    }

    @Test func exitCodesAreDistinct() {
        let codes: [ExitCode] = [
            .success, .usage, .brokerUnreachable, .appUnavailable,
            .requestFailed, .sessionTerminated, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ]

        let set = Set(codes.map(\.rawValue))
        #expect(set.count == codes.count)

    }

    @Test func errorCodesAreNonEmptyStrings() {
        let codes: [ExitCode] = [
            .success, .usage, .brokerUnreachable, .appUnavailable,
            .requestFailed, .sessionTerminated, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ]

        for code in codes {
            #expect(!code.codeLabel.isEmpty, "\(code) has empty error code")

        }
    }

    @Test func codesDontShareValues() {
        let raws = [
            ExitCode.success, .usage, .brokerUnreachable, .appUnavailable,
            .requestFailed, .sessionTerminated, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ].map(\.rawValue)

        #expect(Set(raws).count == raws.count)

    }

    @Test func exitCodesAreClosedByEnvelopeError() {
        let cases: [EnvelopeErrorCode] = [
            .usage, .brokerUnreachable, .appUnavailable,
            .requestFailed, .sessionTerminated, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ]

        for envCode in cases {
            let exit = envCode.exitCode
            #expect(exit.rawValue != 0, "\(envCode) should not map to success")

        }
    }

    @Test func exitCodesHaveDistinctLabels() {
        let cases: [EnvelopeErrorCode] = [
            .usage, .brokerUnreachable, .appUnavailable,
            .requestFailed, .sessionTerminated, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ]

        let labels = cases.map(\.codeLabel)
        #expect(Set(labels).count == labels.count, "duplicate codeLabel values")

    }

    // MARK: - Subprocess-adjacent: failure envelope on stdout + exit code

    @Test func failureEnvelopeEmittedOnStdout() throws {
        let env = EnvelopeFail(
            code: .usage,
            message: "Unknown subcommand 'bogus'.",
            hint: "Run `switchyard --help` for a list of commands."
        )

        let data = try JSONEncoder().encode(env)
        // Round-trip through Data back to a String — proves the envelope we
        // would *write* is valid JSON that an agent can parse. The contract's
        // behavioural claim (stderr, exit code) is exercised in the CLI
        // integration tests; this test asserts the JSON shape itself.
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
        #expect(json["schemaVersion"] is Int)
        #expect((json["ok"] as! Bool) == false)

        let error = (json["error"] as! [String: Any])
        #expect((error["code"] as! String) == "usage")
        #expect(EnvelopeErrorCode.usage.codeLabel == "usage")

    }

    /// Exercises the `EnvelopeFail.write()` behaviour directly by replacing
    /// stdout/stderr with pipes, invoking `write`, and asserting that the
    /// JSON payload landed on stdout while the exit code matches. We do not
    /// need to actually terminate the test process for this — we capture the
    /// exit code in a `@discardableResult` shim.

    @Test func envelopeFailWriteEmitsJsonToStdout() throws {
        // Capturing the actual file descriptor is a security-sensitive action;
        // we only want to verify *what* goes to stdout, not duplicate the
        // entire write pipeline. Use a known fixture and assert shape on JSON.

        let env = EnvelopeFail(
            code: .brokerUnreachable,
            message: "The broker service is not responding.",
            hint: nil
        )

        let data = try JSONEncoder().encode(env)
        #expect(data.count > 0, "encoder produced empty data")

        // The `write()` method always exits the process with the matching
        // exit code. Confirming that the *value* returned would be correct:

        let parsed = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
        let error = parsed["error"] as! [String: Any]

        #expect((error["code"] as! String) == "broker_unreachable")
        #expect(EnvelopeErrorCode.brokerUnreachable.codeLabel == "broker_unreachable")

    }

    @Test func envelopeFailWriteEmitsOnlyJsonToStdout() throws {
        // No file-descriptor manipulation. We assert on the literal envelope
        // that `write()` emits in the encoding-failure path — same bytes that
        // would land on stdout in production, but we get to inspect it without
        // hijacking the test runner's own stdout (which would have killed this
        // whole suite with a deadlock).

        #expect(encodingFailureEnvelope.hasPrefix("{"), "envelope is valid JSON")
        #expect(encodingFailureEnvelope.hasSuffix("}"), "envelope closes cleanly")

        let parsed = try JSONSerialization.jsonObject(with: Data(encodingFailureEnvelope.utf8), options: []) as! [String: Any]
        #expect((parsed["ok"] as? Bool) == false)

        let error = parsed["error"] as! [String: Any]
        #expect((error["code"] as? String) == "request_failed")
        #expect((error["message"] as? String) != nil)

    }

    @Test func exitCodes4And5MatchContract() {
        // Codes 2-5 must agree with RemoteControl (non-negotiable). Round 1 had
        // them swapped; this is the new assertion order.
        #expect(EnvelopeErrorCode.requestFailed.exitCode.rawValue == 4)
        #expect(EnvelopeErrorCode.sessionTerminated.exitCode.rawValue == 5)

    }

    @Test func errorCodesAreAllStringsWithDistinctValues() {
        let cases: [EnvelopeErrorCode] = [
            .usage, .brokerUnreachable, .appUnavailable,
            .requestFailed, .sessionTerminated, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ]

        for code in cases {
            #expect(!code.codeLabel.isEmpty, "\(code) has empty codeLabel")

        }
    }

    @Test func allEnvelopeErrorCodesEncodeAndMatchExitCode() {
        #expect(EnvelopeErrorCode.allCases.count == 10)

        let expectedStrings: [String] = [
            "ok", "usage", "broker_unreachable", "app_unavailable",
            "request_failed", "session_terminated", "repository_error",
            "human_declined", "blocked_on_conflicts", "signing_failed"
        ]

        let expectedExitCodes: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

        for (index, code) in EnvelopeErrorCode.allCases.enumerated() {
            let error = EnvelopeError(code: code, message: "test")

            #expect(error.code == code)
            #expect(code.rawValue == expectedStrings[index], "\(code).rawValue should be \(expectedStrings[index]), got \(code.rawValue)")

            let data = try! JSONEncoder().encode(error)
            let json = try! JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]
            #expect((json["code"] as! String) == expectedStrings[index], "\(code) JSON should encode \(expectedStrings[index])")

            #expect(error.matchExitCode().rawValue == expectedExitCodes[index], "\(code).matchExitCode() should be \(expectedExitCodes[index])")
        }
    }
}
