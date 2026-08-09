// MaintenanceWireTests.swift — maintenance payloads encode to the schemaVersion 1
// envelope (#0135): WorktreePrune.Report, WorktreeRepair.Repaired.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("Maintenance wire shapes")
struct MaintenanceWireTests {

    // MARK: - WorktreePrune.Report

    /// A prunable entry, its `reason` verbatim from git (`git worktree list
    /// --porcelain` wording, measured 2026-08-07). `type` is the String-raw
    /// `Reportable` and encodes as its raw value (#0129 Decision 5);
    /// `removable` is a STORED property and rides the wire (Decision 7 cuts
    /// computed members only — the computed `description` never appears).
    @Test func prunableReportEncodesToTheLiteralWireShape() throws {
        let value = WorktreePrune.Report(
            path: "/Users/dev/repo-gone",
            type: .prunable,
            reason: "gitdir file points to non-existent location")
        let json = try wireJSON(value)
        #expect(json == #"{"path":"\/Users\/dev\/repo-gone","reason":"gitdir file points to non-existent location","removable":true,"type":"prunable"}"#)
        #expect(!json.contains("description"))
        #expect(!json.contains("Removing"))
        #expect(!json.contains("null"))
    }

    /// An abandoned session: the nil `reason` is OMITTED, never `null`
    /// (#0129 Decision 4), the agent lock reason rides verbatim, and
    /// `removable` is false — prune never reaps a locked worktree.
    @Test func abandonedSessionReportEncodesLockReasonAndIsNotRemovable() throws {
        let value = WorktreePrune.Report(
            path: "/Users/dev/repo-0042",
            type: .abandonedSession,
            lockReason: "switchyard-agent:session=7f3a")
        let json = try wireJSON(value)
        #expect(json == #"{"lockReason":"switchyard-agent:session=7f3a","path":"\/Users\/dev\/repo-0042","removable":false,"type":"abandonedSession"}"#)
        #expect(!json.contains("\"reason\""))
        #expect(!json.contains("null"))
    }

    /// Engine+encoder conjunction: `report(entries:)` classifies a
    /// real-shaped porcelain entry (reason string measured from git) and the
    /// resulting array encodes — each half passing alone would not prove the
    /// wire an agent actually receives.
    @Test func reportFromAPrunableEntryEncodesGitsReasonVerbatim() throws {
        let entry = WorktreeEntry(
            path: "/Users/dev/repo-gone",
            head: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
            branch: "refs/heads/issue/0042",
            prunable: true,
            prunableReason: "gitdir file points to non-existent location")
        let reports = WorktreePrune.report(entries: [entry])
        #expect(reports.count == 1)
        #expect(try wireJSON(reports) == #"[{"path":"\/Users\/dev\/repo-gone","reason":"gitdir file points to non-existent location","removable":true,"type":"prunable"}]"#)
    }

    // MARK: - WorktreeRepair.Repaired

    /// One repaired link. The `reason` vocabulary is git's own
    /// (`report_repair` in builtin/worktree.c emits exactly three); for
    /// `gitdir incorrect` the path names the administrative gitdir file —
    /// both ride verbatim.
    @Test func repairedEncodesToTheLiteralWireShape() throws {
        let value = WorktreeRepair.Repaired(
            reason: "gitdir incorrect",
            path: "/Users/dev/repo/.git/worktrees/repo-0042/gitdir")
        #expect(try wireJSON(value) == #"{"path":"\/Users\/dev\/repo\/.git\/worktrees\/repo-0042\/gitdir","reason":"gitdir incorrect"}"#)
    }

    /// Parser+encoder conjunction: the stderr line shape git actually writes
    /// (`repair: <reason>: <path>`) parses through `parseReport` and encodes.
    @Test func parsedRepairReportEncodesReasonAndPath() throws {
        let stderr = "repair: gitdir incorrect: /Users/dev/repo/.git/worktrees/repo-0042/gitdir\n"
        let repaired = WorktreeRepair.parseReport(from: stderr)
        #expect(repaired.count == 1)
        #expect(try wireJSON(repaired) == #"[{"path":"\/Users\/dev\/repo\/.git\/worktrees\/repo-0042\/gitdir","reason":"gitdir incorrect"}]"#)
    }

    // MARK: - Envelope passthrough

    /// The M1 exit-criterion sentence for both payloads: each engine function
    /// returns an array, which rides as a JSON array in `result` — the
    /// compile itself proves the `Encodable & Sendable` bound for both
    /// element types, and each full response is byte-pinned with the v1 keys.
    @Test func envelopeWrapsPruneAndRepairPayloads() throws {
        let reports = [WorktreePrune.Report(
            path: "/Users/dev/repo-gone",
            type: .prunable,
            reason: "gitdir file points to non-existent location")]
        #expect(try wireJSON(Envelope(result: EncodableResult(reports))) == #"{"ok":true,"result":[{"path":"\/Users\/dev\/repo-gone","reason":"gitdir file points to non-existent location","removable":true,"type":"prunable"}],"schemaVersion":1}"#)

        let repaired = [WorktreeRepair.Repaired(
            reason: ".git file broken",
            path: "/Users/dev/repo-0042")]
        let json = try wireJSON(Envelope(result: EncodableResult(repaired)))
        #expect(json == #"{"ok":true,"result":[{"path":"\/Users\/dev\/repo-0042","reason":".git file broken"}],"schemaVersion":1}"#)

        // Structural read-back of one envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [[String: Any]])
        #expect(result.first?["reason"] as? String == ".git file broken")
    }

    /// #0168 decision 8: a missing object rides the structured error payload
    /// and agents branch on `ref`/`oid`, so the shape is contract. The
    /// conformance is SYNTHESISED — a renamed or reordered member changes the
    /// wire silently, and a round-trip test cannot see it because both
    /// directions move together. Golden bytes, per #0155.
    @Test func missingObjectEncodesItsPinnedBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(JournalRestore.MissingObject(
            ref: "refs/tags/probe-tag", oid: "0123456789abcdef0123456789abcdef01234567"))
        #expect(String(decoding: bytes, as: UTF8.self) == """
            {"oid":"0123456789abcdef0123456789abcdef01234567","ref":"refs/tags/probe-tag"}
            """)
    }
}
