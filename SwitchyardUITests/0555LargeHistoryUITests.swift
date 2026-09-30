import XCTest

/// #0555: the large-history fixture
/// (scripts/uitest-fixtures/make-large-history-fixture.sh) — keep the two in sync.
enum UITestLargeHistoryFixture {
    static let repositoryPath = "/Users/admin/uitest-large-repo"
    /// HEAD's tip.
    static let tipSubject = "large commit 6000"
    /// 20 loaded commits' subjects end with it.
    static let needle = "needle"
    /// A tag only on "large commit 5994": found through its ref chip.
    static let tag = "rel-5994"
    static let tagSubject = "large commit 5994"
}

/// #0555: History on 5,000 loaded commits and 1,000 tags (guide §11
/// decision 44). The filter finds a commit by a tag chip, which a click then
/// selects, and counts message matches — the chips and search text come
/// from `HistoryIndex`. (⌘G and the arrow keys are not driven here: on this
/// fixture neither moved the selection, before or after #0552-#0554 — #0556.) The seconds
/// from launch to the tip row, and from the first keystroke of each query to
/// its count, are attached as text for the record: they are never asserted
/// (CLAUDE.md: never assert wall-clock time).
final class Spike0555LargeHistoryUITests: XCTestCase {
    @MainActor
    func testFilterOnALargeHistory() {
        let app = XCUIApplication()
        let launched = Date()
        app.launchWithRemoteFixture(UITestLargeHistoryFixture.repositoryPath)
        let window = app.windows.firstMatch
        let tip = app.historyRows(containing: UITestLargeHistoryFixture.tipSubject).firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 60), "History does not show the large repository's tip")
        var timings: [String] = []
        record("open to tip row: \(seconds(since: launched))", in: &timings)

        // The tag first: only its chip matches, so this fails if the chips
        // are missing. Typing scrolls to the match and opens the fold it
        // was in (#0427), so its row can be clicked.
        let filter = app.sidebarFilterField()
        XCTAssertTrue(filter.waitForExistence(timeout: 30), "no filter field")
        filter.click()
        var typed = Date()
        filter.typeText(UITestLargeHistoryFixture.tag)
        XCTAssertTrue(app.matchCount("1 match").waitForExistence(timeout: 60),
                      "the filter does not find the commit tagged rel-5994 by its chip")
        record("\"rel-5994\" typed to \"1 match\": \(seconds(since: typed))", in: &timings)
        app.selectHistoryRow(subject: UITestLargeHistoryFixture.tagSubject)
        let tagged = XCTAttachment(screenshot: window.screenshot())
        tagged.name = "large-history-tag-match"
        tagged.lifetime = .keepAlways
        add(tagged)

        // Messages: 20 loaded commits say needle.
        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        typed = Date()
        filter.typeText(UITestLargeHistoryFixture.needle)
        XCTAssertTrue(app.matchCount("20 matches").waitForExistence(timeout: 60),
                      "the filter does not count the 20 loaded commits whose subject says needle")
        record("\"needle\" typed to \"20 matches\": \(seconds(since: typed))", in: &timings)
        let counted = XCTAttachment(screenshot: window.screenshot())
        counted.name = "large-history-needle-matches"
        counted.lifetime = .keepAlways
        add(counted)

        let attachment = XCTAttachment(string: timings.joined(separator: "\n"))
        attachment.name = "large-history-timings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Keeps `line` for the attachment and prints it at once, so a run that
    /// fails later still logs what it measured.
    private func record(_ line: String, in timings: inout [String]) {
        timings.append(line)
        print("SPIKE-0555 TIMING \(line)")
    }

    private func seconds(since start: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(start))
    }
}
