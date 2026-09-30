import XCTest

/// #0525: the History filter's scopes (guide §11 decision 40), on #0520's
/// blame fixture. "notes" is in no commit's message, author or branch name,
/// but three commits changed a path containing it (notes-old.txt added, its
/// rename to notes.txt, the edit). "charlie" is text only the first commit
/// added — the rename moved it without adding it — and ⌘G selects that
/// commit.
final class Spike0525HistorySearchUITests: XCTestCase {
    @MainActor
    func testPathsAndContentScopesFindCommits() {
        let app = XCUIApplication()
        app.launchWithBlameFixture()
        let window = app.windows.firstMatch
        let filter = app.sidebarFilterField()
        XCTAssertTrue(filter.waitForExistence(timeout: 30), "no filter field")
        filter.click()
        filter.typeText("notes")

        // Commits (the default): nothing in a message, author or ref.
        XCTAssertTrue(app.matchCount("0 matches").waitForExistence(timeout: 10),
                      "the Commits scope does not say 0 matches for \"notes\"")

        // Paths: the three commits that changed notes-old.txt or notes.txt.
        let paths = window.radioButtons["Paths"]
        XCTAssertTrue(paths.waitForExistence(timeout: 10), "the match bar has no Paths scope")
        paths.click()
        XCTAssertTrue(app.matchCount("3 matches").waitForExistence(timeout: 30),
                      "the Paths scope does not find the three commits that changed notes")
        let pathShot = XCTAttachment(screenshot: window.screenshot())
        pathShot.name = "history-search-paths"
        pathShot.lifetime = .keepAlways
        add(pathShot)

        // Content: "charlie" was added once; the rename is not a match.
        window.radioButtons["Content"].click()
        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        filter.typeText("charlie")
        XCTAssertTrue(app.matchCount("1 match").waitForExistence(timeout: 30),
                      "the Content scope does not find the one commit that added charlie")
        app.typeKey("g", modifierFlags: .command)
        let headline = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@",
            UITestBlameFixture.firstSubject, UITestBlameFixture.firstSubject)).firstMatch
        XCTAssertTrue(headline.waitForExistence(timeout: 10),
                      "⌘G did not select the commit that added charlie")
        let contentShot = XCTAttachment(screenshot: window.screenshot())
        contentShot.name = "history-search-content"
        contentShot.lifetime = .keepAlways
        add(contentShot)
    }
}

extension XCUIApplication {
    /// The match bar's count (#0402, #0524), by its exact text.
    @MainActor
    func matchCount(_ text: String) -> XCUIElement {
        staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
    }
}
