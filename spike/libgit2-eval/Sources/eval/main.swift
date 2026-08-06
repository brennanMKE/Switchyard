// SPIKE — throwaway. Deleted by #0005.
//
// Answers #0001 (does the Homebrew systemLibrary route link and run?) and
// #0004 (can this libgit2 read a --ref-format=reftable repository?).
//
// Usage: eval <repo-path>
// Exits non-zero if any probe fails, so the runner script can gate on it.

import Clibgit2
import Foundation

var failures = 0

// Top-level code is @MainActor in Swift 6, but top-level funcs are not — so
// this needs the annotation to touch `failures`. Worth noting for the real
// codebase, where SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor is already set.
@MainActor
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    let mark = ok ? "PASS" : "FAIL"
    if !ok { failures += 1 }
    print("  [\(mark)] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
}

func lastError() -> String {
    guard let e = git_error_last(), let msg = e.pointee.message else { return "unknown" }
    return String(cString: msg)
}

guard CommandLine.arguments.count > 1 else {
    print("usage: eval <repo-path>")
    exit(2)
}
let path = CommandLine.arguments[1]

git_libgit2_init()
defer { git_libgit2_shutdown() }

var major: Int32 = 0, minor: Int32 = 0, rev: Int32 = 0
git_libgit2_version(&major, &minor, &rev)
print("libgit2 \(major).\(minor).\(rev) — probing \(path)")

// --- open ---------------------------------------------------------------
var repo: OpaquePointer?
let openRC = git_repository_open(&repo, path)
check("open repository", openRC == 0, openRC == 0 ? "" : lastError())
guard openRC == 0, let repo else {
    print("cannot continue without an open repository")
    exit(1)
}
defer { git_repository_free(repo) }

// --- enumerate refs -----------------------------------------------------
var refNames = git_strarray()
let listRC = git_reference_list(&refNames, repo)
let refCount = listRC == 0 ? refNames.count : 0
check("enumerate refs", listRC == 0 && refCount > 0,
      listRC == 0 ? "\(refCount) refs" : lastError())
if listRC == 0 { git_strarray_dispose(&refNames) }

// --- resolve HEAD -------------------------------------------------------
var head: OpaquePointer?
let headRC = git_repository_head(&head, repo)
var headDesc = ""
if headRC == 0, let head {
    if let oid = git_reference_target(head) {
        var buf = [CChar](repeating: 0, count: 41)
        git_oid_fmt(&buf, oid)
        headDesc = String(cString: buf).prefix(10).description
    }
    if let name = git_reference_name(head) {
        headDesc += " (\(String(cString: name)))"
    }
    git_reference_free(head)
}
check("resolve HEAD", headRC == 0, headRC == 0 ? headDesc : lastError())

// --- read reflog --------------------------------------------------------
var reflog: OpaquePointer?
let reflogRC = git_reflog_read(&reflog, repo, "HEAD")
var reflogDesc = ""
if reflogRC == 0, let reflog {
    reflogDesc = "\(git_reflog_entrycount(reflog)) entries"
    git_reflog_free(reflog)
}
check("read HEAD reflog", reflogRC == 0, reflogRC == 0 ? reflogDesc : lastError())

// --- walk a few commits -------------------------------------------------
var walker: OpaquePointer?
var walked = 0
if git_revwalk_new(&walker, repo) == 0, let walker {
    git_revwalk_push_head(walker)
    var oid = git_oid()
    while walked < 100, git_revwalk_next(&oid, walker) == 0 { walked += 1 }
    git_revwalk_free(walker)
}
check("walk commits", walked > 0, "\(walked) walked")

print(failures == 0 ? "  ALL PROBES PASSED" : "  \(failures) PROBE(S) FAILED")
exit(failures == 0 ? 0 : 1)
