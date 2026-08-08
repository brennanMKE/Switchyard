// WorktreeIdentityWireTests.swift — worktree identity payloads encode to the
// schemaVersion 1 envelope (#0130): WorktreeEntry, WorktreeWhere, SiblingWorktree.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("Worktree identity wire shapes")
struct WorktreeIdentityWireTests {

    // MARK: - WorktreeEntry

    /// Every field populated, asserted against the literal bytes. The
    /// lockReason carries the real agent-lock format
    /// (`switchyard-agent:session=<id>`, guide §11 decision 9) so the literal
    /// proves encoding does not transform the string WorktreePrune.isAgentLock
    /// parses.
    @Test func worktreeEntryFullValueEncodesToTheLiteralWireShape() throws {
        let value = WorktreeEntry(
            path: "/Users/dev/repo-0042",
            head: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
            branch: "issue/0042",
            locked: true,
            lockReason: "switchyard-agent:session=7f3a",
            bare: false,
            detached: false,
            prunable: true,
            prunableReason: "gitdir file points to non-existent location",
            isMainWorktree: false)
        #expect(try wireJSON(value) == #"{"bare":false,"branch":"issue\/0042","detached":false,"head":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","isMainWorktree":false,"lockReason":"switchyard-agent:session=7f3a","locked":true,"path":"\/Users\/dev\/repo-0042","prunable":true,"prunableReason":"gitdir file points to non-existent location"}"#)
    }

    /// A bare repository entry: `path`, `head`, `branch`, `lockReason`, and
    /// `prunableReason` are all nil and every one is OMITTED from the wire,
    /// not encoded as null — the same rule the envelope itself uses for
    /// `result` and `error.hint`.
    @Test func worktreeEntryNilOptionalsAreOmittedFromTheWire() throws {
        let value = WorktreeEntry(
            path: nil, head: nil, branch: nil,
            locked: false, lockReason: nil,
            bare: true, detached: false,
            prunable: false, prunableReason: nil,
            isMainWorktree: true)
        let json = try wireJSON(value)
        #expect(json == #"{"bare":true,"detached":false,"isMainWorktree":true,"locked":false,"prunable":false}"#)
        #expect(!json.contains("\"path\""))
        #expect(!json.contains("null"))
    }

    // MARK: - WorktreeWhere

    /// A linked worktree with every field populated.
    @Test func worktreeWhereFullValueEncodesToTheLiteralWireShape() throws {
        let value = WorktreeWhere(
            worktreeName: "switchyard-0042",
            path: "/Users/dev/repo-0042",
            gitDir: "/Users/dev/repo/.git/worktrees/switchyard-0042",
            commonDir: "/Users/dev/repo/.git",
            mainWorktreePath: "/Users/dev/repo")
        #expect(try wireJSON(value) == #"{"commonDir":"\/Users\/dev\/repo\/.git","gitDir":"\/Users\/dev\/repo\/.git\/worktrees\/switchyard-0042","mainWorktreePath":"\/Users\/dev\/repo","path":"\/Users\/dev\/repo-0042","worktreeName":"switchyard-0042"}"#)
    }

    /// A bare repository: `worktreeName`, `path`, and `mainWorktreePath` are
    /// nil and omitted; the two always-present dirs remain.
    @Test func worktreeWhereNilOptionalsAreOmittedFromTheWire() throws {
        let value = WorktreeWhere(
            worktreeName: nil, path: nil,
            gitDir: "/srv/repo.git", commonDir: "/srv/repo.git",
            mainWorktreePath: nil)
        let json = try wireJSON(value)
        #expect(json == #"{"commonDir":"\/srv\/repo.git","gitDir":"\/srv\/repo.git"}"#)
        #expect(!json.contains("\"worktreeName\""))
        #expect(!json.contains("null"))
    }

    // MARK: - SiblingWorktree

    /// A sibling holding the branch, every field populated.
    @Test func siblingWorktreeFullValueEncodesToTheLiteralWireShape() throws {
        let value = SiblingWorktree(
            path: "/Users/dev/repo-0042",
            branch: "issue/0042",
            head: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
            isMainWorktree: false,
            isCurrent: false)
        #expect(try wireJSON(value) == #"{"branch":"issue\/0042","head":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","isCurrent":false,"isMainWorktree":false,"path":"\/Users\/dev\/repo-0042"}"#)
    }

    /// Porcelain reported no HEAD oid: the one optional, `head`, is omitted.
    @Test func siblingWorktreeNilHeadIsOmittedFromTheWire() throws {
        let value = SiblingWorktree(
            path: "/Users/dev/repo",
            branch: "main",
            head: nil,
            isMainWorktree: true,
            isCurrent: true)
        let json = try wireJSON(value)
        #expect(json == #"{"branch":"main","isCurrent":true,"isMainWorktree":true,"path":"\/Users\/dev\/repo"}"#)
        #expect(!json.contains("\"head\""))
        #expect(!json.contains("null"))
    }

    // MARK: - Envelope passthrough

    /// The M1 exit-criterion sentence for all three types: each wraps in the
    /// real `Envelope` through `EncodableResult` — the compile itself proves
    /// the `Encodable & Sendable` bound for each — and each full response is
    /// byte-pinned with the v1 frame keys.
    @Test func envelopeWrapsAllThreeWorktreeIdentityPayloads() throws {
        let entry = WorktreeEntry(
            path: nil, head: nil, branch: nil,
            locked: false, lockReason: nil,
            bare: true, detached: false,
            prunable: false, prunableReason: nil,
            isMainWorktree: true)
        #expect(try wireJSON(Envelope(result: EncodableResult(entry))) == #"{"ok":true,"result":{"bare":true,"detached":false,"isMainWorktree":true,"locked":false,"prunable":false},"schemaVersion":1}"#)

        let whereValue = WorktreeWhere(
            worktreeName: nil, path: nil,
            gitDir: "/srv/repo.git", commonDir: "/srv/repo.git",
            mainWorktreePath: nil)
        #expect(try wireJSON(Envelope(result: EncodableResult(whereValue))) == #"{"ok":true,"result":{"commonDir":"\/srv\/repo.git","gitDir":"\/srv\/repo.git"},"schemaVersion":1}"#)

        let sibling = SiblingWorktree(
            path: "/Users/dev/repo",
            branch: "main",
            head: nil,
            isMainWorktree: true,
            isCurrent: true)
        let json = try wireJSON(Envelope(result: EncodableResult(sibling)))
        #expect(json == #"{"ok":true,"result":{"branch":"main","isCurrent":true,"isMainWorktree":true,"path":"\/Users\/dev\/repo"},"schemaVersion":1}"#)

        // Structural read-back of one envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["branch"] as? String == "main")
    }
}
