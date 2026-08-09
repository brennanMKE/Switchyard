// JournalCheckpointPartialFailureTests.swift — a checkpoint failing at the
// anchor create leaves nothing discoverable (#0177)
//
// Deliberately NOT @testable: the failure is driven through the same public
// `checkpoint` call every restore-class flow makes — the #0116 failure class.

import Foundation
import Testing
import YardGit

struct JournalCheckpointPartialFailureTests {

    private let git = GitProcess()

    private func exists(_ oid: String, in repo: FixtureRepository) throws -> Bool {
        try git.capture(["cat-file", "-e", oid], workingDirectory: repo.url.path).exitCode == 0
    }

    /// #0167 decision 5, exercised instead of argued: drive a real checkpoint
    /// to fail *after* every object is written and *at* the anchor-ref create,
    /// then prove the half-entry is invisible — not listed, not rebuilt, not
    /// even a defect — and that what was written is unreachable.
    ///
    /// Injection: the loose-ref directory the anchor create must take its ref
    /// lock in is made unwritable. Everything earlier in the flow still works
    /// — capture and list only *read* refs, and objects land under `objects/`
    /// — so the flow runs whole and dies at exactly the commit point, proven
    /// by the thrown failure naming `update-ref`.
    ///
    /// Single format on purpose: the injection is files-backend mechanics (a
    /// per-ref lock file in the refs directory). The property it witnesses is
    /// the write *order* in `JournalCheckpoint`/`JournalAnchor` — the same
    /// code on either backend.
    @Test func aCheckpointFailingAtTheAnchorCreateLeavesNothingDiscoverable() throws {
        let repo = try FixtureRepository.linear(refFormat: .files)
        defer { repo.destroy() }
        let ctx = try WorktreeContext.resolve(path: repo.url.path)

        // A pre-existing entry, so "nothing new appears" is asserted against
        // a journal that visibly works, not against emptiness. Its future
        // timestamp also pins the doomed checkpoint's id to future+1 — and
        // seeding it creates the loose-ref directory the injection needs.
        let future = JournalEntryID.generate(now: Date(timeIntervalSince1970: 4_000_000_000))
        let seeded = try JournalAnchor.write(
            .init(metadataJSON: Data("stub".utf8)), id: future, in: ctx)

        // The blob the checkpoint will write for the current ref state,
        // computed WITHOUT writing (`hash-object` without `-w`). Anchor refs
        // live in the namespace RefSnapshot excludes, so the seed does not
        // perturb this oid.
        let refsBlob = try #require(try git.run(
            ["hash-object", "--stdin"], workingDirectory: repo.url.path,
            standardInput: RefSnapshot.capture(in: ctx).serialized()).lines.first)
        try #require(try !exists(refsBlob, in: repo))  // vacuity guard on the oid

        // No unreachable objects yet: the fsck delta below is this test's.
        let baseline = try git.run(["fsck", "--unreachable", "--no-progress"],
                                   workingDirectory: repo.url.path)
        try #require(baseline.lines.isEmpty)

        // The injection. The directory is resolved through git, never built
        // by string concatenation, and only its permission bits are touched —
        // nothing under $GIT_DIR is read as state.
        let journalRefDir = try #require(try git.run(
            ["rev-parse", "--path-format=absolute", "--git-path", "refs/switchyard/journal"],
            workingDirectory: repo.url.path).lines.first)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: journalRefDir)
        defer {  // LIFO: restores before repo.destroy() runs
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: journalRefDir)
        }

        // The whole flow runs and dies at exactly the anchor create: the
        // thrown failure names update-ref — not capture, not hash-object,
        // not commit-tree.
        let failure = try #require(throws: GitProcess.Failure.self) {
            try JournalCheckpoint.checkpoint(operation: "doomed", in: ctx)
        }
        guard case let .exited(code, stderr, arguments) = failure else {
            Issue.record("checkpoint did not reach git at all: \(failure)")
            return
        }
        #expect(code == 128)
        #expect(arguments.first == "update-ref")
        #expect(stderr.contains("cannot lock ref"))

        // The window is proven, not assumed: every object before the commit
        // point exists — the refs blob, and a snapshot commit whose tree
        // carries it under the wire name — and every one is unreachable.
        // Reachability is asserted directly; nothing here runs `git gc`.
        #expect(try exists(refsBlob, in: repo))
        let unreachable = try git.run(["fsck", "--unreachable", "--no-progress"],
                                      workingDirectory: repo.url.path)
        let orphanCommits = unreachable.lines.filter { $0.hasPrefix("unreachable commit ") }
        #expect(orphanCommits.count == 1)
        #expect(unreachable.lines.contains("unreachable blob \(refsBlob)"))
        let orphan = try #require(orphanCommits.first?.split(separator: " ").last.map(String.init))
        let tree = try git.run(["ls-tree", orphan], workingDirectory: repo.url.path)
        #expect(tree.lines.contains("100644 blob \(refsBlob)\t\(JournalAnchor.refsTreeEntryName)"))

        // And nothing discovers it: not the listing, and not a rebuild —
        // no entry, and no defect either. A half-written checkpoint is
        // invisible, not merely broken.
        #expect(try JournalAnchor.list(in: ctx) == [seeded])
        let rebuilt = try JournalRebuild.rebuild(in: ctx)
        #expect(rebuilt.entries.map(\.id) == [future])
        #expect(rebuilt.defects.isEmpty)
    }
}
