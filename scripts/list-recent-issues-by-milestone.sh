#!/usr/bin/env zsh
# List issues grouped by milestone with per-milestone status counts.
#
# Top: a compact status table (one row per milestone) showing open / in-
# progress / resolved totals.
# Bottom: the issues themselves, grouped by relevance (fresh > open >
# resolved) with their milestone column alongside.

set -euo pipefail
zmodload zsh/datetime

SCRIPT_NAME="${0##*/}"
LIMIT=50            # per-milestone cap; 0 = no limit
COLOR_MODE=auto
SHOW_ALL=0

FRESH_SECS=172800   # 2 days
WEEK_SECS=604800    # 7 days

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [-n LIMIT] [-a] [--color|--no-color] [-h] [DIR]

List issues by milestone with per-milestone status counts.

The top section is a compact table of open / in-progress / resolved
totals per milestone, so you can see at a glance which milestone owns
the most unblocked work.

The bottom section lists the issues themselves, ordered by relevance:
fresh (touched in last 2 days), then still-open, then resolved within
the past week. Resolved issues older than a week are hidden unless -a.

DIR can be a directory name relative to the current working directory
(e.g. "project-issues") or an absolute path. When DIR is omitted, the
script uses ./issues if present, otherwise shallow-scans \$PWD for a
folder containing an Issues.md/Issue.md guide or a project.json marker,
then repeats that search in each parent directory up to the project root.

Options:
  -n LIMIT    Show at most LIMIT issues per milestone (default: 50). Use 0 for no limit.
  -a          Include stale (>1 week) resolved issues too.
  --color     Force colored, grouped output even when piped.
  --no-color  Force plain columnar output (also honors NO_COLOR env var).
  -h          Show this help.
EOF
}

human_age() {
    local secs=$1
    if (( secs < 60 )); then printf "%ds" "$secs"
    elif (( secs < 3600 )); then printf "%dm" $(( secs / 60 ))
    elif (( secs < 86400 )); then printf "%dh" $(( secs / 3600 ))
    elif (( secs < 604800 )); then printf "%dd" $(( secs / 86400 ))
    elif (( secs < 2592000 )); then printf "%dw" $(( secs / 604800 ))
    elif (( secs < 31536000 )); then printf "%dmo" $(( secs / 2592000 ))
    else printf "%dy" $(( secs / 31536000 ))
    fi
}

is_terminal_status() {
    case "$1" in
        resolved|closed|done|fixed|complete|completed|wontfix) return 0 ;;
        *) return 1 ;;
    esac
}

is_in_progress_status() {
    case "$1" in
        "in-progress") return 0 ;;
        "in progress") return 0 ;;
        wip)           return 0 ;;
        *)             return 1 ;;
    esac
}

# --- argument parsing -------------------------------------------------
typeset -a rest
for arg in "$@"; do
    case "$arg" in
        --color)    COLOR_MODE=always ;;
        --no-color) COLOR_MODE=never ;;
        --help)     usage; exit 0 ;;
        *)          rest+=("$arg") ;;
    esac
done
set -- "${rest[@]}"

while getopts "n:ah" opt; do
    case "$opt" in
        n) LIMIT="$OPTARG" ;;
        a) SHOW_ALL=1 ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

# --- color setup ------------------------------------------------------
use_color=0
case "$COLOR_MODE" in
    always) use_color=1 ;;
    never)  use_color=0 ;;
    auto)   [[ -t 1 && -z "${NO_COLOR:-}" ]] && use_color=1 ;;
esac

if (( use_color )); then
    C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'; C_GRAY=$'\e[90m'
else
    C_RESET= C_DIM= C_BOLD= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_MAGENTA= C_CYAN= C_GRAY=
fi

# --- locate the issues directory --------------------------------------
is_issues_dir() {
    local d=$1
    [[ -f "$d/project.json" || -f "$d/Issues.md" || -f "$d/Issue.md" ]]
}

find_issues_in() {
    local base=$1
    if [[ -d "$base/issues" ]] && is_issues_dir "$base/issues"; then
        print -r -- "$base/issues"
        return 0
    fi

    typeset -a candidates
    local d c
    for d in "$base"/*(N/); do
        is_issues_dir "$d" && candidates+=("$d")
    done
    (( ${#candidates} > 0 )) || return 1

    for c in $candidates; do
        if [[ "${c:t:l}" == *issue* ]]; then
            print -r -- "$c"
            return 0
        fi
    done
    print -r -- "${candidates[1]}"
}

resolve_issues_dir() {
    local arg="${1:-}"
    if [[ -n "$arg" ]]; then
        if [[ "$arg" = /* ]]; then print -r -- "$arg"
        else print -r -- "$PWD/$arg"
        fi
        return
    fi

    local dir="$PWD" found
    while [[ -n "$dir" && "$dir" != "/" && "$dir" != "$HOME" ]]; do
        found=$(find_issues_in "$dir") && { print -r -- "$found"; return }
        [[ -e "$dir/.git" ]] && break
        dir="${dir:h}"
    done

    print -r -- "$PWD/issues"
}

ISSUES_DIR=$(resolve_issues_dir "${1:-}")

if [[ ! -d "$ISSUES_DIR" ]]; then
    if [[ -n "${1:-}" ]]; then print -u2 "error: $ISSUES_DIR not found"
    else print -u2 "error: no issues folder in $PWD or any parent up to the project root"; print -u2 "       (pass a directory: $SCRIPT_NAME DIR)"; fi
    exit 1
fi

typeset -a files
files=("$ISSUES_DIR"/[0-9][0-9][0-9][0-9].md(N.))

if (( ${#files} == 0 )); then print -u2 "no issue files in $ISSUES_DIR"; exit 0; fi

now=$EPOCHSECONDS

# --- gather issue records ---------------------------------------------
typeset -a ids states titles ages mtimes ranks milestones
hidden=0

for f in $files; do
    id="${${f:t}:r}"

    state=$(awk -F'\\|' '
        /^\| \*\*Status\*\* \|/ { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit }' "$f")
    [[ -z "$state" ]] && state="?"

    title=$(awk 'NR==1 { sub(/^# +[0-9]+ +— +/, ""); print; exit }' "$f")
    [[ -z "$title" ]] && title="(no title)"

    mtime=$(stat -f %m "$f")
    age_secs=$(( now - mtime ))

    milestone=$(awk -F'\\|' '
        /^\| \*\*Milestone\*\* \|/ { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit }' "$f")
    [[ -z "$milestone" ]] && milestone="———"

    local terminal=0 in_progress=0
    is_terminal_status "${state:l}" && terminal=1
    is_in_progress_status "${state:l}" && in_progress=1

    if (( age_secs <= FRESH_SECS )); then
        rank=$(( terminal ? 1 : 0 ))
    elif (( ! terminal && ! in_progress )); then
        rank=2
    elif (( in_progress )); then
        rank=2
    elif (( age_secs <= WEEK_SECS )); then
        rank=3
    else
        (( SHOW_ALL )) && rank=4 || { (( hidden += 1 )); continue; }
    fi

    ids+=("$id"); states+=("$state"); titles+=("$title")
    ages+=("$(human_age $age_secs)"); mtimes+=("$mtime"); ranks+=("$rank")
    milestones+=("$milestone")
done

if (( ${#ids} == 0 )); then
    if (( hidden > 0 )); then print -u2 "no current issues in ${ISSUES_DIR:t} ($hidden stale resolved hidden; use -a to show)"
    else print -u2 "no issue files in $ISSUES_DIR"; fi
    exit 0
fi

# --- order by rank, then newest first ---------------------------------
typeset -a keys
for (( i=1; i<=${#ids}; i++ )); do
    inv=$(( 99999999992 - mtimes[i] ))
    keys+=("$(printf '%d%011d%04d' "${ranks[i]}" "$inv" "$i")")
done
typeset -a order
order=(${(o)keys})

# --- gather per-milestone counts -------------------------------------
typeset -A ms_open=() ms_in_progress=() ms_resolved=()

for (( i=1; i<=${#ids}; i++ )); do
    m=${milestones[i]}; s="${states[i]:l}"
    if is_in_progress_status "$s"; then
        ms_in_progress[$m]=$(( ${ms_in_progress[$m]:-0} + 1 ))
    elif is_terminal_status "$s"; then
        ms_resolved[$m]=$(( ${ms_resolved[$m]:-0} + 1 ))
    else
        ms_open[$m]=$(( ${ms_open[$m]:-0} + 1 ))
    fi
done

# Sort milestone keys: M followed by digits first (numerically ascending), then everything else.
typeset -a ms_keys_num=() ms_keys_other=() final_ms_keys=()
for m in "${(@k)ms_open}"; do
    if [[ "$m" =~ ^M([0-9]+)$ ]]; then ms_keys_num+=("$m"); else ms_keys_other+=("$m"); fi
done

for m in "${(n)ms_keys_num[@]:-}"; do final_ms_keys+=("$m"); done
for m in "${ms_keys_other[@]:-}"; do final_ms_keys+=("$m"); done

# --- render -----------------------------------------------------------
status_color() {
    case "$1" in
        resolved|closed|done|fixed|complete|completed) print -r -- "$C_GREEN" ;;
        wip|"in-progress"|"in progress")              print -r -- "$C_CYAN" ;;
        open|new|todo|reopened)                        print -r -- "$C_YELLOW" ;;
        *)                                             print -r -- "$C_MAGENTA" ;;
    esac
}

age_color() {
    local age_secs=$1
    if   (( age_secs <= FRESH_SECS )); then print -r -- "$C_GREEN$C_BOLD"
    elif (( age_secs <= WEEK_SECS  )); then print -r -- "$C_YELLOW"
    else print -r -- "$C_DIM"
    fi
}

section_of() {
    case "$1" in 0|1) print -r -- fresh ;; 2) print -r -- open ;; *) print -r -- resolved ;; esac
}

print_section_header() {
    local sect=$1
    if (( use_color )); then
        case "$sect" in
            fresh) print -r -- "${C_BOLD}${C_BLUE}⚡ Fresh · last 2 days${C_RESET}" ;;
            open)  print -r -- "${C_BOLD}${C_BLUE}○ Open · needs attention${C_RESET}" ;;
            resolved) print -r -- "${C_BOLD}${C_BLUE}✓ Resolved · past week${C_RESET}" ;;
        esac
    else print -r -- "--- ${sect:u} ---"
    fi
}

# --- summary table ----------------------------------------------------
if (( use_color )); then
    print -r "${C_BOLD}${C_BLUE}milestone status${C_RESET}"
    printf '  %s%-6s%s  %7s  %10s  %8s\n' \
        "$C_GRAY" "name" "$C_RESET" "open" "in-progress" "resolved"
    for m in "${final_ms_keys[@]}"; do
        local mc=$C_CYAN; [[ "$m" == "———" ]] && mc=$C_DIM
        printf '  %s%-6s%s  %7d  %10d  %8d\n' \
            "$mc" "[$m]" "$C_RESET" \
            "${ms_open[$m]:-0}" "${ms_in_progress[$m]:-0}" "${ms_resolved[$m]:-0}"
    done
else
    print -r -- "--- milestone status ---"
    printf ' %-6s  %7s  %10s  %8s\n' "name" "open" "in-progress" "resolved"
    for m in "${final_ms_keys[@]}"; do
        printf ' %-6s  %7d  %10d  %8d\n' "[$m]" \
            "${ms_open[$m]:-0}" "${ms_in_progress[$m]:-0}" "${ms_resolved[$m]:-0}"
    done
fi

# --- listing ----------------------------------------------------------
STATUS_W=12
shown=0; prev_section=""
typeset -A per_milestone_shown=()
for m in "${final_ms_keys[@]}"; do per_milestone_shown[$m]=0; done

for k in $order; do
    idx=$(( 10#${k:12:4} ))

    id=$ids[idx]; state=$states[idx]; title=$titles[idx]
    age=$ages[idx]; rank=$ranks[idx]; m=${milestones[idx]}
    age_secs=$(( now - mtimes[idx] ))

    sect=$(section_of $rank)
    if [[ "$sect" != "$prev_section" ]]; then
        (( shown > 0 && use_color )) && print
        print_section_header "$sect"
        prev_section="$sect"
    fi

    (( LIMIT > 0 && ${per_milestone_shown[$m]:-0} >= LIMIT )) && {
        (( shown += 1 )); continue
    }

    if (( use_color )); then
        local glyph="•"
        case "${state:l}" in
            resolved|closed|done|fixed|complete|completed) glyph="✓" ;;
            wip|"in-progress"|"in progress") glyph="◐" ;;
            open|new|todo|reopened)           glyph="○" ;;
        esac

        scolor_str=$(status_color "${state:l}")
        acolor_str=$(age_color $age_secs)
        tcolor_str="$C_RESET"
        is_terminal_status "${state:l}" && tcolor_str="$C_DIM"
        statusf="$glyph ${state}"

        printf -- '  %s[ %5s ] %-4s %s%-12s%s  %s%4s%s  %s%s%s\n' \
            "$C_GRAY" "${m:-—}" "$C_RESET" \
            "$scolor_str" "$statusf" "$C_RESET" \
            "$acolor_str" "$age" "$C_RESET" \
            "$tcolor_str" "$title" "$C_RESET"
    else
        printf '  [%s] %-4s  %-12s  %5s  %s\n' "$m" "$id" "$state" "$age" "$title"
    fi

    (( shown += 1 ))
    per_milestone_shown[$m]=$(( ${per_milestone_shown[$m]:-0} + 1 ))
done

# --- footer -----------------------------------------------------------
local footer="$shown shown"
(( hidden > 0 )) && footer+=" · $hidden stale resolved hidden (-a to show)"
if (( use_color )); then
    print -r -- "${C_DIM}${footer}${C_RESET}"
else
    print -r -- "$footer"
fi
