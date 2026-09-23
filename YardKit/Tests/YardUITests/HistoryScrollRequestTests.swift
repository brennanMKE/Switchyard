// HistoryScrollRequestTests.swift
//
// #0401: `HistoryScrollRequest` is public, so no `@testable`.

import Testing
import YardUI

@Test("two scroll requests for the same commit are distinct, so a repeat click scrolls again")
func twoScrollRequestsForTheSameCommitAreDistinct() {
    let first = HistoryScrollRequest(oid: "abc123")
    let second = HistoryScrollRequest(oid: "abc123")
    #expect(first != second)
    #expect(first.oid == second.oid)
}

@Test("a scroll request equals itself")
func aScrollRequestEqualsItself() {
    let request = HistoryScrollRequest(oid: "abc123")
    #expect(request == request)
}
