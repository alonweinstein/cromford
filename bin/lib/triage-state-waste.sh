#!/bin/bash
# bin/lib/triage-state-waste.sh — the paid-unchanged account of the
# TRIAGE-STATE tick (BH-3921, bodies BH-3926). Sourced by
# bin/lib/triage-state.sh next to the lib; defines functions only, nothing runs
# on source. See docs/triage-state/paid-unchanged.md.
#
# ts_waste_account <path> — called once before each tick-line log site, path
#   one of restricted | unrestricted | zero | unreadable. Reads this tick's
#   decisions.tsv and rows.json and sets TS_PAID_UNCHANGED (the count, `?` when
#   the rows were unreadable — never 0), TS_WASTE_LABELS (the counted labels)
#   and exports TS_ROW_NOTE. Under TS_MODE=enforce it also moves the streak
#   file state/triage-state/<p>/paid-unchanged.streak (+1 on a count > 0, 0 on
#   a count of 0, untouched when unreadable) and, when the streak reaches
#   exactly 3, raises ONE lane alert (id triage-paid-unchanged:<p>). Shadow
#   never reads or writes the streak. Prints nothing, always returns 0.
#   Counted, over in-scope (column 7) keys that are not work (column 9):
#     restricted    `llm` keys, not recheck-due, whose input hash equals their
#                   stored verdict_hash
#     unrestricted  the same, plus `skip unchanged:*|buildable-*` and `enqueue`
#                   (the whole session runs, so it re-reads those too)
#     zero          0 (no call is made)
# ts_waste_bracket — printed inside the tick line's last `[...]`, right before
#   its `]`: ` paid_unchanged=N` (leading space), nothing when no account ran.
# ts_row_note_of <key> [dir] — the shard cost-row note for one key: `ts=<class>`,
#   class one of new | changed | due | cap | unreadable | unchanged | work.
#   Reads <dir> (default: this project's state dir; bin/triage-shard.sh passes
#   its dispatch snapshot). Nothing for a key with no decisions line or any
#   other reason.
#
# Note formats:
#   single-session cost-row note  ts:new=N:chg=N:due=N:cap=N:unr=N:pu=N
#     at most 64 chars of [a-z0-9=:._-]; `pu=` is always LAST, because the SQL
#     reads it as a numeric suffix (`pu=na` when the rows were unreadable)
#   shard cost-row note           ts=<class>
# Decision reasons the read-rule slice will emit: `skip deferred:cap`,
# `skip deferred:budget` (counted as cap=; 0 until that slice lands).

# _ts_waste_rows <dir> — `<key>\t<verdict_hash>` per stored row; nothing when
# the rows file is unreadable or `null`
_ts_waste_rows() {
  jq -r '.[]? | [(.ticket_key // "" | tostring), (.verdict_hash // "")] | @tsv' "$1/rows.json" 2>/dev/null
}

ts_waste_account() {
  local path="${1:-}" d f unr=0 out counts labels n p h sf prev nxt
  TS_PAID_UNCHANGED=""; TS_WASTE_LABELS=""; TS_ROW_NOTE=""; export TS_ROW_NOTE
  d=$(_ts_dir); [ -n "$d" ] || return 0
  f="$d/decisions.tsv"
  { [ "$path" = unreadable ] || [ "${TS_ROWS_OK:-0}" != 1 ]; } && unr=1
  if [ ! -r "$f" ]; then
    TS_PAID_UNCHANGED='?'; TS_ROW_NOTE="ts:pu=na"
    return 0
  fi
  out=$(_ts_waste_rows "$d" | awk -F'\t' -v mode="$path" '
    FILENAME == "-" { vh[$1] = $2; next }
    $7 != "1" { next }
    $3 == "llm" && $4 ~ /^new/ { a++ }
    $3 == "llm" && $4 ~ /^changed/ { b++ }
    $3 == "llm" && $4 ~ /^recheck-due/ { c++ }
    $3 == "skip" && $4 ~ /^deferred:/ { e++ }
    $3 == "llm" && ($4 ~ /^unhashable/ || $4 ~ /^rows-unreadable/) { u++ }
    mode == "zero" || $9 == "1" { next }
    ($3 == "llm" && $4 !~ /^recheck-due/ && $5 != "-" && ($1 in vh) && $5 == vh[$1]) \
      || (mode != "restricted" && (($3 == "skip" && ($4 ~ /^unchanged:/ || $4 ~ /^buildable-/)) || $3 == "enqueue")) {
      n++; l = l " " $2
    }
    END { printf "new=%d:chg=%d:due=%d:cap=%d:unr=%d\t%d\t%s", a, b, c, e, u, n, substr(l, 2) }' - "$f" 2>/dev/null)
  counts=${out%%$'\t'*}; out=${out#*$'\t'}; n=${out%%$'\t'*}; labels=${out#*$'\t'}
  case "$n" in ''|*[!0-9]*) unr=1; counts="" ;; esac
  if [ "$unr" = 1 ]; then
    TS_PAID_UNCHANGED='?'; TS_ROW_NOTE="ts:${counts:+$counts:}pu=na"
    return 0
  fi
  TS_PAID_UNCHANGED=$n; TS_WASTE_LABELS=$labels
  TS_ROW_NOTE="ts:$counts:pu=$n"
  [ "${TS_MODE:-}" = enforce ] || return 0
  # THE STREAK. A box-local counter, written tmp+mv; an unreadable or corrupt
  # file reads as 0, and a failed write moves nothing and alerts nothing.
  sf="$d/paid-unchanged.streak"
  prev=$(head -1 "$sf" 2>/dev/null | tr -d '[:space:]')
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  nxt=0; [ "$n" -gt 0 ] && nxt=$((prev + 1))
  printf '%s\n' "$nxt" > "$sf.tmp.$$" 2>/dev/null && mv -f "$sf.tmp.$$" "$sf" 2>/dev/null \
    || { rm -f "$sf.tmp.$$" 2>/dev/null; return 0; }
  # The 3 is a fixed rule (BH-3926), not a knob. Exactly 3: one alert per streak.
  if [ "$nxt" -eq 3 ]; then
    h=$(_ts_h); p="${PROJECT:-}"
    [ -x "$h/bin/lane-alert.sh" ] && "$h/bin/lane-alert.sh" --id "triage-paid-unchanged:$p" --severity warn triage \
      "$p: 3 triage ticks in a row paid the model for tickets whose inputs had not changed (last: $n: $(printf '%s' "$labels" | cut -c1-300)). Read logs/$p.log and state/triage-state/$p/decisions.tsv." \
      >/dev/null 2>&1
  fi
  return 0
}

ts_waste_bracket() { [ -n "${TS_PAID_UNCHANGED:-}" ] && printf ' paid_unchanged=%s' "$TS_PAID_UNCHANGED"; return 0; }

ts_row_note_of() {
  local k="${1:-}" d="${2:-}"
  [ -n "$d" ] || d=$(_ts_dir)
  [ -n "$k" ] && [ -n "$d" ] && [ -r "$d/decisions.tsv" ] || return 0
  _ts_waste_rows "$d" | awk -F'\t' -v k="$k" '
    FILENAME == "-" { if ($1 == k) vh = $2; next }
    $1 != k { next }
    { c = "" }
    $9 == "1" { c = "work" }
    c == "" && (($3 == "skip" && ($4 ~ /^unchanged:/ || $4 ~ /^buildable-/)) || $3 == "enqueue") { c = "unchanged" }
    c == "" && $3 == "llm" && $4 !~ /^recheck-due/ && $5 != "-" && vh != "" && $5 == vh { c = "unchanged" }
    c == "" && $3 == "llm" && $4 ~ /^new/ { c = "new" }
    c == "" && $3 == "llm" && $4 ~ /^changed/ { c = "changed" }
    c == "" && $3 == "llm" && $4 ~ /^recheck-due/ { c = "due" }
    c == "" && $3 == "skip" && $4 ~ /^deferred:/ { c = "cap" }
    c == "" && $3 == "llm" && ($4 ~ /^unhashable/ || $4 ~ /^rows-unreadable/) { c = "unreadable" }
    c != "" { print "ts=" c }
    { exit }' - "$d/decisions.tsv" 2>/dev/null
  return 0
}
