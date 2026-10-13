#!/bin/bash
# tests/pipeline-health-stranded-queue.bh-3316-test.sh — bin/pipeline-health.sh
# pages a queued build_queue ROW that nothing will ever claim (BH-3316).
#
# Five `target=local` rows on a pool-routed project sat queued 349m and nothing
# paged: check 1 reads only state/build-queue/ FILES, and nothing claims a local
# row on a fly-routed project. The block is extracted VERBATIM between its own
# markers and run with alert() stubbed; queue_list and queue_routing_facts are
# the real bin/lib/jobs/*.sh against a fake worker, so what is asserted is the
# page the real code raises for the rows the worker answers.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PH="$DIR/bin/pipeline-health.sh"
A=$(grep -c '^# >>> stranded queue row' "$PH")
B=$(grep -c '^# <<< stranded queue row' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok || bad "bin/pipeline-health.sh must carry exactly one '# >>> stranded queue row' … '# <<< stranded queue row' block (open=$A close=$B)"
awk '/^# >>> stranded queue row/{f=1;next} /^# <<< stranded queue row/{exit} f' "$PH" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: no stranded queue row block to run"; echo "pipeline-health-stranded-queue.bh-3316: $PASS passed, $((FAIL+1)) failed"; exit 1; }

# RETRACT_NS: evaluate the real assignment line, then ask it the question the
# epilogue asks (grep -E "^($RETRACT_NS):").
RL=$(grep -m1 '^RETRACT_NS=' "$PH")
RNS=$( eval "$RL"; printf '%s' "$RETRACT_NS" )
grep -qE "^($RNS):" <<<"strandedqueue:proj:BH-1" \
  && ok || bad "strandedqueue is not in RETRACT_NS, so a retargeted row never retracts its page"

H="$T/h"
mkdir -p "$H/flags" "$H/logs" "$H/bin/lib/jobs" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"

NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - $1 * 60 ))" +%Y-%m-%dT%H:%M:%SZ; }
# rows <key> <target> <age-min> ... -> a /api/queue answer for project $1
rows() {
  local p="$1"; shift; local out="" k t a
  while [ $# -gt 0 ]; do
    k=$1 t=$2 a=$3; shift 3
    out="$out${out:+,}{\"project\":\"$p\",\"ticket_key\":\"$k\",\"ticket_id\":\"1\",\"status\":\"queued\",\"target\":\"$t\",\"attempt\":0,\"claimed_by\":null,\"enqueued_at\":\"$(iso "$a")\"}"
  done
  printf '{"queue":[%s]}' "$out"
}
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$URL" in
  */api/routing/*) printf '{}\n404\n' ;;
  */api/queue\?project=*)
    P=${URL#*project=}; P=${P%%&*}
    if [ -f "$QDIR/$P.json" ]; then cat "$QDIR/$P.json"; else printf '{"queue":[]}'; fi; printf '\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
QDIR="$T/q"; mkdir -p "$QDIR"

drive() { # drive <projects> [env...]
  local projs="$1"; shift
  : > "$T/alerts.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_URL=https://jobs.invalid \
           JOBS_BOX=t JOBS_RETRIES=0 ROUTING_ROWS=off QDIR="$QDIR" JOBS_ALERT=0 "$@"
    # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh"
    alert() { printf '%s|%s\n' "$2" "$3" >> "$T/alerts.txt"; }
    PROJECTS="$projs"
    # shellcheck disable=SC1090
    . "$T/block.sh" ) >/dev/null 2>&1
}

# pool: pool-routed. loc: local-routed. halt: pool + halted.
touch "$H/flags/builder-fly-pool" "$H/flags/fly-pool-pool" \
      "$H/flags/builder-fly-halt" "$H/flags/fly-pool-halt" "$H/flags/pool-halt-halt"
rows pool BH-1174 local 349 BH-9 local 30 BH-8 fly 349 > "$QDIR/pool.json"
rows loc  LC-1 local 349 LC-2 fly 349 > "$QDIR/loc.json"
rows halt HT-1 fly 349 > "$QDIR/halt.json"
drive "pool loc halt"

grep -q '^strandedqueue:pool:BH-1174|pool BH-1174 queued 349m target=local and nothing will claim it (target=local on a pool-routed project' "$T/alerts.txt" \
  && ok || bad "a 349m local row on a pool project must page: $(cat "$T/alerts.txt")"
grep -q 'Retarget: queue-done pool BH-1174 done "retarget" then queue-put pool BH-1174 <ticket> fly' "$T/alerts.txt" \
  && ok || bad "the page does not carry the retarget commands: $(cat "$T/alerts.txt")"
grep -q ':BH-9|' "$T/alerts.txt" && bad "a 30m local row (under STRANDED_QUEUE_MIN) paged" || ok
grep -q ':BH-8|' "$T/alerts.txt" && bad "a fly row on a pool project paged" || ok
grep -q ':LC-' "$T/alerts.txt" && bad "a row on a local project paged: $(grep LC- "$T/alerts.txt")" || ok
grep -q '^strandedqueue:halt:HT-1|.*routing is halted' "$T/alerts.txt" \
  && ok || bad "a fly row on a halted pool must page: $(cat "$T/alerts.txt")"
[ "$(wc -l < "$T/alerts.txt")" = 2 ] && ok || bad "exactly two pages expected, got: $(cat "$T/alerts.txt")"

# The threshold is the settings row: at 400 the 349m row is still young.
drive "pool" STRANDED_QUEUE_MIN=400
[ -s "$T/alerts.txt" ] && bad "STRANDED_QUEUE_MIN=400 still paged the 349m row: $(cat "$T/alerts.txt")" || ok

# A queue outage is a skip, not a clean read and not a crash.
drive "pool halt" CURL_MODE=down
[ -s "$T/alerts.txt" ] && bad "a queue outage paged: $(cat "$T/alerts.txt")" || ok
( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_URL=https://jobs.invalid JOBS_BOX=t \
         JOBS_RETRIES=0 ROUTING_ROWS=off QDIR="$QDIR" JOBS_ALERT=0 CURL_MODE=down
  . "$H/bin/jobs-client.sh"; alert() { :; }; PROJECTS="pool"; . "$T/block.sh"; echo reached ) 2>/dev/null \
  | grep -qx reached && ok || bad "the block did not run to its end on a queue outage"

# A full page of 500 is named, never silently read as every row (D12).
python3 - "$QDIR/big.json" "$(iso 5)" <<'PY'
import json, sys
json.dump({"queue": [{"project": "big", "ticket_key": f"B-{i}", "status": "queued", "target": "fly",
                      "attempt": 0, "enqueued_at": sys.argv[2]} for i in range(500)]}, open(sys.argv[1], "w"))
PY
drive "big"
grep -q '^strandedqueue:big:page-cut|big: the stranded-queue check read a full page of 500' "$T/alerts.txt" \
  && ok || bad "a full 500-row page was not named: $(head -3 "$T/alerts.txt")"

echo "pipeline-health-stranded-queue.bh-3316: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
