// LaneAssignment.swift — commit DAG rows with stable lane assignment (#0015)

import Foundation

/// One commit of the DAG, as `git rev-list --parents` reports it: the
/// commit's oid and its parent oids in parent order.
public struct GraphNode: Sendable, Equatable {
    public let oid: String
    public let parents: [String]

    public init(oid: String, parents: [String]) {
        self.oid = oid
        self.parents = parents
    }
}

/// One row of the laid-out graph: a commit, the lane (column) it occupies,
/// and the lane each of its parent edges continues in below the row.
public struct GraphRow: Sendable, Equatable {
    public let oid: String
    public let parents: [String]

    /// 0-based column of this commit. Lane 0 is the leftmost.
    public let lane: Int

    /// `parentLanes[i]` is the lane the edge toward `parents[i]` runs in
    /// below this row. `parentLanes[0] == lane` always — the first parent
    /// inherits the commit's own lane — and the array is empty for a root.
    public let parentLanes: [Int]

    public init(oid: String, parents: [String], lane: Int, parentLanes: [Int]) {
        self.oid = oid
        self.parents = parents
        self.lane = lane
        self.parentLanes = parentLanes
    }
}

/// Assigns lanes to commits already in topological order (children before
/// parents) — the order `git rev-list --topo-order` emits.
///
/// A lane is a column that is either free or *awaiting* one oid: the commit
/// that, when the walk reaches it, will be drawn in that column. The rules,
/// in the order they are applied to each commit:
///
/// 1. If any lanes await this commit, it occupies the **leftmost** of them
///    and every other lane awaiting it closes — those are its other child
///    edges converging on its row.
/// 2. Otherwise (a tip within this input) it takes the leftmost free lane,
///    or opens a new one at the right edge.
/// 3. Its **first parent inherits its lane**, which is what keeps a line of
///    first-parent history in one straight column.
/// 4. Each remaining parent's edge joins a lane **already awaiting that
///    parent** when one exists; only otherwise does it take the leftmost
///    free lane or open a new one. This check is what keeps repeated merges
///    of one branch from leaking a lane per merge.
/// 5. A root frees its lane for reuse.
///
/// The function is pure: the same input array always produces the same
/// rows, with no dependence on hashing or iteration order.
public enum LaneAssigner {

    public static func assign(_ nodes: [GraphNode]) -> [GraphRow] {
        // lanes[i] is the oid lane i is awaiting, or nil when the lane is
        // free. Lanes are only ever appended, so indices are stable within
        // one call; trailing free lanes cost nothing.
        var lanes: [String?] = []

        func laneAwaiting(_ oid: String) -> Int? {
            lanes.firstIndex(of: oid)
        }

        /// Leftmost free lane, or a new lane at the right edge.
        func allocate(_ oid: String) -> Int {
            if let free = lanes.firstIndex(of: nil) {
                lanes[free] = oid
                return free
            }
            lanes.append(oid)
            return lanes.count - 1
        }

        var rows: [GraphRow] = []
        rows.reserveCapacity(nodes.count)

        for node in nodes {
            let lane: Int
            if let waiting = laneAwaiting(node.oid) {
                // Rule 1: leftmost awaiting lane wins; the rest converge
                // into this row and close.
                for i in lanes.indices where lanes[i] == node.oid {
                    lanes[i] = nil
                }
                lane = waiting
                lanes[lane] = node.oid
            } else {
                // Rule 2: a tip of the input.
                lane = allocate(node.oid)
            }

            var parentLanes: [Int] = []
            parentLanes.reserveCapacity(node.parents.count)
            if let firstParent = node.parents.first {
                // Rule 3: the first parent inherits the lane.
                lanes[lane] = firstParent
                parentLanes.append(lane)
                for parent in node.parents.dropFirst() {
                    // Rule 4: join an awaiting lane before opening one.
                    if let existing = laneAwaiting(parent) {
                        parentLanes.append(existing)
                    } else {
                        parentLanes.append(allocate(parent))
                    }
                }
            } else {
                // Rule 5: a root closes its lane.
                lanes[lane] = nil
            }

            rows.append(GraphRow(
                oid: node.oid,
                parents: node.parents,
                lane: lane,
                parentLanes: parentLanes))
        }
        return rows
    }
}

/// Parses `git rev-list --parents` output: one line per commit, the commit
/// oid followed by its parent oids, all full 40-hex, space-separated.
///
/// Pure function on text — no `Process` construction, no filesystem access.
/// A malformed line throws rather than being dropped: silently losing a
/// commit would corrupt every lane below it.
public struct RevListParser {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A line that is not a space-separated list of 40-hex oids.
        case malformedLine(String)

        public var description: String {
            switch self {
            case let .malformedLine(line):
                "malformed rev-list line: \(line)"
            }
        }
    }

    public init() {}

    public func parse(_ text: String) throws -> [GraphNode] {
        var nodes: [GraphNode] = []
        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let tokens = lineSub.split(separator: " ")
            guard let first = tokens.first,
                  tokens.allSatisfy({ token in
                      token.count == 40 && token.allSatisfy { $0.isHexDigit }
                  }) else {
                throw Failure.malformedLine(String(lineSub))
            }
            nodes.append(GraphNode(
                oid: String(first),
                parents: tokens.dropFirst().map(String.init)))
        }
        return nodes
    }
}

/// Loads the commit DAG of the repository at `path` in topological order and
/// assigns lanes, returning one row per commit, newest first.
///
/// `limit` caps the number of rows (`--max-count`); parents outside the
/// window still appear in `parents`/`parentLanes`, so a renderer can draw
/// their edges running off the bottom. Note the cap does not bound git's own
/// work: `--topo-order` traverses the full history before emitting the first
/// row, which is what the `commit-graph` file makes affordable (#0003:
/// 391 ms → 79 ms for a 100-commit window; `git` plumbing uses the file
/// automatically when it exists). `revisions` are the starting points, e.g.
/// `["HEAD"]` or several refs; a trailing `--` keeps git from reading a
/// revision name as a path. An unborn `HEAD` is an error from git
/// (`fatal: bad revision 'HEAD'`, exit 128), surfacing as
/// `GitProcess.Failure.exited`.
public func graphRows(
    at path: String,
    limit: Int? = nil,
    revisions: [String] = ["HEAD"],
    git: GitProcess = GitProcess()
) throws -> [GraphRow] {
    let output = try git.run(
        graphRowsArguments(limit: limit, revisions: revisions),
        workingDirectory: path
    )
    return LaneAssigner.assign(try RevListParser().parse(output.text))
}

/// Async twin of `graphRows(at:limit:revisions:git:)` (#0344), for callers
/// already on Swift concurrency's cooperative pool: the `git rev-list`
/// subprocess is awaited on the non-blocking `GitProcess` path, so the pool
/// thread is released while git runs. Same arguments (shared
/// `graphRowsArguments`), same parser, same lane assignment.
public func graphRows(
    at path: String,
    limit: Int? = nil,
    revisions: [String] = ["HEAD"],
    git: GitProcess = GitProcess()
) async throws -> [GraphRow] {
    let output = try await git.run(
        graphRowsArguments(limit: limit, revisions: revisions),
        workingDirectory: path
    )
    return LaneAssigner.assign(try RevListParser().parse(output.text))
}

/// The arguments `graphRows` runs, shared by the synchronous and async paths
/// (#0344) so the journal-ref exclusion below cannot drift between them.
private func graphRowsArguments(limit: Int?, revisions: [String]) -> [String] {
    var arguments = ["rev-list", "--topo-order", "--parents"]
    if let limit {
        arguments.append("--max-count=\(limit)")
    }

    // Journal refs are engine bookkeeping and must never appear in the graph.
    // `--exclude` applies only to a FOLLOWING `--all`/`--branches`/`--tags`/
    // `--remotes`, so this is a measured no-op for the default `["HEAD"]` and
    // takes effect exactly when a caller passes `--all` — which the M3 graph
    // view will. Unconditional on purpose: a conditional would have to inspect
    // the revisions array and would miss `--branches`, `--tags`, `--remotes`.
    arguments.append("--exclude=\(RefSnapshot.switchyardNamespace)*")

    // Review-decision notes are the same class of engine bookkeeping (#0059),
    // and --all really does traverse them: measured on git 2.50.1, a
    // repository with `refs/notes/switchyard-review` attached shows the notes
    // ref's own commit as an extra `rev-list --all` row, a node that is not a
    // commit of the repository's history at all. Same placement rule: the
    // pattern must precede the pseudo-option it qualifies.
    arguments.append("--exclude=\(ReviewNotes.refNamespace)*")

    arguments += revisions
    arguments.append("--")
    return arguments
}

// MARK: - Wire encoding (#0133)

/// `GraphRow` is a `schemaVersion: 1` payload component: `graphRows(at:)`
/// returns `[GraphRow]`, which rides as a JSON array in `result`. Plain-stdlib
/// `Encodable` — the engine still imports nothing. (`GraphNode` is parser
/// input, not a payload, and gets no conformance.)
extension GraphRow: Encodable {
    /// Stable wire keys, identical to the member names; no raw values. The
    /// enum is rename-safety; `LogGraphWireTests` pins the bytes.
    private enum CodingKeys: String, CodingKey {
        case oid, parents, lane, parentLanes
    }
}

// MARK: - §6 exit class (#0147)

/// A malformed rev-list line is a repository-state failure — guide §6
/// code 6.
extension RevListParser.Failure: ExitClassCarrying {
    public var exitClass: ExitClass { .repositoryError }
}
