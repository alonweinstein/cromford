# bin/lib/pr-trailers.sh — the machine-readable "the harness built this" block
# at the foot of a PR body (BH-3987). Sourced, never executed: nothing runs at
# source time, no `set` flags, every expansion safe under `set -u`.
#
#   Harness-Job: <job_id | lane:<lane-id> | train:<branch> | none>
#   Harness-Ticket: <KEY | none>
#   Harness-Train: <train-branch> <#n> <#n> ...      (only when a train is given)
#
# A value keeps [A-Za-z0-9._:/#@+-] only (the train list also keeps spaces), is
# cut to 200 chars, and is `none` when nothing survives. The allow-list drops
# newlines, so a ticket title can never start a trailer line of its own.
# THE LAST OCCURRENCE WINS: pr_trailers_read keeps the last value of each key,
# and pr_trailers_apply always puts its block last, after the 🤖 footer, so a
# `Harness-Job:` line typed into a ticket body higher up never reads back.
#
#   pr_trailers_text    <job> <ticket> [train]             -> the block on stdout
#   pr_trailers_apply   <body-file> <job> <ticket> [train] -> rc 0 rewritten, rc 1 untouched
#   pr_trailers_job_for <build-dir>                        -> $JOB_ID, job.json .job_id, or none
#   pr_trailers_read    <body-file|->                      -> job<TAB>ticket<TAB>train
# shellcheck shell=bash

_pr_trailers_clean() { # <value> [allow-space]
  local LC_ALL=C v set='A-Za-z0-9._:/#@+-'
  [ -n "${2-}" ] && set='A-Za-z0-9._:/#@+ -'
  v=$(printf '%s' "${1-}" | tr -cd "$set")
  v=${v#"${v%%[! ]*}"}; v=${v%"${v##*[! ]}"}
  v=${v:0:200}
  printf '%s\n' "${v:-none}"
}

pr_trailers_text() { # <job> <ticket> [train]
  printf 'Harness-Job: %s\n' "$(_pr_trailers_clean "${1-}")"
  printf 'Harness-Ticket: %s\n' "$(_pr_trailers_clean "${2-}")"
  [ -n "${3-}" ] && printf 'Harness-Train: %s\n' "$(_pr_trailers_clean "$3" space)"
  return 0
}

pr_trailers_apply() { # <body-file> <job> <ticket> [train]
  local LC_ALL=C f="${1-}" block body max tmp
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] && [ -w "$f" ] || return 1
  block=$(pr_trailers_text "${2-}" "${3-}" "${4-}")
  # Drop every old trailer line wherever it sits. Blank lines are held back until
  # a real line follows, and a trailer line throws away the ones held above it:
  # that is the blank line a previous apply added, with no state to carry.
  body=$(awk '{ l = $0; sub(/\r$/, "", l) }
              l ~ /^Harness-(Job|Ticket|Train):/ { pend = ""; next }
              l ~ /^[[:space:]]*$/ { pend = pend $0 "\n"; next }
              { printf "%s%s\n", pend, $0; pend = "" }' "$f") || return 1
  # GitHub refuses a body over 65536 chars; the block is what must survive.
  max=$(( 65000 - ${#block} - 3 ))
  [ "${#body}" -gt "$max" ] && body=${body:0:max}
  tmp="$f.trailers.$$"
  { if [ -n "$body" ]; then printf '%s\n\n%s\n' "$body" "$block" > "$tmp"
    else printf '%s\n' "$block" > "$tmp"; fi; } 2>/dev/null && mv -f "$tmp" "$f" && return 0
  rm -f "$tmp"
  return 1
}

pr_trailers_job_for() { # <build-dir>
  local j="${JOB_ID-}"
  [ -n "$j" ] || j=$(jq -r '.job_id // empty' "${1-}/job.json" 2>/dev/null)
  _pr_trailers_clean "$j"
}

pr_trailers_read() { # <body-file|->
  local src="${1--}"
  [ "$src" = - ] || [ -r "$src" ] || return 1
  if [ "$src" = - ]; then tr -d '\r'; else tr -d '\r' < "$src"; fi | awk '
    function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s }
    /^Harness-Job:/    { j = val($0) }
    /^Harness-Ticket:/ { t = val($0) }
    /^Harness-Train:/  { r = val($0) }
    END { printf "%s\t%s\t%s\n", j, t, r }'
}
