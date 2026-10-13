#!/bin/bash
# bin/lib/gate-release.sh — BH-3825: the shared contract for releasing work
# that is gated on another ticket's merge. Sourced, never executed. Defines
# functions only, then sources the part files below: no `set -e`, safe under
# the caller's `set -u`.
#
# WHY. project-4 TK-2186 came back PLAN_BLOCKED on TK-2185 (2026-10-01). TK-2185
# merged at 16:03Z, nothing re-read the `LAUNCH-QUEUE gate: TK-2185 ... merged`
# line, and TK-2186 was launched by hand at 17:47Z.
#
# WHAT IS HERE. The grammar of a merge gate (gr_parse_gate), the "has KEY
# merged?" truth (gr_key_merged) and small readers over this box's build
# records. The work functions (gr_release_queue, gr_reoffer_scan, ...) are
# defined by part files under bin/lib/gate-release/, sourced at the end of this
# file; bin/gate-release.sh calls them only when they are defined.
#
# MERGED means a merged PR, never a board status, checked in this order:
#   (a) `PR_MERGED <url>` on line 1 of builds/<p>-<KEY>-*/RESULT or
#       builds/pool-<p>-<KEY>-*/RESULT; merged_at = that RESULT's mtime;
#   then the split-chain positive cache state/split-chain/<p>/merged/<KEY>;
#   (b) merge_ledger_has <url> (bin/lib/jobs/jobs.sh, when the caller loaded
#       it) for the newest `PR_CREATED <url>` in fleet.conf's repo; a hit
#       writes that cache;
#   (c) split_chain_key_merged (bin/lib/split-chain.sh), one GitHub REST read,
#       at most GATE_RELEASE_MAX_LOOKUPS per shell.
# For (b) and (c) merged_at is the cache file's mtime. An outage, the budget,
# the cap, a foreign repo, an open or a closed PR = NOT merged, and nothing is
# cached, so a failure leaves today's behaviour.
#
# STATE: state/gate-release/<p>/ (created by gr_state_dir; nothing in this file
# writes into it) and the shared split-chain merged cache above.
#
# KNOBS (catalog/lanes.d/_lib.json `gate-release`, resolved through
# lib_env_apply; the numbers below are the documented fallback only):
#   GATE_RELEASE_MAX_LAUNCHES (0 = dark: ships off, one settings row turns it
#   on)  GATE_RELEASE_REMIND_S (21600)
#   GATE_RELEASE_MAX_LOOKUPS (10) — GitHub reads per shell, read here
# KILL SWITCH: gate-release-off, read by bin/gate-release.sh through lane_switch.
# shellcheck shell=bash

_GR_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_GR_APPLIED=0
_GR_READS=0

if ! declare -F split_chain_key_merged >/dev/null 2>&1; then
  # shellcheck source=bin/lib/split-chain.sh
  [ -r "$_GR_LIBDIR/split-chain.sh" ] && . "$_GR_LIBDIR/split-chain.sh"
fi

# _gr_knobs — sets _GR_MAXLAUNCH/_GR_REMIND/_GR_MAXL in THIS shell; the
# settings contract is applied once per process (the _sc_knobs idiom).
_gr_knobs() {
  if [ "$_GR_APPLIED" = 0 ]; then
    _GR_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_GR_LIBDIR/lane-gate.sh" ] && . "$_GR_LIBDIR/lane-gate.sh"
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply gate-release
  fi
  _GR_MAXLAUNCH="${GATE_RELEASE_MAX_LAUNCHES:-0}"
  _GR_REMIND="${GATE_RELEASE_REMIND_S:-21600}"
  _GR_MAXL="${GATE_RELEASE_MAX_LOOKUPS:-10}"
  case "$_GR_MAXLAUNCH" in ''|*[!0-9]*) _GR_MAXLAUNCH=0 ;; esac
  case "$_GR_REMIND" in ''|*[!0-9]*) _GR_REMIND=21600 ;; esac
  case "$_GR_MAXL" in ''|*[!0-9]*) _GR_MAXL=10 ;; esac
  return 0
}

_GR_KEY_RE='^[A-Z][A-Z0-9]{0,9}-[0-9]+$'
_GR_VOCAB=' and both all its their the is are has have been pr prs merged to into main master on once after when lands landed '

# gr_parse_gate <line> — rc 0 and the blocker keys, one per line, when the text
# after the first `gate:` (any case), with every ` project=<name>` token taken
# out (rq_lines appends it; it is never a condition), up to the first `;`,
# ` | `, ` — ` or the end, is a pure merge gate: it says `merged`, names a key
# other than the line's own (its first token, when that is a key), and holds
# nothing but keys, `PR`, `#N`, `(),&+` and the connective vocabulary above.
# Anything else is a prose gate: rc 1, nothing printed.
# THE TAIL after that separator must be filler (the operator, 2026-10-02): tokens with
# no letter or digit, an ISO stamp (`2026-10-01`, `2026-10-01T16:03Z`, `16:03Z`),
# `#N`, `PR`, or the vocabulary. A key there (the line's own included) or any
# other word makes the WHOLE line prose, so `TK-2185 merged; then QA by the
# client` is never released on TK-2185 alone.
# A dotted key (`BH-3825.0`) matches neither the key pattern nor the
# vocabulary, so a gate naming one is prose and is never released (accepted,
# the operator 2026-10-02).
gr_parse_gate() {
  local line="${1:-}" lc pre seg tail="" own="" tok w merged=0 keys="" k us=$'\x1f'
  local -a toks=()
  lc="${line,,}"
  pre="${lc%%gate:*}"
  [ "$pre" != "$lc" ] || return 1
  seg=" ${line:$(( ${#pre} + 5 ))} "
  while [[ $seg =~ [[:space:]]project=[a-z-]+[[:space:]] ]]; do
    seg="${seg/"${BASH_REMATCH[0]}"/ }"
  done
  seg="${seg//;/$us}"; seg="${seg// | /$us}"; seg="${seg// — /$us}"
  case "$seg" in *"$us"*) tail="${seg#*"$us"}"; seg="${seg%%"$us"*}" ;; esac
  tail="${tail//$us/ }"
  read -r -a toks <<<"$tail"
  for tok in "${toks[@]}"; do
    w="${tok//[(),&+]/}"
    [[ $w =~ [A-Za-z0-9] ]] || continue
    [[ $w =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9:.]+Z?)?$ ]] && continue
    [[ $w =~ ^[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z$ ]] && continue
    [[ $w =~ ^#[0-9]+$ ]] && continue
    case "$w" in PR|pr) continue ;; esac
    [[ $w =~ $_GR_KEY_RE ]] && return 1
    case "$_GR_VOCAB" in *" ${w,,} "*) continue ;; esac
    return 1
  done
  seg="${seg//[(),&+]/ }"
  read -r own _ <<<"$line"
  [[ $own =~ $_GR_KEY_RE ]] || own=""
  read -r -a toks <<<"$seg"
  for tok in "${toks[@]}"; do
    if [[ $tok =~ $_GR_KEY_RE ]]; then
      [ "$tok" = "$own" ] && continue
      case " $keys " in *" $tok "*) ;; *) keys="${keys:+$keys }$tok" ;; esac
      continue
    fi
    case "$tok" in PR|pr) continue ;; esac
    [[ $tok =~ ^#[0-9]+$ ]] && continue
    w="${tok,,}"
    case "$_GR_VOCAB" in
      *" $w "*) [ "$w" = merged ] && merged=1; continue ;;
    esac
    return 1
  done
  [ "$merged" = 1 ] && [ -n "$keys" ] || return 1
  for k in $keys; do printf '%s\n' "$k"; done
  return 0
}

# _gr_at <file> — the evidence time: the file's mtime, or now when it is gone.
_gr_at() {
  local t
  t=$(_sc_mtime "$1")
  case "$t" in ''|0|*[!0-9]*) t=$(date +%s) ;; esac
  printf '%s' "$t"
}

# gr_key_merged <harness> <project> <KEY> — rc 0 and `<pr>\t<merged_at>` when
# merged (tiers in the header); rc 1 and nothing otherwise. Call it in the
# caller's own shell, not in $( ), for the lookup cap to span a pass.
gr_key_merged() {
  local h="${1:-}" p="${2:-}" k="${3:-}" d l url n newest="" nt=0 t slug rslug mk
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  declare -F _sc_dirs >/dev/null 2>&1 || return 1
  _gr_knobs
  mk="$h/state/split-chain/$p/merged/$k"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -f "$d/RESULT" ] || continue
    l=""; IFS= read -r l < "$d/RESULT" 2>/dev/null
    case "$l" in
      "PR_MERGED "*)
        url=$(printf '%s' "${l#PR_MERGED }" | awk '{print $1}')
        n=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+).*#\1#p')
        printf '%s\t%s\n' "$n" "$(_gr_at "$d/RESULT")"
        return 0 ;;
      "PR_CREATED "*)
        t=$(_sc_mtime "$d/RESULT")
        [ "$t" -ge "$nt" ] 2>/dev/null && { nt="$t"; newest="$l"; } ;;
    esac
  done < <(_sc_dirs "$h" "$p" "$k")
  if [ -f "$mk" ]; then
    printf '%s\t%s\n' "$(tr -dc '0-9' < "$mk" 2>/dev/null)" "$(_gr_at "$mk")"
    return 0
  fi
  [ -n "$newest" ] || return 1
  if declare -F merge_ledger_has >/dev/null 2>&1; then
    slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
    url=$(printf '%s' "${newest#PR_CREATED }" | awk '{print $1}')
    rslug=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+([/?#].*)?$#\1#p')
    n=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)([/?#].*)?$#\1#p')
    if [ -n "$slug" ] && [ -n "$rslug" ] && [ -n "$n" ] \
       && [ "${rslug,,}" = "${slug,,}" ] && merge_ledger_has "$url" >/dev/null 2>&1; then
      mkdir -p "${mk%/*}" 2>/dev/null && printf '%s\n' "$n" > "$mk" 2>/dev/null
      printf '%s\t%s\n' "$n" "$(_gr_at "$mk")"
      return 0
    fi
  fi
  [ "$_GR_READS" -lt "$_GR_MAXL" ] || return 1
  _GR_READS=$((_GR_READS + 1))
  n=$(split_chain_key_merged "$h" "$p" "$k") || return 1
  printf '%s\t%s\n' "$n" "$(_gr_at "$mk")"
  return 0
}

# gr_newest_result <harness> <project> <KEY> — `<dir>\t<RESULT line 1>` for
# KEY's newest build dir (by dir mtime), `<dir>\tINFLIGHT` when it has no
# RESULT yet; rc 1 and nothing when KEY has no build dir.
gr_newest_result() {
  local h="${1:-}" p="${2:-}" k="${3:-}" d best="" bt=-1 t l
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  declare -F _sc_dirs >/dev/null 2>&1 || return 1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    t=$(_sc_mtime "$d")
    [ "$t" -gt "$bt" ] 2>/dev/null && { bt="$t"; best="$d"; }
  done < <(_sc_dirs "$h" "$p" "$k")
  [ -n "$best" ] || return 1
  if [ -f "$best/RESULT" ]; then
    l=""; IFS= read -r l < "$best/RESULT" 2>/dev/null
    printf '%s\t%s\n' "$best" "$l"
  else
    printf '%s\tINFLIGHT\n' "$best"
  fi
  return 0
}

# gr_ticket_id <harness> <project> <KEY> [fallback] — the board ticket id from
# state/<p>.keymap.json (the map of OPEN tickets: a readable map without KEY
# means closed, rc 1). With no readable map, the fallback token when it is
# `[0-9A-Za-z_-]+` and not an all-caps word (HOLD, READY); else rc 1.
gr_ticket_id() {
  local h="${1:-}" p="${2:-}" k="${3:-}" fb="${4:-}" km id
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  km="$h/state/$p.keymap.json"
  if jq -e 'type == "object"' "$km" >/dev/null 2>&1; then
    id=$(jq -r --arg k "$k" '.[$k] // empty' "$km" 2>/dev/null) || id=""
    [ -n "$id" ] || return 1
    printf '%s\n' "$id"
    return 0
  fi
  case "$fb" in ''|*[!0-9A-Za-z_-]*) return 1 ;; esac
  [[ $fb =~ ^[A-Z]+$ ]] && return 1
  printf '%s\n' "$fb"
  return 0
}

# gr_state_dir <harness> <project> — creates and prints state/gate-release/<p>.
gr_state_dir() {
  local h="${1:-}" p="${2:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 1
  printf '%s\n' "$h/state/gate-release/$p"
  mkdir -p "$h/state/gate-release/$p" 2>/dev/null
}

# The sibling part files: every bin/lib/gate-release/*.sh, wherever this lib is
# sourced. A part that fails to source never fails this one.
for _gr_f in "$_GR_LIBDIR/gate-release/"*.sh; do
  # shellcheck source=/dev/null
  [ -r "$_gr_f" ] && { . "$_gr_f" || true; }
done
unset _gr_f
