// 0582FixupWithParentUITests.swift
//
// #0582 (guide §11 decision 46): Commit ▸ Fixup with Parent on a commit in
// the MIDDLE of the branch folds it into its parent, and Edit ▸ Undo Fixup
// puts the branch back. The assertions read git itself, not the screen: the
// fixture is scripts/uitest-fixtures/make-fixup-fixture.sh.
//
// TODO(#0590+): the `Git` helper below is self-contained until Workstream C's
// shared git-state assertion helper lands; migrate to it then.

import XCTest

private enum FixupFixture {
    static let repositoryPath = "/Users/admin/uitest-fixup-repo"
    static let branch = "refs/heads/fixup-main"
    static let middleSubject = "fixup middle"
    static let tipSubject = "fixup tip"
}

/// Runs `/usr/bin/git -C <fixture>` from the test runner and returns stdout.
private enum Git {
    static func run(_ arguments: [String], file: StaticString = #filePath,
                    line: UInt = #line) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", FixupFixture.repositoryPath] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            XCTFail("could not launch git \(arguments): \(error)", file: file, line: line)
            return ""
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments) failed",
                       file: file, line: line)
        return String(decoding: data, as: UTF8.self)
    }

    static func oid(_ revision: String) -> String {
        run(["rev-parse", revision]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polls git until `condition` holds or `timeout` passes — the app's
    /// action runs asynchronously after the menu click. Bounded; asserts
    /// nothing about elapsed time.
    static func wait(timeout: TimeInterval = 60, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(250_000)
        }
        return condition()
    }

    /// The stored message bytes: `cat-file commit` minus its header block.
    static func message(_ revision: String) -> String {
        let object = run(["cat-file", "commit", revision])
        guard let split = object.range(of: "\n\n") else { return "" }
        return String(object[split.upperBound...])
    }
}

final class Spike0582FixupWithParentUITests: XCTestCase {
    @MainActor
    func testFixupWithParentFoldsAMidBranchCommitAndUndoRestoresIt() {
        // The pre-state, read from git before the app touches anything.
        let tipBefore = Git.oid(FixupFixture.branch)
        let rootOid = Git.oid("\(FixupFixture.branch)~3")
        let middleTree = Git.oid("\(FixupFixture.branch)~1^{tree}")
        let tipTree = Git.oid("\(FixupFixture.branch)^{tree}")
        let parentMessage = Git.message("\(FixupFixture.branch)~2")
        XCTAssertEqual(parentMessage, "fixup parent\n\nparent body line\n", "fixture drifted")
        let parentAuthor = Git.run(["log", "-n", "1", "--format=%an|%ae|%ad", "--date=raw",
                                    "\(FixupFixture.branch)~2"])
        XCTAssertTrue(parentAuthor.hasPrefix("Parent Author|"), "fixture drifted")

        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestRepository", FixupFixture.repositoryPath, "-uiTestRealSurfaces",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60), "no window")
        // The branch map folds the run below the tip (decision 29): open it.
        let fold = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@", "Folded ")).firstMatch
        if fold.waitForExistence(timeout: 30) { fold.click() }
        app.selectHistoryRow(subject: FixupFixture.middleSubject)

        app.menuBars.menuBarItems["Commit"].click()
        let fixup = app.menuBars.menuItems["Fixup with Parent"]
        XCTAssertTrue(fixup.waitForExistence(timeout: 10), "the Commit menu has no Fixup with Parent")
        guard fixup.isEnabled else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Fixup with Parent is disabled on a mid-branch commit (decision 46 not built)")
            return
        }
        fixup.click()

        XCTAssertTrue(Git.wait { Git.oid(FixupFixture.branch) != tipBefore },
                      "the branch never moved: the fixup did not run")
        let middleRow = app.historyRows(containing: FixupFixture.middleSubject).firstMatch
        XCTAssertTrue(app.waitUntilDisappears(middleRow, timeout: 30),
                      "the folded commit is still listed in History")
        XCTAssertFalse(app.staticTexts["Couldn’t Fixup Commit"].exists, "the fixup failed")
        let folded = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        folded.name = "0582-folded"
        folded.lifetime = .keepAlways
        add(folded)

        // Git state after the fold.
        XCTAssertEqual(Git.run(["log", "--format=%s", FixupFixture.branch]),
                       "fixup tip\nfixup parent\nfixup root\n",
                       "the middle commit is gone and its parent and descendant remain")
        XCTAssertEqual(Git.message("\(FixupFixture.branch)~1"), parentMessage,
                       "the parent's message is kept byte for byte")
        XCTAssertEqual(Git.oid("\(FixupFixture.branch)~1^{tree}"), middleTree,
                       "the selected commit's change is in the parent")
        XCTAssertEqual(Git.run(["show", "\(FixupFixture.branch)~1:parent.txt"]),
                       "parent\nfolded by middle\n")
        XCTAssertEqual(Git.run(["rev-list", "--parents", "-n", "1", "\(FixupFixture.branch)~1"])
                           .split(separator: " ").count, 2,
                       "the folded commit has exactly one parent")
        XCTAssertEqual(Git.oid("\(FixupFixture.branch)~2"), rootOid, "the root is untouched")
        XCTAssertEqual(Git.run(["log", "-n", "1", "--format=%an|%ae|%ad", "--date=raw",
                                "\(FixupFixture.branch)~1"]),
                       parentAuthor, "the parent's author and author date are kept")
        XCTAssertEqual(Git.oid("\(FixupFixture.branch)^{tree}"), tipTree,
                       "the descendant's tree is intact")
        XCTAssertEqual(Git.message(FixupFixture.branch), "fixup tip\n")
        XCTAssertEqual(Git.run(["diff", "--cached", "--name-only"]), "staged.txt\n",
                       "the staged file is still staged and was not swept into the fold")

        // Edit ▸ Undo Fixup restores the branch exactly.
        app.menuBars.menuBarItems["Edit"].click()
        let undo = app.menuBars.menuItems["Undo Fixup"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the Edit menu offers no Undo Fixup")
        undo.click()
        XCTAssertTrue(Git.wait { Git.oid(FixupFixture.branch) == tipBefore },
                      "Undo Fixup did not restore the branch tip")
        XCTAssertEqual(Git.run(["symbolic-ref", "HEAD"]), "\(FixupFixture.branch)\n")
        XCTAssertEqual(Git.run(["diff", "--cached", "--name-only"]), "staged.txt\n")
        let undone = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        undone.name = "0582-undone"
        undone.lifetime = .keepAlways
        add(undone)
    }
}
