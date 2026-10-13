#!/bin/bash
# tests/flag-row-kill-switch.bh-1629-test.sh — BH-1629: a pause_flags ROW for
# automerge-disabled, with no flags/ file on the box, holds every script that
# gates on it: bin/merge-queue.sh, bin/rebase-train.sh, bin/rebase-train-ahead.sh.
#
# Since #1580 the row is the truth and the file its cache (flag_active reconciles
# first), so the documented rollback is `bin/jobs-client.sh flag-set <name> off`,
# not `rm flags/<name>`. This suite pins the reader side of that: each real
# script, run against a stubbed worker, stops on a row alone. Each arm has a
# control (no row, no file) that must get PAST the gate, or the arm proves
# nothing.
#
# No network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 tests/flag-row-kill-switch.bh-1629-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# Fake worker: GET /api/flags/<name> from $ROWS/<name>.json, 404 otherwise.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac; done
case "$METHOD $URL" in
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
exit 1
EOF
cat > "$T/fakebin/git" <<'EOF'
#!/bin/bash
printf 'git %s\n' "$*" >> "$GH_CALLS"
exit 1
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/git"

# mkh <root> — a scratch harness carrying the real client and its modules.
mkh() {
  scratch_rm "$1"
  mkdir -p "$1/bin/lib/jobs" "$1/flags" "$1/state" "$1/logs" "$1/locks" "$1/env" "$1/rows" "$1/repos/proj"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  cp "$DIR/bin/fleet-conf.sh" "$1/bin/"
  cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/gh-pr-list.sh" "$1/bin/lib/"
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$1/bin/lib/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$1/env/global.env"
  printf 'proj example-org/proj https://proj.example /api/board 0 local -\n' > "$1/fleet.conf"
  # The conductor lib is a recorder: its first call past the gate is logged.
  cat > "$1/bin/lib/merge-conductor-lib.sh" <<EOF
mc_queue_enabled() { echo mc_queue_enabled >> "\$GH_CALLS"; return 1; }
mc_pr_view() { echo mc_pr_view >> "\$GH_CALLS"; return 75; }
mc_rest_status() { printf '?'; }
mc_log() { :; }
mc_rebase() { echo mc_rebase >> "\$GH_CALLS"; return 1; }
EOF
  # merge-queue needs a non-empty queue to reach its gate.
  mkdir -p "$1/state/merge-queue/proj"; : > "$1/state/merge-queue/proj/41"
  # rebase-train.sh used to pin H=/root/harness and REPO=/root/repos/…; main now
  # reads HARNESS and REPOS_ROOT (runs sets both), and the rewrite keeps an older
  # copy of the script pointed at scratch too.
  sed -e "s#^H=/root/harness\$#H=$1#" -e "s#^REPO=\"/root/repos/\$PROJECT\"#REPO=\"$1/repos/\$PROJECT\"#" \
    "$DIR/bin/rebase-train.sh" > "$1/bin/rebase-train.sh"
  cp "$DIR/bin/merge-queue.sh" "$DIR/bin/rebase-train-ahead.sh" "$1/bin/"
}

runs() { # runs <harness> <script> — rc to stdout
  local H="$1"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_SECRET=test-secret \
      JOBS_RETRIES=0 JOBS_URL=https://jobs.invalid ROWS="$H/rows" GH_CALLS="$H/gh-calls.txt" \
      REPOS_ROOT="$H/repos"
    bash "$H/bin/$2" proj >/dev/null 2>&1 ); echo $?
}

arm() { # arm <script> <label>
  local S="$1" L="$2" H RC
  H="$T/row-$L"; mkh "$H"
  grep -q '^H=/root/harness$' "$H/bin/$S" && { bad "$L: scratch copy still points at the live harness"; return; }
  printf '{"flag":{"name":"automerge-disabled","active":1,"updated_at":"2026-09-23T01:00:00Z"}}' \
    > "$H/rows/automerge-disabled.json"
  [ ! -e "$H/flags/automerge-disabled" ] || bad "$L: fixture has a file before the run"
  RC=$(runs "$H" "$S")
  [ "$RC" = 0 ] && ok || bad "$L: row-only automerge-disabled: rc $RC, want 0"
  [ ! -s "$H/gh-calls.txt" ] && ok || bad "$L: row-only automerge-disabled did not hold — calls: $(tr '\n' ';' < "$H/gh-calls.txt")"
  grep -qE 'dequeued|landed|merged' "$H/logs/"*.log 2>/dev/null && bad "$L: something landed under the kill switch" || ok
  # TEST-CHANGE BH-4153: automerge-disabled is a harness_flags row read DB-first;
  # no flags/ file is reconciled into place any more. The row's answer lands in
  # the last-good cache instead, and the hold above is what proves it was read.
  [ ! -e "$H/flags/automerge-disabled" ] && ok || bad "$L: a row-only automerge-disabled must not write flags/automerge-disabled (BH-4153)"
  jq -e '.on == true' "$H/state/flags-cache/fleet/automerge-disabled" >/dev/null 2>&1 && ok \
    || bad "$L: the row's answer must be cached in state/flags-cache/fleet/automerge-disabled"
  [ ! -e "$H/locks/rebase-train-proj.lock" ] && ok \
    || bad "$L: got past the gate under a row-only automerge-disabled (rebase-train lock taken)"
  [ -f "$H/state/merge-queue/proj/41" ] && ok || bad "$L: the queue entry was dropped under the kill switch"

  H="$T/ctl-$L"; mkh "$H"
  RC=$(runs "$H" "$S")
  if [ "$S" = rebase-train.sh ]; then
    # rebase-train.sh makes its lock right after the gate, before any gh call.
    [ -e "$H/locks/rebase-train-proj.lock" ] && ok || bad "$L control: no row, no file — never got past the gate (rc $RC)"
  else
    [ -s "$H/gh-calls.txt" ] && ok || bad "$L control: no row, no file — never reached its first gh/conductor call (rc $RC)"
  fi
  [ ! -e "$H/flags/automerge-disabled" ] && ok || bad "$L control: a flag file appeared with no row"
}

echo "== A. merge-queue.sh =="; arm merge-queue.sh mq
echo "== B. rebase-train.sh =="; arm rebase-train.sh rt
echo "== C. rebase-train-ahead.sh =="; arm rebase-train-ahead.sh rta

echo "flag-row-kill-switch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
