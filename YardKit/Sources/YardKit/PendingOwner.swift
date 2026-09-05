// PendingOwner.swift — the per-connection ownership token (#0349)
//
// The app's listener delegate mints one per accepted CLI connection and
// threads it into every pending registration that connection makes. The
// connection's invalidation handler abandons exactly the pendings owned by
// its own token — a CLI dying must never touch another CLI's pending.

import Foundation

/// Which CLI connection registered a pending (#0349).
///
/// A value type wrapping a fresh UUID per connection: the stores keep it in
/// their slots and match it by equality in `abandonAll(ownedBy:)`. The
/// stores' `awaitDecision` defaults to a fresh token per call, so a pending
/// registered without an explicit owner is owned by nobody and can never be
/// abandoned by a connection death — the default keeps direct store use
/// (tests, non-XPC callers) safe by construction.
public struct PendingOwner: Hashable, Sendable {

    /// Fresh per connection; equality is the only thing the stores read.
    public let id: UUID

    public init() {
        self.id = UUID()
    }
}
