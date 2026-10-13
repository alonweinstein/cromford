#!/bin/bash
# tests/fleet-status-held-queued.bh-1461-test.sh — a HELD row and a terminal
# `*.failed.json` marker are not "queued", and the fleet page says so.
#
# 2026-09-22: the fleet page read "8 queued, oldest 265 min" for cromford —
# the shape of a wedged pool, and the number worker/watchdog/src/index.js pages
# on (`oldest_queued_min > 40`). Three of those rows were held (by prose, which
# is BH-1461's other half) and five were terminal `*.failed.json` parks that
# nothing will ever start. Neither is a build waiting for a machine, so neither
# may age in `oldest_queued_min` or count in `queue_depth`; they ride in their
# own fields instead, because dropping them silently would be the opposite
# error — a pile of parked work invisible on the one page that watches it.
#
# Drives the FILE-fallback path on purpose: no jobs client is installed in the
# fixture, which is exactly what bin/fleet-status-push.sh falls back to, and it
# is the path that counted `*.failed.json` as queued.
# Run from anywhere: tests/fleet-status-held-queued.bh-1461-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh): every age
# below is derived from it, so the fixture cannot flake on calendar drift.
NOW=$(date -u +%s)

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin" \
         "$T/state/build-queue/alpha-os" "$T/state/pool/alpha-os"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nCONSOLE_URL=http://console.invalid\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/watchdog-url.sh" "$T/bin/lib/"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
sed "s|^H=/root/harness|H=$T|" "$DIR/bin/fleet-status-push.sh" > "$T/fsp.sh"
printf 'alpha-os Org/alpha https://a.example /api/board 2 box-alpha\n' > "$T/fleet.conf"
echo "a recent triage line" > "$T/logs/alpha-os.log"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
run() { rm -f "$T/PUSH.json"; PATH="$T/fakebin:$PATH" bash "$T/fsp.sh"; }
field() { jq -r ".projects.\"alpha-os\".$1 // \"missing\"" "$T/PUSH.json" 2>/dev/null; }
# qrow <key> <age-minutes> — a queued build-queue file, aged by mtime.
qrow() {
  jq -nc --arg k "$1" '{ticket_id:"1016",key:$k,attempt:1,deferrals:0,deaths:0}' \
    > "$T/state/build-queue/alpha-os/$1.json"
  touch -d "@$((NOW - ${2:-0} * 60))" "$T/state/build-queue/alpha-os/$1.json" 2>/dev/null \
    || touch -t "$(date -u -r $((NOW - ${2:-0} * 60)) '+%Y%m%d%H%M.%S' 2>/dev/null)" \
         "$T/state/build-queue/alpha-os/$1.json" 2>/dev/null
}

# ---------- 1. a plain queue still counts, and ages ----------
qrow BH-1 30
qrow BH-2 10
run
[ "$(field queue_depth)" = 2 ] && ok || bad "two waiting rows are queue_depth 2 (got $(field queue_depth))"
[ "$(field held)" = 0 ]   && ok || bad "nothing held means held 0 (got $(field held))"
[ "$(field failed)" = 0 ] && ok || bad "nothing parked means failed 0 (got $(field failed))"
QA=$(field oldest_queued_min)
[ "$QA" -ge 29 ] 2>/dev/null && ok || bad "the oldest waiting row is ~30 min (got $QA)"

# ---------- 2. a terminal .failed.json is not queued ----------
# bin/fly-pool.sh writes these when a row runs out of attempts. Nothing starts
# them again, so they are a PILE, not a QUEUE — and they were counted as queue
# depth AND (before BH-1075's `grep -v failed`) aged as the oldest.
jq -nc '{key:"BH-3",ticket_id:"1018",reason:"attempts exhausted"}' \
  > "$T/state/build-queue/alpha-os/BH-3.failed.json"
touch -d "@$((NOW - 265 * 60))" "$T/state/build-queue/alpha-os/BH-3.failed.json" 2>/dev/null || true
run
[ "$(field queue_depth)" = 2 ] && ok || bad "a .failed.json must not count as queued (got $(field queue_depth))"
[ "$(field failed)" = 1 ] && ok || bad "a .failed.json rides in failed (got $(field failed))"
QA=$(field oldest_queued_min)
[ "$QA" -lt 100 ] 2>/dev/null && ok || bad "a 265-min park must not become oldest_queued_min (got $QA)"

# ---------- 3. a HELD row is not queued either ----------
# The marker bin/fly-pool.sh writes beside its .terminal / .pr-noted sentinels
# when the HOLD gate skips a row. The row keeps its queue file — it resumes the
# moment the hold lifts — but it is not waiting on a machine.
printf '{"key":"BH-1","why":"hold:body HOLD: waiting on the client"}\n' \
  > "$T/state/pool/alpha-os/BH-1.held"
run
[ "$(field queue_depth)" = 1 ] && ok || bad "a held row must not count as queued (got $(field queue_depth))"
[ "$(field held)" = 1 ] && ok || bad "a held row rides in held (got $(field held))"
QA=$(field oldest_queued_min)
[ "$QA" -lt 29 ] 2>/dev/null && ok || bad "the held row must not age oldest_queued_min (got $QA)"

# ---------- 4. every row held or parked reads as an EMPTY queue ----------
# The incident's shape: nothing is waiting, so nothing is wedged, and the
# watchdog's oldest_queued_min alert must not fire — but the work is still
# visible as held/failed rather than deleted from the page.
printf '{"key":"BH-2","why":"hold:comment"}\n' > "$T/state/pool/alpha-os/BH-2.held"
run
[ "$(field queue_depth)" = 0 ] && ok || bad "all-held is queue depth 0 (got $(field queue_depth))"
[ "$(field oldest_queued_min)" = 0 ] && ok || bad "an empty queue has no age (got $(field oldest_queued_min))"
[ "$(field held)" = 2 ] && ok || bad "both held rows are counted (got $(field held))"
[ "$(field failed)" = 1 ] && ok || bad "the parked row is still counted (got $(field failed))"

# ---------- 5. a marker with no queue row counts nothing ----------
# A held marker left behind by a row that has since been consumed must not
# invent a held row out of nothing — the queue file is the record.
printf '{"key":"BH-9","why":"hold:body"}\n' > "$T/state/pool/alpha-os/BH-9.held"
run
[ "$(field held)" = 2 ] && ok || bad "an orphan marker must not be counted (got $(field held))"

echo "fleet-status-held-queued: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
