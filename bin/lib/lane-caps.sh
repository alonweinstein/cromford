#!/bin/bash
# bin/lib/lane-caps.sh — the VOLUME bound on a hub LLM lane: dollars per UTC
# day, and bytes of evidence per prompt. Sourced, never executed (BH-1039).
#
# THE INCIDENT THIS IS. 2026-09-20, hub logs/cost.csv, stage alert-triage:
# $793 in 12 hours against a $39-$61/day baseline. The configured RUNNER_TRIAGE
# (grok) hit its context cliff, agent-call's ladder descended to codex and then
# to Fable over OpenRouter at API prices, and the per-session price moved ~100x
# while the session COUNT stayed inside its cap. 150 of the 192 sessions ended
# `handled=0 escalated=0 noise=1` — about $4 each to call a stale heartbeat
# noise, against a 485-family backlog that never drained.
#
# So: a session cap is not a spend cap. This library is the spend cap, plus the
# two other bounds the same incident asked for.
#
#   lane_cap_usd <lane>            dollars/UTC-day for the lane, or nothing
#   lane_cap_bytes <lane>          evidence bytes the lane may put in a prompt
#   lane_caps_source               the layers that answered, joined ` + `, or
#                                  "built-in defaults" (layering: _lc_load)
#   lane_caps_legacy_rows          conf rows this grammar refused (space sep.)
#   lane_caps_knobs <lane>         the lane's cap knobs as a JSON array (BH-1132)
#   lane_evidence_cap <lane>       stdin -> stdout, truncated WITH A MARKER
#   lane_day_usd <lane>            what the lane has spent so far this UTC day
#   lane_day_cap_tripped <lane>    rc 0 = over the cap (and one ALERTS line)
#   lane_noise_cap <lane>          noise-only sessions/UTC-day, or `off`
#   lane_noise_count <lane>        noise-only sessions so far today (rc 2 = unreadable)
#   lane_noise_record <lane> <handled> <escalated>   one session's verdict
#   lane_noise_cap_tripped <lane>  rc 0 = out of noise budget (and one ALERTS line)
#
# FAIL OPEN, ALWAYS, AND SAY SO. Every reader here degrades to "no cap, lane
# runs" when it cannot answer: an unreadable cost.csv, a missing price table, a
# conf file that is not there. A bound that turns a lane OFF because it could
# not read a file would take out the de-noising layer in exactly the situation
# where it is needed, and it would look identical to a lane that was correctly
# stopped. Every degrade writes one line naming what it could not read.
_LC_H="${HARNESS:-/root/harness}"
# The alert helper beside THIS copy of the library first: callers (and tests)
# source the repo copy with HARNESS on a tree that may not carry bin/alert-line.sh.
_LC_AL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/alert-line.sh"
[ -x "$_LC_AL" ] || _LC_AL="$_LC_H/bin/alert-line.sh"
# shellcheck source=conf-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/conf-row.sh" 2>/dev/null || true
# THE FALLBACK IS A CAP, NOT A CEREMONY (BH-1164). $200/day was chosen as
# "present but generous" for an unlisted lane. What it actually did on
# 2026-09-20 was bind on the hub itself: the box had this LIBRARY but not
# catalog/lane-caps.conf (fleet-sync lands them separately), so the reviewed
# `lane alert-triage 120` row never applied and the number that finally stopped
# the runaway at 21:20Z was this constant — 3-5x the lane's own observed
# $39-$61 day. A fallback for the box that is FURTHEST BEHIND has to be the
# TIGHTEST number, not the loosest: too low costs one loud page and a queue that
# waits, too high costs the bill this file exists to prevent. Whenever it binds,
# lane_cap_usd says so in logs/lane-caps.log.
LANE_CAPS_DEFAULT_USD=50
LANE_CAPS_DEFAULT_BYTES=20000
# THE THIRD BOUND IS ON THE THING THAT WAS ACTUALLY WRONG (BH-1168). A session
# that concludes `handled=0 escalated=0` costs full price and produces nothing;
# 150 of the 192 sessions on 2026-09-20 were exactly that, and on the
# 16:10-21:20Z tail it was every one of them. The dollar cap catches that only
# after the day's money is gone. This one counts the noise-only sessions and
# stops the lane at the budget, whatever they cost. 10/day is ~2.5 ticks of pure
# noise at the default 4 families a tick — and, like the dollar fallback, it is
# the number that binds on the box FURTHEST BEHIND, so it is the tight one
# rather than the generous one. A real day that trips it is the signal to raise
# the reviewed row, not evidence the bound is wrong.
LANE_CAPS_DEFAULT_NOISE=10

_LC_LOADED=""
_LC_SOURCE=""
_LC_DEF_USD=""
_LC_DEF_BYTES=""
_LC_DEF_NOISE=""
_LC_DEF_NOISE_SET=""
_LC_LEGACY=""
declare -A _LC_USD
declare -A _LC_BYTES
declare -A _LC_NOISE

# A NON-NEGATIVE number, or nothing at all — never a half-parsed threshold.
#
# ZERO IS A VALUE (BH-1164). This used to demand a POSITIVE number, so
# `LANE_USD_CAP_ALERT_TRIAGE=0` — the most obvious way an operator writes "spend
# nothing on this lane today" — was refused as garbage and fell straight through
# to the default, and the lane kept buying sessions against a cap the operator
# believed was zero. `0` now binds as 0, which lane_day_cap_tripped reads as
# "already at the cap" on an empty ledger: the lane is OFF. That is the same
# reading BH-1132's registry gives every other knob (`zero_means: "off"`), and
# it is the opposite of `off`, which means deliberately UNCAPPED. Two words,
# two meanings, and neither of them is "take the default".
_lc_num() {
  case "${1:-}" in
    ''|*[!0-9.]*) return 1 ;;
    # AT LEAST ONE DIGIT. `.` and `..` pass the class above and `awk` reads them
    # as 0 — which, now that 0 means "lane off", would turn a typo into a silent
    # stop of the whole de-noising layer. A cap has to be written, not implied.
    *[0-9]*) awk -v v="$1" 'BEGIN{ exit !(v+0 >= 0) }' && printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# A positive WHOLE number. Dollars are decimal ($90.50 is a cap); BYTES are fed
# straight to `tail -c` and to shell arithmetic, and `1.5` there is not a small
# cap — it is two bash errors and an EMPTY prompt that still buys a paid session
# (BH-1039 review, N1). A byte column that is not an integer binds nothing and
# is named by lane_caps_legacy_rows() rather than accepted.
_lc_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -gt 0 ] 2>/dev/null && printf '%s' "$1" ;;
  esac
}

# A non-negative WHOLE number — a COUNT of sessions (BH-1168). Zero is a value
# here for the same reason it is on the dollar cap: `LANE_NOISE_CAP_<LANE>=0` is
# "buy no session on this lane today", and it is the opposite of `off`. `1.5`,
# `-3` and `abc` are none of those and bind nothing: half a session is not a
# budget, and an operator typo may not silently remove a bound.
_lc_count() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s' "$1" ;;
  esac
}

# The env-variable suffix for a lane name: upper case, every non-alphanumeric
# character to `_`. alert-triage -> ALERT_TRIAGE.
_lc_envkey() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9' '_' | tr 'a-z' 'A-Z'; }

_lc_load() {
  [ -n "$_LC_LOADED" ] && return 0
  _LC_LOADED=1
  _LC_DEF_USD="$LANE_CAPS_DEFAULT_USD"
  _LC_DEF_BYTES="$LANE_CAPS_DEFAULT_BYTES"
  _LC_DEF_NOISE="$LANE_CAPS_DEFAULT_NOISE"
  _LC_SOURCE=""
  local f ff=""
  # $LANE_CAPS_CONF (a fixture) reads no row of either kind: the first readable
  # of it and the files below, as given, exactly as before BH-4155.
  if [ -n "${LANE_CAPS_CONF:-}" ]; then
    for f in "$LANE_CAPS_CONF" "$_LC_H/flags/lane-caps.conf" \
             "$_LC_H/catalog/lane-caps.conf" \
             "$(dirname "${BASH_SOURCE[0]}")/../../catalog/lane-caps.conf"; do
      [ -r "$f" ] && { _LC_SOURCE="$f"; _lc_file "$f"; break; }
    done
    _LC_SOURCE="${_LC_SOURCE:-built-in defaults}"
    return 0
  fi
  [ -r "$_LC_H/flags/lane-caps.conf" ] && ff="$_LC_H/flags/lane-caps.conf"
  # The catalog, only when no flags file is readable (the first-hit rule).
  if [ -z "$ff" ]; then
    for f in "$_LC_H/catalog/lane-caps.conf" \
             "$(dirname "${BASH_SOURCE[0]}")/../../catalog/lane-caps.conf"; do
      [ -r "$f" ] && { _LC_SOURCE="$f"; _lc_file "$f"; break; }
    done
  fi
  # THE SETTINGS ROWS (BH-2411, bin/lib/conf-row.sh): `conf.lane-caps.lane.<lane>`
  # = `<usd|off> [bytes]`, `conf.lane-caps.default` = `<usd|off> [bytes]`,
  # `conf.lane-caps.noise.<lane|default>` = `<count|off>`. Two kinds, in this
  # order: the registry-seed rows (BH-4155, the DB copy of the catalog, which
  # bin/cost-caps-seed-sync.sh re-seeds on the hub's deploy when the file
  # moves, so a reviewed catalog edit still moves the cap) above the catalog line, then flags/lane-caps.conf line by line, then the operator
  # rows (box row first) above all of it. The LANE_*_CAP_<LANE> env overrides
  # still beat every layer. A row is all or nothing: one this grammar refuses
  # binds nothing (the layer below stands, never `off`) and is named in
  # lane_caps_legacy_rows as `seed:<key>` or `row:<key>`.
  if command -v conf_rows_seeded >/dev/null 2>&1; then
    local sk sv seeded=""
    while IFS=$'\t' read -r sk sv; do
      [ -n "$sk" ] || continue
      _lc_row "$sk" "$sv" seed && seeded=1
    done < <(conf_rows_seeded lane-caps "$_LC_H")
    [ -n "$seeded" ] && _LC_SOURCE="${_LC_SOURCE:+$_LC_SOURCE + }settings seed conf.lane-caps.*"
  fi
  if [ -n "$ff" ]; then
    _LC_SOURCE="${_LC_SOURCE:+$_LC_SOURCE + }$ff"
    _lc_file "$ff"
  fi
  _LC_SOURCE="${_LC_SOURCE:-built-in defaults}"
  command -v conf_rows >/dev/null 2>&1 || return 0
  local k v ks=""
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    _lc_row "$k" "$v" row && ks="$ks $k"
  done < <(conf_rows lane-caps "$_LC_H")
  if [ -n "$ks" ]; then
    _LC_SOURCE="$_LC_SOURCE + settings conf.lane-caps.*"
    # shellcheck disable=SC2086  # the key list, one word per key
    conf_row_note_file lane-caps "$_LC_H/flags/lane-caps.conf" $ks
  fi
  return 0
}

# _lc_file <path> — every row of a lane-caps file, applied.
_lc_file() {
  local row kw a b c
  # INLINE COMMENTS ARE COMMENTS (BH-1039 review r2, N1). `read -r kw a b c` put
  # `40000 # why` in $c, so `lane medic 90 40000 # why` bound NO byte cap and was
  # named as a refused row instead — a threshold the operator wrote, can see in
  # the file, and does not have. Everything from the first `#` is cut BEFORE the
  # row is split, which also subsumes the whole-line-comment case.
  while IFS= read -r row || [ -n "$row" ]; do
    row="${row%%#*}"
    read -r kw a b c <<<"$row"
    [ -n "${kw:-}" ] || continue
    _lc_line "$kw" "$a" "$b" "$c"
  done < "$1"
}

# _lc_row <key> <value> <seed|row> — one settings row through the grammar. rc 0
# when it bound; a refused row is named `<seed|row>:<key>`; a key this grammar
# does not have (another box's row, an unknown directive) is skipped, rc 1.
_lc_row() {
  local k="$1" kw a b c x y z
  read -r x y z <<<"$2"
  case "$k" in
    lane.*.*|noise.*.*) return 1 ;;   # another box's row, or no key this grammar has
    lane.?*|noise.?*) kw="${k%%.*}"; a="${k#*.}"; b="$x"; c="$y" ;;
    default) kw=default; a="$x"; b="$y"; c="" ;;
    *) return 1 ;;
  esac
  if [ -z "$z" ] && _lc_row_ok "$kw" "$a" "$b" "$c"; then
    _lc_line "$kw" "$a" "$b" "$c"; return 0
  fi
  _LC_LEGACY="${_LC_LEGACY:+$_LC_LEGACY }$3:$k"
  return 1
}

# _lc_row_ok <kw> <a> <b> <c> — every field a settings row carries is one this
# grammar takes (a file line may still bind its dollars with a bad byte column;
# a row may not half-apply).
_lc_row_ok() {
  case "$1" in
    lane)    [ -n "$2" ] && { [ "$3" = off ] || _lc_num "$3" >/dev/null; } && { [ -z "$4" ] || _lc_int "$4" >/dev/null; } ;;
    default) { [ "$2" = off ] || _lc_num "$2" >/dev/null; } && { [ -z "$3" ] || _lc_int "$3" >/dev/null; } && [ -z "$4" ] ;;
    noise)   [ -n "$2" ] && { [ "$3" = off ] || _lc_count "$3" >/dev/null; } && [ -z "$4" ] ;;
    *) return 1 ;;
  esac
}

# _lc_line <kw> <a> <b> <c> — one line of the grammar, applied.
_lc_line() {
  local kw="$1" a="$2" b="$3" c="$4"
  case "$kw" in
    lane)
      # `off` is a VALUE (deliberately uncapped), not a missing number. A row
      # with no lane name, or a dollar figure that is neither a positive
      # number nor `off`, binds nothing and is named rather than skipped.
      if [ -n "$a" ] && { [ "$b" = off ] || _lc_num "$b" >/dev/null; }; then
        _LC_USD["$a"]="$b"
        if [ -n "$c" ]; then
          if _lc_int "$c" >/dev/null; then
            _LC_BYTES["$a"]="$c"
          else
            _LC_LEGACY="${_LC_LEGACY:+$_LC_LEGACY }$kw:$a:bytes"
          fi
        fi
      else
        _LC_LEGACY="${_LC_LEGACY:+$_LC_LEGACY }$kw:$a"
      fi
      ;;
    default)
      { [ "$a" = off ] || _lc_num "$a" >/dev/null; } && _LC_DEF_USD="$a"
      if [ -n "$b" ]; then
        if _lc_int "$b" >/dev/null; then
          _LC_DEF_BYTES="$b"
        else
          _LC_LEGACY="${_LC_LEGACY:+$_LC_LEGACY }$kw:bytes"
        fi
      fi
      ;;
    # A SEPARATE DIRECTIVE, NOT A FOURTH COLUMN (BH-1168). The shipped parser
    # reads a row as `kw a b c`, so `lane medic 90 40000 10` on a box whose
    # library is a sync behind lands `40000 10` in $c, refuses the byte column
    # and drops that lane to the 20000 default — silently, and on a lane this
    # ticket is not about. A `noise` row on an old library is named as ONE
    # legacy row and changes nothing else.
    noise)
      if [ "$a" = default ]; then
        if [ "$b" = off ] || _lc_count "$b" >/dev/null; then
          _LC_DEF_NOISE="$b"; _LC_DEF_NOISE_SET=1
        else
          _LC_LEGACY="${_LC_LEGACY:+$_LC_LEGACY }$kw:default"
        fi
      elif [ -n "$a" ] && { [ "$b" = off ] || _lc_count "$b" >/dev/null; }; then
        _LC_NOISE["$a"]="$b"
      else
        _LC_LEGACY="${_LC_LEGACY:+$_LC_LEGACY }$kw:$a"
      fi
      ;;
    *)
      _LC_LEGACY="${_LC_LEGACY:+$_LC_LEGACY }$kw"
      ;;
  esac
  return 0
}

lane_caps_source()      { _lc_load; printf '%s\n' "$_LC_SOURCE"; }
lane_caps_legacy_rows() { _lc_load; printf '%s\n' "$_LC_LEGACY"; }

# lane_cap_usd <lane> — dollars per UTC day. Prints `off` for a lane that is
# deliberately uncapped, and NOTHING (rc 1) for a lane name that is empty.
lane_cap_usd() {
  _lc_load
  local l="${1:-}" v vn
  [ -n "$l" ] || return 1
  # The env override beats every file, for one run. Garbage in it is IGNORED
  # rather than read as "uncapped": an operator typo must not silently remove a
  # bound. `off` is the way to say uncapped, and it is spelled out.
  vn="LANE_USD_CAP_$(_lc_envkey "$l")"; v="${!vn:-}"
  if [ -n "$v" ] && { [ "$v" = off ] || _lc_num "$v" >/dev/null; }; then
    printf '%s\n' "$v"; return 0
  fi
  # NOTHING ABOUT THE BINDING CAP IS SILENT (BH-1164). $200/day was not wrong
  # because 200 is a bad number; it was wrong because no line anywhere on that
  # hub said the reviewed `lane alert-triage 120` row was NOT in force. A lane
  # running on the built-in fallback — a box whose fleet-sync has not landed
  # catalog/lane-caps.conf, which is the incident — says so once per lane per
  # UTC day, with the number that is actually binding and how to change it.
  if [ -z "${_LC_USD[$l]:-}" ] && [ "${_LC_SOURCE% + settings *}" = "built-in defaults" ]; then
    _lc_log "$l" "no lane-caps.conf on this box — capped at \$$_LC_DEF_USD/day by the built-in defaults (bin/lib/lane-caps.sh). Deploy catalog/lane-caps.conf for this lane's reviewed row, or set $vn."
  fi
  printf '%s\n' "${_LC_USD[$l]:-$_LC_DEF_USD}"
}

# lane_caps_knobs <lane> — this lane's cap knobs as a JSON array, in the shape
# the lanes registry serves an operator (BH-1132: env/type/default/min/max/unit/
# zero_means/note). The LIBRARY that owns the numbers emits them, so the
# registry can never carry a second, stale copy of a bound — the cost-capture
# failure mode of BH-1039 applied to config: a knob page that shows $200 while
# the lane runs on $50 is worse than no page.
#
# `default` is the cap RESOLVED for this lane right now (conf row, or the
# built-in fallback), never a literal — that is the number an operator is being
# asked about. Every dollar knob declares `zero_means: "off"`: 0 stops the lane.
lane_caps_knobs() {
  _lc_load
  local l="${1:-}" usd bytes noise
  [ -n "$l" ] || return 1
  usd=$(lane_cap_usd "$l"); bytes=$(lane_cap_bytes "$l"); noise=$(lane_noise_cap "$l")
  python3 - "$l" "$(_lc_envkey "$l")" "$usd" "$bytes" "$_LC_SOURCE" "$noise" <<'PYK'
import json, sys
lane, key, usd, byt, src, noise = sys.argv[1:7]
def num(v):
    try:
        f = float(v)
    except ValueError:
        return v            # `off` — a deliberately uncapped lane
    return int(f) if f == int(f) else f
print(json.dumps([
    {"env": f"LANE_USD_CAP_{key}", "type": "number", "default": num(usd),
     "min": 0, "max": 1000, "unit": "USD/day", "zero_means": "off",
     "note": (f"Dollars this lane may spend in one UTC day (now: {usd}, from {src}). "
              "0 stops the lane; `off` runs it uncapped. Nothing is dropped when it "
              "trips — the lane's queue waits and it pages once a day.")},
    {"env": f"LANE_BYTES_CAP_{key}", "type": "int", "default": num(byt),
     "min": 1000, "max": 2000000, "unit": "bytes", "zero_means": None,
     "note": (f"Evidence bytes this lane may put in one prompt (now: {byt}, from {src}). "
              "Truncation carries a marker; too small and a family is re-spooled "
              "every tick and never triaged, which pages once a day.")},
    {"env": f"LANE_NOISE_CAP_{key}", "type": "int", "default": num(noise),
     "min": 0, "max": 1000, "unit": "sessions/day", "zero_means": "off",
     "note": (f"Sessions concluding `handled=0 escalated=0` this lane may buy in one "
              f"UTC day (now: {noise}, from {src}). At the budget it stops buying "
              "sessions until 00:00Z and pages once; a session that handles or "
              "escalates anything resets the count. 0 stops the lane; `off` runs it "
              "unbounded. Nothing is dropped — the queue waits.")},
]))
PYK
}

# lane_cap_bytes <lane> — evidence bytes this lane may put in one prompt.
lane_cap_bytes() {
  _lc_load
  local l="${1:-}" v vn
  [ -n "$l" ] || return 1
  vn="LANE_BYTES_CAP_$(_lc_envkey "$l")"; v="${!vn:-}"
  # INTEGER ONLY, and a typo is IGNORED rather than obeyed: `LANE_BYTES_CAP=1.5`
  # used to be accepted and then emptied the evidence with two bash errors while
  # the session was still bought (BH-1039 review, N1).
  _lc_int "$v" >/dev/null && { printf '%s\n' "$v"; return 0; }
  if [ -n "$v" ]; then
    _lc_log "$l" "$vn=$v is not a whole number of bytes — IGNORED; the lane's configured byte cap stands"
  fi
  printf '%s\n' "${_LC_BYTES[$l]:-$_LC_DEF_BYTES}"
}

# lane_evidence_cap <lane> — stdin to stdout, cut to the lane's byte cap with a
# MARKER LINE saying how much was dropped.
#
# RC 2 = THE BODY IS THE MARKER AND NOTHING ELSE (BH-1039 review r2, I4). When
# not one complete record fits the cap, the marker is still printed (a caller
# that ignores the rc reads a declared absence, never a silent one) — but the rc
# says "there is no evidence here", so a caller can decline to buy a session on
# it. A $4 strong-tier session on zero evidence, with the family stamped into the
# 6h brake by nobody having looked, is the shape this rc exists to refuse.
#
# The marker is the whole point. `head -c 20000` (what alert-triage did) hands
# the model a prompt that ends mid-sentence with nothing to say it was cut, so a
# session on a third of the evidence reads exactly like a session on all of it.
# Evidence is cut from the HEAD — oldest first, the same rule the responder's
# comment budget already follows — because the newest lines are the ones that
# describe the condition as it is now.
lane_evidence_cap() {
  local l="${1:-}" cap body n kept kn
  cap=$(lane_cap_bytes "$l") || cap="$LANE_CAPS_DEFAULT_BYTES"
  body=$(cat)
  n=$(printf '%s' "$body" | wc -c | tr -d ' ')
  if [ "${n:-0}" -le "${cap:-0}" ]; then
    printf '%s' "$body"
    return 0
  fi
  kept=$(printf '%s' "$body" | tail -c "$cap")
  # WHOLE LINES ONLY (BH-1039 review, I3). `tail -c` cuts at a BYTE, so the
  # first surviving line is a fragment with its head gone — in alerts-medic.sh
  # that is an `id<TAB>line` whose id is gone (the model is handed a body it
  # cannot act on, and the SEEN list would consume the id anyway), and here it
  # is a broken beat-json. Drop through the first newline unless the cut landed
  # exactly on one; if not one COMPLETE line fits, keep none and say so, because
  # half a record is worse evidence than a declared absence.
  if [ "${kept:0:1}" = $'\n' ]; then
    kept="${kept#?}"
  elif [[ "$kept" == *$'\n'* ]]; then
    kept="${kept#*$'\n'}"
  else
    kept=""
  fi
  kn=$(printf '%s' "$kept" | wc -c | tr -d ' ')
  if [ "${kn:-0}" -eq 0 ]; then
    printf '%s' \
      "-- [capped: dropped all ${n}B of evidence — not one COMPLETE line fits the ${cap}B cap for lane $l (LANE_BYTES_CAP_$(_lc_envkey "$l"), catalog/lane-caps.conf); raise the cap]"
    return 2
  fi
  printf '%s\n%s' \
    "-- [capped: dropped $(( n - kn )) of ${n}B of evidence to fit the ${cap}B cap for lane $l (LANE_BYTES_CAP_$(_lc_envkey "$l"), catalog/lane-caps.conf)]" \
    "$kept"
}

# _lc_knobs — LANE_CAPS_SCAN and LANE_CAPS_PRICE_MAX into $_LC_SCAN / $_LC_PMAX
#   (BH-1940, catalog/lanes.d/_lib.lane-caps.json). Order: operator row > cached
#   row > env > registry default, through lane-gate.sh's lib_env_apply in a
#   subshell, so its fail-closed exit 75 writes its one ALERTS line and cannot
#   end the lane. Then the default in THIS checkout's own registry file, the one
#   source a scratch tree with no rendered registry still has. Neither is a
#   literal. Once per process per env value.
_LC_LIB="$(dirname "${BASH_SOURCE[0]}")"
_LC_KNOB_KEY="none"; _LC_SCAN=""; _LC_PMAX=""
_lc_digits() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
# _lc_default <ENV> — the knob's default in this checkout's registry file, or nothing.
_lc_default() {
  local v
  v=$(jq -r --arg e "$1" '.libs[]? | select(.id == "lane-caps") | .knobs[]?
                          | select(.env == $e) | .default // empty' \
        "$_LC_LIB/../../catalog/lanes.d/_lib.lane-caps.json" 2>/dev/null)
  _lc_digits "$v" && printf '%s' "$v"
  return 0
}
_lc_knobs() {
  local k="${LANE_CAPS_SCAN-}|${LANE_CAPS_SCAN+set}|${LANE_CAPS_PRICE_MAX-}|${LANE_CAPS_PRICE_MAX+set}" r
  [ "$k" = "$_LC_KNOB_KEY" ] && return 0
  _LC_KNOB_KEY="$k"
  r=$(
    lg="$_LC_H/bin/lib/lane-gate.sh"
    [ -r "$lg" ] || lg="$_LC_LIB/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply lane-caps >/dev/null 2>&1
    printf '%s|%s' "${LANE_CAPS_SCAN:-}" "${LANE_CAPS_PRICE_MAX:-}"
  ) || r="|"
  IFS='|' read -r _LC_SCAN _LC_PMAX <<<"$r"
  _lc_digits "$_LC_SCAN" || _LC_SCAN=$(_lc_default LANE_CAPS_SCAN)
  _lc_digits "$_LC_PMAX" || _LC_PMAX=$(_lc_default LANE_CAPS_PRICE_MAX)
  return 0
}

# _lc_window <cost> <scan> — the last <scan> rows of the ledger, or all of it
#   when <scan> is empty (unresolved).
_lc_window() { if [ -n "${2:-}" ]; then tail -n "$2" "$1"; else cat "$1"; fi; }

# lane_day_usd <lane> — what this lane has spent so far in the current UTC day,
# from logs/cost.csv, printed to 2dp. ALWAYS prints a number.
#
# ROWS WITH NO DOLLARS ARE PRICED, NOT SKIPPED. That is the whole reason this
# reader exists rather than an awk one-liner over $13: these three lanes are the
# UNPRICED ones (a runner whose usage capture missed writes tokens and a blank
# cost), and a cap that reads a blank as $0.00 is a cap that never fires on
# precisely the lanes it was built for. Blank rows are priced through
# cost_price_tokens — the repo's ONE pricing formula, cliff included — so this
# never becomes a second answer to "what did that call cost".
#
# BOUNDED: at most LANE_CAPS_PRICE_MAX blank rows are priced (each is a jq
# call). Past that the pricing stops and the shortfall is DECLARED in the lane
# log, because an under-count that nobody is told about is a cap that silently
# reads low.
lane_day_usd() {
  local l="${1:-}" cost day priced blanks n=0 sum=0 line model in out cr cw usd scan pmax
  cost="${COST:-$_LC_H/logs/cost.csv}"
  day="${LANE_CAPS_DAY:-$(date -u +%Y-%m-%d)}"
  if [ ! -r "$cost" ]; then
    _lc_log "$l" "no cost ledger at $cost — spend reads \$0.00 and the daily cap cannot fire"
    printf '0.00\n'; return 0
  fi
  # AN UNRESOLVED BOUND IS NO BOUND, NEVER A $0.00. Both knobs only bound the
  # cost of the read. With nothing to resolve them (a box whose sync landed this
  # library before its registry file), the whole ledger is read and every blank
  # row is priced: slower, never lower, so the cap still fires. Said once a day.
  _lc_knobs
  scan="$_LC_SCAN"; pmax="$_LC_PMAX"
  _lc_digits "$scan" || scan=""
  _lc_digits "$pmax" || pmax=""
  if [ -z "$scan" ] || [ -z "$pmax" ]; then
    _lc_log "$l" "LANE_CAPS_SCAN/LANE_CAPS_PRICE_MAX unresolved (no row, no env, no registry default): reading all of $cost and pricing every blank row"
  fi
  # WHICH COLUMN NAMES THE LANE. cost.csv is `...,project,stage,...` ($3,$4),
  # and these three lanes call agent-call.sh as `triage <lane>` — so the LANE
  # name lands in the PROJECT column and the stage column reads `triage` for all
  # of them. Reading $4 alone would have summed $0.00 for every one of them,
  # forever, and the cap would never once have fired; the first draft of this
  # function did exactly that and a fixture that set both columns to the lane
  # name hid it. Both are matched, so `lane_day_usd triage` also answers for the
  # whole stage, and neither spelling can silently under-count.
  # BOUNDED READ, like cliff_projected_context's (BH-1039 review, N4). cost.csv
  # is append-only and grows for the life of the box; three lanes ask this
  # question on every tick, and a whole-file scan twice per call is a cost the
  # cap itself would start paying. LANE_CAPS_SCAN rows is far more than one UTC
  # day of any of these lanes.
  priced=$(_lc_window "$cost" "$scan" 2>/dev/null | awk -F, -v l="$l" -v d="$day" \
    '($3 == l || $4 == l) && index($1, d) == 1 && $13 ~ /^[0-9]*\.?[0-9]+$/ { s += $13 + 0 } END { printf "%.6f", s + 0 }') || priced=0
  blanks=$(_lc_window "$cost" "$scan" 2>/dev/null | awk -F, -v l="$l" -v d="$day" \
    '($3 == l || $4 == l) && index($1, d) == 1 && $13 !~ /^[0-9]*\.?[0-9]+$/ && ($9 $10 $11 $12) != "" { print $6 "\t" $9 "\t" $10 "\t" $11 "\t" $12 }') || blanks=""
  # THE WINDOW BOUND DECLARES ITSELF (BH-1039 review r2, N2). LANE_CAPS_SCAN
  # rows is a guess about one UTC day of this lane; the hub's own cost.csv runs
  # ~920 rows/day across all lanes, so a busy day can push the day's first row
  # out of the window and the total then reads LOW with nothing to say so. If
  # the OLDEST row still in the window is already dated today, the window may
  # have started mid-day — say it rather than let the cap read low in silence.
  if _lc_window "$cost" "$scan" 2>/dev/null | head -1 \
     | awk -F, -v d="$day" '{ exit !(index($1, d) == 1) }'; then
    _lc_log "$l" "the last $scan rows of $cost all start inside $day — the window may not reach this day's first row and the day total below can read LOW; raise LANE_CAPS_SCAN"
  fi
  sum="$priced"
  if [ -n "$blanks" ] && command -v cost_price_tokens >/dev/null 2>&1; then
    while IFS=$'\t' read -r model in out cr cw; do
      [ -n "$model" ] || continue
      n=$((n+1))
      if [ -n "$pmax" ] && [ "$n" -gt "$pmax" ]; then
        _lc_log "$l" "more than $pmax unpriced rows today — the day total below counts only the first $pmax of them and reads LOW"
        break
      fi
      usd=$(cost_price_tokens "$model" "$in" "$out" "$cr" "$cw") || usd=""
      [ -n "$usd" ] && sum=$(awk -v a="$sum" -v b="$usd" 'BEGIN{printf "%.6f", a + b}')
    done <<<"$blanks"
  elif [ -n "$blanks" ]; then
    _lc_log "$l" "rows with tokens and no dollars today, and cost_price_tokens is not loaded — the day total reads LOW"
  fi
  awk -v s="$sum" 'BEGIN{ printf "%.2f\n", s + 0 }'
}

# lane_day_cap_tripped <lane> — rc 0 when the lane is at or over its daily
# dollar cap. On the FIRST trip of a UTC day it also writes one ALERTS line.
#
# ONE LINE PER LANE PER UTC DAY, like every other daily alert in this repo: the
# lane is about to stop on every tick until midnight, and 144 identical pages is
# how a real one gets missed. The line is appended BEFORE the flag is touched,
# so a crash between the two costs a duplicate line rather than a silent stop.
lane_day_cap_tripped() {
  local l="${1:-}" cap spend flag
  [ -n "$l" ] || return 1
  cap=$(lane_cap_usd "$l") || return 1
  [ "$cap" = off ] && return 1
  _lc_num "$cap" >/dev/null || return 1
  spend=$(lane_day_usd "$l")
  awk -v s="$spend" -v c="$cap" 'BEGIN{ exit !(s + 0 >= c + 0) }' || return 1
  flag="$_LC_H/flags/alerted-lane-usd-$(printf '%s' "$l" | tr -c 'A-Za-z0-9._-' '_')-${LANE_CAPS_DAY:-$(date -u +%Y%m%d)}"
  if [ ! -f "$flag" ]; then
    mkdir -p "$_LC_H/logs" "$_LC_H/flags" 2>/dev/null
    HARNESS="$_LC_H" "$_LC_AL" "[$l] DAILY SPEND CAP: \$$spend spent today against a \$$cap/day cap — this lane is STOPPED until 00:00Z and is buying no sessions. Nothing is dropped: its work stays queued. Raise or clear the cap in $(lane_caps_source) (lane $l), or for one run LANE_USD_CAP_$(_lc_envkey "$l")=off." || return 0
    touch "$flag" 2>/dev/null
  fi
  return 0
}

# ---------------------------------------------------------------------------
# THE NOISE BUDGET (BH-1168): how many sessions that found NOTHING this lane may
# buy in one UTC day. The dollar cap bounds the bill; this one bounds the
# pointlessness, and it fires whatever a session costs.
# ---------------------------------------------------------------------------

# lane_noise_cap <lane> — noise-only sessions per UTC day. Prints `off` for a
# lane that is deliberately unbounded, and NOTHING (rc 1) for an empty name.
lane_noise_cap() {
  _lc_load
  local l="${1:-}" v vn
  [ -n "$l" ] || return 1
  vn="LANE_NOISE_CAP_$(_lc_envkey "$l")"; v="${!vn:-}"
  if [ -n "$v" ]; then
    if [ "$v" = off ] || _lc_count "$v" >/dev/null; then
      printf '%s\n' "$v"; return 0
    fi
    # IGNORED AND NAMED, never obeyed and never read as 0 — the same rule
    # lane_cap_bytes follows. A typo here would otherwise stop the de-noising
    # layer for a day, which is the loudest possible way to lose one.
    _lc_log "$l" "$vn=$v is not a whole number of sessions — IGNORED; the lane's configured noise budget stands"
  fi
  # NOTHING ABOUT THE BINDING BOUND IS SILENT, the BH-1164 rule applied to this
  # bound: a lane running on the built-in number (no conf on the box, or a conf
  # with no row for it) says so once per lane per UTC day, with the number that
  # is actually in force and how to change it.
  if [ -z "${_LC_NOISE[$l]:-}" ] && [ -z "$_LC_DEF_NOISE_SET" ]; then
    _lc_log "$l" "no noise row for this lane in $_LC_SOURCE — its noise budget is the built-in default of $_LC_DEF_NOISE noise-only session(s)/day (bin/lib/lane-caps.sh). Add a 'noise $l <n|off>' row to catalog/lane-caps.conf, or set $vn."
  fi
  printf '%s\n' "${_LC_NOISE[$l]:-$_LC_DEF_NOISE}"
}

# The counter's path: ONE file per lane, holding `<YYYY-MM-DD><TAB><n>`.
# One file, not one per day, so a lane that has run for a year has one row to
# read and nothing to prune — a stale day is overwritten, never summed.
_lc_noise_file() {
  printf '%s/state/lane-noise-%s.count' \
    "$_LC_H" "$(printf '%s' "${1:-lane}" | tr -c 'A-Za-z0-9._-' '_')"
}

# lane_noise_count <lane> — noise-only sessions recorded so far TODAY.
#   rc 0 + a number   a counter that was read (a missing file is a real 0)
#   rc 2 + NOTHING    present but unreadable — the caller fails OPEN
#
# ABSENT IS NOT UNREADABLE (D11). No file at all is the normal first state of
# every lane on every box and is a silent 0; a directory, a truncated row or a
# read error is a DEGRADE, and it is declared before the lane runs on without
# the bound.
lane_noise_count() {
  local l="${1:-}" f day line k n
  [ -n "$l" ] || return 1
  f=$(_lc_noise_file "$l")
  day="${LANE_CAPS_DAY:-$(date -u +%Y-%m-%d)}"
  [ -e "$f" ] || { printf '0\n'; return 0; }
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    _lc_log "$l" "the noise counter $f is not a readable file — the noise budget fails OPEN, the lane runs"
    return 2
  fi
  line=$(head -1 "$f" 2>/dev/null) || line=""
  IFS=$'\t' read -r k n <<<"$line"
  if [ -z "${k:-}" ] || ! _lc_count "${n:-}" >/dev/null; then
    _lc_log "$l" "the noise counter $f does not hold '<day><TAB><n>' — the noise budget fails OPEN, the lane runs"
    return 2
  fi
  # A counter stamped with another UTC day is not this day's count. It reads 0
  # and the next write overwrites it.
  [ "$k" = "$day" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$n"
}

# lane_noise_record <lane> <handled> <escalated> — one finished session's
# verdict. `handled=0 escalated=0` bumps the count; anything the session
# actually did RESETS it to 0, so a lane that starts finding real problems again
# is not still stopped on this morning's noise.
#
# ALWAYS rc 0 to the caller, and a failed write is a declared line rather than a
# stop: this runs after the session has already been bought, and a bound that
# aborts a tick because it could not write a counter costs more than the counter
# is worth.
lane_noise_record() {
  local l="${1:-}" h="${2:-}" e="${3:-}" f day rc
  [ -n "$l" ] || return 1
  # BOTH FIELDS OR NEITHER (D9/D11). A session whose summary could not be parsed
  # is not a noise verdict and not a useful one; it changes nothing.
  _lc_count "$h" >/dev/null && _lc_count "$e" >/dev/null || return 1
  f=$(_lc_noise_file "$l")
  day="${LANE_CAPS_DAY:-$(date -u +%Y-%m-%d)}"
  mkdir -p "$_LC_H/state" 2>/dev/null
  # A FEW MILLISECONDS OF LOCK, NEVER A QUEUE (the operator, 2026-09-13). The flock is
  # around this one read-modify-write and is released with the subshell; nothing
  # here waits for another lane's session.
  (
    exec 8>"$f.lock" 2>/dev/null || exit 3
    flock 8 2>/dev/null
    # `mv` onto a DIRECTORY moves the temp file INSIDE it and reports success,
    # which would read as a working counter forever. A path that exists and is
    # not a regular file is a write failure, said out loud.
    [ ! -e "$f" ] || [ -f "$f" ] || exit 4
    local cur next
    if [ "$h" -gt 0 ] || [ "$e" -gt 0 ]; then
      next=0
    else
      cur=$(lane_noise_count "$l" 2>/dev/null) || cur=0
      [ -n "$cur" ] || cur=0
      next=$(( cur + 1 ))
    fi
    printf '%s\t%s\n' "$day" "$next" > "$f.tmp" 2>/dev/null || exit 5
    mv -f "$f.tmp" "$f" 2>/dev/null || exit 6
  )
  rc=$?
  [ "$rc" -eq 0 ] \
    || _lc_log "$l" "could not write the noise counter $f (rc $rc) — this session is not being counted and the noise budget reads LOW; the lane runs"
  return 0
}

# lane_noise_cap_tripped <lane> — rc 0 when the lane has spent its noise budget
# for this UTC day. On the FIRST trip of the day it also writes one ALERTS line.
#
# ONE PAGE PER LANE PER UTC DAY, appended BEFORE the flag is touched: the lane
# will stop on every tick until midnight, 144 identical pages is how a real one
# gets missed, and a crash between the line and the flag costs a duplicate line
# rather than a silent stop.
lane_noise_cap_tripped() {
  local l="${1:-}" cap n flag
  [ -n "$l" ] || return 1
  cap=$(lane_noise_cap "$l") || return 1
  [ "$cap" = off ] && return 1
  _lc_count "$cap" >/dev/null || return 1
  # FAIL OPEN on rc 2: lane_noise_count has already declared the degrade, and a
  # bound that stops the de-noising layer because a file was unreadable would
  # fire in exactly the situation the layer is needed.
  n=$(lane_noise_count "$l") || return 1
  [ -n "$n" ] || return 1
  [ "$n" -ge "$cap" ] 2>/dev/null || return 1
  flag="$_LC_H/flags/alerted-lane-noise-$(printf '%s' "$l" | tr -c 'A-Za-z0-9._-' '_')-${LANE_CAPS_DAY:-$(date -u +%Y%m%d)}"
  if [ ! -f "$flag" ]; then
    mkdir -p "$_LC_H/logs" "$_LC_H/flags" 2>/dev/null
    HARNESS="$_LC_H" "$_LC_AL" "[$l] NOISE BUDGET: $n session(s) today concluded handled=0 escalated=0 against a budget of $cap/day — this lane is STOPPED until 00:00Z and is buying no sessions. Nothing is dropped: its work stays queued. A session that handles or escalates something resets the count. Raise or clear the budget in $(lane_caps_source) (noise $l), or for one run LANE_NOISE_CAP_$(_lc_envkey "$l")=off." || return 0
    touch "$flag" 2>/dev/null
  fi
  return 0
}

# One degrade line into the lane's own log, deduped per lane per UTC day. A
# fail-open reader that says nothing is indistinguishable from one that read a
# real zero — which is the dead-feed shape this repo keeps paying for.
_lc_log() {
  local l="${1:-lane}" msg="${2:-}" flag sig
  # KEYED ON THE MESSAGE TOO (BH-1039 review r2, N3). One flag per lane per day
  # meant the FIRST degrade of the day silenced every LATER, DIFFERENT one — an
  # unreadable ledger at 00:05 would have swallowed "the day total reads LOW" for
  # the next 24 hours. Each distinct message still says itself once a day.
  sig=$(printf '%s' "$msg" | cksum 2>/dev/null | cut -d' ' -f1); sig="${sig:-0}"
  flag="$_LC_H/flags/lane-caps-degraded-$(printf '%s' "$l" | tr -c 'A-Za-z0-9._-' '_')-${LANE_CAPS_DAY:-$(date -u +%Y%m%d)}-$sig"
  [ -f "$flag" ] && return 0
  mkdir -p "$_LC_H/logs" "$_LC_H/flags" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [lane-caps] $l: $msg" >> "$_LC_H/logs/lane-caps.log" 2>/dev/null
  touch "$flag" 2>/dev/null
  return 0
}
