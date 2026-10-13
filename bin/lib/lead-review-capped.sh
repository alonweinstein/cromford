#!/bin/bash
# bin/lib/lead-review-capped.sh — one warn when this box's lead-review
# concurrency stays capped below its configured value by /tmp, memory or cpu.
# Sourced by bin/lead-review.sh, never executed; defining a function is its
# only effect at source time.
#
# WHY. On 2026-10-11 box-small ran lead reviews one at a time from at
# least 15:06Z: `concurrency capped at 1 by /tmp` on every tick, 6 requests
# waiting a tick, and nothing paged. The cap line was in logs/lead-review.log
# only (BH-6041).
#
# lr_capped_check <configured> [box] — call once a tick, right after
# rpool_init. It reads RPOOL_CAP_BY, RPOOL_K and RPOOL_CAP_WHY.
#   capped  = RPOOL_CAP_BY is tmp, memory or cpu (BH-5337) AND RPOOL_K is below the configured
#             value. A configured value of 0 (no cap) compares against
#             LEAD_REVIEW_CAP_ALERT_MIN (default 4). A box_max cap is an
#             operator choice and never counts.
#   state   = state/lead-review-capped.<box>: `<epoch of the first capped tick>
#             <0|1 warned>`, written tmp + mv. A line that does not parse counts
#             as absent, which restarts the window: a lost file delays the warn,
#             it never doubles it.
#   capped, no state             -> write `<now> 0`.
#   capped, held >= LEAD_REVIEW_CAP_ALERT_AFTER_MIN (30) min, not warned
#                                -> one bin/lane-alert.sh warn (the batched
#                                   digest), id lead-review-capped-<box>; the
#                                   state says warned only when that call
#                                   answered rc 0, so a failed call is retried
#                                   next tick.
#   not capped, state present    -> remove it and resolve the id.
# rc 1 with nothing written when there is no harness root. A bad knob uses its
# default and logs one line through the caller's `log`, when it has one.
# Test seam: LEAD_REVIEW_CAP_NOW (epoch).

_lrc_log() { command -v log >/dev/null 2>&1 && log "$*"; return 0; }
# _lrc_knob <name> <default> <min> [max] — the knob's value, or the default
# (logged) when it is not a whole number inside the bounds.
_lrc_knob() {
  local v="${!1:-}"
  [ -n "$v" ] || { printf '%s' "$2"; return; }
  case "$v" in
    *[!0-9]*) ;;
    *) if [ "$((10#$v))" -ge "$3" ] && { [ -z "${4:-}" ] || [ "$((10#$v))" -le "$4" ]; }; then printf '%s' "$((10#$v))"; return; fi ;;
  esac
  _lrc_log "$1='$v' is not a whole number in range; using $2"
  printf '%s' "$2"
}

lr_capped_check() { # lr_capped_check <configured> [box]
  local conf="${1:-}" box="${2:-}" h="${HARNESS:-${H:-}}" la st now after floor want k first warned held text
  [ -n "$h" ] || return 1
  [ -n "$box" ] || box=$(hostname 2>/dev/null)
  box="${box//[^A-Za-z0-9._-]/_}"
  [ -n "$box" ] || return 1
  st="$h/state/lead-review-capped.$box"
  la="$h/bin/lane-alert.sh"
  now="${LEAD_REVIEW_CAP_NOW:-$(date +%s)}"
  after=$(_lrc_knob LEAD_REVIEW_CAP_ALERT_AFTER_MIN 30 5)
  floor=$(_lrc_knob LEAD_REVIEW_CAP_ALERT_MIN 4 1 32)
  case "$conf" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$conf" = 0 ]; then want=$floor; else want=$conf; fi
  k="${RPOOL_K:-}"
  case "$k" in ''|*[!0-9]*) return 0 ;; esac

  case "${RPOOL_CAP_BY:-}" in
    tmp|memory|cpu) [ "$k" -lt "$want" ] ;;
    *) false ;;
  esac
  if [ $? -ne 0 ]; then
    if [ -e "$st" ]; then
      rm -f -- "$st" 2>/dev/null
      "$la" --resolve --id "lead-review-capped-$box" lead-review \
        "lead-review on $box: concurrency is back to $k (configured value $conf)." >/dev/null 2>&1
    fi
    return 0
  fi

  first=""; warned=""
  [ -r "$st" ] && read -r first warned < "$st" 2>/dev/null
  case "$first:$warned" in [0-9]*:[01]) case "$first" in *[!0-9]*) first="" ;; esac ;; *) first="" ;; esac
  if [ -z "$first" ]; then
    mkdir -p "$h/state" 2>/dev/null
    printf '%s 0\n' "$now" > "$st.tmp.$$" 2>/dev/null && mv -f "$st.tmp.$$" "$st" 2>/dev/null
    return 0
  fi
  [ "$warned" = 1 ] && return 0
  held=$(( (now - first) / 60 ))
  [ "$held" -ge "$after" ] || return 0
  if [ "$conf" = 0 ]; then
    text="lead-review on $box: concurrency capped at $k (configured value 0 = no cap, below LEAD_REVIEW_CAP_ALERT_MIN $floor) by ${RPOOL_CAP_WHY:-$RPOOL_CAP_BY} for $held min."
  else
    text="lead-review on $box: concurrency capped at $k (configured value $conf) by ${RPOOL_CAP_WHY:-$RPOOL_CAP_BY} for $held min."
  fi
  text="$text Free /tmp or memory on the box, raise the /tmp size (bin/tmpfs-ensure.sh), or for a cpu cap lower LEAD_REVIEW_WORKER_CPUS or move reviews to a box with more vCPUs."
  if "$la" --severity warn --id "lead-review-capped-$box" lead-review "$text" >/dev/null 2>&1; then
    printf '%s 1\n' "$first" > "$st.tmp.$$" 2>/dev/null && mv -f "$st.tmp.$$" "$st" 2>/dev/null
  fi
  return 0
}
