# The row notation for commit-DAG lane fixtures

**Original to Switchyard (#0025).** The notation is the engine's two graph types — `GraphNode`
and `GraphRow` in `YardKit/Sources/YardGit/LaneAssignment.swift` — flattened onto one line per
commit. It was designed from the shape of those types and from nothing else; no other project's
fixture format was consulted. The parser is test infrastructure:
`DAGFixture` in `YardKit/Tests/YardGitTests/LaneAssignmentFixtureTests.swift`. Nothing in the
shipped engine reads it.

## Grammar

- One line per commit, **children before parents** — the input order `LaneAssigner.assign`
  requires (`git rev-list --topo-order` emission order).
- Every token on a line is `name@lane`: a name (any characters except whitespace and `@`),
  one `@`, and a non-negative integer lane.
- The **first** token is the commit and the lane it must occupy. The **remaining** tokens are its
  parents **in parent order**, each carrying the lane its edge must continue in below the row.
  A line with one token is a root.
- A line whose first non-whitespace character is `#` is a comment. Blank lines are skipped.
  Comments share a line with nothing.
- A parent name that never appears as a commit is a dangling edge — legal, the same shape as a
  parent outside a `--max-count` window.
- Malformed tokens, duplicate commit names, and fixtures with no commit lines are parse errors
  (`DAGFixture.Failure`), never skipped: a silently dropped line would corrupt every expectation
  below it.

## Example

The criss-cross merge (x = b+s, y = s+b, z = x+y), with its expected layout:

    z@0     x@0 y@1
    y@1     s@1 b@2
    x@0     b@0 s@1
    s@1     base@1
    b@0     base@0
    base@0

Line 1 reads: commit `z` occupies lane 0; its first parent `x`'s edge continues in lane 0, its
second parent `y` in lane 1. Decoded, that line is `GraphNode(oid: "z", parents: ["x", "y"])`
and the expectation `GraphRow(oid: "z", parents: ["x", "y"], lane: 0, parentLanes: [0, 1])`.
`parentLanes[0] == lane` holds in every valid layout (rule 3, first-parent inheritance); a fixture
that writes something else fails its test rather than failing to parse.

## Where the cases live

Inline in `LaneAssignmentFixtureTests.swift`, one multiline string literal per case, next to the
test that runs it. Not in separate resource files: the test target declares no resources in
`Package.swift`, and a resource that fails to copy fails silently — inline literals cannot go
stale or missing. The algorithm the cases pin is specified in
`docs/clean-room/graph-lane-assignment.md` (#0075) and #0015.
