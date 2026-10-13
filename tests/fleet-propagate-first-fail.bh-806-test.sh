#!/bin/bash
# tests/fleet-propagate-first-fail.bh-806-test.sh — BH-806 item 5: when a pool
# image fails to bake, logs/fleet-propagate.log must say WHY.
#
# WHAT THIS PINS. Before this change a failed bake wrote the single word `fail`
# into state/fleet-propagate.json and nothing else: `pool-<P>.out` lives in a
# scratch dir on the hub and is overwritten on the next tick, so the only
# durable record of 11 hours of 0/10 rebakes was a count. Now every failed pool
# appends one line to the log naming its rc and the first line of its output
# that says what went wrong, the summary line stays last, and a why-line from a
# previous run never rides into the next one.
#
#   * a failing pool: `pool <P>: fail — rc=<n>: <first failing line>`
#   * a pool that produced no output at all (a timeout kill): `rc=124: (no output)`
#   * the passing pool gets NO line
#   * the alert wording is unchanged (tests/fleet-propagate-test.sh pins it)
#
# The REAL bin/fleet-propagate.sh runs against a scratch $HARNESS with stubbed
# ssh/pgrep/crontab/harness-sync/fly-image-build/lane-alert and a scratch git
# origin, exactly as tests/fleet-propagate-test.sh does.
#
# Run from anywhere: tests/fleet-propagate-first-fail.bh-806-test.sh (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export POOL_IMAGE_MIN_AGE_MIN=0
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS_LANE=test        # a test lane is not act-time fenced
H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin"
cp "$DIR/bin/fleet-propagate.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
echo hub > "$H/state/box-id"

cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha 10.0.0.1
beta     Acme/beta     -                     -          4 box-beta  10.0.0.2
EOF
: > "$H/flags/fly-pool-app-alpha-os"
: > "$H/flags/fly-pool-app-project-6"

# ── stubs ────────────────────────────────────────────────────────────────────
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
echo "cafe123456789"; exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/bin/pgrep"
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/bin/harness-sync.sh"
cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"
exit 0
EOF
# The bake stub speaks in the real bin/fly-image-build.sh's voice: its progress
# lines, then a real failure. `silent` is a `timeout` kill (no output at all),
# `apierr` puts a second failing line AFTER the first so "first" is a real
# assertion and not just "the line that happens to be there".
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
if [ "$1" = "${BAKE_FAIL:-}" ]; then
  case "${BAKE_MODE:-fatal}" in
    silent) exit "${BAKE_RC:-124}" ;;
    apierr) echo "== ensuring app builder-$1 exists =="
            echo "Error: failed to fetch an image or build from source: error rendering push status" >&2
            echo "FATAL: image build/push failed" >&2
            exit 1 ;;
    *)      echo "== ensuring app builder-$1 exists =="
            echo "== building + pushing image to registry.fly.io/builder-$1 =="
            echo "FATAL: image build/push failed" >&2
            exit 1 ;;
  esac
fi
echo "== done: registry.fly.io/builder-$1:deployment-9 pushed =="
exit 0
EOF
chmod +x "$T/bin"/* "$H/bin"/*

# ── a real scratch repo: bare origin + the hub's checkout ────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"
echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
: > "$T/livecron"

commit() { # commit <path> <content>
  mkdir -p "$(dirname "$T/src/$1")"; echo "$2" > "$T/src/$1"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "$1" && git -C "$T/src" push -q origin main
}
run() {
  : > "$T/alerts"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    ALERTS="$T/alerts" LIVE_CRON="$T/livecron" \
    BAKE_FAIL="${BAKE_FAIL:-}" BAKE_MODE="${BAKE_MODE:-fatal}" BAKE_RC="${BAKE_RC:-124}" \
    bash "$H/bin/fleet-propagate.sh" ) > "$T/out" 2>"$T/err"
}
LOG="$H/logs/fleet-propagate.log"
logtail() { tail -5 "$LOG" 2>/dev/null; }

# ── 1. a failing pool says WHY, in the log ──────────────────────────────────
commit bin/run-build.sh "echo v2"
# BH-3680: first-fail paging pinned; the default (warn while a retry is queued) is tests/fleet-propagate.bh-3680-test.sh
PROPAGATE_PAGE_ON_FIRST_FAIL=1 BAKE_FAIL=project-6 run
grep -q 'pool project-6: fail — rc=1: FATAL: image build/push failed' "$LOG" && ok \
  || bad "1: the log must carry project-6's failing line:
$(logtail)"
grep -q 'pool project-6: fail — rc=1: == ensuring' "$LOG" \
  && bad "1: the why-line must be the line that says WHY, not the first line of output:
$(logtail)" || ok
grep -q 'pool alpha-os: fail' "$LOG" && bad "1: a pool that PASSED must get no why-line:
$(logtail)" || ok
grep -q 'images=1/2' "$LOG" && ok || bad "1: the run summary must still be written: $(logtail)"
tail -1 "$LOG" | grep -q 'images=1/2' && ok \
  || bad "1: the summary must stay the LAST line of the run (got: $(tail -1 "$LOG"))"
[ "$(grep -c -- 'pool project-6: fail' "$LOG")" = 1 ] && ok || bad "1: exactly one why-line per failed pool"

# ── 2. exactly one alert, unchanged wording ────────────────────────────────
[ "$(grep -c . "$T/alerts")" = 1 ] && ok || bad "2: exactly one alert per run (got: $(cat "$T/alerts"))"
grep -q -- '--critical' "$T/alerts" && ok || bad "2: a failed bake must stay critical: $(cat "$T/alerts")"
grep -q '1/2 pool images rebaked' "$T/alerts" && ok || bad "2: the alert wording must not change: $(cat "$T/alerts")"
grep -q 'FATAL: image build/push failed' "$T/alerts" \
  && bad "2: the why-line belongs in the log, not in the alert text: $(cat "$T/alerts")" || ok

# ── 2b. the FIRST failing line, not the last ───────────────────────────────
commit bin/run-build.sh "echo v2b"
BAKE_FAIL=project-6 BAKE_MODE=apierr run
grep -q 'pool project-6: fail — rc=1: Error: failed to fetch an image or build from source' "$LOG" && ok \
  || bad "2b: two failing lines must log the FIRST one:
$(logtail)"

# ── 3. a bake killed by the timeout, with no output at all ─────────────────
commit bin/run-build.sh "echo v3"
BAKE_FAIL=project-6 BAKE_MODE=silent BAKE_RC=124 run
grep -q 'pool project-6: fail — rc=124: (no output)' "$LOG" && ok \
  || bad "3: a silent kill must be recorded honestly with its rc:
$(logtail)"

# ── 4. no stale why-line rides into the next run ───────────────────────────
commit bin/run-build.sh "echo v4"
BEFORE=$(grep -c 'pool project-6: fail' "$LOG")
run                                   # everything passes this time
[ "$(grep -c 'pool project-6: fail' "$LOG")" = "$BEFORE" ] && ok \
  || bad "4: a run where every pool passed must add no why-line:
$(logtail)"
grep -q 'images=2/2' "$LOG" && ok || bad "4: the healthy run must record 2/2: $(logtail)"
grep -q -- '--critical' "$T/alerts" && bad "4: a healthy run must not be critical: $(cat "$T/alerts")" || ok

# ── 5. a long failing line is capped WITHOUT an early-exit pipeline ────────
# The helper itself, lifted verbatim by its markers: `printf | head -c 300`
# caps the same 300 bytes but kills the producer, so under the script's own
# `set -o pipefail` pool_first_fail returned 141 on every line over 300 bytes.
# Nothing reads that rc today, which is exactly why it has to be pinned here —
# the next caller that does would drop the why-line for the longest failures.
# The fixture line is past one pipe buffer (64 KB) on purpose: under the cap a
# single short write lands in the buffer before head exits and no signal is
# ever delivered, so a 900-byte line proves nothing. A bake that dumps a whole
# JSON body on one line is exactly this shape.
PFF=$(awk '/^[[:space:]]*# >>> pool-first-fail$/{f=1;next} /^[[:space:]]*# <<< pool-first-fail$/{f=0} f' "$H/bin/fleet-propagate.sh")
[ -n "$PFF" ] && ok || bad "5: the pool-first-fail block was not found — nothing was tested"
printf 'FATAL: %s\n' "$(head -c 200000 /dev/zero | tr '\0' z)" > "$T/long.out"
WHY=$( set -uo pipefail; eval "$PFF"; pool_first_fail "$T/long.out" ); WHY_RC=$?
[ "$WHY_RC" = 0 ] && ok || bad "5: pool_first_fail must not return $WHY_RC on a line longer than the cap"
[ "${#WHY}" = 300 ] && ok || bad "5: the why-line must still be capped at 300 (got ${#WHY})"
[ "${WHY:0:7}" = "FATAL: " ] && ok || bad "5: the cap must keep the START of the line (got: ${WHY:0:20})"

echo "fleet-propagate-first-fail.bh-806-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
