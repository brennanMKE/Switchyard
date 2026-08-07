// ConflictsTests.swift — tests for ConflictedFile, ConflictParser, conflictedFiles

import Foundation
import Testing
@testable import YardGit

struct ConflictsTests {

    private let git = GitProcess()
    @Test("contentConflictReportsAllThreeStages", arguments: FixtureRepository.RefFormat.supported())
    func contentConflictReportsAllThreeStages(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.conflictedTwo(refFormat: format)
        defer { repo.destroy() }

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["f.txt", "g.txt"])

        let first = try #require(files.first(where: { $0.path == "f.txt" }))
        #expect(first.kind == .bothModified)

        let base = try #require(first.base)
        let ours = try #require(first.ours)
        let theirs = try #require(first.theirs)

        #expect(base.mode == "100644")
        #expect(ours.mode == "100644")
        #expect(theirs.mode == "100644")

        let git = GitProcess()
        #expect(try git.capture(["cat-file", "-p", base.oid], workingDirectory: repo.url.path).text == "original f\n")
        #expect(try git.capture(["cat-file", "-p", ours.oid], workingDirectory: repo.url.path).text == "ours f\n")
        #expect(try git.capture(["cat-file", "-p", theirs.oid], workingDirectory: repo.url.path).text == "theirs f\n")
    }

    @Test("deleteModifyReportsNoOursStage", arguments: FixtureRepository.RefFormat.supported())
    func deleteModifyReportsNoOursStage(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["d.txt": "original d\n", "keep.txt": "keep\n"])])
        try repo.build([.init("theirs", parents: ["base"], files: ["d.txt": "theirs d\n"])])

        let git = GitProcess()
        try repo.checkoutDetached(repo.oids["base"]!)
        try git.run(["rm", "-q", "d.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "ours deletes d"], workingDirectory: repo.url.path)
        _ = try git.capture(["merge", "--no-commit", repo.oids["theirs"]!],
                            workingDirectory: repo.url.path)

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["d.txt"])

        let entry = try #require(files.first(where: { $0.path == "d.txt" }))
        #expect(entry.kind == .deletedByUs)
        #expect(entry.ours == nil)

        let base = try #require(entry.base)
        let theirs = try #require(entry.theirs)

        #expect(try git.capture(["cat-file", "-p", theirs.oid], workingDirectory: repo.url.path).text == "theirs d\n")
    }

    @Test("addAddReportsNoBaseStage", arguments: FixtureRepository.RefFormat.supported())
    func addAddReportsNoBaseStage(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["base.txt": "base\n"])])
        try repo.build([.init("ours", parents: ["base"], files: ["new.txt": "ours new\n"])])
        try repo.build([.init("theirs", parents: ["base"], files: ["new.txt": "theirs new\n"])])

        let git = GitProcess()
        try repo.checkoutDetached(repo.oids["ours"]!)
        _ = try git.capture(["merge", "--no-commit", repo.oids["theirs"]!],
                            workingDirectory: repo.url.path)

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["new.txt"])

        let entry = try #require(files.first(where: { $0.path == "new.txt" }))
        #expect(entry.kind == .bothAdded)
        #expect(entry.base == nil)

        let ours = try #require(entry.ours)
        let theirs = try #require(entry.theirs)

        #expect(try git.capture(["cat-file", "-p", ours.oid], workingDirectory: repo.url.path).text == "ours new\n")
    }

    @Test("pathsAreCountedNotStageEntries", arguments: FixtureRepository.RefFormat.supported())
    func pathsAreCountedNotStageEntries(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: [
            "d.txt": "original d\n", "f.txt": "original f\n", "g.txt": "original g\n"
        ])])
        try repo.build([.init("theirs", parents: ["base"], files: [
            "d.txt": "theirs d\n", "f.txt": "theirs f\n", "g.txt": "theirs g\n"
        ])])

        let git = GitProcess()
        try repo.checkoutDetached(repo.oids["base"]!)
        try repo.writeUntracked(["f.txt": "ours f\n", "g.txt": "ours g\n"])
        try git.run(["rm", "-q", "d.txt"], workingDirectory: repo.url.path)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "ours"], workingDirectory: repo.url.path)
        _ = try git.capture(["merge", "--no-commit", repo.oids["theirs"]!],
                            workingDirectory: repo.url.path)

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["d.txt", "f.txt", "g.txt"])
        #expect(files.count == 3)

        let stageLines = try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).lines
        #expect(stageLines.count == 8)
    }

    @Test("rebaseConflictIsReportedWithSidesSwapped", arguments: FixtureRepository.RefFormat.supported())
    func rebaseConflictIsReportedWithSidesSwapped(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["f.txt": "original\n"])])
        try repo.build([.init("ours", parents: ["base"], files: ["f.txt": "ours\n"])])
        try repo.build([.init("theirs", parents: ["base"], files: ["f.txt": "theirs\n"])])

        let git = GitProcess()
        try repo.checkoutDetached(repo.oids["ours"]!)
        _ = try git.capture(["rebase", repo.oids["theirs"]!], workingDirectory: repo.url.path)

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["f.txt"])

        let entry = try #require(files.first(where: { $0.path == "f.txt" }))
        #expect(entry.kind == .bothModified)

        let ours = try #require(entry.ours)
        let theirs = try #require(entry.theirs)

        let catGit = GitProcess()
        #expect(try catGit.capture(["cat-file", "-p", ours.oid], workingDirectory: repo.url.path).text == "theirs\n")
        #expect(try catGit.capture(["cat-file", "-p", theirs.oid], workingDirectory: repo.url.path).text == "ours\n")
    }

    @Test("cherryPickConflictIsReported", arguments: FixtureRepository.RefFormat.supported())
    func cherryPickConflictIsReported(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["f.txt": "original\n"])])
        try repo.build([.init("ours", parents: ["base"], files: ["f.txt": "ours\n"])])
        try repo.build([.init("theirs", parents: ["base"], files: ["f.txt": "theirs\n"])])

        let git = GitProcess()
        try repo.checkoutDetached(repo.oids["ours"]!)
        _ = try git.capture(["cherry-pick", repo.oids["theirs"]!], workingDirectory: repo.url.path)

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["f.txt"])

        let entry = try #require(files.first(where: { $0.path == "f.txt" }))
        #expect(entry.kind == .bothModified)

        let ours = try #require(entry.ours)
        let theirs = try #require(entry.theirs)

        let catGit = GitProcess()
        #expect(try catGit.capture(["cat-file", "-p", ours.oid], workingDirectory: repo.url.path).text == "ours\n")
        #expect(try catGit.capture(["cat-file", "-p", theirs.oid], workingDirectory: repo.url.path).text == "theirs\n")
    }

    @Test("dirtyButUnconflictedTreeReportsNoConflicts", arguments: FixtureRepository.RefFormat.supported())
    func dirtyButUnconflictedTreeReportsNoConflicts(format: FixtureRepository.RefFormat) throws {
        let repo = try FixtureRepository.linear(refFormat: format)
        defer { repo.destroy() }

        try repo.writeUntracked(["a.txt": "edited\n", "untracked.txt": "u\n"])

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.isEmpty)
    }

    @Test("renameOriginalPathIsNotScannedAsARecord")
    func renameOriginalPathIsNotScannedAsARecord() throws {
        let rename = "2 R. N... 100644 100644 100644 "
            + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb R100 renamed.txt"
        let originalPath = "u orig.txt"
        let u = "u UU N... 100644 100644 100644 100644 "
            + "334adba7b261109f0ebd5347d491172b3ad52f7d "
            + "f08b71eba2bad1b394def9febc40e93c6f577888 "
            + "1e76667a4a9713d4d2674161d6d24b470b45176c f.txt"
        let data = Data((rename + "\u{0}" + originalPath + "\u{0}" + u + "\u{0}").utf8)

        let files = try ConflictParser().parse(data)
        #expect(files.map(\.path) == ["f.txt"])

        let entry = try #require(files.first(where: { $0.path == "f.txt" }))
        let base = try #require(entry.base)
        let ours = try #require(entry.ours)
        let theirs = try #require(entry.theirs)

        #expect(base.oid == "334adba7b261109f0ebd5347d491172b3ad52f7d")
        #expect(ours.oid == "f08b71eba2bad1b394def9febc40e93c6f577888")
        #expect(theirs.oid == "1e76667a4a9713d4d2674161d6d24b470b45176c")
    }

    @Test("truncatedURecordThrows")
    func truncatedURecordThrows() {
        let data = Data("u UU N... 100644\u{0}".utf8)

        #expect(throws: ConflictParser.Failure.self) {
            try ConflictParser().parse(data)
        }
    }

    @Test("unrecognizedKindThrows")
    func unrecognizedKindThrows() {
        let data = Data(("u XX N... 100644 100644 100644 100644 "
            + "334adba7b261109f0ebd5347d491172b3ad52f7d "
            + "f08b71eba2bad1b394def9febc40e93c6f577888 "
            + "1e76667a4a9713d4d2674161d6d24b470b45176c f.txt\u{0}").utf8)

        #expect(throws: ConflictParser.Failure.unrecognizedKind(xy: "XX", path: "f.txt")) {
            try ConflictParser().parse(data)
        }
    }
} // end struct ConflictsTests
