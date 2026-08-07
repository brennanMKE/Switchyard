# Clean-room design notes

Switchyard is **MIT**; GitUp is **GPLv3**. That makes the separation strict rather than optional, and
these notes are the artifact that makes "clean-room" a description of the process rather than a claim
about intent.

## The process, and why the note is required

For each concept GitUp solved that Switchyard also needs:

1. Read GitUp — or, where its own documentation is sufficient, read that — to understand **what
   problem the component solves** and **why it is shaped that way**.
2. **Close the source.**
3. Write a note here, in your own words, describing the problem and the approach Switchyard will
   take. Cite git's documented behavior and first principles, not GitUp's implementation.
4. Implement from the note.

The note is not paperwork. Implementing from a note written from understanding produces independent
code; implementing with the source open produces a translation, and a line-by-line Objective-C to
Swift translation is a derivative work regardless of how it is phrased.

**Never** paste GitUp source into a context window and ask for a Swift port. **Never** copy its test
fixtures — test data counts.

## What is recorded here

| Note | Covers | Written before |
|---|---|---|
| [snapshot-and-undo.md](snapshot-and-undo.md) | Why undo restores state rather than inverting operations | #0027 |
| [graph-lane-assignment.md](graph-lane-assignment.md) | Laying out a commit DAG in columns | #0015 |
| [rebase-engine-scope.md](rebase-engine-scope.md) | Why stock rebase is insufficient, and how little we need | #0060 |

Each note records the date it was written and what was read to form the understanding, so the
sequence — read, close, write, implement — is auditable after the fact.
