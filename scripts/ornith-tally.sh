#!/usr/bin/env zsh
#
# ornith-tally.sh [--markdown]
#
# Tallies what the local model has actually processed, per issue.
#
# The numbers come from OpenCode's own SQLite database, which records
# tokens_input / tokens_output per session — the dispatch logs carry no token
# counts at all, and LM Studio exposes no historical usage endpoint. This is
# the only durable record, and it survives session ends, unlike the
# subagent_tokens figure a dispatcher reports once.
#
# Issue attribution comes from the session's working directory: a dispatch runs
# in ../switchyard-NNNN, so the worktree name is the issue number. Sessions in
# the primary checkout predate the worktree rule and are grouped as "(main)".
#
# --markdown emits the table for issues/cost-ledger.md.

set -u
setopt ERR_EXIT PIPE_FAIL

DB="$HOME/.local/share/opencode/opencode.db"
[[ -f "$DB" ]] || { print -u2 "ornith-tally: no OpenCode database at $DB"; exit 1 }

MARKDOWN=0
[[ "${1:-}" == "--markdown" ]] && MARKDOWN=1

# Hosted comparison. CLAUDE.md says Ornith "replaces Sonnet here", so Sonnet 5
# list pricing is the honest counterfactual: $3/MTok in, $15/MTok out.
IN_RATE=3.0
OUT_RATE=15.0

QUERY="
SELECT
  CASE
    WHEN directory LIKE '%switchyard-%'
      THEN substr(directory, instr(directory, 'switchyard-') + 11, 4)
    ELSE '(main)'
  END AS issue,
  SUM(tokens_input),
  SUM(tokens_output),
  COUNT(*)
FROM session
WHERE directory LIKE '%switchyard%'
  AND model LIKE '%ornith%'
GROUP BY issue
ORDER BY issue;
"

rows=$(sqlite3 -separator '|' "$DB" "$QUERY")

if (( MARKDOWN )); then
  print "| Issue | Sessions | Input tokens | Output tokens | Total | Hosted equivalent |"
  print "|---|---|---|---|---|---|"
else
  printf "%-8s %9s %14s %13s %14s %12s\n" ISSUE SESSIONS INPUT OUTPUT TOTAL "IF HOSTED"
fi

typeset -i ti=0 to=0 ts=0
while IFS='|' read -r issue tin tout sess; do
  [[ -n "$issue" ]] || continue
  ti+=$tin; to+=$tout; ts+=$sess
  total=$(( tin + tout ))
  cost=$(printf "%.2f" $(( tin / 1000000.0 * IN_RATE + tout / 1000000.0 * OUT_RATE )))
  label=$issue
  [[ "$issue" != "(main)" ]] && label="#$issue"
  if (( MARKDOWN )); then
    printf "| %s | %s | %'d | %'d | %'d | \$%s |\n" "$label" "$sess" "$tin" "$tout" "$total" "$cost"
  else
    printf "%-8s %9s %14s %13s %14s %12s\n" "$label" "$sess" \
      "$(printf "%'d" $tin)" "$(printf "%'d" $tout)" "$(printf "%'d" $total)" "\$$cost"
  fi
done <<< "$rows"

grand=$(( ti + to ))
saved=$(printf "%.2f" $(( ti / 1000000.0 * IN_RATE + to / 1000000.0 * OUT_RATE )))

if (( MARKDOWN )); then
  printf "| **Total** | **%d** | **%'d** | **%'d** | **%'d** | **\$%s** |\n" "$ts" "$ti" "$to" "$grand" "$saved"
  print ""
  print "Actual cost: **\$0.00**. Ornith runs locally in LM Studio; the hosted column is what the"
  print "same traffic would have cost on Sonnet 5 at list price (\$3/MTok in, \$15/MTok out), which is"
  print "the model CLAUDE.md says it replaces."
else
  print ""
  printf "%-8s %9s %14s %13s %14s %12s\n" TOTAL "$ts" \
    "$(printf "%'d" $ti)" "$(printf "%'d" $to)" "$(printf "%'d" $grand)" "\$$saved"
  print ""
  print "Actual cost: \$0.00 — Ornith is local. The last column is what this traffic"
  print "would have cost on Sonnet 5 at list price, the model it replaces here."
fi
