#!/bin/bash
# tests/commented-mirror.bh-2526-test.sh — bin/commented-mirror.sh turns a build
# dir's COMMENTED file into a job_artifacts `commented` row (BH-2526), so the
# hub's alerts groomer can read "this build was handled" from the DB instead of
# ssh-ing to the box that holds the dir.
#
# Runs the REAL bin/commented-mirror.sh over the REAL bin/jobs-client.sh and a
# curl stub that records every request. What is asserted is the PUTs the worker
# received and the `.commented-db` stamp left behind, never the source text.
#
# The failure that costs something is a stamp without a row (the hub then never
# learns the build was handled), so M3 pins write-then-stamp: a PUT that fails
# leaves no stamp and stops the loop. M4 pins the other direction: a build that
# was relaunched in place (COMMENTED removed) withdraws its row, or a stale
# `commented` row would settle an alert about a build that is running again.
# M7 drives the production call site — a real bin/run-triage.sh tick that ends
# in a gate SKIP — because that is the only thing that ever runs the mirror.
#
# Run from anywhere: tests/commented-mirror.bh-2526-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "commented-mirror.bh-2526: jq missing, cannot run"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/locks" "$H/env" "$H/flags" "$H/state" "$H/builds" "$T/fakebin"
printf 'JOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\n' > "$H/env/global.env"
[ -r "$DIR/bin/commented-mirror.sh" ] && sed "s|/root/harness|$H|g" "$DIR/bin/commented-mirror.sh" > "$H/bin/commented-mirror.sh"
chmod +x "$H/bin/commented-mirror.sh" 2>/dev/null
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
printf 'box-1\n' > "$H/state/box-name"

# curl: "METHOD URL BODY" per request; PUT_MODE=500 answers the artifact PUT
# with a 500, PUT_MODE=down fails the transport.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; METHOD=GET; BODY=""
while [ \$# -gt 0 ]; do case "\$1" in -X) METHOD="\$2"; shift 2;; --data-binary|-d) BODY="\$2"; shift 2;; *) shift;; esac; done
printf '%s %s %s\n' "\$METHOD" "\$URL" "\$BODY" >> "$T/curl.log"
case "\$METHOD \$URL" in
  "PUT "*/api/jobs/*/artifacts)
    [ "\${PUT_MODE:-ok}" = down ] && exit 7
    [ "\${PUT_MODE:-ok}" = 500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    printf '{"ok":true}\n200\n' ;;
  */api/jobs) printf '{"job":{"id":"triage-x-os-1","budget_usd":1}}\n201\n' ;;
  # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are now harness_flags rows read DB-first; a 200 with no .flag row is UNREADABLE and fails closed (paused), so the flag GET must answer the worker's real no-row 404.
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

mkbuild() { # mkbuild <name> <job_id|-> [age_s] — a handled build dir
  local d="$H/builds/$1"
  mkdir -p "$d"; touch "$d/COMMENTED"
  [ "$2" = - ] || jq -nc --arg j "$2" '{project:"x-os",key:"XO-1",job_id:$j}' > "$d/job.json"
  touch -d "@$(( $(date +%s) - ${3:-600} ))" "$d"
}
reset() { scratch_rm "$H/builds"; scratch_rm "$T/curl.log"; mkdir -p "$H/builds"; : > "$H/logs/commented-mirror.log"; : > "$T/curl.log"; }
mirror() { PATH="$T/fakebin:$PATH" bash "$H/bin/commented-mirror.sh" x-os >/dev/null 2>&1; }
puts() { grep -c '^PUT ' "$T/curl.log" 2>/dev/null || true; }
mlog() { cat "$H/logs/commented-mirror.log" 2>/dev/null; }

# ---- M1 a handled dir becomes one commented row -------------------------------
reset; mkbuild x-os-XO-1-202609250101 job-111
mirror
[ "$(puts)" = 1 ] && ok || bad "M1 one PUT expected (got $(puts): $(cat "$T/curl.log"))"
PL=$(grep -m1 '^PUT ' "$T/curl.log")
grep -q '^PUT https://jobs.invalid/api/jobs/job-111/artifacts ' <<<"$PL" && ok || bad "M1 the PUT must target the dir's job id: $PL"
B=$(sed 's/^[^ ]* [^ ]* //' <<<"$PL")
[ "$(jq -r .artifact_kind <<<"$B" 2>/dev/null)" = commented ] && ok || bad "M1 artifact_kind must be commented: $B"
[ "$(jq -r .artifact_ref <<<"$B" 2>/dev/null)" = "$H/builds/x-os-XO-1-202609250101" ] && ok || bad "M1 ref must be the dir path with no trailing slash: $B"
[ "$(cat "$H/builds/x-os-XO-1-202609250101/.commented-db" 2>/dev/null)" = job-111 ] && ok || bad "M1 the stamp must hold the job id"
grep -q 'put=1 withdrawn=0 nojob=0 deferred=0' <(mlog) && ok || bad "M1 summary line (log: $(mlog))"

# ---- M2 idempotent -----------------------------------------------------------
: > "$T/curl.log"; mirror
[ "$(puts)" = 0 ] && ok || bad "M2 a second run must PUT nothing (got $(puts))"

# ---- M3 a failed PUT leaves no stamp and stops the loop ---------------------
for mode in 500 down; do
  reset; mkbuild x-os-XO-1-a job-1 900; mkbuild x-os-XO-2-b job-2 600
  PUT_MODE=$mode mirror
  [ ! -e "$H/builds/x-os-XO-1-a/.commented-db" ] && [ ! -e "$H/builds/x-os-XO-2-b/.commented-db" ] \
    && ok || bad "M3($mode) a failed PUT must leave no stamp"
  [ "$(puts)" = 1 ] && ok || bad "M3($mode) the loop must stop after the first failure (got $(puts) PUTs)"
done

# ---- M4 un-commented dir withdraws on the stamped job id ---------------------
reset; mkbuild x-os-XO-3-c job-333
mirror; rm -f "$H/builds/x-os-XO-3-c/COMMENTED"; : > "$T/curl.log"
mirror
PL=$(grep -m1 '^PUT ' "$T/curl.log")
B=$(sed 's/^[^ ]* [^ ]* //' <<<"$PL")
[ "$(puts)" = 1 ] && grep -q '/api/jobs/job-333/artifacts ' <<<"$PL" \
  && [ "$(jq -r .artifact_ref <<<"$B" 2>/dev/null)" = withdrawn ] \
  && [ "$(jq -r .artifact_kind <<<"$B" 2>/dev/null)" = commented ] \
  && ok || bad "M4 one withdraw PUT on job-333 expected: $(cat "$T/curl.log")"
[ ! -e "$H/builds/x-os-XO-3-c/.commented-db" ] && ok || bad "M4 the stamp must be removed after the withdraw"
grep -q 'withdrawn=1' <(mlog) && ok || bad "M4 summary must count withdrawn=1 (log: $(mlog))"
# a withdraw that fails keeps the stamp, so the next tick retries it
reset; mkbuild x-os-XO-3-c job-333; mirror; rm -f "$H/builds/x-os-XO-3-c/COMMENTED"
PUT_MODE=500 mirror
[ -e "$H/builds/x-os-XO-3-c/.commented-db" ] && ok || bad "M4 a failed withdraw must keep the stamp"

# ---- M5 the cap: defer, never drop; reject a non-number ---------------------
reset; for i in 1 2 3 4 5; do mkbuild "x-os-XO-$i-d" "job-$i" $(( 1000 - i )); done
COMMENTED_MIRROR_MAX=2 mirror
[ "$(puts)" = 2 ] && ok || bad "M5 cap 2 must PUT exactly 2 (got $(puts))"
grep -q 'put=2 .*deferred=3' <(mlog) && ok || bad "M5 the rest must be counted deferred=3 (log: $(mlog))"
grep -q '/api/jobs/job-1/artifacts' "$T/curl.log" && grep -q '/api/jobs/job-2/artifacts' "$T/curl.log" \
  && ok || bad "M5 oldest first: job-1 and job-2 go before the rest"
: > "$T/curl.log"; COMMENTED_MIRROR_MAX=5 mirror
[ "$(puts)" = 3 ] && ok || bad "M5 the next tick drains the deferred 3 (got $(puts))"
reset; mkbuild x-os-XO-1-e job-1
: > "$T/curl.log"; COMMENTED_MIRROR_MAX=0 mirror
[ "$(puts)" = 0 ] && ok || bad "M5 cap 0 means off (got $(puts))"
: > "$H/logs/commented-mirror.log"; COMMENTED_MIRROR_MAX=abc mirror
[ "$(puts)" = 0 ] && ok || bad "M5 a non-number cap must PUT nothing (got $(puts))"
[ "$(grep -c 'COMMENTED_MIRROR_MAX=abc' "$H/logs/commented-mirror.log")" = 1 ] \
  && ok || bad "M5 a non-number cap must log one refusal line (log: $(mlog))"

# ---- M6 no job.json -> skipped, counted -------------------------------------
reset; mkbuild pool-x-os-XO-6-f -
mirror
[ "$(puts)" = 0 ] && ok || bad "M6 no job id means no PUT (got $(puts))"
grep -q 'nojob=1' <(mlog) && ok || bad "M6 summary must count nojob=1 (log: $(mlog))"
[ ! -e "$H/builds/pool-x-os-XO-6-f/.commented-db" ] && ok || bad "M6 no stamp without a PUT"

# ---- M7 the production call site: a real run-triage tick that SKIPs ----------
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkdir -p "$H/bin/lib/rt" "$H/prompts" "$H/fixture" "$T/repos" "$T/calls"
echo "SOP for x-os." > "$H/prompts/x-os.md"
cat > "$T/fleet.conf" <<'EOC'
x-os   example-org/x-os    https://board.example  /api/board  2 box-1 10.0.0.1
EOC
export FLEET_CONF="$T/fleet.conf"
wire_triage() {
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"
  chmod +x "$H/bin/run-triage.sh"
  for s in "$DIR"/bin/lib/rt/*.sh; do
    sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
  done
}
wire_triage
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$DIR/bin/lib/pause.sh" "$DIR/bin/lib/pause-rows.sh" "$H/bin/lib/"
echo 'pause_refresh(){ return 0; }' >> "$H/bin/lib/pause.sh"
printf '#!/bin/sh\necho box-1\n' > "$H/bin/box-name.sh"
printf '#!/bin/sh\necho "SKIP no-change (1 tickets)"\n' > "$H/bin/triage-gate.sh"
for s in unblocked-children.sh decompose-parent-close.sh beat.sh lane-alert.sh hotfix-seen.sh orphan-reconcile.sh triage-contract.sh; do
  printf '#!/bin/sh\nexit 0\n' > "$H/bin/$s"
done
printf '#!/bin/sh\necho "$*" >> "%s/agent.calls"\nexit 0\n' "$T" > "$H/bin/agent-call.sh"
chmod +x "$H/bin/"*.sh
tick() {
  scratch_rm "$H/state"; mkdir -p "$H/state"; model_routes_fixture "$H" x-os || exit 1
  : > "$T/curl.log"
  PATH="$T/fakebin:$PATH" CALLDIR="$T/calls" TRIAGE_SHARDS=0 HARNESS_SECRET=testsecret JOBS_URL=https://jobs.invalid \
    "$H/bin/run-triage.sh" x-os >/dev/null 2>&1
}
reset; mkbuild x-os-XO-7-g job-777
tick
grep -q 'rc=skip :: gate no-change' "$H/logs/x-os.log" 2>/dev/null && ok \
  || bad "M7 fixture: the tick must end in a gate SKIP (log: $(tail -3 "$H/logs/x-os.log" 2>/dev/null))"
grep -q '^PUT https://jobs.invalid/api/jobs/job-777/artifacts ' "$T/curl.log" && ok \
  || bad "M7 a SKIP tick must still mirror the COMMENTED dir (curl: $(grep -c . "$T/curl.log") requests)"
[ "$(cat "$H/builds/x-os-XO-7-g/.commented-db" 2>/dev/null)" = job-777 ] && ok || bad "M7 the tick must leave the stamp"
[ ! -s "$T/agent.calls" ] && ok || bad "M7 a SKIP tick buys no session"

echo "commented-mirror.bh-2526: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
