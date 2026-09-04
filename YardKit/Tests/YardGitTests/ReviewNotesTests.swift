// ReviewNotesTests.swift — review decisions as git notes (#0059)
//
// The criterion the issue pins: attaching a note never changes a commit SHA.
// Everything else follows from byte fidelity (--no-stripspace storage, stdin
// carriage) and namespace isolation (never refs/notes/commits, never visible
// to the ordinary ref enumeration).

import Foundation
import Testing
import YardGit

@Suite("ReviewNotes (#0059)")
struct ReviewNotesTests {

    /// The decision body a test records — the ReviewReply JSON shape, with the
    /// characters JSON quoting has to survive: non-ASCII, quotes, braces.
    private static let decisionBody =
        #"{"comments":[{"hunkID":"@@ -1 +1 @@","path":"a.txt","text":"café \"nice\" {brace}"}],"decision":"approve","message":"looks good — café"}"#

    // MARK: - The criterion: SHA preservation

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func recordAttachesNoteWithoutChangingTheCommitSHA(format: FixtureRepository.RefFormat) async throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])
        let headBefore = try repo.revParse("HEAD")

        try await ReviewNotes.record(
            body: Self.decisionBody, forCommitOID: headBefore, at: repo.url.path)

        let headAfter = try repo.revParse("HEAD")
        #expect(headAfter == headBefore,
                "attaching a note must never change the commit SHA")
        let body = try #require(
            await ReviewNotes.noteBody(forCommitOID: headBefore, at: repo.url.path),
            "the note must be readable back under the dedicated namespace")
        // Byte identity, not string identity: U+FFFD or a stripped trailing
        // newline must fail here unambiguously.
        #expect(Data(body.utf8) == Data(Self.decisionBody.utf8),
                "the note must read back byte-identical, got \(body)")
    }

    // MARK: - list

    @Test(arguments: FixtureRepository.RefFormat.supported())
    func listReturnsEachDecisionForItsRightCommit(format: FixtureRepository.RefFormat) async throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])
        let oidA = try #require(repo.oids["a"])
        let oidB = try #require(repo.oids["b"])
        let bodyA = #"{"decision":"approve","message":"first"}"#
        let bodyB = #"{"decision":"reject","message":"second"}"#
        try await ReviewNotes.record(body: bodyA, forCommitOID: oidA, at: repo.url.path)
        try await ReviewNotes.record(body: bodyB, forCommitOID: oidB, at: repo.url.path)

        let notes = try await ReviewNotes.list(at: repo.url.path)
        #expect(notes.count == 2, "both decisions must be listed, got \(notes)")
        let noteA = try #require(notes.first(where: { $0.oid == oidA }),
                                 "the decision for commit a must carry commit a's oid")
        let noteB = try #require(notes.first(where: { $0.oid == oidB }),
                                 "the decision for commit b must carry commit b's oid")
        #expect(Data(noteA.body.utf8) == Data(bodyA.utf8))
        #expect(Data(noteB.body.utf8) == Data(bodyB.utf8))
    }

    /// `record` passes `-f`: a re-review of the same commit replaces the
    /// recorded decision, latest wins — one note per commit, the newest body.
    @Test func rerecordingReplacesTheDecisionLatestWins() async throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let oid = try #require(repo.oids["c"])
        let first = #"{"decision":"approve"}"#
        let second = #"{"decision":"amend","message":"try again"}"#
        try await ReviewNotes.record(body: first, forCommitOID: oid, at: repo.url.path)
        try await ReviewNotes.record(body: second, forCommitOID: oid, at: repo.url.path)

        let notes = try await ReviewNotes.list(at: repo.url.path)
        #expect(notes.count == 1, "one note per commit: the latest decision replaces the first")
        #expect(notes.first?.oid == oid)
        #expect(notes.first?.body == second)
    }

    // MARK: - Namespace exclusion

    /// A review note never appears in `yard`'s ordinary ref enumeration: not
    /// in a ref snapshot's captured refs, not in the graph. The premise is
    /// asserted first — the note must exist under the dedicated namespace —
    /// so the exclusions cannot pass vacuously.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func reviewNoteNeverAppearsInOrdinaryRefEnumeration(format: FixtureRepository.RefFormat) async throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])
        let head = try repo.revParse("HEAD")

        try await ReviewNotes.record(
            body: Self.decisionBody, forCommitOID: head, at: repo.url.path)

        // Premise: the note exists, under the dedicated namespace — recorded
        // anywhere else and every exclusion below would be vacuous.
        let notes = try await ReviewNotes.list(at: repo.url.path)
        let listed = try #require(notes.first(where: { $0.oid == head }),
                                  "the note must be listed under \(ReviewNotes.refNamespace)")
        #expect(Data(listed.body.utf8) == Data(Self.decisionBody.utf8))
        let notesCommit = try repo.revParse(ReviewNotes.refNamespace)

        // Ref enumeration: the namespace ref is never captured.
        let context = try await WorktreeContext.resolve(path: repo.url.path)
        let snapshot = try await RefSnapshot.capture(in: context)
        #expect(!snapshot.refs.contains(where: { $0.name.hasPrefix(ReviewNotes.refNamespace) }),
                "the review-notes ref must never appear in the captured ref list, got \(snapshot.refs.map(\.name))")

        // The graph: `--all` really does traverse notes refs (measured on git
        // 2.50.1), so the notes ref's own commit would surface as a row that
        // is not a commit of the repository's history. It must not.
        let rows = try await graphRows(at: repo.url.path, revisions: ["--all"])
        #expect(!rows.contains(where: { $0.oid == notesCommit }),
                "the notes ref's commit must never appear in the graph")
        let knownOIDs = Set(repo.oids.values)
        #expect(rows.allSatisfy { knownOIDs.contains($0.oid) },
                "every graph row must be a real commit of the fixture, got \(rows.map(\.oid))")
    }

    // MARK: - CommitLog surfacing

    /// `yard log`'s entry carries the note when the commit has one (byte
    /// identical) and omits it when it does not.
    @Test(arguments: FixtureRepository.RefFormat.supported())
    func commitLogCarriesTheNoteWhenPresentAndOmitsItWhenAbsent(format: FixtureRepository.RefFormat) async throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }
        try repo.build([FixtureRepository.Commit("a"), FixtureRepository.Commit("b")])
        let oidA = try #require(repo.oids["a"])
        let oidB = try #require(repo.oids["b"])
        try await ReviewNotes.record(
            body: Self.decisionBody, forCommitOID: oidB, at: repo.url.path)

        let entries = try await CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries.count == 2)
        let entryB = try #require(entries.first(where: { $0.oid == oidB }))
        let entryA = try #require(entries.first(where: { $0.oid == oidA }))
        let carriedNote = try #require(entryB.note,
                                       "the annotated commit's entry must carry the note")
        #expect(Data(carriedNote.utf8) == Data(Self.decisionBody.utf8),
                "the annotated commit's entry must carry the note byte-identical, got \(carriedNote)")
        #expect(entryA.note == nil,
                "a commit without a note must have no note field, got \(entryA.note ?? "nil")")
    }

    /// Another tool's ordinary `refs/notes/commits` note is neither a review
    /// decision nor visible as one: the log's `%N` field is fed from the
    /// dedicated namespace alone.
    @Test func ordinaryNotesNamespaceNeverSurfacesAsAReviewDecision() async throws {
        var repo = try FixtureRepository.linear()
        defer { repo.destroy() }
        let oid = try #require(repo.oids["c"])
        try await GitProcess().run(
            ["notes", "--ref=refs/notes/commits", "add", "-f", "-m", "ordinary note", oid],
            workingDirectory: repo.url.path)

        let entries = try await CommitLog.run(path: repo.url.path, rangeArguments: ["HEAD"])
        #expect(entries.allSatisfy { $0.note == nil },
                "refs/notes/commits notes must never surface as review decisions")
        let listed = try await ReviewNotes.list(at: repo.url.path)
        #expect(listed.isEmpty,
                "the dedicated namespace must be empty when only ordinary notes exist")
    }
}
