// 0591GitAssertionsUITests.swift
//
// #0591: the XCUITest runner in the guest can run /usr/bin/git against the
// history fixture and read what every history spike asserts on. No app
// launch: the claim is about the runner process, not the app.

import XCTest

final class Spike0591GitAssertionsUITests: XCTestCase {
    func testTheRunnerReadsTheHistoryFixtureWithGit() {
        let repo = GitRepo(path: HistoryFixture.path("merge-ff"))
        XCTAssertEqual(repo.headBranch(), "main")
        XCTAssertEqual(repo.subjects("main"),
                       [HistoryFixture.mainTipSubject, HistoryFixture.mainThreeSubject,
                        HistoryFixture.sharedSubject, HistoryFixture.rootSubject])
        XCTAssertEqual(repo.parents(of: "main"), [repo.oid("main~1")])
        XCTAssertEqual(repo.parents(of: "main~3"), [])
        XCTAssertEqual(repo.message(of: "ff-topic"), HistoryFixture.ffSubject)
        XCTAssertEqual(repo.lsTree("main"), ["README.md", "main3.txt", "main4.txt", "shared.txt"])
        XCTAssertEqual(repo.fileContents(at: "shared.txt"), "alpha\nbeta from main\ngamma")
        XCTAssertEqual(repo.worktreeFile("main4.txt"), "main four")
        XCTAssertTrue(repo.isClean(), "fixture copy is dirty: \(repo.porcelain())")
        XCTAssertEqual(repo.oid("v1.0"), repo.oid("main~2"))
        XCTAssertFalse(repo.isMidMerge())
        XCTAssertEqual(GitRepo(path: HistoryFixture.path("rebase")).headBranch(), "rebase-topic")
        XCTAssertEqual(GitRepo(path: HistoryFixture.path("rebase-conflict")).headBranch(), "clash-topic")
        XCTAssertEqual(GitRepo(path: HistoryFixture.path("squash")).subjects("stack").prefix(4),
                       ArraySlice(HistoryFixture.stackSubjects))
    }
}
