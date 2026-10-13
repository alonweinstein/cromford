#!/bin/bash
# tests/mc/nhv-other-callers.bh-3806-test.sh — BH-3806: when BH-3683 withholds
# the lead-verdict status on a head (la_decide rc 1), NO caller of
# mc_enqueue_mergify labels the PR or asks `@mergifyio queue`. The enqueue
# answers rc 4 with a refusal naming `bin/lead-verdict.sh post ... --source
# human`, and each caller maps rc 4 explicitly.
#
# WHAT IS DRIVEN. The real bin/lib/merge-conductor-lib.sh (so the real
# mc_enqueue_mergify and mc_mergify_command) under a fake gh that logs every
# label POST and comment POST; la_decide / la_human_needed / vs_publish are
# stubs that log their calls.
#   O1  mc_enqueue_mergify, la rc 1: rc 4, 0 label POSTs, 0 comments, 0 status
#       publishes, stdout names the full human command
#   O2  the real merge_pr handler of bin/poll-commands.sh (extracted between its
#       markers, as tests/poll-commands-mergify.bh-2199-test.sh does) over the
#       real enqueue, la rc 1: outcome `refused`, the result names the command,
#       0 label POSTs, 0 comments, never ok:true
#   O5  the real bin/merge-conductor.sh READY arm when the gate said rc 0 and the
#       enqueue's own la_decide says rc 1 (the memo bypassed): the row is
#       NEEDS_HUMAN_VERDICT, no mergefail strike, the tick holds `asked`, 0 label
#       POSTs
#   O6  controls with la rc 0: O1 and O2 label and ask exactly as before
# O3 (bin/rule-adopt.sh) and O4 (the bin/batch-resolve.sh train) drive those
# scripts whole, so they live in tests/rule-adopt.bh-3715-test.sh and
# tests/batch-resolve-test.sh beside the fixtures they need.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/nhv-other-callers.bh-3806-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR

SLUG=example-org/mgfy-os
URL=https://github.com/example-org/mgfy-os/pull/31
HEAD1=aaaaaaaa1111bbbbbbbb2222cccccccc33334444
PROT="touches protected paths: catalog/switches.d/x-off.json"
CMD="bin/lead-verdict.sh post $SLUG 31 $HEAD1 MERGE --source human"

# ── the lib world for O1/O2/O6 ──────────────────────────────────────────────
O="$T/o"; mkdir -p "$O/h/bin/lib" "$O/h/logs" "$O/h/state" "$O/bin"
cat > "$O/bin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$O/gh-calls"
case "\$*" in
  *"api -X POST repos/"*"/labels"*) printf '%s\n' "\$*" >> "$O/labels" ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "\$*" >> "$O/comments" ;;
esac
exit 0
EOF
chmod +x "$O/bin/gh"
cat > "$O/stubs.sh" <<EOF
la_decide() { printf '%s\n' "\$*" >> "$O/la"; LA_REASON="$PROT"; return "\$(cat "$O/la-rc")"; }
la_human_needed() { printf '%s\n' "\$*" >> "$O/lhn"; return 0; }
vs_publish() { printf '%s\n' "\$*" >> "$O/vs"; return 0; }
vs_context() { echo lead-verdict; }
mc_queue_state() { printf 'queued'; }
mc_mergify_witness() { [ "\$(cat "$O/la-rc")" = 0 ]; }
EOF
oreset() { rm -f "$O"/{gh-calls,labels,comments,la,lhn,vs}; scratch_rm "$O/h/state"; mkdir -p "$O/h/state"; echo "$1" > "$O/la-rc"; }
ocount() { [ -f "$O/$1" ] && wc -l < "$O/$1" | tr -d ' ' || echo 0; }
enq() { ( export HARNESS="$O/h" PATH="$O/bin:$PATH"
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  . "$O/stubs.sh"
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify "$SLUG" "$URL" "$HEAD1" ) 2>"$O/enq.err"; }

# ── O1: direct, la rc 1 ─────────────────────────────────────────────────────
oreset 1
OUT=$(enq); RC=$?
[ "$RC" = 4 ] && ok || bad "O1: a withheld verdict is rc 4 (got rc $RC, out: $OUT)"
[ "$(ocount labels)" = 0 ] && ok || bad "O1: no merge-queue label POST while the verdict is withheld ($(cat "$O/labels" 2>/dev/null))"
[ "$(ocount comments)" = 0 ] && ok || bad "O1: no @mergifyio comment while the verdict is withheld ($(cat "$O/comments" 2>/dev/null))"
[ "$(ocount vs)" = 0 ] && ok || bad "O1: no lead-verdict status published ($(cat "$O/vs" 2>/dev/null))"
grep -qF "$CMD" <<<"$OUT" && ok || bad "O1: the refusal names '$CMD' (out: $OUT)"
grep -q '^refused: ' <<<"$OUT" && ok || bad "O1: the refusal starts 'refused: ' (out: $OUT)"
grep -qF "catalog/switches.d/x-off.json" <<<"$OUT" && ok || bad "O1: the refusal names the protected path (out: $OUT)"
[ "$(ocount lhn)" = 1 ] && ok || bad "O1: the human-needed beat still goes out once (calls: $(cat "$O/lhn" 2>/dev/null))"

# ── O6a: direct, la rc 0 — unchanged ────────────────────────────────────────
oreset 0
OUT=$(enq); RC=$?
[ "$RC" = 0 ] && ok || bad "O6: la rc 0 enqueues as before (rc $RC, out: $OUT)"
[ "$(ocount labels)" = 1 ] && grep -q "issues/31/labels" "$O/labels" && ok || bad "O6: one label POST on la rc 0 ($(cat "$O/labels" 2>/dev/null))"
[ "$(ocount comments)" = 1 ] && grep -q '@mergifyio queue' "$O/comments" && ok || bad "O6: one @mergifyio queue on la rc 0 ($(cat "$O/comments" 2>/dev/null))"
[ "$(ocount vs)" = 1 ] && ok || bad "O6: the status is published on la rc 0 ($(cat "$O/vs" 2>/dev/null))"

# ── O2: the console Merge button ────────────────────────────────────────────
cat > "$O/h/bin/fleet-conf.sh" <<CONF
#!/bin/bash
[ "\$1" = --projects ] && { echo mgfy; exit 0; }
[ "\$2" = repo ] && printf '%s\n' "$SLUG"
exit 0
CONF
chmod +x "$O/h/bin/fleet-conf.sh"
awk '$0 ~ "^    # >>> merge_pr handler" {f=1; next} $0 ~ "^    # <<< merge_pr handler" {exit} f {print}' "$DIR/bin/poll-commands.sh" \
  | sed -e '1s/^    merge_pr)//' -e '$s/ ;;$//' > "$O/merge_pr.body"
[ -s "$O/merge_pr.body" ] && ok || { echo "FAIL: could not extract the merge_pr handler — markers missing?"; exit 1; }
press() {
  HARNESS="$O/h" PATH="$O/bin:$PATH" DIR="$DIR" O="$O" ID=1 PROJECT=mgfy \
  PAYLOAD="{\"pr_url\":\"$URL\",\"sha\":\"${HEAD1:0:12}\"}" LIVEHEAD="$HEAD1" \
    bash -c '
      set -uo pipefail
      OK=false; RESULT=""; OUTCOME=""
      . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
      . "$O/stubs.sh"
      mc_queue_provider() { printf mergify; }
      mc_pr_view() { printf %s "$LIVEHEAD"; }
      export MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0
      . "$0"
      printf "OK=%s\nRESULT=%s\nOUTCOME=%s\n" "$OK" "$RESULT" "$OUTCOME"' "$O/merge_pr.body" 2>"$O/press.err"
}
oreset 1
OUT=$(press)
[ "$(sed -n 's/^OUTCOME=//p' <<<"$OUT")" = refused ] && ok || bad "O2: a withheld verdict acks a terminal refused (got: $OUT; err: $(head -3 "$O/press.err"))"
[ "$(sed -n 's/^OK=//p' <<<"$OUT")" = false ] && ok || bad "O2: never ok:true (got: $OUT)"
sed -n 's/^RESULT=//p' <<<"$OUT" | grep -qF -- "--source human" && ok || bad "O2: the result names the --source human command (got: $OUT)"
sed -n 's/^RESULT=//p' <<<"$OUT" | grep -qF "$CMD" && ok || bad "O2: the result carries the whole command '$CMD' (got: $OUT)"
grep -qiE 'merge failed|queued|in place' <<<"$(sed -n 's/^RESULT=//p' <<<"$OUT")" && bad "O2: the refusal must not say merge failed / queued / in place (got: $OUT)" || ok
[ "$(ocount labels)" = 0 ] && ok || bad "O2: no label POST from the button ($(cat "$O/labels" 2>/dev/null))"
[ "$(ocount comments)" = 0 ] && ok || bad "O2: no @mergifyio comment from the button ($(cat "$O/comments" 2>/dev/null))"
grep -q -- '-X PUT' "$O/gh-calls" 2>/dev/null && bad "O2: no REST merge ($(cat "$O/gh-calls"))" || ok
# O6b: the same press on la rc 0 still queues.
oreset 0
OUT=$(press)
[ "$(sed -n 's/^OK=//p' <<<"$OUT")" = true ] && sed -n 's/^RESULT=//p' <<<"$OUT" | grep -q "^queued $URL" && ok || bad "O6: la rc 0 still queues from the button (got: $OUT; err: $(head -3 "$O/press.err"))"
[ "$(ocount labels)" = 1 ] && [ "$(ocount comments)" = 1 ] && ok || bad "O6: la rc 0 labels and asks once (labels $(ocount labels), comments $(ocount comments))"

# ── O5: the conductor READY arm on a gate/enqueue race ──────────────────────
# shellcheck source=tests/lib/nhv-conductor-fixture.sh
. "$(dirname "$0")/../lib/nhv-conductor-fixture.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
# ae_mark recorded, so the `asked` mark the tier-2 self-enqueue reads is visible.
printf 'ae_mark() { printf "%%s\\n" "$*" >> "%s/ae-marks.txt"; }\n' "$T" > "$T/h/bin/lib/autoenqueue.sh"
H41=aaaaaaaa00aaaaaaaaaaaaaaaaaaaaaaaaaaaa41
nhvf_pr 41 "$H41"
nhvf_reset
: > "$T/ae-marks.txt"
touch "$T/nomemo"
nhvf_la 0 "$PROT"; printf '0\n1\n' > "$T/la-seq"
nhvf_tick
[ "$(nhvf_field 41 2)" = NEEDS_HUMAN_VERDICT ] && ok || bad "O5: an enqueue refused on rc 4 leaves the row NEEDS_HUMAN_VERDICT (got '$(nhvf_field 41 2)'; log: $(grep -F '#41' "$CLOG" | tail -4))"
nhvf_field 41 7 | grep -qF -- "--source human" && ok || bad "O5: the row's reason names the command (reason: $(nhvf_field 41 7))"
grep -q '^refused: ' <<<"$(nhvf_field 41 7)" && bad "O5: the reason drops the 'refused: ' prefix (reason: $(nhvf_field 41 7))" || ok
[ "$(nhvf_count . label-adds.txt)" = 0 ] && ok || bad "O5: no label POST ($(cat "$T/label-adds.txt"))"
[ "$(grep -ci '@mergifyio' "$T/queue-cmds.txt")" = 0 ] && ok || bad "O5: no @mergifyio ask ($(cat "$T/queue-cmds.txt"))"
grep -q mergefail "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "O5: rc 4 is no mergefail strike ($(grep mergefail "$T/h/state/merge-conductor/attempts.txt"))" || ok
grep -qxF "mgfy asked example-org/mgfy-os#41 $H41" "$T/ae-marks.txt" && ok || bad "O5: the tick marks the row asked, so the tier-2 self-enqueue posts nothing (marks: $(cat "$T/ae-marks.txt"))"
grep -q 'MERGE_HELD' "$CLOG" && bad "O5: rc 4 is not the rc 3 hold ($(grep MERGE_HELD "$CLOG"))" || ok
[ "$(nhvf_count . la-calls.txt)" = 2 ] && ok || bad "O5 setup: the gate and the enqueue each asked once (calls: $(cat "$T/la-calls.txt"))"

echo "nhv-other-callers.bh-3806-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
