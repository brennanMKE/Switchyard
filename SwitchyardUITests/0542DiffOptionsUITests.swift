import XCTest

/// #0542: the diff options fixture
/// (scripts/uitest-fixtures/make-diffopts-fixture.sh) — keep the two in sync.
enum UITestDiffOptionsFixture {
    static let repositoryPath = "/Users/admin/uitest-diffopts-repo"
    /// Re-indented and edited in the working tree.
    static let code = "code.txt"
    /// Only whitespace changed, in the working tree and in `commitSubject`.
    static let spaces = "spaces.txt"
    /// notes.txt edited, spaces.txt given trailing spaces.
    static let commitSubject = "diffopts whitespace commit"
}

/// #0542: diff options (guide §11 decision 42). In the Changes view, Ignore
/// Whitespace hides the re-indented line, turns Stage Hunk off and says so,
/// and notes a whitespace-only file; Whole File shows every line; Reset
/// turns staging back on and Stage Hunk stages. In the commit changes
/// window, a changed word is highlighted, and Ignore Whitespace notes the
/// whitespace-only file.
final class Spike0542DiffOptionsUITests: XCTestCase {
    @MainActor
    func testIgnoreWhitespaceContextAndWordHighlights() {
        let app = XCUIApplication()
        app.launchWithRemoteFixture(UITestDiffOptionsFixture.repositoryPath)
        let window = app.windows.firstMatch

        let code = app.changesRow(UITestDiffOptionsFixture.code, staged: false)
        XCTAssertTrue(code.waitForExistence(timeout: 30), "code.txt is not listed")
        code.click()
        let reindented = app.staticTexts["-foo();"]
        XCTAssertTrue(reindented.waitForExistence(timeout: 30), "the diff does not show the re-indent")
        XCTAssertTrue(app.staticTexts["+total = compute(10);"].exists, "the diff does not show the edit")
        let stageHunk = app.buttons.matching(NSPredicate(format: "title == 'Stage Hunk' OR label == 'Stage Hunk'"))
            .firstMatch
        XCTAssertTrue(stageHunk.waitForExistence(timeout: 10))
        XCTAssertTrue(stageHunk.isEnabled, "Stage Hunk is off with the standard options")

        // Ignore Whitespace: the re-indent is context, staging is off, and the bar says so.
        choose("Ignore Whitespace", app: app)
        XCTAssertTrue(app.waitUntilDisappears(reindented, timeout: 30), "-foo(); is still shown")
        XCTAssertTrue(app.staticTexts["+if ready {"].exists, "the new line is gone too")
        XCTAssertTrue(app.staticTexts.matching(identifier: "diff-options-staging-note").firstMatch.exists,
                      "the bar does not say hunk staging is off")
        XCTAssertFalse(stageHunk.isEnabled, "Stage Hunk is on while whitespace is ignored")
        let ignored = XCTAttachment(screenshot: window.screenshot())
        ignored.name = "whitespace-ignored"
        ignored.lifetime = .keepAlways
        add(ignored)

        // A file whose only change is whitespace has nothing left to show.
        app.changesRow(UITestDiffOptionsFixture.spaces, staged: false).click()
        XCTAssertTrue(app.text(containing: "Only whitespace changed in spaces.txt").waitForExistence(timeout: 30),
                      "spaces.txt is not noted as whitespace-only")

        // Whole File: code.txt is one hunk of every line.
        code.click()
        choose("Whole File", app: app)
        XCTAssertTrue(app.staticTexts["@@ -1,30 +1,32 @@"].waitForExistence(timeout: 30),
                      "Whole File did not show the file as one hunk")

        // Reset: staging is back, and Stage Hunk stages.
        let reset = app.buttons.matching(identifier: "diff-options-reset").firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "no Reset in the bar")
        reset.click()
        XCTAssertTrue(reindented.waitForExistence(timeout: 30), "Reset did not bring back the plain diff")
        let deadline = Date().addingTimeInterval(30)
        while !stageHunk.isEnabled && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(stageHunk.isEnabled, "Stage Hunk is still off after Reset")
        stageHunk.click()
        XCTAssertTrue(app.changesRow(UITestDiffOptionsFixture.code, staged: true).waitForExistence(timeout: 30),
                      "Stage Hunk staged nothing after Reset")

        // The commit changes window: Ignore Whitespace notes spaces.txt.
        let row = app.historyRows(containing: UITestDiffOptionsFixture.commitSubject).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no History row for the whitespace commit")
        row.doubleClick()
        let changes = app.windows.matching(NSPredicate(
            format: "title CONTAINS %@", UITestDiffOptionsFixture.commitSubject)).firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 30), "double-clicking the row opened no changes window")
        XCTAssertTrue(changes.staticTexts["-keep"].waitForExistence(timeout: 30),
                      "the window does not show spaces.txt's change")
        // notes.txt's pair shows its changed word ("edited") on the stronger tint.
        let words = XCTAttachment(screenshot: changes.screenshot())
        words.name = "word-highlights"
        words.lifetime = .keepAlways
        add(words)
        choose("Ignore Whitespace", app: app, in: changes)
        XCTAssertTrue(changes.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@",
            "Only whitespace changed in spaces.txt", "Only whitespace changed in spaces.txt"))
            .firstMatch.waitForExistence(timeout: 30), "the window does not note spaces.txt")
        XCTAssertTrue(changes.staticTexts["+alpha edited"].exists, "notes.txt's change is gone too")
        let window2 = XCTAttachment(screenshot: changes.screenshot())
        window2.name = "commit-window-whitespace-ignored"
        window2.lifetime = .keepAlways
        add(window2)
    }

    /// Opens the Diff Options menu — in `scope`, the front window when
    /// `nil` — and chooses `item`.
    @MainActor
    private func choose(_ item: String, app: XCUIApplication, in scope: XCUIElement? = nil,
                        file: StaticString = #filePath, line: UInt = #line) {
        let root = scope ?? app.windows.firstMatch
        let menu = root.descendants(matching: .any).matching(identifier: "diff-options").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no Diff Options menu", file: file, line: line)
        menu.click()
        let entry = app.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the menu has no \(item)", file: file, line: line)
        entry.click()
    }
}
