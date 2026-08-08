// WhereAmIWireTests.swift — WhereAmI encodes to the schemaVersion 1 envelope (#0129)

import Foundation
import Testing
import YardGit
import YardKit

/// Encodes a value the way the CLI writes envelopes: `JSONEncoder` with
/// `.sortedKeys` and nothing else — the same configuration as
/// `EnvelopeFail.write()` and YardKit's internal `jsonString`. Sorted keys
/// make the bytes deterministic, so tests can assert literal JSON.
func wireJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting.insert(.sortedKeys)
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

@Suite("WhereAmI wire shape")
struct WhereAmIWireTests {

    /// Every field populated, asserted against the literal bytes. A
    /// round-trip cannot catch a key both sides share wrongly; the literal is
    /// the contract.
    @Test func fullValueEncodesToTheLiteralWireShape() throws {
        let value = WhereAmI(
            branch: "main", upstream: "origin/main", ahead: 2, behind: 1,
            isMidRebase: false, isMidMerge: true, isMidCherryPick: false,
            stashCount: 3, untrackedCount: 4, unstagedCount: 5, stagedCount: 6,
            hasConflicts: true, conflictCount: 7,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        #expect(try wireJSON(value) == #"{"ahead":2,"behind":1,"branch":"main","conflictCount":7,"hasConflicts":true,"headOID":"a1b2c3d","isMidCherryPick":false,"isMidMerge":true,"isMidRebase":false,"rawHead":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","stagedCount":6,"stashCount":3,"unstagedCount":5,"untrackedCount":4,"upstream":"origin\/main"}"#)
    }

    /// A detached HEAD with no upstream: every nil optional is OMITTED from
    /// the wire, not encoded as null — the same rule the envelope itself uses
    /// for `result` and `error.hint`.
    @Test func nilOptionalsAreOmittedFromTheWire() throws {
        let value = WhereAmI(
            branch: nil, upstream: nil, ahead: nil, behind: nil,
            isMidRebase: false, isMidMerge: false, isMidCherryPick: false,
            stashCount: 0, untrackedCount: 0, unstagedCount: 0, stagedCount: 0,
            hasConflicts: false, conflictCount: 0,
            headOID: "a1b2c3d",
            rawHead: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        let json = try wireJSON(value)
        #expect(json == #"{"conflictCount":0,"hasConflicts":false,"headOID":"a1b2c3d","isMidCherryPick":false,"isMidMerge":false,"isMidRebase":false,"rawHead":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","stagedCount":0,"stashCount":0,"unstagedCount":0,"untrackedCount":0}"#)
        #expect(!json.contains("\"branch\""))
        #expect(!json.contains("null"))
    }

    /// The M1 exit-criterion sentence, literally: the engine result type
    /// encodes to a `schemaVersion: 1` envelope. Wrapped in the real
    /// `Envelope` through `EncodableResult` — the compile itself proves the
    /// `Encodable & Sendable` bound, and the literal pins the whole response.
    @Test func envelopeWrapsWhereAmIWithTheV1Keys() throws {
        let value = WhereAmI(
            branch: "main", upstream: nil, ahead: nil, behind: nil,
            isMidRebase: false, isMidMerge: false, isMidCherryPick: false,
            stashCount: 0, untrackedCount: 0, unstagedCount: 1, stagedCount: 0,
            hasConflicts: false, conflictCount: 0,
            headOID: "cafc5cd",
            rawHead: "cafc5cde84e5e8b8ddd67d821b0b803b60f43216")
        let json = try wireJSON(Envelope(result: EncodableResult(value)))
        #expect(json == #"{"ok":true,"result":{"branch":"main","conflictCount":0,"hasConflicts":false,"headOID":"cafc5cd","isMidCherryPick":false,"isMidMerge":false,"isMidRebase":false,"rawHead":"cafc5cde84e5e8b8ddd67d821b0b803b60f43216","stagedCount":0,"stashCount":0,"unstagedCount":1,"untrackedCount":0},"schemaVersion":1}"#)

        // Structural read-back of the envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["branch"] as? String == "main")
    }
}
