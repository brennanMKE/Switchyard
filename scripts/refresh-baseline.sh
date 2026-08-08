#!/bin/zsh
# refresh-baseline.sh NNNN [NNNN …] — point an issue's stated suite count at main's.
#
# Why this exists: preflight check 4b is hard, and it fires whenever an issue
# quotes a suite count that main has since moved past. On 2026-08-08 that
# happened SEVEN times in one session — #0032, #0033, #0155, #0172 and others —
# because every merged issue moves the baseline under every planned issue behind
# it. The fix was always the same two-minute edit, and doing it by hand invites
# the mistake that cost #0032 an extra rejection: putting the CURRENT number
# somewhere after the historical one, when the check reads the FIRST number
# following `test-baseline.txt`.
#
# So this rewrites exactly that number and leaves the surrounding prose alone.
# It does not touch deltas — the delta is the criterion and is never stale.
#
# Exit 0 changed (or already current) · 1 usage/notfound · 2 no anchor to rewrite

set -u
setopt ERR_EXIT

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"

(( $# )) || { print -u2 "usage: refresh-baseline.sh NNNN [NNNN …]"; exit 1 }

CURRENT=$(<docs/test-baseline.txt)
CURRENT="${CURRENT//[[:space:]]/}"
[[ "$CURRENT" == <-> ]] || { print -u2 "refresh-baseline: docs/test-baseline.txt is not a number"; exit 1 }

RC=0
for ISSUE in "$@"; do
  FILE="issues/$ISSUE.md"
  [[ -f "$FILE" ]] || { print -u2 "refresh-baseline: $FILE does not exist"; RC=1; continue }

  # The anchor preflight itself uses: the first number within 30 characters
  # after `test-baseline.txt`. Rewrite that one occurrence and nothing else.
  BEFORE=$(python3 - "$FILE" "$CURRENT" <<'PY'
import re, sys
path, current = sys.argv[1], sys.argv[2]
t = open(path).read()
m = re.search(r'(test-baseline\.txt[^0-9]{0,30})(\d+)', t)
if not m:
    print("NOANCHOR"); raise SystemExit
old = m.group(2)
if old == current:
    print("CURRENT"); raise SystemExit
t = t[:m.start(2)] + current + t[m.end(2):]
open(path, "w").write(t)
print(old)
PY
)
  case "$BEFORE" in
    NOANCHOR) print -u2 "refresh-baseline: #$ISSUE names no 'test-baseline.txt' figure to rewrite"; RC=2 ;;
    CURRENT)  print "refresh-baseline: #$ISSUE already states $CURRENT" ;;
    *)        print "refresh-baseline: #$ISSUE  $BEFORE → $CURRENT" ;;
  esac
done
exit $RC
