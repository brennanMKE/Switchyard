// 0568ComposerUITests.swift
//
// #0568: the commit composer (guide §11 decision 45) on the fixture
// scripts/uitest-fixtures/make-composer-fixture.sh builds. Two classes, one
// per clone, for the launch-count quirk in UITestSupport.swift: the run
// script gives each its own `run_spike_if_selected 0568 …` line.

import XCTest

/// The fixture `make-composer-fixture.sh` generates inside the guest.
enum UITestComposerFixture {
    static let repositoryPath = "/Users/admin/uitest-composer-repo"
    /// commit.template's text with its comment line stripped.
    static let template = "Composer template subject\n\nRefs:"
    static let staged = "staged.txt"
    static let ann = "Ann Lee <ann@example.com>"
    static let bob = "Bob Quinn <bob@example.com>"
}

extension XCUIApplication {
    @MainActor
    func launchWithComposerFixture() {
        launchArguments = ["-uiTestRepository", UITestComposerFixture.repositoryPath, "-uiTestRealSurfaces"]
        launch()
        XCTAssertTrue(windows.firstMatch.waitForExistence(timeout: 60),
                      "The app launched but opened no window within 60 s")
    }

    /// The message editor's text.
    @MainActor
    var commitMessageText: String { textViews["commit-message"].value as? String ?? "" }

    /// Waits up to `timeout` for the message editor to hold `text`.
    @MainActor
    func waitForCommitMessage(_ text: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if commitMessageText == text { return true }
            usleep(200_000)
        }
        return commitMessageText == text
    }
}

@MainActor
private func attach(_ test: XCTestCase, _ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    test.add(shot)
}

/// The template starts the editor, the guide counts the subject, Co-Author
/// adds a trailer, ⌘↩ commits, and Recent Messages brings the message back.
final class Spike0568ComposerUITests: XCTestCase {
    @MainActor
    func testComposerWritesAndCommits() {
        let app = XCUIApplication()
        app.launchWithComposerFixture()
        XCTAssertTrue(app.changesRow(UITestComposerFixture.staged, staged: true).waitForExistence(timeout: 30),
                      "staged.txt is not listed as staged")

        // commit.template, comment stripped; Commit waits for an edit.
        XCTAssertTrue(app.waitForCommitMessage(UITestComposerFixture.template),
                      "the editor did not start from commit.template: \(app.commitMessageText.debugDescription)")
        XCTAssertFalse(app.buttons["commit-button"].isEnabled, "Commit is enabled on the unedited template")
        let guide = app.staticTexts["message-guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 10), "no guide line under the editor")
        XCTAssertEqual(guide.value as? String, "Subject 25/50")
        attach(self, app, "composer-template")

        // A subject past 50: the guide says so, and Commit is still enabled.
        let editor = app.textViews["commit-message"]
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        let subject = "0568 a subject that runs on past the fifty character guide"
        editor.typeText(subject)
        XCTAssertTrue(app.waitForCommitMessage(subject))
        XCTAssertEqual(guide.value as? String, "Subject 58/50")
        XCTAssertTrue(app.buttons["commit-button"].isEnabled, "a long subject must warn, not block")

        // Co-Author offers Ann (an author) and Bob (credited in a trailer).
        let coAuthor = app.menuButtons["co-author-menu"]
        XCTAssertTrue(coAuthor.waitForExistence(timeout: 10), "no Co-Author menu")
        coAuthor.click()
        XCTAssertTrue(app.menuItems[UITestComposerFixture.bob].waitForExistence(timeout: 10),
                      "Co-Author does not offer Bob, credited by a trailer")
        attach(self, app, "composer-co-author-menu")
        app.menuItems[UITestComposerFixture.ann].click()
        let credited = subject + "\n\nCo-authored-by: " + UITestComposerFixture.ann + "\n"
        XCTAssertTrue(app.waitForCommitMessage(credited),
                      "Co-Author did not add Ann's trailer: \(app.commitMessageText.debugDescription)")
        attach(self, app, "composer-credited")

        // ⌘↩ commits; the editor starts from the template again.
        editor.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.historyRows(containing: subject).firstMatch.waitForExistence(timeout: 30),
                      "the commit is not in History")
        XCTAssertTrue(app.waitForCommitMessage(UITestComposerFixture.template),
                      "after the commit the editor did not start from the template again")

        // Recent Messages brings the whole message back.
        let recent = app.menuButtons["recent-messages-menu"]
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "no Recent Messages menu")
        recent.click()
        let item = app.menuItems[subject]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Recent Messages does not offer the commit just made")
        attach(self, app, "composer-recent-menu")
        item.click()
        XCTAssertTrue(app.waitForCommitMessage(subject + "\n\nCo-authored-by: " + UITestComposerFixture.ann),
                      "Recent Messages did not put the message back: \(app.commitMessageText.debugDescription)")
        attach(self, app, "composer-reused")
    }
}

/// A draft left in the editor is there again when the repository is opened
/// in a new window.
final class Spike0568DraftKeptUITests: XCTestCase {
    @MainActor
    func testDraftSurvivesClosingTheWindow() {
        let app = XCUIApplication()
        app.launchWithComposerFixture()
        XCTAssertTrue(app.waitForCommitMessage(UITestComposerFixture.template),
                      "the editor did not start from commit.template")
        let editor = app.textViews["commit-message"]
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("0568 a draft worth keeping")
        XCTAssertTrue(app.waitForCommitMessage("0568 a draft worth keeping"))

        app.typeKey("w", modifierFlags: .command)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.windows.count > 0 { usleep(200_000) }
        XCTAssertEqual(app.windows.count, 0, "⌘W did not close the window")

        app.openThroughFilePanel(UITestComposerFixture.repositoryPath, test: self)
        XCTAssertTrue(app.waitForCommitMessage("0568 a draft worth keeping", timeout: 30),
                      "the reopened window lost the draft: \(app.commitMessageText.debugDescription)")
        attach(self, app, "composer-draft-kept")
    }
}
