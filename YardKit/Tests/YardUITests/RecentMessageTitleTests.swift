// RecentMessageTitleTests.swift — a Recent Messages item's title (#0567)

import Testing
@testable import YardUI

@Test func aRecentMessageIsTitledByItsSubject() {
    #expect(recentMessageTitle("Fix the parser\n\nIt dropped the last line.") == "Fix the parser")
    #expect(recentMessageTitle("One line") == "One line")
}

@Test func aLongSubjectIsCutWithAnEllipsis() {
    let sixty = String(repeating: "a", count: 60)
    #expect(recentMessageTitle(sixty) == sixty)
    let title = recentMessageTitle(sixty + "b\n\nbody")
    #expect(title == String(repeating: "a", count: 59) + "…")
    #expect(title.count == 60)
}
