#!/bin/bash
# bin/lib/context-pack.sh — the shell side of the context-pack wire (BH-3478).
# Sourced, never run. A split child gets its parent planner's codebase map as a
# "context pack" so the child's plan starts warm instead of re-surveying.
#
#   cp_put <project> <child> <parent> <base-sha> <pack-file>
#     POST /api/context-packs. rc 0 published (prints "published") /
#     3 refused (the worker answered 4xx: bad key, self-parent, empty, 413 over
#     64000 bytes; the pack is never sliced) / 1 unreachable, 5xx, no client,
#     or a caller bug (bad token, child == parent, empty pack file).
#   cp_fetch <project> <key> <dst-file>
#     GET /api/context-packs. rc 0 wrote <dst> (pack_md, exact bytes) and
#     <dst>.parent (parent_key) / 2 no row, or a row whose parent_key is the
#     key itself / 1 outage or an answer that is not a context pack. <dst> and
#     <dst>.parent are written only on rc 0.
#   cp_preamble <pack-file>
#     Prints the WARM START instruction naming <pack-file>.parent, a blank line
#     and the pack. rc 1 and prints nothing with no pack or no parent.
#
# Fail-open: nothing here exits or alerts. Root is ${HARNESS:-${H:-}} only (D43);
# empty root and no client beside this file means rc 1.

_CP_ROOT="${HARNESS:-${H:-}}"
_CP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Same loader as _mr_ensure_client (bin/lib/model-route.sh): jobs-client.sh
# turns on nounset/pipefail and exits when its modules are missing, so it is
# loaded on first use, only when present, and the caller's options put back.
_cp_ensure_client() {
  local c pf nu
  command -v _jobs_req >/dev/null 2>&1 && return 0
  for c in "${_CP_SELF_DIR:+$_CP_SELF_DIR/../jobs-client.sh}" "${_CP_ROOT:+$_CP_ROOT/bin/jobs-client.sh}"; do
    [ -n "$c" ] && [ -r "$c" ] && [ -r "$(dirname "$c")/lib/jobs/req.sh" ] || continue
    pf=$(set -o | awk '$1=="pipefail"{print $2}')
    nu=$(set -o | awk '$1=="nounset"{print $2}')
    # shellcheck source=/dev/null
    . "$c" >/dev/null 2>&1
    [ "$pf" = off ] && set +o pipefail
    [ "$nu" = off ] && set +u
    command -v _jobs_req >/dev/null 2>&1 && return 0
  done
  return 1
}

_cp_tok_ok() { case "$1" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

cp_put() {
  local p="${1:-}" k="${2:-}" pk="${3:-}" sha="${4:-}" f="${5:-}" body rc
  _cp_tok_ok "$p" && _cp_tok_ok "$k" && _cp_tok_ok "$pk" && [ "$k" != "$pk" ] \
    && [ -n "$f" ] && [ -s "$f" ] || return 1
  _cp_ensure_client || return 1
  body=$(jq -n --arg p "$p" --arg k "$k" --arg pk "$pk" --arg sha "$sha" \
    --arg b "${JOBS_BOX:-}" --rawfile pack "$f" \
    '{project:$p,ticket_key:$k,parent_key:$pk,pack_md:$pack}
     + (if $sha=="" then {} else {base_sha:$sha} end)
     + (if $b=="" then {} else {box:$b} end)') || return 1
  JOBS_HTTP=
  _jobs_req POST /api/context-packs "$body" >/dev/null; rc=$?
  [ "$rc" = 0 ] && { echo published; return 0; }
  case "${JOBS_HTTP:-}" in 4*) return 3 ;; *) return 1 ;; esac
}

cp_fetch() {
  local p="${1:-}" k="${2:-}" dst="${3:-}" resp rc parent
  _cp_tok_ok "$p" && _cp_tok_ok "$k" && [ -n "$dst" ] || return 1
  _cp_ensure_client || return 1
  resp=$(_jobs_req GET "/api/context-packs?project=$(jq -rn --arg v "$p" '$v|@uri')&key=$(jq -rn --arg v "$k" '$v|@uri')"); rc=$?
  [ "$rc" = 2 ] && return 2
  [ "$rc" = 0 ] || return 1
  parent=$(printf '%s' "$resp" | jq -er '.context_pack | select(type=="object")
    | select((.pack_md|type)=="string" and .pack_md!="" and (.parent_key|type)=="string" and .parent_key!="")
    | .parent_key' 2>/dev/null) && [ -n "$parent" ] || return 1
  [ "$parent" = "$k" ] && return 2
  if printf '%s' "$resp" | jq -j '.context_pack.pack_md' > "$dst.tmp.$$" 2>/dev/null \
     && printf '%s\n' "$parent" > "$dst.parent.tmp.$$" \
     && mv -f "$dst.tmp.$$" "$dst" && mv -f "$dst.parent.tmp.$$" "$dst.parent"; then
    return 0
  fi
  rm -f "$dst.tmp.$$" "$dst.parent.tmp.$$"
  return 1
}

cp_preamble() {
  local f="${1:-}" parent
  [ -n "$f" ] && [ -s "$f" ] || return 1
  parent=$(head -n1 "$f.parent" 2>/dev/null)
  [ -n "$parent" ] || return 1
  printf '%s\n\n' "WARM START: this ticket is a split child of $parent. The parent's planner already mapped the codebase; the context pack below is that map. Do NOT re-survey what the pack already covers — read only the code this slice needs that the pack lacks, then write the plan."
  cat "$f"
}
