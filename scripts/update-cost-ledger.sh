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

# The Ornith figures live in issues/ornith-tally.md, which ornith-tally.sh
# regenerates in full. Refresh it rather than mirroring anything into the ledger.
./scripts/ornith-tally.sh --write >/dev/null

python3 - "$LEDGER" <<'PY'
import re, sys, pathlib
ledger = pathlib.Path(sys.argv[1])
t = ledger.read_text()

# Recompute the billed total from the rows actually present, so a hand-added row
# is picked up and a hand-edited one cannot silently disagree with the sum.
tok = cost = 0
for line in t.split("\n"):
    r = re.match(r"^\| \d{4}-\d{2}-\d{2} \| .*? \| .*? \| ([\d,]+) \| \$([\d.]+) \|$", line)
    if r:
        tok += int(r.group(1).replace(",", ""))
        cost += float(r.group(2))

stray = [l for l in t.split("\n")
         if re.match(r"^\| \d{4}-\d{2}-\d{2} \|", l) and "Ornith" in l]
if stray:
    print(f"update-cost-ledger: WARNING — {len(stray)} per-issue Ornith row(s) are back in the",
          file=sys.stderr)
    print("    ledger. Those belong in issues/ornith-tally.md; mirroring them here double-counts.",
          file=sys.stderr)

t = re.sub(r"^\| \| \| \*\*Total measured\*\* \| \*\*[\d,]+\*\* \| \*\*\$[\d.]+\*\* \|$",
           f"| | | **Total measured** | **{tok:,}** | **${cost:.2f}** |",
           t, count=1, flags=re.M)
ledger.write_text(t)
print(f"cost-ledger: billed {tok:,} tokens, ${cost:.2f}")
print("ornith-tally: regenerated from OpenCode's database")
PY
