import XCTest

/// #0520: a file's history and blame in the Detail pane (guide §11 decision
/// 39). The Changes view's Show History lists the commits that changed
/// notes.txt, the one before its rename included; Blame shows each line's
/// commit and the uncommitted line; clicking a line's commit selects it in
/// History with the inspector still open, and closing the inspector shows
/// that commit. From the commit's changed files, Blame reads the file at
/// that commit.
final class Spike0520FileHistoryBlameUITests: XCTestCase {
    @MainActor
    func testShowHistoryBlameAndSelectACommit() {
        let app = XCUIApplication()
        app.launchWithBlameFixture()
        let window = app.windows.firstMatch

        // Show History from the Changes view's row.
        let row = app.changesRow(UITestBlameFixture.file, staged: false)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no Changes row for notes.txt")
        row.rightClick()
        let showHistory = app.menuItems["Show History"]
        XCTAssertTrue(showHistory.waitForExistence(timeout: 10), "the row's menu has no Show History")
        showHistory.click()

        let path = app.fileInspectorPath()
        XCTAssertTrue(path.waitForExistence(timeout: 30), "Show History opened no inspector")
        XCTAssertTrue(app.text(containing: "Renamed from \(UITestBlameFixture.oldName)")
            .waitForExistence(timeout: 30), "the history did not follow the rename")
        let history = XCTAttachment(screenshot: window.screenshot())
        history.name = "file-history"
        history.lifetime = .keepAlways
        add(history)

        // Blame: the uncommitted line, and a link per run of lines.
        let blameSegment = window.radioButtons["Blame"]
        XCTAssertTrue(blameSegment.waitForExistence(timeout: 10), "no Blame segment")
        blameSegment.click()
        XCTAssertTrue(app.text(containing: "Not Committed Yet").waitForExistence(timeout: 30),
                      "the working-tree blame shows no uncommitted line")
        // A `.link`-style button is not always a `Button` to XCUI; match by
        // identifier across element types.
        let firstLink = window.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'blame-commit-'")).firstMatch
        XCTAssertTrue(firstLink.waitForExistence(timeout: 30), "the blame has no commit links")
        let blame = XCTAttachment(screenshot: window.screenshot())
        blame.name = "blame"
        blame.lifetime = .keepAlways
        add(blame)

        // Line 1 is the first commit's. Clicking it selects that commit in
        // History and leaves the inspector open; closing it shows the commit.
        firstLink.click()
        let node = app.historyRows(containing: UITestBlameFixture.firstSubject).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 30), "no History row for the first commit")
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: node)
        wait(for: [selected], timeout: 30)
        XCTAssertTrue(path.exists, "clicking a commit closed the inspector")
        app.buttons["file-inspector-close"].click()
        let headline = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@",
            UITestBlameFixture.firstSubject, UITestBlameFixture.firstSubject)).firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 30),
                      "closing the inspector did not show the selected commit")

        // Blame from the commit's changed files: the file as it was then.
        let changedFile = app.staticTexts["commit-file-\(UITestBlameFixture.oldName)"]
        XCTAssertTrue(changedFile.waitForExistence(timeout: 30), "the commit lists no notes-old.txt")
        changedFile.rightClick()
        let blameItem = app.menuItems["Blame"]
        XCTAssertTrue(blameItem.waitForExistence(timeout: 10), "the file's menu has no Blame")
        blameItem.click()
        XCTAssertTrue(app.text(containing: "At ").waitForExistence(timeout: 30),
                      "the inspector does not say which commit it reads")
        XCTAssertTrue(app.text(containing: "bravo").waitForExistence(timeout: 30),
                      "the blame at the first commit does not show its own line")
        XCTAssertFalse(app.text(containing: "Not Committed Yet").exists,
                       "a blame at a commit shows an uncommitted line")
        let atCommit = XCTAttachment(screenshot: window.screenshot())
        atCommit.name = "blame-at-commit"
        atCommit.lifetime = .keepAlways
        add(atCommit)
    }
}
