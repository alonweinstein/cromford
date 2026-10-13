#!/bin/bash
# bin/pause.sh — set, renew, end and list BH-1672 pauses from a shell.
#
# WHY IT EXISTS. A pause is a row in the jobs worker's `pauses` table with a
# reason, an actor and an expiry (bin/lib/pause.sh has the wire contract). This
# is the operator's way to write one without hand-crafting curl: every verb is
# one request through _jobs_req, and the worker's answer is printed or the
# error goes to stderr. It never writes local state; the box cache is
# pause_refresh's job.
#
# usage:
#   bin/pause.sh set   <fleet|project> <what> --reason R [--ttl D] [--actor A]
#   bin/pause.sh renew <fleet|project> <what> --reason R [--ttl D] [--actor A]
#   bin/pause.sh end   <id>
#   bin/pause.sh list  [--active]
# what is reviews|merges|builds|triage. --ttl is <n>[s|m|h|d] (bare n = seconds);
# without it the worker applies the pause_default_ttl_s setting. The actor
# defaults to $(hostname). renew is set: the worker renews the live row for
# (scope, what) if there is one. list prints id scope what expires_at ended_at
# actor reason, tab-separated; plain list asks for every row (?active=0).
#
# Exit: 0 ok, 1 the worker refused or did not answer (http + body on stderr),
# 2 bad usage or no jobs client.
set -uo pipefail
H="${HARNESS:-/root/harness}"

usage() { sed -n '/^# usage:/,/^# Exit:/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "pause: $*" >&2; exit 2; }
fail() { echo "pause: $1 failed http=${JOBS_HTTP:-none} ${JOBS_BODY:0:200}" >&2; exit 1; }
# req <verb> <method> <path> [body] — _jobs_req in THIS shell, not in $(...), so
# JOBS_HTTP / JOBS_BODY survive for the error line. The answer lands in $out.
req() {
  local v="$1" tmp; shift
  tmp=$(mktemp "${TMPDIR:-/tmp}/pause-cli.XXXXXX") || die "mktemp failed"
  _jobs_req "$@" > "$tmp"; local rc=$?
  out=$(cat "$tmp"); rm -f "$tmp"
  [ "$rc" = 0 ] || fail "$v"
}

verb="${1:-}"; [ -n "$verb" ] || usage; shift
case "$verb" in set|renew|end|list) ;; -h|--help|help) usage ;; *) echo "pause: unknown verb '$verb'" >&2; usage ;; esac

client="${PAUSE_JOBS_CLIENT:-$H/bin/jobs-client.sh}"
[ -r "$client" ] || die "jobs client $client is not readable — nothing to talk to"
# shellcheck source=/dev/null
. "$client" 2>/dev/null
declare -F _jobs_req >/dev/null || die "jobs client $client did not define _jobs_req"

case "$verb" in
  set|renew)
    scope=""; what=""; reason=""; have_reason=0; ttl=""; actor="$(hostname 2>/dev/null)"
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason) [ $# -ge 2 ] || die "--reason needs a value"; reason="$2"; have_reason=1; shift 2 ;;
        --ttl)    [ $# -ge 2 ] || die "--ttl needs a value"; ttl="$2"; [ -n "$ttl" ] || die "--ttl is empty"; shift 2 ;;
        --actor)  [ $# -ge 2 ] || die "--actor needs a value"; actor="$2"; shift 2 ;;
        --*) die "unknown flag $1" ;;
        *) if [ -z "$scope" ]; then scope="$1"; elif [ -z "$what" ]; then what="$1"; else die "unexpected argument $1"; fi; shift ;;
      esac
    done
    [ -n "$scope" ] && [ -n "$what" ] || die "$verb needs <fleet|project> <what>"
    [ "$have_reason" = 1 ] && [ -n "$reason" ] || die "--reason required"
    [ -n "$actor" ] || die "--actor is empty and hostname gave nothing"
    ttl_s=""
    if [ -n "$ttl" ]; then
      [[ "$ttl" =~ ^([0-9]+)([smhd]?)$ ]] || die "--ttl '$ttl' is not <n>[s|m|h|d]"
      n=$((10#${BASH_REMATCH[1]}))
      case "${BASH_REMATCH[2]}" in m) n=$((n*60)) ;; h) n=$((n*3600)) ;; d) n=$((n*86400)) ;; esac
      [ "$n" -gt 0 ] || die "--ttl must be greater than zero"
      ttl_s="$n"
    fi
    body=$(jq -nc --arg s "$scope" --arg w "$what" --arg r "$reason" --arg a "$actor" --arg t "$ttl_s" \
      '{scope:$s, what:$w, reason:$r, actor:$a} + (if $t == "" then {} else {ttl_s:($t|tonumber)} end)')
    req "$verb" PUT /api/pauses "$body"
    printf '%s' "$out" | jq -r '(.pause // .) | "\(.id) \(.scope) \(.what) until \(.expires_at)"' ;;
  end)
    [ $# -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]] || die "end needs one numeric <id>"
    req end POST "/api/pauses/$1/end"
    printf '%s' "$out" | jq -r --arg id "$1" '(.pause // .) | "\(.id // $id) ended \(.ended_at // "")"' 2>/dev/null || echo "$1 ended" ;;
  list)
    q=0
    case "${1:-}" in "") ;; --active) q=1 ;; *) die "unknown list argument $1" ;; esac
    req list GET "/api/pauses?active=$q"
    printf '%s' "$out" | jq -e '.pauses | type == "array"' >/dev/null 2>&1 || { JOBS_BODY="$out"; fail list; }
    printf '%s' "$out" | jq -r '.pauses[] | [.id, .scope, .what, .expires_at, .ended_at, .actor, (.reason // "" | gsub("[\t\r\n]+"; " "))]
      | map(if . == null then "" else tostring end) | @tsv'
    printf '%s' "$out" | jq -e '.truncated == true' >/dev/null 2>&1 && echo "(truncated at 500)" >&2
    ;;
esac
exit 0
