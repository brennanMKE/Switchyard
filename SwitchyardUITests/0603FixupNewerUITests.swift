// 0603FixupNewerUITests.swift
//
// #0603 (guide §11 decision 48): Commit ▸ Fixup Newer Commits into This on
// the commit with the good message folds the three "wip" commits above it
// into it — Brennan's workflow — and Edit ▸ Undo Fixup Newer Commits puts
// the branch back. The assertions read git itself: the fixture is the
// `fixup-newer` copy of scripts/uitest-fixtures/make-history-ops-fixture.sh.

import XCTest

final class Spike0603FixupNewerUITests: XCTestCase {
    @MainActor
    func testFixupNewerFoldsTheWipCommitsIntoTheGoodOne() {
        let repo = GitRepo(path: HistoryFixture.path("fixup-newer"))
        let before = GitStateSnapshot(repo)
        let beforeGraph = repo.graph("wip")
        XCTAssertEqual(repo.headBranch(), "wip", "fixture drifted")
        XCTAssertEqual(Array(repo.subjects("wip").prefix(5)), [
            HistoryFixture.wipSubject, HistoryFixture.wipSubject, HistoryFixture.wipSubject,
            HistoryFixture.wipGood, HistoryFixture.mainTipSubject,
        ], "fixture drifted")
        let tip = repo.oid("wip")
        let good = repo.oid("wip~3")
        let goodAuthor = repo.git("log", "-1", "--format=%an|%ae|%ad", "--date=raw", good)
        let base = repo.oid("main")
        let tipTree = repo.treeOid("wip")

        let app = XCUIApplication()
        app.launchWithHistoryFixture("fixup-newer")
        // The branch map folds a quiet run (decision 29, #0427): open it if
        // the good commit sits inside one.
        if !app.historyRows(containing: HistoryFixture.wipGood).firstMatch
            .waitForExistence(timeout: 15) {
            let fold = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@", "Folded ")).firstMatch
            if fold.waitForExistence(timeout: 10) { fold.click() }
        }
        app.selectHistoryRow(subject: HistoryFixture.wipGood)
        app.chooseCommitMenuItem("Fixup Newer Commits into This")

        XCTAssertTrue(
            repo.wait { repo.oid("wip") != tip && repo.headBranch() == "wip" },
            "wip never moved — before:\n\(beforeGraph)\nafter:\n\(repo.graph("wip"))")
        XCTAssertFalse(app.staticTexts["Couldn’t Fixup Newer Commits"].exists, "the fold failed")
        XCTAssertEqual(repo.parents(of: "wip"), [base],
                       "the wips are not folded onto “hist main tip”:\n\(repo.graph("wip"))")
        XCTAssertEqual(repo.message(of: "wip"), HistoryFixture.wipGoodMessage,
                       "the good commit's message was not kept")
        XCTAssertEqual(repo.treeOid("wip"), tipTree, "the fold lost a wip change")
        XCTAssertEqual(repo.fileContents(at: "wip.txt", rev: "wip"), "draft 3")
        XCTAssertEqual(repo.git("log", "-1", "--format=%an|%ae|%ad", "--date=raw", "wip"),
                       goodAuthor, "the good commit's author and date were not kept")
        XCTAssertEqual(repo.oid("main"), base, "main moved")
        XCTAssertEqual(repo.porcelain(), "")
        app.keepScreenshot("0603-folded", in: self)

        app.chooseEditMenuItem("Undo Fixup Newer Commits")
        repo.assertRestored(to: before, "Undo Fixup Newer Commits did not restore wip")
        XCTAssertEqual(repo.oid("wip~3"), good)
        app.keepScreenshot("0603-undone", in: self)
    }
}
