// 0592MergeUITests.swift
//
// #0592: Merge into Current Branch, driven from the app's Commit menu and
// checked against git: the branch's file must be in HEAD's tree AND the
// working tree (Brennan's 2026-10-05 report: a merge commit "with no file
// change"); Edit ▸ Undo Merge gives back every ref and the clean tree. A
// conflicting merge shows the failure alert and the header's Abort, and
// Abort restores the pre-merge state.

import XCTest

final class Spike0592MergeFastForwardableUITests: XCTestCase {
    @MainActor
    func testMergingAFastForwardableBranchBringsItsFileIntoHeadAndUndoTakesItBack() {
        let repo = GitRepo(path: HistoryFixture.path("merge-ff"))
        let before = GitStateSnapshot(repo)
        let mainTip = repo.oid("main")
        let topic = repo.oid("ff-topic")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("merge-ff")
        app.selectHistoryRow(subject: HistoryFixture.ffSubject)
        app.chooseCommitMenuItem("Merge into Current Branch")

        XCTAssertTrue(repo.wait { repo.oid("main") != mainTip }, "main never moved: no merge happened")
        XCTAssertEqual(repo.headBranch(), "main")
        XCTAssertEqual(repo.parents(of: "main"), [mainTip, topic],
                       "HEAD is not a merge of the old main tip and ff-topic")
        XCTAssertTrue(repo.lsTree("main").contains("ff.txt"),
                      "the merge commit's tree lacks ff.txt: \(repo.lsTree("main"))")
        XCTAssertEqual(repo.worktreeFile("ff.txt"), "fast-forwardable",
                       "ff.txt is not in the working tree after the merge")
        XCTAssertEqual(repo.porcelain(), "", "the merge left the tree dirty")
        XCTAssertTrue(app.historyRows(containing: "Merge branch 'ff-topic'").firstMatch
            .waitForExistence(timeout: 30), "History never showed the merge commit")
        app.keepScreenshot("0592-ff-merged", in: self)

        app.chooseEditMenuItem("Undo Merge")
        repo.assertRestored(to: before, "Undo Merge did not restore the pre-merge refs, tree and status")
        XCTAssertNil(repo.worktreeFile("ff.txt"), "ff.txt survived Undo Merge")
        app.keepScreenshot("0592-ff-undone", in: self)
    }
}

final class Spike0592MergeDivergedUITests: XCTestCase {
    @MainActor
    func testATrueMergeHasBothParentsAndBothSidesFiles() {
        let repo = GitRepo(path: HistoryFixture.path("merge-true"))
        let before = GitStateSnapshot(repo)
        let mainTip = repo.oid("main")
        let topic = repo.oid("diverged-topic")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("merge-true")
        app.selectHistoryRow(subject: HistoryFixture.divergedTwoSubject)
        app.chooseCommitMenuItem("Merge into Current Branch")

        XCTAssertTrue(repo.wait { repo.oid("main") != mainTip }, "main never moved: no merge happened")
        XCTAssertEqual(repo.parents(of: "main"), [mainTip, topic])
        let tree = repo.lsTree("main")
        for path in ["diverged1.txt", "diverged2.txt", "main4.txt"] {
            XCTAssertTrue(tree.contains(path), "the merge's tree lacks \(path): \(tree)")
        }
        XCTAssertEqual(repo.worktreeFile("diverged2.txt"), "diverged two")
        XCTAssertEqual(repo.porcelain(), "")
        XCTAssertTrue(app.historyRows(containing: "Merge branch 'diverged-topic'").firstMatch
            .waitForExistence(timeout: 30), "History never showed the merge commit")
        app.keepScreenshot("0592-true-merged", in: self)

        app.chooseEditMenuItem("Undo Merge")
        repo.assertRestored(to: before, "Undo Merge did not restore the pre-merge state")
        app.keepScreenshot("0592-true-undone", in: self)
    }
}

final class Spike0592MergeConflictUITests: XCTestCase {
    @MainActor
    func testAConflictingMergeStopsWithTheConflictAndAbortRestores() {
        let repo = GitRepo(path: HistoryFixture.path("merge-conflict"))
        let before = GitStateSnapshot(repo)
        let app = XCUIApplication()
        app.launchWithHistoryFixture("merge-conflict")
        app.selectHistoryRow(subject: HistoryFixture.clashSubject)
        app.chooseCommitMenuItem("Merge into Current Branch")

        XCTAssertTrue(repo.wait { repo.isMidMerge() }, "no merge in progress: MERGE_HEAD never appeared")
        XCTAssertEqual(repo.conflictedPaths(), ["shared.txt"])
        let alert = app.staticTexts["Couldn’t Merge Branch"]
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "no “Couldn’t Merge Branch” alert")
        app.keepScreenshot("0592-conflict-alert", in: self)
        app.dismissAlert()

        let abort = app.windowButton("Abort")
        XCTAssertTrue(abort.waitForExistence(timeout: 30), "the header shows no Abort for the merge")
        app.keepScreenshot("0592-conflict-header", in: self)
        abort.click()
        let confirm = app.windowButton("Abort Merge")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no “Abort Merge” confirmation")
        confirm.click()

        // Abort is a journal undo, then `merge --abort` (ConflictHandoff
        // .runAbort): the refs and tree come back before MERGE_HEAD goes, so
        // wait for MERGE_HEAD to go first.
        XCTAssertTrue(repo.wait { !repo.isMidMerge() }, "Abort left MERGE_HEAD behind")
        repo.assertRestored(to: before, "Abort did not restore the pre-merge state")
        XCTAssertTrue(app.waitUntilDisappears(abort, timeout: 30), "the header still offers Abort")
        app.keepScreenshot("0592-conflict-aborted", in: self)
    }
}
