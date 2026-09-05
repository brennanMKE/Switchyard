// ResolveApplyTests.swift — the engine apply half, per resolution kind,
// against real fixture conflicts (#0057)
//
// Every kind the porcelain can produce is built with the fixture API: a
// content conflict (`UU`), add/add (`AA`), delete/modify both directions
// (`DU`/`UD`), and rename/rename(1to2) — which surfaces as three records:
// `DD` at the old path, `AU` at ours' new path, `UA` at theirs' new path.
// The assertions read the INDEX, not the worktree alone: after an apply the
// path's stage-0 blob must carry exactly the chosen side's content.

import Foundation
import Testing
@testable import YardGit

@Suite("ResolveApply")
struct ResolveApplyTests {

    // MARK: - Fixture helpers

    /// One side's changes relative to the base commit: files written, files
    /// deleted. Deletions need REAL worktree removals — `git rm`, not "the
    /// file is absent from the writes map" — because a side whose only other
    /// change is a lone addition lets git's rename detection pair the
    /// deletion with the addition and auto-resolve what should conflict
    /// (measured, git 2.50.1: even an empty added file pairs).
    private struct Side {
        var writes: [String: String] = [:]
        var deletes: [String] = []

        init(writes: [String: String] = [:], deletes: [String] = []) {
            self.writes = writes
            self.deletes = deletes
        }
    }

    /// Builds base → ours / theirs commits (children of base), checks out
    /// ours, and merges theirs without committing — the conflict shape
    /// `FixtureRepository.conflicted` builds, parameterised over the sides
    /// so every kind the fixture API can produce is reachable.
    private func conflictedFixture(
        refFormat: FixtureRepository.RefFormat,
        base: [String: String],
        ours: Side,
        theirs: Side
    ) throws -> FixtureRepository {
        let git = GitProcess()
        var repo = try FixtureRepository(refFormat: refFormat)
        try repo.build([.init("base", files: base)])
        let baseOID = try #require(repo.oids["base"])

        func commitSide(_ name: String, _ side: Side) throws -> String {
            try repo.checkoutDetached(baseOID)
            for path in side.deletes {
                try git.run(["rm", "-q", "--", path], workingDirectory: repo.url.path)
            }
            for (path, contents) in side.writes {
                let file = repo.url.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
            try git.run(["add", "-A"], workingDirectory: repo.url.path)
            try git.run(["commit", "-q", "-m", name], workingDirectory: repo.url.path)
            return try git.run(["rev-parse", "HEAD"], workingDirectory: repo.url.path).lines[0]
        }

        let oursOID = try commitSide("ours", ours)
        let theirsOID = try commitSide("theirs", theirs)
        try repo.checkoutDetached(oursOID)
        _ = try? git.run(["merge", "--no-commit", theirsOID], workingDirectory: repo.url.path)
        return repo
    }

    private func conflictedFile(
        _ path: String, in repo: FixtureRepository
    ) throws -> ConflictedFile {
        let files = try conflictedFiles(at: repo.url.path)
        return try #require(
            files.first(where: { $0.path == path }),
            "\(path) must be conflicted before the apply; got \(files.map(\.path))")
    }

    private func assertResolved(_ path: String, in repo: FixtureRepository) throws {
        let files = try conflictedFiles(at: repo.url.path)
        #expect(!files.contains { $0.path == path },
                "\(path) must have no unmerged entries after the apply; got \(files.map(\.path))")
    }

    /// The staged (stage-0) content of a resolved path — the record the
    /// apply is responsible for.
    private func stagedContent(_ path: String, in repo: FixtureRepository) throws -> String {
        let out = try GitProcess().run(
            ["cat-file", "blob", ":\(path)"], workingDirectory: repo.url.path)
        return String(decoding: out.standardOutput, as: UTF8.self)
    }

    private func workingContent(_ path: String, in repo: FixtureRepository) throws -> String {
        String(decoding: try Data(contentsOf: repo.url.appendingPathComponent(path)), as: UTF8.self)
    }

    private func journalEntryCount(in repo: FixtureRepository) throws -> Int {
        let context = try WorktreeContext.resolve(path: repo.url.path)
        return try JournalAnchor.list(in: context).count
    }

    private func journalOperations(in repo: FixtureRepository) throws -> [String] {
        let context = try WorktreeContext.resolve(path: repo.url.path)
        return try JournalAnchor.list(in: context).map { entry in
            try JournalEntryMetadata(
                serialized: JournalAnchor.metadata(for: entry.id, in: context)).operation
        }
    }

    // MARK: - Content conflicts (UU)

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func useOursWritesOursStageContentStagesThePathAndCheckpoints(
        refFormat: FixtureRepository.RefFormat
    ) throws {
        let repo = try conflictedFixture(
            refFormat: refFormat,
            base: ["f.txt": "original\n"],
            ours: Side(writes: ["f.txt": "ours\n"]),
            theirs: Side(writes: ["f.txt": "theirs\n"]))
        defer { repo.destroy() }
        #expect(try conflictedFile("f.txt", in: repo).kind == .bothModified)

        try ResolveApply.apply(resolution: .useOurs, path: "f.txt", at: repo.url.path)

        try assertResolved("f.txt", in: repo)
        #expect(try stagedContent("f.txt", in: repo) == "ours\n",
                "the staged blob must carry ours' content")
        #expect(try workingContent("f.txt", in: repo) == "ours\n",
                "the working file must carry the chosen content")
        #expect(try journalOperations(in: repo).contains("resolve"),
                "the apply must write its checkpoint entry")
    }

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func useTheirsWritesTheirsStageContentAndStagesThePath(
        refFormat: FixtureRepository.RefFormat
    ) throws {
        let repo = try conflictedFixture(
            refFormat: refFormat,
            base: ["f.txt": "original\n"],
            ours: Side(writes: ["f.txt": "ours\n"]),
            theirs: Side(writes: ["f.txt": "theirs\n"]))
        defer { repo.destroy() }

        try ResolveApply.apply(resolution: .useTheirs, path: "f.txt", at: repo.url.path)

        try assertResolved("f.txt", in: repo)
        #expect(try stagedContent("f.txt", in: repo) == "theirs\n",
                "the staged blob must carry theirs' content")
    }

    @Test func editedContentWritesTheHumanTextAndStagesIt() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "original\n"],
            ours: Side(writes: ["f.txt": "ours\n"]),
            theirs: Side(writes: ["f.txt": "theirs\n"]))
        defer { repo.destroy() }

        try ResolveApply.apply(
            resolution: .editedContent("merged by hand\n"), path: "f.txt", at: repo.url.path)

        try assertResolved("f.txt", in: repo)
        #expect(try stagedContent("f.txt", in: repo) == "merged by hand\n")
        #expect(try workingContent("f.txt", in: repo) == "merged by hand\n")
    }

    /// The non-checkpointing primitive writes NO journal entry — the
    /// composition rule (#0212): a caller that wraps several applies in one
    /// `around` of its own must not find stray entries.
    @Test func applyWithoutCheckpointStagesWithoutAJournalEntry() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "original\n"],
            ours: Side(writes: ["f.txt": "ours\n"]),
            theirs: Side(writes: ["f.txt": "theirs\n"]))
        defer { repo.destroy() }
        let before = try journalEntryCount(in: repo)

        try ResolveApply.applyWithoutCheckpoint(
            resolution: .useOurs, path: "f.txt", at: repo.url.path, git: GitProcess())

        try assertResolved("f.txt", in: repo)
        #expect(try stagedContent("f.txt", in: repo) == "ours\n")
        #expect(try journalEntryCount(in: repo) == before,
                "the non-checkpointing primitive must not write an entry")
    }

    // MARK: - Add/add (AA)

    @Test func addAddUseOursStagesOursContentWithNoBasePresent() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["b.txt": "unrelated\n"],
            ours: Side(writes: ["n.txt": "ours\n"]),
            theirs: Side(writes: ["n.txt": "theirs\n"]))
        defer { repo.destroy() }
        let entry = try conflictedFile("n.txt", in: repo)
        #expect(entry.kind == .bothAdded)
        #expect(entry.base == nil, "an add/add conflict has no base stage")

        try ResolveApply.apply(resolution: .useOurs, path: "n.txt", at: repo.url.path)

        try assertResolved("n.txt", in: repo)
        #expect(try stagedContent("n.txt", in: repo) == "ours\n")
    }

    @Test func addAddUseTheirsStagesTheirsContent() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["b.txt": "unrelated\n"],
            ours: Side(writes: ["n.txt": "ours\n"]),
            theirs: Side(writes: ["n.txt": "theirs\n"]))
        defer { repo.destroy() }

        try ResolveApply.apply(resolution: .useTheirs, path: "n.txt", at: repo.url.path)

        try assertResolved("n.txt", in: repo)
        #expect(try stagedContent("n.txt", in: repo) == "theirs\n")
    }

    // MARK: - Delete/modify (DU and UD)

    /// `DU` — deleted by us: ours has no stage, theirs' content is the
    /// surviving side and sits in the worktree. Keeping the modification
    /// stages theirs' blob content.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func keepModificationOnDeletedByUsStagesTheirs(refFormat: FixtureRepository.RefFormat) throws {
        let repo = try conflictedFixture(
            refFormat: refFormat,
            base: ["f.txt": "base\n"],
            ours: Side(deletes: ["f.txt"]),
            theirs: Side(writes: ["f.txt": "theirs-mod\n"]))
        defer { repo.destroy() }
        let entry = try conflictedFile("f.txt", in: repo)
        #expect(entry.kind == .deletedByUs)
        #expect(entry.ours == nil)

        try ResolveApply.apply(resolution: .keepModification, path: "f.txt", at: repo.url.path)

        try assertResolved("f.txt", in: repo)
        #expect(try stagedContent("f.txt", in: repo) == "theirs-mod\n")
    }

    /// `UD` — deleted by them: theirs has no stage, ours' content survives.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func keepModificationOnDeletedByThemStagesOurs(refFormat: FixtureRepository.RefFormat) throws {
        let repo = try conflictedFixture(
            refFormat: refFormat,
            base: ["f.txt": "base\n"],
            ours: Side(writes: ["f.txt": "ours-mod\n"]),
            theirs: Side(deletes: ["f.txt"]))
        defer { repo.destroy() }
        let entry = try conflictedFile("f.txt", in: repo)
        #expect(entry.kind == .deletedByThem)
        #expect(entry.theirs == nil)

        try ResolveApply.apply(resolution: .keepModification, path: "f.txt", at: repo.url.path)

        try assertResolved("f.txt", in: repo)
        #expect(try stagedContent("f.txt", in: repo) == "ours-mod\n")
    }

    /// Keeping the deletion on `DU`: the working file exists (theirs'
    /// content was checked out), so the apply must remove it and stage the
    /// deletion — the path leaves the index entirely.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func keepDeletionRemovesTheWorkingFileAndStagesTheDeletion(
        refFormat: FixtureRepository.RefFormat
    ) throws {
        let repo = try conflictedFixture(
            refFormat: refFormat,
            base: ["f.txt": "base\n"],
            ours: Side(deletes: ["f.txt"]),
            theirs: Side(writes: ["f.txt": "theirs-mod\n"]))
        defer { repo.destroy() }
        #expect(try conflictedFile("f.txt", in: repo).kind == .deletedByUs)
        #expect(FileManager.default.fileExists(
                    atPath: repo.url.appendingPathComponent("f.txt").path),
                "precondition: the surviving side's content is in the worktree")

        try ResolveApply.apply(resolution: .keepDeletion, path: "f.txt", at: repo.url.path)

        try assertResolved("f.txt", in: repo)
        #expect(!FileManager.default.fileExists(
                    atPath: repo.url.appendingPathComponent("f.txt").path),
                "the working file must be gone")
        let listing = try GitProcess().run(
            ["ls-files", "--", "f.txt"], workingDirectory: repo.url.path)
        #expect(listing.lines.isEmpty, "the deletion must be staged — no index entry remains")
    }

    /// `DD` — both deleted (the old path of a rename group): the working
    /// file is already gone and `keepDeletion` records the deletion,
    /// clearing the stage-1-only entry.
    @Test func keepDeletionResolvesABothDeletedRecord() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "base\n"],
            ours: Side(writes: ["g.txt": "base\n"], deletes: ["f.txt"]),
            theirs: Side(writes: ["h.txt": "base\n"], deletes: ["f.txt"]))
        defer { repo.destroy() }
        let entry = try conflictedFile("f.txt", in: repo)
        #expect(entry.kind == .bothDeleted)
        #expect(entry.ours == nil && entry.theirs == nil)

        try ResolveApply.apply(resolution: .keepDeletion, path: "f.txt", at: repo.url.path)

        try assertResolved("f.txt", in: repo)
    }

    // MARK: - Rename conflicts

    /// rename/rename(1to2) — the porcelain records the design's rename card
    /// covers. Taking ours' path+content stages ours' new path (`AU`, whose
    /// ours stage carries ours' content); the rejected side's new path and
    /// the old path resolve as their own keep-deletion cards.
    @Test func renameTakeOursStagesOursNewPathAndTheRestResolvesAsDeletions() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "base\n"],
            ours: Side(writes: ["g.txt": "base\n"], deletes: ["f.txt"]),
            theirs: Side(writes: ["h.txt": "base\n"], deletes: ["f.txt"]))
        defer { repo.destroy() }
        let oursRecord = try conflictedFile("g.txt", in: repo)
        #expect(oursRecord.kind == .addedByUs, "ours' renamed path surfaces as AU")
        _ = try conflictedFile("h.txt", in: repo)   // theirs', UA
        _ = try conflictedFile("f.txt", in: repo)   // the old path, DD

        try ResolveApply.apply(resolution: .renameTakeOurs, path: "g.txt", at: repo.url.path)
        try assertResolved("g.txt", in: repo)
        #expect(try stagedContent("g.txt", in: repo) == "base\n",
                "ours' path carries ours' content")

        try ResolveApply.apply(resolution: .keepDeletion, path: "h.txt", at: repo.url.path)
        try assertResolved("h.txt", in: repo)
        try ResolveApply.apply(resolution: .keepDeletion, path: "f.txt", at: repo.url.path)
        try assertResolved("f.txt", in: repo)

        let remaining = try conflictedFiles(at: repo.url.path)
        #expect(remaining.isEmpty, "the whole rename group is resolved; got \(remaining.map(\.path))")
    }

    /// Taking theirs' path+content is the symmetric apply on theirs' `UA`
    /// record.
    @Test func renameTakeTheirsStagesTheirsNewPath() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "base\n"],
            ours: Side(writes: ["g.txt": "base\n"], deletes: ["f.txt"]),
            theirs: Side(writes: ["h.txt": "base\n"], deletes: ["f.txt"]))
        defer { repo.destroy() }
        let theirsRecord = try conflictedFile("h.txt", in: repo)
        #expect(theirsRecord.kind == .addedByThem, "theirs' renamed path surfaces as UA")

        try ResolveApply.apply(resolution: .renameTakeTheirs, path: "h.txt", at: repo.url.path)
        try assertResolved("h.txt", in: repo)
        #expect(try stagedContent("h.txt", in: repo) == "base\n",
                "theirs' path carries theirs' content")
    }

    // MARK: - Refusals

    /// A path whose porcelain record does not carry the side the resolution
    /// names is refused by name — nothing is staged.
    @Test func useOursOnARecordWithoutAnOursStageThrows() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "base\n"],
            ours: Side(writes: ["g.txt": "base\n"], deletes: ["f.txt"]),
            theirs: Side(writes: ["h.txt": "base\n"], deletes: ["f.txt"]))
        defer { repo.destroy() }

        #expect(throws: ResolveApplyError.stageAbsent(path: "h.txt", side: "ours")) {
            try ResolveApply.apply(resolution: .useOurs, path: "h.txt", at: repo.url.path)
        }
        #expect(try !conflictedFiles(at: repo.url.path).isEmpty,
                "the refusal must leave the conflict untouched")
    }

    /// An already-resolved (or never-conflicted) path is refused, not
    /// staged: the lookup is what keeps a stale double-press from staging
    /// something the human never saw.
    @Test func applyOnANonConflictedPathThrows() throws {
        let repo = try FixtureRepository.linear()
        defer { repo.destroy() }

        #expect(throws: ResolveApplyError.pathNotConflicted(path: "nope.txt")) {
            try ResolveApply.apply(resolution: .useOurs, path: "nope.txt", at: repo.url.path)
        }
    }

    /// `keepModification` on a `DD` record has no surviving side to keep —
    /// refused by name; the resolution there is `keepDeletion`.
    @Test func keepModificationWithoutASurvivingSideThrows() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "base\n"],
            ours: Side(writes: ["g.txt": "base\n"], deletes: ["f.txt"]),
            theirs: Side(writes: ["h.txt": "base\n"], deletes: ["f.txt"]))
        defer { repo.destroy() }

        #expect(throws: ResolveApplyError.bothStagesAbsent(path: "f.txt")) {
            try ResolveApply.apply(resolution: .keepModification, path: "f.txt", at: repo.url.path)
        }
    }

    // MARK: - The blob read the serving body shares

    @Test func readBlobReturnsTheExactObjectBytes() throws {
        let repo = try conflictedFixture(
            refFormat: .files,
            base: ["f.txt": "original\n"],
            ours: Side(writes: ["f.txt": "ours\n"]),
            theirs: Side(writes: ["f.txt": "theirs\n"]))
        defer { repo.destroy() }
        let entry = try conflictedFile("f.txt", in: repo)
        let oursStage = try #require(entry.ours)

        let data = try ResolveApply.readBlob(oid: oursStage.oid, at: repo.url.path)
        #expect(String(decoding: data, as: UTF8.self) == "ours\n")
    }
}
