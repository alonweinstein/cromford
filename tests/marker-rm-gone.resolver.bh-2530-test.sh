#!/bin/bash
# tests/marker-rm-gone.resolver.bh-2530-test.sh — BH-2674 (BH-2530.3): the
# resolver's re-offer of a box-owned ticket (br_enqueue_fresh's box branch)
# clears the D1 `commented` row and nothing else. The ssh rm of the owning
# box's blocked-commented stamp is gone: a `cleared` row outvotes any file left
# there (bin/lib/comment-mark.sh), so the row is the whole re-offer, and a row
# the DB did not take is a failed re-offer (BR_ENQUEUE_WHY, rc 1), not a hop.
#
# A REAL tick drives it: the park is merge-failed-twice on a ticket whose
# project is owned by box-tproj and not pool-routed, so the rung is REBUILD
# FRESH through the box branch. The jobs worker is
# tests/lib/fake-fix-round-worker.bh-2530.py behind a `curl` shim, with the
# real transport (bin/lib/jobs/req.sh), the real ledger verbs and the real
# bin/lib/comment-mark.sh. ssh is recorded, never real.
#
# Cases:
#   R1  worker up: the row is `cleared`, 0 ssh calls, the stamp is re-offered
#   R2  worker down: 0 ssh calls, the "did not take the cleared row" line
#   R3  the bodies of br_enqueue_fresh and br_fix_remote, comments stripped,
#       name no ssh (secondary to R1/R2; fails when either function is gone)
# Run: HARNESS_TEST_SANDBOX=1 bash tests/marker-rm-gone.resolver.bh-2530-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
cp "$DIR/bin/lib/comment-mark.sh" "$DIR/bin/lib/fix-round-queue.sh" "$H/bin/lib/" || exit 1

# ---- the fake worker and the real transport ----------------------------------
FRW="$T/frw"; mkdir -p "$FRW" "$H/bin/lib/jobs" || exit 1
cp "$DIR/bin/lib/jobs/req.sh" "$H/bin/lib/jobs/" || exit 1
printf '#!/bin/bash\nFRW_STATE=%q exec python3 %q "$@"\n' "$FRW" "$DIR/tests/lib/fake-fix-round-worker.bh-2530.py" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl" || exit 1
{ printf 'queue_put() { printf "%%s\\n" "$*" >> %q; echo queued; }\n' "$T/queue.txt"
  printf 'queue_list() { return 1; }\n'
  printf 'JOBS_HARNESS=%q; HARNESS_SECRET=test-secret; JOBS_URL=https://jobs.invalid; JOBS_RETRIES=0\n' "$H"
  printf '. %q\n' "$H/bin/lib/jobs/req.sh"
  sed -n '/^job_ledger_row() {/,/^}/p;/^job_ledger_put() {/,/^}/p' "$DIR/bin/lib/jobs/jobs.sh"
} > "$H/bin/jobs-client.sh" || exit 1
grep -q '^job_ledger_put() {' "$H/bin/jobs-client.sh" || { echo "FAIL: the ledger verbs did not install"; exit 1; }

# The PR the rung reads: TK-9 on its own branch, open.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"issue comment"*|*"pr comment"*) exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) _h=\$(<"$T/prhead"); _b=\$(<"$T/prbranch"); echo "\${_h:-null} \${_b:-null}" ;;
  *"--json headRefOid,headRefName"*) echo "\$(cat "$T/prhead") \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json headRefOid"*)  cat "$T/prhead" ;;
  *"--json title"*)       cat "$T/prtitle" 2>/dev/null ;;
  *"pr list"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
LOGF="$H/logs/blocked-resolver.log"
KEY="blocked tproj TK-9"
LEDGER() { jq -r --arg k "commented	$KEY" '.[$k].status // "none"' "$FRW/ledger.json" 2>/dev/null || echo none; }

reoffer() {
  scratch_rm "$H/state/blocked-resolver"; rm -f "$H/flags/fly-pool-tproj"
  : > "$T/ssh.txt"; : > "$T/queue.txt"; : > "$LOGF"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
  ROW "o/tproj#11" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/11"
  RUN
}

# ---- R1. worker up: the row is the re-offer, no ssh
scratch_rm "$FRW"; mkdir -p "$FRW"
reoffer
[ "$(LEDGER)" = cleared ] && ok || bad "R1: the re-offer must clear the '$KEY' row (ledger: $(cat "$FRW/ledger.json" 2>/dev/null); log: $(grep TK-9 "$LOGF" | tail -3))"
[ -s "$T/ssh.txt" ] && bad "R1: a re-offer must not ssh to the owning box ($(cat "$T/ssh.txt"))" || ok
grep -q "cleared row commented '$KEY'" "$LOGF" && ok || bad "R1: the success line names the row (log: $(tail -3 "$LOGF"))"

# ---- R2. worker down: no ssh fallback, the failure is said
scratch_rm "$FRW"; mkdir -p "$FRW"; touch "$FRW/down"
reoffer
rm -f "$FRW/down"
[ -s "$T/ssh.txt" ] && bad "R2: the DB down must not fall back to ssh ($(cat "$T/ssh.txt"))" || ok
grep -q "the jobs DB did not take the cleared row for TK-9" "$LOGF" && ok \
  || bad "R2: the failed re-offer is said (log: $(grep TK-9 "$LOGF" | tail -3))"
grep -q "cleared row commented" "$LOGF" && bad "R2: an unwritten row is not a success line" || ok

# ---- R3. the two functions' code (comments stripped) names no ssh
for fn in br_enqueue_fresh br_fix_remote; do
  body=$(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$DIR/bin/blocked-resolver.sh")
  [ -n "$body" ] || { bad "R3: $fn is missing from bin/blocked-resolver.sh"; continue; }
  code=$(printf '%s\n' "$body" | grep -v '^[[:space:]]*#')
  grep -qiE 'ssh|tailnet' <<<"$code" && bad "R3: $fn still names ssh or a tailnet address: $(printf '%s\n' "$code" | grep -iE 'ssh|tailnet')" || ok
done

echo "marker-rm-gone.resolver.bh-2530: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
