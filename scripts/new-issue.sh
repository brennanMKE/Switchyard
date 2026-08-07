#!/bin/zsh
# new-issue.sh — allocate the next free issue number and create the file.
#
# Exists because I clobbered resolved issue #0113 with `cat > issues/0113.md`,
# having picked the number from the *open* issue list. A resolved issue still
# owns its number, and `>` overwrites without asking.
#
# Usage:  scripts/new-issue.sh "Title of the issue" [< body-on-stdin]
# Prints the path it created. Refuses to overwrite anything.
setopt ERR_EXIT PIPE_FAIL
cd "${0:A:h}/.."

[[ -n "$1" ]] || { print -u2 "usage: new-issue.sh <title> [< body]"; exit 2 }
title="$1"

# Every file on disk, not just the open ones. Reserved test numbers (8888,
# 9999) must not drag the allocation up with them.
highest=$(ls issues/[0-9]*.md 2>/dev/null \
  | sed 's|.*/||; s|\.md$||' \
  | grep -E '^[0-9]{4}$' \
  | awk '$1 < 8000' \
  | sort -n | tail -1)
: ${highest:=0000}
next=$(printf '%04d' $((10#$highest + 1)))
path="issues/$next.md"

# noclobber makes the redirect fail rather than overwrite, which is the whole
# point of this script.
setopt NO_CLOBBER
if [[ -e "$path" ]]; then
  print -u2 "new-issue: $path already exists — allocation is wrong, not the file"
  exit 1
fi

# zsh/datetime gives strftime as a builtin. `date` is an external the sandbox
# does not reliably expose to a script, same as `cat` above.
zmodload zsh/datetime
strftime -s today '%Y-%m-%d' $EPOCHSECONDS

body=""
# `$(<file)` is a zsh builtin — no external `cat`, which the sandbox does not
# always make available to a script even when the calling shell has it.
[[ -t 0 ]] || body=$(</dev/stdin)

{
  print -r -- "# $next — $title"
  print -r -- ""
  print -r -- "| | |"
  print -r -- "|---|---|"
  print -r -- "| **Status** | open |"
  print -r -- "| **Module** |  |"
  print -r -- "| **Milestone** |  |"
  print -r -- "| **Platform** | macOS |"
  print -r -- "| **First seen** | $today |"
  print -r -- ""
  [[ -n "$body" ]] && print -r -- "$body"
} > "$path"

print -- "$path"
