# shellcheck shell=bash
# bin/lib/served-sha-watch.d/20-autodeploy.sh — the opt-in auto-deploy hook of
# bin/served-sha-watch.sh (BH-4938, child 3 of #4916). Sourced by the driver,
# never executed; defines ssw_hook_autodeploy and runs nothing.
#
# WHY. project-3 #467 merged as 2b2272a4, Vercel never created a deployment for
# it, and prod served a ~5h old build. The fix a human made was one click on
# "Redeploy" for main HEAD; this hook makes that click, once.
#
# WHEN IT ACTS. Called per project as
#   ssw_hook_autodeploy <project> <verdict> <head> <served> <dep_state> <age_s> <state_file>
# It REQUESTS a production deployment of main's full 40-hex HEAD only when
# SSW_AUTODEPLOY is 1 (the driver passes 1 only for SERVED_SHA_AUTODEPLOY=1),
# the verdict is alert, dep_state is exactly none, the state file is readable,
# it holds no ledger entry for this sha, and the repo, project id, team and
# served deployment name are all known. On a later alert/wait tick it pages
# once (critical, id served-autodeploy:<project>:<sha12>) when prod still does
# not serve the sha SSW_LAG_S after the request; on in-sync it logs the
# confirmation and resolves that page if one was sent. Following up and
# confirming run whatever the knob says, so a page opened before the knob was
# turned off still closes.
#
# LEDGER. `.deploy {sha, at, rc, id?, alerted?}` in the driver's state file.
# It is written as rc "pending" BEFORE the POST (no write, no POST), then as
# requested (2xx with an id), requested-empty (2xx, no id) or failed:<http>
# (000 = no answer). Any entry for the sha blocks another POST for it, whatever
# its rc: a pending or failed request may still have reached Vercel.
#
# NEVER. A branch, a short sha, a guessed name/org/repo, a second POST for a
# sha, a token in argv, a log or an alert. The token rides curl's -K config on
# stdin, as in ssw_vapi.

_ssw_ad_say() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$root/logs/served-sha-watch.log" 2>/dev/null
}

# _ssw_ad_post <path> <json> — ssw_vapi's POST plus Content-Type: application/json,
# which the deployments API needs and ssw_vapi cannot send. Same answer shape:
# the body, then the HTTP code on the last line (000 = transport).
_ssw_ad_post() {
  local p="${1:-}" to="${SERVED_SHA_HTTP_TIMEOUT:-20}" out code body=""
  case "$to" in ''|*[!0-9]*|0) to=20 ;; esac
  if [ -z "$p" ] || [ -z "${SSW_BASE:-}" ] || [ -z "${SSW_TOKEN:-}" ]; then printf '\n000\n'; return 1; fi
  out=$(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$SSW_TOKEN" \
        | curl -sS -X POST --max-time "$to" -w '\n%{http_code}' -K - --data-binary "${2:-}" "$SSW_BASE$p" 2>/dev/null)
  code="${out##*$'\n'}"
  case "$out" in *$'\n'*) body="${out%$'\n'*}" ;; esac
  case "$code" in [0-9][0-9][0-9]) ;; *) code=000 ;; esac
  printf '%s\n%s\n' "$body" "$code"
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}

ssw_hook_autodeploy() {
  local p="${1:-}" v="${2:-}" head="${3:-}" served="${4:-}" dep="${5:-}" sf="${7:-}"
  local root="${HARNESS:-${H:-}}" now="${SSW_NOW:-}" lag="${SSW_LAG_S:-}"
  local head8 aid st d at msg org repo body r code did rc js
  [ -n "$root" ] || return 1
  [[ $head =~ ^[0-9a-f]{40}$ ]] || return 0
  head8=${head:0:8}; aid="served-autodeploy:$p:${head:0:12}"
  case "$v" in in-sync|wait|alert) ;; *) return 0 ;; esac
  case "$now" in ''|*[!0-9]*) return 0 ;; esac

  if ! st=$(ssw_state_read "$sf") \
     || ! d=$(jq -c --arg h "$head" 'if (.deploy.sha? // "") == $h then .deploy else empty end' <<< "$st" 2>/dev/null); then
    [ "${SSW_AUTODEPLOY:-0}" = 1 ] && _ssw_ad_say "$p: state file unreadable, auto-deploy skipped (fail closed)"
    return 0
  fi

  # Confirm: prod serves the sha we asked for.
  if [ "$v" = in-sync ] && [ -n "$d" ]; then
    msg="$p: auto-deploy of $head8 confirmed: prod serves it"
    _ssw_ad_say "$msg"
    [ "$(jq -r '.alerted // false' <<< "$d")" = true ] \
      && "$root/bin/lane-alert.sh" --resolve --id "$aid" served-sha-watch "$msg" >/dev/null 2>&1
    return 0
  fi

  # Follow up: requested SSW_LAG_S ago and prod still behind. Page once.
  if [ -n "$d" ] && [ "$(jq -r '.alerted // false' <<< "$d")" != true ]; then
    at=$(jq -r '.at // empty' <<< "$d"); rc=$(jq -r '.rc // empty' <<< "$d")
    case "$rc" in failed:*) ;; *)
      if [[ $at =~ ^[0-9]+$ ]] && [[ $lag =~ ^[0-9]+$ ]] && [ $((now - at)) -ge "$lag" ]; then
        "$root/bin/lane-alert.sh" --severity critical --id "$aid" served-sha-watch \
          "$p: auto-deploy of $head8 requested $(((now - at) / 60))m ago, prod still serves ${served:0:8}" >/dev/null 2>&1
        st=$(ssw_state_read "$sf") || st='{}'
        ssw_state_write "$sf" "$(jq -c --argjson d "$d" '.deploy = ($d + {alerted:true})' <<< "$st")" \
          || _ssw_ad_say "$p: auto-deploy alert sent, state write failed"
        return 0
      fi ;;
    esac
  fi

  # Request: every condition checked, in order.
  [ "${SSW_AUTODEPLOY:-0}" = 1 ] || return 0
  [ "$v" = alert ] || return 0
  [ "$dep" = none ] || return 0  # ssw-ad: dep-none
  [ -z "$d" ] || return 0
  if ! [[ ${SSW_SLUG:-} =~ ^[^/]+/[^/]+$ ]]; then _ssw_ad_say "$p: auto-deploy skipped (repo unknown)"; return 0; fi
  [ -n "${SSW_VNAME:-}" ] || { _ssw_ad_say "$p: auto-deploy skipped (name unknown)"; return 0; }
  [ -n "${SSW_PID:-}" ] || { _ssw_ad_say "$p: auto-deploy skipped (project id unknown)"; return 0; }
  [ -n "${SSW_TEAM:-}" ] || { _ssw_ad_say "$p: auto-deploy skipped (team unknown)"; return 0; }
  org=${SSW_SLUG%%/*}; repo=${SSW_SLUG#*/}

  js=$(jq -c --arg h "$head" --argjson now "$now" '.deploy = {sha:$h, at:$now, rc:"pending"}' <<< "$st")
  ssw_state_write "$sf" "$js" || { _ssw_ad_say "$p: auto-deploy ledger write failed, no request sent"; return 0; }  # ssw-ad: ledger
  body=$(jq -nc --arg n "$SSW_VNAME" --arg pid "$SSW_PID" --arg o "$org" --arg r "$repo" --arg h "$head" \
    '{name:$n, project:$pid, target:"production", gitSource:{type:"github", org:$o, repo:$r, ref:"main", sha:$h}}')
  r=$(_ssw_ad_post "/v13/deployments?teamId=$SSW_TEAM" "$body")  # ssw-ad: post
  code=$(_ssw_code "$r")
  did=$(_ssw_body "$r" | jq -r '.id // empty' 2>/dev/null) || did=""
  d=$(jq -nc --arg h "$head" --argjson now "$now" '{sha:$h, at:$now}')
  case "$code" in
    2??) if [ -n "$did" ]; then rc=requested; d=$(jq -c --arg i "$did" '. + {rc:"requested", id:$i}' <<< "$d")
         else rc=requested-empty; d=$(jq -c '. + {rc:"requested-empty"}' <<< "$d"); fi ;;
    *) rc="failed:$code"
       "$root/bin/lane-alert.sh" --severity critical --id "$aid" served-sha-watch \
         "$p: auto-deploy request failed (HTTP $code) for $head8" >/dev/null 2>&1
       d=$(jq -c --arg rc "$rc" '. + {rc:$rc, alerted:true}' <<< "$d") ;;
  esac
  st=$(ssw_state_read "$sf") || st="$js"
  ssw_state_write "$sf" "$(jq -c --argjson d "$d" '.deploy = $d' <<< "$st")" \
    || _ssw_ad_say "$p: auto-deploy outcome write failed, ledger stays pending"
  _ssw_ad_say "$p: auto-deploy of $head8 $rc"
  return 0
}
