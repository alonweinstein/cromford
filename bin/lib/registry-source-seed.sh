#!/bin/bash
# shellcheck shell=bash
# bin/lib/registry-source-seed.sh — BH-5651 (BH-5633.3): the fleet switch to the
# D1 registry. Sourced, never executed; set -u safe; defines functions only.
#
#   registry_source_seed <checkout> <global.env> <harness-root>
#     appends REGISTRY_SOURCE=db to global.env, once, and only when it is safe:
#     - global.env missing: rc 0, nothing.
#     - any `REGISTRY_SOURCE=` line (db, file, empty, anything): rc 0, nothing.
#       The operator's line wins; REGISTRY_SOURCE=file is the kill switch.
#       A commented `# REGISTRY_SOURCE=...` line does not count.
#     - otherwise one GET /api/registry with this box's JOBS_URL/HARNESS_SECRET
#       from global.env (bin/lib/registry.sh registry_json_fetched, TTL 0, in a
#       throwaway root: no cache and no outage ALERTS line on this box). It
#       must answer usably NOW (a cache served through an outage does not
#       count) and its active project set must equal the checkout fleet.conf's.
#       Either fails: rc 0, nothing appended, ONE update-runners.log line a UTC
#       day (flags/registry-seed-wait-<day>), no ALERTS line: the box keeps
#       working in file mode.
#     - a pass appends the line under the harden-state release/rearm lock (the
#       watchdog_url_seed pattern) and logs one update-runners.log line. A
#       failed append is ONE line through bin/alert-line.sh, rc 1.
#   Caller: bin/harness-sync.sh, right after watchdog_url_seed, `|| true`.
# The root is the third argument and nothing else (D43): empty is rc 0, nothing.

registry_source_seed() {
  local ck="$1" genv="$2" root="$3" rj have want day rc lib probe
  [ -n "$root" ] && [ -e "$genv" ] || return 0
  grep -q '^REGISTRY_SOURCE=' "$genv" 2>/dev/null && return 0
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/registry.sh"
  want=$(awk '!/^[[:space:]]*(#|$)/ {print $1}' "$ck/fleet.conf" 2>/dev/null | sort)
  # The probe runs in a throwaway root: a box still in file mode must not open
  # an outage episode (an ALERTS line) or leave a cache behind for a registry
  # it does not read yet.
  probe=$(mktemp -d 2>/dev/null) || return 0
  rj=$(
    set -a; . "$genv" 2>/dev/null; set +a
    export HARNESS="$probe" REGISTRY_SOURCE=db
    . "$lib" 2>/dev/null || exit 1
    registry_json_fetched 2>/dev/null
  ) || rj=""
  have=""
  if [ -n "$rj" ] && [ -s "$rj" ]; then
    have=$(jq -r '.projects[] | select((.status // "active") == "active") | .project' "$rj" 2>/dev/null | sort)
  fi
  rm -rf "$probe"
  if [ -z "$rj" ] || [ -z "$want" ] || [ "$have" != "$want" ]; then
    day=$(date -u +%Y%m%d)
    if [ ! -e "$root/flags/registry-seed-wait-$day" ]; then
      mkdir -p "$root/flags" 2>/dev/null && touch "$root/flags/registry-seed-wait-$day" 2>/dev/null
      printf '%s harness sync: REGISTRY_SOURCE=db NOT seeded into env/global.env (BH-5651): %s; the box stays in file mode and the next sync asks again\n' \
        "$(date -u '+%Y-%m-%d %H:%M:%SZ')" \
        "$( if [ -z "$rj" ]; then echo "GET /api/registry gave no usable answer"
            elif [ -z "$want" ]; then echo "$ck/fleet.conf lists no project"
            else echo "the registry's active projects ($(printf '%s\n' "$have" | grep -c .)) are not the checkout fleet.conf's ($(printf '%s\n' "$want" | grep -c .))"; fi )" \
        >> "$root/logs/update-runners.log" 2>/dev/null
    fi
    return 0
  fi
  # global.env is +i on an armed box: release -> append -> rearm under the
  # re-arm lane's lock (bin/lib/watchdog-url.sh watchdog_url_seed).
  (
    flock -w 60 8 || exit 3
    [ -x "$root/bin/harden-state.sh" ] && "$root/bin/harden-state.sh" --release "$genv" >/dev/null 2>&1
    cat 2>/dev/null >> "$genv" <<'EOF'
REGISTRY_SOURCE=db
EOF
    rc=$?
    [ -x "$root/bin/harden-state.sh" ] && "$root/bin/harden-state.sh" --rearm "$genv" >/dev/null 2>&1
    exit $rc
  ) 2>/dev/null 8>"$root/locks/harden-state.lock"
  rc=$?
  if [ "$rc" = 0 ]; then
    printf '%s harness sync: REGISTRY_SOURCE=db seeded into env/global.env; the registry answered with the checkout'"'"'s %s projects (BH-5651)\n' \
      "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$(printf '%s\n' "$want" | grep -c .)" >> "$root/logs/update-runners.log" 2>/dev/null
    return 0
  fi
  local msg="harness sync: could not append REGISTRY_SOURCE=db to $genv (rc $rc) — this box keeps reading the committed fleet.conf while the fleet reads the D1 registry (BH-5651). Fix: add the line REGISTRY_SOURCE=db to $genv by hand (bin/harden-state.sh --release it first on an armed box)"
  # Through bin/alert-line.sh only (BH-2314), as watchdog_url_seed does.
  local al="$root/bin/alert-line.sh"
  [ -x "$al" ] || al="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/alert-line.sh"
  if [ -x "$al" ]; then
    HARNESS="$root" "$al" "$msg"
  else
    printf '%s %s (no bin/alert-line.sh to page with)\n' "$(date -u '+%F %TZ')" "$msg" >> "$root/logs/update-runners.log" 2>/dev/null
  fi
  return 1
}
