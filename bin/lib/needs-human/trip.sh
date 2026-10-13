# bin/lib/needs-human/trip.sh — the same-finding tripwire (BH-3445, slice 3 of
# BH-3433). Contracts are in bin/lib/needs-human.sh.
#
# LENS_REFUSE review calls nh_trip_on_block on every REVIEW_BLOCKED. It
# fingerprints the final review round (the reviewer's NEEDS_HUMAN: action, else
# the round's BLOCK headlines) and nh_trip_note counts the distinct build ids
# that blocked on that fingerprint in the D1 ledger (kind review_block_fp, key
# <project>#<issue>#<fp>, detail a JSON array of build ids, status its length).
# At NEEDS_HUMAN_TRIP_COUNT builds it places a `tripwire` hold through
# bin/needs-human-hold.sh (unless lane_switch needs-human-hold-off is on) and
# writes one "[needs-human] TRIPWIRE" alert line saying what happened.
#
# The jobs client is the CALLER's (run-build loads it before rb_review): with
# no job_ledger_row/job_ledger_put defined the ledger is unreadable, and an
# unreadable ledger never counts and never trips. The root is HARNESS or H
# only; with neither, the log goes to stderr and nothing rooted is called.
# Nothing is ever printed on stdout, and nh_trip_on_block always returns 0.
# shellcheck shell=bash

# The registered lib file for the needs-human knob (catalog/lanes.d/_lib.needs-human.json).
NH_TRIP_KNOB=NEEDS_HUMAN_TRIP_COUNT   # settings row lib.needs-human.needs_human_trip_count; nh_trip_note reads it
_NH_TRIP_DEFAULT=2   # fallback when no row and no env set the knob; the registry default
_NH_TRIP_MIN=2       # the registry's min and max: a row can never trip on the first block
_NH_TRIP_MAX=10
_NH_TRIP_KEEP=50     # newest build ids kept: the worker cuts detail at 4000 chars
_NH_TRIP_CUT=160     # headline / action length that reaches the placer and the alert

_nh_trip_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _nh_trip_log <text> — one line to logs/needs-human.log, fail-open; stderr
# when there is no root.
_nh_trip_log() {
  local root line
  root=$(_nh_trip_root)
  line="$(date -u '+%F %TZ') trip: $*"
  if [ -n "$root" ]; then
    { mkdir -p "$root/logs" && printf '%s\n' "$line" >> "$root/logs/needs-human.log"; } 2>/dev/null
  else
    printf '%s\n' "$line" >&2
  fi
  return 0
}

# _nh_trip_threshold — the knob after lib_env_apply, clamped to the registry
# bounds (an env value outside them is used as is by lane-gate, not here).
_nh_trip_threshold() {
  local root v
  root=$(_nh_trip_root)
  v=$(
    if [ -n "$root" ]; then
      command -v lib_env_apply >/dev/null 2>&1 || . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1
      command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply needs-human >/dev/null 2>&1
    fi
    printf '%s' "${NEEDS_HUMAN_TRIP_COUNT:-}"
  ) 2>/dev/null
  case "$v" in
    '') v=$_NH_TRIP_DEFAULT ;;
    *[!0-9]*|?????*)
      _nh_trip_log "NEEDS_HUMAN_TRIP_COUNT='$v' is not an integer from 0 to 9999, using $_NH_TRIP_DEFAULT"
      v=$_NH_TRIP_DEFAULT ;;
    *) v=$((10#$v)) ;;
  esac
  if [ "$v" -lt "$_NH_TRIP_MIN" ]; then
    _nh_trip_log "NEEDS_HUMAN_TRIP_COUNT=$v is below $_NH_TRIP_MIN, clamped to $_NH_TRIP_MIN"; v=$_NH_TRIP_MIN
  elif [ "$v" -gt "$_NH_TRIP_MAX" ]; then
    _nh_trip_log "NEEDS_HUMAN_TRIP_COUNT=$v is above $_NH_TRIP_MAX, clamped to $_NH_TRIP_MAX"; v=$_NH_TRIP_MAX
  fi
  printf '%s' "$v"
}

# nh_trip_note <project> <issue> <fp> <build-id> — rc 0 trip, 1 no trip,
# 2 ledger unreadable (nothing counted). Sets _NH_TRIP_N (the count) and
# _NH_TRIP_AT (the threshold) for nh_trip_on_block's log and alert.
nh_trip_note() {
  local p="${1:-}" n="${2:-}" fp="${3:-}" bid="${4:-}" key row rc ids
  _NH_TRIP_N=0; _NH_TRIP_AT=""
  if [ -z "$p" ] || [ -z "$n" ] || [ -z "$fp" ] || [ -z "$bid" ]; then
    _nh_trip_log "$p#$n: note needs project, issue, fp and build id, not counted"; return 2
  fi
  if ! declare -F job_ledger_row job_ledger_put >/dev/null 2>&1; then
    _nh_trip_log "$p#$n: ledger unreadable (no jobs client loaded), not counted"; return 2
  fi
  key="$p#$n#$fp"
  row=$(job_ledger_row review_block_fp "$key" 2>/dev/null); rc=$?
  case "$rc" in
    0) ids=$(jq -c '.detail | (if type == "string" then (try fromjson catch null) else . end)
                   | select(type == "array" and all(.[]; type == "string"))' <<<"$row" 2>/dev/null)
       if [ -z "$ids" ]; then
         _nh_trip_log "$p#$n: ledger unreadable (row $key detail is not a JSON array of build ids), not counted"; return 2
       fi ;;
    2) ids='[]' ;;
    *) _nh_trip_log "$p#$n: ledger unreadable (read rc $rc), not counted"; return 2 ;;
  esac
  # A resumed build keeps its build id: already in the array, nothing written.
  if ! jq -e --arg b "$bid" 'index([$b]) != null' <<<"$ids" >/dev/null 2>&1; then
    ids=$(jq -c --arg b "$bid" --argjson k "$_NH_TRIP_KEEP" '(. + [$b]) | .[-$k:]' <<<"$ids") || {
      _nh_trip_log "$p#$n: ledger unreadable (could not append $bid), not counted"; return 2; }
    if ! job_ledger_put review_block_fp "$key" "$(jq 'length' <<<"$ids")" "$ids" >/dev/null 2>&1; then
      _nh_trip_log "$p#$n: ledger unreadable (put failed for $bid), not counted"; return 2
    fi
  fi
  _NH_TRIP_N=$(jq 'length' <<<"$ids")
  _NH_TRIP_AT=$(_nh_trip_threshold)
  [ "$_NH_TRIP_N" -ge "$_NH_TRIP_AT" ]
}

# _nh_trip_final_round <review.md> — the lines after the second-to-last
# VERDICT line (re-reviews are appended), or the whole file.
_nh_trip_final_round() {
  awk '{ l[NR] = $0 }
       /^VERDICT: (APPROVE|BLOCK)[[:space:]]*$/ { v[++nv] = NR }
       END { s = (nv >= 2) ? v[nv - 1] + 1 : 1; for (i = s; i <= NR; i++) print l[i] }' "$1"
}

# _nh_trip_headlines — stdin: a review round. The BLOCK finding headlines
# (F<n>, B<n> or <n>. after markdown), sorted and deduplicated.
_nh_trip_headlines() {
  awk '{ s = $0; sub(/^[[:space:]#>*_-]+/, "", s)
         if (s !~ /^(F[0-9]+|B[0-9]+|[0-9]+\.)/) next
         t = tolower(s)
         if (t ~ /non-block|not block/) next
         if (t !~ /(^|[^a-z])block(s|ing|er)?([^a-z]|$)/) next
         sub(/[[:space:]]+$/, "", s); print s }' | LC_ALL=C sort -u
}

_nh_trip_hold_off() { # _nh_trip_hold_off <root> — rc 0 when the switch is on
  local root="${1:-}"
  (
    command -v lane_switch >/dev/null 2>&1 || . "$root/bin/lib/lane-switch.sh" >/dev/null 2>&1
    # No lane_switch: the switch is unreadable, so the pause stands (the
    # conservative side); the switch is read only through lane_switch (BH-2320).
    command -v lane_switch >/dev/null 2>&1 || exit 1
    lane_switch needs-human-hold-off >/dev/null 2>&1
  )
}

_nh_trip_block() {
  local p="${1:-}" n="${2:-}" md="${3:-}" bid="${4:-}" action="${5:-}"
  local root final heads fp head src rc prc slug url tail
  if [ -z "$n" ]; then _nh_trip_log "$p: no issue number (not an issues board), skipped"; return 0; fi
  if [ ! -r "$md" ]; then _nh_trip_log "$p#$n: review.md unreadable ($md), skipped"; return 0; fi
  if ! declare -F nh_fingerprint >/dev/null 2>&1; then _nh_trip_log "$p#$n: nh_fingerprint not loaded, skipped"; return 0; fi
  final=$(_nh_trip_final_round "$md")
  if [ -z "$action" ]; then
    action=$(awk '/^NEEDS_HUMAN:/ { sub(/^NEEDS_HUMAN:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); if ($0 != "") { print; exit } }' <<<"$final")
  fi
  fp=""
  if [ -n "$action" ] && fp=$(nh_fingerprint "$action"); then
    head=$action; src=action
  else
    heads=$(_nh_trip_headlines <<<"$final")
    if [ -z "$heads" ] || ! fp=$(nh_fingerprint "$heads"); then
      _nh_trip_log "$p#$n: fp:none ($bid)"; return 0
    fi
    head=$(sed -n 1p <<<"$heads"); src=headlines
  fi
  head=${head:0:$_NH_TRIP_CUT}
  nh_trip_note "$p" "$n" "$fp" "$bid"; rc=$?
  case "$rc" in
    0) ;;
    1) _nh_trip_log "$p#$n: fp $fp count $_NH_TRIP_N/$_NH_TRIP_AT, no trip"; return 0 ;;
    *) _nh_trip_log "$p#$n: ledger unreadable, not counted"; return 0 ;;
  esac
  root=$(_nh_trip_root)
  if [ -z "$root" ]; then
    _nh_trip_log "$p#$n: TRIPPED fp $fp count $_NH_TRIP_N source $src, no root: no hold, no alert"; return 0
  fi
  slug="${NH_SLUG:-}"
  [ -n "$slug" ] || slug=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
  if [ -n "$slug" ]; then url="https://github.com/$slug/issues/$n"; else url="issue #$n"; fi
  if _nh_trip_hold_off "$root"; then
    prc=off
    _nh_trip_log "$p#$n: hold switch needs-human-hold-off on, no hold placed"
    tail="NOT paused: needs-human-hold-off is on"
  else
    HARNESS="$root" "$root/bin/needs-human-hold.sh" "$p" "$n" "$fp" \
      "pause-and-diagnose: the same review finding blocked $_NH_TRIP_N builds: $head" tripwire >/dev/null 2>&1
    prc=$?
    if [ "$prc" = 0 ]; then tail="paused for diagnosis"; else tail="hold NOT placed (placer rc $prc)"; fi
  fi
  HARNESS="$root" "$root/bin/alert-line.sh" --project "$p" --id "nh-trip:$p#$n#$fp" \
    "[needs-human] TRIPWIRE $p#$n: $_NH_TRIP_N REVIEW_BLOCKED builds on the same finding (fp $fp), $tail — $url" >/dev/null 2>&1
  _nh_trip_log "$p#$n: TRIPPED fp $fp count $_NH_TRIP_N source $src placer rc $prc"
  return 0
}

# nh_trip_on_block <project> <issue> <review.md> <build-id> [<nh-action>] — rc 0, no output.
nh_trip_on_block() { _nh_trip_block "$@" >/dev/null; return 0; }
