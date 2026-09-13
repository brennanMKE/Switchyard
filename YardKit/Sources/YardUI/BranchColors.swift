// BranchColors.swift
//
// #0366: one colour per branch, the same colour on every refresh, every
// launch and every machine, independent of which lane column the branch
// happens to occupy. Ownership says which branch a commit (and so an edge)
// belongs to; the colour is a pure function of the branch's name.

import SwiftUI
import YardGit

/// A branch tip the History pane colours by.
public nonisolated struct BranchTip: Hashable, Sendable {
    /// Short name: `main`, `origin/main`, or `HEAD` for a detached `HEAD`.
    public let name: String
    public let oid: String
    public let isRemote: Bool

    public init(name: String, oid: String, isRemote: Bool) {
        self.name = name
        self.oid = oid
        self.isRemote = isRemote
    }

    /// The name the colour is derived from. A remote-tracking branch drops
    /// its remote segment, so `origin/feature` is drawn in `feature`'s
    /// colour -- the dash (#0368) is what tells them apart.
    public var colorKey: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
}

public nonisolated enum BranchOwnership {
    private static let heads = "refs/heads/"
    private static let remotes = "refs/remotes/"

    /// Tips in claiming order: a detached `HEAD`, then `HEAD`'s branch, then
    /// the other local branches by name, then remote-tracking branches by
    /// name. Earlier tips win shared history, so `main` owns its own
    /// first-parent line even where a feature branch also reaches it.
    public static func tips(from refs: RefSnapshot) -> [BranchTip] {
        var result: [BranchTip] = []
        var headBranch: String?
        switch refs.head {
        case let .symbolic(target) where target.hasPrefix(heads):
            headBranch = String(target.dropFirst(heads.count))
        case let .detached(oid):
            result.append(BranchTip(name: "HEAD", oid: oid, isRemote: false))
        default:
            break
        }
        result += refs.refs
            .filter { $0.name.hasPrefix(heads) }
            .map { BranchTip(name: String($0.name.dropFirst(heads.count)), oid: $0.oid, isRemote: false) }
            .sorted { ($0.name == headBranch ? 0 : 1, $0.name) < ($1.name == headBranch ? 0 : 1, $1.name) }
        result += refs.refs
            .filter { $0.name.hasPrefix(remotes) && !$0.name.hasSuffix("/HEAD") }
            .map { BranchTip(name: String($0.name.dropFirst(remotes.count)), oid: $0.oid, isRemote: true) }
            .sorted { $0.name < $1.name }
        return result
    }

    /// oid -> owning tip. Each tip, in `tips` order, claims its first-parent
    /// chain within `rows` until it reaches a commit already claimed. A commit
    /// no tip's first-parent chain reaches (history merged in from a deleted
    /// branch) has no owner.
    public static func owners(in rows: [GraphRow], tips: [BranchTip]) -> [String: BranchTip] {
        let byOid = Dictionary(rows.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        var owners: [String: BranchTip] = [:]
        for tip in tips {
            var next: String? = tip.oid
            while let oid = next, let row = byOid[oid], owners[oid] == nil {
                owners[oid] = tip
                next = row.parents.first
            }
        }
        return owners
    }

    /// The branch an edge is drawn for. A first-parent edge belongs to its
    /// child's branch. Any other parent edge -- the line a merge draws to the
    /// history it merged -- belongs to the branch owning that parent, falling
    /// back to the child's. Both rows the edge spans compute the same answer.
    public static func owner(of edge: LaneEdge, in owners: [String: BranchTip]) -> BranchTip? {
        edge.parentIndex == 0 ? owners[edge.child] : (owners[edge.parent] ?? owners[edge.child])
    }
}

public nonisolated enum BranchColor {
    /// System colours only, so each adapts to light, dark and Increase
    /// Contrast. Yellow and cyan are left out: both read poorly as a 2 pt
    /// stroke on a light background.
    public static let palette: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .red, .mint, .brown,
    ]

    /// FNV-1a (64-bit) over the key's UTF-8 bytes, reduced into `palette`.
    /// Deliberately not `hashValue`: Swift seeds `Hasher` per process, so a
    /// `hashValue`-based colour would change on every launch.
    public static func index(forKey key: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(palette.count))
    }

    /// `nil` -- history no branch owns -- draws in `.secondary`.
    public static func color(for tip: BranchTip?) -> Color {
        guard let tip else { return .secondary }
        return palette[index(forKey: tip.colorKey)]
    }
}
