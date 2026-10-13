#!/bin/bash
# tests/registry-db-fallback.bh-5649-test.sh — BH-5649 (the ticket's
# tests/registry-db-fallback-test.sh): what bin/fleet-conf.sh answers in
# REGISTRY_SOURCE=db mode when harness-jobs /api/registry is down or wrong.
#
#   F1 API down: the cache answers, and 5 calls write ONE ALERTS line
#   F2 an answer of {} keeps the cache byte for byte
#   F3 HTTP 500 keeps the cache byte for byte
#   F4 a good answer ends the episode (registry.log "usable again"), and the
#      next outage alerts again
#   F5 no cache and API down: the committed file answers, same output and rc
#      as file mode, and one ALERTS line says "no cache"
#   F6 not configured (no HARNESS_SECRET): no call, no ALERTS line; the cache
#      answers, else the file
#   F7 no temp file is left in state/registry
#   F8 8 concurrent callers in one outage write exactly one ALERTS line
#   F9 {"version":3,"projects":[]} is an outage, not an empty registry
#
# Run from anywhere: tests/registry-db-fallback.bh-5649-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FC="$DIR/bin/fleet-conf.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/stub"
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
S="${CURL_STUB_DIR:?}"
{ printf '%s ' "$@" | tr '\n' ' '; echo; } >> "$S/calls"
rc=$(cat "$S/rc" 2>/dev/null); rc=${rc:-0}
[ "$rc" = 0 ] || exit "$rc"
cat "$S/body" 2>/dev/null
printf '\n%s' "$(cat "$S/http" 2>/dev/null || echo 200)"
SH
chmod +x "$T/bin/curl"
: > "$T/stub/calls"
calls() { wc -l < "$T/stub/calls" | tr -d ' '; }
stub() { echo "$1" > "$T/stub/rc"; echo "$2" > "$T/stub/http"; printf '%s' "$3" > "$T/stub/body"; }

# The committed file and the registry disagree on purpose: an answer says
# which one it came from.
cat > "$T/file.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha 10.9.9.1
delta    Acme/delta    -                     -          8 box-small 10.9.9.3
zeta-os  Acme/zeta-os  https://zeta.example  /api/board 1
EOF
GOOD='{"version":4,"updated_at":"2026-10-09T00:00:00Z",
 "projects":[{"project":"alpha-os","repo":"Acme/cached","prod":"https://alpha.example","board_prefix":"/api/board","cron_offset":2,"box":"box-alpha","position":0,"status":"active"},
             {"project":"delta","repo":"Acme/delta","prod":"-","board_prefix":"-","cron_offset":8,"box":"box-small","position":1,"status":"active"}],
 "boxes":[{"box":"box-alpha","box_id":"alpha","tailnet_ip":"10.9.9.1","cost_box":null,"standby_hub_name":null,"standby_hub_id":null},
          {"box":"box-small","box_id":"small","tailnet_ip":"10.9.9.3","cost_box":"small","standby_hub_name":null,"standby_hub_id":null}],
 "lane_boxes":[],"box_accounts":[]}'

HH="$T/h"
db() { # db <cmd...> — db mode against the stub, FLEET_CONF on the committed file
  env PATH="$T/bin:$PATH" HARNESS="$HH" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
    REGISTRY_SOURCE=db CURL_STUB_DIR="$T/stub" FLEET_CONF="$T/file.conf" "$@" 2>/dev/null
}
alerts() { grep -c '\[registry\]' "$HH/logs/ALERTS.log" 2>/dev/null || echo 0; }
RG="$HH/state/registry"

# ---- seed the cache with a good answer ------------------------------------------
stub 0 200 "$GOOD"
OUT=$(db "$DIR/bin/fleet-conf.sh" alpha-os repo)
[ "$OUT" = Acme/cached ] && ok || bad "seed: a good answer printed '$OUT', want Acme/cached"
[ -s "$RG/registry.json" ] && [ -s "$RG/fleet.conf" ] && [ "$(cat "$RG/version" 2>/dev/null)" = 4 ] \
  && ok || bad "seed: the cache files were not written"

# ---- F1 API down -------------------------------------------------------------------
stub 7 000 ""
OUT=$(REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo); R=$?
[ "$OUT" = Acme/cached ] && [ "$R" = 0 ] && ok || bad "F1 API down printed '$OUT' rc $R, want the cache"
for _ in 1 2 3 4; do REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null; done
[ "$(alerts)" = 1 ] && ok || bad "F1 5 calls in one outage wrote $(alerts) ALERTS lines, want 1"
grep -q 'unusable (curl_rc=7) — reading the cached registry v4' "$HH/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "F1 the ALERTS line does not name the reason and the cache: $(cat "$HH/logs/ALERTS.log" 2>/dev/null)"
[ -e "$RG/outage" ] && ok || bad "F1 no outage marker"

# ---- F2 {} keeps the cache ---------------------------------------------------------
cp "$RG/registry.json" "$T/before.json"; cp "$RG/fleet.conf" "$T/before.conf"
stub 0 200 '{}'
OUT=$(REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo)
[ "$OUT" = Acme/cached ] && ok || bad "F2 {} answered '$OUT'"
cmp -s "$T/before.json" "$RG/registry.json" && cmp -s "$T/before.conf" "$RG/fleet.conf" \
  && ok || bad "F2 an answer of {} changed the cache"

# ---- F3 HTTP 500 keeps the cache ----------------------------------------------------
stub 0 500 '{"error":"registry unavailable"}'
OUT=$(REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo)
[ "$OUT" = Acme/cached ] && ok || bad "F3 HTTP 500 answered '$OUT'"
cmp -s "$T/before.json" "$RG/registry.json" && cmp -s "$T/before.conf" "$RG/fleet.conf" \
  && ok || bad "F3 an HTTP 500 changed the cache"
[ "$(alerts)" = 1 ] && ok || bad "F2/F3 are the same episode: $(alerts) ALERTS lines, want 1"

# ---- F4 episode reset ----------------------------------------------------------------
stub 0 200 "$GOOD"
REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null
[ ! -e "$RG/outage" ] && ok || bad "F4 a good answer left the outage marker"
grep -q 'registry API usable again (v4)' "$HH/logs/registry.log" 2>/dev/null && ok || bad "F4 no 'usable again' line in registry.log"
stub 7 000 ""
REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null
REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null
[ "$(alerts)" = 2 ] && ok || bad "F4 the second outage: $(alerts) ALERTS lines, want 2"

# ---- F9 an empty registry is an outage ------------------------------------------------
stub 0 200 "$GOOD"; REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null
cp "$RG/registry.json" "$T/before.json"
stub 0 200 '{"version":3,"updated_at":"x","projects":[],"boxes":[],"lane_boxes":[],"box_accounts":[]}'
OUT=$(REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo)
[ "$OUT" = Acme/cached ] && ok || bad "F9 an empty registry answered '$OUT'"
cmp -s "$T/before.json" "$RG/registry.json" && ok || bad "F9 an empty registry overwrote the cache"
[ "$(alerts)" = 3 ] && [ -e "$RG/outage" ] && ok || bad "F9 an empty registry is not an outage: $(alerts) ALERTS lines"
stub 0 200 '{"version":0,"updated_at":"x","projects":[{"project":"a","repo":"A/a","prod":"-","board_prefix":"-","cron_offset":1,"box":null}],"boxes":[],"lane_boxes":[],"box_accounts":[]}'
REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null
cmp -s "$T/before.json" "$RG/registry.json" && ok || bad "F9 version 0 overwrote the cache"
stub 0 200 'not json'
REGISTRY_CACHE_TTL_S=0 db "$FC" alpha-os repo >/dev/null
cmp -s "$T/before.json" "$RG/registry.json" && ok || bad "F9 a non-JSON body overwrote the cache"

# ---- F7 no partial files ------------------------------------------------------------
STRAY=$(ls -A "$RG" | grep -vxE 'registry\.json|fleet\.conf|version|outage|\.refresh\.lock')
[ -z "$STRAY" ] && ok || bad "F7 stray files in state/registry: $STRAY"

# ---- F5 no cache, API down -------------------------------------------------------------
HH="$T/h5"; RG="$HH/state/registry"; stub 7 000 ""
for P in alpha-os delta zeta-os no-such; do
  for F in repo box tailnet_ip; do
    A=$(FLEET_CONF="$T/file.conf" "$FC" "$P" "$F" 2>/dev/null; echo "rc=$?")
    B=$(db "$FC" "$P" "$F"; echo "rc=$?")
    [ "$A" = "$B" ] && ok || bad "F5 $P $F: file [$A] db [$B]"
  done
done
A=$(FLEET_CONF="$T/file.conf" "$FC" --projects); B=$(db "$FC" --projects)
[ "$A" = "$B" ] && ok || bad "F5 --projects: file [$A] db [$B]"
[ "$(alerts)" = 1 ] && grep -q 'no cache, reading the committed fleet.conf' "$HH/logs/ALERTS.log" \
  && ok || bad "F5 want exactly 1 'no cache' ALERTS line, got: $(cat "$HH/logs/ALERTS.log" 2>/dev/null)"
STRAY=$(ls -A "$RG" 2>/dev/null | grep -vxE 'outage|\.refresh\.lock')
[ -z "$STRAY" ] && ok || bad "F7 stray files after a cold outage: $STRAY"

# ---- F6 not configured ------------------------------------------------------------------
: > "$T/stub/calls"; stub 0 200 "$GOOD"
nc() { env PATH="$T/bin:$PATH" HARNESS="$HH" JOBS_URL=https://jobs.test REGISTRY_SOURCE=db \
  REGISTRY_CACHE_TTL_S=0 CURL_STUB_DIR="$T/stub" FLEET_CONF="$T/file.conf" "$@" 2>/dev/null; }
HH="$T/h6"
mkdir -p "$HH/state/registry"; cp "$T/h/state/registry/registry.json" "$T/h/state/registry/fleet.conf" "$HH/state/registry/"
OUT=$(nc "$FC" alpha-os repo)
[ "$OUT" = Acme/cached ] && ok || bad "F6 not configured with a cache answered '$OUT'"
HH="$T/h6b"
OUT=$(nc "$FC" alpha-os repo)
[ "$OUT" = Acme/alpha-os ] && ok || bad "F6 not configured without a cache answered '$OUT', want the file"
nc "$FC" alpha-os repo >/dev/null
[ "$(calls)" = 0 ] && ok || bad "F6 not configured made $(calls) call(s)"
[ ! -s "$T/h6/logs/ALERTS.log" ] && [ ! -s "$T/h6b/logs/ALERTS.log" ] && ok || bad "F6 not configured wrote an ALERTS line"
[ "$(grep -c 'not configured' "$T/h6b/logs/registry.log" 2>/dev/null)" = 1 ] && ok || bad "F6 want one 'not configured' registry.log line a day"

# ---- F8 concurrency -----------------------------------------------------------------------
HH="$T/h8"; stub 7 000 ""
for _ in 1 2 3 4 5 6 7 8; do
  db "$FC" alpha-os repo > /dev/null &
done
wait
[ "$(alerts)" = 1 ] && ok || bad "F8 8 concurrent callers wrote $(alerts) ALERTS lines, want 1"

echo "registry-db-fallback: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
