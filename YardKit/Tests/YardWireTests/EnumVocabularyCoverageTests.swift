// EnumVocabularyCoverageTests.swift — every value an enum's git-output
// parser can produce is fed a real record and asserted (#0316).
//
// `ExitClassCoverageTests` and `DescriptionCoverageTests` both guard "every
// conformer of a protocol has an assertion" via a source scan compared
// against a runtime registry. This file guards a different shape: there is
// no protocol to scan for here, because the vocabulary lives in *how a
// value is constructed* — a `rawValue:` initializer, or a hand-written
// character switch — not in a conformance declaration a line-oriented scan
// can locate. So this file is table-driven against the enum's own case list
// (or, where the case list under-counts the real input space, the
// documented character alphabet), not scan-driven.
//
// Boundary — which enums count as "parsed out of git output": an enum
// belongs here when a value of it is constructed directly from a token
// git's own process output supplies, on the path a real command uses to
// build one — not any enum that merely models internal state (journal step
// kind, CLI intent, exit class, and so on) and never receives a byte from
// git. Two conformers meet that bar today, and are the two the M1 review
// pass measured:
//
//   - `ConflictedFile.Kind` (Conflicts.swift) — `Kind(rawValue:)` fed the XY
//     token of a `u` porcelain v2 record. `CaseIterable` and `String`-
//     backed, so its vocabulary IS its case list: looping over `allCases`
//     is exhaustive over the wire vocabulary by construction, and a case
//     added to the enum is automatically exercised with no separate row to
//     forget. #0311 measured 3 of 7 cases — `UD`, `AU`, `UA` — with no test
//     anywhere feeding them real bytes.
//
//   - `WorktreeStatusEntry.State` (WorktreeStatus.swift) — NOT 1:1 with its
//     own case list: `R` and `C` both alias to `.modified`, `A`/`+` and
//     `D`/`-` each alias to one case, and a leading `u` record overrides
//     `staged` to `.conflicted` regardless of its own XY field. `allCases`
//     therefore under-counts the real input space (9 cases, more than 9
//     input characters map onto them), so the table below is keyed on the
//     *character* alphabet rather than the case list — and the case count
//     is asserted separately (`stateCaseCountIsNine`) so a case added to
//     the enum itself is still visible even though it cannot drive the
//     character table's row count the way `Kind.allCases` drives the first
//     test.
//
//     The character alphabet itself is not invented for this file:
//     `WorktreeStatusParser.Failure.unrecognizedStatusCharacter`'s own doc
//     comment names it directly — "`. M T A D R C` (ordinary/rename) or
//     `D A U` (unmerged)" — plus the three special leading tokens the
//     zero-field record types use, `? ! u`. That is 7 + 3 (the unmerged
//     alphabet's `D`/`A` already counted, `U` new) + 3 = 11 distinct
//     characters, matching `alphabetRows().count` below.
//
//     `State.init?(char:)`'s switch also matches `+` and `-`, which appear
//     in neither documented alphabet above and are not real
//     `git status --porcelain=v2` output — nothing in this codebase or
//     git's own porcelain v2 documentation cites a record that emits them.
//     They are excluded from the table on that basis, which is a decision
//     recorded here, not an oversight: if a future record type turns out to
//     emit them, they belong in `alphabetRows()` and this paragraph is
//     wrong.
//
// Not scanned generically across the engine, unlike the two protocol-
// conformance guards: discovering "every enum fed from git output" from
// source text would mean recognizing arbitrary `RawValue:` call sites and
// hand-written character switches, which has no single canonical shape the
// way a conformance clause does. The issue that proposed this file draws
// the boundary explicitly by naming these two conformers; a generic scanner
// reaching further than that is exactly the kind of over-reach that gets a
// check disabled by the first person it wrongly flags.

import Foundation
import Testing
import YardGit

@Suite("§ enum-vocabulary coverage")
struct EnumVocabularyCoverageTests {

    // MARK: - ConflictedFile.Kind

    /// Every conflict kind git can report, fed a real-shaped `u` porcelain
    /// v2 record carrying that kind's own XY token, parsed through the same
    /// `ConflictParser` a real command uses. `Kind.allCases` drives the
    /// loop, so a case added to the enum is exercised automatically.
    @Test func everyConflictKindParsesFromARealPorcelainRecord() throws {
        #expect(
            ConflictedFile.Kind.allCases.count == 7,
            "a conflict kind was added or removed — update this file's header comment")

        for kind in ConflictedFile.Kind.allCases {
            let record = "u \(kind.rawValue) N... 100644 100644 100644 100644 "
                + "1111111111111111111111111111111111111111 "
                + "2222222222222222222222222222222222222222 "
                + "3333333333333333333333333333333333333333 conflict-probe.txt"
            let data = Data((record + "\u{0}").utf8)

            let files = try ConflictParser().parse(data)
            let entry = try #require(
                files.first,
                "XY \"\(kind.rawValue)\" (case \(kind)) produced no ConflictedFile at all")
            #expect(
                entry.kind == kind,
                "XY \"\(kind.rawValue)\" parsed as \(entry.kind), expected \(kind)")
        }
    }

    // MARK: - WorktreeStatusEntry's status alphabet

    private struct AlphabetRow {
        let char: String
        let record: Data
        let field: (WorktreeStatusEntry) -> WorktreeStatusEntry.State
        let expected: WorktreeStatusEntry.State
    }

    private static let renameHash = "35fbd83349cf5962cbef75d9f6340f48be890382"

    /// Builds a `2` (rename/copy) record in git's real layout, mirroring
    /// `WorktreeStatusTests.renameRecord`: `<fixed> <score> <new>\0<orig>\0`.
    private static func renameOrCopyRecord(xy: String, score: String, new: String, original: String) -> Data {
        var bytes: [UInt8] = Array(
            "2 \(xy) N... 100644 100644 100644 \(renameHash) \(renameHash) \(score) \(new)".utf8)
        bytes.append(0x00)
        bytes.append(contentsOf: Array(original.utf8))
        bytes.append(0x00)
        return Data(bytes)
    }

    private static func ordinaryRecord(xy: String, path: String) -> Data {
        Data("1 \(xy) N... 100644 100644 100644 aaa bbb \(path)\u{0}".utf8)
    }

    private static func specialRecord(leading: String, path: String) -> Data {
        Data("\(leading) \(path)\u{0}".utf8)
    }

    private static func unmergedRecord(path: String) -> Data {
        Data(("u UU N... 100644 100644 100644 100644 "
            + "4444444444444444444444444444444444444444 "
            + "5555555555555555555555555555555555555555 "
            + "6666666666666666666666666666666666666666 \(path)\u{0}").utf8)
    }

    /// One row per character in the documented status alphabet (see this
    /// file's header comment for where each character's membership comes
    /// from). `.field` picks `staged` or `worktree` — whichever side of the
    /// record the character actually appears on in real git output.
    private func alphabetRows() -> [AlphabetRow] {
        [
            AlphabetRow(char: ".", record: Self.ordinaryRecord(xy: "..", path: "dot.txt"),
                        field: \.staged, expected: .unmodified),
            AlphabetRow(char: "M", record: Self.ordinaryRecord(xy: "M.", path: "modified.txt"),
                        field: \.staged, expected: .modified),
            AlphabetRow(char: "T", record: Self.ordinaryRecord(xy: "T.", path: "typechanged.txt"),
                        field: \.staged, expected: .typechange),
            AlphabetRow(char: "A", record: Self.ordinaryRecord(xy: "A.", path: "added.txt"),
                        field: \.staged, expected: .added),
            AlphabetRow(char: "D", record: Self.ordinaryRecord(xy: "D.", path: "deleted.txt"),
                        field: \.staged, expected: .deleted),
            AlphabetRow(char: "R", record: Self.renameOrCopyRecord(
                            xy: "R.", score: "R100", new: "renamed.txt", original: "orig-r.txt"),
                        field: \.staged, expected: .modified),
            // #0310: `C` had no assertion anywhere in the suite before this file.
            AlphabetRow(char: "C", record: Self.renameOrCopyRecord(
                            xy: "C.", score: "C100", new: "copied.txt", original: "orig-c.txt"),
                        field: \.staged, expected: .modified),
            AlphabetRow(char: "U", record: Self.unmergedRecord(path: "unmerged.txt"),
                        field: \.worktree, expected: .unmerged),
            AlphabetRow(char: "u", record: Self.unmergedRecord(path: "conflicted.txt"),
                        field: \.staged, expected: .conflicted),
            AlphabetRow(char: "?", record: Self.specialRecord(leading: "?", path: "untracked.txt"),
                        field: \.worktree, expected: .untracked),
            AlphabetRow(char: "!", record: Self.specialRecord(leading: "!", path: "ignored.txt"),
                        field: \.worktree, expected: .ignored),
        ]
    }

    @Test func everyStatusAlphabetCharacterParsesFromARealRecord() throws {
        let rows = alphabetRows()
        #expect(
            Set(rows.map(\.char)).count == 11,
            "duplicate or missing alphabet row — the documented alphabet is . M T A D R C U u ? !")
        try #require(!rows.isEmpty)

        for row in rows {
            let status = try WorktreeStatusParser().parse(row.record)
            let entry = try #require(
                status.entries.first,
                "character \"\(row.char)\" produced no WorktreeStatusEntry at all")
            #expect(
                row.field(entry) == row.expected,
                "character \"\(row.char)\" parsed as \(row.field(entry)), expected \(row.expected)")
        }
    }

    /// Anchors `State`'s own case count. The alphabet table above is keyed
    /// on input characters, which can outnumber cases (`R`/`C` both land on
    /// `.modified`), so a case added to the enum without a new input
    /// character mapping to it would not grow `alphabetRows()` — this is a
    /// second, independent anchor rather than a duplicate of the count
    /// above.
    @Test func stateCaseCountIsNine() throws {
        #expect(
            WorktreeStatusEntry.State.allCases.count == 9,
            "a State case was added or removed — update the alphabet table above and this count")
    }
}
