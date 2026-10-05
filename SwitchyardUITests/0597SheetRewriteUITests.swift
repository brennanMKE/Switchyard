// 0597SheetRewriteUITests.swift
//
// #0597: Edit Message… and Split… — the two rewrites composed in a sheet —
// from the Commit menu, checked against git, then taken back with Undo.

import XCTest

final class Spike0597EditMessageUITests: XCTestCase {
    @MainActor
    func testEditMessageRewordsOneCommitAndKeepsEveryTree() {
        let repo = GitRepo(path: HistoryFixture.path("edit-message"))
        let before = GitStateSnapshot(repo)
        let tip = repo.oid("stack")
        let tipTree = repo.treeOid("stack")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("edit-message")
        app.selectHistoryRow(subject: HistoryFixture.stackTwo)
        app.chooseCommitMenuItem("Edit Message…")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no Edit Commit Message sheet")
        let editor = sheet.textViews.firstMatch
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("stack two reworded")
        app.keepScreenshot("0597-edit-sheet", in: self)
        sheet.buttons["Save"].click()

        XCTAssertTrue(repo.wait { repo.oid("stack") != tip && repo.headBranch() == "stack" }, "stack never moved")
        XCTAssertEqual(Array(repo.subjects("stack").prefix(4)),
                       ["stack tip", "stack split", "stack two reworded", "stack one"])
        XCTAssertEqual(repo.treeOid("stack"), tipTree, "a reword changed the tip's tree")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0597-reworded", in: self)

        app.chooseEditMenuItem("Undo Edit Message")
        repo.assertRestored(to: before, "Undo Edit Message did not restore stack")
    }
}

final class Spike0597SplitUITests: XCTestCase {
    @MainActor
    func testSplitMakesTheSelectedHunkItsOwnCommit() {
        let repo = GitRepo(path: HistoryFixture.path("split"))
        let before = GitStateSnapshot(repo)
        let tip = repo.oid("stack")
        let tipTree = repo.treeOid("stack")
        let two = repo.oid("stack~2")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("split")
        app.selectHistoryRow(subject: HistoryFixture.stackSplit)
        app.chooseCommitMenuItem("Split…")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no Split sheet")
        let hunk = sheet.staticTexts["+split a"].firstMatch
        XCTAssertTrue(hunk.waitForExistence(timeout: 30), "the Split sheet lists no split-a.txt hunk")
        hunk.click()
        app.keepScreenshot("0597-split-sheet", in: self)
        sheet.buttons["Split"].click()

        XCTAssertTrue(repo.wait { repo.oid("stack") != tip && repo.headBranch() == "stack" }, "stack never moved")
        XCTAssertEqual(repo.oid("stack~3"), two, "the split is not on “stack two”:\n\(repo.graph("stack"))")
        XCTAssertEqual(repo.lsTree("stack~2").filter { $0.hasPrefix("split-") }, ["split-a.txt"],
                       "the first half does not hold exactly the selected hunk")
        XCTAssertEqual(repo.lsTree("stack~1").filter { $0.hasPrefix("split-") }, ["split-a.txt", "split-b.txt"])
        XCTAssertEqual(repo.treeOid("stack"), tipTree, "the split changed the tip's tree")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0597-split", in: self)

        app.chooseEditMenuItem("Undo Split")
        repo.assertRestored(to: before, "Undo Split did not restore stack")
    }
}
