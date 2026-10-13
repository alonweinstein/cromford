#!/bin/bash
# tests/fleet-propagate.bh-1115-test.sh — BH-1115: bin/fleet-propagate.sh bounds
# the pool bake fan-out and names the failure class per pool.
#
# WHAT THIS PINS. On 2026-09-20 00:00Z the first propagate tick after midnight
# baked all ten pool images in parallel with a freshly rolled WARM_BUST (every
# warm layer cold at once): one remote build OOM'd, five starved past the 1800s
# timeout, and the alert said only "failed: project-4 ..." — every cause had to be
# read out of the out files. So:
#   * POOL_BAKE_PARALLEL (default 2) caps the warm bake lane;
#   * a pool whose warm layer is COLD (no ok bake stamped today) is baked in a
#     serial lane, one at a time, alongside the capped warm lane;
#   * every failed pool carries a reason — timeout / oom / install / builder /
#     build — in the log line, in fleet-propagate.json and in the alert;
#   * the record is {status, reason, warm_sha} per pool, and warm_sha is the
#     repo sha fly/warm-bake.sh printed inside the image build;
#   * --check names the lane it would use and still writes nothing.
#
# Everything outside the script is stubbed through PATH ($T/bin) and a scratch
# HARNESS ($H/bin). The fly-image-build.sh stub counts its own concurrency under
# flock, per lane, so the cap and the serial lane are measured from what really
# ran — not from the script's source. git is REAL against a scratch origin.
#
# Run from anywhere: tests/fleet-propagate.bh-1115-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date +%s) # one wall-clock read; every fixture age is derived from it

# The fixture pushes to a scratch bare repo on main. The act-time guard fences
# pushes to main in the execute lane; a test lane is not guarded.
export HARNESS_LANE=test

H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin" "$T/fix" "$T/cnt"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
echo hub > "$H/state/box-id"
FLY="$H/state/fly"
FIX="$T/fix"; CNT="$T/cnt"; COLD_SET="$T/cold.set"
export FIX CNT COLD_SET
: > "$COLD_SET"

# ── the fixture fleet: one box; the pools are the flag files, set per section ─
cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os - - 2 box-alpha 10.0.0.1
EOF

# ── stubs ────────────────────────────────────────────────────────────────────
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
echo "cafe123456789"; exit 0
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
cat > "$H/bin/harness-sync.sh" <<'EOF'
#!/bin/bash
echo "synced (stub)"; exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"
exit 0
EOF
# The bake stub is the measuring instrument: it records its own in-flight count
# per LANE (the lane the fixture EXPECTS this pool in) and the run-wide total,
# so "cold max 1, warm max <= cap" is read off what really overlapped.
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
P="$1"
printf '%s\n' "$P" >> "$BAKE_CALLS"
LANE=warm; grep -qx "$P" "$COLD_SET" 2>/dev/null && LANE=cold
bump() { # bump <counter> <delta>
  (
    flock 9
    local cur max
    cur=$(cat "$CNT/$1.cur" 2>/dev/null || echo 0); cur=$((cur + $2))
    echo "$cur" > "$CNT/$1.cur"
    max=$(cat "$CNT/$1.max" 2>/dev/null || echo 0)
    [ "$cur" -gt "$max" ] && echo "$cur" > "$CNT/$1.max"
  ) 9>>"$CNT/lock"
}
bump "$LANE" 1; bump all 1
[ -f "$FIX/$P.out" ] && cat "$FIX/$P.out"
sleep "$(cat "$FIX/$P.sleep" 2>/dev/null || echo 0.5)"
bump "$LANE" -1; bump all -1
exit "$(cat "$FIX/$P.rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin"/* "$H/bin"/*

# ── a real scratch repo: bare origin + the hub's checkout ────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"
echo "echo init" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"

SEQ=0
commit() { # commit — one bin/ change, i.e. a fleet path
  SEQ=$((SEQ+1))
  echo "echo v$SEQ" > "$T/src/bin/run-build.sh"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "v$SEQ" && git -C "$T/src" push -q origin main
}
pools() { # pools <project...> — the pool set for this section, fixtures cleared
  rm -f "$H"/flags/fly-pool-app-* 2>/dev/null
  scratch_rm "$FLY"; scratch_rm "$FIX"; mkdir -p "$FLY" "$FIX"
  : > "$COLD_SET"
  local p; for p in "$@"; do : > "$H/flags/fly-pool-app-$p"; done
}
warm() { # warm <project> — an ok bake stamped TODAY (the layer is current)
  echo "$NOW" > "$FLY/$1.baked-at"
}
cold() { # cold <project> — an ok bake stamped yesterday (the layer is stale)
  echo "$((NOW - 86400))" > "$FLY/$1.baked-at"
  printf '%s\n' "$1" >> "$COLD_SET"
}
never() { # never <project> — no bake stamp at all: cold, and never baked
  rm -f "$FLY/$1.baked-at"
  printf '%s\n' "$1" >> "$COLD_SET"
}
fixture() { # fixture <project> <rc> <sleep> [out-text]
  echo "$2" > "$FIX/$1.rc"; echo "$3" > "$FIX/$1.sleep"
  [ $# -ge 4 ] && printf '%s\n' "$4" > "$FIX/$1.out"
}
run() { # run [flags...] — PAR / TMO / KNOB come from the caller's environment
  : > "$T/ssh.calls"; : > "$T/bake.calls"; : > "$T/alerts"
  rm -f "$CNT"/*.cur "$CNT"/*.max
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    POOL_IMAGE_MIN_AGE_MIN="${KNOB:-0}" \
    POOL_BAKE_PARALLEL="${PAR:-}" POOL_BAKE_TIMEOUT_S="${TMO:-}" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out" 2>"$T/err"
}
cmax()   { cat "$CNT/$1.max" 2>/dev/null || echo 0; }        # cmax <lane|all>
nbake()  { grep -c . "$T/bake.calls" 2>/dev/null | head -1; }
nalert() { grep -c . "$T/alerts"     2>/dev/null | head -1; }
jsonq()  { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }
reason() { jsonq ".pools[\"$1\"].reason"; }
status() { jsonq ".pools[\"$1\"].status"; }
lastlog() { tail -1 "$H/logs/fleet-propagate.log"; }
snapshot() { find "$H/state" "$H/logs" -type f -exec md5sum {} \; 2>/dev/null | sort; }

# ══ §A the cap on the warm lane ══════════════════════════════════════════════
pools w1 w2 w3 w4 w5
for P in w1 w2 w3 w4 w5; do warm "$P"; fixture "$P" 0 0.5; done
commit; run
[ "$(nbake)" = 5 ] && ok || bad "§A all five warm pools must be baked (got: $(cat "$T/bake.calls"))"
[ "$(cmax warm)" = 2 ] && ok \
  || bad "§A an unset POOL_BAKE_PARALLEL must cap the warm lane at 2 (max in flight was $(cmax warm))"
[ "$(cmax cold)" = 0 ] && ok || bad "§A no pool is cold here, so the serial lane must be empty (got $(cmax cold))"

commit; PAR=1 run
[ "$(nbake)" = 5 ] && ok || bad "§A POOL_BAKE_PARALLEL=1 must still bake every pool (got: $(cat "$T/bake.calls"))"
[ "$(cmax warm)" = 1 ] && ok || bad "§A POOL_BAKE_PARALLEL=1 must bake one at a time (max was $(cmax warm))"

pools w1 w2 w3 w4
for P in w1 w2 w3 w4; do warm "$P"; fixture "$P" 0 0.5; done
commit; PAR=0 run
[ "$(cmax warm)" -gt 2 ] && ok \
  || bad "§A POOL_BAKE_PARALLEL=0 means unlimited: four warm pools must exceed 2 in flight (max was $(cmax warm))"

commit; PAR=abc run
grep -q 'POOL_BAKE_PARALLEL=abc is not a number' "$H/logs/fleet-propagate.log" && ok \
  || bad "§A a garbage cap must be named in the log, never silent"
[ "$(cmax warm)" = 2 ] && ok \
  || bad "§A a garbage cap must fall back to 2, not to unlimited (max was $(cmax warm))"

# ══ §B the two lanes: cold serial, warm capped, every pool baked once ════════
pools c1 c2 c3 w1 w2
cold c1; cold c2; never c3; warm w1; warm w2
for P in c1 c2 c3 w1 w2; do fixture "$P" 0 0.5; done
commit; PAR=2 run
[ "$(cmax cold)" = 1 ] && ok \
  || bad "§B a cold warm-layer must be baked one at a time (cold max in flight was $(cmax cold))"
[ "$(cmax warm)" = 2 ] && ok || bad "§B the warm lane must still run at the cap (max was $(cmax warm))"
[ "$(cmax all)" -le 3 ] && ok \
  || bad "§B at most cap+1 remote builds may overlap (total max was $(cmax all))"
[ "$(nbake)" = 5 ] && [ "$(sort -u "$T/bake.calls" | wc -l)" = 5 ] && ok \
  || bad "§B every pool must be baked exactly once (got: $(cat "$T/bake.calls"))"
BAD_STATUS=""
for P in c1 c2 c3 w1 w2; do [ "$(status "$P")" = ok ] || BAD_STATUS="$BAD_STATUS $P=$(status "$P")"; done
[ -z "$BAD_STATUS" ] && ok || bad "§B every pool must be recorded ok (got$BAD_STATUS)"
MISSING=""
for P in c1 c2 c3; do
  grep -qE "$P: warm layer cold \(last ok bake .*\).*serial lane" "$H/logs/fleet-propagate.log" || MISSING="$MISSING $P"
done
[ -z "$MISSING" ] && ok \
  || bad "§B each cold pool must log its lane (missing:$MISSING): $(grep 'serial lane' "$H/logs/fleet-propagate.log")"
grep -q "c3: warm layer cold (last ok bake never)" "$H/logs/fleet-propagate.log" && ok \
  || bad "§B a pool with no stamp must say so: $(grep 'c3' "$H/logs/fleet-propagate.log")"
grep -q "w1: warm layer cold" "$H/logs/fleet-propagate.log" \
  && bad "§B a pool stamped today is not cold: $(grep 'w1' "$H/logs/fleet-propagate.log")" || ok

# ══ §C --check names the lane and writes nothing ════════════════════════════
pools c1 w1
cold c1; warm w1
fixture c1 0 0.5; fixture w1 0 0.5
commit
BEFORE_SNAP=$(snapshot)
run --check; RC=$?
[ "$RC" = 0 ] && ok || bad "§C --check must exit 0 (rc=$RC)"
grep -q '^    c1: bake (cold, serial lane)$' "$T/out" && ok \
  || bad "§C --check must name the serial lane for a cold pool: $(cat "$T/out")"
grep -q '^    w1: bake$' "$T/out" && ok \
  || bad "§C --check must print a plain bake for a warm pool: $(cat "$T/out")"
[ "$(nbake)" = 0 ] && ok || bad "§C --check must bake nothing"
[ "$(snapshot)" = "$BEFORE_SNAP" ] && ok || bad "§C --check wrote state or logs:
$(diff <(printf '%s\n' "$BEFORE_SNAP") <(snapshot))"

# ══ §D the classifier: the four incident shapes, the catch-all, the negatives ═
pools p-timeout p-oom p-install p-builder p-build
for P in p-timeout p-oom p-install p-builder p-build; do never "$P"; done
fixture p-timeout 0 5     'Creating an optimized production build ...'
fixture p-oom     1 0     'ERROR: process "/bin/sh -c cd /opt/warm/repo && npm run build" did not complete successfully: exit code: 137'
fixture p-install 1 0     'npm error code EUSAGE
npm error `npm ci` can only install packages when your package.json and package-lock.json are in sync.
npm error Missing: next@15.0.3 from lock file'
fixture p-builder 1 0     'Error: error releasing builder: deadline_exceeded'
fixture p-build   1 0     'Error: failed to fetch an image or build from source: build failed'
commit; TMO=2 run
[ "$(reason p-timeout)" = timeout ] && ok \
  || bad "§D a bake killed by our own timeout must read timeout (got '$(reason p-timeout)')"
[ "$(status p-timeout)" = fail ] && ok || bad "§D a timed-out bake is a failure (got '$(status p-timeout)')"
[ "$(reason p-oom)" = oom ] && ok || bad "§D exit code: 137 must read oom (got '$(reason p-oom)')"
[ "$(reason p-install)" = install ] && ok || bad "§D an npm lockfile failure must read install (got '$(reason p-install)')"
[ "$(reason p-builder)" = builder ] && ok || bad "§D deadline_exceeded must read builder (got '$(reason p-builder)')"
[ "$(reason p-build)" = build ] && ok || bad "§D an unmatched failure must read build (got '$(reason p-build)')"

pools n-ok-warmfail n-ok-137 n-timeoutword n-digest n-both
for P in n-ok-warmfail n-ok-137 n-timeoutword n-digest n-both; do never "$P"; done
fixture n-ok-warmfail 0 0 'warm build FAILED — baking checkout+node_modules only'
fixture n-ok-137      0 0 'ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 137
== retried and succeeded =='
fixture n-timeoutword 1 0 'next build exceeded the configured timeout 60000 ms for a page'
# The digest below is a repeated-137 40-hex, not a real-length sha256. The
# public-mirror leak guard refuses any bare 64-hex token and, by construction,
# has no marker rule for hex (bin/share/leakcheck.py), so a full-length digest
# here reds the publish suites. 40 hex in a repeated pattern is the shape every
# other suite already uses for a fake sha, and what this case proves — a loose
# 137 inside a hex blob is not an oom — does not depend on the length.
fixture n-digest      1 0 'pushing manifest sha256:1371371371371371371371371371371371371371'
fixture n-both        1 0 'Error: error releasing builder: deadline_exceeded
ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 137'
commit; run
[ "$(status n-ok-warmfail)" = ok ] && [ "$(reason n-ok-warmfail)" = "" ] && ok \
  || bad "§D a warm-bake fallback that still exits 0 is ok with no reason (got '$(status n-ok-warmfail)'/'$(reason n-ok-warmfail)')"
[ "$(status n-ok-137)" = ok ] && [ "$(reason n-ok-137)" = "" ] && ok \
  || bad "§D rc 0 must never be classified, whatever the out file says (got '$(status n-ok-137)'/'$(reason n-ok-137)')"
[ "$(reason n-timeoutword)" = build ] && ok \
  || bad "§D the word timeout in the body is not our timeout (got '$(reason n-timeoutword)')"
[ "$(reason n-digest)" = build ] && ok || bad "§D 137 inside a digest is not an oom (got '$(reason n-digest)')"
[ "$(reason n-both)" = oom ] && ok \
  || bad "§D oom outranks builder when both appear (got '$(reason n-both)')"

# ══ §E the record: {status, reason, warm_sha} for ok / fail / debounced ══════
# BH-3463 added warm and capture beside them (empty here: no warm line, no
# timeout), so the exact-object compare below carries both keys. BH-6201 added
# phases, whose seconds depend on the clock: it is checked on its own below and
# left out of the exact compare.
SHA40=3f7c1a9b2e5d4068a1b2c3d4e5f60718293a4b5c
pools ok-pool bad-pool deb-pool
never ok-pool; never bad-pool
echo "$NOW" > "$FLY/deb-pool.baked-at"      # fresh: inside the debounce window
fixture ok-pool  0 0 "#9 2.1 warm-bake: repo sha $SHA40
#9 2.4 added 1450 packages in 41s"
fixture bad-pool 1 0 'ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 137'
fixture deb-pool 0 0
commit; KNOB=30 run
EXPECT=$(jq -Sc . <<EOF
{"bad-pool":{"status":"fail","reason":"oom","warm_sha":"","warm":"","capture":""},
 "deb-pool":{"status":"debounced","reason":"","warm_sha":"","warm":"","capture":""},
 "ok-pool":{"status":"ok","reason":"","warm_sha":"$SHA40","warm":"","capture":""}}
EOF
)
GOT=$(jq -Sc '.pools|map_values(del(.phases))' "$H/state/fleet-propagate.json" 2>/dev/null)
[ "$GOT" = "$EXPECT" ] && ok || bad "§E the record must be {status,reason,warm_sha,warm,capture} per pool
  expected: $EXPECT
  got:      $GOT"
PH=$(jq -r '[.pools["ok-pool"].phases, .pools["bad-pool"].phases, .pools["deb-pool"].phases]|map(tostring)|join("|")' "$H/state/fleet-propagate.json" 2>/dev/null)
case "$PH" in build=*,total=*'|'build=*,total=*'|') ok ;; *) bad "§E phases: a bake records build=..,total=.., a debounced pool records \"\" (got '$PH')" ;; esac
[ -f "$FLY/ok-pool.baked-at" ] && ok || bad "§E an ok bake must still stamp state/fly/ok-pool.baked-at"
[ ! -f "$FLY/bad-pool.baked-at" ] && ok || bad "§E a failed bake must never be stamped"

# ══ §F the log line and the alert name the reason per failed pool ════════════
pools project-4 project-3 good-pool
never project-4; never project-3; never good-pool
fixture project-4 0 5 'Creating an optimized production build ...'
fixture project-3 1 0 'ERROR: process "/bin/sh -c npm run build" did not complete successfully: exit code: 137'
fixture good-pool 0 0 'ok'
# BH-3680: first-fail paging pinned; the default (warn while a retry is queued) is tests/fleet-propagate.bh-3680-test.sh
commit; PROPAGATE_PAGE_ON_FIRST_FAIL=1 TMO=2 run
[ "$(nalert)" = 1 ] && ok || bad "§F a partly failed run must alert exactly once (got $(nalert))"
grep -q -- '--critical' "$T/alerts" && ok || bad "§F a failed bake must stay critical: $(cat "$T/alerts")"
grep -q 'project-4(timeout)' "$T/alerts" && ok || bad "§F the alert must name the timeout: $(cat "$T/alerts")"
grep -q 'project-3(oom)' "$T/alerts" && ok || bad "§F the alert must name the oom: $(cat "$T/alerts")"
grep -q 'good-pool' "$T/alerts" && bad "§F a pool that worked must not be listed: $(cat "$T/alerts")" || ok
lastlog | grep -q 'failed=' && ok || bad "§F the log line must carry the failures: $(lastlog)"
lastlog | grep -q 'project-4(timeout)' && lastlog | grep -q 'project-3(oom)' && ok \
  || bad "§F the log line must name both reasons: $(lastlog)"
# The one-word class rides WITH the BH-806 why-line, it does not replace it: the
# why-line is keyed on the bare pool name ($WORK/pool-<P>.why), so a reason glued
# into the failed-pool list would look the file up under `project-4(timeout)` and
# print "(no why recorded)" for every failure.
grep -q 'pool project-4: fail — rc=124: ' "$H/logs/fleet-propagate.log" && ok \
  || bad "§F the failed pool must still carry its BH-806 why-line, under its bare name: $(grep 'pool project-4' "$H/logs/fleet-propagate.log")"
grep -q 'pool project-3: fail — rc=1: ERROR: process' "$H/logs/fleet-propagate.log" && ok \
  || bad "§F the why-line must quote the bake's own failing line: $(grep 'pool project-3' "$H/logs/fleet-propagate.log")"
grep -q '(no why recorded)' "$H/logs/fleet-propagate.log" \
  && bad "§F a failed pool with a reason still has a why file: $(grep 'no why recorded' "$H/logs/fleet-propagate.log")" || ok

pools g1 g2
never g1; never g2
fixture g1 0 0; fixture g2 0 0
commit; run
grep -q -- '--critical' "$T/alerts" && bad "§F a clean run is not critical: $(cat "$T/alerts")" || ok
grep -qE '\((timeout|oom|install|builder|build)\)' "$T/alerts" \
  && bad "§F a clean run's alert must carry no reason token: $(cat "$T/alerts")" || ok
grep -q 'failed=' <<<"$(lastlog)" && bad "§F a clean run must print no failed= list: $(lastlog)" || ok

echo "fleet-propagate.bh-1115-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
