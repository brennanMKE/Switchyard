import Foundation
@testable import YardKit
import Testing

// MARK: - Throwing-encode fixture type

/// A payload whose `Encodable.encode(to:)` always throws. We verify that
/// `jsonString(_:)` and the envelope failure path handle this correctly — they
/// must not return an `optionalChainedValue` and must fall back to the literal
/// envelope string.

private struct ThrowingPayload: Encodable, Sendable {
    func encode(to encoder: Encoder) throws {
        throw EnvelopeTestError.encodedAlready
    }

}

private enum EnvelopeTestError: Error {
    case encodedAlready
}

// MARK: - Tests for jsonString path through throwing payload

@Test func jsonStringReturnsLiteralEnvelopeWhenEncodeThrows() throws {
    let payload = ThrowingPayload()
    let wrapper = EncodableResult(payload)

    // `jsonString` catches every throw from encode — including the case where
    // the payload's own encoder throws. It returns the literal envelope bytes,
    // not JSON that contains a partial structure plus "throwing payload" in the
    // error field (the literal string has no `error` key — only Ok:false plus a
    // fixed code and message).

    let result = jsonString(wrapper)

    #expect(result.contains("request_failed"))
    #expect(result.hasPrefix("{"))
    #expect(result.hasSuffix("}"))

    let parsed = try JSONSerialization.jsonObject(with: Data(result.utf8), options: []) as! [String: Any]
    #expect((parsed["ok"] as? Bool) == false)

    let error = parsed["error"] as! [String: Any]
    #expect((error["code"] as? String) == "request_failed")

}

@Test func jsonStringNeverThrowsEvenWithThrowingPayload() {
    // `jsonString` catches every error internally — the caller must not have to
    // deal with a thrown `EncodingError`.

    let payload = ThrowingPayload()
    let wrapper = EncodableResult(payload)

    // No `try` in scope; the call must complete normally.
    let result = jsonString(wrapper)

    #expect(result == encodingFailureEnvelope, "throwing payload must produce the literal envelope")
}

// MARK: - Tests for EnvelopeFail.write() throwing-encode path (no stdout capture)

@Test func encodingFailureEnvelopeMatchesExpectedPayload() throws {
    // The literal envelope string is the same one `write()` emits when it tries
    // to encode a payload that throws. We assert against the literal so any
    // downstream change — even to message wording — is a visible diff.

    #expect(encodingFailureEnvelope.hasPrefix("{"))
    #expect(encodingFailureEnvelope.hasSuffix("}"))

    let parsed = try JSONSerialization.jsonObject(with: Data(encodingFailureEnvelope.utf8), options: []) as! [String: Any]
    #expect((parsed["ok"] as? Bool) == false)

    let error = parsed["error"] as! [String: Any]
    #expect((error["code"] as? String) == "request_failed")

}

@Test func encodingFailureEnvelopeIsAlwaysIdentical() throws {
    // Every call site that falls back to this literal must produce the same
    // bytes, so a mutation test can confirm they stay in sync.

    // The literal must be valid JSON carrying the contracted shape -- comparing
    // it to itself asserts nothing at all.
    let data = try #require(encodingFailureEnvelope.data(using: .utf8))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           "the failure envelope must be a JSON object")
    #expect(obj["schemaVersion"] as? Int == 1)
    #expect(obj["ok"] as? Bool == false)
    let err = try #require(obj["error"] as? [String: Any])
    #expect(err["code"] as? String == "request_failed")
    #expect(err["message"] as? String == "Failed to encode the response.")

}
