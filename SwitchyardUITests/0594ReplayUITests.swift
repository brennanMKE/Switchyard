// 0594ReplayUITests.swift
//
// #0594: Cherry-Pick and Revert from the Commit menu, checked against git,
// then taken back with Edit ▸ Undo.

import XCTest

final class Spike0594CherryPickUITests: XCTestCase {
    @MainActor
    func testCherryPickCopiesTheCommitOntoMainAndUndoTakesItBack() {
        let repo = GitRepo(path: HistoryFixture.path("cherry-pick"))
        let before = GitStateSnapshot(repo)
        let mainTip = repo.oid("main")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("cherry-pick")
        app.selectHistoryRow(subject: HistoryFixture.pickSubject)
        app.chooseCommitMenuItem("Cherry-Pick")

        XCTAssertTrue(repo.wait { repo.oid("main") != mainTip }, "main never moved")
        XCTAssertEqual(repo.parents(of: "main"), [mainTip])
        XCTAssertEqual(repo.subjects("main").first, HistoryFixture.pickSubject)
        XCTAssertEqual(repo.fileContents(at: "pick.txt", rev: "main"), "picked")
        XCTAssertEqual(repo.worktreeFile("pick.txt"), "picked")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0594-picked", in: self)

        app.chooseEditMenuItem("Undo Cherry-Pick")
        repo.assertRestored(to: before, "Undo Cherry-Pick did not restore main")
        XCTAssertNil(repo.worktreeFile("pick.txt"))
    }
}

final class Spike0594RevertUITests: XCTestCase {
    @MainActor
    func testRevertRemovesTheCommitsFileAndUndoTakesItBack() {
        let repo = GitRepo(path: HistoryFixture.path("revert"))
        let before = GitStateSnapshot(repo)
        let mainTip = repo.oid("main")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("revert")
        app.selectHistoryRow(subject: HistoryFixture.mainThreeSubject)
        app.chooseCommitMenuItem("Revert")

        XCTAssertTrue(repo.wait { repo.oid("main") != mainTip }, "main never moved")
        XCTAssertEqual(repo.parents(of: "main"), [mainTip])
        XCTAssertEqual(repo.subjects("main").first, "Revert \"\(HistoryFixture.mainThreeSubject)\"")
        XCTAssertFalse(repo.lsTree("main").contains("main3.txt"))
        XCTAssertNil(repo.worktreeFile("main3.txt"))
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0594-reverted", in: self)

        app.chooseEditMenuItem("Undo Revert")
        repo.assertRestored(to: before, "Undo Revert did not restore main")
        XCTAssertEqual(repo.worktreeFile("main3.txt"), "main three")
    }
}
