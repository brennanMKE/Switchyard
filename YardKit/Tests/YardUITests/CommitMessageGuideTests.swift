// CommitMessageGuideTests.swift — the line under the message editor (#0563)

import Testing
@testable import YardUI

private let long72 = String(repeating: "word ", count: 14) + "wo"   // 72 characters
private let long73 = long72 + "r"

@Test func theSubjectIsCountedAgainstFiftyAndWarnsPastIt() {
    let fifty = CommitMessageGuide(message: String(repeating: "s", count: 50) + "\n\nBody.")
    #expect(fifty.subjectLength == 50)
    #expect(!fifty.isWarning)
    #expect(fifty.summary == "Subject 50/50")

    let over = CommitMessageGuide(message: String(repeating: "s", count: 51))
    #expect(over.isWarning)
    #expect(over.summary == "Subject 51/50")
}

@Test func theSubjectCountsCharactersAsAReaderSeesThem() {
    #expect(CommitMessageGuide(message: "Café 👩‍💻").subjectLength == 6)
}

@Test func textOnLineTwoIsAWarning() {
    let guide = CommitMessageGuide(message: "Subject\nmore subject")
    #expect(guide.secondLineHasText)
    #expect(guide.isWarning)
    #expect(guide.summary == "Subject 7/50 · Leave line 2 blank")
    #expect(!CommitMessageGuide(message: "Subject\n  \nBody").secondLineHasText)
}

@Test func bodyLinesPastSeventyTwoAreCountedButNotURLsOrTrailers() {
    #expect(long72.count == 72)
    let message = [
        "Subject", "", long72, long73, long73,
        "https://example.com/" + String(repeating: "x", count: 80),
        "Co-authored-by: " + String(repeating: "N", count: 40) + " <" + String(repeating: "e", count: 30) + "@example.com>",
    ].joined(separator: "\n")
    let guide = CommitMessageGuide(message: message)
    #expect(guide.longBodyLines == 2)
    #expect(guide.summary == "Subject 7/50 · 2 body lines over 72")

    #expect(CommitMessageGuide(message: "S\n\n" + long73).summary == "Subject 1/50 · 1 body line over 72")
}

@Test func theSubjectLineIsNeverCountedAsBody() {
    #expect(CommitMessageGuide(message: long73).longBodyLines == 0)
}
