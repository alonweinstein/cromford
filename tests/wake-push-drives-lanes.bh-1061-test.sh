#!/bin/bash
# tests/wake-push-drives-lanes.bh-1061-test.sh — push wakes drive rebase-train,
# fleet-propagate, and prompt-eval through the real wake-loop.sh and class file.
#
# Since BH-2637 the loop runs on EVERY box and claims its own rows from the stub
# worker (tests/lib/wake-claim-stub.sh) through the REAL jobs-client; it never
# ssh's. cromford is `local` (the hub, box-hub: fleet-propagate and
# prompt-eval are hub lanes); project-3 is box-project-3-2's, so ITS loop
# launches rebase-train locally and the hub never takes project-3's push row.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-push-drives-lanes.bh-1061-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T"
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls" "$T/fakebin"
mkdir -p "$T/harness-checkout/.git"
export HARNESS_CHECKOUT="$T/harness-checkout"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0

# Real loop and lib.
cp "$DIR/bin/wake-loop.sh"   "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
# Copy the class file if it exists (test-first: absent until the feature lands).
[ -f "$DIR/bin/lib/wake-class-push.sh" ] && cp "$DIR/bin/lib/wake-class-push.sh" "$T/bin/lib/wake-class-push.sh"

# BH-2637: the REAL jobs-client — wakes_claim / wake_cursor_* /
# wake_cooldown_take go to the stub worker, and flag_active answers from
# flags/<name> when the flag sync gets `{}` back (the curl below serves that).
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
wcs_install "$T/bin"

# Registry: cromford on the hub, project-3 on a remote box.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'cromford\nproject-3\n'; exit 0; }
case "$1/$2" in
  cromford/repo) echo example-org/cromford ;;
  project-3/repo)       echo example-org/project-3 ;;
  cromford/box)  echo local ;;
  project-3/box)        echo box-project-3-2 ;;
  cromford/board_prefix) echo /api/board ;;
  project-3/board_prefix)       echo /api/feature-board ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"

# box-for uses the registry: the REAL box-for.sh, box-name.sh and hub-box.sh,
# plus the rendered lane registry off-hub launches are checked against (BH-2637).
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }
HUB=box-hub project-3BOX=box-project-3-2

# No Blocked-by expansion for these tests.
cat > "$T/bin/unblocked-children.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/unblocked-children.sh"

# Recorders for legacy lanes (must stay quiet for push-only drains).
for s in merge-conductor deploy-train postmerge-qa run-triage; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
SH
  chmod +x "$T/bin/$s.sh"
done

# Recorders for the lanes the push class drives.
# Each also notes its WAKE_LAUNCH in calls/<lane>.env.
for s in rebase-train.sh fleet-propagate.sh prompt-eval.sh; do
  cat > "$T/bin/$s" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/${s%.sh}"
echo "WAKE_LAUNCH=\${WAKE_LAUNCH:-}" >> "\$HARNESS/calls/${s%.sh}.env"
SH
  chmod +x "$T/bin/$s"
done

# curl: the stub worker's wake routes (BH-2637), else `{}`.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
chmod +x "$T/bin/curl"

# ssh records its argv — nothing may call it any more (BH-2637).
cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/ssh"
SH
chmod +x "$T/bin/ssh"

# crontab: lane_runs_here's real dependency is `crontab -l` (the root user
# crontab), not an env var — same stub idiom as
# tests/wake-classes-hook.bh-1034-test.sh's case 6/7.
cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
[ "${1:-}" = "-l" ] || exit 1
[ -r "$HARNESS/crontab.out" ] || exit 1
cat "$HARNESS/crontab.out"
SH
chmod +x "$T/bin/crontab"

# gh is never called by the push class, but the loop's closed_diff may call it.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
echo '[]'
SH
chmod +x "$T/bin/gh"

# setsid makes launches synchronous so the test can assert immediately.
cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$T/bin/setsid"

# git controls prompts_touched: diff-tree prints the names we want.
cat > "$T/fakebin/git" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/calls/git"
# Strip a leading -C <dir> so we can match the real subcommand.
shift_n=0
if [ "$1" = "-C" ]; then shift_n=2; fi
set -- "${@:$((shift_n + 1))}"
# cat-file check: accept any sha that is not UNKNOWN.
if [ "$1" = "cat-file" ] && [ "${3:-}" = "UNKNOWN^{commit}" ]; then
  exit 1
fi
# diff-tree: name the changed files for the requested sha.
if [ "$1" = "diff-tree" ] && [ "${5:-}" = "PROMPTS" ]; then
  echo "prompts/triage.md"
elif [ "$1" = "diff-tree" ]; then
  echo "bin/x.sh"
fi
exit 0
SH
chmod +x "$T/fakebin/git"

W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-19T11:39:04Z"}' "$1" "${2:-example-org/project-3}" "$3" "${4:-key}" "${5:-push}"; }
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs"
}
settle() {
  local prev="" cur i
  for i in $(seq 1 12); do
    sleep 0.25
    cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
# run [box] — the loop as <box> (default: the hub).
run() { BOX_NAME="${1:-$HUB}" PATH="$T/fakebin:$T/bin:$PATH" "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
LOG() { cat "$T/logs/wake-loop.log" 2>/dev/null; }
# own_cursor0 — project-3-2's own cursor row at 0, so a run after the hub's claims
# from 0 instead of adopting the hub's watermark.
own_cursor0() { mkdir -p "$T/state/wcs"; printf 0 > "$T/state/wcs/cursor.$project-3BOX"; }
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# 1. flag on + crontab names rebase-train locally -> one local call, no ssh
#    (BH-2637: on project-3's own box, the one whose crontab that is)
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
printf '%s\n' '* * * * * /root/harness/bin/rebase-train.sh project-3' > "$T/crontab.out"
wakes "$(W 1 example-org/project-3 push abc1111)"
run "$project-3BOX"
[ "$(calls rebase-train)" = 1 ] && ok || bad "local rebase-train must be called once (got $(calls rebase-train))"
[ "$(calls ssh)" = 0 ] && ok || bad "local rebase-train must not ssh (got $(calls ssh))"
grep -qx 'project-3' "$T/calls/rebase-train" && ok || bad "local rebase-train argv must be 'project-3'"

# ---------------------------------------------------------------------------
# 2. flag on + crontab does NOT name it: the hub (handed the row by a
#    mis-filtering worker) drops it — no launch, no ssh — and project-3's own box
#    launches rebase-train locally with WAKE_LAUNCH=1 (BH-2637: was one ssh call)
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
printf '%s\n' '* * * * * /root/harness/bin/something-else.sh project-3' > "$T/crontab.out"
wakes "$(W 2 example-org/project-3 push abc2222)"
CLAIM_ALL=1 run "$HUB"
[ "$(calls rebase-train)" = 0 ] && ok || bad "remote rebase-train must not run locally (got $(calls rebase-train))"
# TEST-CHANGE BH-2637: the hub never reaches another box's rebase-train — the drop line, and no ssh (was: ssh once).
LOG | grep -q 'another box owns the repo — example-org/project-3' && [ "$(calls ssh)" = 0 ] && ok \
  || bad "the hub must drop project-3's push row and not ssh (ssh=$(calls ssh)): $(LOG | tail -5)"
own_cursor0
run "$project-3BOX"
# TEST-CHANGE BH-2637: WAKE_LAUNCH=1 rides the owning box's local launch, not an ssh argv.
grep -qx 'WAKE_LAUNCH=1' "$T/calls/rebase-train.env" 2>/dev/null && [ "$(calls ssh)" = 0 ] && ok \
  || bad "the owning box's rebase-train must run with WAKE_LAUNCH=1, no ssh (ssh=$(calls ssh))"
# TEST-CHANGE BH-2637: script and project are the owning box's own launch (once, argv project-3), not an ssh command.
[ "$(calls rebase-train)" = 1 ] && grep -qx 'project-3' "$T/calls/rebase-train" && ok \
  || bad "the owning box must launch rebase-train.sh project-3 once (got $(calls rebase-train))"

# ---------------------------------------------------------------------------
# 3. cromford push -> fleet-propagate once
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
wakes "$(W 3 example-org/cromford push def3333 push)"
run
[ "$(calls fleet-propagate)" = 1 ] && ok || bad "cromford push must call fleet-propagate once (got $(calls fleet-propagate))"
[ "$(calls prompt-eval)" = 0 ] && ok || bad "non-prompts push must not call prompt-eval (got $(calls prompt-eval))"

# ---------------------------------------------------------------------------
# 4. cromford push touching prompts -> prompt-eval --cron once
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
wakes "$(W 4 example-org/cromford push PROMPTS push)"
run
[ "$(calls prompt-eval)" = 1 ] && ok || bad "prompts push must call prompt-eval once (got $(calls prompt-eval))"
grep -qx -- '--cron' "$T/calls/prompt-eval" && ok || bad "prompt-eval argv must be exactly '--cron' (got '$(cat "$T/calls/prompt-eval" 2>/dev/null)')"

# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 6. missing checkout or unknown sha logs one line, no prompt-eval
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
wakes "$(W 8 example-org/cromford push UNKNOWN push)"
run
[ "$(calls prompt-eval)" = 0 ] && ok || bad "unknown sha must not call prompt-eval (got $(calls prompt-eval))"
[ "$(calls fleet-propagate)" = 1 ] && ok || bad "unknown sha must still call fleet-propagate (got $(calls fleet-propagate))"

# ---------------------------------------------------------------------------
# 7. a push for project-3 produces no fleet-propagate and no prompt-eval
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
wakes "$(W 9 example-org/project-3 push abc9999 push)"
run "$project-3BOX"
[ "$(calls fleet-propagate)" = 0 ] && ok || bad "project-3 push must not call fleet-propagate (got $(calls fleet-propagate))"
[ "$(calls prompt-eval)" = 0 ] && ok || bad "project-3 push must not call prompt-eval (got $(calls prompt-eval))"

# ---------------------------------------------------------------------------
# 8. flag off -> none of the new lanes are launched
# ---------------------------------------------------------------------------
reset
wakes "$(W 10 example-org/project-3 push abc1010 push)" "$(W 11 example-org/cromford push def1010 push)"
run "$HUB"
own_cursor0
run "$project-3BOX"
[ "$(calls rebase-train)" = 0 ] && ok || bad "flag off: no rebase-train (got $(calls rebase-train))"
[ "$(calls fleet-propagate)" = 0 ] && ok || bad "flag off: no fleet-propagate (got $(calls fleet-propagate))"
[ "$(calls prompt-eval)" = 0 ] && ok || bad "flag off: no prompt-eval (got $(calls prompt-eval))"

# ---------------------------------------------------------------------------
# 9. global wake-lanes-off -> classes suppressed, legacy lanes still run
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push" "$T/flags/wake-lanes-off"
wakes "$(W 12 example-org/project-3 push abc1212 push)"
run "$project-3BOX"
[ "$(calls rebase-train)" = 0 ] && ok || bad "wake-lanes-off must suppress rebase-train (got $(calls rebase-train))"
[ "$(calls merge-conductor)" = 0 ] && ok || bad "wake-lanes-off must not suppress legacy lanes when no pr wake (got $(calls merge-conductor))"

# ---------------------------------------------------------------------------
# --- second-half helpers: real scripts need the backstop lib in $T/bin/lib ---
mkdir -p "$T/bin" "$T/bin/lib"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
flag_active() { [ -f "${HARNESS:-/root/harness}/flags/${1:-}" ]; }
SH
chmod +x "$T/bin/jobs-client.sh"

# The real script looks at $HARNESS_CHECKOUT (default /root/harness-checkout).
export HARNESS_CHECKOUT="$T/harness-checkout"

# 10. second half: real fleet-propagate.sh flag on + fresh stamp -> skip, no fetch
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
mkdir -p "$T/state/wake-ran" "$T/locks"
printf '%s' "$(date +%s)" > "$T/state/wake-ran/fleet-propagate-fleet"
mkdir -p "$T/harness-checkout/.git"
# The script checks -d .git, then resolves NEW; with no origin/main it exits 1.
# We only care that it does not call git fetch before exiting.
( PATH="$T/fakebin:$PATH" HARNESS="$T" "$DIR/bin/fleet-propagate.sh" ) >/dev/null 2>&1 || true
! grep -q 'fetch' "$T/calls/git" 2>/dev/null && ok || bad "fresh stamp must skip before git fetch"

# ---------------------------------------------------------------------------
# 11. second half: real fleet-propagate.sh with WAKE_LAUNCH=1 -> runs and re-stamps
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-push"
mkdir -p "$T/state/wake-ran" "$T/locks"
old=$(date +%s); printf '%s' "$(( old - 1000 ))" > "$T/state/wake-ran/fleet-propagate-fleet"
before=$old
mkdir -p "$T/harness-checkout/.git"
( PATH="$T/fakebin:$PATH" HARNESS="$T" WAKE_LAUNCH=1 "$DIR/bin/fleet-propagate.sh" ) >/dev/null 2>&1 || true
new=$(cat "$T/state/wake-ran/fleet-propagate-fleet" 2>/dev/null || echo 0)
[ "$new" -ge "$before" ] && ok || bad "WAKE_LAUNCH=1 must refresh the fleet-propagate stamp (before=$before initial=$((before-1000)) new=$new)"

# ---------------------------------------------------------------------------
# 12. the dispatched triple: remote_launch (label, project, script, args) and
# launch (label, script, args) argv, exactly.
#
# BH-1351: this case used to run the real bin/rebase-train.sh with a fresh
# backstop stamp and then assert `ok` unconditionally — a case that could not
# fail. It could not observe the backstop either, because rebase-train.sh
# hardcodes H=/root/harness and /root/repos/$PROJECT and never looks at
# $HARNESS, so the scratch tree was invisible to it. What IS observable from
# here is the argv wc_push_dispatch hands each launcher, and that is what the
# class owns: get the order of remote_launch's (label, project, script) wrong
# and a lane runs on the wrong box with the wrong argument.
# ---------------------------------------------------------------------------
reset
PATH="$T/fakebin:$PATH"
H="$T"; SELF="$T/bin"
. "$DIR/bin/lib/wake-class-push.sh"
cooled() { return 0; }
launch() { echo "$*" >> "$T/calls/dispatch-launch"; }
remote_launch() { echo "$*" >> "$T/calls/dispatch-remote"; }
wc_push_row project-3 push k1 push example-org/project-3 1
wc_push_row cromford push PROMPTS push example-org/cromford 2
wc_push_dispatch
[ "$(calls dispatch-remote)" = 2 ] && ok || bad "12 dispatch must remote_launch once per pushed project (got $(calls dispatch-remote))"
grep -qx 'rebase-train\[project-3\] project-3 rebase-train.sh project-3' "$T/calls/dispatch-remote" \
  && ok || bad "12 remote_launch argv must be 'rebase-train[project-3] project-3 rebase-train.sh project-3' (got '$(tr '\n' '|' < "$T/calls/dispatch-remote" 2>/dev/null)')"
grep -qx 'rebase-train\[cromford\] cromford rebase-train.sh cromford' "$T/calls/dispatch-remote" \
  && ok || bad "12 remote_launch argv must be 'rebase-train[cromford] cromford rebase-train.sh cromford' (got '$(tr '\n' '|' < "$T/calls/dispatch-remote" 2>/dev/null)')"
[ "$(calls dispatch-launch)" = 2 ] && ok || bad "12 a prompts push must launch fleet-propagate AND prompt-eval (got $(calls dispatch-launch))"
grep -qx "push\[cromford\] fleet-propagate $T/bin/fleet-propagate.sh" "$T/calls/dispatch-launch" \
  && ok || bad "12 fleet-propagate launch argv wrong (got '$(tr '\n' '|' < "$T/calls/dispatch-launch" 2>/dev/null)')"
grep -qx "push\[cromford\] prompt-eval $T/bin/prompt-eval.sh --cron" "$T/calls/dispatch-launch" \
  && ok || bad "12 prompt-eval launch argv wrong (got '$(tr '\n' '|' < "$T/calls/dispatch-launch" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# 13. accumulators reset after dispatch (round-4): WC_PUSH_PROJECTS and
# WC_PUSH_BH_SHA must not survive their own dispatch call, or a later
# non-empty drain of ANY class (drain() calls every armed class's dispatch
# once per non-empty poll, not just the class whose row triggered it — see
# bin/wake-loop.sh's WAKE_CLASSES loop) re-fires every stale project forever.
# Exercises the class file's functions directly with cooled()/launch()/
# remote_launch() stubbed, so the assertion is not masked by cooled's own
# real cooldown window the way a second real wake-loop.sh drain would be.
# ---------------------------------------------------------------------------
reset
PATH="$T/fakebin:$PATH"
H="$T"; SELF="$T/bin"
. "$DIR/bin/lib/wake-class-push.sh"
cooled() { return 0; }
launch() { echo "$*" >> "$T/calls/dispatch-launch"; }
remote_launch() { echo "$*" >> "$T/calls/dispatch-remote"; }
wc_push_row project-3 push k1 push example-org/project-3 1
wc_push_row cromford push k2 push example-org/cromford 2
wc_push_dispatch
[ "$(calls dispatch-remote)" = 2 ] && ok || bad "first dispatch must remote_launch rebase-train once per project (got $(calls dispatch-remote))"
[ "$(calls dispatch-launch)" = 1 ] && ok || bad "first dispatch must launch fleet-propagate once for the cromford push (got $(calls dispatch-launch))"
[ -z "$WC_PUSH_PROJECTS" ] && ok || bad "WC_PUSH_PROJECTS must reset after dispatch (got '$WC_PUSH_PROJECTS')"
[ -z "$WC_PUSH_BH_SHA" ] && ok || bad "WC_PUSH_BH_SHA must reset after dispatch (got '$WC_PUSH_BH_SHA')"
before_remote=$(calls dispatch-remote); before_launch=$(calls dispatch-launch)
wc_push_dispatch
[ "$(calls dispatch-remote)" = "$before_remote" ] && ok || bad "empty dispatch must not re-fire rebase-train (got $(calls dispatch-remote), was $before_remote)"
[ "$(calls dispatch-launch)" = "$before_launch" ] && ok || bad "empty dispatch must not re-fire fleet-propagate/prompt-eval (got $(calls dispatch-launch), was $before_launch)"

# ---------------------------------------------------------------------------
echo "wake-push-drives-lanes.bh-1061-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
