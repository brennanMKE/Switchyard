// 0604DisabledReasonUITests.swift
//
// #0604: a disabled Commit-menu item shows its reason without hovering.
// DIAGNOSTIC (planner's first VM run): dumps what XCUITest sees.

import XCTest

final class Spike0604DisabledReasonUITests: XCTestCase {
    @MainActor
    func testADisabledItemShowsItsReasonInTheMenu() {
        let repo = GitRepo(path: HistoryFixture.path("cherry-pick"))
        XCTAssertEqual(repo.headBranch(), "main")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("cherry-pick")

        app.menuBars.menuBarItems["Commit"].click()
        sleep(1)
        let shot0 = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot0.name = "0604-menu-before-selection"; shot0.lifetime = .keepAlways; add(shot0)
        print("DIAG-NOSEL-BEGIN\n\(app.menuBars.firstMatch.debugDescription)\nDIAG-NOSEL-END")
        app.typeKey(.escape, modifierFlags: [])

        app.selectHistoryRow(subject: HistoryFixture.pickSubject)
        app.menuBars.menuBarItems["Commit"].click()
        let fixup = app.menuBars.menuItems["Fixup with Parent"]
        let found = fixup.waitForExistence(timeout: 10)
        sleep(1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "0604-menu-off-chain"; shot.lifetime = .keepAlways; add(shot)
        print("DIAG-SEL-BEGIN\n\(app.menuBars.firstMatch.debugDescription)\nDIAG-SEL-END")
        XCTAssertTrue(found, "no Fixup with Parent item")
        if found {
            print("DIAG-FIXUP title=\(fixup.title) label=\(fixup.label) value=\(String(describing: fixup.value)) id=\(fixup.identifier) enabled=\(fixup.isEnabled)")
            print("DIAG-FIXUP-TREE\n\(fixup.debugDescription)")
        }
        let reason = "Only commits in “main”’s own history can be rewritten"
        let anyReason = app.menuBars.descendants(matching: .any).matching(NSPredicate(
            format: "title CONTAINS %@ OR label CONTAINS %@ OR value CONTAINS %@", reason, reason, reason))
        print("DIAG-REASON-COUNT \(anyReason.count)")
        app.typeKey(.escape, modifierFlags: [])
    }
}
