// 0604DisabledReasonUITests.swift
//
// #0604 (guide §11 decision 49): a disabled Commit-menu item shows why it is
// disabled without hovering — the reason is the item's subtitle — and when
// every item shares one reason it is shown once, as a line above them.
//
// The subtitle is drawn but not in the accessibility tree: XCUITest reports
// only the item's title, and `value` stays empty even with
// `.accessibilityValue` (measured, the planner's first two VM runs). So the
// spike reads it the way a person does — from the pixels, with Vision's
// text recognizer over the item's own screenshot.

import Vision
import XCTest

final class Spike0604DisabledReasonUITests: XCTestCase {
    @MainActor
    func testADisabledItemShowsItsReasonInTheMenu() throws {
        let repo = GitRepo(path: HistoryFixture.path("cherry-pick"))
        let pick = repo.oid("pick-source")
        XCTAssertEqual(repo.headBranch(), "main")
        XCTAssertFalse(repo.git("rev-list", "--first-parent", "main").contains(pick),
                       "“pick source commit” is on main's first-parent chain — the fixture changed")
        let app = XCUIApplication()
        app.launchWithHistoryFixture("cherry-pick")

        // No commit selected: every item is disabled for one reason, shown once.
        app.menuBars.menuBarItems["Commit"].click()
        XCTAssertTrue(app.menuBars.menuItems["Select a commit first"].waitForExistence(timeout: 10),
                      "the Commit menu does not say “Select a commit first” with no commit selected")
        app.typeKey(.escape, modifierFlags: [])

        // A commit off main's first-parent chain: Fixup with Parent is
        // disabled, and its reason is drawn under its title.
        app.selectHistoryRow(subject: HistoryFixture.pickSubject)
        app.menuBars.menuBarItems["Commit"].click()
        let fixup = app.menuBars.menuItems["Fixup with Parent"]
        XCTAssertTrue(fixup.waitForExistence(timeout: 10), "the Commit menu has no Fixup with Parent")
        XCTAssertFalse(fixup.isEnabled, "Fixup with Parent is enabled on a commit off main's chain")
        let shot = fixup.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "0604-fixup-item"
        attachment.lifetime = .keepAlways
        add(attachment)
        let lines = try recognizedLines(in: shot.pngRepresentation)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            lines.contains { $0.localizedCaseInsensitiveContains("own history can be rewritten") },
            "Fixup with Parent shows no reason; the item reads \(lines)")
    }

    /// The text lines Vision reads in a PNG, top to bottom.
    private func recognizedLines(in png: Data) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(data: png).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
