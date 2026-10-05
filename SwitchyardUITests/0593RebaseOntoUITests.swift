// 0593RebaseOntoUITests.swift
//
// #0593: Rebase onto Here from the Commit menu — a clean rebase replays the
// branch's two commits onto the selected commit; a conflicting one stops
// with the alert and the header's Abort, and Abort puts the branch back.

import XCTest

final class Spike0593RebaseOntoUITests: XCTestCase {
    @MainActor
    func testRebaseOntoReplaysTheBranchAndUndoRestoresIt() {
        let repo = GitRepo(path: HistoryFixture.path("rebase"))
        let before = GitStateSnapshot(repo)
        let topic = repo.oid("rebase-topic")
        let mainTip = repo.oid("main")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("rebase")
        app.selectHistoryRow(subject: HistoryFixture.mainTipSubject)
        app.chooseCommitMenuItem("Rebase onto Here")

        XCTAssertTrue(repo.wait { repo.oid("rebase-topic") != topic && repo.headBranch() == "rebase-topic" }, "rebase-topic never moved")
        XCTAssertEqual(repo.headBranch(), "rebase-topic")
        XCTAssertEqual(Array(repo.subjects("rebase-topic").prefix(3)),
                       [HistoryFixture.rebaseTwoSubject, HistoryFixture.rebaseOneSubject,
                        HistoryFixture.mainTipSubject])
        XCTAssertEqual(repo.oid("rebase-topic~2"), mainTip, "the replay is not on main's tip")
        let tree = repo.lsTree("rebase-topic")
        for path in ["rebase1.txt", "rebase2.txt", "main4.txt"] {
            XCTAssertTrue(tree.contains(path), "the rebased tip lacks \(path): \(tree)")
        }
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0593-rebased", in: self)

        app.chooseEditMenuItem("Undo Rebase")
        repo.assertRestored(to: before, "Undo Rebase did not restore rebase-topic")
        app.keepScreenshot("0593-undone", in: self)
    }
}

final class Spike0593RebaseConflictUITests: XCTestCase {
    @MainActor
    func testAConflictingRebaseStopsAndAbortRestoresTheBranch() {
        let repo = GitRepo(path: HistoryFixture.path("rebase-conflict"))
        let before = GitStateSnapshot(repo)
        let app = XCUIApplication()
        app.launchWithHistoryFixture("rebase-conflict")
        app.selectHistoryRow(subject: HistoryFixture.mainTipSubject)
        app.chooseCommitMenuItem("Rebase onto Here")

        XCTAssertTrue(repo.wait { !repo.conflictedPaths().isEmpty }, "the rebase never stopped on a conflict")
        XCTAssertEqual(repo.conflictedPaths(), ["shared.txt"])
        let alert = app.staticTexts["Couldn’t Rebase Branch"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "no “Couldn’t Rebase Branch” alert")
        app.keepScreenshot("0593-conflict-alert", in: self)
        app.dismissAlert()

        let abort = app.windowButton("Abort")
        XCTAssertTrue(abort.waitForExistence(timeout: 30), "the header shows no Abort for the rebase")
        app.keepScreenshot("0593-conflict-header", in: self)
        abort.click()
        let confirm = app.windowButton("Abort Cherry-pick")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no “Abort Cherry-pick” confirmation")
        confirm.click()

        // Abort is a journal undo, then `cherry-pick --abort`: wait for the
        // pick state to go before comparing the snapshot.
        XCTAssertTrue(repo.wait { !repo.isMidCherryPick() }, "Abort left the cherry-pick in progress")
        repo.assertRestored(to: before, "Abort did not restore clash-topic")
        app.keepScreenshot("0593-conflict-aborted", in: self)
    }
}
