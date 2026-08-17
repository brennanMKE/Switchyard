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
            Row("SequencerSnapshot.Error", SequencerSnapshot.Error.malformedPlumbingOutput(command: "mktree"), .repositoryError),
            Row("JournalMetadataCache.Error", JournalMetadataCache.Error.unsupportedSchema(version: 2, path: "/probe/journal.json"), .repositoryError),
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
            Row("WorktreeStatusParser.Failure",
                WorktreeStatusParser.Failure.unrecognizedRecordType(leading: "X"), .repositoryError),
            // #0208: asserted in CommitHunksTests.commitHunksErrorMapsToRepositoryError.
            Row("CommitHunksError", CommitHunksError.indexNotClean(paths: ["probe/staged.txt"]),
                .repositoryError),
            // #0039: FixupError has three distinct exit classes across its
            // cases (targetNotAncestor/nothingStaged → 6, blockedOnConflicts
            // → 8, signingFailed → 9); this row exercises the repositoryError
            // case, the same shape as the sibling errors above.
            Row("FixupError", FixupError.targetNotAncestor(target: "probe-target"), .repositoryError),
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

    // MARK: - Every declared error type, not just ExitClassCarrying conformers

    // #0197: the guard above answers "does every ExitClassCarrying conformer
    // carry the right class?" and structurally cannot answer "does every
    // error type carry one at all?" — a type that conforms to nothing
    // produces no line containing "ExitClassCarrying", so the guard above
    // stays green around it. That is how WorktreeStatusParser shipped with
    // no error type whatsoever (#0193) while every mechanical check passed.
    //
    // Discovery rule: every codebase error type today is declared with a
    // literal `Error` or `Swift.Error` token in its own conformance clause —
    // `enum WorktreeAddError: Error, ...` or `enum Error: Swift.Error, ...`
    // — verified by grepping every enum/struct/class/actor declaration under
    // `YardKit/Sources/YardGit` and `YardKit/Sources/YardKit` for a
    // conformance list containing the word `Error`: exactly 35 hits, all
    // `enum`, none `struct`/`class`/`actor`. So this reuses
    // `ConformanceScan.scan(for: "Error", under:)` — the same regex-based
    // scanner as the guard above, parameterised differently — and reads its
    // `declarationSites`/`extensionSites`, not `unrecognized`: unlike
    // `ExitClassCarrying`, the word "Error" also appears on nearly every
    // throw site and catch clause of a nested `.Error` type (`\bError\b`
    // matches across the dot in `WorktreeContext.Error.pathNotResolved`), so
    // `unrecognized` is expected to be large and is not a signal here.
    //
    // Matching identity: a declaration-site scan cannot see nesting, so a
    // conformer like `WorktreeContext.Error` is found as local name `Error`
    // in file `WorktreeContext.swift` — the same `file:localName` identity
    // `DescriptionCoverageTests.Row.siteLabel` already uses for its
    // declaration-site scan. The existing `ExitClassCarrying` registry is
    // scanned by qualified name via extension sites instead (`scanSources()`
    // above), so this guard re-derives `file:localName` from those same
    // extension sites rather than inventing a second registry to keep in
    // sync.

    /// Every type in the engine and the shared layer whose own declaration
    /// names `Error` or `Swift.Error` in its conformance clause, identified
    /// as `file:localName` (a declaration-site scan cannot see nesting).
    ///
    /// Scanned as **two** separate protocol names, not one: `ConformanceScan`
    /// wraps its match in `\b...\b`, and Swift's `Regex` word boundary
    /// follows Unicode text segmentation (UAX #29), which does not break a
    /// word between two letters joined by a period — `\bError\b` matches
    /// `.Error` but not `Swift.Error`, measured directly (`Regex("\\bError\\b")`
    /// matches against `".Error"` but not `"Swift.Error"` or `"X.Error"`).
    /// Scanning for the literal token `"Swift.Error"` sidesteps this: the
    /// escaped literal places `\b` only outside the whole token, with no
    /// boundary check on the internal dot, and correctly finds the ~20
    /// conformers that spell it that way — verified by hand against
    /// `RepositoryIdentity.swift` and `WorktreeContext.swift`, both of which
    /// `\bError\b` alone silently missed before this was found.
    private func declaredErrorSites() throws -> Set<ConformanceScan.Site> {
        let roots = [
            repoRoot.appendingPathComponent("YardKit/Sources/YardGit"),
            repoRoot.appendingPathComponent("YardKit/Sources/YardKit"),
        ]
        var sites: Set<ConformanceScan.Site> = []
        for root in roots {
            sites.formUnion(try ConformanceScan.scan(for: "Error", under: root).sites)
            sites.formUnion(try ConformanceScan.scan(for: "Swift.Error", under: root).sites)
        }
        return sites
    }

    /// Every `ExitClassCarrying` conformer from `scanSources()` above,
    /// reduced from its qualified name (`WorktreeContext.Error`) to the same
    /// `file:localName` identity `declaredErrorSites()` uses, so the two
    /// scans can be compared directly.
    private func exitClassConformedSites() throws -> Set<ConformanceScan.Site> {
        let scan = try scanSources()
        return Set(scan.extensionSites.map { site in
            ConformanceScan.Site(
                file: site.file,
                name: site.name.split(separator: ".").last.map(String.init) ?? site.name)
        })
    }

    /// Declared error types this guard does not require to carry an exit
    /// class, keyed by `file:localName`, each reason citing an issue. Adding
    /// an entry here is a decision, not a default: a declared error type
    /// belongs in `ExitClassCarrying` unless a reason says why it cannot.
    ///
    /// `FixtureRepository.Error` is #0197's headline finding: it ships in
    /// the `YardGit` product with no exit class, and is registered in
    /// `DescriptionCoverageTests`, so the omission reads as an oversight.
    /// Decided here as an exclusion, not a new conformance: it is a
    /// test/diagnostic fixture-builder error (`FixtureRepository` "[b]uilds
    /// throwaway git repositories for tests"), thrown only while assembling
    /// a DAG description for a test, and it never reaches a real command's
    /// §6 mapping the way every other conformer above does.
    ///
    /// Extending the same scan to `YardKit/Sources/YardKit` (per this
    /// issue's Expected behavior) surfaced two more gaps #0197 did not
    /// anticipate, both recorded here rather than silently left red:
    /// `RepositoryIdentity.Error` has no call site anywhere in `Sources`
    /// today (the same "not wired to a command path" shape as
    /// `FixtureRepository.Error`, and the same shape `ExitClass.swift`
    /// already documents for `.blockedOnConflicts`/`.signingFailed`), and
    /// `RepositoryRegistry.Error` lives in `YardKit`, which has no
    /// dependency on `YardGit` in `Package.swift` and so cannot import
    /// `ExitClassCarrying` at all — `ExitClass.swift`'s own doc comment
    /// already says "YardKit never sees this protocol"; its §6 mapping
    /// happens at M3 wiring time via `ExitCode` conversion, not via this
    /// protocol.
    private let errorTypeAllowList: [String: String] = [
        "FixtureRepository.swift:Error":
            "#0197 — test/diagnostic fixture-builder error, thrown while " +
            "assembling a throwaway DAG for tests; never reaches a real " +
            "command's §6 mapping.",
        "RepositoryIdentity.swift:Error":
            "#0197 — no call site anywhere in Sources yet; not wired to a " +
            "command path, same shape as FixtureRepository.Error above.",
        "RepositoryRegistry.swift:Error":
            "#0197 — declared in YardKit, which does not depend on YardGit " +
            "and cannot import ExitClassCarrying; §6 mapping happens at M3 " +
            "wiring time via ExitCode conversion instead.",
        "RecentOperations.swift:Error":
            "#0150 — declared in YardKit, which does not depend on YardGit " +
            "and cannot import ExitClassCarrying; same shape as " +
            "RepositoryRegistry.Error above, §6 mapping happens at M3 " +
            "wiring time via ExitCode conversion instead.",
        "BrokerConnection.swift:CLIError":
            "#0048 — declared in YardKit, which does not depend on YardGit " +
            "and cannot import ExitClassCarrying; maps directly to ExitCode " +
            "via its own exitCode property, exhaustively switched, same " +
            "shape as RepositoryRegistry.Error above.",
        "AppConnection.swift:AppConnectionError":
            "#0048 — declared in YardKit, which does not depend on YardGit " +
            "and cannot import ExitClassCarrying; maps directly to ExitCode " +
            "via its own exitCode property, exhaustively switched, same " +
            "shape as RepositoryRegistry.Error above.",
    ]

    /// #0197's headline: every declared error type under
    /// `YardKit/Sources/YardGit` and `YardKit/Sources/YardKit` either
    /// conforms to `ExitClassCarrying` or has a recorded allow-list reason —
    /// unlike `everySourceConformerHasARegistryRow` above, this cannot be
    /// fooled by a type that conforms to nothing, because it starts from
    /// every declared error type rather than from `ExitClassCarrying`
    /// conformance sites.
    @Test func everyDeclaredErrorTypeHasAnExitClassOrARecordedReason() throws {
        let declared = try declaredErrorSites()
        try #require(
            !declared.isEmpty,
            "the Error scan found no declared error types at all — the scanner or its path is broken")

        let declaredLabels = Set(declared.map(\.label))
        let conformedLabels = Set(try exitClassConformedSites().map(\.label))
        let allowed = Set(errorTypeAllowList.keys)

        let missing = declaredLabels.subtracting(conformedLabels).subtracting(allowed)
        #expect(
            missing.isEmpty,
            """
            declared error types with no ExitClassCarrying conformance and \
            no recorded allow-list reason: \
            \(missing.sorted().joined(separator: ", ")). Conform via a \
            top-level extension, or add an errorTypeAllowList entry citing \
            an issue.
            """)

        let staleAllowList = allowed.subtracting(declaredLabels)
        #expect(
            staleAllowList.isEmpty,
            """
            errorTypeAllowList entries with no matching declared error type \
            (renamed, removed, or now conforming — drop the entry): \
            \(staleAllowList.sorted().joined(separator: ", "))
            """)

        let contradictions = conformedLabels.intersection(allowed)
        #expect(
            contradictions.isEmpty,
            "both conforming and allow-listed: \(contradictions.sorted().joined(separator: ", "))")
    }
}
