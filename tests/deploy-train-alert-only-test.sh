#!/bin/bash
# tests/deploy-train-alert-only-test.sh — bin/deploy-train.sh with DEPLOY_ROLLBACK=off
# and no DEPLOY_HOOK_URL (a Vercel git-integration project such as project-5).
# Run from anywhere: tests/deploy-train-alert-only-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T" TRAIN_POLLS=2 TRAIN_POLL_SECS=0
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state/deploy-queue/p" "$T/calls"
# a two-commit repo standing in for /root/repos/<project>; origin/main = HEAD
git init -q "$T/repo" && (cd "$T/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two \
  && git init -q --bare "$T/origin.git" && git remote add origin "$T/origin.git" && git push -q origin HEAD:main \
  && git update-ref refs/remotes/origin/main HEAD)
TARGET=$(git -C "$T/repo" rev-parse HEAD); OLD=$(git -C "$T/repo" rev-parse HEAD~1)
export DEPLOY_TRAIN_REPO_DIR="$T/repo"
# shims: fleet-conf answers the repo; curl serves whatever $T/live holds; beat
# and gh record every call (gh must never be reached in alert-only mode).
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
echo "org/repo"
SH
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
echo "$1" >> "$HARNESS/calls/beat"
SH
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
case "$*" in *POST*) echo "hook" >> "$HARNESS/calls/hook";; *) printf '{"sha":"%s"}' "$(cat "$HARNESS/live")";; esac
SH
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"; echo "https://github.com/org/repo/pull/1"
SH
# flock is Linux-only; the train's slot lock is not under test here.
cat > "$T/bin/flock" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
printf 'VERSION_URL=https://example.test/api/internal/version\nDEPLOY_ROLLBACK=off\n' > "$T/env/p.env"
run() { "$DIR/bin/deploy-train.sh" p; }

# 1. production still serves the OLD sha after the polls: alert, batch left
#    queued, no hook (none configured), no revert PR, exit 0.
printf '%s' "$OLD" > "$T/live"
printf '%s build-x\n' "$TARGET" > "$T/state/deploy-queue/p/$(( $(date +%s) - 1800 ))-${TARGET:0:8}"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "alert-only should exit 0 (rc=$RC)"
grep -q "DEPLOY TRAIN: production is NOT serving ${TARGET:0:8}" "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "ALERTS.log should carry the NOT serving line (got: $(cat "$T/logs/ALERTS.log" 2>/dev/null))"
grep -q '"kind":"fleet_alert"' "$T/calls/beat" 2>/dev/null && grep -q "deploy-stale:p:${TARGET:0:8}" "$T/calls/beat" && ok || bad "fleet_alert beat expected (got: $(cat "$T/calls/beat" 2>/dev/null))"
[ "$(ls "$T/state/deploy-queue/p" | wc -l)" -eq 1 ] && ok || bad "batch must stay queued in alert-only mode"
[ ! -f "$T/calls/gh" ] && ok || bad "no revert PR must be opened (gh called: $(cat "$T/calls/gh"))"
[ ! -f "$T/calls/hook" ] && ok || bad "no deploy hook must fire when DEPLOY_HOOK_URL is unset"
grep -qE "queued [0-9]+m\) — DEPLOY_ROLLBACK=off" "$T/logs/deploy-train.log" && ok || bad "train log should say alert-only (got: $(cat "$T/logs/deploy-train.log"))"
[ -n "$(git -C "$T/repo" branch --list 'rollback/*')" ] && bad "no rollback branch expected" || ok

# 2. production now serves the merge: VERIFIED, queue cleared, no alert.
rm -f "$T/calls/beat" "$T/logs/ALERTS.log"
printf '%s' "$TARGET" > "$T/live"
run; RC=$?
[ "$RC" -eq 0 ] && grep -q "train VERIFIED live at ${TARGET:0:8}" "$T/logs/deploy-train.log" && ok || bad "verified path (rc=$RC log: $(tail -1 "$T/logs/deploy-train.log"))"
[ -z "$(ls -A "$T/state/deploy-queue/p")" ] && ok || bad "queue should be cleared after verify"
[ ! -f "$T/calls/beat" ] && ok || bad "no alert on a verified deploy"

# 3. DEPLOY_ROLLBACK unset (fleet default): the revert path is taken — gh is
#    reached for the PR. Pin the default so the OS fleet keeps its behaviour.
printf 'VERSION_URL=https://example.test/api/internal/version\n' > "$T/env/p.env"
printf '%s' "$OLD" > "$T/live"
printf '%s build-y\n' "$TARGET" > "$T/state/deploy-queue/p/$(date +%s)-${TARGET:0:8}"
run >/dev/null 2>&1
grep -q "initiating automatic rollback" "$T/logs/deploy-train.log" && ok || bad "default mode must still roll back"

# 5. SELF-SOURCED: queue EMPTY, production serves OLD, origin/main is TARGET
#    (a merge nobody enqueued — a session's watcher armed it): the train
#    enqueues the head itself and the alert fires exactly as for an enqueued
#    merge. Then: production AHEAD of git (ancestry) and an empty queue = inert.
printf 'VERSION_URL=https://example.test/api/internal/version\nDEPLOY_ROLLBACK=off\n' > "$T/env/p.env"
rm -f "$T/state/deploy-queue/p"/* "$T/logs/ALERTS.log" "$T/logs/deploy-train.log"
printf '%s' "$OLD" > "$T/live"
SELF_SOURCE_MIN_AGE_MIN=0 run; RC=$?
[ "$RC" -eq 0 ] && grep -q "self-sourced: production serves ${OLD:0:8}, origin/main is ${TARGET:0:8}" "$T/logs/deploy-train.log" 2>/dev/null && ok || bad "empty queue + main ahead of prod → self-sourced departure (rc=$RC log=$(cat "$T/logs/deploy-train.log" 2>/dev/null))"
grep -q "DEPLOY TRAIN: production is NOT serving ${TARGET:0:8}" "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "self-sourced departure must alert like an enqueued one (got: $(cat "$T/logs/ALERTS.log" 2>/dev/null))"
[ "$(ls "$T/state/deploy-queue/p" | wc -l)" -eq 1 ] && grep -q "self-sourced" "$T/state/deploy-queue/p"/* && ok || bad "self-sourced entry must stay queued for the next departure"
rm -f "$T/state/deploy-queue/p"/* "$T/logs/deploy-train.log"
printf '%s' "$OLD" > "$T/live"
run; RC=$?   # default min age (20 min): a head committed seconds ago is not yet stale
[ "$RC" -eq 0 ] && [ ! -f "$T/logs/deploy-train.log" ] && [ -z "$(ls -A "$T/state/deploy-queue/p")" ] && ok || bad "a head younger than the min age must not self-source (rc=$RC)"
printf '%s' "$TARGET" > "$T/live"
SELF_SOURCE_MIN_AGE_MIN=0 run; RC=$?
[ "$RC" -eq 0 ] && [ ! -f "$T/logs/deploy-train.log" ] && [ -z "$(ls -A "$T/state/deploy-queue/p")" ] && ok || bad "production at origin/main + empty queue must be inert (rc=$RC)"

# 4. no VERSION_URL at all: the train is inert (exit 0, nothing written).
printf '' > "$T/env/p.env"; rm -f "$T/logs/deploy-train.log"
run; RC=$?
[ "$RC" -eq 0 ] && [ ! -f "$T/logs/deploy-train.log" ] && ok || bad "no VERSION_URL should be inert (rc=$RC)"

echo "deploy-train-alert-only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
