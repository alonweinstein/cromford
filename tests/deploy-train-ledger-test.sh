#!/bin/bash
# tests/deploy-train-ledger-test.sh — the deploy train's DURABLE record.
#
# WHAT IS UNDER TEST. Not that the train still works (deploy-train-alert-only
# covers that) but that its two terminal outcomes now leave a row something
# other than this box can read. Until this, the only proof that production ever
# served a merged sha was a line in logs/deploy-train.log, so DORA's lead time
# stopped at "merged" and the train's own success rate was unqueryable.
#
# The properties pinned here are the ones whose failure is SILENT:
#   * the VERIFIED branch writes kind=deploy, key=<slug>@<sha production
#     serves>, status verified — with the batch's PR urls in the detail, or the
#     DORA join has nothing to attach a lead time to;
#   * the FAILED-verify branch writes a `failed` row carrying what production
#     actually served, so a train that never arrived is distinguishable from a
#     train that never ran;
#   * the write is FAIL-OPEN: with no jobs-client.sh on the box, the train's
#     behaviour is what it was before this change.
# Run from anywhere: tests/deploy-train-ledger-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T" TRAIN_POLLS=2 TRAIN_POLL_SECS=0
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state/deploy-queue/p" "$T/calls" "$T/builds/b1"
# a two-commit repo standing in for /root/repos/<project>; origin/main = HEAD
git init -q "$T/repo" && (cd "$T/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two \
  && git init -q --bare "$T/origin.git" && git remote add origin "$T/origin.git" && git push -q origin HEAD:main \
  && git update-ref refs/remotes/origin/main HEAD)
TARGET=$(git -C "$T/repo" rev-parse HEAD); OLD=$(git -C "$T/repo" rev-parse HEAD~1)
export DEPLOY_TRAIN_REPO_DIR="$T/repo"

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
# The ledger stub records kind/key/status/detail exactly as the train passes them.
JOBS_CLIENT='job_ledger_put() { printf "%s\t%s\t%s\t%s\n" "${1:-}" "${2:-}" "${3:-}" "${4:-}" >> "$HARNESS/calls/ledger"; }'
printf '%s\n' "$JOBS_CLIENT" > "$T/bin/jobs-client.sh"
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
printf 'VERSION_URL=https://example.test/api/internal/version\nDEPLOY_ROLLBACK=off\n' > "$T/env/p.env"
run() { "$DIR/bin/deploy-train.sh" p; }
# A build dir exactly as run-build.sh leaves one: RESULT carries PR_CREATED <url>.
echo "PR_CREATED https://github.com/org/repo/pull/77" > "$T/builds/b1/RESULT"
enqueue() { printf '%s %s\n' "$TARGET" "$T/builds/b1" > "$T/state/deploy-queue/p/$(( $(date +%s) - 1800 ))-${TARGET:0:8}"; }
LEDGER="$T/calls/ledger"
field() { awk -F'\t' -v n="$1" 'NR==1{print $n}' "$LEDGER" 2>/dev/null; }

# 1. VERIFIED: one deploy row, keyed <slug>@<sha production serves>.
printf '%s' "$TARGET" > "$T/live"; enqueue
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "verified path should exit 0 (rc=$RC)"
[ -f "$LEDGER" ] && [ "$(wc -l <"$LEDGER")" -eq 1 ] && ok || bad "exactly one ledger write expected (got: $(cat "$LEDGER" 2>/dev/null))"
[ "$(field 1)" = "deploy" ] && ok || bad "ledger kind must be 'deploy' (got '$(field 1)')"
[ "$(field 2)" = "org/repo@$TARGET" ] && ok || bad "key must be <slug>@<sha> (got '$(field 2)')"
[ "$(field 3)" = "verified" ] && ok || bad "status must be 'verified' (got '$(field 3)')"
D=$(field 4)
[ "$(jq -r '.project' <<<"$D")" = "p" ] && ok || bad "detail.project (got '$D')"
[ "$(jq -r '.sha' <<<"$D")" = "$TARGET" ] && ok || bad "detail.sha must be what production serves (got '$D')"
jq -e '.verified_at | test("^[0-9]{4}-")' >/dev/null <<<"$D" && ok || bad "detail.verified_at must be an ISO instant (got '$D')"
jq -e '.departure  | test("^[0-9]{4}-")' >/dev/null <<<"$D" && ok || bad "detail.departure must be an ISO instant (got '$D')"
[ "$(jq -r '.prod_url' <<<"$D")" = "https://example.test/api/internal/version" ] && ok || bad "detail.prod_url (got '$D')"
jq -e '.waited_s | type=="number"' >/dev/null <<<"$D" && ok || bad "detail.waited_s must be a number (got '$D')"
[ "$(jq -r '.merges' <<<"$D")" = "1" ] && ok || bad "detail.merges must count the batch (got '$D')"
[ "$(jq -r '.prs[0]' <<<"$D")" = "https://github.com/org/repo/pull/77" ] && ok || bad "detail.prs must carry the departure's PR urls (got '$D')"
[ "$(jq -r '.shas[0]' <<<"$D")" = "$TARGET" ] && ok || bad "detail.shas must carry the queued merge shas (got '$D')"
# The train's own behaviour is untouched by the write.
grep -q "train VERIFIED live at ${TARGET:0:8}" "$T/logs/deploy-train.log" && ok || bad "verified log line still expected"
[ -z "$(ls -A "$T/state/deploy-queue/p")" ] && ok || bad "queue should still be cleared after verify"

# 2. FAILED verify (alert-only): a `failed` row naming what production served.
rm -f "$LEDGER" "$T/calls/beat" "$T/logs/ALERTS.log"
printf '%s' "$OLD" > "$T/live"; enqueue
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "failed-verify path should still exit 0 (rc=$RC)"
[ "$(field 1)" = "deploy" ] && [ "$(field 2)" = "org/repo@$TARGET" ] && ok || bad "failed row keyed on the target sha (got '$(field 2)')"
[ "$(field 3)" = "failed" ] && ok || bad "status must be 'failed' (got '$(field 3)')"
D=$(field 4)
[ "$(jq -r '.live' <<<"$D")" = "$OLD" ] && ok || bad "detail.live must name what production actually served (got '$D')"
jq -e '.reason | test("not serving")' >/dev/null <<<"$D" && ok || bad "detail.reason must say why (got '$D')"
jq -e 'has("verified_at")|not' >/dev/null <<<"$D" && ok || bad "a failed departure must not claim a verified_at (got '$D')"
grep -q "DEPLOY TRAIN: production is NOT serving ${TARGET:0:8}" "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "the alert must still fire"
[ "$(ls "$T/state/deploy-queue/p" | wc -l)" -eq 1 ] && ok || bad "batch must still stay queued in alert-only mode"

# 3. FAIL-OPEN: no jobs-client.sh on the box at all — the train is unchanged.
rm -f "$LEDGER" "$T/bin/jobs-client.sh" "$T/logs/deploy-train.log" "$T/calls/beat"
printf '%s' "$TARGET" > "$T/live"; enqueue
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "a box with no jobs-client.sh must still exit 0 (rc=$RC)"
grep -q "train VERIFIED live at ${TARGET:0:8}" "$T/logs/deploy-train.log" && ok || bad "verify must be unchanged without jobs-client.sh"
[ -z "$(ls -A "$T/state/deploy-queue/p")" ] && ok || bad "queue cleared without jobs-client.sh"
[ ! -f "$LEDGER" ] && ok || bad "no ledger row can exist without a client"
[ ! -f "$T/calls/beat" ] && ok || bad "no alert on a verified deploy, client or not"

# 4. A departure with no readable build dir still records itself (shas, no prs).
printf '%s\n' "$JOBS_CLIENT" > "$T/bin/jobs-client.sh"; chmod +x "$T/bin/jobs-client.sh"
rm -f "$LEDGER" "$T/logs/deploy-train.log"
printf '%s self-sourced\n' "$TARGET" > "$T/state/deploy-queue/p/$(date +%s)-${TARGET:0:8}"
run >/dev/null 2>&1
[ "$(field 3)" = "verified" ] && ok || bad "a self-sourced departure still records (got '$(cat "$LEDGER" 2>/dev/null)')"
D=$(field 4)
[ "$(jq -r '.prs | length' <<<"$D")" = "0" ] && ok || bad "no build dir means no prs, not a broken row (got '$D')"
[ "$(jq -r '.shas[0]' <<<"$D")" = "$TARGET" ] && ok || bad "the sha is recorded even with no build dir (got '$D')"

echo "deploy-train-ledger: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
