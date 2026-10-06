// 0598RefsHereUITests.swift
//
// #0598: Set Branch Tip Here…, Create Branch… and Add Tag… from the Commit
// menu, checked against git, then taken back with Edit ▸ Undo.

import XCTest

final class Spike0598SetBranchTipUITests: XCTestCase {
    @MainActor
    func testSetBranchTipMovesOnlyTheRefAndUndoRestoresIt() {
        let repo = GitRepo(path: HistoryFixture.path("set-tip"))
        let before = GitStateSnapshot(repo)
        let shared = repo.oid("main~2")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("set-tip")
        app.selectHistoryRow(subject: HistoryFixture.sharedSubject)
        app.chooseCommitMenuItem("Set Branch Tip Here…")

        XCTAssertTrue(repo.wait { repo.oid("main") == shared }, "main never moved to “hist shared”")
        XCTAssertEqual(repo.headBranch(), "main")
        // The index and working tree are untouched: the dropped commits'
        // changes are now staged against the new tip.
        XCTAssertEqual(repo.git("diff", "--cached", "--name-only"), "main3.txt\nmain4.txt\nshared.txt")
        XCTAssertEqual(repo.worktreeFile("main4.txt"), "main four")
        app.keepScreenshot("0598-tip-set", in: self)

        app.chooseEditMenuItem("Undo Set Branch Tip")
        repo.assertRestored(to: before, "Undo Set Branch Tip did not restore main")
    }
}

final class Spike0598CreateBranchAndTagUITests: XCTestCase {
    @MainActor
    func testCreateBranchAndAddTagNameTheSelectedCommit() {
        let repo = GitRepo(path: HistoryFixture.path("refs"))
        let before = GitStateSnapshot(repo)
        let three = repo.oid("main~1")
        let root = repo.oid("main~3")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("refs")

        app.selectHistoryRow(subject: HistoryFixture.mainThreeSubject)
        app.chooseCommitMenuItem("Create Branch…")
        var sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no Create Branch sheet")
        let branchField = sheet.textFields.firstMatch
        branchField.click()
        branchField.typeText("made-here")
        sheet.buttons["Create"].click()
        XCTAssertTrue(repo.wait { repo.oid("refs/heads/made-here") == three }, "made-here was not created at “hist main three”")
        XCTAssertEqual(repo.headBranch(), "main", "Create Branch switched branches")
        app.keepScreenshot("0598-branch-created", in: self)
        app.chooseEditMenuItem("Undo New Branch")
        // Guide §11 decision 20: a restore deletes only refs its snapshot
        // recorded, so the branch Create Branch made survives its own Undo
        // (measured, the planner's second VM run). Everything else must be
        // back; the branch's removal is #0600's question.
        XCTAssertTrue(repo.wait { GitStateSnapshot(repo).removingRef("refs/heads/made-here") == before },
                      "Undo New Branch changed more than made-here:\n\(GitStateSnapshot(repo))")
        XCTExpectFailure("#0600: Undo New Branch leaves the branch it made (decision 20)") {
            XCTAssertEqual(repo.refOid("refs/heads/made-here"), "", "Undo New Branch left made-here")
        }
        let beforeTag = GitStateSnapshot(repo)

        app.selectHistoryRow(subject: HistoryFixture.rootSubject)
        app.chooseCommitMenuItem("Add Tag…")
        sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "no Add Tag sheet")
        let tagField = sheet.textFields.firstMatch
        tagField.click()
        tagField.typeText("v-made-here")
        sheet.buttons["Add Tag"].click()
        XCTAssertTrue(repo.wait { repo.oid("refs/tags/v-made-here") == root }, "v-made-here was not created at “hist root”")
        app.keepScreenshot("0598-tag-added", in: self)
        app.chooseEditMenuItem("Undo New Tag")
        XCTAssertTrue(repo.wait { GitStateSnapshot(repo).removingRef("refs/tags/v-made-here") == beforeTag },
                      "Undo New Tag changed more than v-made-here:\n\(GitStateSnapshot(repo))")
        XCTExpectFailure("#0600: Undo New Tag leaves the tag it made (decision 20)") {
            XCTAssertEqual(repo.refOid("refs/tags/v-made-here"), "", "Undo New Tag left v-made-here")
        }
    }
}
