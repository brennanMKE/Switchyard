// CommitDetailSummaryTests.swift
//
// #0403: the Detail pane's changed-files heading. Public API, no @testable.

import Testing
import YardUI

@Test("one changed file is singular")
func oneChangedFileIsSingular() {
    #expect(CommitDetailView.changedFilesSummary(count: 1) == "1 changed file")
}

@Test("several changed files are plural")
func severalChangedFilesArePlural() {
    #expect(CommitDetailView.changedFilesSummary(count: 3) == "3 changed files")
}
