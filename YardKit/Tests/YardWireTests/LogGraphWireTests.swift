// LogGraphWireTests.swift — log and graph payloads encode to the schemaVersion 1
// envelope (#0133): CommitLogEntry, Trailer, SignatureStatus, GraphRow. First
// contact for #0129 Decision 5's middle clause: a non-raw, payload-free enum
// encodes as its DECLARED case-name string.
//
// Every fixture value below is pasted from a real run (2026-08-07): a scratch
// repository built with pinned GIT_AUTHOR_DATE/GIT_COMMITTER_DATE (so the oids
// are deterministic), read back through the real `CommitLog.run` /
// `graphRows(at:)` and encoded with `wireJSON` — the literals are that output.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("Log and graph wire shapes")
struct LogGraphWireTests {

    // MARK: - SignatureStatus (Decision 5, middle clause)

    /// The whole declared vocabulary, one literal per case — a single JSON
    /// string, exactly the case name. `SignatureStatus` has no raw type
    /// (#0127), so these strings are declared in `encode(to:)`, not derived;
    /// no case can be added or renamed without this table forcing a wire
    /// decision. The array is explicit and its count is asserted so the loop
    /// cannot go vacuous.
    @Test func signatureStatusEncodesEveryCaseAsItsDeclaredString() throws {
        let vocabulary: [(SignatureStatus, String)] = [
            (.noSig, #""noSig""#),
            (.good, #""good""#),
            (.goodUntrusted, #""goodUntrusted""#),
            (.bad, #""bad""#),
            (.expiredSignature, #""expiredSignature""#),
            (.expiredKey, #""expiredKey""#),
            (.revokedKey, #""revokedKey""#),
            (.cannotCheck, #""cannotCheck""#),
            (.unknown, #""unknown""#),
        ]
        #expect(vocabulary.count == 9)
        for (status, expected) in vocabulary {
            #expect(try wireJSON(status) == expected)
        }
    }

    // MARK: - Trailer

    /// A trailer parsed from a real line encodes as `{"key":…,"value":…}` —
    /// the parser+encoder conjunction — and the computed `description` is not
    /// on the wire (#0129 Decision 7).
    @Test func trailerParsedFromARealLineEncodesKeyAndValue() throws {
        let trailer = try #require(Trailer.parse("Agent-Name: fable-5"))
        let json = try wireJSON(trailer)
        #expect(json == #"{"key":"Agent-Name","value":"fable-5"}"#)
        #expect(!json.contains("description"))
    }

    // MARK: - CommitLogEntry

    /// The planning fixture's merge commit, every field populated: two
    /// parents, a real `%D` refs string, a body with trailers, and the `%G?`
    /// flag `N` -> `.noSig`. The multi-line `message` rides verbatim (newlines
    /// escaped as `\n` by JSONEncoder), and the computed `subject` /
    /// `shortOid` / `hasProvenance` never appear (#0129 Decision 7).
    @Test func commitLogEntryFullValueEncodesToTheLiteralWireShape() throws {
        let agentName = try #require(Trailer.parse("Agent-Name: fable-5"))
        let signedOff = try #require(
            Trailer.parse("Signed-off-by: Ada Lovelace <ada@example.com>"))
        let value = CommitLogEntry(
            oid: "4b67d4699c8172fd533e5949bf39dc7f52453b07",
            parents: ["3d789ba3640661799ee263b2cd2fbd7c90f0cb5a",
                      "8e861a240582cf87f112369b93b7f0dddd468a70"],
            author: "Ada Lovelace",
            refs: "HEAD -> main, tag: v1.0",
            signatureStatus: .noSig,
            message: "Merge branch 'topic'\n\nAgent-Name: fable-5\nSigned-off-by: Ada Lovelace <ada@example.com>\n",
            trailers: [agentName, signedOff])
        let json = try wireJSON(value)
        #expect(json == #"{"author":"Ada Lovelace","message":"Merge branch 'topic'\n\nAgent-Name: fable-5\nSigned-off-by: Ada Lovelace <ada@example.com>\n","oid":"4b67d4699c8172fd533e5949bf39dc7f52453b07","parents":["3d789ba3640661799ee263b2cd2fbd7c90f0cb5a","8e861a240582cf87f112369b93b7f0dddd468a70"],"refs":"HEAD -> main, tag: v1.0","signatureStatus":"noSig","trailers":[{"key":"Agent-Name","value":"fable-5"},{"key":"Signed-off-by","value":"Ada Lovelace <ada@example.com>"}]}"#)
        #expect(!json.contains("\"subject\""))
        #expect(!json.contains("shortOid"))
        #expect(!json.contains("hasProvenance"))
    }

    /// The fixture's root commit: empty `parents` and `trailers` encode as
    /// `[]`, never omitted and never `null` — they are non-optional, so
    /// Decision 4 has no subject here and an empty array is the truthful
    /// value. The empty `refs` string rides as `""` (a non-tip commit's `%D`
    /// is empty).
    @Test func rootCommitEncodesEmptyParentsAndTrailersAsEmptyArrays() throws {
        let value = CommitLogEntry(
            oid: "d4cd73b7ccc0810ce9a389b130133adc17b38281",
            parents: [],
            author: "Ada Lovelace",
            refs: "",
            signatureStatus: .noSig,
            message: "Initial commit\n",
            trailers: [])
        let json = try wireJSON(value)
        #expect(json == #"{"author":"Ada Lovelace","message":"Initial commit\n","oid":"d4cd73b7ccc0810ce9a389b130133adc17b38281","parents":[],"refs":"","signatureStatus":"noSig","trailers":[]}"#)
        #expect(json.contains(#""parents":[]"#))
        #expect(json.contains(#""trailers":[]"#))
        #expect(!json.contains("null"))
    }

    // MARK: - GraphRow

    /// The planning fixture's whole laid-out graph, exactly as
    /// `graphRows(at:)` returned it: a merge at lane 0 with `parentLanes`
    /// [0,1], the topic branch in lane 1, and the root with empty `parents`
    /// and `parentLanes` encoding as `[]`.
    @Test func graphRowsForARealMergeEncodeToTheLiteralWireShape() throws {
        let rows = [
            GraphRow(oid: "4b67d4699c8172fd533e5949bf39dc7f52453b07",
                     parents: ["3d789ba3640661799ee263b2cd2fbd7c90f0cb5a",
                               "8e861a240582cf87f112369b93b7f0dddd468a70"],
                     lane: 0, parentLanes: [0, 1]),
            GraphRow(oid: "8e861a240582cf87f112369b93b7f0dddd468a70",
                     parents: ["d4cd73b7ccc0810ce9a389b130133adc17b38281"],
                     lane: 1, parentLanes: [1]),
            GraphRow(oid: "3d789ba3640661799ee263b2cd2fbd7c90f0cb5a",
                     parents: ["d4cd73b7ccc0810ce9a389b130133adc17b38281"],
                     lane: 0, parentLanes: [0]),
            GraphRow(oid: "d4cd73b7ccc0810ce9a389b130133adc17b38281",
                     parents: [], lane: 0, parentLanes: []),
        ]
        #expect(try wireJSON(rows) == #"[{"lane":0,"oid":"4b67d4699c8172fd533e5949bf39dc7f52453b07","parentLanes":[0,1],"parents":["3d789ba3640661799ee263b2cd2fbd7c90f0cb5a","8e861a240582cf87f112369b93b7f0dddd468a70"]},{"lane":1,"oid":"8e861a240582cf87f112369b93b7f0dddd468a70","parentLanes":[1],"parents":["d4cd73b7ccc0810ce9a389b130133adc17b38281"]},{"lane":0,"oid":"3d789ba3640661799ee263b2cd2fbd7c90f0cb5a","parentLanes":[0],"parents":["d4cd73b7ccc0810ce9a389b130133adc17b38281"]},{"lane":0,"oid":"d4cd73b7ccc0810ce9a389b130133adc17b38281","parentLanes":[],"parents":[]}]"#)
    }

    // MARK: - Envelope passthrough

    /// The M1 exit-criterion sentence for both payloads: `CommitLog.run` and
    /// `graphRows(at:)` each return an array, which rides as a JSON array in
    /// `result` — the compile itself proves the `Encodable & Sendable` bound
    /// for both element types, and each full response is byte-pinned with the
    /// v1 frame keys.
    @Test func envelopeWrapsLogAndGraphPayloads() throws {
        let entries = [CommitLogEntry(
            oid: "d4cd73b7ccc0810ce9a389b130133adc17b38281",
            parents: [],
            author: "Ada Lovelace",
            refs: "",
            signatureStatus: .noSig,
            message: "Initial commit\n",
            trailers: [])]
        #expect(try wireJSON(Envelope(result: EncodableResult(entries))) == #"{"ok":true,"result":[{"author":"Ada Lovelace","message":"Initial commit\n","oid":"d4cd73b7ccc0810ce9a389b130133adc17b38281","parents":[],"refs":"","signatureStatus":"noSig","trailers":[]}],"schemaVersion":1}"#)

        let rows = [GraphRow(
            oid: "d4cd73b7ccc0810ce9a389b130133adc17b38281",
            parents: [], lane: 0, parentLanes: [])]
        let json = try wireJSON(Envelope(result: EncodableResult(rows)))
        #expect(json == #"{"ok":true,"result":[{"lane":0,"oid":"d4cd73b7ccc0810ce9a389b130133adc17b38281","parentLanes":[],"parents":[]}],"schemaVersion":1}"#)

        // Structural read-back of one envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [[String: Any]])
        #expect(result.first?["lane"] as? Int == 0)
    }
}
