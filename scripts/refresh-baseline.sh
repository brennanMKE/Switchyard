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

  # Rewrite every number preflight check 4b would read, using its exact anchor.
  BEFORE=$(python3 - "$FILE" "$CURRENT" <<'PY'
import re, sys
path, current = sys.argv[1], sys.argv[2]
t = open(path).read()

# EXACTLY preflight check 4b's anchor, and EVERY match — not just the first.
# #0031 stated the baseline twice: `refresh-baseline` rewrote the first, and
# preflight kept failing on the second, which reads as the script not working.
# The check scans them all, so they must all be current or none of them may use
# this phrasing.
# THREE-to-four digits, never two. preflight's own reader accepts {2,4}, but it
# only READS; this REWRITES, so it must be strictly more conservative. #0040
# phrased its criterion as "the count in `docs/test-baseline.txt`, by **exactly
# 13**" — the anchor matched, the delta was two digits, and the script rewrote
# the DELTA as 724, destroying the round's actual criterion. Suite counts here
# are in the hundreds; deltas are one or two digits. That is the discriminator.
#
# The negative lookbehind is the second guard: a number introduced by "by" or
# "exactly" is a delta being described, not a baseline being stated.
ANCHOR = re.compile(
    r'(test-baseline\.txt[^0-9]{0,30}|main(?:[^0-9.]{0,20}(?:is|reported|suite is))[^0-9]{0,10})'
    # NOT preceded by '#': `#0043` is an ISSUE REFERENCE, not a suite count, and
    # the script rewrote one as `#761` in #0181 — mangling a cross-reference.
    # NOT zero-padded for the same reason: suite counts are never `0761`.
    r'(\*{0,2})(?<!by \*\*)(?<!exactly )(?<!exactly \*\*)(?<![#0-9])([1-9][0-9]{2,3})'
)
# KNOWN LIMITATION, shared with preflight check 4b: both look for the number
# AFTER the `test-baseline.txt` mention. #0181 wrote "The suite on `main`
# currently reads **737** tests (`docs/test-baseline.txt` is the anchor…)" —
# baseline first, anchor second — so neither tool could see the stale 737, and
# the anchor match landed on the following `#0043` instead. Guarded now against
# rewriting the wrong token, but a baseline stated BEFORE the anchor still needs
# a human. Planners are told to put the current baseline first in the sentence;
# this is the cost of that instruction being followed too literally.
found = list(ANCHOR.finditer(t))
if not found:
    print("NOANCHOR"); raise SystemExit
olds = [m.group(3) for m in found]
if all(o == current for o in olds):
    print("CURRENT"); raise SystemExit
out, last = [], 0
for m in found:
    out.append(t[last:m.start(3)]); out.append(current); last = m.end(3)
out.append(t[last:])
open(path, "w").write("".join(out))
print(",".join(sorted(set(o for o in olds if o != current))))
PY
)
  case "$BEFORE" in
    NOANCHOR) print -u2 "refresh-baseline: #$ISSUE names no 'test-baseline.txt' figure to rewrite"; RC=2 ;;
    CURRENT)  print "refresh-baseline: #$ISSUE already states $CURRENT" ;;
    *)        print "refresh-baseline: #$ISSUE  $BEFORE → $CURRENT" ;;
  esac

  # Rewriting the anchor is not the whole job, and #0167 proved it: the refresh
  # moved the anchor 663 → 674 and left the round-2 TARGET at the scratch tree's
  # stale 673 further down. A transcribing round would have measured 684 against
  # a stated 673 with no way to know which was wrong, and preflight's own check
  # passed because it only reads the anchor. Those other figures cannot be
  # rewritten safely — a target is baseline PLUS a delta, and some are
  # deliberately historical — so surface them and let a human decide.
  python3 - "$FILE" "$CURRENT" <<'PY'
import re, sys
path, current = sys.argv[1], sys.argv[2]
cur = int(current)
suspect = []
for n, line in enumerate(open(path), 1):
    for m in re.finditer(r'Test run with \*{0,2}(\d{3,4})', line):
        v = int(m.group(1))
        # Plausibly a stale suite figure: near the current baseline but not a
        # sane target (baseline + a small delta). Wide net, human adjudicates.
        if v != cur and not (cur < v <= cur + 60):
            suspect.append((n, v, line.strip()[:88]))
if suspect:
    print(f"refresh-baseline: WARNING — other suite figures in {path} that are not {current}:")
    for n, v, s in suspect:
        print(f"    line {n}: {v}   {s}")
    print("    A target should be the baseline plus this issue's delta. Check each is")
    print("    intended as history rather than a stale number a round would measure against.")
PY
done
exit $RC
