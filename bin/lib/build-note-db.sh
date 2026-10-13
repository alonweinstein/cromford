#!/bin/bash
# shellcheck shell=bash
# bin/lib/build-note-db.sh — BH-5003: a build note as a ledger row, so a build
# on ANY box sees it. Sourced, never run.
#
# A BUILD NOTE is what bin/blocked-resolver.sh carries to the NEXT build of a
# ticket: an adjudicated test-tamper ruling, or the failing-CI evidence of an
# automatic narrower re-plan (KIND: ci-replan, bin/lib/br/opt/cirepair.sh).
# Until BH-5003 it was only the hub file state/build-notes/<p>/<KEY>.md, read by
# a hub build and relayed by bin/fly-pool.sh to a pool machine. A build on a
# watcher box (not hub, not pool) never saw it, so an accepted TEST-CHANGE
# blocked again. The note is now ALSO the ledger row
#   kind build_note, key "<project> <KEY>", status pending -> consumed|relayed
# and the hub file stays exactly as before, as the row's mirror.
#
#   bn_put <p> <KEY> <file>          the row, `pending`, detail = the first 4000
#                                    bytes of <file> (the route cuts at 4000;
#                                    the plan stage reads 1500 and KIND: is
#                                    line 1)
#   bn_take <p> <KEY> <out>          read the row; only a `pending` one is
#                                    claimed (consumed) and only a won claim
#                                    writes its detail to <out>. Atomic across
#                                    boxes: the claim is the worker's one-
#                                    statement compare-and-set.
#   bn_mark <p> <KEY> consumed|relayed
#                                    mark a row that is STILL pending
#   bn_status <p> <KEY>              print the row's status
#   bn_used <p> <KEY> <file>         rc 0, printing consumed|relayed, only when
#                                    the row is used up AND describes THIS file
#                                    (its detail is the file's first 4000 bytes).
#                                    The row outlives its note: a second note for
#                                    the same key whose bn_put did not land (an
#                                    outage, or BUILD_NOTE_DB=0 at write time)
#                                    finds the FIRST note's terminal row, and that
#                                    row says nothing about this file. Any
#                                    mismatch is rc 1, so the caller keeps the
#                                    file behaviour (relay, consume, count).
#
# FAIL-OPEN, every function. No jobs client, BUILD_NOTE_DB=0, a row that is not
# there, a claim route that is not deployed yet (404) and an outage all return
# non-zero and change nothing; every caller then does exactly what it did
# before this lib existed (the hub file, the relay). A claim never creates a
# row: bn_take and bn_mark read first and only claim a `pending` one, because
# the claim route inserts an absent key.
#
# THE KNOB. BUILD_NOTE_DB (registry: catalog/lanes.d/_lib.build-note-db.json,
# default 1), read through lane-gate's lib_env_apply the way
# bin/lib/file-claims.sh reads its ttl. 0 = main's behaviour: no row is
# written, read or marked.
#
# The harness root is ${HARNESS:-${H:-}} and nothing else (BH-2613): with no
# root the knob falls to env then its default, and no path is built.

bn__on() {
  local v="" lib
  command -v job_ledger_row >/dev/null 2>&1 && command -v job_ledger_put >/dev/null 2>&1 \
    && command -v job_ledger_claim >/dev/null 2>&1 || return 1
  lib=$(dirname "${BASH_SOURCE[0]}")
  if [ -n "${HARNESS:-${H:-}}" ]; then
    v=$(
      command -v lib_env_apply >/dev/null 2>&1 || . "$lib/lane-gate.sh" >/dev/null 2>&1
      lib_env_apply build-note-db >/dev/null 2>&1
      printf '%s' "${BUILD_NOTE_DB:-}"
    ) 2>/dev/null
  fi
  [[ "$v" =~ ^[01]$ ]] || v=${BUILD_NOTE_DB:-}
  [[ "$v" =~ ^[01]$ ]] || v=1
  [ "$v" = 1 ]
}

# bn__key <p> <KEY> -> the ledger key; rc 1 on an empty or "-" part.
bn__key() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$2" != "-" ] || return 1
  printf '%s %s' "$1" "$2"
}

bn_put() {
  local k f="${3:-}" d
  k=$(bn__key "${1:-}" "${2:-}") || return 1
  [ -s "$f" ] || return 1
  bn__on || return 1
  d=$(head -c 4000 "$f" 2>/dev/null)
  [ -n "$d" ] || return 1
  job_ledger_put build_note "$k" pending "$d" >/dev/null 2>&1
}

bn_status() {
  local k
  k=$(bn__key "${1:-}" "${2:-}") || return 1
  bn__on || return 1
  job_ledger_get build_note "$k" 2>/dev/null
}

bn_used() {
  local k f="${3:-}" row st det
  k=$(bn__key "${1:-}" "${2:-}") || return 1
  [ -s "$f" ] || return 1
  bn__on || return 1
  row=$(job_ledger_row build_note "$k" 2>/dev/null) || return 1
  st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
  case "$st" in consumed|relayed) ;; *) return 1 ;; esac
  det=$(printf '%s' "$row" | jq -r '.detail // ""' 2>/dev/null)
  [ -n "$det" ] && [ "$det" = "$(head -c 4000 "$f" 2>/dev/null)" ] || return 1
  printf '%s' "$st"
}

bn_take() {
  local k out="${3:-}" row st det
  k=$(bn__key "${1:-}" "${2:-}") || return 1
  [ -n "$out" ] || return 1
  bn__on || return 1
  row=$(job_ledger_row build_note "$k" 2>/dev/null) || return 1
  st=$(printf '%s' "$row" | jq -r '.status // ""' 2>/dev/null)
  [ "$st" = pending ] || return 1
  det=$(printf '%s' "$row" | jq -r '.detail // ""' 2>/dev/null)
  [ -n "$det" ] || return 1
  job_ledger_claim build_note "$k" consumed 30 consumed,relayed >/dev/null 2>&1 || return 1
  printf '%s\n' "$det" > "$out"
}

bn_mark() {
  local k to="${3:-}"
  k=$(bn__key "${1:-}" "${2:-}") || return 1
  case "$to" in consumed|relayed) ;; *) return 1 ;; esac
  bn__on || return 1
  [ "$(job_ledger_get build_note "$k" 2>/dev/null)" = pending ] || return 1
  job_ledger_claim build_note "$k" "$to" 30 consumed,relayed >/dev/null 2>&1
}
