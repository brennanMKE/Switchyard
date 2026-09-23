// HistoryScrollRequest.swift
//
// #0401: a one-shot request for the History list to scroll a commit into
// view. Each request carries a fresh `serial`, so asking for the same commit
// twice (clicking the same sidebar branch again after scrolling away) is
// still a change `onChange(of:)` sees.

import Foundation

public nonisolated struct HistoryScrollRequest: Equatable, Sendable {
    /// The commit to scroll to, a full oid.
    public let oid: String
    /// Distinguishes two requests for the same oid.
    public let serial: UUID

    public init(oid: String) {
        self.oid = oid
        self.serial = UUID()
    }
}
