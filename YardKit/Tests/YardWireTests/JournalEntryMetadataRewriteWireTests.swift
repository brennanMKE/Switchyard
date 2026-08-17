// JournalEntryMetadataRewriteWireTests.swift — the attached rewrite mapping's
// wire shape, byte-exact (#0221)
//
// `JournalEntryMetadata.RewriteMapping` is the own-invocation counterpart to
// `JournalObserved.Metadata`'s foreign rewrite payload (#0220): the same
// shape, attached to the in-flight entry instead of living in a separate
// observed one. Pinned literally for the same reason every other entry
// field is pinned in `JournalEntryMetadataTests` (`YardGitTests`) — a
// round-trip cannot catch a key both sides share wrongly, the literal is
// the contract.

import Foundation
import Testing
import YardGit

@Suite("JournalEntryMetadata.rewrite wire shape")
struct JournalEntryMetadataRewriteWireTests {

    private static func entry(
        rewrite: JournalEntryMetadata.RewriteMapping?
    ) throws -> JournalEntryMetadata {
        JournalEntryMetadata(
            id: try #require(JournalEntryID("01K1H8R100W7CBVX5TRJJEDDVM")),
            operation: "fixup",
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: nil, path: "/repo"),
            captured: .refsOnly,
            rewrite: rewrite)
    }

    @Test func rewriteMappingEncodesToThePinnedBytes() throws {
        let mapping = JournalEntryMetadata.RewriteMapping(
            source: "rebase",
            rewrites: [
                PostRewrite.Rewrite(
                    oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                    newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517"),
                PostRewrite.Rewrite(
                    oldOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517",
                    newOid: "5091a0b36200bb1ace0d1ccc310fe128f7e001bf"),
            ])
        let value = try Self.entry(rewrite: mapping)
        let expected = #"{"captured":{"head":true,"index":false,"refs":true,"sequencer":false,"untracked":false,"worktree":false},"guard":{},"id":"01K1H8R100W7CBVX5TRJJEDDVM","operation":"fixup","rewrite":{"rewrites":[{"newOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517","oldOid":"a3317ca3bde3e98bd5c8d097a5e99dd9cb510742"},{"newOid":"5091a0b36200bb1ace0d1ccc310fe128f7e001bf","oldOid":"1db38f7e412aaa4357e0e76acdd212ba8e646517"}],"source":"rebase"},"schemaVersion":1,"timestamp":"1970-01-01T00:00:00Z","worktree":{"path":"/repo"}}"#
        #expect(try value.serialized() == Data(expected.utf8))
    }

    /// `rewrite` absent (the ordinary case — nothing rewrote this entry) is
    /// OMITTED from the wire, not encoded as `null`, matching every other
    /// optional field this type carries.
    @Test func absentRewriteIsOmittedNotNull() throws {
        let value = try Self.entry(rewrite: nil)
        let json = try #require(String(data: value.serialized(), encoding: .utf8))
        #expect(!json.contains("rewrite"))
        #expect(!json.contains("null"))
    }

    /// `extraInfo` is omitted when absent, matching `PostRewrite.Rewrite`'s
    /// existing wire rule pinned in `JournalObservedWireTests`.
    @Test func rewriteEntryOmitsAbsentExtraInfo() throws {
        let value = try Self.entry(rewrite: .init(
            source: "amend",
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517")]))
        let json = try #require(String(data: value.serialized(), encoding: .utf8))
        #expect(!json.contains("extraInfo"))
    }

    /// A round trip through `RewriteMapping`'s `Decodable` side, which the
    /// hand-written `Encodable`-only `JournalObserved.Metadata`/`RefUpdate`
    /// path does not need but this one does — `JournalEntryMetadata` is read
    /// back on every `list`/`undo`, not written once and forgotten.
    @Test func rewriteMappingRoundTripsThroughDecode() throws {
        let mapping = JournalEntryMetadata.RewriteMapping(
            source: "rebase",
            rewrites: [PostRewrite.Rewrite(
                oldOid: "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742",
                newOid: "1db38f7e412aaa4357e0e76acdd212ba8e646517",
                extraInfo: "extra")])
        let value = try Self.entry(rewrite: mapping)
        let decoded = try JournalEntryMetadata(serialized: value.serialized())
        #expect(decoded.rewrite == mapping)
        #expect(decoded == value)
    }
}
