#!/bin/bash
# tests/warm-bake-guard-test.sh — fly warm-bake dependency-install guard and
# fleet-propagate's honest reporting for project-6.
#
# WHAT THIS PINS:
#   * fly/warm-bake.sh skips dependency install when a repo has no package
#     manifest, prints one skip line, and exits 0.
#   * It picks the right install command for pnpm, npm ci, and plain npm.
#   * bin/fleet-propagate.sh no longer special-cases project-6: rc=0 is ok,
#     rc!=0 is fail, and "known-fail" never reaches the record or the alert.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s) # one wall-clock read for deterministic fixtures

# The fleet-propagate test touches a scratch bare repo on main. In the execute
# lane the act-time guard fences pushes to main; a test lane is not guarded.
export HARNESS_LANE=test

mkdir -p "$T/fakebin" "$T/fixtures" "$T/harness/bin" "$T/harness/logs" \
         "$T/harness/state" "$T/harness/locks" "$T/harness/flags"
export PATH="$T/fakebin:$PATH"

# ══ 1. warm-bake.sh install guard ════════════════════════════════════════════
cat > "$T/fakebin/npm" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_CALLS"
exit "${NPM_RC:-0}"
STUB
cat > "$T/fakebin/corepack" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PNPM_CALLS"
exit "${PNPM_RC:-0}"
STUB
chmod +x "$T/fakebin"/*

NPM_CALLS="$T/npm.calls"; PNPM_CALLS="$T/pnpm.calls"
export NPM_CALLS PNPM_CALLS
: > "$NPM_CALLS"; : > "$PNPM_CALLS"

run_warm_bake() { # run_warm_bake <fixture-dir> [env-assignments...]
  local d="$1"; shift
  ( cd "$d"; env "$@" bash "$DIR/fly/warm-bake.sh" "$(pwd)" )
}

mkdir -p "$T/fixtures/no-manifest"
OUT=$(run_warm_bake "$T/fixtures/no-manifest" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "no-manifest fixture must exit 0 (rc=$RC)"
grep -q "warm-bake: no package manifest in .*no-manifest, skipping install" <<<"$OUT" \
  && ok || bad "no-manifest fixture must print the skip line (got: $OUT)"
[ ! -s "$NPM_CALLS" ] && ok || bad "no-manifest fixture must run no install command"
[ ! -s "$PNPM_CALLS" ] && ok || bad "no-manifest fixture must run no pnpm command"

mkdir -p "$T/fixtures/package-json-only"; echo '{}' > "$T/fixtures/package-json-only/package.json"
: > "$NPM_CALLS"
OUT=$(run_warm_bake "$T/fixtures/package-json-only" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "package.json-only fixture must exit with stub rc 0 (rc=$RC)"
grep -q '^install$' "$NPM_CALLS" && ok \
  || bad "package.json-only fixture must run npm install (got: $(cat "$NPM_CALLS"))"

: > "$NPM_CALLS"
OUT=$(run_warm_bake "$T/fixtures/package-json-only" NPM_RC=3 2>&1); RC=$?
[ "$RC" = 3 ] && ok || bad "package.json-only fixture must propagate install rc (rc=$RC)"

mkdir -p "$T/fixtures/npm-lock"; echo '{}' > "$T/fixtures/npm-lock/package.json"; : > "$T/fixtures/npm-lock/package-lock.json"
: > "$NPM_CALLS"
OUT=$(run_warm_bake "$T/fixtures/npm-lock" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "package-lock.json fixture must exit 0 (rc=$RC)"
grep -q '^ci$' "$NPM_CALLS" && ok \
  || bad "package-lock.json fixture must run npm ci (got: $(cat "$NPM_CALLS"))"

mkdir -p "$T/fixtures/pnpm-lock"; echo '{}' > "$T/fixtures/pnpm-lock/package.json"; : > "$T/fixtures/pnpm-lock/pnpm-lock.yaml"
: > "$PNPM_CALLS"
OUT=$(run_warm_bake "$T/fixtures/pnpm-lock" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "pnpm-lock.yaml fixture must exit 0 (rc=$RC)"
grep -q '^pnpm install --frozen-lockfile$' "$PNPM_CALLS" && ok \
  || bad "pnpm-lock.yaml fixture must run corepack pnpm install --frozen-lockfile (got: $(cat "$PNPM_CALLS"))"

# ══ 2. fleet-propagate.sh no longer tolerates project-6 warm-bake failures ═══
H="$T/harness"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
: > "$H/state/box-id"

cat > "$H/fleet.conf" <<'EOF'
project-6 example-org/project-6-runtime - - 3 box-project-6-1 10.0.0.6
EOF
: > "$H/flags/fly-pool-app-project-6"

cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
echo "cafe123456789"; exit 0
STUB
cat > "$T/fakebin/pgrep" <<'STUB'
#!/bin/bash
[ -n "${PGREP_HIT:-}" ] && { echo 4242; exit 0; }
exit 1
STUB
cat > "$T/fakebin/crontab" <<'STUB'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
cp "$1" "$INSTALLED_CRON"; exit 0
STUB
cat > "$H/bin/harness-sync.sh" <<'STUB'
#!/bin/bash
echo "synced (stub)"; exit 0
STUB
cat > "$H/bin/fly-image-build.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
[ "$1" = "${BAKE_FAIL:-}" ] && exit 1
exit 0
STUB
cat > "$H/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"
exit 0
STUB
chmod +x "$T/fakebin"/* "$H/bin"/*

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"
echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"

commit() {
  mkdir -p "$(dirname "$T/src/$1")"; echo "$2" > "$T/src/$1"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "$1" && git -C "$T/src" push -q origin main
}
jsonq() { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }

run_propagate() {
  # POOL_IMAGE_MIN_AGE_MIN=0 is the documented per-merge mode: this section
  # bakes project-6 twice in a row on purpose, and BH-821's debounce would skip
  # the second one. The debounce has its own suite.
  : > "$T/ssh.calls"; : > "$T/bake.calls"; : > "$T/alerts"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" POOL_IMAGE_MIN_AGE_MIN=0 \
    FLEET_PROPAGATE_PATH="$T/fakebin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    BAKE_FAIL="${BAKE_FAIL:-}" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out" 2>"$T/err"
}

printf '2,12 * * * * /root/harness/bin/run-triage.sh project-6\n' > "$T/livecron"

commit bin/run-build.sh "echo v2"
run_propagate
[ "$(jsonq '.pools["project-6"].status')" = "ok" ] && ok \
  || bad "project-6 rc=0 must record ok (got $(jsonq '.pools["project-6"].status'))"
[ -s "$T/alerts" ] && ok || bad "project-6 rc=0 must still produce exactly one alert"
grep -q -- '--critical' "$T/alerts" && bad "project-6 rc=0 must not be critical: $(cat "$T/alerts")" || ok
grep -q 'known-fail' "$T/alerts" && bad "project-6 rc=0 alert must not contain known-fail" || ok

commit bin/run-build.sh "echo v3"
# BH-3680: a failed bake with a retry QUEUED is now a warn (it usually heals on
# the next tick). This case pins the other half of the rule, "a failure that
# will NOT be retried pages critical", so it turns retries off.
POOL_BAKE_RETRY_MAX=0 BAKE_FAIL=project-6 run_propagate
[ "$(jsonq '.pools["project-6"].status')" = "fail" ] && ok \
  || bad "project-6 rc=1 must record fail (got $(jsonq '.pools["project-6"].status'))"
grep -q -- '--critical' "$T/alerts" && ok \
  || bad "project-6 rc=1 must make the run critical: $(cat "$T/alerts")"
grep -q 'known-fail' "$T/alerts" && bad "project-6 failure alert must not say known-fail" || ok
grep -q 'known-fail' "$H/logs/fleet-propagate.log" && bad "log must not contain known-fail" || ok
[ "$(jsonq '.pools["project-6"].status')" != "known-fail" ] && ok \
  || bad "state must not record known-fail for project-6"

echo "warm-bake-guard-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
