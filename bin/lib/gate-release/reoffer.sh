#!/bin/bash
# bin/lib/gate-release/reoffer.sh — BH-3829 (slice 3 of #3825): a settled
# PLAN_BLOCKED result is re-offered once every blocker it stated has merged. A
# part file of bin/lib/gate-release.sh, which sources it; bin/gate-release.sh
# calls gr_reoffer_scan once per triage tick, bin/triage-gate.sh step 1d reads
# the keys file it writes, and bin/lib/rt/scope.sh calls gate_release_take_lines.
#
# WHY. project-4 TK-2186 came back PLAN_BLOCKED on TK-2185 and its RESULT was
# marked COMMENTED, so it counted as settled. TK-2185 merged at 16:03Z and
# nothing put TK-2186 back in front of a session; it was launched by hand at
# 17:47Z. This pass notices the merge and hands the ticket to the next tick as
# a `board gate: REOFFER` line. It never launches: the session decides.
#
# SHIPS DARK. GATE_RELEASE_MAX_LAUNCHES falls back to 0, and at 0 every
# function here returns before it reads anything: no GitHub read, no write, no
# log line. The same settings row (lib.gate-release.GATE_RELEASE_MAX_LAUNCHES)
# that turns the queue release on turns this on, and it is also the most
# offers one pass makes.
#
# DUE (gr_reoffer_due), per key with a `PLAN_BLOCKED*` RESULT on this box; every
# check fails closed:
#   an in-app board (board_prefix not `-`) with a readable keymap that holds
#   the key (open); gr_newest_result is that same dir, still PLAN_BLOCKED, and
#   the dir has COMMENTED (nothing newer, nothing in flight); the build-key lock
#   is not held; the queue pass has not released the key since the RESULT; not
#   offered within GATE_RELEASE_REMIND_S; at least one STATED blocker, and every
#   one merged (gr_key_merged) after the RESULT's mtime.
# STATED BLOCKERS are the union of the key's own READY-QUEUE line's
# gr_parse_gate keys and the keys in the newest logs/decisions.log line for
# this project and key, when that line is newer than the RESULT and says
# PLAN_BLOCKED. A queue line for the key whose `gate:` is prose vetoes the
# offer (the operator, 2026-10-02: text after a separator is prose). A dotted key
# (`TK-2185.0`) never counts.
# WRITE ORDER per offer: state/gate-release/<p>/offered/<KEY> (epoch) FIRST,
# then the one-shot state/gate-reoffer-keys-<p>, then one GATE_REOFFER line in
# logs/<p>.log (also printed, so the driver counts one action). A failed write
# skips that key.
# STATE: offered/<KEY> under state/gate-release/<p>/, and the keys file, which
# the tick's take deletes (or the gate deletes unread once older than the
# window). Root comes only from the <harness> argument.
# shellcheck shell=bash

if ! declare -F rq_lines >/dev/null 2>&1; then
  # shellcheck source=bin/lib/ready-queue.sh
  [ -r "$_GR_LIBDIR/ready-queue.sh" ] && . "$_GR_LIBDIR/ready-queue.sh"
fi

# _grr_log <harness> <project> <text> — one line in logs/<p>.log.
_grr_log() {
  local now="${GR_NOW:-$(date +%s)}"
  printf '%s [%s] %s\n' "$(date -u -d "@$now" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null)" "$2" "$3" \
    >> "$1/logs/$2.log" 2>/dev/null
  return 0
}

# _grr_keys <text> <own-key> — the undotted keys <text> names, minus its own.
_grr_keys() {
  local k
  for k in $(printf '%s\n' "$1" | grep -oE '\b[A-Z][A-Z0-9]{0,9}-[0-9]+(\.[0-9]+)?\b' || true); do
    case "$k" in *.*|"$2") continue ;; esac
    printf '%s\n' "$k"
  done
  return 0
}

# _grr_blockers <harness> <project> <KEY> <ticket-id> <result-mtime> — the
# stated blockers, one per line. rc 1 = a prose queue gate vetoes the offer.
_grr_blockers() {
  local h="$1" p="$2" k="$3" id="$4" rt="$5" line lp first out="" b dl at
  if declare -F rq_lines >/dev/null 2>&1; then
    while IFS= read -r line; do
      read -r first _ <<<"$line"
      [ "$first" = "$k" ] || continue
      if [[ $line =~ project=([a-z-]+) ]]; then lp="${BASH_REMATCH[1]}"
      else lp=$("$h/bin/project-of.sh" "$line" 2>/dev/null) || lp=""; fi
      [ "$lp" = "$p" ] || continue
      case "${line,,}" in *gate:*) ;; *) continue ;; esac
      b=$(gr_parse_gate "$line") || return 1
      out="${out:+$out
}$b"
    done < <(rq_lines "$h" "$p" 2>/dev/null)
  fi
  # `<date> <time>Z [p] gate=G scope=S KEY :: action :: reason` (bin/decision-log.sh);
  # the session may name the ticket by its key or by its board id.
  dl=$(awk -v p="[$p]" -v k="$k" -v id="$id" '
    { i = index($0, " :: "); if (!i) next
      n = split(substr($0, 1, i - 1), f, " ")
      if (n >= 4 && f[3] == p && (f[n] == k || f[n] == id)) last = $0 }
    END { if (last != "") print last }' "$h/logs/decisions.log" 2>/dev/null) || dl=""
  if [ -n "$dl" ]; then
    read -r at _ <<<"$dl"
    at=$(date -u -d "$at ${dl:11:8}" +%s 2>/dev/null) || at=0
    case "${dl#* :: }" in
      *PLAN_BLOCKED*)
        if [ "$at" -gt "$rt" ] 2>/dev/null; then
          b=$(_grr_keys "${dl#* :: }" "$k")
          out="${out:+$out
}$b"
        fi ;;
    esac
  fi
  printf '%s\n' "$out" | awk 'NF && !s[$0]++'
  return 0
}

# gr_reoffer_due <harness> <project> [--any-offer] — prints
# `<KEY>\t<dir>\t<KEY-N (#pr), ...>\t<KEY-N merged (#pr), ...>` per due key.
# --any-offer skips the remind window (the take re-verifies keys the scan has
# just stamped). Always rc 0.
gr_reoffer_due() {
  local h="${1:-}" p="${2:-}" anyoff="${3:-}" bp km s now r l dir k id nr rt lock off rel
  local blockers b tmp mo pr at names why ok seen=" "
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _gr_knobs
  [ "$_GR_MAXLAUNCH" -gt 0 ] 2>/dev/null || return 0
  declare -F lane_switch >/dev/null 2>&1 && HARNESS="$h" lane_switch gate-release-off file && return 0
  declare -F _sc_dirs >/dev/null 2>&1 && declare -F _sc_mtime >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  bp=$("$h/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || bp=""
  [ -n "$bp" ] && [ "$bp" != "-" ] || return 0
  km="$h/state/$p.keymap.json"
  jq -e 'type == "object"' "$km" >/dev/null 2>&1 || return 0
  s="$h/state/gate-release/$p"
  now="${GR_NOW:-$(date +%s)}"
  tmp=$(mktemp "${TMPDIR:-/tmp}/gr-reoffer.XXXXXX" 2>/dev/null) || return 0
  for r in "$h/builds/$p-"*/RESULT "$h/builds/pool-$p-"*/RESULT; do
    [ -f "$r" ] || continue
    l=""; IFS= read -r l < "$r" 2>/dev/null
    case "$l" in PLAN_BLOCKED*) ;; *) continue ;; esac
    dir="${r%/RESULT}"; k="${dir##*/}"; k="${k#pool-}"; k="${k#"$p"-}"
    [[ $k =~ ^([A-Z][A-Z0-9]{0,9}-[0-9]+)(-|$) ]] || continue
    k="${BASH_REMATCH[1]}"
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "
    # Cheap, local checks first; a GitHub read is the last thing asked.
    id=$(jq -r --arg k "$k" '.[$k] // empty' "$km" 2>/dev/null) || id=""
    [ -n "$id" ] || continue
    nr=$(gr_newest_result "$h" "$p" "$k") || continue
    [ "${nr%%$'\t'*}" = "$dir" ] || continue
    case "${nr#*$'\t'}" in PLAN_BLOCKED*) ;; *) continue ;; esac
    [ -e "$dir/COMMENTED" ] || continue
    lock="$h/locks/build-key-$p-$k.lock"
    if [ -e "$lock" ]; then
      command -v flock >/dev/null 2>&1 || continue
      ( exec 9>>"$lock" || exit 1; flock -n 9 ) 2>/dev/null || continue
    fi
    rt=$(_sc_mtime "$r")
    # the queue pass (queue.sh) already relaunched it from its queue line
    if [ -e "$s/released/$k" ]; then
      rel=$(_sc_mtime "$s/released/$k")
      [ "$rel" -ge "$rt" ] 2>/dev/null && continue
    fi
    if [ "$anyoff" != "--any-offer" ]; then
      off=$(tr -dc '0-9' < "$s/offered/$k" 2>/dev/null)
      [ -n "$off" ] && [ $(( now - off )) -lt "$_GR_REMIND" ] && continue
    fi
    blockers=$(_grr_blockers "$h" "$p" "$k" "$id" "$rt") || continue
    [ -n "$blockers" ] || continue
    ok=1; names=""; why=""
    for b in $blockers; do
      # gr_key_merged runs in THIS shell (its lookup cap spans the pass), so
      # its answer goes through a file, not $( ).
      gr_key_merged "$h" "$p" "$b" > "$tmp" 2>/dev/null || { ok=0; break; }
      mo=$(cat "$tmp" 2>/dev/null); pr="${mo%%$'\t'*}"; at="${mo#*$'\t'}"
      [ "$at" -gt "$rt" ] 2>/dev/null || { ok=0; break; }
      names="${names:+$names, }$b${pr:+ (#$pr)}"
      why="${why:+$why, }$b merged${pr:+ (#$pr)}"
    done
    [ "$ok" = 1 ] || continue
    printf '%s\t%s\t%s\t%s\n' "$k" "$dir" "$names" "$why"
  done
  rm -f "$tmp"
  return 0
}

# gr_reoffer_scan <harness> <project> — the driver's pass: at most
# GATE_RELEASE_MAX_LAUNCHES offers, each written in the order above.
gr_reoffer_scan() {
  local h="${1:-}" p="${2:-}" due s now k dir names why n=0
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _gr_knobs
  [ "$_GR_MAXLAUNCH" -gt 0 ] 2>/dev/null || return 0
  due=$(gr_reoffer_due "$h" "$p") || due=""
  [ -n "$due" ] || return 0
  s=$(gr_state_dir "$h" "$p") && mkdir -p "$s/offered" 2>/dev/null || return 0
  now="${GR_NOW:-$(date +%s)}"
  while IFS=$'\t' read -r k dir names why; do
    [ -n "$k" ] || continue
    [ "$n" -lt "$_GR_MAXLAUNCH" ] || break
    printf '%s\n' "$now" > "$s/offered/$k" 2>/dev/null || continue
    printf '%s\n' "$k" >> "$h/state/gate-reoffer-keys-$p" 2>/dev/null || continue
    _grr_log "$h" "$p" "GATE_REOFFER $k: PLAN_BLOCKED result re-offered, $why"
    printf 'GATE_REOFFER %s: PLAN_BLOCKED result re-offered, %s\n' "$k" "$why"
    n=$((n + 1))
  done <<<"$due"
  return 0
}

# gate_release_take_lines <harness> <project> — the tick's half. Reads and
# DELETES state/gate-reoffer-keys-<p> (one-shot), re-verifies every key, and
# prints one gate-diff-shaped `board gate: REOFFER <KEY> ...` line per key still
# due. A keys file older than the remind window is deleted unread.
gate_release_take_lines() {
  local h="${1:-}" p="${2:-}" f keys due k dir names why id title
  [ -n "$h" ] && [ -n "$p" ] || return 0
  f="$h/state/gate-reoffer-keys-$p"
  [ -e "$f" ] || return 0
  _gr_knobs
  if [ $(( $(date +%s) - $(_sc_mtime "$f") )) -gt "$_GR_REMIND" ]; then
    rm -f "$f"; return 0
  fi
  keys=$(grep -E '^[A-Z][A-Z0-9]{0,9}-[0-9]+$' "$f" 2>/dev/null | awk '!s[$0]++')
  rm -f "$f"
  [ -n "$keys" ] || return 0
  keys=$'\n'"$keys"$'\n'
  due=$(gr_reoffer_due "$h" "$p" --any-offer) || due=""
  while IFS=$'\t' read -r k dir names why; do
    [ -n "$k" ] || continue
    case "$keys" in *$'\n'"$k"$'\n'*) ;; *) continue ;; esac
    id=$(jq -r --arg k "$k" '.[$k] // empty' "$h/state/$p.keymap.json" 2>/dev/null) || id=""
    title=""
    [ -n "$id" ] && title=$(jq -r --arg id "$id" \
      '[.[]? | .[]? | select(type == "object") | select((.id | tostring) == $id) | .title // ""][0] // "" | gsub("[\\n\\t\\r]"; " ")' \
      "$h/state/$p.gate.json" 2>/dev/null)
    printf 'board gate: REOFFER %s "%s" (PLAN_BLOCKED result %s is not settled: %s merged after it; re-read the thread and relaunch per the queue rules if nothing else blocks it. If you do not launch it this tick, write ONE line DECISION: %s :: defer :: <reason>)\n' \
      "$k" "$title" "${dir##*/}" "$names" "$k"
  done <<<"$due"
  return 0
}
