// FileInspectorTests.swift — the file inspector's data layer (#0516)
//
// Imports `YardUI` and `YardGit` without `@testable`, like
// `CommitDiffLoaderTests`: every type here is public API the view and the
// app use, and a member that dropped to internal must fail to compile here.

import Foundation
import Testing
import YardGit
import YardUI

private func row(_ path: String, _ state: WorktreeStatusEntry.State,
                 side: WorkingChanges.Side = .unstaged, from originalPath: String? = nil) -> WorkingChanges.Row {
    WorkingChanges.Row(side: side, path: path, originalPath: originalPath, state: state)
}

private func file(_ path: String, header: String = "") -> FileDiff {
    FileDiff(path: path, oldMode: nil, newMode: nil, isBinary: false,
             headerText: "diff --git a/\(path) b/\(path)\n" + header, hunks: [])
}

private let oid1 = String(repeating: "1", count: 40)
private let oid2 = String(repeating: "2", count: 40)

// MARK: - Targets

@Test func untrackedAndConflictedRowsHaveNoInspector() {
    #expect(FileInspectorTarget.forWorkingRow(row("new.txt", .untracked), mode: .history) == nil)
    #expect(FileInspectorTarget.forWorkingRow(row("c.txt", .conflicted, side: .conflicted), mode: .blame) == nil)
    #expect(FileInspectorTarget.forWorkingRow(row("u.txt", .unmerged, side: .conflicted), mode: .blame) == nil)
}

@Test func aModifiedRowOffersBothModesInTheWorkingTree() throws {
    let target = try #require(FileInspectorTarget.forWorkingRow(row("a.txt", .modified), mode: .blame))
    #expect(target.mode == .blame)
    #expect(target.path == "a.txt")
    #expect(target.revision == nil)
    #expect(target.historyRevision == "HEAD")
    #expect(target.historyPath == "a.txt")
    #expect(target.modes == [.history, .blame])
    #expect(target.revisionLabel == "Working tree")
    #expect(target.with(.history).mode == .history)
}

@Test func aStagedRenameFollowsHistoryFromItsOriginalPath() throws {
    let target = try #require(FileInspectorTarget.forWorkingRow(
        row("g.txt", .modified, side: .staged, from: "f.txt"), mode: .history))
    #expect(target.path == "g.txt", "blame reads the file on disk, at its new name")
    #expect(target.historyPath == "f.txt", "HEAD has the file at its old name")
}

@Test func aDeletedRowHasHistoryAndNoBlame() throws {
    let target = try #require(FileInspectorTarget.forWorkingRow(row("gone.txt", .deleted), mode: .blame))
    #expect(target.mode == .history, "asking for Blame on a deleted file opens History")
    #expect(target.modes == [.history])
    #expect(target.blameUnavailable == "gone.txt is deleted in the working tree")
}

@Test func aCommitsFilesAreReadAtThatCommit() {
    let modified = FileInspectorTarget.forCommitFile(file("a.txt"), oid: oid1, mode: .blame)
    #expect(modified.revision == oid1)
    #expect(modified.mode == .blame)
    #expect(modified.modes == [.history, .blame])
    #expect(modified.revisionLabel == "At 1111111")

    let deleted = FileInspectorTarget.forCommitFile(
        file("b.txt", header: "deleted file mode 100644\n"), oid: oid1, mode: .blame)
    #expect(deleted.mode == .history)
    #expect(deleted.modes == [.history])
    #expect(deleted.blameUnavailable == "b.txt is deleted in this commit")
}

@Test func aHistoryRowBlamesTheFileAsThatCommitLeftIt() throws {
    let renamed = FileHistory.Entry(oid: oid2, author: "A", authorTime: 0, subject: "move",
                                    status: "R", path: "g.txt", previousPath: "f.txt")
    let target = try #require(FileInspectorTarget.blame(of: renamed))
    #expect(target == FileInspectorTarget(mode: .blame, path: "g.txt", revision: oid2))
    let deletion = FileHistory.Entry(oid: oid2, author: "A", authorTime: 0, subject: "rm",
                                     status: "D", path: "g.txt", previousPath: nil)
    #expect(FileInspectorTarget.blame(of: deletion) == nil)
}

// MARK: - Links

@Test func aLoadedCommitIsSelectedAndAnOlderOneOpensItsChanges() {
    #expect(FileInspectorLink.resolve(oid: oid1, subject: "s", repositoryPath: "/r", loaded: [oid1])
        == .selectInHistory(oid: oid1))
    #expect(FileInspectorLink.resolve(oid: oid2, subject: "old", repositoryPath: "/r", loaded: [oid1])
        == .openChanges(CommitChangesTarget(repositoryPath: "/r", oid: oid2, subject: "old")))
}

// MARK: - Rows

private func line(_ oid: String, _ number: Int, _ content: String, time: Int = 1_700_000_000) -> BlameLine {
    BlameLine(oid: oid, finalLine: number, originalLine: number, originalPath: "f.txt",
              author: oid == BlameLine.uncommittedOID ? "Not Committed Yet" : "Ann",
              authorEmail: "a@example.invalid", authorTime: time, authorTimeZone: "+0000",
              summary: "subject \(oid.prefix(1))", isBoundary: false, content: content)
}

@Test func aRunOfLinesFromOneCommitShowsItsCommitOnce() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000 + 7_200)
    let rows = BlameRows.make([
        line(oid1, 1, "a"), line(oid1, 2, "b"), line(oid2, 3, "c"),
        line(BlameLine.uncommittedOID, 4, "d"), line(oid1, 5, "e"),
    ], now: now)

    #expect(rows.map(\.id) == [1, 2, 3, 4, 5])
    #expect(rows.map(\.content) == ["a", "b", "c", "d", "e"])
    #expect(rows.map(\.run) == [0, 0, 1, 2, 3])
    #expect(rows.map { $0.commit != nil } == [true, false, true, true, true])
    let first = try #require(rows[0].commit)
    #expect(first.oid == oid1)
    #expect(first.shortOid == "1111111")
    #expect(first.author == "Ann")
    #expect(first.summary == "subject 1")
    #expect(first.date == "2h ago", "abbreviated and relative; measured \"2h ago\" (en_US)")
    #expect(rows[3].commit == BlameRow.Commit(oid: nil, shortOid: "", author: "Not Committed Yet",
                                              date: "", summary: ""))
}

@Test func aHistoryRowSaysWhatTheCommitDidToTheFile() {
    func entry(_ status: String, previous: String? = nil) -> FileHistory.Entry {
        FileHistory.Entry(oid: oid1, author: "Ann", authorTime: 1_700_000_000, subject: "s",
                          status: status, path: "g.txt", previousPath: previous)
    }
    #expect(FileHistoryRowText.change(for: entry("R", previous: "f.txt")) == "Renamed from f.txt")
    #expect(FileHistoryRowText.change(for: entry("C", previous: "f.txt")) == "Copied from f.txt")
    #expect(FileHistoryRowText.change(for: entry("A")) == "Added")
    #expect(FileHistoryRowText.change(for: entry("D")) == "Deleted")
    #expect(FileHistoryRowText.change(for: entry("M")) == nil)
    let caption = FileHistoryRowText.caption(
        for: entry("M"), now: Date(timeIntervalSince1970: 1_700_000_000 + 7_200))
    #expect(caption.hasPrefix("1111111 · Ann · "))
    #expect(caption == "1111111 · Ann · 2h ago")
}

// MARK: - Loaders, on a real repository

@Test func theLoadersFollowAStagedRenameAndBlameTheWorkingTree() async throws {
    var repo = try FixtureRepository()
    defer { repo.destroy() }
    try repo.build([
        .init("one", files: ["f.txt": "a\nb\n"]),
        .init("two", files: ["f.txt": "a\nB\n"]),
    ])
    let git = GitProcess()
    try await git.run(["mv", "f.txt", "g.txt"], workingDirectory: repo.url.path)
    try "a\nB\nc\n".write(to: repo.url.appendingPathComponent("g.txt"), atomically: true, encoding: .utf8)

    let summary = try await loadRepositorySummary(at: repo.url.path)
    let staged = try #require(WorkingChanges(status: summary.status).staged.first)
    let target = try #require(FileInspectorTarget.forWorkingRow(staged, mode: .history))

    let history = try await loadFileHistory(at: repo.url.path, target: target)
    #expect(history.map(\.subject) == ["two", "one"])

    let rows = try await loadBlameRows(at: repo.url.path, target: target.with(.blame))
    #expect(rows.map(\.content) == ["a", "B", "c"])
    #expect(rows.map { $0.commit?.oid } == [repo.oids["one"], repo.oids["two"], nil])
}
