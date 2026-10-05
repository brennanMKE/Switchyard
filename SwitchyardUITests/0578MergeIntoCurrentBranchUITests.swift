// 0578MergeIntoCurrentBranchUITests.swift
//
// #0578: Brennan's 2026-10-05 report, driven through the app — select
// docs2's commit, Commit ▸ Merge into Current Branch — then asserted with
// git, not labels: HEAD is a merge of the old HEAD and docs2's tip, its tree
// and the working tree hold docs.md, the tree is clean, the Detail pane
// lists docs.md for the merge commit, and Edit ▸ Undo Merge puts every one
// of those back. One class per fixture shape: an app session opens a window
// on only two XCUITest launches (UITestSupport.swift), and the smoke test
// takes the first.

import XCTest

class MergeIntoCurrentBranchSpike: XCTestCase {
    /// The fixture shape, `ff` or `diverged`; each subclass names one.
    var shape: String { "" }

    @MainActor
    func mergeDocs2ThenUndo() {
        let repo = UITestMergeFixture.path(shape)
        let start = UITestGit.run(["rev-parse", "HEAD", UITestMergeFixture.mergedBranch], in: repo)
        XCTAssertEqual(start.status, 0, "the test runner could not run git: \(start.output)")
        XCTAssertEqual(start.lines.count, 2, "rev-parse printed \(start.output)")
        let before = start.lines.first ?? ""
        let docs2Tip = start.lines.last ?? ""

        let app = XCUIApplication()
        app.launchWithMergeFixture(shape)
        app.selectHistoryRow(subject: UITestMergeFixture.docsSubject)
        app.menuBars.menuBarItems["Commit"].click()
        let merge = app.menuBars.menuItems["Merge into Current Branch"]
        XCTAssertTrue(merge.waitForExistence(timeout: 10), "the Commit menu has no Merge into Current Branch")
        merge.click()
        let mergeRow = app.historyRows(containing: UITestMergeFixture.mergeSubject).firstMatch
        XCTAssertTrue(mergeRow.waitForExistence(timeout: 30), "Merge into Current Branch wrote no merge commit")

        // Git: a merge of the old HEAD and docs2's tip, holding docs.md.
        let parents = UITestGit.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo)
            .trimmed.split(separator: " ").map(String.init)
        XCTAssertEqual(parents.count, 3, "HEAD is not a two-parent merge: \(parents)")
        XCTAssertEqual(parents.dropFirst().first, before, "the merge's first parent is not the old HEAD")
        XCTAssertEqual(parents.last, docs2Tip, "the merge's second parent is not docs2's tip")
        XCTAssertTrue(
            UITestGit.run(["ls-tree", "-r", "--name-only", "HEAD"], in: repo).lines
                .contains(UITestMergeFixture.file),
            "the merge commit's tree has no docs.md")
        XCTAssertEqual(
            UITestGit.run(["diff", "--name-only", "HEAD^1", "HEAD"], in: repo).lines,
            [UITestMergeFixture.file], "the merge brought in something other than docs.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo)/\(UITestMergeFixture.file)"),
                      "docs.md is not in the working tree")
        XCTAssertEqual(UITestGit.run(["status", "--porcelain"], in: repo).output, "",
                       "the merge left the working tree dirty")

        // The window: the merge commit is selected and lists docs.md.
        let listed = app.staticTexts.matching(identifier: "commit-file-\(UITestMergeFixture.file)").firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 30),
                      "the Detail pane lists no docs.md for the merge commit — the report's “no file change”")
        let merged = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        merged.name = "0578-\(shape)-merged"
        merged.lifetime = .keepAlways
        add(merged)

        // Undo: one journal step back to the pre-merge state.
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Merge"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Merge")
        undo.click()
        XCTAssertTrue(app.waitUntilDisappears(mergeRow, timeout: 30), "Undo Merge left the merge commit in History")
        XCTAssertEqual(UITestGit.run(["rev-parse", "HEAD"], in: repo).trimmed, before,
                       "Undo Merge did not put HEAD back")
        XCTAssertEqual(UITestGit.run(["rev-parse", UITestMergeFixture.mergedBranch], in: repo).trimmed, docs2Tip,
                       "Undo Merge moved docs2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(repo)/\(UITestMergeFixture.file)"),
                       "Undo Merge left docs.md in the working tree")
        XCTAssertEqual(UITestGit.run(["status", "--porcelain"], in: repo).output, "",
                       "Undo Merge left the working tree dirty")
        let undone = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        undone.name = "0578-\(shape)-undone"
        undone.lifetime = .keepAlways
        add(undone)
    }
}

final class Spike0578MergeFastForwardableUITests: MergeIntoCurrentBranchSpike {
    override var shape: String { "ff" }

    @MainActor
    func testMergeIntoCurrentBranchBringsInDocsAndUndoes() { mergeDocs2ThenUndo() }
}

final class Spike0578MergeDivergedUITests: MergeIntoCurrentBranchSpike {
    override var shape: String { "diverged" }

    @MainActor
    func testMergeIntoCurrentBranchBringsInDocsAndUndoes() { mergeDocs2ThenUndo() }
}
