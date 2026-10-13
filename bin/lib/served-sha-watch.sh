#!/bin/bash
# bin/lib/served-sha-watch.sh — the reads and the judge behind
# bin/served-sha-watch.sh (BH-4936, the tracer of #4916). Sourced, never
# executed; defines functions, runs nothing, no `set -e`.
#
#   ssw_vercel_token              print the hub's Vercel CLI token; rc 1 when none.
#                                 SERVED_SHA_VERCEL_AUTH, when set, is the ONLY
#                                 file tried; unset tries the CLI's two auth files.
#   ssw_vapi <m> <path> [body]    one Vercel API call against $SSW_BASE with the
#                                 Bearer $SSW_TOKEN. Prints the body, then the
#                                 HTTP code on the last line (000 = transport);
#                                 rc 0 only on 2xx. The header rides curl's -K
#                                 config on stdin, so the token is never in argv.
#   ssw_head <slug>               `<sha> <epoch>` of main HEAD (epoch empty when
#                                 the committer date is missing); rc = gh_rest's.
#   ssw_served <team> <domain>    `<sha> <deployment name>` the domain serves;
#                                 rc 1 with the reason printed instead
#                                 (alias:<code>, deployment:<code>, served:no-git-sha).
#   ssw_dep_state <team> <pid> <head>   building|ready|failed|none|unread for the
#                                 production deployments of <head>.
#   ssw_is_sha <s> / ssw_same_sha <a> <b>   8-40 lowercase hex / one is a prefix
#                                 of the other at the shorter length.
#   ssw_judge now head_ts lag_s head served compare_status dep_state
#                                 pure; prints in-sync|wait|alert|unreadable.
#   ssw_state_read <file>         the JSON object, {} when absent; rc 2 corrupt.
#   ssw_state_write <file> <json> tmp + mv; non-zero on any failure.

ssw_vercel_token() {
  local f t
  local -a files=(/root/.local/share/com.vercel.cli/auth.json /root/.vercel/auth.json)
  [ -n "${SERVED_SHA_VERCEL_AUTH:-}" ] && files=("$SERVED_SHA_VERCEL_AUTH")
  for f in "${files[@]}"; do
    [ -r "$f" ] && [ -s "$f" ] || continue
    t=$(jq -r '.token // empty' "$f" 2>/dev/null) || t=""
    [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}

ssw_vapi() {
  local m="${1:-}" p="${2:-}" to="${SERVED_SHA_HTTP_TIMEOUT:-20}" out code body=""
  local -a args
  case "$to" in ''|*[!0-9]*|0) to=20 ;; esac
  if [ -z "$m" ] || [ -z "$p" ] || [ -z "${SSW_BASE:-}" ] || [ -z "${SSW_TOKEN:-}" ]; then
    printf '\n000\n'; return 1
  fi
  args=(-sS -X "$m" --max-time "$to" -w '\n%{http_code}' -K -)
  [ $# -ge 3 ] && args+=(--data-binary "$3")
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$SSW_TOKEN" | curl "${args[@]}" "$SSW_BASE$p" 2>/dev/null)
  code="${out##*$'\n'}"
  case "$out" in *$'\n'*) body="${out%$'\n'*}" ;; esac
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
  printf '%s\n%s\n' "$body" "$code"
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}

# Split ssw_vapi's answer: _ssw_code / _ssw_body <answer>.
_ssw_code() { printf '%s' "${1##*$'\n'}"; }
_ssw_body() { case "$1" in *$'\n'*) printf '%s' "${1%$'\n'*}" ;; esac; }

ssw_head() {
  local slug="${1:-}" t rc=0 sha d ep=""
  t=$(mktemp "${TMPDIR:-/tmp}/ssw-head.XXXXXX") || return 75
  gh_rest GET "repos/$slug/commits/main" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; return "$rc"; fi
  sha=$(jq -r '.sha // empty' "$t" 2>/dev/null)
  d=$(jq -r '.commit.committer.date // empty' "$t" 2>/dev/null)
  rm -f "$t"
  [ -n "$sha" ] || return 75
  [ -n "$d" ] && { ep=$(date -u -d "$d" +%s 2>/dev/null) || ep=""; }
  printf '%s %s\n' "$sha" "$ep"
}

ssw_served() {
  local team="${1:-}" domain="${2:-}" r id sha name
  r=$(ssw_vapi GET "/v4/aliases/$domain?teamId=$team") || { echo "alias:$(_ssw_code "$r")"; return 1; }
  id=$(_ssw_body "$r" | jq -r '.deploymentId // .deployment.id // empty' 2>/dev/null)
  [ -n "$id" ] || { echo "alias:no-deployment"; return 1; }
  r=$(ssw_vapi GET "/v13/deployments/$id?teamId=$team") || { echo "deployment:$(_ssw_code "$r")"; return 1; }
  sha=$(_ssw_body "$r" | jq -r '.gitSource.sha // .meta.githubCommitSha // empty' 2>/dev/null)
  name=$(_ssw_body "$r" | jq -r '.name // empty' 2>/dev/null)
  [ -n "$sha" ] || { echo "served:no-git-sha"; return 1; }
  printf '%s %s\n' "$sha" "$name"
}

ssw_dep_state() {
  local team="${1:-}" pid="${2:-}" head="${3:-}" r s
  r=$(ssw_vapi GET "/v6/deployments?projectId=$pid&teamId=$team&target=production&limit=20") \
    || { echo unread; return 0; }
  s=$(_ssw_body "$r" | jq -er --arg h "$head" '
    if (.deployments | type) != "array" then error("no list") else . end
    | [ .deployments[]
        | ((.meta.githubCommitSha // .gitSource.sha // "") | ascii_downcase) as $s
        | select(($s | length) >= 8 and ($h | startswith($s) or ($s | startswith($h))))
        | (.state // .readyState // "") ] as $st
    | if any($st[]; . == "BUILDING" or . == "QUEUED" or . == "INITIALIZING") then "building"
      elif any($st[]; . == "READY") then "ready"
      elif any($st[]; . == "ERROR") then "failed"
      else "none" end' 2>/dev/null) || s=unread
  printf '%s\n' "${s:-unread}"
}

ssw_is_sha() { [[ "${1:-}" =~ ^[0-9a-f]{8,40}$ ]]; }

ssw_same_sha() {
  local a="${1:-}" b="${2:-}" n
  ssw_is_sha "$a" && ssw_is_sha "$b" || return 1
  n=${#a}; [ "${#b}" -lt "$n" ] && n=${#b}
  [ "${a:0:n}" = "${b:0:n}" ]
}

ssw_judge() {
  local now="${1:-}" ts="${2:-}" lag="${3:-}" head="${4:-}" served="${5:-}" cmp="${6:-}" dep="${7:-}"
  case "$now$lag" in ''|*[!0-9]*) echo unreadable; return 0 ;; esac
  if ! ssw_is_sha "$head" || ! ssw_is_sha "$served"; then echo unreadable; return 0; fi
  if ssw_same_sha "$head" "$served"; then echo in-sync; return 0; fi
  case "$cmp" in
    identical|behind) echo in-sync; return 0 ;;
    '') echo unreadable; return 0 ;;
  esac
  [ "$dep" = failed ] && { echo alert; return 0; }  # ssw-judge: failed
  case "$ts" in ''|*[!0-9]*) echo wait; return 0 ;; esac
  if [ "$((now - ts))" -ge "$lag" ]; then echo alert; else echo wait; fi
}

ssw_state_read() {
  local f="${1:-}" j
  [ -n "$f" ] || return 2
  [ -e "$f" ] || { echo '{}'; return 0; }
  j=$(jq -ce 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null) || return 2
  printf '%s\n' "$j"
}

ssw_state_write() {
  local f="${1:-}" j="${2:-}" tmp
  [ -n "$f" ] || return 1
  printf '%s' "$j" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  tmp="$f.tmp.$$"
  printf '%s\n' "$j" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -fT "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
}
