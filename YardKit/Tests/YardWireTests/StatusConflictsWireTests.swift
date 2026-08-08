// StatusConflictsWireTests.swift — status and conflicts payloads encode to the
// schemaVersion 1 envelope (#0131): WorktreeStatus, WorktreeStatusEntry, ConflictedFile.

import Foundation
import Testing
import YardGit
import YardKit

@Suite("Status and conflicts wire shapes")
struct StatusConflictsWireTests {

    // MARK: - WorktreeStatusEntry

    /// A staged rename with a dirty submodule, every wire field populated. The
    /// literal proves `pathBytes` / `originalPathBytes` never appear (#0129
    /// Decision 6) and that the two `State` fields encode as their porcelain
    /// raw characters (#0129 Decision 5).
    @Test func worktreeStatusEntryFullValueEncodesToTheLiteralWireShape() throws {
        var value = WorktreeStatusEntry(
            path: "docs/renamed.md",
            pathBytes: Array("docs/renamed.md".utf8),
            originalPath: "docs/original.md",
            originalPathBytes: Array("docs/original.md".utf8))
        value.staged = .modified
        value.worktree = .unmodified
        value.submodule = try #require(
            WorktreeStatusEntry.SubmoduleState(subToken: "SCMU"))
        #expect(try wireJSON(value) == #"{"originalPath":"docs\/original.md","path":"docs\/renamed.md","staged":"M","submodule":{"commitChanged":true,"hasModifications":true,"hasUntracked":true},"worktree":"."}"#)
    }

    /// An untracked file: `originalPath` and `submodule` are nil and OMITTED
    /// from the wire, not encoded as null — and the raw-bytes fields are
    /// absent by name, pinning Decision 6 as a key-level fact.
    @Test func worktreeStatusEntryNilOptionalsAreOmittedFromTheWire() throws {
        var value = WorktreeStatusEntry(path: "notes.txt")
        value.staged = .unmodified
        value.worktree = .untracked
        let json = try wireJSON(value)
        #expect(json == #"{"path":"notes.txt","staged":".","worktree":"?"}"#)
        #expect(!json.contains("\"originalPath\""))
        #expect(!json.contains("pathBytes"))
        #expect(!json.contains("null"))
    }

    /// A path that is not valid UTF-8 — git can commit one on other
    /// filesystems even though APFS refuses to create one. The wire carries
    /// the lossily-decoded `path` string: the invalid byte 0xE9 becomes
    /// U+FFFD REPLACEMENT CHARACTER, which is valid UTF-8 and therefore a
    /// legal JSON string. The raw bytes stay off the wire (#0129 Decision 6);
    /// `pathBytes` remains the lossless in-process source of truth.
    @Test func nonUTF8PathRidesTheWireAsTheLossyDecodedString() throws {
        let rawPath: [UInt8] = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
        let value = WorktreeStatusEntry(
            path: String(decoding: rawPath, as: UTF8.self),
            pathBytes: rawPath)
        let json = try wireJSON(value)
        #expect(json == #"{"path":"caf\#u{FFFD}.txt","staged":".","worktree":"."}"#)
        #expect(!json.contains("pathBytes"))
    }

    /// The whole-status payload is an object with one `entries` key — an
    /// object can gain sibling fields additively under the schema rule; a
    /// bare array cannot.
    @Test func worktreeStatusEncodesAsAnEntriesObject() throws {
        var entry = WorktreeStatusEntry(path: "a.txt")
        entry.worktree = .modified
        let value = WorktreeStatus(entries: [entry])
        #expect(try wireJSON(value) == #"{"entries":[{"path":"a.txt","staged":".","worktree":"M"}]}"#)
    }

    // MARK: - ConflictedFile

    /// A both-modified conflict with all three stages, every field populated.
    /// `kind` encodes as the porcelain XY raw value (#0129 Decision 5), each
    /// stage as an `{mode, oid}` object, and `pathBytes` never appears.
    @Test func conflictedFileFullValueEncodesToTheLiteralWireShape() throws {
        let value = ConflictedFile(
            path: "file.txt",
            pathBytes: Array("file.txt".utf8),
            kind: .bothModified,
            base: ConflictedFile.StageEntry(
                oid: "df967b96a579e45a18b8251732d16804b2e56a55", mode: "100644"),
            ours: ConflictedFile.StageEntry(
                oid: "ba2906d0666cf726c7eaadd2cd3db615dedfdf3a", mode: "100644"),
            theirs: ConflictedFile.StageEntry(
                oid: "2299c37978265a95cbe835a4b0f0bbf15aad5549", mode: "100644"))
        #expect(try wireJSON(value) == #"{"base":{"mode":"100644","oid":"df967b96a579e45a18b8251732d16804b2e56a55"},"kind":"UU","ours":{"mode":"100644","oid":"ba2906d0666cf726c7eaadd2cd3db615dedfdf3a"},"path":"file.txt","theirs":{"mode":"100644","oid":"2299c37978265a95cbe835a4b0f0bbf15aad5549"}}"#)
    }

    /// Real bytes, end to end: the `u` record `git status --porcelain=v2 -z`
    /// emitted for an add/add conflict at a NON-UTF-8 path (created via
    /// `git update-index --index-info`; measured 2026-08-07) parses through
    /// `ConflictParser` and encodes with the nil `base` omitted, the lossy
    /// path, and no raw-bytes key. This is the parser+encoder conjunction —
    /// each half passing alone would not prove the wire.
    @Test func conflictParserOutputForANonUTF8ConflictEncodesLossily() throws {
        let record = "u AA N... 000000 100644 100644 000000 "
            + "0000000000000000000000000000000000000000 "
            + "587be6b4c3f93f93c489c0111bba5596147a26cb "
            + "975fbec8256d3e8a3797e7a3611380f27c49f4ac caf"
        let bytes = Array(record.utf8) + [0xE9] + Array(".txt".utf8) + [0x00]
        let files = try ConflictParser().parse(Data(bytes))
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.pathBytes.contains(0xE9))
        let json = try wireJSON(file)
        #expect(json == #"{"kind":"AA","ours":{"mode":"100644","oid":"587be6b4c3f93f93c489c0111bba5596147a26cb"},"path":"caf\#u{FFFD}.txt","theirs":{"mode":"100644","oid":"975fbec8256d3e8a3797e7a3611380f27c49f4ac"}}"#)
        #expect(!json.contains("\"base\""))
        #expect(!json.contains("null"))
        #expect(!json.contains("pathBytes"))
    }

    // MARK: - Envelope passthrough

    /// The M1 exit-criterion sentence for both payloads: each wraps in the
    /// real `Envelope` through `EncodableResult` — the compile itself proves
    /// the `Encodable & Sendable` bound — and each full response is
    /// byte-pinned with the v1 frame keys. The conflicts payload is a JSON
    /// array in `result`, matching `conflictedFiles(at:)`'s `[ConflictedFile]`.
    @Test func envelopeWrapsStatusAndConflictsPayloads() throws {
        var entry = WorktreeStatusEntry(path: "a.txt")
        entry.staged = .added
        let status = WorktreeStatus(entries: [entry])
        #expect(try wireJSON(Envelope(result: EncodableResult(status))) == #"{"ok":true,"result":{"entries":[{"path":"a.txt","staged":"A","worktree":"."}]},"schemaVersion":1}"#)

        let conflicts = [ConflictedFile(
            path: "file.txt",
            pathBytes: Array("file.txt".utf8),
            kind: .bothDeleted,
            base: ConflictedFile.StageEntry(
                oid: "df967b96a579e45a18b8251732d16804b2e56a55", mode: "100644"),
            ours: nil,
            theirs: nil)]
        let json = try wireJSON(Envelope(result: EncodableResult(conflicts)))
        #expect(json == #"{"ok":true,"result":[{"base":{"mode":"100644","oid":"df967b96a579e45a18b8251732d16804b2e56a55"},"kind":"DD","path":"file.txt"}],"schemaVersion":1}"#)

        // Structural read-back of one envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [[String: Any]])
        #expect(result.first?["kind"] as? String == "DD")
    }
}
