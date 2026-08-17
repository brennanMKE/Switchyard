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

@Suite("JournalObserved.Metadata wire shape")
struct JournalObservedWireTests {

    @Test func refUpdatesKindEncodesToTheLiteralWireShape() throws {
        let value = JournalObserved.Metadata(updates: [
            ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
                refName: "refs/heads/main"),
        ])
        #expect(try wireJSON(value) == #"{"kind":"ref_updates","schemaVersion":1,"updates":[{"newValue":"a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0","oldValue":"0000000000000000000000000000000000000000","refName":"refs\/heads\/main"}]}"#)
    }

    /// `kind` is a new required key on both shapes; an existing reader that
    /// only looks at `updates` is unaffected by a `rewrites`-kind entry, so
    /// no `schemaVersion` bump accompanies it (#0220's payload decision).
    @Test func refUpdatesKindOmitsTheRewritesFields() throws {
        let value = JournalObserved.Metadata(updates: [
            ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0",
                refName: "refs/heads/main"),
        ])
        let json = try wireJSON(value)
        #expect(!json.contains("\"source\""))
        #expect(!json.contains("\"rewrites\""))
        #expect(!json.contains("null"))
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
            ])
        #expect(try wireJSON(value) == #"{"kind":"rewrites","rewrites":[{"newOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517","oldOid":"a3317ca3bde3e98bd5c8d097a5e99dd9cb510742"},{"newOid":"5091a0b36200bb1ace0d1ccc310fe128f7e001bf","oldOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517"}],"schemaVersion":1,"source":"rebase"}"#)
    }

    /// `extraInfo` is emitted only when present -- githooks(5) says no
    /// command currently passes it, but the parser tolerates it, so the wire
    /// shape must too.
    @Test func rewritesKindOmitsAbsentExtraInfoButEmitsItWhenPresent() throws {
        let withoutExtraInfo = try wireJSON(JournalObserved.Metadata(
            source: .amend,
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517")]))
        #expect(!withoutExtraInfo.contains("extraInfo"))
        #expect(!withoutExtraInfo.contains("\"updates\""))

        let withExtraInfo = try wireJSON(JournalObserved.Metadata(
            source: .amend,
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517",
                extraInfo: "extra")]))
        #expect(withExtraInfo == #"{"kind":"rewrites","rewrites":[{"extraInfo":"extra","newOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517","oldOid":"a3317ca3bde3e98bd5c8d097a5e99dd9cb510742"}],"schemaVersion":1,"source":"amend"}"#)
    }

    /// `source` is `PostRewrite.Source`, encoded as its git argument: the raw
    /// string for `.unrecognized` is kept, not dropped -- a future git verb
    /// the parser does not know is exactly the case worth recording.
    @Test func unrecognizedSourceEncodesItsRawArgument() throws {
        let value = JournalObserved.Metadata(
            source: .unrecognized("filter-repo"),
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517")])
        let json = try wireJSON(value)
        #expect(json.contains(#""source":"filter-repo""#))
    }
}
