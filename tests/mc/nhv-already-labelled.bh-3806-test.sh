#!/bin/bash
# tests/mc/nhv-already-labelled.bh-3806-test.sh — BH-3806: a PR that already
# carries OUR merge-queue label and sits QUEUED, with no `lead-verdict: success`
# on its head and BH-3683 withholding it (la_decide rc 1), never reached the
# BH-3777 gate: MC_INQUEUE won before the CLEAN arm (#3798, #3799 on
# 2026-10-01). The conductor now takes the label off ONCE per (PR, head) and the
# row is NEEDS_HUMAN_VERDICT in the same tick.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, merge mode, over a Mergify
# repo with a fake gh (tests/lib/nhv-conductor-fixture.sh). Every assertion
# reads the label DELETEs, the status reads, the rows and the conductor log.
#   A1  QUEUED + labelled, no status, la rc 1: one tick -> NEEDS_HUMAN_VERDICT,
#       exactly 1 DELETE of merge-queue, one NHV_UNQUEUED line
#   A2  the next tick: 0 DELETEs, still NEEDS_HUMAN_VERDICT
#   A3  a hand re-label on the same head: 0 DELETEs
#   A4  a lead-verdict success status on the head: 0 DELETEs, QUEUED
#   A5  la rc 0: 0 DELETEs, QUEUED
#   A6  la rc 2: 0 DELETEs, QUEUED
#   A7  the status read answers 500: 0 DELETEs, QUEUED, la_decide not asked
#   A8  merge mode off: 0 DELETEs, QUEUED, one WOULD unqueue line
#   A9  a repo outside the protected-paths catalog: 0 DELETEs, 0 status reads
#   A10 a DELETE answering 500: no mark, retried next tick, then lands once
#   A11 a lead-verdict FAILURE status counts as absent: the label comes off
#   A12 only Mergify's own `queued` label, not ours: 0 DELETEs
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/nhv-already-labelled.bh-3806-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/nhv-conductor-fixture.sh
. "$(dirname "$0")/../lib/nhv-conductor-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
H41=aaaaaaaa00aaaaaaaaaaaaaaaaaaaaaaaaaaaa41
nhvf_pr 41 "$H41"
PROT="touches protected paths: catalog/switches.d/x-off.json"
KEY='example-org/mgfy-os#41'
state() { nhvf_field 41 2; }
dels()  { nhvf_count . label-dels.txt; }
labelled() { grep -qxF merge-queue "$T/labels-41"; }

# queued_row — a fresh row the conductor enqueued (la rc 0), so it is QUEUED
# with our label on; then the authority flips to withheld and the logs clear.
queued_row() {
  nhvf_reset
  nhvf_la 0 "no protected path"; nhvf_tick
  [ "$(state)" = QUEUED ] && labelled || bad "setup: the row must be QUEUED and labelled (state '$(state)', labels: $(cat "$T/labels-41"); log: $(grep -F '#41' "$CLOG" | tail -3))"
  nhvf_la 1 "$PROT"; nhvf_clear
}
stays_queued() { # stays_queued <case>
  [ "$(dels)" = 0 ] && ok || bad "$1: no label DELETE ($(cat "$T/label-dels.txt"))"
  [ "$(state)" = QUEUED ] && ok || bad "$1: the row stays QUEUED (got '$(state)')"
  labelled && ok || bad "$1: our label stays on"
}

# ── A1 ──────────────────────────────────────────────────────────────────────
queued_row
nhvf_tick
[ "$(dels)" = 1 ] && grep -q 'repos/example-org/mgfy-os/issues/41/labels/merge-queue' "$T/label-dels.txt" && ok \
  || bad "A1: exactly one DELETE of our label (got: $(cat "$T/label-dels.txt"); log: $(grep -F '#41' "$CLOG" | tail -4))"
[ "$(state)" = NEEDS_HUMAN_VERDICT ] && ok || bad "A1: the row is NEEDS_HUMAN_VERDICT in the same tick (got '$(state)'; log: $(grep -F '#41' "$CLOG" | tail -4))"
grep -qF "$KEY QUEUED -> NEEDS_HUMAN_VERDICT" "$CLOG" && ok || bad "A1: the log shows QUEUED -> NEEDS_HUMAN_VERDICT ($(grep -F '#41' "$CLOG" | tail -4))"
[ "$(grep -c "NHV_UNQUEUED $KEY $H41" "$CLOG")" = 1 ] && ok || bad "A1: one NHV_UNQUEUED line names the key and full head ($(grep NHV "$CLOG"))"
grep "NHV_UNQUEUED" "$CLOG" | grep -qF "x-off.json" && ok || bad "A1: the line carries LA_REASON ($(grep NHV "$CLOG"))"
nhvf_field 41 7 | grep -qF -- "bin/lead-verdict.sh post example-org/mgfy-os 41 $H41 MERGE --source human" && ok || bad "A1: the reason names the command ($(nhvf_field 41 7))"
labelled && bad "A1: our label is off" || ok
[ "$(nhvf_count . label-adds.txt)" = 0 ] && [ "$(grep -ci '@mergifyio' "$T/queue-cmds.txt")" = 0 ] && ok || bad "A1: nothing re-labels or asks ($(cat "$T/label-adds.txt" "$T/queue-cmds.txt"))"
# ── A2 ──────────────────────────────────────────────────────────────────────
nhvf_clear; nhvf_tick
[ "$(dels)" = 0 ] && ok || bad "A2: the second tick issues no DELETE ($(cat "$T/label-dels.txt"))"
[ "$(state)" = NEEDS_HUMAN_VERDICT ] && ok || bad "A2: still NEEDS_HUMAN_VERDICT (got '$(state)')"
# ── A3 ──────────────────────────────────────────────────────────────────────
printf 'merge-queue\n' >> "$T/labels-41"
nhvf_clear; nhvf_tick
[ "$(dels)" = 0 ] && ok || bad "A3: a hand re-label on the same head is left alone ($(cat "$T/label-dels.txt"))"

# ── A4..A9: the row must stay QUEUED ────────────────────────────────────────
queued_row; echo success > "$T/status-mode"; nhvf_tick
stays_queued A4
queued_row; nhvf_la 0 "a human verdict stands"; nhvf_tick
stays_queued A5
queued_row; nhvf_la 2 "the files could not be read whole"; nhvf_tick
stays_queued A6
queued_row; echo 500 > "$T/status-mode"; nhvf_tick
stays_queued A7
[ "$(nhvf_count . la-calls.txt)" = 0 ] && ok || bad "A7: an unreadable status asks no la_decide ($(cat "$T/la-calls.txt"))"
queued_row; rm -f "$T/h/flags/merge-conductor-merge"; nhvf_tick
stays_queued A8
[ "$(grep -c "WOULD unqueue" "$CLOG")" = 1 ] && ok || bad "A8: one WOULD unqueue line ($(grep -F '#41' "$CLOG" | tail -3))"
touch "$T/h/flags/merge-conductor-merge"
queued_row; echo 1 > "$T/la-scope"; nhvf_tick
stays_queued A9
[ "$(nhvf_count . status-reads.txt)" = 0 ] && ok || bad "A9: a non-governed repo costs no status read ($(cat "$T/status-reads.txt"))"

# ── A10: a failed DELETE is never recorded as done ──────────────────────────
queued_row; touch "$T/del500"; nhvf_tick
[ "$(dels)" = 1 ] && ok || bad "A10: one DELETE tried ($(cat "$T/label-dels.txt"))"
grep -q "nhvunqueue" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "A10: no mark after a failed DELETE" || ok
[ "$(state)" = QUEUED ] && ok || bad "A10: the row stays QUEUED while the label is on (got '$(state)')"
nhvf_clear; nhvf_tick
[ "$(dels)" = 1 ] && ok || bad "A10: the next tick tries again ($(cat "$T/label-dels.txt"))"
rm -f "$T/del500"; nhvf_clear; nhvf_tick
[ "$(dels)" = 1 ] && [ "$(state)" = NEEDS_HUMAN_VERDICT ] && ok || bad "A10: once the DELETE lands the row is NEEDS_HUMAN_VERDICT (dels $(dels), state '$(state)')"
nhvf_clear; nhvf_tick
[ "$(dels)" = 0 ] && ok || bad "A10: and never again ($(cat "$T/label-dels.txt"))"

# ── A11: a failure status is not a success ──────────────────────────────────
queued_row; echo failure > "$T/status-mode"; nhvf_tick
[ "$(dels)" = 1 ] && [ "$(state)" = NEEDS_HUMAN_VERDICT ] && ok || bad "A11: a lead-verdict failure is not a cleared head (dels $(dels), state '$(state)')"

# ── A12: Mergify's label only ───────────────────────────────────────────────
queued_row; printf 'queued\n' > "$T/labels-41"; nhvf_tick
[ "$(dels)" = 0 ] && ok || bad "A12: without our label nothing is deleted ($(cat "$T/label-dels.txt"))"

echo "nhv-already-labelled.bh-3806-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
