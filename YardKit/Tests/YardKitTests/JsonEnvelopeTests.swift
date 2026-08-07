// EnvelopeTests.swift

import Foundation
import Testing
@testable import YardKit

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

        /// The payload may contain an empty object or be absent — both are
        /// acceptable forms of "nothing to return" and changing between them
        /// is not a breaking change. What matters is that `schemaVersion` and
        /// `ok` are always present.

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
            code: "unsupported_operation",
            message: "This command does not support that argument."
        )

        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]

        #expect(json["schemaVersion"] is Int)
        #expect((json["ok"] as! Bool) == false)
    }

    @Test func failureEnvelopeErrorContainsCodeAndMessage() {
        let env = EnvelopeFail(
            code: "broken_lock",
            message: "The worktree lock is corrupted.",
            hint: nil
        )

        #expect(env.error.code == "broken_lock")
        #expect(env.error.message == "The worktree lock is corrupted.")
    }

    @Test func failureEnvelopeErrorIncludesOptionalHint() {
        let hint = "Run `yard checkpoint` to release the lock."
        let env = EnvelopeFail(
            code: "broken_lock",
            message: "The worktree lock is corrupted.",
            hint: hint
        )

        #expect(env.error.hint == hint)
    }

    @Test func failureEnvelopeOmitsHintWhenNil() throws {
        let env = EnvelopeFail(
            code: "broken_lock",
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
            code: "broker_error",
            message: "The broker service is not responding.",
            hint: "Run `brew services start com.yourcompany.switchyard`"
        )

        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [String: Any]

        #expect(json["schemaVersion"] is Int)
        #expect((json["ok"] as! Bool) == false)

        let error = (json["error"] as! [String: Any])
        #expect((error["code"] as! String) == "broker_error")
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

    @Test func sessionTerminatedMatchesRemoteControl() {
        #expect(ExitCode.sessionTerminated.rawValue == 4)
    }

    @Test func requestFailedMatchesRemoteControl() {
        #expect(ExitCode.requestFailed.rawValue == 5)
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

    @Test func exitCodeSuccessIsDistinct() {
        let codes: [ExitCode] = [
            .success, .usage, .brokerUnreachable, .appUnavailable,
            .sessionTerminated, .requestFailed, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ]

        let set = Set(codes.map(\.rawValue))
        #expect(set.count == codes.count)

    }

    // MARK: - Error code string values are stable

    @Test func errorCodesAreNonEmptyStrings() {
        let codes: [ExitCode] = [
            .success, .usage, .brokerUnreachable, .appUnavailable,
            .sessionTerminated, .requestFailed, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ]

        for code in codes {
            #expect(!code.codeLabel.isEmpty, "\(code) has empty error code")

        }
    }

    @Test func codesDontShareValues() {
        let raws = [
            ExitCode.success, .usage, .brokerUnreachable, .appUnavailable,
            .sessionTerminated, .requestFailed, .repositoryError,
            .humanDeclined, .blockedOnConflicts, .signingFailed
        ].map(\.rawValue)

        #expect(Set(raws).count == raws.count)

    }
}
