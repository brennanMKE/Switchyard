// WorkingChangesRowTests.swift — the History pane's Uncommitted Changes row (#0446)

import Testing
@testable import YardUI

@Test func theRowCountsChangedFilesAndSaysCleanForNone() {
    #expect(WorkingChangesRow.countText(fileCount: 0) == "Working tree clean")
    #expect(WorkingChangesRow.countText(fileCount: 1) == "1 changed file")
    #expect(WorkingChangesRow.countText(fileCount: 3) == "3 changed files")
}
