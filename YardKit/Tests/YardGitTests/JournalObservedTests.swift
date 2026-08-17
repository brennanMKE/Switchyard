// JournalObservedTests.swift — observed foreign ref transactions (#0153)
//
// Deliberately NOT @testable: `JournalObserved` is called by the hook layer
// (#0191) as a public caller, so a member silently dropping to internal must
// fail here at compile time (the #0116 failure class).

import Foundation
import Testing
import YardGit

struct JournalObservedTests {

    private static func id(_ suffix: String) throws -> JournalEntryID {
        try #require(JournalEntryID("010000000000000000000000" + suffix))
    }

    /// Writes an ordinary checkpoint entry through the real journal path,
    /// mirroring `JournalListTests`'s helper.
    @discardableResult
    private static func writeCheckpoint(
        _ id: JournalEntryID, in context: WorktreeContext
    ) throws -> JournalAnchor.Entry {
        let metadata = JournalEntryMetadata(
            id: id, operation: "checkpoint",
            timestamp: Date(timeIntervalSince1970: 0),
            worktree: .init(name: nil, path: "/unused-by-these-tests"),
            captured: .refsOnly)
        return try JournalAnchor.write(
            JournalAnchor.Contents(metadataJSON: try metadata.serialized()),
            id: id, in: context)
    }

    /// `JournalAnchor.metadata` reads through the journal namespace only, so
    /// an observed entry's blob is read directly by its own ref name.
    private static func observedMetadataJSON(
        for id: JournalEntryID, in context: WorktreeContext
    ) throws -> Data {
        try GitProcess().run(
            ["cat-file", "blob",
             JournalObserved.refPrefix + id.string + ":" + JournalAnchor.metadataTreeEntryName],
            workingDirectory: context.topLevel ?? context.gitDir
        ).standardOutput
    }

    @Test func anObservedEntryIsInvisibleToTheJournalAndItsListing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let checkpoint = try Self.writeCheckpoint(try Self.id("01"), in: context)
        let observed = try JournalObserved.record(
            [ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: try repo.revParse("HEAD"),
                refName: "refs/heads/main")],
            in: context, now: Date(timeIntervalSince1970: 0))

        let anchored = try JournalAnchor.list(in: context)
        #expect(!anchored.isEmpty)
        #expect(anchored.map(\.id) == [checkpoint.id])
        #expect(!anchored.map(\.id).contains(observed.id))

        let listing = try JournalList.list(in: context)
        #expect(!listing.items.isEmpty)
        #expect(listing.items.map(\.entry.id) == [checkpoint.id])
        #expect(!listing.items.map(\.entry.id).contains(observed.id))
        #expect(listing.items.compactMap(\.defect).isEmpty)
    }

    /// `JournalObserved.Metadata` and `RefUpdate` are `Encodable` only (#0153
    /// pins the wire shape one way), so decoding the written blob back for
    /// assertions goes through a local mirror with the identical keys.
    private struct DecodedRefUpdate: Decodable, Equatable {
        let oldValue: String
        let newValue: String
        let refName: String
    }

    private struct DecodedMetadata: Decodable {
        let schemaVersion: Int
        let updates: [DecodedRefUpdate]
    }

    @Test func observedEntriesRoundTripTheirRefUpdates() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let head = try repo.revParse("HEAD")
        let updates = [
            ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: head, refName: "refs/heads/main"),
            ReferenceTransaction.RefUpdate(
                oldValue: head, newValue: String(repeating: "0", count: 40),
                refName: "refs/heads/stale"),
        ]
        let entry = try JournalObserved.record(
            updates, in: context, now: Date(timeIntervalSince1970: 0))

        let listed = try JournalObserved.list(in: context)
        #expect(!listed.isEmpty)
        #expect(listed.map(\.id) == [entry.id])

        let json = try Self.observedMetadataJSON(for: entry.id, in: context)
        #expect(!json.isEmpty)
        let decoded = try JSONDecoder().decode(DecodedMetadata.self, from: json)
        #expect(!decoded.updates.isEmpty)
        #expect(decoded.updates.count == updates.count)
        #expect(decoded.updates == updates.map {
            DecodedRefUpdate(oldValue: $0.oldValue, newValue: $0.newValue, refName: $0.refName)
        })
    }

    @Test func theObservedNamespaceIsNotTheJournalNamespace() throws {
        #expect(JournalObserved.refPrefix != JournalAnchor.refPrefix)

        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let head = try repo.revParse("HEAD")

        let entry = try JournalObserved.record(
            [ReferenceTransaction.RefUpdate(
                oldValue: String(repeating: "0", count: 40),
                newValue: head, refName: "refs/heads/main")],
            in: context, now: Date(timeIntervalSince1970: 0))

        let refs = try GitProcess().run(
            ["for-each-ref", "--format=%(refname)", "refs/switchyard/**"],
            workingDirectory: context.topLevel ?? context.gitDir).lines
        #expect(!refs.isEmpty)
        let matching = refs.filter { $0.hasSuffix(entry.id.string) }
        #expect(!matching.isEmpty)
        #expect(matching.allSatisfy { $0.hasPrefix(JournalObserved.refPrefix) })
    }

    // MARK: - Foreign rewrite decisions (#0220)

    private static let oidA = "a3317ca3bde3e98bd5c8d097a5e99dd9cb510742"
    private static let oidB = "1db38f7e412aaa4357e0e76acdd212ba8e646517"
    private static let oidC = "5091a0b36200bb1ace0d1ccc310fe128f7e001bf"

    /// Builds a `PostRewrite.Decision` through the real `decide` entry point
    /// rather than a memberwise initializer -- `Decision` has no public
    /// init, by design (#0043), so a foreign caller can only ever construct
    /// one the way the hook does.
    private static func rewriteDecision(
        source: String, isOwn: Bool, pairs: [(oldOid: String, newOid: String)]
    ) -> PostRewrite.Decision {
        let stdin = pairs.map { "\($0.oldOid) \($0.newOid)" }.joined(separator: "\n") + "\n"
        return PostRewrite.decide(
            sourceArgument: source,
            environment: isOwn ? [GitProcess.markerVariable: "1"] : [:],
            readStandardInput: { Data(stdin.utf8) })
    }

    private struct DecodedRewrite: Decodable, Equatable {
        let oldOid: String
        let newOid: String
    }

    private struct DecodedRewriteMetadata: Decodable {
        let schemaVersion: Int
        let kind: String
        let source: String
        let rewrites: [DecodedRewrite]
    }

    @Test func aForeignRewriteDecisionIsRecordedWithKindSourceAndOrderedRewrites() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let decision = Self.rewriteDecision(
            source: "rebase", isOwn: false,
            pairs: [(Self.oidA, Self.oidB), (Self.oidB, Self.oidC)])

        let entry = try JournalObserved.record(
            decision, in: context, now: Date(timeIntervalSince1970: 0))
        let recorded = try #require(entry)

        let listed = try JournalObserved.list(in: context)
        #expect(!listed.isEmpty)
        #expect(listed.map(\.id) == [recorded.id])

        let json = try Self.observedMetadataJSON(for: recorded.id, in: context)
        #expect(!json.isEmpty)
        let decoded = try JSONDecoder().decode(DecodedRewriteMetadata.self, from: json)
        #expect(decoded.schemaVersion == JournalObserved.Metadata.currentSchemaVersion)
        #expect(decoded.kind == "rewrites")
        #expect(decoded.source == "rebase")
        #expect(!decoded.rewrites.isEmpty)
        #expect(decoded.rewrites == [
            DecodedRewrite(oldOid: Self.oidA, newOid: Self.oidB),
            DecodedRewrite(oldOid: Self.oidB, newOid: Self.oidC),
        ], "order is part of the contract -- a rebase's mapping is a sequence, not a set")
    }

    /// #0221's boundary: this issue only ever persists a foreign decision.
    /// An own invocation writes nothing here, so once #0221 lands, the two
    /// halves cannot both record the same rewrite.
    @Test func anOwnInvocationDecisionWritesNothing() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let decision = Self.rewriteDecision(
            source: "amend", isOwn: true, pairs: [(Self.oidA, Self.oidB)])
        #expect(decision.isOwnInvocation)

        let entry = try JournalObserved.record(decision, in: context)
        #expect(entry == nil,
                "an own invocation's mapping is #0221's to attach, not this function's to record")
        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    /// Mid-rebase dedup, at the unit level: a rebase-merge directory at the
    /// resolved git-path (never a path built by string concatenation onto
    /// ".git/") is git's own signal that a rebase is in progress, and an
    /// `amend` invocation seen during one must not produce its own entry --
    /// the rebase's own final invocation repeats the pair (measured, #0043's
    /// Givens; see `rebaseMergeExistsDuringAMidRebaseAmendButNotAPlainAmend`
    /// below for the real, end-to-end measurement).
    @Test func aMidRebaseAmendDoesNotProduceItsOwnObservedEntry() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let rebaseMergePath = try context.path(for: "rebase-merge")
        try FileManager.default.createDirectory(
            atPath: rebaseMergePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let decision = Self.rewriteDecision(
            source: "amend", isOwn: false, pairs: [(Self.oidA, Self.oidB)])

        let entry = try JournalObserved.record(decision, in: context)
        #expect(entry == nil, "a mid-rebase amend must not produce its own observed entry")
        #expect(try JournalObserved.list(in: context).isEmpty)
    }

    /// The dedup gates on `source == .amend` only: measured (#0043's
    /// Givens), even the FINAL `rebase`-sourced invocation can still see
    /// rebase-merge on disk before cleanup, and that invocation is the
    /// authoritative one -- it must never be skipped.
    @Test func aFinalRebaseInvocationIsRecordedEvenWhileRebaseMergeStillExists() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let rebaseMergePath = try context.path(for: "rebase-merge")
        try FileManager.default.createDirectory(
            atPath: rebaseMergePath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rebaseMergePath) }

        let decision = Self.rewriteDecision(
            source: "rebase", isOwn: false, pairs: [(Self.oidA, Self.oidB)])

        let entry = try JournalObserved.record(decision, in: context)
        #expect(entry != nil, "the authoritative rebase invocation must still be recorded")
    }

    /// The totality invariant (#0043): a persistence failure never surfaces
    /// as a non-zero hook exit. `record` propagates the failure -- a caller
    /// in the hook path swallows it, exactly as `ReferenceTransaction.runHook`
    /// already does for the ref-update `record` (#0191) -- and `decision`,
    /// already total by construction, is unaffected either way.
    @Test func aPersistenceFailurePropagatesWithoutChangingTheDecisionsExitCode() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let context = try WorktreeContext.resolve(path: repo.url.path)

        let decision = Self.rewriteDecision(
            source: "rebase", isOwn: false, pairs: [(Self.oidA, Self.oidB)])
        #expect(decision.exitCode == 0)

        let failingGit = GitProcess(executablePath: "/usr/bin/false")
        #expect(throws: (any Error).self) {
            try JournalObserved.record(decision, in: context, git: failingGit)
        }
        #expect(decision.exitCode == 0,
                "a persistence failure must never surface as a non-zero hook exit")
    }

    // MARK: - The real contract: rebase-merge's existence, measured

    private static func installRebaseMergeProbeHook(
        in repo: FixtureRepository, loggingTo log: URL
    ) throws {
        let context = try WorktreeContext.resolve(path: repo.url.path)
        let hooksDir = try context.path(for: "hooks")
        try FileManager.default.createDirectory(
            atPath: hooksDir, withIntermediateDirectories: true)
        let hookPath = hooksDir + "/post-rewrite"
        let script = """
        #!/bin/sh
        p=$(git rev-parse --path-format=absolute --git-path rebase-merge)
        if [ -e "$p" ]; then state=EXISTS; else state=ABSENT; fi
        printf '=I= %s %s\\n' "$1" "$state" >> "\(log.path)"
        cat > /dev/null
        exit 0
        """
        try script.write(toFile: hookPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hookPath)
    }

    private struct RebaseMergeProbe: Equatable {
        let source: String
        let rebaseMergeExisted: Bool
    }

    private static func rebaseMergeProbes(in log: URL) -> [RebaseMergeProbe] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard line.hasPrefix("=I= ") else { return nil }
            let fields = line.dropFirst(4).split(separator: " ")
            guard fields.count == 2 else { return nil }
            return RebaseMergeProbe(
                source: String(fields[0]), rebaseMergeExisted: fields[1] == "EXISTS")
        }
    }

    /// Measures, against real `git` subprocesses and a real `post-rewrite`
    /// hook, the discriminator the mid-rebase skip depends on: a plain
    /// `commit --amend` reports no rebase-merge on disk; an `amend` fired
    /// while an interactive rebase is paused (the same sequencer state a
    /// squash/fixup step's internal amend runs inside, per #0043's Givens)
    /// reports one. Paused via an `edit` stop rather than reproducing a
    /// literal `fixup!` -- the property under test is the git-exposed
    /// on-disk state, not the specific rebase step that produces it.
    @Test func rebaseMergeExistsDuringAMidRebaseAmendButNotAPlainAmend() throws {
        // Plain amend: no rebase in progress.
        var plain = try FixtureRepository()
        defer { plain.destroy() }
        try plain.build([.init("a")])
        let plainLog = plain.url.appendingPathComponent("post-rewrite.log")
        try Self.installRebaseMergeProbeHook(in: plain, loggingTo: plainLog)
        try GitProcess().run(
            ["commit", "--amend", "-q", "-m", "amended"], workingDirectory: plain.url.path)

        let plainProbes = Self.rebaseMergeProbes(in: plainLog)
        try #require(plainProbes.count == 1)
        #expect(plainProbes[0].source == "amend")
        #expect(!plainProbes[0].rebaseMergeExisted,
                "a plain amend must report no rebase in progress")

        // Mid-rebase amend: an interactive rebase paused on "edit" leaves
        // the sequencer's rebase-merge state on disk exactly as a
        // squash/fixup step's internal amend would see it.
        var mid = try FixtureRepository()
        defer { mid.destroy() }
        try mid.build([.init("base")])
        try mid.build([.init("a", parents: ["base"])])
        try mid.branch("feature", at: "a")
        try mid.build([.init("m", parents: ["base"])])
        try mid.branch("main", at: "m")
        try mid.checkout("feature")

        try GitProcess().run(
            ["rebase", "-i", "-q", "main"],
            workingDirectory: mid.url.path,
            extraEnvironment: [
                "GIT_SEQUENCE_EDITOR": "sed -i '' -e '1s/^pick/edit/'",
                "GIT_EDITOR": "true",
            ])

        let midLog = mid.url.appendingPathComponent("post-rewrite.log")
        try Self.installRebaseMergeProbeHook(in: mid, loggingTo: midLog)
        try GitProcess().run(
            ["commit", "--amend", "-q", "--allow-empty", "-m", "amended-mid-rebase"],
            workingDirectory: mid.url.path)

        let midProbes = Self.rebaseMergeProbes(in: midLog)
        try #require(midProbes.count == 1)
        #expect(midProbes[0].source == "amend")
        #expect(midProbes[0].rebaseMergeExisted,
                "the discriminator the mid-rebase skip depends on, measured against a real paused rebase")
    }
}
