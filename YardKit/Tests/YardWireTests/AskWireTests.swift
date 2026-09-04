// AskWireTests.swift — the ask wire's bytes are the contract (#0056)
//
// Non-@testable, like every test in this target: the wire is a public-caller
// contract, and @testable would mask a conformance that silently dropped to
// internal (the #0116 failure class).

import Foundation
import Testing
import YardKit

@Suite("Ask wire shape")
struct AskWireTests {

    /// Every answered field populated, asserted against the literal bytes. A
    /// round-trip cannot catch a key both sides share wrongly; the literal is
    /// the contract.
    @Test func fullReplyEncodesToTheLiteralWireShape() throws {
        let reply = AskReply(
            optionIndex: 1,
            optionText: "deploy to staging",
            message: "the second one",
            declined: nil)
        #expect(try wireJSON(reply) == #"{"message":"the second one","optionIndex":1,"optionText":"deploy to staging"}"#)
    }

    /// An answer with nothing extra: the two `nil` optionals OMITTED from
    /// the wire — never `null` (#0129 Decision 4).
    @Test func minimalAnswerOmitsTheAbsentOptionals() throws {
        let reply = AskReply.chosen(index: 0, text: "yes")
        let json = try wireJSON(reply)
        #expect(json == #"{"optionIndex":0,"optionText":"yes"}"#)
        #expect(!json.contains("null"), "absent means absent, never null")
    }

    /// A decline is a decided reply with declined semantics — the marker is
    /// its own key, and the answer keys are absent. With an explanation,
    /// the message rides along.
    @Test func declinedRepliesEncodeToTheirOwnShape() throws {
        #expect(try wireJSON(AskReply.declined()) == #"{"declined":true}"#)
        #expect(try wireJSON(AskReply.declined(message: "not now")) == #"{"declined":true,"message":"not now"}"#)
    }

    /// The request, pinned whole: common dir, verbatim question, options in
    /// order, timeout. The CLI's own shape sends `commonDir` empty — the
    /// app resolves it — so that form is pinned too.
    @Test func requestEncodesToTheLiteralWireShape() throws {
        let resolved = AskRequest(
            commonDir: "/repos/a/.git",
            question: "Deploy now?",
            options: ["yes", "no"],
            timeoutSeconds: 60)
        #expect(try wireJSON(resolved) == #"{"commonDir":"\/repos\/a\/.git","options":["yes","no"],"question":"Deploy now?","timeoutSeconds":60}"#)

        let fromCLI = AskRequest(
            commonDir: "",
            question: "Deploy now?",
            options: ["yes", "no"],
            timeoutSeconds: 3600)
        #expect(try wireJSON(fromCLI) == #"{"commonDir":"","options":["yes","no"],"question":"Deploy now?","timeoutSeconds":3600}"#)
    }

    /// The outcome's two tagged forms. `timedOut` encodes as its own key —
    /// a timeout is never bytes-shaped like a decision. There is no
    /// `superseded`: asks queue instead of replacing (#0056).
    @Test func outcomesEncodeToTheirTaggedForms() throws {
        #expect(try wireJSON(AskOutcome.decided(AskReply.chosen(index: 2, text: "c"))) == #"{"decided":{"optionIndex":2,"optionText":"c"}}"#)
        #expect(try wireJSON(AskOutcome.timedOut) == #"{"timedOut":true}"#)
    }

    /// Both sides share these types, so the bytes decode back to the same
    /// value — asserted, not assumed.
    @Test func replyRequestAndOutcomeRoundTripThroughTheirOwnBytes() throws {
        let reply = AskReply(
            optionIndex: 1, optionText: "b", message: "ship it", declined: nil)
        let decoded = try JSONDecoder().decode(AskReply.self, from: JSONEncoder().encode(reply))
        #expect(decoded == reply)

        let declined = AskReply.declined(message: "later")
        let decodedDeclined = try JSONDecoder().decode(AskReply.self, from: JSONEncoder().encode(declined))
        #expect(decodedDeclined == declined)

        let request = AskRequest(
            commonDir: "/repos/a/.git", question: "Q?", options: ["a"], timeoutSeconds: 5)
        #expect(try JSONDecoder().decode(AskRequest.self, from: JSONEncoder().encode(request)) == request)

        let outcomeBytes = try JSONEncoder().encode(AskOutcome.decided(reply))
        let decodedOutcome = try JSONDecoder().decode(AskOutcome.self, from: outcomeBytes)
        #expect(decodedOutcome == .decided(reply))
    }

    // MARK: - Binding the schema to the type (#0226-style self-reference)

    /// `YardKit/Schemas/ask.json`, resolved from this file's compile-time
    /// path: `Tests/YardWireTests/` → up three → package root.
    private static let askSchemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // YardWireTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // YardKit (package root)
        .appendingPathComponent("Schemas", isDirectory: true)
        .appendingPathComponent("ask.json")

    /// The result carries an array-shaped input (`options`), so the schema
    /// carries the self-reference form — `{"schema": "ask"}`, no field
    /// list — and the type's own encoded keys are pinned here instead, the
    /// way `ReviewWireTests` does for #0055.
    @Test func schemaResultIsTheSelfReferenceAndTheReplyEncodesOnlyItsVocabulary() throws {
        let data = try Data(contentsOf: Self.askSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "ask",
                "ask.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let full = AskReply(
            optionIndex: 1, optionText: "b", message: "m", declined: nil)
        let fullKeys = try topLevelKeys(ofJSON: wireJSON(full))
        #expect(!fullKeys.isEmpty, "a fully-populated answer must encode at least one key")
        #expect(fullKeys == ["message", "optionIndex", "optionText"],
                "a fully-populated answer encodes exactly its three wire keys; got \(fullKeys.sorted())")

        let minimal = AskReply.chosen(index: 0, text: "a")
        let minimalKeys = try topLevelKeys(ofJSON: wireJSON(minimal))
        #expect(!minimalKeys.isEmpty, "a minimally-populated answer must encode at least one key")
        #expect(minimalKeys == ["optionIndex", "optionText"],
                "a minimal answer omits exactly the message key; got \(minimalKeys.sorted())")
        #expect(minimalKeys.isSubset(of: fullKeys),
                "the minimal answer's keys must be a subset of the full answer's keys")

        let declined = AskReply.declined()
        let declinedKeys = try topLevelKeys(ofJSON: wireJSON(declined))
        #expect(declinedKeys == ["declined"],
                "a decline encodes exactly the declined marker; got \(declinedKeys.sorted())")

        let vocabulary = fullKeys.union(minimalKeys).union(declinedKeys)
        #expect(vocabulary == ["declined", "message", "optionIndex", "optionText"],
                "the reply's complete wire vocabulary is fixed; got \(vocabulary.sorted())")
    }
}
