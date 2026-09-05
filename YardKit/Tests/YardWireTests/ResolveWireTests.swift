// ResolveWireTests.swift — the resolve wire's bytes are the contract (#0057)
//
// Non-@testable, like every test in this target: the wire is a public-caller
// contract, and @testable would mask a conformance that silently dropped to
// internal (the #0116 failure class).

import Foundation
import Testing
import YardKit

@Suite("Resolve wire shape")
struct ResolveWireTests {

    /// Every field populated, asserted against the literal bytes. A
    /// round-trip cannot catch a key both sides share wrongly; the literal is
    /// the contract.
    @Test func fullPathResolutionEncodesToTheLiteralWireShape() throws {
        let resolution = PathResolution(
            path: "Sources/YardKit/AppConnection.swift",
            kind: .bothModified,
            choice: .editedContent,
            editedContent: "merged text\n",
            note: "kept the docs paragraph")
        #expect(try wireJSON(resolution) == #"{"choice":"editedContent","editedContent":"merged text\n","kind":"UU","note":"kept the docs paragraph","path":"Sources\/YardKit\/AppConnection.swift"}"#)
    }

    /// A use-ours choice with nothing extra: both nil optionals OMITTED from
    /// the wire — never `null` (#0129 Decision 4).
    @Test func minimalPathResolutionOmitsTheAbsentOptionals() throws {
        let resolution = PathResolution(
            path: "f.txt", kind: .bothAdded, choice: .useOurs,
            editedContent: nil, note: nil)
        let json = try wireJSON(resolution)
        #expect(json == #"{"choice":"useOurs","kind":"AA","path":"f.txt"}"#)
        #expect(!json.contains("null"), "absent means absent, never null")
    }

    /// The kind's case name IS the wire key — and the raw values are the
    /// porcelain XY pairs themselves, so the wire record reads next to `git
    /// status --porcelain=v2`. Every case, each iteration asserting.
    @Test func conflictKindEncodesAsItsPorcelainPair() throws {
        #expect(ConflictKind.allCases.count == 7,
                "a new conflict kind must update this pin and the wire contract")
        for kind in ConflictKind.allCases {
            #expect(try wireJSON(kind) == "\"\(kind.rawValue)\"")
        }
    }

    /// The per-card choice vocabulary: the case name IS the wire key
    /// (#0130). Every case, each iteration asserting.
    @Test func pathChoiceEncodesAsItsCaseName() throws {
        #expect(PathChoice.allCases.count == 7,
                "a new path choice must update this pin and the wire contract")
        for choice in PathChoice.allCases {
            #expect(try wireJSON(choice) == "\"\(choice.rawValue)\"")
        }
    }

    /// The request's two forms: a scoped pathspec, and no pathspec (every
    /// conflicted path) — the absent optional omitted from the wire.
    @Test func requestEncodesWithAndWithoutAPathspec() throws {
        let scoped = ResolveRequest(
            commonDir: "/repos/a/.git", pathspec: "Sources", timeoutSeconds: 3600)
        #expect(try wireJSON(scoped) == #"{"commonDir":"\/repos\/a\/.git","pathspec":"Sources","timeoutSeconds":3600}"#)

        let all = ResolveRequest(
            commonDir: "/repos/a/.git", pathspec: nil, timeoutSeconds: 30)
        let json = try wireJSON(all)
        #expect(json == #"{"commonDir":"\/repos\/a\/.git","timeoutSeconds":30}"#)
        #expect(!json.contains("null"), "absent means absent, never null")
    }

    /// The request's scope rule: absent pathspec covers everything; a
    /// pathspec covers its own path and anything under the directory it
    /// names — but not a similarly-prefixed sibling file.
    @Test func requestScopeMatchesExactlyOrUnderTheNamedDirectory() throws {
        let all = ResolveRequest(commonDir: "/", pathspec: nil, timeoutSeconds: 60)
        #expect(all.matches(path: "any/f.txt"))

        let file = ResolveRequest(commonDir: "/", pathspec: "f.txt", timeoutSeconds: 60)
        #expect(file.matches(path: "f.txt"))
        #expect(!file.matches(path: "f.txt.bak"), "a prefix without / must not match")
        #expect(!file.matches(path: "g/f.txt"))

        let directory = ResolveRequest(commonDir: "/", pathspec: "Sources", timeoutSeconds: 60)
        #expect(directory.matches(path: "Sources"))
        #expect(directory.matches(path: "Sources/YardKit/AppConnection.swift"))
        #expect(!directory.matches(path: "SourcesOther/f.txt"))
    }

    /// The reply's two tagged forms — `{"resolutions":[…]}` vs
    /// `{"cancelled":true}` — pinned apart, so a submitted stack and a
    /// cancellation can never be bytes-shaped alike.
    @Test func replyEncodesBothTaggedForms() throws {
        let reply = ResolveReply.resolutions([
            PathResolution(path: "f.txt", kind: .bothModified, choice: .useOurs),
            PathResolution(path: "g.txt", kind: .deletedByThem, choice: .keepModification,
                           editedContent: nil, note: "kept ours' version"),
        ])
        #expect(try wireJSON(reply) == #"{"resolutions":[{"choice":"useOurs","kind":"UU","path":"f.txt"},{"choice":"keepModification","kind":"UD","note":"kept ours' version","path":"g.txt"}]}"#)

        let cancelled = ResolveReply.cancelled
        let cancelledJSON = try wireJSON(cancelled)
        #expect(cancelledJSON == #"{"cancelled":true}"#)
        #expect(!cancelledJSON.contains("resolutions"))
    }

    /// An empty resolutions array is a real wire form — Submit with nothing
    /// staged — distinct from cancellation.
    @Test func emptyResolutionsIsAnArrayNotACancellation() throws {
        #expect(try wireJSON(ResolveReply.resolutions([])) == #"{"resolutions":[]}"#)
    }

    /// The outcome's three tagged forms. `timedOut` and `superseded` encode
    /// as their own keys — a timeout or a supersede is never bytes-shaped
    /// like a decision; a cancellation rides `decided` (it IS a decision).
    @Test func outcomesEncodeToTheirTaggedForms() throws {
        #expect(try wireJSON(ResolveOutcome.decided(.cancelled)) == #"{"decided":{"cancelled":true}}"#)
        #expect(try wireJSON(ResolveOutcome.decided(.resolutions([]))) == #"{"decided":{"resolutions":[]}}"#)
        #expect(try wireJSON(ResolveOutcome.timedOut) == #"{"timedOut":true}"#)
        #expect(try wireJSON(ResolveOutcome.superseded) == #"{"superseded":true}"#)
    }

    /// Both sides share these types, so the bytes decode back to the same
    /// value — asserted, not assumed.
    @Test func replyAndOutcomeRoundTripThroughTheirOwnBytes() throws {
        let reply = ResolveReply.resolutions([
            PathResolution(path: "f.txt", kind: .deletedByUs, choice: .keepDeletion),
            PathResolution(path: "g.txt", kind: .bothModified, choice: .editedContent,
                           editedContent: "merged\n", note: "n"),
        ])
        let decoded = try JSONDecoder().decode(ResolveReply.self, from: JSONEncoder().encode(reply))
        #expect(decoded == reply)

        let outcomeBytes = try JSONEncoder().encode(ResolveOutcome.decided(reply))
        let decodedOutcome = try JSONDecoder().decode(ResolveOutcome.self, from: outcomeBytes)
        #expect(decodedOutcome == .decided(reply))

        let cancelledBytes = try JSONEncoder().encode(ResolveOutcome.decided(.cancelled))
        #expect(try JSONDecoder().decode(ResolveOutcome.self, from: cancelledBytes) == .decided(.cancelled))
    }

    /// Decoding garbage shapes is a thrown error, not a guessed value. When
    /// several outcome tags are present `decided` wins — the same convention
    /// `ReviewOutcome` follows — so the enforced rule is that an unknown tag
    /// alone cannot decode.
    @Test func decodingMalformedShapesThrows() throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ResolveReply.self, from: Data("{}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ResolveOutcome.self, from: Data(#"{"somethingElse":true}"#.utf8))
        }
    }

    // MARK: - Binding the schema to the type (#0226-style self-reference)

    /// `YardKit/Schemas/resolve.json`, resolved from this file's compile-time
    /// path: `Tests/YardWireTests/` → up three → package root.
    private static let resolveSchemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // YardWireTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // YardKit (package root)
        .appendingPathComponent("Schemas", isDirectory: true)
        .appendingPathComponent("resolve.json")

    /// The result is array-bearing (`resolutions` is an array of objects), so
    /// the schema carries the self-reference form — `{"schema": "resolve"}`,
    /// no field list — and the type's own encoded keys are pinned here
    /// instead, the way `ReviewWireTests` does for #0055's array-bearing
    /// reply.
    @Test func schemaResultIsTheSelfReferenceAndTheReplyEncodesOnlyItsKeys() throws {
        let data = try Data(contentsOf: Self.resolveSchemaURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(object["envelope"] as? [String: Any])
        let success = try #require(envelope["success"] as? [String: Any])
        let result = try #require(success["result"] as? [String: Any])
        #expect(result["schema"] as? String == "resolve",
                "resolve.json must carry the self-reference form until payload shapes can express arrays")
        #expect(result["fields"] == nil,
                "a field list appeared — bind it to the encoded keys like WhereAmIWireTests does")

        let full = ResolveReply.resolutions([
            PathResolution(path: "f.txt", kind: .bothModified, choice: .editedContent,
                           editedContent: "m", note: "n"),
        ])
        let fullKeys = try topLevelKeys(ofJSON: wireJSON(full))
        #expect(!fullKeys.isEmpty, "a fully-populated reply must encode at least one key")
        #expect(fullKeys == ["resolutions"],
                "the reply encodes exactly its one wire key; got \(fullKeys.sorted())")

        let cancelledKeys = try topLevelKeys(ofJSON: wireJSON(ResolveReply.cancelled))
        #expect(!cancelledKeys.isEmpty, "a cancelled reply must encode at least one key")
        #expect(cancelledKeys == ["cancelled"],
                "the cancelled reply encodes exactly its one wire key; got \(cancelledKeys.sorted())")
    }
}
