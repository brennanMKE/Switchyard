// WorktreeRemoveWireTests.swift — WorktreeRemoveResult and WorktreeRemoveError
// encode to the schemaVersion 1 envelope (#0137), per #0129 Decision 5: every
// enum case's wire form is pinned, because an agent branches on `code` and
// reads the case's detail fields.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("WorktreeRemove wire shapes")
struct WorktreeRemoveWireTests {

    // MARK: - WorktreeRemoveResult

    /// A removal that released an agent lock first. The stored
    /// `lockedRelease` / `forced` are the wire truth. #0290 deleted the
    /// computed `refusal`, `lockReleased`, and `hadToForce` properties
    /// outright, so `success` — excluded via `CodingKeys` — is the only
    /// computed member left on the type; it must NOT appear on the wire
    /// (#0129 Decision 7), and a success has no `error` key. The
    /// `lockReleased` check below no longer guards a live member, but it
    /// stays: it pins that a future computed property reusing that name
    /// (or added with its own `CodingKeys`) cannot leak onto the wire
    /// without this test noticing.
    @Test func successResultEncodesToTheLiteralWireShape() throws {
        let value = WorktreeRemoveResult(
            worktreePath: "/Users/dev/repo-0042",
            lockedRelease: true,
            forced: false)
        let json = try wireJSON(value)
        #expect(json == #"{"forced":false,"lockedRelease":true,"worktreePath":"\/Users\/dev\/repo-0042"}"#)
        #expect(!json.contains("\"success\""))
        #expect(!json.contains("\"lockReleased\""))
        #expect(!json.contains("\"error\""))
        #expect(!json.contains("null"))
    }

    // MARK: - WorktreeRemoveError, one literal per case (#0129 Decision 5)

    /// The refusal an agent most needs structurally: the dirty paths as a
    /// JSON array, not prose — `message` restates them for humans.
    @Test func uncleanEncodesCodeMessageAndPaths() throws {
        let value = WorktreeRemoveError.unclean(
            paths: ["Sources/App/Main.swift", "notes.txt"])
        #expect(try wireJSON(value) == #"{"code":"dirty","message":"refusing to remove dirty worktree Sources\/App\/Main.swift, notes.txt","paths":["Sources\/App\/Main.swift","notes.txt"]}"#)
    }

    @Test func unknownEncodesThePath() throws {
        #expect(try wireJSON(WorktreeRemoveError.unknown(path: "/Users/dev/not-a-worktree")) == #"{"code":"notFound","message":"not a worktree: \/Users\/dev\/not-a-worktree","path":"\/Users\/dev\/not-a-worktree"}"#)
    }

    @Test func nestedEncodesInsideAndTarget() throws {
        let value = WorktreeRemoveError.nested(
            inside: "/Users/dev/repo-0042",
            target: "/Users/dev/repo-0042/vendor")
        #expect(try wireJSON(value) == #"{"code":"nested","inside":"\/Users\/dev\/repo-0042","message":"worktree \/Users\/dev\/repo-0042\/vendor is inside another worktree at \/Users\/dev\/repo-0042","target":"\/Users\/dev\/repo-0042\/vendor"}"#)
    }

    /// The catch-all: git's exit status rides as `exitCode` (a number), NOT as
    /// `code` — that key is taken by the stable case string `"failure"`.
    @Test func unknownFailureEncodesExitCodeAndStderr() throws {
        let value = WorktreeRemoveError.unknownFailure(
            code: 128, stderr: "fatal: validation failed")
        #expect(try wireJSON(value) == #"{"code":"failure","exitCode":128,"message":"git worktree remove exited 128: fatal: validation failed","stderr":"fatal: validation failed"}"#)
    }

    @Test func lockFailedEncodesPathAndDetail() throws {
        let value = WorktreeRemoveError.lockFailed(
            path: "/Users/dev/repo-0042",
            detail: "The operation could not be completed")
        #expect(try wireJSON(value) == #"{"code":"lockFailed","detail":"The operation could not be completed","message":"could not release lock on \/Users\/dev\/repo-0042: The operation could not be completed","path":"\/Users\/dev\/repo-0042"}"#)
    }

    // MARK: - Refusal result and envelope

    /// A refusal result embeds the error object under `error`; the Bools are
    /// non-optional and stay on the wire.
    @Test func refusalResultEmbedsTheErrorObject() throws {
        let value = WorktreeRemoveResult(
            worktreePath: "/Users/dev/repo-0042",
            lockedRelease: false,
            error: .unclean(paths: ["Sources/App/Main.swift", "notes.txt"]))
        #expect(try wireJSON(value) == #"{"error":{"code":"dirty","message":"refusing to remove dirty worktree Sources\/App\/Main.swift, notes.txt","paths":["Sources\/App\/Main.swift","notes.txt"]},"forced":false,"lockedRelease":false,"worktreePath":"\/Users\/dev\/repo-0042"}"#)
    }

    /// The M1 exit-criterion sentence: the engine result type encodes to a
    /// `schemaVersion: 1` envelope, refusal included. Whether a registered
    /// command surfaces a refusal as this `ok: true` payload or as an
    /// `EnvelopeFail` is an M3 registration decision — this test pins the
    /// encoding mechanics, not that choice.
    @Test func envelopeWrapsARefusalWithTheV1Keys() throws {
        let value = WorktreeRemoveResult(
            worktreePath: "/Users/dev/repo-0042",
            lockedRelease: false,
            error: .unclean(paths: ["Sources/App/Main.swift", "notes.txt"]))
        let json = try wireJSON(Envelope(result: EncodableResult(value)))
        #expect(json == #"{"ok":true,"result":{"error":{"code":"dirty","message":"refusing to remove dirty worktree Sources\/App\/Main.swift, notes.txt","paths":["Sources\/App\/Main.swift","notes.txt"]},"forced":false,"lockedRelease":false,"worktreePath":"\/Users\/dev\/repo-0042"},"schemaVersion":1}"#)

        // Structural read-back, so a failure here distinguishes "envelope
        // broke" from "payload byte drift" — and pins the agent's branch
        // path: result.error.code, then result.error.paths.
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [String: Any])
        let error = try #require(result["error"] as? [String: Any])
        #expect(error["code"] as? String == "dirty")
        #expect(error["paths"] as? [String] == ["Sources/App/Main.swift", "notes.txt"])
    }
}
