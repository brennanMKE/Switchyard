// WatchWireTests.swift — the watch wire's bytes are the contract (#0058)
//
// Non-@testable, like every test in this target: the wire is a public-caller
// contract, and @testable would mask a conformance that silently dropped to
// internal (the #0116 failure class).

import Foundation
import Testing
import YardKit

@Suite("Watch wire shape")
struct WatchWireTests {

    /// The request, pinned whole: the all-repositories selector is the
    /// ABSENCE of `repositoryPath`, and "until detached" is the ABSENCE of
    /// `timeoutSeconds` — never `null` (#0129 Decision 4).
    @Test func requestEncodesToTheLiteralWireShape() throws {
        let full = WatchRequest(repositoryPath: "/repos/a", timeoutSeconds: 30)
        #expect(try wireJSON(full) == #"{"repositoryPath":"\/repos\/a","timeoutSeconds":30}"#)

        let pathOnly = WatchRequest(repositoryPath: "/repos/a", timeoutSeconds: nil)
        #expect(try wireJSON(pathOnly) == #"{"repositoryPath":"\/repos\/a"}"#)

        let timeoutOnly = WatchRequest(repositoryPath: nil, timeoutSeconds: 30)
        #expect(try wireJSON(timeoutOnly) == #"{"timeoutSeconds":30}"#)

        let bare = WatchRequest(repositoryPath: nil, timeoutSeconds: nil)
        #expect(try wireJSON(bare) == #"{}"#)
        #expect(try !wireJSON(bare).contains("null"), "absent means absent, never null")
    }

    /// The event, pinned whole: sequence, kind, and the payload embedded as
    /// a nested JSON OBJECT — never an escaped string the consumer would
    /// have to double-decode.
    @Test func eventEncodesToTheLiteralWireShape() throws {
        let appEvent = WatchEvent(
            sequence: 7,
            kind: .appEvent,
            payload: ["note": .string("hi")])
        #expect(try wireJSON(appEvent) == #"{"kind":"app_event","payload":{"note":"hi"},"sequence":7}"#)

        let observed = WatchEvent(
            sequence: 1,
            kind: .journalObserved,
            payload: [
                "kind": .string("ref_updates"),
                "schemaVersion": .int(1),
                "updates": .array([.object(["oldValue": .string("1111111"), "refName": .string("refs/heads/main"), "newValue": .string("2222222")])]),
            ])
        #expect(
            try wireJSON(observed)
                == #"{"kind":"journal_observed","payload":{"kind":"ref_updates","schemaVersion":1,"updates":[{"newValue":"2222222","oldValue":"1111111","refName":"refs\/heads\/main"}]},"sequence":1}"#)
    }

    /// Every kind round-trips through its raw wire spelling. CaseIterable so
    /// a kind added later cannot silently skip this assertion.
    @Test func everyEventKindSurvivesItsOwnBytes() throws {
        let kinds = WatchEvent.Kind.allCases
        #expect(kinds.count == 2, "a new kind must arrive with its wire spelling pinned here")
        for kind in kinds {
            let event = WatchEvent(sequence: 1, kind: kind, payload: [:])
            let decoded = try JSONDecoder().decode(
                WatchEvent.self, from: JSONEncoder().encode(event))
            #expect(decoded.kind == kind, "kind \(kind.rawValue) must survive its own bytes")
        }
    }

    /// The end reason's three tagged forms — each reason its own key, so a
    /// session end is never bytes-shaped like another reason (the AskOutcome
    /// convention).
    @Test func endReasonsEncodeToTheirTaggedForms() throws {
        #expect(try wireJSON(WatchEndReason.detached) == #"{"detached":true}"#)
        #expect(try wireJSON(WatchEndReason.timedOut) == #"{"timedOut":true}"#)
        #expect(try wireJSON(WatchEndReason.appShutdown) == #"{"appShutdown":true}"#)
    }

    /// Both sides share these types, so the bytes decode back to the same
    /// value — asserted, not assumed.
    @Test func eventRequestAndReasonRoundTripThroughTheirOwnBytes() throws {
        let event = WatchEvent(
            sequence: 3,
            kind: .appEvent,
            payload: [
                "nested": .object(["list": .array([.int(1), .double(1.5), .bool(true), .null])]),
                "text": .string("payload"),
                "count": .int(2),
            ])
        #expect(try JSONDecoder().decode(WatchEvent.self, from: JSONEncoder().encode(event)) == event)

        let request = WatchRequest(repositoryPath: "/repos/a", timeoutSeconds: 30)
        #expect(try JSONDecoder().decode(WatchRequest.self, from: JSONEncoder().encode(request)) == request)

        for reason in [WatchEndReason.detached, .timedOut, .appShutdown] {
            #expect(try JSONDecoder().decode(WatchEndReason.self, from: JSONEncoder().encode(reason)) == reason)
        }
    }

    /// The payload bridge: bytes a `JournalObserved.Metadata.serialized()`
    /// caller holds become a typed object payload, with booleans kept
    /// booleans and integers kept integers — a 1 that arrived as an int must
    /// not decode as a bool, and `true` must not decode as an int.
    @Test func payloadBridgeKeepsJSONTypesDistinct() throws {
        let bytes = Data(#"{"armed":true,"count":1,"ratio":1.5,"label":"x","children":[2,"y"],"empty":null}"#.utf8)
        let payload = try WatchJSON.object(fromJSON: bytes)
        #expect(payload["armed"] == .bool(true))
        #expect(payload["count"] == .int(1))
        #expect(payload["ratio"] == .double(1.5))
        #expect(payload["label"] == .string("x"))
        #expect(payload["children"] == .array([.int(2), .string("y")]))
        #expect(payload["empty"] == .null)
    }

    /// A payload whose top level is not an object is refused — a watch
    /// event's payload is an object by contract, and encoding anything else
    /// would produce an event the wire shape does not describe.
    @Test func payloadBridgeRefusesNonObjectTopLevel() throws {
        #expect(throws: WatchWireError.payloadNotAnObject) {
            try WatchJSON.object(fromJSON: Data("[1,2]".utf8))
        }
        #expect(throws: WatchWireError.payloadNotAnObject) {
            try WatchJSON.object(fromJSON: Data("7".utf8))
        }
        #expect(throws: WatchWireError.self) {
            try WatchJSON.object(fromJSON: Data("not json".utf8))
        }
    }
}
