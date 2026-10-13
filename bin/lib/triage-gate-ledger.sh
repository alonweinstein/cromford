#!/bin/bash
# bin/lib/triage-gate-ledger.sh — BH-2318. The row twin of the triage gate's
# per-project state, so a project that moves boxes (or a rebuilt box) does not
# re-buy a full triage session on arrival. Sourced, never executed.
#
# WHAT WAS LOST. state/<p>.gate.json (the consumed board fingerprint),
# state/<p>.gate-meta (the full-sweep clock) and state/<p>.gate.fail (the
# BH-1021 failure counter) lived on one machine. On a new box the gate read "no
# gate-meta" as `RUN daily-sweep` and "no gate.json" as `RUN no-gate-state`,
# and a failure streak restarted at 1.
#
# THE ROWS (ledgers, kind=triage_gate, keyed by project):
#   <project>        "<sha256 of gate.json> <gate-meta epoch>"
#   <project> fail   "<sha16|none> <n>" | "cleared"
# The fingerprint BODY is not in the row: status is cut at 128 chars and detail
# at 4000 by worker/jobs/src/routes/ledger.js, and a real fingerprint is ~135KB.
# The sha is enough: when the live board hashes to it, the live fingerprint IS
# the consumed file byte for byte (both are written with printf '%s'), so the
# gate writes it back. When it does not, the old per-ticket state cannot be
# rebuilt and the gate answers what it always has, `RUN no-gate-state`.
# state/<p>.gate.pending gets no row: it is written and consumed inside a tick.
#
# RULES, all inherited from bin/lib/ledger-twin.sh (BH-1036): the file is
# written FIRST and the row second; the row is read only when the file is
# ABSENT, and hydration never overwrites a local file; a read that cannot be
# answered, or a malformed row, is a miss and never "already consumed"; a write
# that cannot be made is rc 0. It ships dark behind the `no-twin-ledgers` flag:
# with the flag down every function here makes no request and changes nothing.

# No HARNESS/H = no root = only the sibling copy is tried (BH-2650).
_TGL_R="${HARNESS:-${H:-}}"
for _TGL_P in "$(dirname "${BASH_SOURCE[0]}")/ledger-twin.sh" ${_TGL_R:+"$_TGL_R/bin/lib/ledger-twin.sh"}; do
  # shellcheck source=/dev/null
  [ -r "$_TGL_P" ] && { . "$_TGL_P"; break; }
done
unset _TGL_P _TGL_R

# _tgl_ready <harness> — rc 0 when the adapter is loaded. A caller that runs
# before it sourced bin/jobs-client.sh (bin/triage-shard.sh's key-lock-held
# re-arm) gets the client here, but only when the flag file says the twin is on,
# so a dark fleet sources nothing new.
_tgl_ready() {
  declare -F lt_read >/dev/null 2>&1 || return 1
  if ! declare -F job_ledger_get >/dev/null 2>&1 && [ -f "${1:-}/flags/no-twin-ledgers" ] \
     && [ -r "${1:-}/bin/jobs-client.sh" ]; then
    # shellcheck source=/dev/null
    . "$1/bin/jobs-client.sh" 2>/dev/null
  fi
  return 0
}

# tgl_put_gate <harness> <project> — mirror gate.json's sha + gate-meta. rc 0 always.
tgl_put_gate() {
  local h="${1:-}" p="${2:-}" g sha ep
  [ -n "$h" ] && [ -n "$p" ] && _tgl_ready "$h" || return 0
  g="$h/state/$p.gate.json"
  [ -s "$g" ] || return 0
  sha=$(sha256sum < "$g" | cut -d' ' -f1)
  ep=$(cat "$h/state/$p.gate-meta" 2>/dev/null)
  case "$ep" in ''|*[!0-9]*) ep=0 ;; esac
  lt_put triage_gate "$p" "$sha $ep"
  return 0
}

# tgl_read_gate <harness> <project> — rc 0 only on a well-formed row; sets
# TGL_SHA and TGL_EPOCH. Miss, outage, flag off or a malformed row: rc 1.
TGL_SHA=""; TGL_EPOCH=""
tgl_read_gate() {
  local p="${2:-}"
  TGL_SHA=""; TGL_EPOCH=""
  [ -n "${1:-}" ] && [ -n "$p" ] && _tgl_ready "$1" || return 1
  lt_read triage_gate "$p" || return 1
  [[ "$LT_VAL" =~ ^([0-9a-f]{64})\ ([0-9]+)$ ]] || return 1
  TGL_SHA="${BASH_REMATCH[1]}"; TGL_EPOCH="${BASH_REMATCH[2]}"
  return 0
}

# tgl_hydrate_meta <harness> <project> — write gate-meta from the row, only
# when the file is absent. An epoch of 0 (the row of a gate that was seeded
# without a clock) is not written: absent already means 0.
tgl_hydrate_meta() {
  local h="${1:-}" p="${2:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 1
  [ -e "$h/state/$p.gate-meta" ] && return 1
  tgl_read_gate "$h" "$p" || return 1
  [ "$TGL_EPOCH" -gt 0 ] 2>/dev/null || return 1
  printf '%s\n' "$TGL_EPOCH" > "$h/state/$p.gate-meta"
}

# tgl_hydrate_gate <harness> <project> <live fingerprint> [sha] — only when
# gate.json is absent or empty: rc 0 and gate.json written when the live
# fingerprint hashes to the row's sha; rc 1 (nothing written) on any other
# answer. A caller that already ran tgl_read_gate passes TGL_SHA as the 4th
# argument, so the tick makes one ledger read and not two.
tgl_hydrate_gate() {
  local h="${1:-}" p="${2:-}" fp="${3:-}" want="${4:-}"
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$fp" ] || return 1
  [ -s "$h/state/$p.gate.json" ] && return 1
  if [ -z "$want" ]; then tgl_read_gate "$h" "$p" || return 1; want="$TGL_SHA"; fi
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$(printf '%s' "$fp" | sha256sum | cut -d' ' -f1)" = "$want" ] || return 1
  printf '%s' "$fp" > "$h/state/$p.gate.json"
}

# tgl_put_fail <harness> <project> — mirror gate.fail as "<sha16> <n>". rc 0 always.
tgl_put_fail() {
  local h="${1:-}" p="${2:-}" f sha n
  [ -n "$h" ] && [ -n "$p" ] && _tgl_ready "$h" || return 0
  f="$h/state/$p.gate.fail"
  [ -f "$f" ] || return 0
  sha=$(head -1 "$f"); n=$(sed -n 2p "$f")
  [[ "$sha" =~ ^([0-9a-f]{16}|none)$ ]] && [[ "$n" =~ ^[0-9]+$ ]] || return 0
  lt_put triage_gate "$p fail" "$sha $n"
  return 0
}

# tgl_clear_fail <harness> <project> — the streak ended (success, or consumed at the cap).
tgl_clear_fail() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && _tgl_ready "$1" || return 0
  lt_put triage_gate "$2 fail" cleared
  return 0
}

# tgl_hydrate_fail <harness> <project> — write gate.fail from the row, only when
# the file is absent. `cleared`, a miss, an outage or a malformed row write nothing.
tgl_hydrate_fail() {
  local h="${1:-}" p="${2:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 1
  [ -e "$h/state/$p.gate.fail" ] && return 1
  _tgl_ready "$h" || return 1
  lt_read triage_gate "$p fail" || return 1
  [[ "$LT_VAL" =~ ^([0-9a-f]{16}|none)\ ([0-9]+)$ ]] || return 1
  printf '%s\n%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" > "$h/state/$p.gate.fail"
}
