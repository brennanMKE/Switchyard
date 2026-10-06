// 0596ReorderDeleteUITests.swift
//
// #0596: Swap with Parent, Swap with Child and Delete Commit… from the
// Commit menu, checked against git, then taken back with Edit ▸ Undo.

import XCTest

final class Spike0596SwapWithParentUITests: XCTestCase {
    @MainActor
    func testSwapWithParentMovesTheCommitDownAndUndoRestoresIt() {
        let repo = GitRepo(path: HistoryFixture.path("swap"))
        let before = GitStateSnapshot(repo)
        let tip = repo.oid("stack")
        let tipTree = repo.treeOid("stack")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("swap")
        app.selectHistoryRow(subject: HistoryFixture.stackTwo)
        app.chooseCommitMenuItem("Swap with Parent")

        XCTAssertTrue(repo.wait { repo.oid("stack") != tip && repo.headBranch() == "stack" },
                      "Swap with Parent never moved stack")
        XCTAssertEqual(Array(repo.subjects("stack").prefix(4)),
                       ["stack tip", "stack split", "stack one", "stack two"])
        XCTAssertEqual(repo.treeOid("stack"), tipTree, "a reorder changed the tip's tree")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0596-swapped-parent", in: self)

        app.chooseEditMenuItem("Undo Move Commit")
        repo.assertRestored(to: before, "Undo Move Commit did not restore stack")
    }
}

/// Its own class (and launch), not a second step after Swap with Parent's
/// Undo: re-selecting a row straight after an Undo's refresh failed once in
/// four VM runs ("Tapping the “stack two” row did not select it"), so every
/// history spike performs exactly one operation per launch.
final class Spike0596SwapWithChildUITests: XCTestCase {
    @MainActor
    func testSwapWithChildMovesTheCommitUpAndUndoRestoresIt() {
        let repo = GitRepo(path: HistoryFixture.path("swap"))
        let before = GitStateSnapshot(repo)
        let tip = repo.oid("stack")
        let tipTree = repo.treeOid("stack")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("swap")
        app.selectHistoryRow(subject: HistoryFixture.stackTwo)
        app.chooseCommitMenuItem("Swap with Child")

        XCTAssertTrue(repo.wait { repo.oid("stack") != tip && repo.headBranch() == "stack" },
                      "Swap with Child never moved stack")
        XCTAssertEqual(Array(repo.subjects("stack").prefix(4)),
                       ["stack tip", "stack two", "stack split", "stack one"])
        XCTAssertEqual(repo.treeOid("stack"), tipTree, "a reorder changed the tip's tree")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0596-swapped-child", in: self)

        app.chooseEditMenuItem("Undo Move Commit")
        repo.assertRestored(to: before, "Undo Move Commit did not restore stack")
    }
}

final class Spike0596DeleteUITests: XCTestCase {
    @MainActor
    func testDeleteCommitDropsItsChangeAndUndoRestoresIt() {
        let repo = GitRepo(path: HistoryFixture.path("delete"))
        let before = GitStateSnapshot(repo)
        let tip = repo.oid("stack")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("delete")
        app.selectHistoryRow(subject: HistoryFixture.stackTwo)
        app.chooseCommitMenuItem("Delete Commit…")
        let confirm = app.windowButton("Delete Commit")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no Delete Commit confirmation")
        app.keepScreenshot("0596-delete-confirm", in: self)
        confirm.click()

        XCTAssertTrue(repo.wait { repo.oid("stack") != tip && repo.headBranch() == "stack" }, "stack never moved")
        XCTAssertEqual(Array(repo.subjects("stack").prefix(4)),
                       ["stack tip", "stack split", "stack one", HistoryFixture.mainTipSubject])
        XCTAssertFalse(repo.lsTree("stack").contains("s2.txt"))
        XCTAssertNil(repo.worktreeFile("s2.txt"))
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0596-deleted", in: self)

        app.chooseEditMenuItem("Undo Delete Commit")
        repo.assertRestored(to: before, "Undo Delete Commit did not restore stack")
        XCTAssertEqual(repo.worktreeFile("s2.txt"), "two")
    }
}
