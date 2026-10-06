// HistoryOpsSupport.swift
//
// #0591 (umbrella #0590): the history-operation fixture
// scripts/uitest-fixtures/make-history-ops-fixture.sh generates inside the
// guest — keep the two in sync — and the UI steps every history spike
// shares: launch on one fixture copy, choose a Commit-menu item, choose
// Edit ▸ Undo <title>, keep a screenshot.

import XCTest

enum HistoryFixture {
    static let directory = "/Users/admin/uitest-history"
    /// One copy per spike class, named for it (see the script's header).
    static func path(_ copy: String) -> String { "\(directory)/\(copy)" }

    static let rootSubject = "hist root"
    static let sharedSubject = "hist shared"
    static let mainThreeSubject = "hist main three"
    static let mainTipSubject = "hist main tip"
    static let ffSubject = "ff topic commit"
    static let divergedOneSubject = "diverged topic one"
    static let divergedTwoSubject = "diverged topic two"
    static let clashSubject = "clash topic commit"
    static let pickSubject = "pick source commit"
    static let rebaseOneSubject = "rebase topic one"
    static let rebaseTwoSubject = "rebase topic two"
    /// `stack`, newest first — four commits so none folds (#0427).
    static let stackTip = "stack tip"
    static let stackSplit = "stack split"
    static let stackTwo = "stack two"
    static let stackOne = "stack one"
    static let stackSubjects = [stackTip, stackSplit, stackTwo, stackOne]
    /// `wip`, only in the `fixup-newer` copy (#0603): "wip good" with a
    /// body, then three commits whose whole message is "wip".
    static let wipGood = "wip good"
    static let wipGoodMessage = "wip good\n\nThe message Brennan wrote first; the wips fold into it."
    static let wipSubject = "wip"
}

extension XCUIApplication {
    /// Launches the app on one history fixture copy with the real panes.
    @MainActor
    func launchWithHistoryFixture(_ copy: String) {
        launchArguments = ["-uiTestRepository", HistoryFixture.path(copy), "-uiTestRealSurfaces"]
        launch()
        let tree = debugDescription
        XCTAssertTrue(
            windows.firstMatch.waitForExistence(timeout: 60),
            "The app launched but opened no window within 60 s — its element " +
            "tree starts with: \(String(tree.prefix(1200)))",
            file: #filePath, line: #line)
    }

    /// Chooses `title` from the menu bar's Commit menu, asserting it exists
    /// and is enabled — a disabled item names its reason in `.help`, which
    /// the failure message carries.
    @MainActor
    func chooseCommitMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        menuBars.menuBarItems["Commit"].click()
        let item = menuBars.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10),
                      "the Commit menu has no “\(title)” item", file: file, line: line)
        XCTAssertTrue(item.isEnabled,
                      "“\(title)” is disabled for the selected commit: \(item.title) — \(item.value ?? "")",
                      file: file, line: line)
        item.click()
    }

    /// Chooses Edit ▸ `title` (e.g. "Undo Merge"), asserting the item exists
    /// under that exact name — the journal entry's operation title.
    @MainActor
    func chooseEditMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        menuBars.menuBarItems["Edit"].click()
        let item = menuBars.menuItems[title]
        let present = item.waitForExistence(timeout: 10)
        if !present {
            // Name what the Edit menu does offer, so a renamed title is obvious.
            let offered = menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo'"))
                .allElementsBoundByIndex.map(\.title)
            typeKey(.escape, modifierFlags: [])
            XCTFail("the Edit menu offers no “\(title)”; it offers \(offered)", file: file, line: line)
            return
        }
        item.click()
    }

    /// A button in the front window by its exact label or title. Scoped to
    /// the window because an unscoped `buttons["OK"]` also matches the
    /// Touch Bar's copy, which cannot be clicked (measured: "cannot be
    /// called with Touch Bar elements", #0592's first VM run; #0457).
    @MainActor
    func windowButton(_ title: String) -> XCUIElement {
        windows.firstMatch.buttons.matching(
            NSPredicate(format: "label == %@ OR title == %@", title, title)).firstMatch
    }

    /// Clicks the front alert's OK and waits for the alert to close. The
    /// button is reached through the alert's sheet: Return did not dismiss
    /// it in the guest (measured, the planner's second VM run — the alert
    /// was still up in the final hierarchy), and an unscoped
    /// `buttons["OK"]` hits the Touch Bar copy.
    @MainActor
    func dismissAlert(file: StaticString = #filePath, line: UInt = #line) {
        let alert = sheets.firstMatch
        let ok = alert.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 10), "the alert has no OK button", file: file, line: line)
        ok.click()
        XCTAssertTrue(waitUntilDisappears(alert, timeout: 10), "the alert stayed open after OK",
                      file: file, line: line)
    }

    /// Keeps a window screenshot in the result bundle.
    @MainActor
    func keepScreenshot(_ name: String, in testCase: XCTestCase) {
        let shot = XCTAttachment(screenshot: windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        testCase.add(shot)
    }
}
