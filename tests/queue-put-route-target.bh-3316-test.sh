#!/bin/bash
# tests/queue-put-route-target.bh-3316-test.sh — a no-target queue_put follows
# the project's routing, and the deferral requeue retargets a stranded row.
#
# BH-3316: `jobs-client.sh queue-put P KEY ID` with no target wrote
# target=local on a pool-routed project. Nothing claims a `local` row (only
# fly-dispatch and fly-pool claim, and they claim `fly`), so five rows sat
# queued for 6h. This drives the real client (bin/lib/jobs/*.sh) and the real
# bin/jobs-watchdog.sh against a fake curl and reads back the POSTed body.
# Run from anywhere: tests/queue-put-route-target.bh-3316-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/flags" "$T/state" "$T/bin/lib/jobs" "$T/fakebin" "$T/env" "$T/locks"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/jobs-watchdog.sh" "$T/bin/jobs-watchdog.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Fake worker. /api/routing/<p> answers $ROUTING_JSON when set, else 404.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/routing/*)
    if [ -n "${ROUTING_JSON:-}" ]; then printf '%s\n200\n' "$ROUTING_JSON"; else printf '{"error":"no row"}\n404\n'; fi ;;
  */api/jobs\?status=running*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue\?status=claimed*) printf '{"queue":[]}\n200\n' ;;
  */api/queue\?status=done*)    cat "${QUEUE_DONE_JSON:-/dev/null}"; printf '\n200\n' ;;
  */api/queue\?status=failed*)  printf '{"queue":[]}\n200\n' ;;
  */api/queue)                  printf '{"queued":{"status":"queued"},"duplicate":false}\n201\n' ;;
  *)                            printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/lane-alert.sh"; chmod +x "$T/bin/lane-alert.sh"

ENVS=(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret
      JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 ROUTING_ROWS=off
      REQ_SINK="$T/req.log")

# put <routing-json|""> <args...> -> the POST /api/queue body, via the real CLI
put() {
  local rj="$1"; shift
  rm -f "$T/req.log"
  env "${ENVS[@]}" ROUTING_JSON="$rj" bash "$T/bin/jobs-client.sh" queue-put "$@" >/dev/null 2>&1
  grep '^POST https://jobs.invalid/api/queue ' "$T/req.log" 2>/dev/null | head -1 | cut -d' ' -f3-
}
pool_flags() { touch "$T/flags/builder-fly-$1" "$T/flags/fly-pool-$1"; }
clear_flags() { rm -f "$T"/flags/builder-fly-* "$T"/flags/fly-pool-* "$T"/flags/pool-halt-*; }

# (i) pool flags, no target -> fly
clear_flags; pool_flags P
B=$(put "" P BH-1 1)
[ "$(jq -r .target <<<"$B" 2>/dev/null)" = fly ] && ok || bad "(i) no-target put on a pool-flagged project sent: ${B:-<no POST>}"

# (ii) no flags, the D1 routing row says pool -> fly
clear_flags
B=$(put '{"routing":{"project":"P","builder":"pool","pool_app":"x","halted":0}}' P BH-2 2)
[ "$(jq -r .target <<<"$B" 2>/dev/null)" = fly ] && ok || bad "(ii) no-target put with routing row builder=pool sent: ${B:-<no POST>}"

# (ii-b) the row wins over the files: row says local, flags say pool -> local
clear_flags; pool_flags P
B=$(put '{"routing":{"project":"P","builder":"local","halted":0}}' P BH-2b 2)
[ "$(jq -r .target <<<"$B" 2>/dev/null)" = local ] && ok || bad "(ii-b) routing row builder=local was not preferred over flags: ${B:-<no POST>}"

# (iii) no flags, routing 404 -> local
clear_flags
B=$(put "" P BH-3 3)
[ "$(jq -r .target <<<"$B" 2>/dev/null)" = local ] && ok || bad "(iii) no-target put on a local project sent: ${B:-<no POST>}"

# (iv) an explicit local on a pool project stays local
clear_flags; pool_flags P
B=$(put "" P BH-4 4 local)
[ "$(jq -r .target <<<"$B" 2>/dev/null)" = local ] && ok || bad "(iv) explicit local was overridden: ${B:-<no POST>}"
B=$(put "" P BH-4b 4 fly)
[ "$(jq -r .target <<<"$B" 2>/dev/null)" = fly ] && ok || bad "(iv-b) explicit fly was not kept: ${B:-<no POST>}"

# (v) the pure classifier, every builder x target pair plus halted
fn() { ( export "${ENVS[@]}"; . "$T/bin/jobs-client.sh"; "$@" ) 2>/dev/null; }
chk() { # chk <facts> <target> <want rc> <label>
  fn queue_target_stranded "$1" "$2" >/dev/null; local rc=$?
  [ "$rc" = "$3" ] && ok || bad "(v) queue_target_stranded '$1' '$2' rc=$rc, want $3 ($4)"
}
chk 'pool|0'  local 0 "local on pool strands"
chk 'fly1|0'  local 0 "local on fly1 strands"
chk 'local|0' local 1 "local on local is claimable"
chk 'pool|0'  fly   1 "fly on pool is claimable"
chk 'fly1|0'  fly   1 "fly on fly1 is claimable"
chk 'local|0' fly   1 "fly on local is NOT flagged (flagless box)"
chk 'pool|1'  fly   0 "fly on halted pool strands"
chk 'pool|1'  local 0 "local on halted pool strands"
R=$(fn queue_target_stranded 'pool|0' local)
case "$R" in *"no launcher claims local rows"*) ok ;; *) bad "(v) the local-on-pool reason is '$R'" ;; esac
R=$(fn queue_target_stranded 'pool|1' fly)
case "$R" in *"routing is halted"*) ok ;; *) bad "(v) the halted reason is '$R'" ;; esac
[ "$(fn queue_route_target 'pool|0')" = fly ]  && ok || bad "(v) route target for pool"
[ "$(fn queue_route_target 'fly1|0')" = fly ]  && ok || bad "(v) route target for fly1"
[ "$(fn queue_route_target 'local|0')" = local ] && ok || bad "(v) route target for local"
# the facts reader: row first, halted true/1 both read as 1, files on 404
clear_flags; pool_flags Q; touch "$T/flags/pool-halt-Q"
[ "$(fn queue_routing_facts Q)" = 'pool|1' ] && ok || bad "(v) facts from files: $(fn queue_routing_facts Q)"
[ "$( ( export ROUTING_JSON='{"routing":{"project":"Q","builder":"fly1","halted":true}}'; fn queue_routing_facts Q ) )" = 'fly1|1' ] \
  && ok || bad "(v) facts from a row with halted:true"
fn queue_routing_facts 'bad/name' >/dev/null && bad "(v) a bad project name was accepted" || ok

# (vi) watchdog: a deferred local row on a pool project is requeued as fly
clear_flags; pool_flags project-5
cat > "$T/queue-done.json" <<'EOF'
{"queue":[
 {"project":"project-5","ticket_key":"TK-900","ticket_id":"900","status":"done",
  "target":"local","attempt":1,"claimed_by":null,"enqueued_at":"2026-09-28T13:00:00Z",
  "reason":"BUILD_REFUSED context drift: rules/CLAUDE.md changed under the build",
  "meta":"{\"deferrals\":1}"}
]}
EOF
rm -f "$T/req.log" "$T/state/jobs-watchdog-deferred.txt"
env "${ENVS[@]}" QUEUE_DONE_JSON="$T/queue-done.json" bash "$T/bin/jobs-watchdog.sh" >/dev/null 2>&1
QB=$(grep '^POST https://jobs.invalid/api/queue ' "$T/req.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
[ "$(jq -r .key <<<"$QB" 2>/dev/null)" = TK-900 ] && ok || bad "(vi) watchdog did not re-queue TK-900: ${QB:-<no POST>}"
[ "$(jq -r .target <<<"$QB" 2>/dev/null)" = fly ] && ok || bad "(vi) watchdog re-queued the stranded local row as: $(jq -r .target <<<"$QB" 2>/dev/null)"
[ "$(jq -r .attempt <<<"$QB" 2>/dev/null)" = 1 ] && ok || bad "(vi) watchdog moved the attempt: $QB"
grep -q 'queue-defer-requeue project-5/TK-900 .*retarget=local->fly' "$T/logs/jobs-watchdog.log" 2>/dev/null \
  && ok || bad "(vi) the requeue log line does not name the retarget: $(grep queue-defer "$T"/logs/*.log 2>/dev/null)"

# (vi-b) the same row on a halted pool stays... local is still stranded, but a
# fly row on a halted pool is requeued as fly (halt is a pause, not a reroute)
touch "$T/flags/pool-halt-project-5"
sed 's/"target":"local"/"target":"fly"/; s/TK-900/TK-901/' "$T/queue-done.json" > "$T/queue-done-fly.json"
rm -f "$T/req.log" "$T/state/jobs-watchdog-deferred.txt"
env "${ENVS[@]}" QUEUE_DONE_JSON="$T/queue-done-fly.json" bash "$T/bin/jobs-watchdog.sh" >/dev/null 2>&1
QB=$(grep '^POST https://jobs.invalid/api/queue ' "$T/req.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
[ "$(jq -r .target <<<"$QB" 2>/dev/null)" = fly ] && ok || bad "(vi-b) a fly row on a halted pool was requeued as: ${QB:-<no POST>}"

# (vi-c) a local row on a local project stays local
clear_flags
sed 's/TK-900/TK-902/' "$T/queue-done.json" > "$T/queue-done-local.json"
rm -f "$T/req.log" "$T/state/jobs-watchdog-deferred.txt"
env "${ENVS[@]}" QUEUE_DONE_JSON="$T/queue-done-local.json" bash "$T/bin/jobs-watchdog.sh" >/dev/null 2>&1
QB=$(grep '^POST https://jobs.invalid/api/queue ' "$T/req.log" 2>/dev/null | head -1 | cut -d' ' -f3-)
[ "$(jq -r .target <<<"$QB" 2>/dev/null)" = local ] && ok || bad "(vi-c) a local row on a local project was requeued as: ${QB:-<no POST>}"

echo "queue-put-route-target.bh-3316: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
