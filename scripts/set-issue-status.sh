#!/usr/bin/env zsh
#
# set-issue-status.sh NNNN <status>
#
# Sets an issue's Status row to one of the five valid values, and refuses
# anything else. The tracker is what a human reads to know the state of the
# work, so an invalid or stale status is worse than no tracker at all.
#
#   open         filed, not started
#   in-progress  actively being worked — a dispatch is running or under review
#   resolved     work landed on main, awaiting Brennan's confirmation
#   closed       Brennan confirmed. Only he sets this.
#   wontfix      acknowledged, will not be addressed
#
# Exit 0 set, 1 usage/validation error.

set -u
setopt ERR_EXIT PIPE_FAIL

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"

ISSUE="${1:-}"
STATUS="${2:-}"

VALID=(open in-progress resolved closed wontfix)

if [[ -z "$ISSUE" || -z "$STATUS" ]]; then
  print -u2 "usage: set-issue-status.sh NNNN <${(j:|:)VALID}>"
  exit 1
fi

FILE="issues/$ISSUE.md"
[[ -f "$FILE" ]] || { print -u2 "set-issue-status: $FILE does not exist"; exit 1 }

if [[ ${VALID[(Ie)$STATUS]} -eq 0 ]]; then
  print -u2 "set-issue-status: '$STATUS' is not a valid status.
Valid: ${(j:, :)VALID}
'closed' is Brennan's to set, not ours — use 'resolved' when work lands."
  exit 1
fi

CURRENT=$(grep -m1 '^| \*\*Status\*\*' "$FILE" | awk -F'|' '{gsub(/ /,"",$3); print $3}' || true)
[[ -n "$CURRENT" ]] || { print -u2 "set-issue-status: no Status row in $FILE"; exit 1 }

if [[ "$CURRENT" == "$STATUS" ]]; then
  print "#$ISSUE already $STATUS"
  exit 0
fi

# Only the first Status row — a ## Review section may quote others.
perl -0pi -e "s/\Q| **Status** | $CURRENT |\E/| **Status** | $STATUS |/" "$FILE"

NEW=$(grep -m1 '^| \*\*Status\*\*' "$FILE" | awk -F'|' '{gsub(/ /,"",$3); print $3}')
[[ "$NEW" == "$STATUS" ]] || { print -u2 "set-issue-status: edit did not take (still '$NEW')"; exit 1 }

print "#$ISSUE  $CURRENT → $STATUS"
