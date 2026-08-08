// WorktreeAddWireTests.swift — WorktreeAddResult and WorktreeAddError encode to the
// schemaVersion 1 envelope (#0134). First contact for #0129 Decision 5's
// associated-value clause: every enum case's wire form is pinned, because an
// agent branches on `code` and reads the case's detail fields.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("WorktreeAdd wire shapes")
struct WorktreeAddWireTests {

    // MARK: - WorktreeAddResult

    /// A locked agent creation, every field populated. `success` is computed
    /// and must NOT appear (#0129 Decision 7); no `error` key on success.
    @Test func successResultEncodesToTheLiteralWireShape() throws {
        let value = WorktreeAddResult(
            worktreePath: "/Users/dev/repo-0042",
            branch: "issue/0042",
            head: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
            lockReason: "switchyard-agent:session=7f3a")
        let json = try wireJSON(value)
        #expect(json == #"{"branch":"issue\/0042","head":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","lockReason":"switchyard-agent:session=7f3a","worktreePath":"\/Users\/dev\/repo-0042"}"#)
        #expect(!json.contains("\"success\""))
        #expect(!json.contains("\"error\""))
    }

    /// A detached, unlocked creation: `branch`, `lockReason`, and `error` are
    /// nil and every one is OMITTED from the wire, never `null`.
    @Test func detachedSuccessOmitsNilOptionals() throws {
        let value = WorktreeAddResult(
            worktreePath: "/Users/dev/repo-spike",
            head: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0")
        let json = try wireJSON(value)
        #expect(json == #"{"head":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","worktreePath":"\/Users\/dev\/repo-spike"}"#)
        #expect(!json.contains("\"branch\""))
        #expect(!json.contains("null"))
    }

    // MARK: - WorktreeAddError, one literal per case (Decision 5)

    /// The refusal an agent most needs structurally: `code`, `message`
    /// (= `description`), and the holder as named fields — not prose.
    @Test func branchInUseEncodesCodeMessageAndHolder() throws {
        let value = WorktreeAddError.branchInUse(
            branch: "issue/0042",
            holderPath: "/Users/dev/repo-0042",
            holderIsMainWorktree: false)
        #expect(try wireJSON(value) == #"{"branch":"issue\/0042","code":"branchInUse","holderIsMainWorktree":false,"holderPath":"\/Users\/dev\/repo-0042","message":"branch 'issue\/0042' is already checked out in another worktree at \/Users\/dev\/repo-0042"}"#)
    }

    /// A nil associated value inside a case follows Decision 4 too: the
    /// unidentified holder's path is omitted, never `null`.
    @Test func branchInUseNilHolderPathIsOmitted() throws {
        let value = WorktreeAddError.branchInUse(
            branch: "main", holderPath: nil, holderIsMainWorktree: true)
        let json = try wireJSON(value)
        #expect(json == #"{"branch":"main","code":"branchInUse","holderIsMainWorktree":true,"message":"branch 'main' is already checked out in the main worktree"}"#)
        #expect(!json.contains("\"holderPath\""))
        #expect(!json.contains("null"))
    }

    @Test func branchExistsEncodesTheBranch() throws {
        #expect(try wireJSON(WorktreeAddError.branchExists("issue/0042")) == #"{"branch":"issue\/0042","code":"branchExists","message":"a branch named 'issue\/0042' already exists"}"#)
    }

    @Test func invalidBranchNameEncodesTheName() throws {
        #expect(try wireJSON(WorktreeAddError.invalidBranchName("bad..name")) == #"{"code":"invalidBranchName","message":"'bad..name' is not a valid branch name","name":"bad..name"}"#)
    }

    @Test func pathExistsEncodesThePath() throws {
        #expect(try wireJSON(WorktreeAddError.pathExists("/Users/dev/repo-0042")) == #"{"code":"pathExists","message":"'\/Users\/dev\/repo-0042' already exists","path":"\/Users\/dev\/repo-0042"}"#)
    }

    @Test func invalidReferenceEncodesTheReference() throws {
        #expect(try wireJSON(WorktreeAddError.invalidReference("deadbeef")) == #"{"code":"invalidReference","message":"invalid reference: deadbeef","reference":"deadbeef"}"#)
    }

    /// The catch-all: git's exit status rides as `exitCode` (a number), NOT as
    /// `code` — that key is taken by the stable case string `"failure"`.
    @Test func unknownFailureEncodesExitCodeAndStderr() throws {
        let value = WorktreeAddError.unknownFailure(
            code: 128, stderr: "fatal: not a git repository")
        #expect(try wireJSON(value) == #"{"code":"failure","exitCode":128,"message":"git worktree add exited 128: fatal: not a git repository","stderr":"fatal: not a git repository"}"#)
    }

    // MARK: - Refusal result and envelope

    /// A refusal result embeds the error object under `error`; the nil
    /// `branch`/`head`/`lockReason` are omitted.
    @Test func refusalResultEmbedsTheErrorObject() throws {
        let value = WorktreeAddResult(
            worktreePath: "/Users/dev/repo-0042",
            error: .branchInUse(
                branch: "issue/0042",
                holderPath: "/Users/dev/repo-0042",
                holderIsMainWorktree: false))
        #expect(try wireJSON(value) == #"{"error":{"branch":"issue\/0042","code":"branchInUse","holderIsMainWorktree":false,"holderPath":"\/Users\/dev\/repo-0042","message":"branch 'issue\/0042' is already checked out in another worktree at \/Users\/dev\/repo-0042"},"worktreePath":"\/Users\/dev\/repo-0042"}"#)
    }

    /// The M1 exit-criterion sentence: the engine result type encodes to a
    /// `schemaVersion: 1` envelope, refusal included. Whether a registered
    /// command surfaces a refusal as this `ok: true` payload or as an
    /// `EnvelopeFail` is an M3 registration decision — this test pins the
    /// encoding mechanics, not that choice.
    @Test func envelopeWrapsARefusalWithTheV1Keys() throws {
        let value = WorktreeAddResult(
            worktreePath: "/Users/dev/repo-0042",
            error: .branchInUse(
                branch: "issue/0042",
                holderPath: "/Users/dev/repo-0042",
                holderIsMainWorktree: false))
        let json = try wireJSON(Envelope(result: EncodableResult(value)))
        #expect(json == #"{"ok":true,"result":{"error":{"branch":"issue\/0042","code":"branchInUse","holderIsMainWorktree":false,"holderPath":"\/Users\/dev\/repo-0042","message":"branch 'issue\/0042' is already checked out in another worktree at \/Users\/dev\/repo-0042"},"worktreePath":"\/Users\/dev\/repo-0042"},"schemaVersion":1}"#)

        // Structural read-back, so a failure here distinguishes "envelope
        // broke" from "payload byte drift" — and pins the agent's branch
        // path: result.error.code.
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        let error = try #require(result["error"] as? [String: Any])
        #expect(error["code"] as? String == "branchInUse")
        #expect(error["holderPath"] as? String == "/Users/dev/repo-0042")
    }
}
