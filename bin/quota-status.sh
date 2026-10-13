#!/bin/bash
# bin/quota-status.sh [--json | --clear-cooldown <vendor> <account>]
#   — the per-account quota table for THIS box.
#
# What each registered account (plus the implicit `default`) has left: 5-hour and
# weekly utilization, the per-model families the endpoint reports, poll status and
# age, and any cooldown. Plain text, phone-width, because the Telegram and console
# beats that will carry it later read a terminal-shaped answer (wiring them is not
# part of this wave).
#
# Numbers come from state/quota/<account>.json, written by bin/quota-poll.sh —
# this script never calls out and never reads a credential. ACCOUNT_LABEL is
# shown; a token or a key never is.
#
# Overage (`extra_usage`, BH-1456) gets its own line per account that has a
# reading: whether extra-usage billing is on, how much of the spend limit is
# gone, and whether it was limit-reached or disabled. Without it a `default` row
# reading WEEK 100% / STATE ok looks like a bug rather than an account that is
# working and billing overage.
#
# Cooldowns are keyed by VENDOR and account (state/quota/cooldown/<vendor>/<name>),
# so an account name every vendor shares — `default` — gets one line per vendor
# that is actually cooling, and a codex exhaustion is visible as a codex one.
#
#   --clear-cooldown <vendor> <account>
#       The one write this script makes: drop that cooldown so the next pick can
#       use the account again, say what it did, and log it. It clears this
#       box's file AND the fleet row (BH-2355), and appends `(fleet row
#       cleared)`, `(no fleet row)` or `(fleet not reachable)` to the line.
#       A clear that finds only the fleet row prints `cleared the fleet
#       cooldown for <vendor>/<account>` (BH-2464).
#       rc 0 when the file or the fleet row was there and is now gone, rc 1
#       when there was nothing to clear on either side (said so, and
#       nothing was logged — a log row for a clear that did not happen is a lie
#       an operator reads back later), rc 2 on an unknown vendor or an invalid
#       account name. It touches nothing else — not pins, not leases, not
#       state/model-cooldown-*, not cooldown/.legacy/.
set -uo pipefail

H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/account-pick.sh
if [ -r "$HERE/account-pick.sh" ]; then . "$HERE/account-pick.sh"
elif [ -r "$H/bin/account-pick.sh" ]; then . "$H/bin/account-pick.sh"
else echo "quota-status.sh: account-pick.sh not found beside $0 or in $H/bin" >&2; exit 2; fi
# Live Fly-pool leases per account (bin/lib/pool-account.sh, 2026-09-14): how
# many builder machines are spending this account RIGHT NOW, which the 10-minute
# meter cannot show and which is the number that explains why the picker moved
# on. Optional on purpose — a box without the lib (or without a pool) renders
# exactly the table it rendered before, with leases reported as 0.
# shellcheck source=bin/lib/pool-account.sh
if [ -r "$HERE/lib/pool-account.sh" ]; then . "$HERE/lib/pool-account.sh"
elif [ -r "$H/bin/lib/pool-account.sh" ]; then . "$H/bin/lib/pool-account.sh"
fi
leases_for() { # <account> -> live lease count, 0 when the lib is not present
  command -v pool_account_leases >/dev/null 2>&1 || { echo 0; return 0; }
  pool_account_leases "$1"
}

QUOTA_DIR="${QUOTA_DIR:-$H/state/quota}"
COOLDOWN_SECS="${ACCOUNT_COOLDOWN_SECS:-${MODEL_COOLDOWN_SECS:-21600}}"
# The vendors a cooldown can belong to: the picker's own list, sourced above.
# The literal is only the half-synced-box fallback — a box whose account-pick.sh
# is older than this file would otherwise die on an unbound variable under
# `set -u`, and a status table that refuses to render is worse than one built
# from a list that is one vendor stale.
ACCT_VENDORS="${ACCOUNT_VENDORS:-claude codex grok openrouter fireworks}"

usage() { echo "usage: quota-status.sh [--json | --clear-cooldown <vendor> <account>]" >&2; }

# The operator lever. Before this existed the only way to release an account was
# `rm` under state/, which the iron-law guard refuses at session level — so the
# thing an operator needed most was the thing nobody could type.
clear_cooldown() { # <vendor> <account> -> 0 cleared, 1 nothing to clear, 2 bad args
  local v="${1:-}" a="${2:-}" f at until_ stamped
  if ! _acct_vendor_vars "$v" >/dev/null 2>&1; then
    echo "quota-status.sh: unknown vendor '$v'" >&2; usage; return 2
  fi
  # The account name becomes a path under state/quota/, so it is validated as a
  # name and not merely trusted — same grammar accounts_load applies, plus the
  # implicit `default`.
  case "$a" in
    default) ;;
    ''|*[!a-z0-9._-]*|[!a-z0-9]*) echo "quota-status.sh: invalid account name '$a'" >&2; usage; return 2 ;;
  esac
  if [ "${#a}" -gt 40 ]; then echo "quota-status.sh: invalid account name '$a'" >&2; usage; return 2; fi
  account_cooldown_sweep_legacy
  f=$(account_cooldown_file "$v" "$a")
  # The FILE is the cooldown, so its presence is what decides — an expired or
  # unreadable stamp is still a file the picker has to walk past, and removing it
  # is exactly what an operator typed this for.
  # File first, then the fleet row (BH-2355). The suffix names what the fleet
  # said: a row removed, no row, or no answer. A box without the seam lib has
  # no fleet side at all and prints exactly what it printed before.
  local file_had=0 frc fleet=""
  if [ -e "$f" ]; then
    file_had=1
    at=$(cat "$f" 2>/dev/null); case "$at" in ''|*[!0-9]*) at="" ;; esac
    rm -f "$f" 2>/dev/null
  fi
  if command -v fcd_clear >/dev/null 2>&1; then
    frc=0; fcd_clear account "$v" "$a" || frc=$?
    case "$frc" in
      0) fleet=" (fleet row cleared)" ;;
      1) fleet=" (no fleet row)" ;;
      *) fleet=" (fleet not reachable)"; frc=2 ;;
    esac
  else
    frc=2
  fi
  if [ "$file_had" = 0 ] && [ "$frc" = 0 ]; then
    printf 'cleared the fleet cooldown for %s/%s\n' "$v" "$a"
  elif [ "$file_had" = 0 ]; then
    printf 'no cooldown for %s/%s%s\n' "$v" "$a" "$fleet"
    return 1
  elif [ -n "$at" ]; then
    stamped=$(date -u -d "@$at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
    until_=$(date -u -d "@$(( at + COOLDOWN_SECS ))" '+%H:%MZ' 2>/dev/null)
    printf 'cleared cooldown %s/%s (stamped %s, would have run to %s)%s\n' \
      "$v" "$a" "${stamped:-?}" "${until_:-?}" "$fleet"
  else
    printf 'cleared cooldown %s/%s (the stamp was unreadable)%s\n' "$v" "$a" "$fleet"
  fi
  _acct_log - - - "$a" "cooldown_cleared:$v"
  mkdir -p "$H/logs" 2>/dev/null
  printf '%s [quota-status] cooldown %s/%s cleared by operator\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$v" "$a" >> "$H/logs/failovers.log" 2>/dev/null
  return 0
}

JSON=0
case "${1:-}" in
  --json) JSON=1 ;;
  -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
  --clear-cooldown) clear_cooldown "${2:-}" "${3:-}"; exit $? ;;
  '') ;;
  *) usage; exit 2 ;;
esac

accounts_load
# `default` is listed first and always: it is the account every non-routed call
# on this box already uses, so a table without it describes the wrong box.
NAMES=(default)
for A in "${ACCOUNT_NAMES[@]+"${ACCOUNT_NAMES[@]}"}"; do NAMES+=("$A"); done

vshort() { case "$1" in claude) echo cl ;; codex) echo cx ;; grok) echo gk ;; openrouter) echo or ;; fireworks) echo fw ;; *) echo "??" ;; esac; }

age_human() { # <seconds> -> 12m / 3h / 4d
  local s="${1:-}"
  case "$s" in ''|*[!0-9]*) echo "?"; return ;; esac
  if   [ "$s" -lt 3600 ]  ; then echo "$(( s / 60 ))m"
  elif [ "$s" -lt 172800 ]; then echo "$(( s / 3600 ))h"
  else echo "$(( s / 86400 ))d"; fi
}

# EVERY vendor's cooldown for one account name, as {"<vendor>":"HH:MMZ"}. The
# row's own vendor is not enough: `default` is the name claude and codex both
# answer to, and on 2026-09-18 a cooling codex `default` had no row to appear on
# at all while it was taking claude routing down with it.
cooldowns_json() { # <account> -> a json object, "{}" when nothing is cooling
  local a="$1" v at now until_ obj='{}'
  now=$(date -u +%s)
  for v in $ACCT_VENDORS; do
    at=$(cat "$QUOTA_DIR/cooldown/$v/$a" 2>/dev/null)
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ $(( now - at )) -lt "$COOLDOWN_SECS" ] || continue
    until_=$(date -u -d "@$(( at + COOLDOWN_SECS ))" '+%H:%MZ' 2>/dev/null) || continue
    [ -n "$until_" ] || continue
    obj=$(printf '%s' "$obj" | jq -c --arg v "$v" --arg u "$until_" '. + {($v): $u}' 2>/dev/null) \
      || { printf '%s' '{}'; return 0; }
  done
  printf '%s' "$obj"
}

# One jq pass per account, merged with the registry facts the json does not hold.
row_json() { # <account>
  local a="$1" v f cools
  if [ "$a" = default ]; then v=claude; else v="${ACCT_VENDOR[$a]}"; fi
  f="$QUOTA_DIR/$a.json"
  cools=$(cooldowns_json "$a"); [ -n "$cools" ] || cools='{}'
  { cat "$f" 2>/dev/null; echo '{}'; } | jq -s --arg a "$a" --arg v "$v" \
      --arg label "$( [ "$a" = default ] && echo "" || printf '%s' "${ACCT_LABEL[$a]:-}" )" \
      --arg enabled "$( [ "$a" = default ] && echo 1 || printf '%s' "${ACCT_ENABLED[$a]:-1}" )" \
      --arg prio "$( [ "$a" = default ] && printf '%s' "${ACCOUNT_DEFAULT_PRIORITY}" || printf '%s' "${ACCT_PRIORITY[$a]:-50}" )" \
      --arg models "$( [ "$a" = default ] && echo "" || printf '%s' "${ACCT_MODELS[$a]:-}" )" \
      --argjson cools "$cools" --arg leases "$(leases_for "$a")" '
      (.[0] // {}) as $q
      | { account: $a, vendor: $v, label: $label, enabled: ($enabled == "1"),
          leases: ($leases | tonumber? // 0),
          priority: ($prio | tonumber? // 50), models: $models,
          status: ($q.status // "none"), source: ($q.source // "none"),
          polled_at: ($q.polled_at // null),
          five_hour: ($q.five_hour // null), seven_day: ($q.seven_day // null),
          per_model: ($q.per_model // {}),
          extra_usage: ($q.extra_usage // null),
          error: ($q.error // null),
          cooldowns: $cools,
          cooldown_until: ($cools[$v] // null) }' 2>/dev/null
}

ALL=$(for A in "${NAMES[@]}"; do row_json "$A"; done | jq -s '.' 2>/dev/null)
[ -n "$ALL" ] || ALL='[]'

if [ "$JSON" = 1 ]; then printf '%s\n' "$ALL"; exit 0; fi

# ---- plain text, <= 40 columns ----------------------------------------------
# Fields are joined on US (0x1f), not TAB: `read` treats TAB as IFS WHITESPACE
# and collapses runs of it, so an account with two empty columns silently
# shifted every later value one place left in the table.
sshort() { case "$1" in unreadable) echo unread ;; unmetered) echo unmet ;; unknown) echo unkn ;; *) echo "$1" ;; esac; }

printf 'ACCOUNT    VEND 5H    WEEK  STATE\n'
NOW=$(date -u +%s)
printf '%s\n' "$ALL" | jq -r '.[] | [ .account, .vendor, (.five_hour.pct // ""), (.seven_day.pct // ""),
    .status, (.polled_at // ""), (.enabled|tostring), ([ .per_model | to_entries[] | "\(.key) \(.value.pct)%" ] | join(" ")),
    ([ (.cooldowns // {}) | to_entries[] | "\(.key)=\(.value)" ] | join(" ")),
    (.error // ""), (.leases // 0),
    (if .extra_usage == null then ""
     elif .extra_usage.spend_limit_reached then "LIMIT REACHED"
     elif (.extra_usage.disabled_reason // "") != "" then "off (\(.extra_usage.disabled_reason))"
     elif .extra_usage.user_disabled then "off (you)"
     elif .extra_usage.is_enabled then "on \(.extra_usage.pct // "?")% of cap"
     else "off" end) ]
  | map(if . == null then "" else tostring end) | join("\u001f")' 2>/dev/null |
while IFS=$'\x1f' read -r acct vend five week st polled en per cool err leases extra; do
  AGE=""
  if [ -n "$polled" ]; then
    E=$(date -u -d "$polled" +%s 2>/dev/null) || E=""
    [ -n "$E" ] && AGE=" $(age_human $(( NOW - E )))"
  fi
  st=$(sshort "$st"); [ "$en" = true ] || st="$st/off"
  printf '%-10.10s %-4.4s %-5.5s %-5.5s %-.12s\n' "$acct" "$(vshort "$vend")" \
    "$( [ -n "$five" ] && printf '%s%%' "$five" || printf -- '--' )" \
    "$( [ -n "$week" ] && printf '%s%%' "$week" || printf -- '--' )" \
    "$st$AGE"
  [ -n "$per" ]  && printf ' models: %s\n' "$per"       | cut -c1-40
  # OVERAGE, WHEN THERE IS A READING (BH-1456). This is the line that explains a
  # WEEK of 100% with a STATE of `ok`: the subscription window is spent and the
  # account is billing extra usage, which is a working account, not a parked one.
  # Only accounts whose json carries an `extra_usage` object get a line — a null
  # is "we have no reading", and printing `off` for it would be a claim.
  [ -n "$extra" ] && printf ' extra: %s\n' "$extra"     | cut -c1-40
  # One line per vendor that is cooling this NAME, each saying which vendor it
  # is: `default` can be out on codex and perfectly healthy on claude.
  if [ -n "$cool" ]; then
    for CD in $cool; do
      printf ' cooldown: %s %s to %s\n' "$acct" "$(vshort "${CD%%=*}")" "${CD#*=}" | cut -c1-40
    done
  fi
  # Only when there are any: a zero here is the normal state of every account on
  # every box that does not run a Fly pool, and a line per account saying so
  # would push the real numbers off a phone screen.
  case "${leases:-0}" in 0|'') ;; *) printf ' leases: %s pool machine(s)\n' "$leases" | cut -c1-40 ;; esac
  [ -n "$err" ]  && printf ' note: %s\n' "$err"         | cut -c1-40
  true
done
# FLEET-ONLY COOLDOWNS (BH-2355): an account another box cooled, which this
# box's picker now skips but which has no file here. One line each, after the
# table; one this box also has locally is already on its row above. Not cut to
# 40 columns: the box name is the point of the line.
if command -v fcd_list >/dev/null 2>&1; then
  fcd_list account | while IFS=$'\t' read -r FV FS FU _FSI _FR FB; do
    command -v _acct_cooling_file >/dev/null 2>&1 && _acct_cooling_file "$FV" "$FS" && continue
    FT=$(date -u -d "@$FU" '+%H:%MZ' 2>/dev/null) || continue
    printf ' cooldown: %s %s to %s (fleet, set on %s)\n' "$FS" "$(vshort "$FV")" "$FT" "${FB:-?}"
  done
fi
# Resets last: they are the "when does this come back" line, and putting them in
# the table would push it past a phone's width.
printf '%s\n' "$ALL" | jq -r '.[] | select(.five_hour.resets_at != null or .seven_day.resets_at != null)
  | " resets: \(.account) 5h \(.five_hour.resets_at // "-") wk \(.seven_day.resets_at // "-")"' 2>/dev/null \
  | cut -c1-40

# OWN-ACCOUNT PROJECTS (BH-1657): every fleet.conf project pinned to its own
# Claude account, the label, where the pin came from (db = settings row, env =
# ACCOUNT_OWN_PROJECTS fallback) and the fp8 of the token in accounts.d/<label>.env
# (`missing` when this box has no file — a Fly builder carries it in its bundle
# instead). The token is read in a subshell and only its sha256 cut leaves it.
# Text mode only: --json keeps its shape for the fleet-status push.
own_account_block() {
  local lib p _rest r label src f fp any=0
  for lib in "$HERE/lib/project-account.sh" "$H/bin/lib/project-account.sh"; do
    [ -r "$lib" ] && { . "$lib" 2>/dev/null; break; }
  done
  command -v account_for_project >/dev/null 2>&1 || return 0
  [ -r "$H/fleet.conf" ] || return 0
  printf 'OWN-ACCOUNT PROJECTS\n'
  while read -r p _rest; do
    case "$p" in ''|'#'*) continue ;; esac
    r=$(account_for_project "$p" 2>/dev/null)
    label="${r#label=}"; label="${label%% *}"; src="${r##*source=}"
    [ -n "$label" ] || continue
    f="$HENV/accounts.d/$label.env"
    fp=$( [ -r "$f" ] || exit 0
          set +u; CLAUDE_CODE_OAUTH_TOKEN=""; . "$f" >/dev/null 2>&1
          [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | sha256sum | cut -c1-8 )
    printf '%s %s %s %s\n' "$p" "$label" "$src" "${fp:-missing}"
    any=1
  done < "$H/fleet.conf"
  [ "$any" = 1 ] || printf ' none (every project on the shared pool)\n'
}
own_account_block
