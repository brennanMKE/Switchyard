// 0574HeaderAndDiffLayoutUITests.swift
//
// #0574: at the 900 pt minimum width the hunk buttons stay on one line, and
// a detached HEAD shows its oid once, not twice.

import XCTest

final class Spike0574HeaderAndDiffLayoutUITests: XCTestCase {
    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Drags the window's bottom-right corner to make it `width` wide
    /// (it cannot go below `PaneLayout.windowMinWidth`, 900 pt).
    @MainActor
    private func resize(_ app: XCUIApplication, width: CGFloat) {
        let window = app.windows.firstMatch
        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width - 3, dy: frame.height - 3))
        corner.press(forDuration: 0.6, thenDragTo: corner.withOffset(CGVector(dx: width - frame.width, dy: 0)))
        usleep(800_000)
    }

    @MainActor
    func testTheHeaderAndHunkButtonsFitAtTheMinimumWidth() {
        let app = XCUIApplication()
        app.launchWithSwitchFixture()
        let window = app.windows.firstMatch
        let notes = app.changesRow("notes.txt", staged: false)
        XCTAssertTrue(notes.waitForExistence(timeout: 30), "notes.txt is not listed")
        resize(app, width: 900)
        XCTAssertEqual(window.frame.width, 900, accuracy: 1, "the window did not go to 900 pt")

        // The hunk buttons: one line each, so both are the same height.
        notes.click()
        let discard = window.buttons.matching(NSPredicate(
            format: "title == 'Discard Hunk…' OR label == 'Discard Hunk…'")).firstMatch
        let stage = window.buttons.matching(NSPredicate(
            format: "title == 'Stage Hunk' OR label == 'Stage Hunk'")).firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 30), "no Discard Hunk… button")
        XCTAssertTrue(stage.exists, "no Stage Hunk button")
        XCTAssertEqual(discard.frame.height, stage.frame.height, accuracy: 1,
                       "Discard Hunk… wrapped onto two lines at 900 pt")
        shot(app, "0574-hunk-buttons-900")

        // Detached: the oid once, in the tracking line.
        let base = app.historyRows(containing: UITestSwitchFixture.baseSubject).firstMatch
        XCTAssertTrue(base.waitForExistence(timeout: 30), "no row for the base commit")
        base.tap()
        app.menuBars.menuBarItems["Commit"].click()
        app.menuBars.menuItems["Check Out (Detached)"].click()
        let detached = app.header(beginningWith: "Detached HEAD at ")
        XCTAssertTrue(detached.waitForExistence(timeout: 30), "Check Out (Detached) did not detach")
        let line = (detached.value as? String) ?? detached.label
        let short = String(line.dropFirst("Detached HEAD at ".count))
        let alone = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", short, short))
        XCTAssertEqual(alone.count, 0, "the detached header shows \(short) a second time")
        shot(app, "0574-detached-900")
    }
}
