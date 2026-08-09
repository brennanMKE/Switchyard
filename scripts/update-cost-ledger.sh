#!/bin/zsh
# update-cost-ledger.sh — refresh the Ornith section of issues/cost-ledger.md.
#
# Two kinds of number live in that file and they are maintained differently,
# because their sources differ in one decisive way:
#
#   - Dispatcher and planner figures are reported ONCE, in a completion
#     notification, and exist nowhere else. Not in git, not in a log, not in any
#     API. They are hand-written at the moment they are measured, and anything
#     not written down then is unrecoverable.
#
#   - Ornith figures come from OpenCode's SQLite database, which SURVIVES the
#     session. They are regenerable, so hand-maintaining them is pure downside.
#
# On 2026-08-08 the Ornith numbers were being hand-mirrored per issue anyway.
# Reconciling that mirror against the tally found two issues double-counted
# (#0030 and #0165 — a later cumulative row added without removing the earlier
# per-round one), one short by 513,723 tokens, and seventy-five missing
# outright. The mirror drifted within a single day. So the per-issue rows were
# removed and replaced by one generated section, and this script generates it.
#
# Run it whenever the ledger is being brought up to date.

set -u
setopt ERR_EXIT PIPE_FAIL

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"

LEDGER="issues/cost-ledger.md"
[[ -f "$LEDGER" ]] || { print -u2 "update-cost-ledger: $LEDGER not found"; exit 1 }

TALLY=$(./scripts/ornith-tally.sh) || {
  print -u2 "update-cost-ledger: ornith-tally.sh failed; leaving the ledger untouched."
  exit 1
}

python3 - "$LEDGER" "$TALLY" <<'PY'
import re, sys, pathlib
ledger, tally = pathlib.Path(sys.argv[1]), sys.argv[2]

m = re.search(r"^TOTAL\s+(\d+)\s+([\d,]+)\s+([\d,]+)\s+([\d,]+)\s+\$([\d,.]+)", tally, re.M)
if not m:
    print("update-cost-ledger: could not parse the tally's TOTAL row; ledger untouched.",
          file=sys.stderr)
    raise SystemExit(1)
sessions, tin, tout, ttot, hosted = m.groups()

t = ledger.read_text()

# Recompute the billed total from the rows that are actually present, so a
# hand-added row is picked up and a hand-edited one cannot silently disagree
# with the sum beneath it.
tok = cost = 0
for line in t.split("\n"):
    r = re.match(r"^\| \d{4}-\d{2}-\d{2} \| .*? \| .*? \| ([\d,]+) \| \$([\d.]+) \|$", line)
    if r:
        tok += int(r.group(1).replace(",", ""))
        cost += float(r.group(2))
t = re.sub(r"^\| \| \| \*\*Total measured\*\* \| \*\*[\d,]+\*\* \| \*\*\$[\d.]+\*\* \|$",
           f"| | | **Total measured** | **{tok:,}** | **${cost:.2f}** |",
           t, count=1, flags=re.M)

rows = f"""| | |
|---|---|
| Sessions | **{sessions}** |
| Input tokens | **{tin}** |
| Output tokens | **{tout}** |
| Total tokens | **{ttot}** |
| Actual cost | **$0.00** |
| If hosted on Sonnet 5 at list price | **${hosted}** |"""

# Replace the existing generated block, identified by its header row.
pat = re.compile(r"\| \| \|\n\|---\|---\|\n\| Sessions \|.*?\| If hosted on Sonnet 5 at list price \| \*\*\$[\d,.]+\*\* \|",
                 re.S)
if pat.search(t):
    t = pat.sub(rows, t, count=1)
else:
    print("update-cost-ledger: no Ornith block found to replace — add one first.",
          file=sys.stderr)
    raise SystemExit(1)

ledger.write_text(t)
print(f"cost-ledger: billed {tok:,} tokens, ${cost:.2f}")
print(f"cost-ledger: ornith {ttot} tokens across {sessions} sessions (${hosted} if hosted)")
PY
