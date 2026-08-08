// DiffBlameWireTests.swift — diff and blame payloads encode to the
// schemaVersion 1 envelope (#0132): FileDiff, Hunk, BlameLine.

import Foundation
import Testing
import YardGit
import YardKit

/// Real `git diff` output (2.50.1), byte-for-byte: two hunks in one file
/// whose path contains a space, produced with exactly the flags
/// `listHunks(at:area:)` passes. The trailing `\t` on the `---`/`+++` lines
/// is git's own — it appends a tab after a path containing a space.
private let releaseNotesDiff: String = [
    "diff --git a/release notes.txt b/release notes.txt",
    "index 624b469..f925e58 100644",
    "--- a/release notes.txt\t",
    "+++ b/release notes.txt\t",
    "@@ -1,5 +1,5 @@",
    " line 1",
    "-line 2",
    "+line two edited",
    " line 3",
    " line 4",
    " line 5",
    "@@ -7,6 +7,6 @@ line 6",
    " line 7",
    " line 8",
    " line 9",
    "-line 10",
    "+line ten edited",
    " line 11",
    " line 12",
    "",
].joined(separator: "\n")

/// Real `git diff` output for a chmod with no content change — a FileDiff
/// with both modes and zero hunks.
private let modeOnlyDiff: String = [
    "diff --git a/script.sh b/script.sh",
    "old mode 100644",
    "new mode 100755",
    "",
].joined(separator: "\n")

/// Real `git blame --porcelain` output (2.50.1), byte-for-byte: a
/// three-line file where line 1 comes from the root commit (`boundary`),
/// line 2 from a second commit, and line 3 is uncommitted worktree content
/// (the all-zeros oid, `Not Committed Yet`, and git's fabricated summary).
private let poemBlame: String = [
    "deadd09454eb3135819c0d0809699c3c1dfb1543 1 1 1",
    "author Fixture Author",
    "author-mail <fixture@example.invalid>",
    "author-time 1767323045",
    "author-tz +0000",
    "committer Fixture Author",
    "committer-mail <fixture@example.invalid>",
    "committer-time 1767323045",
    "committer-tz +0000",
    "summary root commit",
    "boundary",
    "filename poem.txt",
    "\talpha",
    "38c87b98ddd7d931ec2761fee3bf94871d85b80c 2 2 1",
    "author Fixture Author",
    "author-mail <fixture@example.invalid>",
    "author-time 1770091506",
    "author-tz +0000",
    "committer Fixture Author",
    "committer-mail <fixture@example.invalid>",
    "committer-time 1770091506",
    "committer-tz +0000",
    "summary improve beta",
    "previous deadd09454eb3135819c0d0809699c3c1dfb1543 poem.txt",
    "filename poem.txt",
    "\tbeta improved",
    "0000000000000000000000000000000000000000 3 3 1",
    "author Not Committed Yet",
    "author-mail <not.committed.yet>",
    "author-time 1786154566",
    "author-tz -0700",
    "committer Not Committed Yet",
    "committer-mail <not.committed.yet>",
    "committer-time 1786154566",
    "committer-tz -0700",
    "summary Version of poem.txt from poem.txt",
    "previous 38c87b98ddd7d931ec2761fee3bf94871d85b80c poem.txt",
    "filename poem.txt",
    "\tgamma uncommitted",
    "",
].joined(separator: "\n")

@Suite("Diff and blame wire shapes")
struct DiffBlameWireTests {

    // MARK: - Hunk

    /// One hunk alone, parsed from real diff bytes. The `id` literal
    /// `e0cf3dfb859e` pins the content-derived id (#0016: SHA-256 over path
    /// and body, truncated to 12 hex) — any change to the derivation goes
    /// red here. The computed `patchText` is not on the wire (#0129
    /// Decision 7); `header` and `body` are, so a reader can reconstruct it.
    @Test func hunkEncodesToTheLiteralWireShapeWithItsDerivedID() throws {
        let files = try HunkParser().parse(releaseNotesDiff)
        let hunk = try #require(files.first?.hunks.first)
        let json = try wireJSON(hunk)
        #expect(json == #"{"body":[" line 1","-line 2","+line two edited"," line 3"," line 4"," line 5"],"header":"@@ -1,5 +1,5 @@","id":"e0cf3dfb859e","newCount":5,"newStart":1,"oldCount":5,"oldStart":1,"path":"release notes.txt"}"#)
        #expect(!json.contains("patchText"))
    }

    // MARK: - FileDiff

    /// The whole file's diff: both hunks nested (each under its own derived
    /// id), `headerText` byte-for-byte including git's trailing tabs, and
    /// the nil `oldMode`/`newMode` OMITTED from the wire, never `null`.
    @Test func fileDiffNestsHunksAndOmitsNilModes() throws {
        let files = try HunkParser().parse(releaseNotesDiff)
        #expect(files.count == 1)
        let json = try wireJSON(try #require(files.first))
        #expect(json == #"{"headerText":"diff --git a\/release notes.txt b\/release notes.txt\nindex 624b469..f925e58 100644\n--- a\/release notes.txt\t\n+++ b\/release notes.txt\t\n","hunks":[{"body":[" line 1","-line 2","+line two edited"," line 3"," line 4"," line 5"],"header":"@@ -1,5 +1,5 @@","id":"e0cf3dfb859e","newCount":5,"newStart":1,"oldCount":5,"oldStart":1,"path":"release notes.txt"},{"body":[" line 7"," line 8"," line 9","-line 10","+line ten edited"," line 11"," line 12"],"header":"@@ -7,6 +7,6 @@ line 6","id":"c930666f6ddd","newCount":6,"newStart":7,"oldCount":6,"oldStart":7,"path":"release notes.txt"}],"isBinary":false,"path":"release notes.txt"}"#)
        #expect(!json.contains("\"oldMode\""))
        #expect(!json.contains("null"))
    }

    /// A mode-only change: both modes ride the wire and the empty `hunks`
    /// array encodes as `[]` — present, never omitted. Binary and mode-only
    /// changes are represented, not silently dropped.
    @Test func modeOnlyFileDiffEncodesEmptyHunksAndBothModes() throws {
        let files = try HunkParser().parse(modeOnlyDiff)
        let json = try wireJSON(try #require(files.first))
        #expect(json == #"{"headerText":"diff --git a\/script.sh b\/script.sh\nold mode 100644\nnew mode 100755\n","hunks":[],"isBinary":false,"newMode":"100755","oldMode":"100644","path":"script.sh"}"#)
        #expect(json.contains(#""hunks":[]"#))
    }

    // MARK: - BlameLine

    /// A root-commit line, every field populated, built through the
    /// memberwise init: the `boundary` marker rides as `isBoundary` — a
    /// wire-visible state an agent branches on for "attribution stops here".
    @Test func blameLineFullValueEncodesToTheLiteralWireShape() throws {
        let value = BlameLine(
            oid: "deadd09454eb3135819c0d0809699c3c1dfb1543",
            finalLine: 1, originalLine: 1, originalPath: "poem.txt",
            author: "Fixture Author", authorEmail: "fixture@example.invalid",
            authorTime: 1767323045, authorTimeZone: "+0000",
            summary: "root commit", isBoundary: true, content: "alpha")
        #expect(try wireJSON(value) == #"{"author":"Fixture Author","authorEmail":"fixture@example.invalid","authorTime":1767323045,"authorTimeZone":"+0000","content":"alpha","finalLine":1,"isBoundary":true,"oid":"deadd09454eb3135819c0d0809699c3c1dfb1543","originalLine":1,"originalPath":"poem.txt","summary":"root commit"}"#)
    }

    /// An uncommitted line: the wire carries the 40-zero oid VERBATIM — the
    /// state an agent branches on — and the computed `isUncommitted` is not
    /// encoded (#0129 Decision 7), because the reader derives it from `oid`.
    @Test func uncommittedBlameLineCarriesTheAllZerosOID() throws {
        let value = BlameLine(
            oid: BlameLine.uncommittedOID,
            finalLine: 3, originalLine: 3, originalPath: "poem.txt",
            author: "Not Committed Yet", authorEmail: "not.committed.yet",
            authorTime: 1786154566, authorTimeZone: "-0700",
            summary: "Version of poem.txt from poem.txt",
            isBoundary: false, content: "gamma uncommitted")
        #expect(value.isUncommitted)
        let json = try wireJSON(value)
        #expect(json == #"{"author":"Not Committed Yet","authorEmail":"not.committed.yet","authorTime":1786154566,"authorTimeZone":"-0700","content":"gamma uncommitted","finalLine":3,"isBoundary":false,"oid":"0000000000000000000000000000000000000000","originalLine":3,"originalPath":"poem.txt","summary":"Version of poem.txt from poem.txt"}"#)
        #expect(!json.contains("isUncommitted"))
    }

    /// The parser+encoder conjunction on real porcelain bytes: all three
    /// lines — boundary root, ordinary commit, uncommitted — in final-line
    /// order, as one wire array. Each half passing alone would not prove
    /// the wire.
    @Test func blameParserOutputForARealPorcelainRunEncodes() throws {
        let lines = try BlameParser().parse(poemBlame)
        #expect(lines.count == 3)
        #expect(try wireJSON(lines) == #"[{"author":"Fixture Author","authorEmail":"fixture@example.invalid","authorTime":1767323045,"authorTimeZone":"+0000","content":"alpha","finalLine":1,"isBoundary":true,"oid":"deadd09454eb3135819c0d0809699c3c1dfb1543","originalLine":1,"originalPath":"poem.txt","summary":"root commit"},{"author":"Fixture Author","authorEmail":"fixture@example.invalid","authorTime":1770091506,"authorTimeZone":"+0000","content":"beta improved","finalLine":2,"isBoundary":false,"oid":"38c87b98ddd7d931ec2761fee3bf94871d85b80c","originalLine":2,"originalPath":"poem.txt","summary":"improve beta"},{"author":"Not Committed Yet","authorEmail":"not.committed.yet","authorTime":1786154566,"authorTimeZone":"-0700","content":"gamma uncommitted","finalLine":3,"isBoundary":false,"oid":"0000000000000000000000000000000000000000","originalLine":3,"originalPath":"poem.txt","summary":"Version of poem.txt from poem.txt"}]"#)
    }

    // MARK: - Envelope passthrough

    /// The M1 exit-criterion sentence for both payloads. `listHunks` returns
    /// `[FileDiff]` and `blameFile` returns `[BlameLine]` with no wrapper
    /// type, so each payload rides as a JSON array in `result` (the same
    /// shape #0131 settled for `conflictedFiles`).
    @Test func envelopeWrapsDiffAndBlamePayloads() throws {
        let files = try HunkParser().parse(modeOnlyDiff)
        #expect(try wireJSON(Envelope(result: EncodableResult(files))) == #"{"ok":true,"result":[{"headerText":"diff --git a\/script.sh b\/script.sh\nold mode 100644\nnew mode 100755\n","hunks":[],"isBinary":false,"newMode":"100755","oldMode":"100644","path":"script.sh"}],"schemaVersion":1}"#)

        let lines = try BlameParser().parse(poemBlame)
        let uncommitted = try #require(lines.last)
        let json = try wireJSON(Envelope(result: EncodableResult([uncommitted])))
        #expect(json == #"{"ok":true,"result":[{"author":"Not Committed Yet","authorEmail":"not.committed.yet","authorTime":1786154566,"authorTimeZone":"-0700","content":"gamma uncommitted","finalLine":3,"isBoundary":false,"oid":"0000000000000000000000000000000000000000","originalLine":3,"originalPath":"poem.txt","summary":"Version of poem.txt from poem.txt"}],"schemaVersion":1}"#)

        // Structural read-back of the envelope frame, so a failure here
        // distinguishes "envelope broke" from "payload byte drift".
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["ok"] as? Bool == true)
        let result = try #require(object["result"] as? [[String: Any]])
        #expect(result.first?["oid"] as? String == BlameLine.uncommittedOID)
    }
}
