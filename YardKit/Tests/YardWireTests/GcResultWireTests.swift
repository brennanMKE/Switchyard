// GcResultWireTests.swift — the wt gc result encodes to the schemaVersion 1
// envelope (#0139): WorktreePrune.GCResult carries both halves — what was
// reported and what was actually pruned — in one response.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("WorktreePrune.GCResult wire shape")
struct GcResultWireTests {

    /// A prune run that reported one prunable entry and reaped it. The
    /// `pruned` element is git's verbatim `git worktree prune -v` stderr line
    /// (measured 2026-08-07): `Removing worktrees/<id>: <reason>`, where
    /// `<id>` is the administrative name under `$GIT_DIR/worktrees`, not the
    /// working-tree path. The nested `Report` shape is #0135's, unchanged.
    @Test func gcResultEncodesToTheLiteralWireShape() throws {
        let value = WorktreePrune.GCResult(
            reports: [WorktreePrune.Report(
                path: "/Users/dev/repo-gone",
                type: .prunable,
                reason: "gitdir file points to non-existent location")],
            pruned: ["Removing worktrees/repo-gone: gitdir file points to non-existent location"])
        #expect(try wireJSON(value) == #"{"pruned":["Removing worktrees\/repo-gone: gitdir file points to non-existent location"],"reports":[{"path":"\/Users\/dev\/repo-gone","reason":"gitdir file points to non-existent location","removable":true,"type":"prunable"}]}"#)
    }

    /// A report-only run (the default): both members are non-optional
    /// arrays, so BOTH keys are always on the wire — `"pruned":[]` is
    /// present, never omitted. An agent reading the response can distinguish
    /// "nothing was pruned" from a missing field.
    @Test func reportOnlyGCResultKeepsBothKeysWithEmptyPruned() throws {
        let value = WorktreePrune.GCResult(reports: [], pruned: [])
        let json = try wireJSON(value)
        #expect(json == #"{"pruned":[],"reports":[]}"#)
        #expect(json.contains(#""pruned""#))
        #expect(json.contains(#""reports""#))
    }

    /// The M1 exit-criterion sentence for `wt gc`, literally: the engine
    /// result type encodes to a `schemaVersion: 1` envelope — the compile
    /// itself proves the `Encodable & Sendable` bound through
    /// `EncodableResult`, and the literal pins the whole response including
    /// an abandoned session's `lockReason` riding inside the envelope.
    @Test func envelopeWrapsGCResultWithTheV1Keys() throws {
        let value = WorktreePrune.GCResult(
            reports: [WorktreePrune.Report(
                path: "/Users/dev/repo-0042",
                type: .abandonedSession,
                lockReason: "switchyard-agent:session=7f3a")],
            pruned: [])
        let json = try wireJSON(Envelope(result: EncodableResult(value)))
        #expect(json == #"{"ok":true,"result":{"pruned":[],"reports":[{"lockReason":"switchyard-agent:session=7f3a","path":"\/Users\/dev\/repo-0042","removable":false,"type":"abandonedSession"}]},"schemaVersion":1}"#)

        // Structural read-back of the envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["pruned"] as? [String] == [])
        let reports = try #require(result["reports"] as? [[String: Any]])
        #expect(reports.first?["type"] as? String == "abandonedSession")
    }
}
