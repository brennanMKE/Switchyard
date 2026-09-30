// RemoteGroupsTests.swift — the sidebar's Remotes section groups (#0532)

import Testing
import YardGit
import YardUI

@Suite("Sidebar remote groups")
struct RemoteGroupsTests {
    private let origin = RemoteConfig.Remote(name: "origin", fetchURL: "/r/o.git", pushURLs: ["/r/o.git"])
    private let backup = RemoteConfig.Remote(name: "backup", fetchURL: "/r/b.git", pushURLs: ["/r/b.git"])
    private let fresh = RemoteConfig.Remote(name: "fresh", fetchURL: "/r/f.git", pushURLs: ["/r/f.git"])

    private func ref(_ short: String) -> RefSnapshot.Entry {
        RefSnapshot.Entry(name: "refs/remotes/" + short, oid: "a1b2c3d")
    }

    @Test func eachRemoteLeadsItsBranchesAndUnownedBranchesComeLast() {
        let groups = RepositorySidebarView.remoteGroups(
            remotes: [origin, backup, fresh],
            branches: [ref("backup/main"), ref("gone/x"), ref("origin/main"), ref("origin/topic")],
            query: "")
        #expect(groups.map(\.remote?.name) == ["backup", "fresh", "origin", nil])
        #expect(groups.map { $0.branches.map(\.name) } == [
            ["refs/remotes/backup/main"], [],
            ["refs/remotes/origin/main", "refs/remotes/origin/topic"],
            ["refs/remotes/gone/x"],
        ])
    }

    @Test func whileFilteringARemoteShowsWhenItsNameOrABranchMatches() {
        // The caller passes branches already narrowed by the query.
        let groups = RepositorySidebarView.remoteGroups(
            remotes: [origin, backup, fresh], branches: [ref("origin/topic")], query: "topic")
        #expect(groups.map(\.remote?.name) == ["origin"])
        let byName = RepositorySidebarView.remoteGroups(
            remotes: [origin, backup, fresh], branches: [], query: "fre")
        #expect(byName.map(\.remote?.name) == ["fresh"])
        #expect(RepositorySidebarView.remoteGroups(remotes: [origin], branches: [], query: "zzz").isEmpty)
    }

    @Test func theHelpTextNamesThePushURLOnlyWhenItDiffers() {
        #expect(RepositorySidebarView.remoteHelpText(origin) == "Fetch: /r/o.git")
        let split = RemoteConfig.Remote(name: "gh", fetchURL: "https://h/a.git", pushURLs: ["git@h:a.git"])
        #expect(RepositorySidebarView.remoteHelpText(split) == "Fetch: https://h/a.git\nPush: git@h:a.git")
        let bare = RemoteConfig.Remote(name: "x", fetchURL: nil, pushURLs: [])
        #expect(RepositorySidebarView.remoteHelpText(bare) == "Fetch: no URL")
    }
}
