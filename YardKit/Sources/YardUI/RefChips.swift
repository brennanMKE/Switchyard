// RefChips.swift
//
// #0358: the ref labels a History row shows at its commit. Branches and
// remote-tracking branches come from `RefSnapshot` (full names, so a local
// branch literally named `origin/main` is not mistaken for the remote one --
// `%D` prints both as `origin/main`, measured). Tags and a detached `HEAD`
// come from `CommitLogEntry.refs` (`%D`), because `%D` peels an annotated tag
// onto its commit while `RefSnapshot.Entry.oid` is the tag object's id.

import SwiftUI
import YardGit

public nonisolated struct RefChip: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case localBranch, remoteBranch, tag, detachedHead
    }

    public let name: String
    public let kind: Kind
    /// The local branch `HEAD` is on, or the detached-`HEAD` chip itself.
    public let isHead: Bool

    public init(name: String, kind: Kind, isHead: Bool) {
        self.name = name
        self.kind = kind
        self.isHead = isHead
    }
}

public nonisolated enum RefChips {
    private static let heads = "refs/heads/"
    private static let remotes = "refs/remotes/"

    /// Chips for the commit `oid`, in display order: `HEAD`'s branch (or the
    /// detached `HEAD`), other local branches, remote-tracking branches, tags.
    public static func make(oid: String, refs: RefSnapshot, decoration: String) -> [RefChip] {
        let decorations = decoration.isEmpty ? [] : decoration.components(separatedBy: ", ")
        var headBranch: String?
        if case let .symbolic(target) = refs.head, target.hasPrefix(heads) {
            headBranch = String(target.dropFirst(heads.count))
        }
        var chips: [RefChip] = []
        if decorations.contains("HEAD") {
            chips.append(RefChip(name: "HEAD", kind: .detachedHead, isHead: true))
        }
        let locals = refs.refs
            .filter { $0.oid == oid && $0.name.hasPrefix(heads) }
            .map { String($0.name.dropFirst(heads.count)) }
            .sorted { ($0 == headBranch ? 0 : 1, $0) < ($1 == headBranch ? 0 : 1, $1) }
        chips += locals.map { RefChip(name: $0, kind: .localBranch, isHead: $0 == headBranch) }
        chips += refs.refs
            .filter { $0.oid == oid && $0.name.hasPrefix(remotes) && !$0.name.hasSuffix("/HEAD") }
            .map { String($0.name.dropFirst(remotes.count)) }
            .sorted()
            .map { RefChip(name: $0, kind: .remoteBranch, isHead: false) }
        chips += decorations
            .filter { $0.hasPrefix("tag: ") }
            .map { RefChip(name: String($0.dropFirst("tag: ".count)), kind: .tag, isHead: false) }
        return chips
    }
}

public nonisolated enum CommitRowAccessibility {
    /// One VoiceOver label for a whole History row -- the gutter itself is
    /// `accessibilityHidden`, so the topology it draws is spoken here.
    public static func label(entry: CommitLogEntry, chips: [RefChip]) -> String {
        var parts = [entry.subject, "commit \(entry.shortOid)", "by \(entry.author)"]
        for chip in chips {
            switch chip.kind {
            case .localBranch: parts.append(chip.isHead ? "current branch \(chip.name)" : "branch \(chip.name)")
            case .remoteBranch: parts.append("remote branch \(chip.name)")
            case .tag: parts.append("tag \(chip.name)")
            case .detachedHead: parts.append("detached HEAD")
            }
        }
        if entry.parents.count > 1 { parts.append("merge commit") }
        return parts.joined(separator: ", ")
    }
}

extension BranchColor {
    /// #0367's chip tint: a branch chip takes its branch's colour, a remote
    /// chip its local counterpart's, and tags stay neutral. `nonisolated`
    /// matches the enum's own declaration in BranchColors.swift; without it
    /// the target's default isolation makes the method `@MainActor` and the
    /// nonisolated tests calling it do not compile.
    nonisolated public static func color(for chip: RefChip) -> Color {
        switch chip.kind {
        case .localBranch: palette[index(forKey: chip.name)]
        case .remoteBranch: color(for: BranchTip(name: chip.name, oid: "", isRemote: true))
        case .tag: .secondary
        case .detachedHead: .orange
        }
    }
}