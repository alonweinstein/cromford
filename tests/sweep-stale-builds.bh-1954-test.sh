#!/bin/bash
# tests/sweep-stale-builds.bh-1954-test.sh — BH-1954: bin/sweep-stale-builds.sh
# refuses on a capped queue read, alerts when it has no queue client, and every
# fail-closed refusal answers the same rc.
#
# The queue stub behaves like worker/jobs/src/routes/queue.js: it filters
# ?status= for real, and it honours ?limit= with the worker's default of 200
# and its clamp at 500. Without the default a sweep that sends no limit would
# see every row and this suite could not tell a truncated live set from a
# whole one, which is the defect it pins.
#
# Contract under test (header of bin/sweep-stale-builds.sh):
#   rc 3  a fail-closed refusal (feed unreadable, no queue client, queue read
#         failed, queue page full), always with ONE ALERTS line and no POST
#   rc 0  a clean run or a no-op (empty feed, dry run)
#   rc 1  usage (unknown arg) and the --max brake
# Run from anywhere: tests/sweep-stale-builds.bh-1954-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$T" || exit 1
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/closeout-terminal.sh" "$T/bin/lib/"
printf 'alpha-os Org/alpha https://a.example /api/board 2 local\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
printf 'CONSOLE_URL=http://console.invalid\nHARNESS_SECRET=s3cret\n' > "$T/env/global.env"
printf '#!/bin/bash\ntrue\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
MODE=""
for a; do case "\$a" in *api/builds/stale*) MODE=get;; *api/builds/close*) MODE=post;; *api/queue*) MODE=queue; URL="\$a";; *api/ledger*|*api/verdict*) MODE=ledger;; esac; done
if [ "\$MODE" = ledger ]; then printf '\n404\n'; exit 0; fi
if [ "\$MODE" = queue ]; then
  printf '%s\n' "\${URL#*api/queue}" >> $T/QUERIES
  [ "\${QUEUE_DOWN:-0}" = 1 ] && exit 7
  ST=""; LIM=200
  case "\$URL" in *status=*) ST="\${URL##*status=}"; ST="\${ST%%&*}";; esac
  case "\$URL" in *limit=*) LIM="\${URL##*limit=}"; LIM="\${LIM%%&*}";; esac
  [ "\$LIM" -gt 500 ] && LIM=500
  jq -c --arg s "\$ST" --argjson n "\$LIM" '{queue: ([ .queue[] | select(\$s == "" or .status == \$s) ] | .[:\$n])}' $T/QUEUE.json
  printf '\n200\n'; exit 0
fi
if [ "\$MODE" = get ]; then cat $T/FEED.json; exit 0; fi
BODY=""; P=0
for a; do [ "\$P" = 1 ] && { BODY="\$a"; P=0; }; [ "\$a" = "-d" ] && P=1; done
printf '%s\n' "\$BODY" >> $T/POSTS.jsonl
N=\$(printf '%s' "\$BODY" | jq '.closed | length')
printf '{"ok":true,"requested":%s,"updated":%s}\n' "\$N" "\$N"
EOF
chmod +x "$T/fakebin/curl"

feed() { jq -nc --argjson b "$1" '{ok:true,count:($b|length),builds:$b}' > "$T/FEED.json"; }
# queue_n <n> <status>: n live rows for keys the feed never names.
queue_n() { jq -nc --argjson n "$1" --arg s "$2" '{queue: [range($n) | {project:"alpha-os", ticket_key:"Q-\(.)", status:$s}]}' > "$T/QUEUE.json"; }
TWO='[{"bkey":"b1","project":"alpha-os","ticket_key":"TK-1","stage":"executing","updated_at":"2026-08-20T00:00:00Z"},
      {"bkey":"b2","project":"alpha-os","ticket_key":"TK-2","stage":"pr_created","updated_at":"2026-08-20T00:00:00Z"}]'
run()  { : > "$T/POSTS.jsonl"; : > "$T/logs/sweep-stale-builds.log"; : > "$T/logs/ALERTS.log"; : > "$T/QUERIES"
         HARNESS="$T" PATH="$T/fakebin:$PATH" HARNESS_SECRET=s3cret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
           bash "$DIR/bin/sweep-stale-builds.sh" "$@" >/dev/null 2>&1; echo $?; }
posted()  { jq -r '.closed[]?' "$T/POSTS.jsonl" 2>/dev/null | sort | tr '\n' ' '; }
# The sweep's own lines only: on an outage the jobs client adds its once-a-day
# "harness-jobs unreachable" line (bin/lib/jobs/req.sh), which is not the sweep's.
nalerts() { grep -c '\[sweep\]' "$T/logs/ALERTS.log" 2>/dev/null || true; }

# ---------- 1. a full page is a refusal, not a live set ----------
feed "$TWO"; queue_n 600 queued
RC_FULL=$(run)
[ -z "$(posted)" ] && ok || bad "full page: nothing may be POSTed (posted=$(posted))"
[ "$(nalerts)" = 1 ] && grep -q 'full page' "$T/logs/ALERTS.log" && ok \
  || bad "full page: exactly one ALERTS line naming the full page (got: $(cat "$T/logs/ALERTS.log"))"
[ "$RC_FULL" = 3 ] && ok || bad "full page: rc must be 3 (rc=$RC_FULL)"

# ---------- 3. the request carries the limit, for both statuses ----------
feed "$TWO"; queue_n 0 queued
RC=$(run)
grep -q 'status=queued.*limit=500' "$T/QUERIES" && grep -q 'status=claimed.*limit=500' "$T/QUERIES" && ok \
  || bad "the queue requests must carry limit=500 (sent: $(tr '\n' ' ' < "$T/QUERIES"))"

# ---------- 2. one row under the cap sweeps normally ----------
feed "$TWO"; queue_n 499 queued
RC=$(run)
[ "$RC" = 0 ] && [ "$(posted)" = "b1 b2 " ] && [ "$(nalerts)" = 0 ] && ok \
  || bad "499 rows: must sweep both, rc 0, no ALERTS (rc=$RC posted=$(posted) alerts=$(nalerts))"
# the claimed read hits the cap the same way
feed "$TWO"; queue_n 500 claimed
RC=$(run)
[ "$RC" = 3 ] && [ -z "$(posted)" ] && [ "$(nalerts)" = 1 ] && ok \
  || bad "a full claimed page must refuse too (rc=$RC posted=$(posted) alerts=$(nalerts))"
queue_n 0 queued

# ---------- 4. no queue client ----------
mv "$T/bin/jobs-client.sh" "$T/bin/jobs-client.sh.off"
feed "$TWO"
RC_NOCLIENT=$(run)
[ -z "$(posted)" ] && [ "$(nalerts)" = 1 ] && grep -q 'jobs-client' "$T/logs/ALERTS.log" && ok \
  || bad "no jobs-client: no POST and one ALERTS line (posted=$(posted) alerts=$(cat "$T/logs/ALERTS.log"))"
[ "$RC_NOCLIENT" = 3 ] && ok || bad "no jobs-client: rc must be 3 (rc=$RC_NOCLIENT)"
mv "$T/bin/jobs-client.sh.off" "$T/bin/jobs-client.sh"

# ---------- 5. queue down ----------
feed "$TWO"
RC_DOWN=$(QUEUE_DOWN=1 run)
[ -z "$(posted)" ] && [ "$(nalerts)" = 1 ] && [ "$RC_DOWN" = 3 ] && ok \
  || bad "queue down: no POST, one ALERTS line, rc 3 (rc=$RC_DOWN posted=$(posted) alerts=$(nalerts))"

# ---------- 6. unreadable feed ----------
printf 'upstream 502 bad gateway' > "$T/FEED.json"
RC_FEED=$(run)
[ -z "$(posted)" ] && [ "$(nalerts)" = 1 ] && [ "$RC_FEED" = 3 ] && ok \
  || bad "unreadable feed: no POST, one ALERTS line, rc 3 (rc=$RC_FEED posted=$(posted) alerts=$(nalerts))"

# ---------- 7. one refusal rc; no-ops are 0; usage and --max are 1 ----------
[ "$RC_FULL" = 3 ] && [ "$RC_NOCLIENT" = 3 ] && [ "$RC_DOWN" = 3 ] && [ "$RC_FEED" = 3 ] && ok \
  || bad "every refusal must share rc 3 (full=$RC_FULL noclient=$RC_NOCLIENT down=$RC_DOWN feed=$RC_FEED)"
feed "$TWO"; RC=$(run);            [ "$RC" = 0 ] && ok || bad "a clean run must be rc 0 (rc=$RC)"
feed '[]';   RC=$(run);            [ "$RC" = 0 ] && ok || bad "an empty feed must be rc 0 (rc=$RC)"
feed "$TWO"; RC=$(run --dry-run);  [ "$RC" = 0 ] && [ -z "$(posted)" ] && ok || bad "--dry-run must be rc 0 (rc=$RC)"
feed "$TWO"; RC=$(run --max 1);    [ "$RC" = 1 ] && [ -z "$(posted)" ] && ok || bad "--max over the cap must be rc 1 (rc=$RC)"
RC=$(run --bogus);                 [ "$RC" = 1 ] && ok || bad "an unknown arg must be rc 1 (rc=$RC)"

# ---------- 8. the header no longer calls the queue evidence box-only ----------
HDR=$(sed -n 1,30p "$DIR/bin/sweep-stale-builds.sh" | grep 'state/build-queue/')
grep -q 'boxes know' <<<"$HDR" \
  && bad "header still says only the boxes know state/build-queue/" || ok

echo "sweep-stale-builds.bh-1954-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
