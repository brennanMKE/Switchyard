// ExitClassCoverageTests.swift — no ExitClassCarrying conformer ships unasserted (#0181)
//
// Swift cannot enumerate a protocol's conformers at runtime, so the conformer
// list comes from a source scan — the `ServiceNamesTests` pattern — and the
// assertion side is a runtime registry in this file: one constructed sample
// value per conformer, with the §6 class the type declares. The two are
// compared as sets in BOTH directions, so a scanner that silently returns
// nothing is itself red (every registry row reads as stale) rather than
// vacuously green. The registry's name column is checked against the runtime
// type of each sample (`String(reflecting:)`), so a row cannot claim to cover
// a type it does not construct.
//
// This target imports YardGit without `@testable` on purpose: a conformer
// whose exit class cannot be reached from a public caller would fail to
// compile here, which is the #0116 failure class caught at build time.

import Foundation
import Testing
import YardGit

@Suite("§6 exit-class coverage")
struct ExitClassCoverageTests {

    // MARK: - The registry

    /// One row per `ExitClassCarrying` conformer: the type name exactly as
    /// the conformance declaration writes it, a constructed sample value,
    /// and the §6 class the type declares.
    private struct Row {
        let name: String
        let sample: any ExitClassCarrying
        let expected: ExitClass

        init(_ name: String, _ sample: any ExitClassCarrying, _ expected: ExitClass) {
            self.name = name
            self.sample = sample
            self.expected = expected
        }
    }

    /// Conformers whose exit class already had an assertion somewhere in the
    /// test tree when #0181 landed — the #0141/#0146/#0147 wire tests, plus
    /// the per-family assertions in `CrossToolGuardTests`,
    /// `JournalLockTests`, `WorktreeDisturbanceTests`, `StagingTests`, and
    /// `IndexSnapshotTests`.
    private func alreadyAsserted() throws -> [Row] {
        [
            Row("WorktreeContext.Error", WorktreeContext.Error.pathNotResolved(name: "MERGE_HEAD"), .repositoryError),
            Row("WorktreeRemoveError", WorktreeRemoveError.unknown(path: "/x"), .repositoryError),
            Row("WorktreeAddError", WorktreeAddError.branchExists("main"), .repositoryError),
            Row("GitProcess.Failure", GitProcess.Failure.launchFailed("posix_spawn failed"), .repositoryError),
            Row("WorktreeListError", WorktreeListError.couldNotList(detail: "boom"), .repositoryError),
            Row("WorktreeSparseError", WorktreeSparseError.patternRefused(detail: "boom"), .repositoryError),
            Row("WorktreeRepair.Error", WorktreeRepair.Error.notRepaired(detail: "boom", exitCode: 128), .repositoryError),
            Row("WorktreeWhere.Error", WorktreeWhere.Error.couldNotListWorktrees(detail: "boom"), .repositoryError),
            Row("WorktreeTemplate.Failure", WorktreeTemplate.Failure.unsupportedVersion(99), .repositoryError),
            Row("ConflictParser.Failure", ConflictParser.Failure.truncatedRecord("u"), .repositoryError),
            Row("HunkParser.Failure", HunkParser.Failure.malformedFileHeader("diff --git"), .repositoryError),
            Row("BlameParser.Failure", BlameParser.Failure.truncatedEntry(oid: String(repeating: "a", count: 40)), .repositoryError),
            Row("RevListParser.Failure", RevListParser.Failure.malformedLine("not-an-oid"), .repositoryError),
            Row("JournalLockError", JournalLockError.timedOut(path: "/x", timeout: .seconds(1)), .repositoryError),
            Row("CrossToolGuard.Error", CrossToolGuard.Error.repositoryChanged(divergences: []), .repositoryError),
            Row("WorktreeDisturbance.Error", WorktreeDisturbance.Error.wouldDisturb(disturbances: []), .repositoryError),
            Row("StagingError", StagingError.unknownHunkIDs(ids: ["h-nope"], area: .unstaged), .repositoryError),
            Row("IndexSnapshot.Error", IndexSnapshot.Error.malformedPlumbingOutput(command: "hash-object"), .repositoryError),
            // #0152: asserted in WorktreeSnapshotTests.
            Row("WorktreeSnapshot.Error", WorktreeSnapshot.Error.malformedPlumbingOutput(command: "write-tree"), .repositoryError),
        ]
    }

    /// The nine conformers #0181 measured with NO exit-class assertion
    /// anywhere in any test target. Kept as a separate block so the gap this
    /// issue closed stays visible, and so deleting this one `+` operand
    /// reproduces the measured red state.
    private func newlyAsserted() throws -> [Row] {
        let earlier = try #require(JournalEntryID("01ARZ3NDEKTSV4RRFFQ69G5FAV"))
        let later = try #require(JournalEntryID("01BX5ZZKBKACTAV9WEVGEMMVRZ"))
        return [
            Row("HookInstall.Failure", HookInstall.Failure.hooksPathManaged(path: "/x/hooks"), .repositoryError),
            Row("JournalAnchor.Error", JournalAnchor.Error.foreignRef("refs/heads/main"), .repositoryError),
            Row("JournalChain.Error", JournalChain.Error.unordered(previous: later, next: earlier), .repositoryError),
            Row("JournalEntryMetadata.SerializationError", JournalEntryMetadata.SerializationError.undecodable(detail: "not JSON"), .repositoryError),
            Row("JournalRebuild.Error", JournalRebuild.Error.malformedPlumbingOutput(command: "cat-file", detail: "boom"), .repositoryError),
            Row("JournalRestore.Error", JournalRestore.Error.unrestorableObjects(missing: []), .repositoryError),
            Row("JournalUndo.Error", JournalUndo.Error.nothingToUndo(requested: 1, available: 0), .repositoryError),
            Row("RefSnapshot.Error", RefSnapshot.Error.malformedRefLine("bad line"), .repositoryError),
            Row("RefSnapshot.SerializationError", RefSnapshot.SerializationError.notUTF8, .repositoryError),
        ]
    }

    /// Conformers added after #0181 landed. Each asserts its own exit class in
    /// its own test file; the row here is what keeps the source scan and the
    /// registry in agreement. `CommitCreate.Failure` (#0036) asserts exit 9 in
    /// `CommitCreateTests.signingFailureCarriesExitClassNine`.
    private func addedSinceTheGuard() throws -> [Row] {
        [
            Row("CommitCreate.Failure", CommitCreate.Failure.signingFailed(reason: "x"), .signingFailed),
        ]
    }

    private func registry() throws -> [Row] {
        try alreadyAsserted() + newlyAsserted() + addedSinceTheGuard()
    }

    /// Deliberate omissions: conformer name → the recorded reason, which must
    /// cite an issue number. Adding an entry here is a decision, not a
    /// default — a conformer belongs in the registry unless an issue says why
    /// it cannot. Empty today.
    private let allowList: [String: String] = [:]

    // MARK: - The source scan

    /// Locates the repository root from this file, so the tests work wherever
    /// the package is checked out — under `swift test` and under Xcode alike.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YardWireTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // YardKit
            .deletingLastPathComponent()   // repo root
    }

    /// The scan half lives in `ConformanceScan` (#0182/#0185), parameterised
    /// by protocol name and shared with `DescriptionCoverageTests`. This
    /// guard keeps #0181's convention: `ExitClassCarrying` is adopted via
    /// top-level extensions only, so a declaration-site conformance is
    /// refused by `scannerRecognizesEveryConformanceSite` rather than
    /// silently folded in.
    private func scanSources() throws -> ConformanceScan.Result {
        try ConformanceScan.scan(
            for: "ExitClassCarrying",
            under: repoRoot.appendingPathComponent("YardKit/Sources"))
    }

    // MARK: - The guard

    /// #0181's headline: every conformer found in the sources has a registry
    /// row or a recorded allow-list reason — so the next `ExitClassCarrying`
    /// type cannot ship bare — and every row still matches a real
    /// conformance, so the scan going empty or a type being renamed is red
    /// here, not silently absorbed.
    @Test func everySourceConformerHasARegistryRow() throws {
        let scan = try scanSources()
        let conformers = Set(scan.extensionSites.map(\.name))
        try #require(
            !conformers.isEmpty,
            "the source scan found no ExitClassCarrying conformers at all — the scanner or its path is broken")

        let registered = Set(try registry().map(\.name))
        let allowed = Set(allowList.keys)

        let missing = conformers.subtracting(registered).subtracting(allowed)
        #expect(
            missing.isEmpty,
            """
            ExitClassCarrying conformers with no exit-class assertion: \
            \(missing.sorted().joined(separator: ", ")). \
            Add a registry row in ExitClassCoverageTests.swift, or an \
            allow-list entry whose reason cites an issue.
            """)

        let stale = registered.union(allowed).subtracting(conformers)
        #expect(
            stale.isEmpty,
            """
            registry or allow-list names with no source conformance (type \
            renamed or removed, or the scanner broke): \
            \(stale.sorted().joined(separator: ", "))
            """)

        let contradictions = registered.intersection(allowed)
        #expect(
            contradictions.isEmpty,
            "both registered and allow-listed: \(contradictions.sorted().joined(separator: ", "))")
    }

    /// The scanner accounts for every line that names the protocol: one
    /// declaration of `ExitClassCarrying` itself, and no line in a shape the
    /// scanner cannot classify.
    @Test func scannerRecognizesEveryConformanceSite() throws {
        let scan = try scanSources()
        #expect(
            scan.protocolDeclarations == 1,
            "expected exactly one ExitClassCarrying protocol declaration, found \(scan.protocolDeclarations)")
        #expect(
            scan.declarationSites.isEmpty,
            """
            ExitClassCarrying must be adopted via a top-level `extension \
            Name: ExitClassCarrying` (#0181 decision 3), not at the type \
            declaration: \(scan.declarationSites.sorted().map(\.label).joined(separator: ", "))
            """)
        #expect(scan.duplicates.isEmpty,
                "duplicate conformance sites: \(scan.duplicates.joined(separator: ", "))")
        #expect(
            scan.unrecognized.isEmpty,
            """
            lines naming ExitClassCarrying in a shape the scanner does not \
            recognize — conform via a top-level `extension Name:
            ExitClassCarrying`, or extend the scanner: \
            \(scan.unrecognized.joined(separator: " | "))
            """)
    }

    /// The assertion the registry exists to make: each conformer's declared
    /// §6 class. This is the test that catches the mutation measured in
    /// #0179/#0181 — flipping one type's `exitClass` to `.signingFailed`
    /// was green across the whole suite before this file existed.
    @Test func everyRegistrySampleCarriesItsDeclaredClass() throws {
        let rows = try registry()
        try #require(!rows.isEmpty, "empty registry")
        for row in rows {
            #expect(
                row.sample.exitClass == row.expected,
                "\(row.name) carries \(row.sample.exitClass), registry expects \(row.expected)")
        }
    }

    /// The name column is honest: each row's name is the runtime type of the
    /// sample it constructs, so a row cannot claim coverage of a type it
    /// does not exercise, and no type is covered by two rows.
    @Test func registryNamesMatchTheRuntimeTypes() throws {
        let rows = try registry()
        try #require(!rows.isEmpty, "empty registry")
        #expect(
            Set(rows.map(\.name)).count == rows.count,
            "duplicate registry rows")
        for row in rows {
            let runtime = String(reflecting: type(of: row.sample))
            #expect(
                runtime == "YardGit.\(row.name)",
                "registry row named \(row.name) constructs a \(runtime)")
        }
    }
}
