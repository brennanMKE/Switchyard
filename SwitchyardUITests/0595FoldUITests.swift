// 0595FoldUITests.swift
//
// #0595: Squash with Parent… (sheet, combined message) and Fixup with Parent
// (tip only today — mid-branch fixup is workstream B, #0580-#0589, which
// extends this file's fixture use) from the Commit menu, checked against
// git, then taken back with Edit ▸ Undo.

import XCTest

final class Spike0595SquashUITests: XCTestCase {
    @MainActor
    func testSquashFoldsTheTipIntoItsParentWithBothMessages() {
        let repo = GitRepo(path: HistoryFixture.path("squash"))
        let before = GitStateSnapshot(repo)
        let tip = repo.oid("stack")
        let grandparent = repo.oid("stack~2")
        let tipTree = repo.treeOid("stack")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("squash")
        app.selectHistoryRow(subject: HistoryFixture.stackTip)
        app.chooseCommitMenuItem("Squash with Parent…")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no Squash sheet")
        app.keepScreenshot("0595-squash-sheet", in: self)
        sheet.buttons["Squash"].click()

        XCTAssertTrue(repo.wait { repo.oid("stack") != tip && repo.headBranch() == "stack" }, "stack never moved")
        XCTAssertEqual(repo.parents(of: "stack"), [grandparent],
                       "the squash is not on “stack two”:\n\(repo.graph("stack"))")
        XCTAssertEqual(repo.treeOid("stack"), tipTree, "the squash changed the tip's tree")
        XCTAssertEqual(repo.message(of: "stack"), "stack split\n\nstack tip")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0595-squashed", in: self)

        // Red until #0599 maps the "squash" operation to its title.
        app.chooseEditMenuItem("Undo Squash")
        repo.assertRestored(to: before, "Undo Squash did not restore stack")
    }
}

final class Spike0595FixupTipUITests: XCTestCase {
    @MainActor
    func testFixupFoldsTheTipIntoItsParentKeepingTheParentsMessage() {
        let repo = GitRepo(path: HistoryFixture.path("fixup"))
        let before = GitStateSnapshot(repo)
        let beforeGraph = repo.graph("stack")
        let tip = repo.oid("stack")
        let grandparent = repo.oid("stack~2")
        let tipTree = repo.treeOid("stack")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("fixup")
        app.selectHistoryRow(subject: HistoryFixture.stackTip)
        app.chooseCommitMenuItem("Fixup with Parent")

        // Fixup moves `stack` twice — `commit --amend --fixup` first, then
        // `rebase --autosquash` — so "stack moved" is not "fixup finished"
        // (measured: the first VM run read the intermediate `fixup!` commit).
        // Wait for the folded result itself.
        XCTAssertTrue(
            repo.wait { repo.oid("stack") != tip && repo.headBranch() == "stack"
                && repo.parents(of: "stack") == [grandparent] },
            "the fold never landed on “stack two” — before:\n\(beforeGraph)\nafter:\n\(repo.graph("stack"))")
        XCTAssertEqual(repo.treeOid("stack"), tipTree)
        XCTAssertEqual(repo.message(of: "stack"), HistoryFixture.stackSplit,
                       "Fixup did not keep the parent's message")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0595-fixed-up", in: self)

        app.chooseEditMenuItem("Undo Fixup")
        repo.assertRestored(to: before, "Undo Fixup did not restore stack")
    }
}
