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
        let baseOID = try #require(repo.oids["base"])
        try repo.checkoutDetached(baseOID)
        try git.run(["rm", "-q", "d.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "ours deletes d"], workingDirectory: repo.url.path)
        let theirsOID = try #require(repo.oids["theirs"])
        _ = try git.capture(["merge", "--no-commit", theirsOID],
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

    // #0311: `deleteModifyReportsNoOursStage` above pins DU (deleted by us).
    // This is its mirror — ours modifies, theirs deletes — which is UD
    // (deleted by them), the case the M1 review found unasserted end-to-end
    // through `conflictedFiles` against real git output.
    @Test("modifyDeleteReportsDeletedByThem", arguments: FixtureRepository.RefFormat.supported())
    func modifyDeleteReportsDeletedByThem(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["d.txt": "original d\n", "keep.txt": "keep\n"])])
        try repo.build([.init("ours", parents: ["base"], files: ["d.txt": "ours d\n"])])

        let git = GitProcess()
        let baseOID = try #require(repo.oids["base"])
        try repo.checkoutDetached(baseOID)
        try git.run(["rm", "-q", "d.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "theirs deletes d"], workingDirectory: repo.url.path)
        let theirsDeleteOID = try repo.revParse("HEAD")

        let oursOID = try #require(repo.oids["ours"])
        try repo.checkoutDetached(oursOID)
        _ = try git.capture(["merge", "--no-commit", theirsDeleteOID],
                            workingDirectory: repo.url.path)

        // Ground truth from git itself (#0281 pattern): confirm the fixture
        // actually produced a "UD" record before trusting the parser under test.
        let statusLines = try git.run(["status", "--porcelain=v2"], workingDirectory: repo.url.path).lines
        let dLine = try #require(statusLines.first(where: { $0.hasSuffix(" d.txt") }))
        #expect(dLine.hasPrefix("u UD "))

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["d.txt"])

        let entry = try #require(files.first(where: { $0.path == "d.txt" }))
        #expect(entry.kind == .deletedByThem)
        #expect(entry.theirs == nil)

        let base = try #require(entry.base)
        let ours = try #require(entry.ours)

        #expect(try git.capture(["cat-file", "-p", base.oid], workingDirectory: repo.url.path).text == "original d\n")
        #expect(try git.capture(["cat-file", "-p", ours.oid], workingDirectory: repo.url.path).text == "ours d\n")
    }

    // #0311: `AU` and `UA` are the two remaining unasserted-end-to-end kinds
    // alongside `UD`. Neither arises from a plain add/add or modify/delete
    // merge (measured: those produce `AA` and `UD`/`DU`) — they come from a
    // rename/rename(1to2) conflict, where the same base path is renamed to
    // two different names on each side. One such merge produces both in a
    // single fixture: the "ours" rename target is `AU` (added by us, no
    // theirs stage at all), the "theirs" rename target is `UA` (its mirror),
    // and the original path itself goes `DD` — measured directly below
    // before trusting the parser, per the issue's own instruction.
    @Test("renameRenameConflictReportsAddedByUsAndAddedByThem", arguments: FixtureRepository.RefFormat.supported())
    func renameRenameConflictReportsAddedByUsAndAddedByThem(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        // Content shared verbatim by both renamed copies, well past git's
        // default 50% similarity threshold, so both sides are detected as
        // renames of `base.txt` rather than independent adds.
        let original = (0..<20).map { "line \($0)\n" }.joined()
        try repo.build([.init("base", files: ["base.txt": original])])

        let git = GitProcess()
        let baseOID = try #require(repo.oids["base"])

        try repo.checkoutDetached(baseOID)
        try git.run(["mv", "base.txt", "a.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "ours renames base.txt to a.txt"], workingDirectory: repo.url.path)
        let oursOID = try repo.revParse("HEAD")

        try repo.checkoutDetached(baseOID)
        try git.run(["mv", "base.txt", "b.txt"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "theirs renames base.txt to b.txt"], workingDirectory: repo.url.path)
        let theirsOID = try repo.revParse("HEAD")

        try repo.checkoutDetached(oursOID)
        _ = try git.capture(["merge", "--no-commit", theirsOID], workingDirectory: repo.url.path)

        // Ground truth from git itself (#0281 pattern): confirm the
        // rename/rename(1to2) fixture actually produced AU at a.txt and UA
        // at b.txt before trusting the parser under test.
        let statusLines = try git.run(["status", "--porcelain=v2"], workingDirectory: repo.url.path).lines
        let aLine = try #require(statusLines.first(where: { $0.hasSuffix(" a.txt") }))
        #expect(aLine.hasPrefix("u AU "))
        let bLine = try #require(statusLines.first(where: { $0.hasSuffix(" b.txt") }))
        #expect(bLine.hasPrefix("u UA "))

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["a.txt", "b.txt", "base.txt"])

        let aEntry = try #require(files.first(where: { $0.path == "a.txt" }))
        #expect(aEntry.kind == .addedByUs)
        #expect(aEntry.base == nil)
        #expect(aEntry.theirs == nil)
        let ours = try #require(aEntry.ours)

        let bEntry = try #require(files.first(where: { $0.path == "b.txt" }))
        #expect(bEntry.kind == .addedByThem)
        #expect(bEntry.base == nil)
        #expect(bEntry.ours == nil)
        let theirs = try #require(bEntry.theirs)

        #expect(try git.capture(["cat-file", "-p", ours.oid], workingDirectory: repo.url.path).text == original)
        #expect(try git.capture(["cat-file", "-p", theirs.oid], workingDirectory: repo.url.path).text == original)
    }

    @Test("addAddReportsNoBaseStage", arguments: FixtureRepository.RefFormat.supported())
    func addAddReportsNoBaseStage(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["base.txt": "base\n"])])
        try repo.build([.init("ours", parents: ["base"], files: ["new.txt": "ours new\n"])])
        try repo.build([.init("theirs", parents: ["base"], files: ["new.txt": "theirs new\n"])])

        let git = GitProcess()
        let oursOID = try #require(repo.oids["ours"])
        try repo.checkoutDetached(oursOID)
        let theirsOID = try #require(repo.oids["theirs"])
        _ = try git.capture(["merge", "--no-commit", theirsOID],
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
        let baseOID = try #require(repo.oids["base"])
        try repo.checkoutDetached(baseOID)
        try repo.writeUntracked(["f.txt": "ours f\n", "g.txt": "ours g\n"])
        try git.run(["rm", "-q", "d.txt"], workingDirectory: repo.url.path)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "ours"], workingDirectory: repo.url.path)
        let theirsOID = try #require(repo.oids["theirs"])
        _ = try git.capture(["merge", "--no-commit", theirsOID],
                            workingDirectory: repo.url.path)

        let files = try conflictedFiles(at: repo.url.path)
        #expect(files.map(\.path) == ["d.txt", "f.txt", "g.txt"])
        #expect(files.count == 3)

        let stageLines = try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).lines
        #expect(stageLines.count == 8)
    }

    // Finding 6, M1 milestone review sixth pass (#0281): every `mode`
    // assertion elsewhere in this file is the string "100644", so a
    // hardcoded `mode: "100644"` in `ConflictParser` would go unnoticed.
    // These two conflict a non-regular-file mode against `base` so the
    // reported stage mode has to come from git's own output to pass.
    @Test("executableModeConflictReportsActualStageModes", arguments: FixtureRepository.RefFormat.supported())
    func executableModeConflictReportsActualStageModes(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["run.sh": "original\n"])])
        try repo.build([.init("theirs", parents: ["base"], files: ["run.sh": "theirs\n"])])

        let git = GitProcess()
        let baseOID = try #require(repo.oids["base"])
        try repo.checkoutDetached(baseOID)
        let scriptURL = repo.url.appendingPathComponent("run.sh")
        try "ours\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "ours makes run.sh executable"], workingDirectory: repo.url.path)
        let theirsOID = try #require(repo.oids["theirs"])
        _ = try git.capture(["merge", "--no-commit", theirsOID],
                            workingDirectory: repo.url.path)

        // Ground truth from git itself, not the parser under test (#0281):
        // confirms the fixture actually produced a 100755 "ours" stage
        // before trusting any assertion made through `conflictedFiles`.
        let stageLines = try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).lines
        #expect(!stageLines.isEmpty)
        let oursStageLine = try #require(stageLines.first(where: { $0.hasSuffix("2\trun.sh") }))
        #expect(oursStageLine.hasPrefix("100755 "))

        let files = try conflictedFiles(at: repo.url.path)
        let entry = try #require(files.first(where: { $0.path == "run.sh" }))
        #expect(entry.kind == .bothModified)

        let base = try #require(entry.base)
        let ours = try #require(entry.ours)
        let theirs = try #require(entry.theirs)

        #expect(base.mode == "100644")
        #expect(ours.mode == "100755")
        #expect(theirs.mode == "100644")
    }

    @Test("symlinkModeConflictReportsSymlinkMode", arguments: FixtureRepository.RefFormat.supported())
    func symlinkModeConflictReportsSymlinkMode(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["link.txt": "target-a\n"])])

        let git = GitProcess()
        let baseOID = try #require(repo.oids["base"])
        try repo.checkoutDetached(baseOID)
        let linkURL = repo.url.appendingPathComponent("link.txt")
        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "b")
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "ours symlinks link.txt to b"], workingDirectory: repo.url.path)
        let oursOID = try repo.revParse("HEAD")

        try repo.checkoutDetached(baseOID)
        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "a")
        try git.run(["add", "-A"], workingDirectory: repo.url.path)
        try git.run(["commit", "-qm", "theirs symlinks link.txt to a"], workingDirectory: repo.url.path)
        let theirsOID = try repo.revParse("HEAD")

        try repo.checkoutDetached(oursOID)
        _ = try git.capture(["merge", "--no-commit", theirsOID], workingDirectory: repo.url.path)

        // Ground truth from git itself (#0281), as above.
        let stageLines = try git.run(["ls-files", "-u"], workingDirectory: repo.url.path).lines
        #expect(!stageLines.isEmpty)
        let oursStageLine = try #require(stageLines.first(where: { $0.hasSuffix("2\tlink.txt") }))
        #expect(oursStageLine.hasPrefix("120000 "))

        let files = try conflictedFiles(at: repo.url.path)
        let entry = try #require(files.first(where: { $0.path == "link.txt" }))
        #expect(entry.kind == .bothModified)

        let base = try #require(entry.base)
        let ours = try #require(entry.ours)
        let theirs = try #require(entry.theirs)

        #expect(base.mode == "100644")
        #expect(ours.mode == "120000")
        #expect(theirs.mode == "120000")
    }

    @Test("rebaseConflictIsReportedWithSidesSwapped", arguments: FixtureRepository.RefFormat.supported())
    func rebaseConflictIsReportedWithSidesSwapped(format: FixtureRepository.RefFormat) throws {
        var repo = try FixtureRepository(refFormat: format)
        defer { repo.destroy() }

        try repo.build([.init("base", files: ["f.txt": "original\n"])])
        try repo.build([.init("ours", parents: ["base"], files: ["f.txt": "ours\n"])])
        try repo.build([.init("theirs", parents: ["base"], files: ["f.txt": "theirs\n"])])

        let git = GitProcess()
        let oursOID = try #require(repo.oids["ours"])
        try repo.checkoutDetached(oursOID)
        let theirsOID = try #require(repo.oids["theirs"])
        _ = try git.capture(["rebase", theirsOID], workingDirectory: repo.url.path)

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
        let oursOID = try #require(repo.oids["ours"])
        try repo.checkoutDetached(oursOID)
        let theirsOID = try #require(repo.oids["theirs"])
        _ = try git.capture(["cherry-pick", theirsOID], workingDirectory: repo.url.path)

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
