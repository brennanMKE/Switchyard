// ReviewWireTests.swift — the review wire's bytes are the contract (#0055)
//
// Non-@testable, like every test in this target: the wire is a public-caller
// contract, and @testable would mask a conformance that silently dropped to
// internal (the #0116 failure class).

import Foundation
import Testing
import YardKit

@Suite("Review wire shape")
struct ReviewWireTests {

    /// Every field populated, asserted against the literal bytes. A
    /// round-trip cannot catch a key both sides share wrongly; the literal is
    /// the contract.
    @Test func fullReplyEncodesToTheLiteralWireShape() throws {
        let reply = ReviewReply(
            decision: .amend,
            message: "fix the typo in the message",
            comments: [
                ReviewComment(
                    path: "Sources/YardKit/AppConnection.swift",
                    hunkID: "h2", line: 41,
                    text: "rename this"),
                ReviewComment(
                    path: "Sources/YardKit/Envelope.swift",
                    hunkID: "h1", line: nil,
                    text: "split this"),
            ],
            editedPatch: "patch-bytes")
        #expect(try wireJSON(reply) == #"{"comments":[{"hunkID":"h2","line":41,"path":"Sources\/YardKit\/AppConnection.swift","text":"rename this"},{"hunkID":"h1","path":"Sources\/YardKit\/Envelope.swift","text":"split this"}],"decision":"amend","editedPatch":"patch-bytes","message":"fix the typo in the message"}"#)
    }

    /// A rejection with nothing extra: every nil optional OMITTED from the
    /// wire, `comments` an empty array — never `null` (#0129 Decision 4).
    @Test func minimalReplyOmitsTheAbsentOptionals() throws {
        let reply = ReviewReply(
            decision: .reject, message: nil, comments: [], editedPatch: nil)
        let json = try wireJSON(reply)
        #expect(json == #"{"comments":[],"decision":"reject"}"#)
        #expect(!json.contains("null"), "absent means absent, never null")
    }

    /// The decision's case name IS the wire key (#0130). Every case, each
    /// iteration asserting.
    @Test func decisionEncodesAsItsCaseName() throws {
        #expect(ReviewDecision.allCases.count == 3,
                "a new decision case must update this pin and the wire contract")
        for decision in ReviewDecision.allCases {
            #expect(try wireJSON(decision) == "\"\(decision.rawValue)\"")
        }
    }

    /// The two selector forms, pinned apart: `{"staged":true}` vs
    /// `{"range":"..."}` — one key each, so a branch literally named `staged`
    /// can never be confused with the flag.
    @Test func requestEncodesBothSelectorForms() throws {
        let range = ReviewRequest(
            commonDir: "/repos/a/.git",
            selector: .range("main..HEAD"),
            timeoutSeconds: 3600)
        #expect(try wireJSON(range) == #"{"commonDir":"\/repos\/a\/.git","selector":{"range":"main..HEAD"},"timeoutSeconds":3600}"#)

        let staged = ReviewRequest(
            commonDir: "/repos/a/.git",
            selector: .staged,
            timeoutSeconds: 30)
        #expect(try wireJSON(staged) == #"{"commonDir":"\/repos\/a\/.git","selector":{"staged":true},"timeoutSeconds":30}"#)
    }

    /// The outcome's three tagged forms. `timedOut` and `superseded` encode
    /// as their own keys — a timeout or a supersede is never bytes-shaped
    /// like a decision.
    @Test func outcomesEncodeToTheirTaggedForms() throws {
        let reply = ReviewReply(
            decision: .approve, message: nil, comments: [], editedPatch: nil)
        #expect(try wireJSON(ReviewOutcome.decided(reply)) == #"{"decided":{"comments":[],"decision":"approve"}}"#)
        #expect(try wireJSON(ReviewOutcome.timedOut) == #"{"timedOut":true}"#)
        #expect(try wireJSON(ReviewOutcome.superseded) == #"{"superseded":true}"#)
    }

    /// Both sides share these types, so the bytes decode back to the same
    /// value — asserted, not assumed.
    @Test func replyAndOutcomeRoundTripThroughTheirOwnBytes() throws {
        let reply = ReviewReply(
            decision: .approve,
            message: "ship it",
            comments: [ReviewComment(path: "f.txt", hunkID: "h1", line: 3, text: "nit")],
            editedPatch: nil)
        let decoded = try JSONDecoder().decode(ReviewReply.self, from: JSONEncoder().encode(reply))
        #expect(decoded == reply)

        let outcomeBytes = try JSONEncoder().encode(ReviewOutcome.decided(reply))
        let decodedOutcome = try JSONDecoder().decode(ReviewOutcome.self, from: outcomeBytes)
        #expect(decodedOutcome == .decided(reply))
    }

    // MARK: - Binding the schema to the type (#0226-style self-reference)

    /// `YardKit/Schemas/review.json`, resolved from this file's compile-time
    /// path: `Tests/YardWireTests/` → up three → package root.
    private static let reviewSchemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // YardWireTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // YardKit (package root)
        .appendingPathComponent("Schemas", isDirectory: true)
        .appendingPathComponent("review.json")

    /// The result is array-bearing (`comments` is an array of objects), so
    /// the schema carries the self-reference form — `{"schema": "review"}`,
    /// no field list — and the type's own encoded keys are pinned here
    /// instead, the way `ConflictsCommandTests` does for #0226's
    /// array-bearing result.
    @Test func schemaResultIsTheSelfReferenceAndTheReplyEncodesOnlyItsFourKeys() throws {
        let data = try Data(contentsOf: Self.reviewSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "review",
                "review.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let full = ReviewReply(
            decision: .amend,
            message: "m",
            comments: [ReviewComment(path: "f.txt", hunkID: "h1", line: 3, text: "t")],
            editedPatch: "p")
        let fullKeys = try topLevelKeys(ofJSON: wireJSON(full))
        #expect(!fullKeys.isEmpty, "a fully-populated reply must encode at least one key")
        #expect(fullKeys == ["comments", "decision", "editedPatch", "message"],
                "a fully-populated reply encodes exactly its four wire keys; got \(fullKeys.sorted())")

        let minimal = ReviewReply(
            decision: .reject, message: nil, comments: [], editedPatch: nil)
        let minimalKeys = try topLevelKeys(ofJSON: wireJSON(minimal))
        #expect(!minimalKeys.isEmpty, "a minimally-populated reply must encode at least one key")
        #expect(minimalKeys == ["comments", "decision"],
                "a minimal reply omits exactly the two optional keys; got \(minimalKeys.sorted())")
        #expect(minimalKeys.isSubset(of: fullKeys),
                "the minimal reply's keys must be a subset of the full reply's keys")
    }
}
