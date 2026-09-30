import XCTest

/// #0533: the remote-management fixture
/// (scripts/uitest-fixtures/make-remotes-fixture.sh) — keep the two in sync.
enum UITestRemotesFixture {
    static let directory = "/Users/admin/uitest-remotes"
    static let repositoryPath = directory + "/repo"
    static let originURL = directory + "/origin.git"
    static let backupURL = directory + "/backup.git"
    static let branch = "remotes-main"
    static let stale = "origin/stale-topic"
}

/// #0533: remote management from the sidebar (guide §11 decision 41). The
/// Remotes section lists each remote above its branches; Prune “origin”
/// deletes a stale remote-tracking branch and Edit ▸ Undo Prune brings it
/// back; Add Remote… adds and fetches a second remote; Rename Remote…
/// renames it and Undo says it can't; Edit URL… re-points it; Remove
/// Remote… says what goes with it and removes it.
final class Spike0533RemoteManagementUITests: XCTestCase {
    @MainActor
    func testAddRenameEditRemoveAndPrune() {
        let app = XCUIApplication()
        app.launchWithRemoteFixture(UITestRemotesFixture.repositoryPath)
        let window = app.windows.firstMatch
        XCTAssertTrue(app.header(beginningWith: "On branch \(UITestRemotesFixture.branch)")
                        .waitForExistence(timeout: 30), "the header does not show remotes-main")

        // Remotes starts collapsed (#0371): open it with its disclosure (#0386's way).
        let sidebar = app.outlines.matching(
            NSPredicate(format: "label == 'Sidebar' OR identifier == 'Sidebar'")).firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the sidebar Outline never rendered")
        let remotesHeader = sidebar.cells.containing(NSPredicate(format: "label == 'Remotes'")).firstMatch
        XCTAssertTrue(remotesHeader.waitForExistence(timeout: 10), "no Remotes header")
        remotesHeader.hover()
        remotesHeader.disclosureTriangles.firstMatch.tap()
        let origin = app.sidebarRow(named: "origin")
        XCTAssertTrue(origin.waitForExistence(timeout: 10), "the Remotes section lists no origin row")
        let stale = app.sidebarRow(named: UITestRemotesFixture.stale)
        XCTAssertTrue(stale.waitForExistence(timeout: 10), "origin/stale-topic is not listed")

        // Prune, then Undo Prune.
        menu(on: origin, app: app, item: "Prune “origin”")
        XCTAssertTrue(app.waitUntilDisappears(stale, timeout: 30), "Prune did not delete origin/stale-topic")
        app.menuBars.menuBarItems["Edit"].click()
        let undoPrune = app.menuBars.menuItems["Undo Prune"]
        XCTAssertTrue(undoPrune.waitForExistence(timeout: 10), "the Edit menu offers no Undo Prune")
        undoPrune.click()
        XCTAssertTrue(stale.waitForExistence(timeout: 30), "Undo Prune did not bring origin/stale-topic back")

        // Add Remote… with Fetch its branches now (on by default).
        menu(on: origin, app: app, item: "Add Remote…")
        fill("remote-name", with: "backup", app: app)
        fill("remote-url", with: UITestRemotesFixture.backupURL, app: app)
        let added = XCTAttachment(screenshot: window.screenshot())
        added.name = "add-remote-sheet"
        added.lifetime = .keepAlways
        add(added)
        app.buttons["remote-confirm"].click()
        let backup = app.sidebarRow(named: "backup")
        XCTAssertTrue(backup.waitForExistence(timeout: 30), "Add Remote… listed no backup row")
        XCTAssertTrue(app.sidebarRow(named: "backup/backup-only").waitForExistence(timeout: 30),
                      "Add Remote… did not fetch backup's branch")

        // Rename Remote…: the branch follows, and Undo says it can't.
        menu(on: backup, app: app, item: "Rename Remote…")
        fill("remote-name", with: "mirror", app: app, replacing: true)
        app.buttons["remote-confirm"].click()
        let mirror = app.sidebarRow(named: "mirror")
        XCTAssertTrue(mirror.waitForExistence(timeout: 30), "Rename Remote… listed no mirror row")
        XCTAssertTrue(app.sidebarRow(named: "mirror/backup-only").waitForExistence(timeout: 30),
                      "the remote-tracking branch did not follow the rename")
        XCTAssertTrue(app.waitUntilDisappears(backup, timeout: 10), "the backup row is still listed")
        app.menuBars.menuBarItems["Edit"].click()
        let cantUndo = app.menuBars.menuItems["Can’t Undo Rename Remote"]
        XCTAssertTrue(cantUndo.waitForExistence(timeout: 10), "the Edit menu does not say Can’t Undo Rename Remote")
        XCTAssertFalse(cantUndo.isEnabled, "Can’t Undo Rename Remote is enabled")
        app.typeKey(.escape, modifierFlags: [])

        // Edit URL…: mirror now fetches from origin.git, so its URL line reads that path twice over.
        menu(on: mirror, app: app, item: "Edit URL…")
        fill("remote-url", with: UITestRemotesFixture.originURL, app: app, replacing: true)
        app.buttons["remote-confirm"].click()
        let originURLs = app.staticTexts.matching(NSPredicate(
            format: "value == %@ OR label == %@", UITestRemotesFixture.originURL, UITestRemotesFixture.originURL))
        let deadline = Date().addingTimeInterval(30)
        while originURLs.count < 2 && Date() < deadline { usleep(200_000) }
        XCTAssertEqual(originURLs.count, 2, "Edit URL… did not re-point mirror at origin.git")

        // Remove Remote… says what goes with it.
        menu(on: mirror, app: app, item: "Remove Remote…")
        let removeButton = window.buttons.matching(
            NSPredicate(format: "label == 'Remove Remote' OR title == 'Remove Remote'")).firstMatch
        XCTAssertTrue(removeButton.waitForExistence(timeout: 10), "Remove Remote… asked nothing")
        XCTAssertTrue(app.text(containing: "mirror/backup-only is deleted").waitForExistence(timeout: 10),
                      "the confirmation does not name the remote-tracking branch it deletes")
        let asked = XCTAttachment(screenshot: window.screenshot())
        asked.name = "remove-remote-confirmation"
        asked.lifetime = .keepAlways
        add(asked)
        removeButton.click()
        XCTAssertTrue(app.waitUntilDisappears(mirror, timeout: 30), "Remove Remote… left the mirror row")
        XCTAssertTrue(app.waitUntilDisappears(app.sidebarRow(named: "mirror/backup-only"), timeout: 30),
                      "Remove Remote… left its remote-tracking branch")
        let removed = XCTAttachment(screenshot: window.screenshot())
        removed.name = "removed"
        removed.lifetime = .keepAlways
        add(removed)
    }

    /// Right-clicks `row` and chooses `item` from its context menu.
    @MainActor
    private func menu(on row: XCUIElement, app: XCUIApplication, item: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        row.rightClick()
        let entry = app.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "the row's menu has no \(item)", file: file, line: line)
        entry.click()
    }

    /// Types `text` into the sheet field `identifier`, first selecting what
    /// is there when `replacing`.
    @MainActor
    private func fill(_ identifier: String, with text: String, app: XCUIApplication, replacing: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the sheet has no \(identifier) field", file: file, line: line)
        field.click()
        if replacing { app.typeKey("a", modifierFlags: .command) }
        field.typeText(text)
    }
}
