// SPIKE — throwaway. Deleted by #0005.
//
// #0003: how fast can we load a large repository and compute lane assignments
// for a visible window?
//
// Measures both candidate paths, because #0004 forced the question:
//   libgit2  — in-process revwalk (unusable on reftable repos)
//   plumbing — `git rev-list --parents` (works everywhere)
//
// Run each with and without a commit-graph file present. Lane assignment is a
// deliberately simple algorithm written from scratch for measurement only —
// #0015 designs the real one, and GitUp's is GPLv3 and was not consulted.

import Clibgit2
import Foundation

@MainActor
func now() -> Double { Date().timeIntervalSince1970 }

struct Node {
    let oid: String
    let parents: [String]
}

/// Minimal lane assignment: walk commits in the order given, keep a set of
/// open lanes each holding the OID it is waiting for, and reuse the lane a
/// commit was expected in. Enough to measure cost; not the shipping algorithm.
@MainActor
func assignLanes(_ nodes: [Node]) -> Int {
    var lanes: [String?] = []
    var maxLane = 0
    for node in nodes {
        var lane = lanes.firstIndex { $0 == node.oid }
        if lane == nil {
            lane = lanes.firstIndex { $0 == nil } ?? lanes.count
            if lane! == lanes.count { lanes.append(nil) }
        }
        maxLane = max(maxLane, lane!)
        // First parent continues in this lane; the rest open their own.
        if let first = node.parents.first {
            lanes[lane!] = first
        } else {
            lanes[lane!] = nil
        }
        for extra in node.parents.dropFirst() {
            if !lanes.contains(where: { $0 == extra }) {
                if let free = lanes.firstIndex(where: { $0 == nil }) {
                    lanes[free] = extra
                } else {
                    lanes.append(extra)
                }
            }
        }
    }
    return maxLane + 1
}

@MainActor
func viaLibgit2(_ path: String, limit: Int) -> (nodes: [Node], seconds: Double)? {
    let t0 = now()
    var repo: OpaquePointer?
    guard git_repository_open(&repo, path) == 0, let repo else { return nil }
    defer { git_repository_free(repo) }

    var walker: OpaquePointer?
    guard git_revwalk_new(&walker, repo) == 0, let walker else { return nil }
    defer { git_revwalk_free(walker) }
    git_revwalk_sorting(walker, GIT_SORT_TOPOLOGICAL.rawValue)
    git_revwalk_push_head(walker)

    var nodes: [Node] = []
    nodes.reserveCapacity(limit)
    var oid = git_oid()
    while nodes.count < limit, git_revwalk_next(&oid, walker) == 0 {
        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { break }
        var buf = [CChar](repeating: 0, count: 41)
        git_oid_fmt(&buf, &oid)
        let selfOid = String(cString: buf)
        var parents: [String] = []
        for i in 0..<git_commit_parentcount(commit) {
            if let pid = git_commit_parent_id(commit, i) {
                var pbuf = [CChar](repeating: 0, count: 41)
                git_oid_fmt(&pbuf, pid)
                parents.append(String(cString: pbuf))
            }
        }
        nodes.append(Node(oid: selfOid, parents: parents))
        git_commit_free(commit)
    }
    return (nodes, now() - t0)
}

@MainActor
func viaPlumbing(_ path: String, limit: Int) -> (nodes: [Node], seconds: Double)? {
    let t0 = now()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", path, "rev-list", "--topo-order", "--parents",
                   "--max-count=\(limit)", "HEAD"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return nil }

    var nodes: [Node] = []
    nodes.reserveCapacity(limit)
    for line in text.split(separator: "\n") {
        let ids = line.split(separator: " ").map(String.init)
        guard let head = ids.first else { continue }
        nodes.append(Node(oid: head, parents: Array(ids.dropFirst())))
    }
    return (nodes, now() - t0)
}

// ---------------------------------------------------------------------------
let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: perf <repo-path> <limit> [label]")
    exit(2)
}
let repoPath = args[1]
let limit = Int(args[2]) ?? 1000
let label = args.count > 3 ? args[3] : ""

git_libgit2_init()
defer { git_libgit2_shutdown() }

print("── window \(limit) commits \(label.isEmpty ? "" : "— \(label)")")

if let (nodes, load) = viaLibgit2(repoPath, limit: limit) {
    let t1 = now()
    let lanes = assignLanes(nodes)
    let layout = now() - t1
    print(String(format: "   libgit2   load %7.1f ms   lanes %6.1f ms   total %7.1f ms   (%d commits, %d lanes)",
                 load * 1000, layout * 1000, (load + layout) * 1000, nodes.count, lanes))
} else {
    print("   libgit2   UNAVAILABLE (cannot open repository)")
}

if let (nodes, load) = viaPlumbing(repoPath, limit: limit) {
    let t1 = now()
    let lanes = assignLanes(nodes)
    let layout = now() - t1
    print(String(format: "   plumbing  load %7.1f ms   lanes %6.1f ms   total %7.1f ms   (%d commits, %d lanes)",
                 load * 1000, layout * 1000, (load + layout) * 1000, nodes.count, lanes))
} else {
    print("   plumbing  FAILED")
}
