// RemoteOnlyHistory.swift
//
// #0368: which loaded commits a local branch or `HEAD` reaches. Everything
// else in the window is reachable only from remote-tracking refs, and is
// drawn dashed and dimmed.

import SwiftUI
import YardGit

public nonisolated enum LocalReachability {
    /// The oids in `rows` reachable through `parents` from any of `tips`,
    /// without leaving the loaded window. `tips` is `HEAD`'s full oid
    /// (`WhereAmI.rawHead`) plus every `refs/heads/*` entry's oid from
    /// `RefSnapshot.refs`.
    public static func oids(in rows: [GraphRow], from tips: Set<String>) -> Set<String> {
        let byOid = Dictionary(rows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var stack = Array(tips)
        while let oid = stack.popLast() {
            guard let row = byOid[oid], seen.insert(oid).inserted else { continue }
            stack.append(contentsOf: row.parents)
        }
        return seen
    }

    /// `HEAD`'s oid plus every local branch tip, the `tips` argument above.
    public static func localTips(refs: RefSnapshot, headOid: String?) -> Set<String> {
        Set(refs.refs.filter { $0.name.hasPrefix("refs/heads/") }.map(\.oid) + [headOid].compactMap { $0 })
    }
}
