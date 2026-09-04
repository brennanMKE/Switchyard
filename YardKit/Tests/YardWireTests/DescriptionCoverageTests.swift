// DescriptionCoverageTests.swift — no engine CustomStringConvertible
// conformer ships with an unasserted description (#0182)
//
// An error's `description` is what an agent reads when a command fails — it
// rides in the CLI's `{"error":{"message":"…"}}` (guide §6). #0182's finding:
// review emptied `StagingError.description` and the suite stayed green. This
// file is the structural fix, on #0181's mechanism: the conformer list comes
// from a source scan (`ConformanceScan`), the assertion side is a runtime
// registry of constructed samples, and the two are compared as sets in BOTH
// directions, so a broken scan is red rather than vacuously green.
//
// The registry asserts SUBSTANCE, not full literals: for a description that
// interpolates values, the values (and load-bearing joins like " → ") must
// appear in the rendered string. Rewording a message stays green; an empty
// string, a dropped interpolation, or a flattened arrow goes red.
//
// This target imports YardGit without `@testable` on purpose: every sample
// must be constructible by a public caller (#0116 failure class, caught at
// build time).

import Foundation
import Testing
import YardGit

@Suite("§6 error-message coverage")
struct DescriptionCoverageTests {

    // MARK: - The registry

    /// What a row asserts about its sample's description beyond "not empty".
    private enum Substance {
        /// The description interpolates data: every listed fragment must
        /// appear verbatim in the rendered string. Fragments are the
        /// interpolated values — plus an anchoring word only where the bare
        /// value would match accidentally (counts, small numbers) — never
        /// whole sentences of prose.
        case carries([String])
        /// The description is fixed prose with no interpolated values, so
        /// non-empty is the whole check; the reason records why that is
        /// acceptable and must cite an issue. No conformer needs this today.
        case prose(reason: String)
    }

    /// One row per conformer: the file and local type name exactly as the
    /// conformance declaration site has them (the scan's identity), the
    /// qualified type name (the runtime identity), a constructed sample,
    /// and the substance its description must carry.
    private struct Row {
        let file: String
        let name: String
        let sample: any CustomStringConvertible
        let substance: Substance

        init(_ file: String, _ name: String,
             _ sample: any CustomStringConvertible, _ substance: Substance) {
            self.file = file
            self.name = name
            self.sample = sample
            self.substance = substance
        }

        /// The scan-side identity this row claims: source file plus the
        /// local name, which is the qualified name's last component.
        var siteLabel: String {
            "\(file):\(name.split(separator: ".").last.map(String.init) ?? name)"
        }
    }

    private func registry() throws -> [Row] {
        let ulid = try #require(JournalEntryID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        let laterUlid = try #require(JournalEntryID("01BX5ZZKBKACTAV9WEVGEMMVRZ"))
        let oid1 = String(repeating: "1", count: 40)
        let oid2 = String(repeating: "2", count: 40)
        let oid3 = String(repeating: "3", count: 40)
        let trailer = try #require(Trailer.parse("Reviewed-by: Probe Reviewer <probe@example.invalid>"))
        return [
            Row("Blame.swift", "BlameParser.Failure",
                BlameParser.Failure.truncatedEntry(oid: oid1),
                .carries([oid1])),
            Row("CommitCreate.swift", "CommitCreate.Failure",
                CommitCreate.Failure.signingFailed(reason: "probe gpg refused the data"),
                .carries(["signing failed", "probe gpg refused the data"])),
            Row("CommitLog.swift", "Trailer",
                trailer,
                .carries(["Reviewed-by", "Probe Reviewer <probe@example.invalid>"])),
            Row("Staging.swift", "CommitHunksError",
                CommitHunksError.indexNotClean(paths: ["probe/staged-a.txt", "probe/staged-b.txt"]),
                .carries(["probe/staged-a.txt", "probe/staged-b.txt"])),
            Row("Conflicts.swift", "ConflictParser.Failure",
                ConflictParser.Failure.unrecognizedKind(xy: "ZQ", path: "probe/conflicted.txt"),
                .carries(["ZQ", "probe/conflicted.txt"])),
            Row("CrossToolGuard.swift", "CrossToolGuard.Error",
                CrossToolGuard.Error.repositoryChanged(divergences: [
                    CrossToolGuard.Divergence(ref: "refs/heads/probe-main", expected: oid1, actual: nil),
                ]),
                .carries(["refs/heads/probe-main", "was \(oid1)", "absent"])),
            Row("FixtureRepository.swift", "FixtureRepository.Error",
                FixtureRepository.Error.unknownParent(commit: "probe-child", parent: "probe-parent"),
                .carries(["probe-child", "probe-parent"])),
            Row("Fixup.swift", "FixupError",
                FixupError.targetNotAncestor(target: "probe-target"),
                .carries(["probe-target", "not an ancestor of HEAD"])),
            Row("GitProcess.swift", "GitProcess.Failure",
                GitProcess.Failure.exited(code: 86, stderr: "probe stderr detail",
                                          arguments: ["rev-parse", "--git-dir"]),
                .carries(["rev-parse --git-dir", "exited 86", "probe stderr detail"])),
            Row("HookInstall.swift", "HookInstall.Failure",
                HookInstall.Failure.hooksPathManaged(path: "/probe/managed-hooks"),
                .carries(["/probe/managed-hooks"])),
            Row("Hunks.swift", "HunkParser.Failure",
                HunkParser.Failure.malformedHunkHeader("@@ probe-not-a-header @@"),
                .carries(["@@ probe-not-a-header @@"])),
            Row("IndexSnapshot.swift", "IndexSnapshot.Error",
                IndexSnapshot.Error.indexFileUnreadable(path: "/probe/gitdir/index",
                                                        detail: "probe EACCES"),
                .carries(["/probe/gitdir/index", "probe EACCES"])),
            Row("JournalAnchor.swift", "JournalEntryID",
                ulid,
                .carries(["01ARZ3NDEKTSV4RRFFQ69G5FAV"])),
            Row("JournalAnchor.swift", "JournalAnchor.Error",
                JournalAnchor.Error.malformedPlumbingOutput(command: "update-ref",
                                                            line: "probe bad line"),
                .carries(["update-ref", "probe bad line"])),
            Row("JournalMetadataCache.swift", "JournalMetadataCache.RowDefect",
                JournalMetadataCache.RowDefect(
                    id: JournalEntryID("01000000000000000000000042")!, reason: "probe reason"),
                .carries(["01000000000000000000000042", "probe reason"])),
            Row("SequencerSnapshot.swift", "SequencerSnapshot.Error",
                SequencerSnapshot.Error.directoryUnreadable(
                    path: "/probe/rebase-merge", detail: "probe detail"),
                .carries(["/probe/rebase-merge", "probe detail"])),
            Row("JournalMetadataCache.swift", "JournalMetadataCache.Error",
                JournalMetadataCache.Error.unsupportedSchema(version: 2, path: "/probe/journal.json"),
                .carries(["/probe/journal.json", "schema version 2", "rebuild it from refs"])),
            Row("JournalObserved.swift", "JournalObserved.Metadata.SerializationError",
                JournalObserved.Metadata.SerializationError.undecodable(detail: "probe decode detail"),
                .carries(["probe decode detail"])),
            Row("JournalChain.swift", "JournalChain.Error",
                JournalChain.Error.unordered(previous: laterUlid, next: ulid),
                .carries(["01ARZ3NDEKTSV4RRFFQ69G5FAV", "01BX5ZZKBKACTAV9WEVGEMMVRZ"])),
            Row("JournalEntryMetadata.swift", "JournalEntryMetadata.SerializationError",
                JournalEntryMetadata.SerializationError.unsupportedSchemaVersion(99),
                .carries(["schemaVersion 99"])),
            Row("JournalLock.swift", "JournalLockError",
                JournalLockError.timedOut(path: "/probe/journal.lock", timeout: .seconds(7)),
                .carries(["/probe/journal.lock", "7.0 seconds"])),
            Row("JournalRebuild.swift", "JournalRebuild.Defect",
                JournalRebuild.Defect.anchorNotACommit(id: ulid, oid: oid2, type: "blob"),
                .carries(["01ARZ3NDEKTSV4RRFFQ69G5FAV", "blob", oid2])),
            Row("JournalRebuild.swift", "JournalRebuild.Error",
                JournalRebuild.Error.malformedPlumbingOutput(command: "for-each-ref",
                                                             detail: "probe plumbing detail"),
                .carries(["for-each-ref", "probe plumbing detail"])),
            Row("JournalRestore.swift", "JournalRestore.Error",
                JournalRestore.Error.unrestorableObjects(missing: [
                    JournalRestore.MissingObject(ref: "refs/tags/probe-tag", oid: oid3),
                ]),
                .carries(["1 recorded object", "refs/tags/probe-tag → \(oid3)"])),
            Row("JournalUndo.swift", "JournalUndo.Error",
                JournalUndo.Error.nothingToUndo(requested: 5, available: 2),
                .carries(["5 step(s) requested", "2 available"])),
            Row("LaneAssignment.swift", "RevListParser.Failure",
                RevListParser.Failure.malformedLine("probe-not-hex"),
                .carries(["probe-not-hex"])),
            Row("RefSnapshot.swift", "RefSnapshot.Error",
                RefSnapshot.Error.malformedRefLine("probe ref line"),
                .carries(["probe ref line"])),
            Row("RefSnapshotSerialization.swift", "RefSnapshot.SerializationError",
                RefSnapshot.SerializationError.unsupportedHeader("probe-header-v99"),
                .carries(["probe-header-v99"])),
            Row("RepositoryIdentity.swift", "RepositoryIdentity.Error",
                RepositoryIdentity.Error.unwritable(path: "/probe/switchyard/repository-id",
                                                    detail: "probe write detail"),
                .carries(["/probe/switchyard/repository-id", "probe write detail"])),
            Row("ReviewNotes.swift", "ReviewNotes.Error",
                ReviewNotes.Error.malformedNotesListLine("probe notes line"),
                .carries(["probe notes line"])),
            Row("Staging.swift", "StagingError",
                StagingError.unknownHunkIDs(ids: ["h-probe-1", "h-probe-2"], area: .unstaged),
                .carries(["h-probe-1", "h-probe-2", "unstaged"])),
            Row("WorktreeAdd.swift", "WorktreeAddError",
                WorktreeAddError.branchInUse(branch: "probe-branch", holderPath: "/probe/holder",
                                             holderIsMainWorktree: false),
                .carries(["probe-branch", "/probe/holder"])),
            Row("WorktreeContext.swift", "WorktreeContext.Error",
                WorktreeContext.Error.notARepository(path: "/probe/nowhere",
                                                     detail: "probe fatal detail"),
                .carries(["/probe/nowhere", "probe fatal detail"])),
            Row("WorktreeDisturbance.swift", "WorktreeDisturbance.Error",
                WorktreeDisturbance.Error.wouldDisturb(disturbances: [
                    WorktreeDisturbance.Disturbance(worktreePath: "/probe/sibling",
                                                    branch: "refs/heads/probe-topic",
                                                    current: oid1, target: oid2, prunable: false),
                ]),
                .carries(["refs/heads/probe-topic", "/probe/sibling", "move to \(oid2)"])),
            Row("WorktreeList.swift", "WorktreeListError",
                WorktreeListError.couldNotList(detail: "probe list detail"),
                .carries(["probe list detail"])),
            Row("WorktreeRemove.swift", "WorktreeRemoveError",
                WorktreeRemoveError.nested(inside: "/probe/outer", target: "/probe/outer/inner"),
                .carries(["/probe/outer/inner", "/probe/outer"])),
            Row("WorktreeRepair.swift", "WorktreeRepair.Error",
                WorktreeRepair.Error.notRepaired(detail: "probe repair detail", exitCode: 86),
                .carries(["exited 86", "probe repair detail"])),
            Row("WorktreeSparse.swift", "WorktreeSparseError",
                WorktreeSparseError.patternRefused(detail: "probe/*"),
                .carries(["probe/*"])),
            Row("WorktreeSnapshot.swift", "WorktreeSnapshot.Error",
                WorktreeSnapshot.Error.noWorktree(gitDir: "/probe/bare.git"),
                .carries(["/probe/bare.git", "has no worktree"])),
            Row("WorktreeStatus.swift", "WorktreeStatusParser.Failure",
                WorktreeStatusParser.Failure.unrecognizedRecordType(leading: "Z"),
                .carries(["record type \"Z\""])),
            Row("WorktreeTemplate.swift", "WorktreeTemplate.Failure",
                WorktreeTemplate.Failure.invalidEntry(index: 7, reason: "probe missing field"),
                .carries(["entry 7", "probe missing field"])),
            Row("WorktreeWhere.swift", "WorktreeWhere.Error",
                WorktreeWhere.Error.couldNotListWorktrees(detail: "probe where detail"),
                .carries(["probe where detail"])),
        ]
    }

    /// Deliberate whole-type omissions: scan-site label
    /// (`File.swift:LocalName`) → the recorded reason, which must cite an
    /// issue number. Empty today; a conformer belongs in the registry unless
    /// an issue says why it cannot.
    private let allowList: [String: String] = [:]

    // MARK: - The source scan

    /// The scan covers `YardKit/Sources/YardGit` — the engine — and not the
    /// whole package, deliberately: `CustomStringConvertible` is a stdlib
    /// protocol any target may adopt for display, but a *description on an
    /// engine type* is the agent-facing error message this guard pins.
    private var engineRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardWireTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("YardKit/Sources/YardGit")
    }

    // MARK: - The guard

    /// #0182's headline: every engine conformer found in the sources has a
    /// registry row or a recorded allow-list reason — the next
    /// `CustomStringConvertible` type cannot ship with an unasserted
    /// description — and every row still matches a real conformance site, so
    /// the scan going empty or a type being renamed is red here, not
    /// silently absorbed.
    @Test func everyDescriptionConformerHasARegistryRow() throws {
        let scan = try ConformanceScan.scan(for: "CustomStringConvertible", under: engineRoot)
        try #require(
            !scan.sites.isEmpty,
            "the source scan found no CustomStringConvertible conformers at all — the scanner or its path is broken")

        let rows = try registry()
        let registered = Set(rows.map(\.siteLabel))
        let allowed = Set(allowList.keys)
        let found = Set(scan.sites.map(\.label))

        let missing = found.subtracting(registered).subtracting(allowed)
        #expect(
            missing.isEmpty,
            """
            CustomStringConvertible conformers with no description assertion: \
            \(missing.sorted().joined(separator: ", ")). \
            Add a registry row in DescriptionCoverageTests.swift, or an \
            allow-list entry whose reason cites an issue.
            """)

        let stale = registered.union(allowed).subtracting(found)
        #expect(
            stale.isEmpty,
            """
            registry or allow-list sites with no source conformance (type \
            renamed or removed, or the scanner broke): \
            \(stale.sorted().joined(separator: ", "))
            """)

        let contradictions = registered.intersection(allowed)
        #expect(
            contradictions.isEmpty,
            "both registered and allow-listed: \(contradictions.sorted().joined(separator: ", "))")
    }

    /// The scanner accounts for every line naming the protocol: no
    /// declaration of `CustomStringConvertible` itself (it is stdlib; one in
    /// the engine would shadow it), no duplicate sites, and no line in a
    /// shape the scanner cannot classify.
    @Test func descriptionScannerAccountsForEveryConformanceSite() throws {
        let scan = try ConformanceScan.scan(for: "CustomStringConvertible", under: engineRoot)
        #expect(
            scan.protocolDeclarations == 0,
            "CustomStringConvertible is a stdlib protocol; found \(scan.protocolDeclarations) declaration(s) shadowing it in the engine")
        #expect(scan.duplicates.isEmpty,
                "duplicate conformance sites: \(scan.duplicates.joined(separator: ", "))")
        #expect(
            scan.unrecognized.isEmpty,
            """
            lines naming CustomStringConvertible in a shape the scanner does \
            not recognize — conform at the type declaration or via a \
            top-level `extension Name: CustomStringConvertible`, or extend \
            ConformanceScan: \(scan.unrecognized.joined(separator: " | "))
            """)
    }

    /// The assertion the registry exists to make: each description is
    /// non-empty and carries its interpolated values. This is the test that
    /// catches #0182's measured mutation — `StagingError.description`
    /// replaced by `""` was green across 13 StagingTests — and the
    /// `ref → oid` arrow drift no test could see.
    @Test func everyRegistryDescriptionCarriesItsSubstance() throws {
        let rows = try registry()
        try #require(!rows.isEmpty, "empty registry")
        for row in rows {
            let text = row.sample.description
            #expect(!text.isEmpty, "\(row.name) renders an empty description")
            switch row.substance {
            case let .carries(fragments):
                try #require(!fragments.isEmpty,
                             "\(row.name): a carries row must list at least one fragment")
                for fragment in fragments {
                    #expect(
                        text.contains(fragment),
                        "\(row.name) description \"\(text)\" does not contain \"\(fragment)\"")
                }
            case .prose:
                break // non-empty is the whole check, by recorded decision
            }
        }
    }

    /// The name column is honest: each row's qualified name is the runtime
    /// type of the sample it constructs, so a row cannot claim coverage of a
    /// type it does not exercise, and no site is claimed by two rows.
    @Test func descriptionRegistryNamesMatchTheRuntimeTypes() throws {
        let rows = try registry()
        try #require(!rows.isEmpty, "empty registry")
        #expect(Set(rows.map(\.siteLabel)).count == rows.count, "duplicate registry rows")
        for row in rows {
            let runtime = String(reflecting: type(of: row.sample))
            #expect(
                runtime == "YardGit.\(row.name)",
                "registry row named \(row.name) constructs a YardGit.\(runtime)")
        }
    }
}
