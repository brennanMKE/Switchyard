// 0604DisabledReasonUITests.swift
//
// #0604: a disabled Commit-menu item shows its reason without hovering.

import XCTest

final class Spike0604DisabledReasonUITests: XCTestCase {
    @MainActor
    func testADisabledItemShowsItsReasonInTheMenu() {
        let repo = GitRepo(path: HistoryFixture.path("cherry-pick"))
        let pick = repo.oid("pick-source")
        XCTAssertEqual(repo.headBranch(), "main")
        XCTAssertFalse(repo.git("rev-list", "--first-parent", "main").contains(pick),
                       "“pick source commit” is on main's first-parent chain — the fixture changed")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("cherry-pick")

        app.menuBars.menuBarItems["Commit"].click()
        let shared = app.menuBars.menuItems["Select a commit first"]
        let sharedShown = shared.waitForExistence(timeout: 10)
        print("DIAG-SHARED exists=\(sharedShown) value=\(String(describing: shared.value))")
        app.typeKey(.escape, modifierFlags: [])

        app.selectHistoryRow(subject: HistoryFixture.pickSubject)
        app.menuBars.menuBarItems["Commit"].click()
        let fixup = app.menuBars.menuItems["Fixup with Parent"]
        XCTAssertTrue(fixup.waitForExistence(timeout: 10), "the Commit menu has no Fixup with Parent")
        let revert = app.menuBars.menuItems["Revert"]
        print("DIAG-FIXUP value=\(String(describing: fixup.value)) frame=\(fixup.frame) revert=\(revert.frame) revertValue=\(String(describing: revert.value))")
        XCTAssertFalse(fixup.isEnabled, "Fixup with Parent is enabled on a commit off main's chain")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "0604-menu-off-chain"; shot.lifetime = .keepAlways; add(shot)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sharedShown, "no shared “Select a commit first” line")
    }
}
