// JournalObservedWireTests.swift — JournalObserved.Metadata's two payload
// shapes, byte-exact (#0220)
//
// `JournalObserved.Metadata` carries two payload shapes discriminated by
// `kind`: a foreign `reference-transaction`'s ref updates, and a foreign
// rewrite's (`commit --amend` / `rebase`) old->new commit mapping. Both are
// pinned literally, sorted keys, the same way `WhereAmIWireTests` pins
// `WhereAmI` -- a round-trip cannot catch a key both sides share wrongly,
// the literal is the contract.

import Foundation
import Testing
import YardGit

/// Mirrors `JournalObserved.record`'s encoder configuration exactly --
/// `.sortedKeys`, `.withoutEscapingSlashes`, and `.iso8601` for the date --
/// so the pinned literals below are the actual bytes `record` writes, not
/// merely `Metadata`'s abstract Encodable shape. Deliberately not the shared
/// `wireJSON(_:)` (`WhereAmIWireTests.swift`): that helper omits both
/// settings, which would let a regression to the wrong date strategy or
/// slash-escaping pass unnoticed.
private func observedWireJSON(_ value: JournalObserved.Metadata) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// A fixed capture moment and worktree, shared by every test in this file so
/// the pinned literals only vary in the fields under test. Matches the
/// convention `JournalEntryMetadataRewriteWireTests.entry(rewrite:)` uses.
private let fixedTimestamp = Date(timeIntervalSince1970: 0)
private let fixedWorktree = JournalEntryMetadata.Worktree(name: nil, path: "/repo")

@Suite("JournalObserved.Metadata wire shape")
struct JournalObservedWireTests {

    @Test func refUpdatesKindEncodesToTheLiteralWireShape() throws {
        let value = JournalObserved.Metadata(updates: [
            ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
                refName: "refs/heads/main"),
        ], timestamp: fixedTimestamp, worktree: fixedWorktree)
        #expect(try observedWireJSON(value) == #"{"kind":"ref_updates","schemaVersion":1,"timestamp":"1970-01-01T00:00:00Z","updates":[{"newValue":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","oldValue":"0000000000000000000000000000000000000000","refName":"refs/heads/main"}],"worktree":{"path":"/repo"}}"#)
    }

    /// `kind` is a new required key on both shapes; an existing reader that
    /// only looks at `updates` is unaffected by a `rewrites`-kind entry, so
    /// no `schemaVersion` bump accompanies it (#0220's payload decision).
    /// `timestamp` and `worktree` are new required keys too (#0235), on the
    /// same additive terms.
    @Test func refUpdatesKindOmitsTheRewritesFields() throws {
        let value = JournalObserved.Metadata(updates: [
            ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
                refName: "refs/heads/main"),
        ], timestamp: fixedTimestamp, worktree: fixedWorktree)
        let json = try observedWireJSON(value)
        #expect(!json.contains("\"source\""))
        #expect(!json.contains("\"rewrites\""))
        #expect(!json.contains("null"))
        #expect(json.contains("\"timestamp\""))
        #expect(json.contains("\"worktree\""))
    }

    @Test func rewritesKindEncodesToTheLiteralWireShape() throws {
        let value = JournalObserved.Metadata(
            source: .rebase,
            rewrites: [
                PostRewrite.Rewrite(
                    oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                    newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517"),
                PostRewrite.Rewrite(
                    oldOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517",
                    newOid: "5091a0b36200bb1ace0d1ccc310fe128f7e001bf"),
            ], timestamp: fixedTimestamp, worktree: fixedWorktree)
        #expect(try observedWireJSON(value) == #"{"kind":"rewrites","rewrites":[{"newOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517","oldOid":"a3317ca3bde3e98bd5c8d097a5e99dd9cb510742"},{"newOid":"5091a0b36200bb1ace0d1ccc310fe128f7e001bf","oldOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517"}],"schemaVersion":1,"source":"rebase","timestamp":"1970-01-01T00:00:00Z","worktree":{"path":"/repo"}}"#)
    }

    /// `extraInfo` is emitted only when present -- githooks(5) says no
    /// command currently passes it, but the parser tolerates it, so the wire
    /// shape must too.
    @Test func rewritesKindOmitsAbsentExtraInfoButEmitsItWhenPresent() throws {
        let withoutExtraInfo = try observedWireJSON(JournalObserved.Metadata(
            source: .amend,
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517")],
            timestamp: fixedTimestamp, worktree: fixedWorktree))
        #expect(!withoutExtraInfo.contains("extraInfo"))
        #expect(!withoutExtraInfo.contains("\"updates\""))

        let withExtraInfo = try observedWireJSON(JournalObserved.Metadata(
            source: .amend,
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517",
                extraInfo: "extra")],
            timestamp: fixedTimestamp, worktree: fixedWorktree))
        #expect(withExtraInfo == #"{"kind":"rewrites","rewrites":[{"extraInfo":"extra","newOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517","oldOid":"a3317ca3bde3e98bd5c8d097a5e99dd9cb510742"}],"schemaVersion":1,"source":"amend","timestamp":"1970-01-01T00:00:00Z","worktree":{"path":"/repo"}}"#)
    }

    /// `source` is `PostRewrite.Source`, encoded as its git argument: the raw
    /// string for `.unrecognized` is kept, not dropped -- a future git verb
    /// the parser does not know is exactly the case worth recording.
    @Test func unrecognizedSourceEncodesItsRawArgument() throws {
        let value = JournalObserved.Metadata(
            source: .unrecognized("filter-repo"),
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517")],
            timestamp: fixedTimestamp, worktree: fixedWorktree)
        let json = try observedWireJSON(value)
        #expect(json.contains(#""source":"filter-repo""#))
    }

    /// The worktree name, when the entry was written in a linked worktree
    /// rather than the main one -- matches `JournalEntryMetadata.Worktree`'s
    /// own wire rule (`name` omitted when nil, present when not).
    @Test func worktreeNameIsPresentWhenNotTheMainWorktree() throws {
        let value = JournalObserved.Metadata(updates: [
            ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
                refName: "refs/heads/main"),
        ], timestamp: fixedTimestamp,
           worktree: JournalEntryMetadata.Worktree(name: "feature", path: "/repo-worktrees/feature"))
        let json = try observedWireJSON(value)
        #expect(json.contains(#""worktree":{"name":"feature","path":"/repo-worktrees/feature"}"#))
    }
}
