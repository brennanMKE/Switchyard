// SmokeUITests.swift
//
// #0395 round 1: the pipeline proof for running Switchyard's UI tests in a
// disposable Tart VM. Not a spike re-derivation — later rounds add those.
//
// The scheme this target belongs to is invoked only inside the VM
// (scripts/run-ui-tests-vm.sh); never on the development Mac. The fixture
// repository is generated per run inside the guest by that script at the
// constants below — keep the two in sync.

import XCTest

final class SmokeUITests: XCTestCase {

    /// The fixture repository the run script generates inside the guest
    /// (`git init` + scripted commits) before the test launches the app.
    private static let fixturePath = "/Users/admin/uitest-fixture-repo"

    /// The fixture's checked-out branch. Distinctive on purpose: the
    /// assertion below proves the header shows THIS fixture's branch, not
    /// some other repository's.
    private static let fixtureBranch = "uitest-main"

    /// Launches the app with `-uiTestRepository <fixture>` — the launch hook
    /// that opens the repository through `RepositoryOpener.open(path:)`
    /// without an `NSOpenPanel` — and asserts the repository header shows
    /// the fixture's branch name.
    @MainActor
    func testLaunchWithUITestRepositoryShowsFixtureBranch() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestRepository", Self.fixturePath]
        app.launch()

        let branchText = app.staticTexts[Self.fixtureBranch]
        XCTAssertTrue(
            branchText.waitForExistence(timeout: 30),
            "The fixture branch “\(Self.fixtureBranch)” never appeared. Either the " +
            "-uiTestRepository hook did not open \(Self.fixturePath), the summary load " +
            "failed (the window then shows “Couldn't open …”), or the header never " +
            "rendered. Fixture tree at \(Self.fixturePath) survives only this run.")
    }
}
