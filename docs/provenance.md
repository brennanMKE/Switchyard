# Agent provenance trailers

A commit in this project can be produced by an agent. That fact is part of the commit's identity —
it has to be, because a signed commit carrying provenance trailers is a meaningfully stronger claim
than one without it, and no existing client offers the combination. This file is that contract: the
trailer keys, their value formats, and how parsers (specifically `switchyard log --agent-only`) interpret
them. Change it only on a new block, and be prepared to walk every existing commit back through the
answer.

## The trailers

Three trailers, in this order, following the `Co-authored-by` convention so that existing tooling
ignores them gracefully and only agent-aware consumers read them:

```
Agent-Name: claude-code
Agent-Model: claude-opus-5
Agent-Session: 01J8X...
```

| Trailer | Value format | Required | Example |
| --- | --- | --- | --- |
| `Agent-Name` | Lowercase identifier of the agent runtime that produced the commit. Alphanumerics, dashes, and underscores only; no spaces (the trailer syntax splits on the first colon-and-space). | Yes | `claude-code`, `openhands` |
| `Agent-Model` | The model identifier as reported by the agent at commit time. Whatever the runtime passes to `--model`, verbatim. | Yes | `claude-opus-5`, `gpt-4o` |
| `Agent-Session` | A session or run identifier supplied by the runtime. Opaque to git; meant for correlation with external logs. | Yes | `01J8X...` |

The trailers must appear in the order shown above. A commit carrying them out of order is well-formed
but `switchyard log --agent-only` will not group consecutive agent trailers against the same session; it
will treat each as a separate entry.

## Value constraints

- No leading or trailing whitespace.
- No bare newlines inside the value; a value that spans multiple lines belongs to the commit message,
  not the trailer line. If the agent needs a long session identifier, let it hash or abbreviate rather
  than introducing newlines.
- `Agent-Name` and `Agent-Model` are **written** with canonical casing
  (`Agent-Name: claude-code`, `Agent-Model: claude-opus-5`), but git matches trailer keys
  case-insensitively on read. A commit whose trailer reads `agent-name: Ornith` is still returned by
  `%(trailers:key=Agent-Name,valueonly)`. `switchyard log --agent-only` must therefore accept any
  casing on read while writing the canonical form.
- `Agent-Session` is opaque; it may contain any characters except newlines and control characters.

## Multiple agents on one commit

A commit may carry trailers for more than one agent, but a single provenance line is a claim that the
associated runtime *also* took responsibility for everything in the patch, which makes signing them
together a meaningful act. The convention is:

- One agent takes "primary" ownership. That agent's trailers go first; they are the ones to match
  against for `--agent-only`. If a commit carries both `Agent-Name: claude-code` and
  `Agent-Name: openhands`, a `--agent-only --agent claude-code` filter should include it and
  `--agent-only --agent openhands` should not.
- The remaining agents' trailers are still present and discoverable, but they are secondary: they do
  not affect `--agent-only` matching and a human consumer should read them as "this commit also
  had input from…" rather than as an assertion of joint responsibility.

## Parsing rules for `switchyard log --agent-only`

- A commit is agent-authored if its trailer block contains at least one `Agent-Name:` line.
- The first `Agent-Name:` trailer is the *primary* agent for matching purposes. Subsequent
  `Agent-Name:` trailers are recorded in the output but do not affect inclusion.
- If a commit carries an `Agent-Name:` line with no matching `Agent-Model:` or `Agent-Session:`,
  treat the commit as agent-authored but leave the missing fields blank in `switchyard log` output and
  record a warning on stderr. Do not drop the commit — that would hide an incomplete provenance
  record, which is a more useful signal than silence.
- If a commit carries an `Agent-Model:` or `Agent-Session:` without any preceding `Agent-Name:`,
  ignore those trailers entirely. They look like legacy or accidental copies and have no provenance
  meaning on their own.

## The trailers-versus-notes split (#0059)

Trailers change the commit SHA because they are part of the commit object. Notes live under
`refs/notes/*` and do not touch the SHA at all. The split is:

| Concern | Carrier | When written | Affects signature? |
| --- | --- | --- | --- |
| Agent provenance (who, what model) | Trailer on the commit message | At commit time | Yes — by virtue of being part of the signed blob |
| Review decisions, approvals, `review --wait` outcomes | Note on `refs/notes/switchyard-review` | After the commit exists | No — attaching a note never changes the SHA |

Provenance is not negotiable: signing it means you mean what the signature says. Notes are records
of post-hoc conversation; they must never invalidate a commit because the only reason to record them
is so that a human can look at a commit and see what happened around it without rewriting history to
make the record permanent.

As implemented (#0059), the decision notes carry more obligations than "somewhere to put a reply":

- **The namespace is dedicated and invisible.** `refs/notes/switchyard-review`, never git's default
  `refs/notes/commits`: another tool's notes must not be readable as decisions, and ours must not be
  mistaken for theirs. The engine excludes the namespace everywhere it enumerates ordinary refs —
  `RefSnapshot.capture` does not capture it (a journal restore therefore leaves recorded decisions
  untouched), and `graphRows`' `--all` traversal excludes it (a notes ref has its own commit, which
  is not a commit of the repository's history and must not render as a graph row). `yard log` is the
  one surface that reads it: a commit's entry carries the decision as its optional `note` field.
- **The note body is the decision's JSON** (`ReviewReply` from #0055, `sortedKeys` — the same wire
  shape the XPC reply uses), written by the app-side review flow the moment the human decides. A
  record failure is swallowed and logged, never surfaced as a review failure — the #0160 invariant,
  one surface over.
- **Byte fidelity is the contract.** `git notes add` applies `stripspace` by default, which appends a
  trailing newline to the stored blob; the engine writes with `--no-stripspace` over stdin so the
  stored note is byte-identical to the JSON the flow encoded, and reads back through `git notes show`
  (verbatim) and `%N` (which appends one newline when the note does not end with one — stripped, the
  one measured formatter quirk). That a note never changes the commit SHA is asserted by a test,
  because it is the property everything else here stands on.

The split is documented here once so that the question does not get relitigated for every feature
that touches either carrier. `docs/switchyard-development-guide.md` §6 "Agent provenance" points at
this file; `docs/provenance.md` is the contract.

## Hard constraint: trailer block must be the final paragraph

The entire trailer block must be the **final paragraph** of the commit message. If any prose
follows it, `git interpret-trailers --parse` returns zero trailers and `%(trailers)` produces
nothing — the whole block is silently void. There is no warning, no error code, and no partial
match: git treats the entire block as ordinary commit-message prose.

Trailing blank lines are harmless; git strips them. Verified on git 2.50.1: a message ending in two
blank lines after the block still parses both trailers, while the same message with a single line of
prose appended parses **zero**.

Consequence for #0038: anything that appends text to a commit message after provenance has been
written destroys the entire provenance record with no error. Writers must write the trailer block
last, and anything that rebases or rewrites a commit message must be aware that provenance is lost
if any text follows it in the resulting message.

## Verification against standard tooling

Verify with `git interpret-trailers` so the format is compatible with every git consumer, not just
the ones this project ships:

```sh
printf "test message\n\nAgent-Name: claude-code\nAgent-Model: claude-opus-5\nAgent-Session: 01J8X...\n" \
  | git interpret-trailers --parse
```

Output:

```
Agent-Name: claude-code
Agent-Model: claude-opus-5
Agent-Session: 01J8X...
```

`git interpret-trailers --parse` enumerates every trailer it finds, in order. If this command
produces the three lines above (and nothing else), every git consumer — `git log --format='%(trailers)'`,
pull-request tooling, patchwork — can read these trailers without a custom parser. Switchyard parses
them with its own code so it can do the field-specific rules above (ordering, multiple-agent
handling); `git interpret-trailers` verifies that the raw text is well-formed.
