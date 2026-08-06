// YardGit.swift

import Clibgit2

/// The engine's entry point and version surface.
///
/// `YardGit` is deliberately standalone: it does not import `YardKit`, know
/// about XPC, or require the app to be running. Every read command and every
/// non-interactive mutation runs in-process here, which is what lets `yard`
/// work in CI, over SSH, and in headless agent runs.
public enum YardGit {
    /// The libgit2 version this build links against.
    ///
    /// libgit2 handles the object database, diff, blame, and merge. Refs,
    /// `HEAD`, the reflog, and DAG traversal go through `git` plumbing
    /// instead — libgit2 cannot read reftable repositories and is slower on
    /// the graph path. See `docs/engine-findings.md`.
    public static var libgit2Version: (major: Int, minor: Int, revision: Int) {
        var major: Int32 = 0, minor: Int32 = 0, rev: Int32 = 0
        git_libgit2_version(&major, &minor, &rev)
        return (Int(major), Int(minor), Int(rev))
    }

    /// Initializes libgit2. Safe to call more than once; libgit2 refcounts it.
    @discardableResult
    public static func initialize() -> Int {
        Int(git_libgit2_init())
    }

    /// Balances `initialize()`.
    @discardableResult
    public static func shutdown() -> Int {
        Int(git_libgit2_shutdown())
    }
}
