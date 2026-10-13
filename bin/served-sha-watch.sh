#!/bin/bash
# gh-identity: app-token
# bin/served-sha-watch.sh — every 5 minutes on the hub, compare what each
# Vercel production domain serves with main HEAD (BH-4936, the tracer of #4916).
#
# WHY. project-3 #467 merged 2026-10-06T16:10Z as 2b2272a4, Vercel never created
# a deployment for it, and prod served a ~5h old build while nothing noticed.
#
# WHAT IT DOES. For each `<project> <teamId> <projectId> <domain>` row of
# SERVED_SHA_CONF (default $H/vercel.conf): main HEAD and its committer date
# (gh_rest repos/<slug>/commits/main), the sha the domain serves (alias ->
# deployment), the state of HEAD's production deployments, and, only when the
# shas differ, GitHub's compare served...head. bin/lib/served-sha-watch.sh's
# ssw_judge turns that into in-sync | wait | alert | unreadable:
#   alert = served is behind HEAD for SERVED_SHA_LAG_MIN minutes or more
#   (HEAD's age from its committer date, else from first_seen in the state
#   file), or HEAD's production deployment failed.
# State: state/served-sha-watch/<project>.json {head, first_seen, served,
# dep_state, last_verdict, checked_at}; first_seen resets when HEAD changes,
# an unreadable tick leaves the file exactly as it was, in-sync deletes it.
# Log: logs/served-sha-watch.log, one line per project not in sync and one
# `checked=N in_sync=N wait=N alert=N unreadable=N` summary.
#
# HOOKS. Every bin/lib/served-sha-watch.d/*.sh is sourced in lexical order, and
# per project, after the state write, every ssw_hook_* function is called as
#   ssw_hook_<name> <project> <verdict> <head> <served> <dep_state> <age_s> <state_file>
# in a subshell, with SSW_SLUG SSW_TEAM SSW_PID SSW_VNAME SSW_NOW SSW_LAG_S
# SSW_DOMAIN SSW_AUTODEPLOY H exported. A non-zero rc is logged, never fatal.
#
# WHAT IT NEVER DOES. This lane sends GET requests only: it sends no alert and
# starts no deploy (#4937 and #4938 add those as hooks). The Vercel token is
# read from the hub's CLI auth file and only ever reaches curl on stdin.
#
# Knobs (catalog/lanes.d/served-sha-watch.json): SERVED_SHA_LAG_MIN (minutes,
# 0 = off), SERVED_SHA_AUTODEPLOY (only 1 is on; handed to hooks as
# SSW_AUTODEPLOY), SERVED_SHA_HTTP_TIMEOUT, SERVED_SHA_CONF,
# SERVED_SHA_VERCEL_AUTH, SERVED_SHA_NOW (epoch seconds; test seam). The Vercel
# base URL is ENDPOINT_VERCEL. Off with flags/lane-off-served-sha-watch.
#
# Usage: bin/served-sha-watch.sh [--help]
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '3,40p' "$0"; exit 0 ;; esac
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165). Registry: catalog/lanes.d/served-sha-watch.json.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit served-sha-watch
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    served-sha-watch
# global.env is sourced HERE because cron does not; applied again below it so a
# settings row is not dropped by a knob the file also sets.
set -a +u; # shellcheck disable=SC1090,SC1091
. "$HENV/global.env" 2>/dev/null; set +a -u
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    served-sha-watch

LOG="$H/logs/served-sha-watch.log"
SDIR="$H/state/served-sha-watch"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
say() { echo "$(STAMP) $*" >> "$LOG" 2>/dev/null; }

LAG_MIN="${SERVED_SHA_LAG_MIN:-20}"
case "$LAG_MIN" in ''|*[!0-9]*) say "SERVED_SHA_LAG_MIN='${LAG_MIN:0:16}' is not a whole number — using 20"; LAG_MIN=20 ;; esac
LAG_MIN=$((10#$LAG_MIN))
[ "$LAG_MIN" = 0 ] && { say "off (SERVED_SHA_LAG_MIN=0)"; exit 0; }
LAG_S=$((LAG_MIN * 60))
SSW_AUTODEPLOY=0
[ "${SERVED_SHA_AUTODEPLOY:-0}" = 1 ] && SSW_AUTODEPLOY=1

exec 9>"$H/locks/served-sha-watch.lock" || { say "cannot open locks/served-sha-watch.lock — skipped"; exit 0; }
flock -n 9 2>/dev/null || { command -v flock >/dev/null 2>&1 && exit 0; }

# shellcheck source=bin/lib/served-sha-watch.sh
. "$H/bin/lib/served-sha-watch.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/served-sha-watch.sh" || { say "cannot load bin/lib/served-sha-watch.sh"; exit 1; }
SSW_TOKEN=$(ssw_vercel_token) || SSW_TOKEN=""
[ -n "$SSW_TOKEN" ] || { say "not configured (no Vercel CLI auth file)"; exit 0; }

. "${HARNESS:-/root/harness}/bin/lib/endpoints.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/endpoints.sh" 2>/dev/null
if ! SSW_BASE=$(endpoint_url vercel 2>/dev/null); then
  say "no vercel endpoint (ENDPOINT_VERCEL: no env, no registry default) — nothing checked"
  exit 1
fi

# shellcheck source=bin/lib/gh-app-auth.sh
. "$H/bin/lib/gh-app-auth.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/gh-app-auth.sh" 2>/dev/null
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/gh-rest.sh" || { say "cannot load bin/lib/gh-rest.sh"; exit 1; }

LC_COLLATE=C
for f in "$H"/bin/lib/served-sha-watch.d/*.sh; do
  [ -r "$f" ] || continue
  # shellcheck disable=SC1090
  . "$f" || say "hook file ${f##*/} failed to load"
done
HOOKS=$(declare -F | awk '$3 ~ /^ssw_hook_/ {print $3}' | LC_ALL=C sort)

NOW="${SERVED_SHA_NOW:-$(date -u +%s)}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac
CONF="${SERVED_SHA_CONF:-$H/vercel.conf}"
[ -r "$CONF" ] || { say "no $CONF — nothing checked"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/served-sha-watch.XXXXXX") || { say "mktemp failed — skipped"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

N=0; N_SYNC=0; N_WAIT=0; N_ALERT=0; N_UNREAD=0
while read -r p team pid domain _ <&3; do
  case "$p" in ''|'#'*) continue ;; esac
  N=$((N + 1))
  reason=""; verdict=""; slug=""; head=""; head_ts=""; served=""; vname=""; dep=unread; cmp=""; age_s=""; first_seen=""
  sf="$SDIR/$p.json"
  [ -n "$domain" ] || reason="vercel.conf row incomplete"
  if [ -z "$reason" ]; then
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
    [ "$slug" = - ] && slug=""
    [ -n "$slug" ] || reason="no repo in fleet.conf"
  fi
  if [ -z "$reason" ]; then
    gh_default_auth_reset; gh_default_auth_for_project "$p" >/dev/null 2>&1 || true
    hd=$(ssw_head "$slug"); rc=$?
    if [ "$rc" = 0 ] && [ -n "$hd" ]; then read -r head head_ts <<< "$hd"; else reason="head:rc$rc"; fi
  fi
  if [ -z "$reason" ]; then
    sv=$(ssw_served "$team" "$domain")
    if [ $? = 0 ]; then read -r served vname <<< "$sv"; else reason="${sv:-served:unread}"; fi
  fi

  st='{}'
  if [ -z "$reason" ]; then
    dep=$(ssw_dep_state "$team" "$pid" "$head")
    if ssw_is_sha "$head" && ssw_is_sha "$served" && ! ssw_same_sha "$head" "$served"; then
      gh_rest GET "repos/$slug/compare/$served...$head" > "$WORK/compare.json" \
        && cmp=$(jq -r '.status // empty' "$WORK/compare.json" 2>/dev/null)
    fi
    st=$(ssw_state_read "$sf"); src=$?
    [ "$src" = 0 ] || { say "$p state corrupt, treated as empty"; st='{}'; }
    first_seen=$(jq -r '.first_seen // empty' <<< "$st")
    [ "$(jq -r '.head // empty' <<< "$st")" = "$head" ] && [[ $first_seen =~ ^[0-9]+$ ]] || first_seen=$NOW
    [ -n "$head_ts" ] || head_ts=$first_seen
    age_s=$((NOW - head_ts))
    verdict=$(ssw_judge "$NOW" "$head_ts" "$LAG_S" "$head" "$served" "$cmp" "$dep")
    if [ "$verdict" = unreadable ]; then
      if ssw_is_sha "$head" && ssw_is_sha "$served"; then reason="compare:unread"; else reason="sha:not-hex"; fi
    fi
  fi
  [ -n "$reason" ] && verdict=unreadable
  case "$verdict" in in-sync|wait|alert|unreadable) ;; *) verdict=unreadable; reason="judge:$verdict" ;; esac

  if [ "$verdict" = wait ] || [ "$verdict" = alert ]; then
    js=$(jq -c --arg h "$head" --argjson fs "$first_seen" --arg s "$served" --arg d "$dep" \
          --arg v "$verdict" --argjson now "$NOW" \
          '. + {head:$h, first_seen:$fs, served:$s, dep_state:$d, last_verdict:$v, checked_at:$now}' <<< "$st")
    ssw_state_write "$sf" "$js" || say "$p state write failed"
  fi

  export SSW_SLUG="$slug" SSW_TEAM="$team" SSW_PID="$pid" SSW_VNAME="$vname" SSW_NOW="$NOW" \
         SSW_LAG_S="$LAG_S" SSW_DOMAIN="$domain" SSW_AUTODEPLOY H
  for hk in $HOOKS; do
    ( "$hk" "$p" "$verdict" "$head" "$served" "$dep" "$age_s" "$sf" ) < /dev/null; hrc=$?
    [ "$hrc" = 0 ] || say "$p hook $hk rc=$hrc"
  done
  [ "$verdict" = in-sync ] && rm -f "$sf"

  case "$verdict" in
    in-sync) N_SYNC=$((N_SYNC + 1)) ;;
    unreadable) N_UNREAD=$((N_UNREAD + 1)); say "$p unreadable ($reason)" ;;
    *) if [ "$verdict" = wait ]; then N_WAIT=$((N_WAIT + 1)); else N_ALERT=$((N_ALERT + 1)); fi
       say "$p $verdict served=${served:0:8} head=${head:0:8} age=$((age_s / 60))m deployment: $dep" ;;
  esac
done 3< "$CONF"

say "checked=$N in_sync=$N_SYNC wait=$N_WAIT alert=$N_ALERT unreadable=$N_UNREAD"
exit 0
