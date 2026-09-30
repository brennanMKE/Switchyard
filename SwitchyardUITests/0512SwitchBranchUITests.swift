import XCTest

/// #0512: switching branches from the sidebar (guide §11 decision 38).
/// A double-click on a branch whose checkout would overwrite a local change
/// asks, and Stash Changes and Switch switches; Edit ▸ Undo Switch Branch
/// switches back. Delete Branch… on an unmerged branch asks twice; Undo
/// brings it back. Delete Tag… removes a tag. Check Out as Local Branch on a
/// remote branch switches to a new tracking branch, and the Commit menu's
/// Check Out (Detached) detaches.
final class Spike0512SwitchBranchUITests: XCTestCase {
    @MainActor
    func testSwitchCheckOutAndDelete() {
        let app = XCUIApplication()
        app.launchWithSwitchFixture()
        let window = app.windows.firstMatch

        let onMain = app.header(beginningWith: "On branch \(UITestSwitchFixture.main)")
        XCTAssertTrue(onMain.waitForExistence(timeout: 30), "the header does not show switch-main")

        // Switch by double-click: the local edit is in the way, so it asks.
        let feature = app.sidebarRow(named: UITestSwitchFixture.feature)
        XCTAssertTrue(feature.waitForExistence(timeout: 30), "no sidebar row for switch-feature")
        feature.doubleClick()
        let stashAndSwitch = window.buttons["Stash Changes and Switch"]
        XCTAssertTrue(stashAndSwitch.waitForExistence(timeout: 30),
                      "switching over a local change did not offer Stash Changes and Switch")
        let blocked = XCTAttachment(screenshot: window.screenshot())
        blocked.name = "switch-blocked"
        blocked.lifetime = .keepAlways
        add(blocked)
        stashAndSwitch.click()
        let onFeature = app.header(beginningWith: "On branch \(UITestSwitchFixture.feature)")
        XCTAssertTrue(onFeature.waitForExistence(timeout: 30), "Stash Changes and Switch did not switch")
        XCTAssertTrue(app.sidebarRow(named: UITestSwitchFixture.stashMessage).waitForExistence(timeout: 30),
                      "the stash the switch made is not in the Stashes list")
        let switched = XCTAttachment(screenshot: window.screenshot())
        switched.name = "switched"
        switched.lifetime = .keepAlways
        add(switched)

        app.menuBars.menuBarItems["Edit"].click()
        let undoSwitch = app.menuBars.menuItems["Undo Switch Branch"]
        XCTAssertTrue(undoSwitch.waitForExistence(timeout: 10), "the Edit menu offers no Undo Switch Branch")
        undoSwitch.click()
        XCTAssertTrue(onMain.waitForExistence(timeout: 30), "Undo Switch Branch did not switch back")

        // Delete Branch… on an unmerged branch asks, then asks again.
        let unmerged = app.sidebarRow(named: UITestSwitchFixture.unmerged)
        XCTAssertTrue(unmerged.waitForExistence(timeout: 10), "no sidebar row for unmerged-topic")
        unmerged.rightClick()
        let deleteBranch = app.menuItems["Delete Branch…"]
        XCTAssertTrue(deleteBranch.waitForExistence(timeout: 10), "the branch row's menu has no Delete Branch…")
        deleteBranch.click()
        let confirm = window.buttons.matching(
            NSPredicate(format: "label == 'Delete Branch' OR title == 'Delete Branch'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Delete Branch… asked nothing")
        confirm.click()
        let force = window.buttons.matching(NSPredicate(
            format: "label == 'Delete Unmerged Branch' OR title == 'Delete Unmerged Branch'")).firstMatch
        XCTAssertTrue(force.waitForExistence(timeout: 30), "an unmerged branch was not asked about twice")
        force.click()
        XCTAssertTrue(app.waitUntilDisappears(unmerged, timeout: 30), "the unmerged branch was not deleted")
        app.menuBars.menuBarItems["Edit"].click()
        let undoDelete = app.menuBars.menuItems["Undo Delete Branch"]
        XCTAssertTrue(undoDelete.waitForExistence(timeout: 10), "the Edit menu offers no Undo Delete Branch")
        undoDelete.click()
        XCTAssertTrue(unmerged.waitForExistence(timeout: 30), "Undo Delete Branch did not bring it back")

        // Delete Tag…, found through the filter (Tags starts collapsed).
        let filter = app.sidebarFilterField()
        XCTAssertTrue(filter.waitForExistence(timeout: 10), "no sidebar filter field")
        filter.tap()
        filter.typeText(UITestSwitchFixture.tag)
        let tag = app.sidebarRow(named: UITestSwitchFixture.tag)
        XCTAssertTrue(tag.waitForExistence(timeout: 10), "the filter did not surface the tag")
        tag.rightClick()
        let deleteTag = app.menuItems["Delete Tag…"]
        XCTAssertTrue(deleteTag.waitForExistence(timeout: 10), "the tag row's menu has no Delete Tag…")
        deleteTag.click()
        let confirmTag = window.buttons.matching(
            NSPredicate(format: "label == 'Delete Tag' OR title == 'Delete Tag'")).firstMatch
        XCTAssertTrue(confirmTag.waitForExistence(timeout: 10), "Delete Tag… asked nothing")
        confirmTag.click()
        XCTAssertTrue(app.waitUntilDisappears(tag, timeout: 30), "the tag was not deleted")

        // Check Out as Local Branch, through the filter (Remotes starts collapsed).
        filter.tap()
        app.typeKey("a", modifierFlags: .command)
        filter.typeText(UITestSwitchFixture.remoteBranch)
        let remote = app.sidebarRow(named: UITestSwitchFixture.remoteBranch)
        XCTAssertTrue(remote.waitForExistence(timeout: 10), "the filter did not surface origin/remote-topic")
        remote.rightClick()
        let checkOut = app.menuItems["Check Out as Local Branch"]
        XCTAssertTrue(checkOut.waitForExistence(timeout: 10), "the remote row's menu has no Check Out as Local Branch")
        checkOut.click()
        XCTAssertTrue(app.header(beginningWith: "On branch \(UITestSwitchFixture.remoteLocal)")
                        .waitForExistence(timeout: 30),
                      "Check Out as Local Branch did not switch to remote-topic")
        filter.tap()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])

        // The Commit menu's Check Out (Detached) on the base commit.
        let base = app.historyRows(containing: UITestSwitchFixture.baseSubject).firstMatch
        XCTAssertTrue(base.waitForExistence(timeout: 30), "no History row for the base commit")
        base.tap()
        app.menuBars.menuBarItems["Commit"].click()
        let detach = app.menuBars.menuItems["Check Out (Detached)"]
        XCTAssertTrue(detach.waitForExistence(timeout: 10), "the Commit menu has no Check Out (Detached)")
        detach.click()
        XCTAssertTrue(app.header(beginningWith: "Detached HEAD at").waitForExistence(timeout: 30),
                      "Check Out (Detached) did not detach")
        let detached = XCTAttachment(screenshot: window.screenshot())
        detached.name = "detached"
        detached.lifetime = .keepAlways
        add(detached)
    }
}
