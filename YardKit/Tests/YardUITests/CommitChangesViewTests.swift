// CommitChangesViewTests.swift
//
// #0404: the change-kind rule, the title, and the view's public surface.
// No `@testable`: these are public API the app target (#0406) calls.
// The header texts are the ones measured from `git diff-tree` in #0404.

import Testing
import SwiftUI
import YardGit
import YardUI

private func file(_ header: String) -> FileDiff {
    FileDiff(path: "a.txt", oldMode: nil, newMode: nil, isBinary: false,
             headerText: header, hunks: [])
}

@Test("a new-file header is an added file")
func newFileHeaderIsAdded() {
    let f = file("diff --git a/a.txt b/a.txt\nnew file mode 100644\nindex 0000000..7898192\n")
    #expect(FileChangeKind.of(f) == .added)
}

@Test("a deleted-file header is a deleted file")
func deletedFileHeaderIsDeleted() {
    let f = file("diff --git a/a.txt b/a.txt\ndeleted file mode 100644\nindex 7898192..0000000\n")
    #expect(FileChangeKind.of(f) == .deleted)
}

@Test("a header with neither line is a modified file")
func plainHeaderIsModified() {
    let f = file("diff --git a/b.txt b/b.txt\nindex 6178079..2997ea2 100644\n")
    #expect(FileChangeKind.of(f) == .modified)
}

@Test("the title is the first 10 characters of the oid, then the subject")
func titleIsShortOidThenSubject() {
    let target = CommitChangesTarget(
        repositoryPath: "fixture-repo-path",
        oid: "0123456789abcdef0123456789abcdef01234567",
        subject: "Fix the thing")
    #expect(target.title == "0123456789 Fix the thing")
}

@MainActor
@Test("CommitChangesView is constructible at a caller's access level")
func commitChangesViewIsPubliclyConstructible() {
    let target = CommitChangesTarget(repositoryPath: "fixture-repo-path", oid: "abc", subject: "s")
    let view = CommitChangesView(target: target)
    _ = view.body
    #expect(String(describing: CommitChangesView.self) == "CommitChangesView")
}
