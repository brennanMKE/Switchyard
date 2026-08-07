# Commit graph lane assignment

**Written 2026-08-06, before #0015.** Understanding formed from: GitUp's README, which names
`GIGraphView` as the class rendering its Map view; the measured behavior of `git rev-list
--topo-order --parents` recorded in `docs/engine-findings.md` (#0003); and git's documentation for
`commit-graph` and generation numbers. GitUp's graph implementation and its test fixtures were not
consulted, and must not be — **its fixtures are GPLv3 test data and copying them would be copying
code.**

## The problem

A commit DAG has to be drawn as rows and columns. Each commit occupies one row in topological order;
each column ("lane") is a vertical track that an edge follows between commits. The layout has to be:

- **Stable** — the same history produces the same lanes every time, or scrolling makes branches
  appear to jump between columns.
- **Narrow** — a repository with hundreds of merged branches must not produce hundreds of columns.
- **Incremental** — computable for a visible window without laying out all 80,000 commits.

The third is where the naive approach fails, and #0003 measured why: **topological order costs a
full history traversal regardless of window size.** A 100-commit window took the same time as a
20,000-commit one, because `--topo-order` must see the whole DAG before it can emit the first row
correctly. Windowing the *display* does not window the *cost*.

## The shape of the algorithm

Walk commits in topological order maintaining a set of open lanes, each holding the OID it is waiting
to draw next.

For each commit:
1. If a lane is already waiting for this commit, it occupies that lane — this is what makes a branch
   keep its column instead of wandering.
2. Otherwise it takes the leftmost free lane, or opens a new one.
3. Its **first parent inherits the lane**, which keeps mainline history in a straight column.
4. Its **remaining parents open lanes of their own**, unless some lane is already waiting for them —
   that check is what prevents a lane leak at every merge.

Step 4's condition is the one that matters. The measurement spike omitted it properly and produced
**4,145 open lanes for 20,000 commits**, which is both visually useless and the reason its lane
assignment cost 2.1 seconds. A correct implementation compacts: a lane whose commit has been drawn
and whose parent is already tracked elsewhere is freed immediately for reuse.

## Performance constraints from #0003

- **Use the `commit-graph`.** With it, a 100-commit window loads in 79 ms via plumbing; without it,
  391 ms. Switchyard keeps the file fresh in the background.
- **Refs and traversal come from `git` plumbing, not libgit2** — libgit2 cannot open reftable
  repositories at all and showed no benefit from the commit-graph.
- **Lane assignment, not loading, is the scaling problem** past a few thousand rows. Budget
  accordingly: the data source is settled, the algorithm is not.
- Treat the spike's 2.1 s at 20,000 commits as an **upper bound to beat**, not a prediction.

## Testing

Table-driven, with an **original** text notation for a DAG paired with its expected lane assignment,
one file per case. The notation is designed here rather than borrowed, and the cases are written from
scratch: linear, simple branch and merge, criss-cross merge, octopus merge, multiple roots, orphan
branch.

Per #0025, the suite must be verified by deliberately breaking lane assignment and confirming a
fixture fails. A fixture suite that passes against broken code is worse than none.

## What to implement from this

`#0015` builds the traversal and lane assignment against `git rev-list --topo-order --parents`, with
`#0025` supplying the fixtures. The design note is the input; GitUp is not.
