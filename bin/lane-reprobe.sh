#!/bin/bash
# bin/lane-reprobe.sh — hub cron (*/5), BH-1687 (part 2 of BH-1674): re-probe
# the runner lanes marked down in state/lane-down/ and let them clear
# themselves. The auth canary only looks every 6h and never says a lane came
# back; this lane gives each down lane its own schedule.
#
# Each tick: seed a record for any lane line in state/claude-auth-down.txt
# that predates the records and for any live fleet `lane` row (BH-2359) whose
# record is absent, then probe the DUE records, oldest last_probe
# first, at most LANE_REPROBE_MAX_PER_RUN, until LANE_REPROBE_DEADLINE_S.
# A record is due once LANE_REPROBE_FAST_S has passed since its last probe, or
# LANE_REPROBE_SLOW_S once the outage is LANE_REPROBE_BACKOFF_AFTER_S old.
#   ok probe       -> ld_recovered: record, flag and STATE line gone, one
#                     "back on" line, lanedown-<ID> and lanedown-stale-<ID> resolved
#   anything else  -> ld_mark (last_error, last_probe) and a "still down" line;
#                     rc 75 "not probed" and empty output are down, never ok
#   down >= LANE_DOWN_STANDING_S with no standing_at -> ONE warn per outage,
#                     lanedown-stale-<ID>; standing_at is stamped only after
#                     lane-alert.sh returns 0, so an undelivered warn retries
# Due records past the cap or the deadline are logged as "deferred N" and wait
# for the next tick. The record and its helpers are bin/lib/lane-down.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-lane-reprobe
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off lane-reprobe.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-reprobe
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lane-reprobe

mkdir -p "$H/locks" "$H/logs" || exit 1
# Dedupe, never a wait: a tick that finds the previous one still probing leaves.
exec 9>"$H/locks/lane-reprobe.lock"
flock -n 9 || exit 0
# shellcheck source=lib/lane-down.sh
. "$H/bin/lib/lane-down.sh" || { echo "lane-reprobe: $H/bin/lib/lane-down.sh missing" >&2; exit 1; }

FAST=${LANE_REPROBE_FAST_S:-1800};          case "$FAST" in ''|*[!0-9]*) FAST=1800 ;; esac
SLOW=${LANE_REPROBE_SLOW_S:-21600};         case "$SLOW" in ''|*[!0-9]*) SLOW=21600 ;; esac
BACKOFF=${LANE_REPROBE_BACKOFF_AFTER_S:-86400}; case "$BACKOFF" in ''|*[!0-9]*) BACKOFF=86400 ;; esac
STANDING=${LANE_DOWN_STANDING_S:-86400};    case "$STANDING" in ''|*[!0-9]*) STANDING=86400 ;; esac
MAXN=${LANE_REPROBE_MAX_PER_RUN:-4};        case "$MAXN" in ''|*[!0-9]*) MAXN=4 ;; esac
DEADLINE=${LANE_REPROBE_DEADLINE_S:-600};   case "$DEADLINE" in ''|*[!0-9]*) DEADLINE=600 ;; esac

LOG=$H/logs/lane-reprobe.log
utc() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(utc "$(date +%s)") $*" >> "$LOG"; }

# interval <since> <now> — how long this outage waits between probes.
interval() {
  case "$1" in ''|*[!0-9]*) echo "$FAST"; return ;; esac
  if [ $(($2 - $1)) -ge "$BACKOFF" ]; then echo "$SLOW"; else echo "$FAST"; fi
}
# due <record> <now> — never probed, or its interval has passed since the last probe.
due() {
  local lp
  lp=$(ld_get "$1" last_probe)
  case "$lp" in ''|*[!0-9]*) return 0 ;; esac
  [ $(($2 - lp)) -ge "$(interval "$(ld_get "$1" since)" "$2")" ]
}
# seed <now> — lane lines from before BH-1674 have a STATE line and flags but no
# record. Bare box lines (hub, project-4) are the claude lanes and never match. The
# box part is _ld_id_ok's charset, and the visibility canary's per-repo latches
# (ghdefault-<slug>, ghblind-<slug>) are excluded by prefix: a repo slug ending
# in -grok is not a runner lane (BH-2381).
seed() {
  local id rc lines=()
  [ -f "$H/state/claude-auth-down.txt" ] || return 0
  mapfile -t lines < <(grep -E '^[a-z0-9_.-]+-(codex|openrouter|fireworks|grok)$' "$H/state/claude-auth-down.txt" \
                       | grep -Ev '^gh(default|blind)-')
  for id in "${lines[@]}"; do
    [ -e "$(ld_record_path "$H" "$id")" ] && continue
    ld_mark "$H" "$id" "" "(pre-BH-1674 outage, error not recorded)" "$1"; rc=$?
    if [ "$rc" -eq 0 ]; then log "seeded $id from STATE"; else log "could not seed $id (ld_mark rc $rc)"; fi
  done
}
# seed_fleet <now> — BH-2359: a live `lane` row in the fleet (fcd_list) whose
# record is absent, e.g. after a hub rebuild, comes back as a record carrying
# the row's since. Runner lanes only, the set seed() admits: claude rows are
# STATE lines the hourly canary re-derives. No contract or no rows = no-op.
# A row whose id is not a <box>-<lane> id is logged ONCE per row (BH-2464):
# SKIPPED lists the ids already logged, rewritten each tick to the ones still
# live, so an id logs again only after its row is gone and a new one appears.
SKIPPED=$H/state/lane-reprobe-skipped.txt
seed_fleet() {
  local vendor subject until since reason box id rc bad=()
  command -v fcd_list >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r vendor subject until since reason box; do
    case "$vendor" in codex|openrouter|fireworks|grok) ;; *) continue ;; esac
    id=$subject-$vendor
    if ! _ld_id_ok "$id"; then
      bad+=("$id")
      grep -Fxq -- "$id" "$SKIPPED" 2>/dev/null || log "skipping fleet row $id: not a <box>-<lane> id"
      continue
    fi
    [ -e "$(ld_record_path "$H" "$id")" ] && continue
    case "$since" in *[!0-9]*) since="" ;; esac
    ld_mark "$H" "$id" "" "${reason:-(fleet row, error not recorded)}" "$1" "$since"; rc=$?
    if [ "$rc" -eq 0 ]; then log "seeded $id from fleet row"; else log "could not seed $id from fleet row (ld_mark rc $rc)"; fi
  done < <(fcd_list lane)
  if [ "${#bad[@]}" -eq 0 ]; then rm -f "$SKIPPED"
  else printf '%s\n' "${bad[@]}" > "$SKIPPED.tmp.$$" && mv "$SKIPPED.tmp.$$" "$SKIPPED"; fi
}
# addr_of <record> <box> — the record's addr, local for the hub, else fleet.conf.
addr_of() {
  local a
  a=$(ld_get "$1" addr)
  [ -z "$a" ] && [ "$2" = hub ] && a=local
  [ -n "$a" ] || a=$("$H/bin/fleet-conf.sh" --tailnet-ip-of-box "box-$2" 2>/dev/null) \
              || a=$("$H/bin/fleet-conf.sh" --tailnet-ip-of-box "$2" 2>/dev/null) || a=""
  echo "$a"
}
# stamp_standing <record> <t> — the lib has no setter; same tmp+mv discipline.
stamp_standing() {
  awk -v t="$2" 'index($0, "standing_at=") == 1 { print "standing_at=" t; next } { print }' "$1" > "$1.tmp.$$" \
    && mv "$1.tmp.$$" "$1"
}

start=$(date +%s)
seed "$start"
seed_fleet "$start"

queue=()
for r in "$H"/state/lane-down/*; do
  [ -f "$r" ] || continue
  case "$r" in *.tmp.*) continue ;; esac
  due "$r" "$start" || continue
  lp=$(ld_get "$r" last_probe); case "$lp" in ''|*[!0-9]*) lp=0 ;; esac
  queue+=("$lp ${r##*/}")
done
mapfile -t DUE < <(printf '%s\n' "${queue[@]+"${queue[@]}"}" | sort -n -k1,1 | awk 'NF == 2 { print $2 }')

probed=0; done_n=0
for ID in "${DUE[@]+"${DUE[@]}"}"; do
  [ "$probed" -lt "$MAXN" ] || break
  [ $(($(date +%s) - start)) -lt "$DEADLINE" ] || break
  done_n=$((done_n + 1))
  # The lane name goes into a command line: only a well-formed id is probed.
  [[ $ID =~ ^[a-z0-9_.-]+-[a-z0-9_.]+$ ]] || { log "skipping $ID: not a <box>-<lane> id"; continue; }
  r=$(ld_record_path "$H" "$ID"); box=${ID%-*}; lane=${ID##*-}
  addr=$(addr_of "$r" "$box")
  [ -n "$addr" ] || { log "no address for $box, not probed"; continue; }
  probed=$((probed + 1))
  if [ "$addr" = local ]; then
    OUT=$(timeout 180 bash -c "$H/bin/lane-probe.sh $lane" 2>&1)
  else
    OUT=$(timeout 180 ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$addr" "/root/harness/bin/lane-probe.sh $lane" 2>&1)
  fi
  t=$(date +%s)
  if ld_probe_ok "$OUT"; then
    ld_recovered "$H" "$ID" "$t" || log "could not clear $ID after an ok probe (ld_recovered rc $?)"
    continue
  fi
  ld_mark "$H" "$ID" "" "$OUT" "$t"; rc=$?
  [ "$rc" -eq 0 ] || { log "could not re-mark $ID (ld_mark rc $rc)"; continue; }
  since=$(ld_get "$r" since); case "$since" in ''|*[!0-9]*) since=$t ;; esac
  age=$((t - since))
  log "lane $lane still down on $box ($(ld_fmt_dur "$age")), next probe in $(ld_fmt_dur "$(interval "$since" "$t")")"
  if [ "$age" -ge "$STANDING" ] && [ -z "$(ld_get "$r" standing_at)" ]; then
    err=$(ld_get "$r" last_error); err=${err%"${err##*[! ]}"}   # the lib flattens the trailing newline to a space
    if [ -x "$H/bin/lane-alert.sh" ]; then
      "$H/bin/lane-alert.sh" --id "lanedown-stale-$ID" --severity warn auth \
        "RUNNER LANE $lane on $box down $(ld_fmt_dur "$age") (since $(utc "$since")). Last error: ${err:-none recorded}. That fallback tier is unavailable there; re-probing every ${SLOW}s." \
        >/dev/null 2>&1; rc=$?
    else
      rc=127
    fi
    if [ "$rc" -eq 0 ]; then
      stamp_standing "$r" "$t" || log "standing warn for $ID sent but standing_at not written"
    else
      log "standing warn for $ID not delivered (lane-alert rc $rc), retrying on its next probe"
    fi
  fi
done

left=$((${#DUE[@]} - done_n))
[ "$left" -le 0 ] || log "deferred $left due lane(s) to the next tick (cap $MAXN, deadline ${DEADLINE}s)"
exit 0
