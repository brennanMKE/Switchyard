// RefChipsTests.swift — history rows label branch and tag tips (#0367)
//
// Imports YardUI WITHOUT `@testable`, same idiom as BranchColorsTests:
// everything asserted here is reachable at exactly the access level the app
// target sees. Every decoration string is one of #0367's measured `%D`
// results, taken on a repository holding both `refs/remotes/origin/main` and
// a local branch literally named `origin/main`; every pinned colour index is
// a result from #0366's measured table.

import SwiftUI
import Testing
import YardGit
import YardUI

private let oid0 = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
private let oid1 = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"

private func ref(_ name: String, _ oid: String) -> RefSnapshot.Entry {
    RefSnapshot.Entry(name: name, oid: oid)
}

@Suite("RefChips")
struct RefChipsTests {

    @Test func attachedTopCommitYieldsHeadBranchThenFeatureThenRemoteThenTags() {
        let refs = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [
                ref("refs/heads/main", oid0),
                ref("refs/heads/feature", oid0),
                ref("refs/remotes/origin/main", oid0),
                ref("refs/remotes/origin/HEAD", oid0),
            ])
        // #0367's measured `%D` for the attached top commit. Branch names
        // come from the snapshot (so `origin/HEAD` never chips), tags from
        // the decoration, in its order.
        let chips = RefChips.make(
            oid: oid0, refs: refs,
            decoration: "HEAD -> main, tag: v2, tag: v1, origin/main, feature")
        #expect(chips.count == 5)
        #expect(chips.map(\.name) == ["main", "feature", "origin/main", "v2", "v1"])
        #expect(chips.map(\.kind) == [.localBranch, .localBranch, .remoteBranch, .tag, .tag])
        #expect(chips.map(\.isHead) == [true, false, false, false, false])
    }

    @Test func localBranchNamedOriginMainYieldsOneLocalChip() throws {
        // Measured: `main` and `refs/remotes/origin/main` sit at the top
        // commit, and the local branch literally named `origin/main` sits one
        // commit down, where `%D` prints just `origin/main` -- the same text
        // the remote prints at the top. The snapshot's full names are what
        // keep this chip local.
        let refs = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [
                ref("refs/heads/main", oid0),
                ref("refs/remotes/origin/main", oid0),
                ref("refs/heads/origin/main", oid1),
            ])
        let chips = RefChips.make(oid: oid1, refs: refs, decoration: "origin/main")
        #expect(chips.count == 1)
        let only = try #require(chips.first)
        #expect(only.name == "origin/main")
        #expect(only.kind == .localBranch)
        #expect(only.isHead == false)
    }

    @Test func detachedHeadChipComesFirst() throws {
        let refs = RefSnapshot(
            head: .detached(oid: oid0),
            refs: [
                ref("refs/heads/main", oid0),
                ref("refs/heads/feature", oid0),
                ref("refs/remotes/origin/main", oid0),
            ])
        // #0367's measured `%D` while detached. No branch is `HEAD`'s, so the
        // locals sort by name behind the detached-`HEAD` chip.
        let chips = RefChips.make(
            oid: oid0, refs: refs,
            decoration: "HEAD, tag: v2, tag: v1, origin/main, main, feature")
        let head = try #require(chips.first)
        #expect(head.name == "HEAD")
        #expect(head.kind == .detachedHead)
        #expect(head.isHead)
        #expect(chips.map(\.name) == ["HEAD", "feature", "main", "origin/main", "v2", "v1"])
        #expect(chips.map(\.kind) == [.detachedHead, .localBranch, .localBranch, .remoteBranch, .tag, .tag])
    }

    @Test func theStashCommitDecoratesNoChips() {
        // Measured: the stash commit's `%D` is `refs/stash` — not a branch, a
        // remote or a `tag:` decoration — and chips are branch, remote, tag
        // and detached-`HEAD` tips only.
        let refs = RefSnapshot(
            head: .symbolic(target: "refs/heads/main"),
            refs: [ref("refs/stash", oid0)])
        let chips = RefChips.make(oid: oid0, refs: refs, decoration: "refs/stash")
        #expect(chips.isEmpty)
    }

    @Test func chipTintsFollowBranchColors() {
        // #0366's pinned table: "main" hashes to palette index 6, "feature"
        // to 9, and a remote chip takes its local counterpart's colour.
        #expect(BranchColor.color(for: RefChip(name: "main", kind: .localBranch, isHead: true))
                == BranchColor.palette[6])
        #expect(BranchColor.color(for: RefChip(name: "origin/feature", kind: .remoteBranch, isHead: false))
                == BranchColor.palette[9])
        #expect(BranchColor.color(for: RefChip(name: "v1", kind: .tag, isHead: false)) == .secondary)
        #expect(BranchColor.color(for: RefChip(name: "HEAD", kind: .detachedHead, isHead: true)) == .orange)
    }
}

@Suite("CommitRowAccessibility")
struct CommitRowAccessibilityTests {

    private func entry(
        oid: String = oid0, parents: [String] = [], author: String = "Ada",
        refs: String = "", message: String
    ) -> CommitLogEntry {
        CommitLogEntry(
            oid: oid, parents: parents, author: author, refs: refs,
            signatureStatus: .noSig, message: message, trailers: [])
    }

    @Test func mergeCommitWithHeadChipSpeaksTheMeasuredLabel() {
        let merge = entry(
            parents: [
                "0000000000000000000000000000000000000001",
                "0000000000000000000000000000000000000002",
            ],
            refs: "HEAD -> main", message: "Merge side\n\nFull body text.")
        let chips = [RefChip(name: "main", kind: .localBranch, isHead: true)]
        #expect(CommitRowAccessibility.label(entry: merge, chips: chips)
                == "Merge side, commit a1b2c3d4e5f6, by Ada, current branch main, merge commit")
    }

    @Test func labelNamesBranchRemoteAndTagChips() {
        let plain = entry(message: "Add a thing")
        let chips = [
            RefChip(name: "feature", kind: .localBranch, isHead: false),
            RefChip(name: "origin/main", kind: .remoteBranch, isHead: false),
            RefChip(name: "v1", kind: .tag, isHead: false),
        ]
        #expect(CommitRowAccessibility.label(entry: plain, chips: chips)
                == "Add a thing, commit a1b2c3d4e5f6, by Ada, branch feature, remote branch origin/main, tag v1")
    }

    @Test func detachedHeadIsSpokenAsDetachedHEAD() {
        let detached = entry(message: "Rebase in progress")
        let chips = [RefChip(name: "HEAD", kind: .detachedHead, isHead: true)]
        #expect(CommitRowAccessibility.label(entry: detached, chips: chips)
                == "Rebase in progress, commit a1b2c3d4e5f6, by Ada, detached HEAD")
    }
}