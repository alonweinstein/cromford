#!/bin/bash
# tests/review-pool-tmp-own.bh-6041-test.sh — BH-6041: with RPOOL_TMP_PREFIX
# set, every review-pool worker gets its own dir under the tmp path,
# <prefix><tickpid>-<id>, exported as RPOOL_TMP_OWN, and the dir is gone after
# every exit path: a normal exit and TERM (the worker's EXIT trap), SIGKILL
# (the tick's collect) and the tick's end (rpool_finish). With the prefix
# empty (bin/review-prs.sh) nothing changes.
#
# The real bin/lib/review-pool.sh is installed with its closure and sourced in
# a fresh bash per case; REVIEW_POOL_TMP_PATH points at a fixture /tmp under
# $T, so the real /tmp is never read or written. Cases:
#   O1  a worker that exits 0 had its dir (lr<pid>-<id>, mode 711) while it ran
#       and leaves the fixture /tmp empty;
#   O2  a worker that makes rules-pack-snap.XXXXXX in RPOOL_TMP_OWN leaves no
#       trace of it;
#   O3  a worker sent TERM mid-run: its own trap removed the dir before the
#       tick collects it;
#   O4  a worker sent SIGKILL mid-run: the dir outlives it, and after
#       rpool_wait_all the fixture /tmp is empty and the result is `killed`;
#   O5  RPOOL_TMP_PREFIX empty: no dir is made, RPOOL_TMP_OWN is empty and not
#       in a child's environment, also when the tick inherited one;
#   O6  rpool_finish removes a leftover lr<tickpid>-* and keeps another tick's;
#   O7  the dir cannot be made: the worker runs with RPOOL_TMP_OWN empty and
#       the tick logs one line.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/review-pool-tmp-own.bh-6041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

scratch_install_closure bin/lib/review-pool.sh "$T/p" >/dev/null || { echo "FAIL: cannot install review-pool.sh's closure"; exit 1; }
FX="$T/fxtmp"
export FX TT="$T"

# pool <case-script> — source the lib in a fresh bash and run the case script
# there: rpool_init with K=4 into $T/pool, logging into $T/log.
pool() {
  scratch_rm "$FX"; mkdir -p "$FX"; scratch_rm "$T/pool"; rm -f "$T/log" "$T"/rec.*
  timeout 60 env -u RPOOL_TMP_OWN REVIEW_POOL_TMP_PATH="$FX" REVIEW_POOL_TMP_SWEEP= REVIEW_POOL_POLL_S=0.05 \
    REVIEW_BOX_MAX=4 bash -c '
    . "$0/bin/lib/review-pool.sh" || exit 9
    lg() { printf "%s\n" "$*" >> "$TT/log"; }
    rpool_on_result() { printf "%s %s\n" "$1" "$2" >> "$TT/rec.results"; }
    '"$1" "$T/p" > "$T/out" 2>&1
  RC=$?
  [ "$RC" = 124 ] && bad "a pool case did not finish in 60 s"
}
fx_empty() { [ -z "$(ls -A "$FX" 2>/dev/null)" ]; }

# ══ O1 a normal exit ════════════════════════════════════════════════════════
pool '
RPOOL_TMP_PREFIX=lr
rpool_init lead-review REVIEW 4 "$TT/pool" lg
w() { printf "%s %s\n" "$RPOOL_TMP_OWN" "$(stat -c %a "$RPOOL_TMP_OWN" 2>/dev/null)" > "$TT/rec.own"; echo $$ > "$TT/rec.tick"; RPOOL_RESULT=done; }
rpool_start r1 w; rpool_wait_all'
read -r own mode < "$T/rec.own" 2>/dev/null || own=""
tick=$(cat "$T/rec.tick" 2>/dev/null)
[ -n "$own" ] && [ "$own" = "$FX/lr$tick-r1" ] && ok || bad "O1 RPOOL_TMP_OWN is <tmp path>/lr<tickpid>-r1 (got '$own', tick '$tick')"
[ "${mode:-}" = 711 ] && ok || bad "O1 the dir is mode 711 (got '${mode:-}')"
fx_empty && ok || bad "O1 a worker that exits 0 leaves the fixture /tmp empty ($(ls -A "$FX"))"
[ "$(cat "$T/rec.results" 2>/dev/null)" = "r1 done" ] && ok || bad "O1 the result is done ($(cat "$T/rec.results" 2>/dev/null))"

# ══ O2 a rules-pack snapshot inside it ══════════════════════════════════════
cat > "$T/rp-stub" <<'SH'
#!/bin/bash
# never a bare "/rules-pack-snap.*": an unset dir is recorded and refused
[ -n "${RULES_PACK_SNAPSHOT_TMP:-}" ] || { echo unset > "$TT/rec.snap"; exit 1; }
d=$(mktemp -d "$RULES_PACK_SNAPSHOT_TMP/rules-pack-snap.XXXXXX") || exit 1
echo x > "$d/f"; printf '%s\n' "$d" > "$TT/rec.snap"
SH
chmod +x "$T/rp-stub"
pool '
RPOOL_TMP_PREFIX=lr
rpool_init lead-review REVIEW 4 "$TT/pool" lg
w() { RULES_PACK_SNAPSHOT_TMP="$RPOOL_TMP_OWN" "$TT/rp-stub"; RPOOL_RESULT=done; }
rpool_start r2 w; rpool_wait_all'
snap=$(cat "$T/rec.snap" 2>/dev/null)
case "$snap" in "$FX"/lr[0-9]*-r2/rules-pack-snap.*) ok ;; *) bad "O2 the snapshot is made under lr<pid>-r2 (got '$snap')" ;; esac
fx_empty && ok || bad "O2 the snapshot went with the worker's dir ($(ls -A "$FX"))"

# ══ O3 TERM mid-run: the worker's own trap ══════════════════════════════════
pool '
RPOOL_TMP_PREFIX=lr
rpool_init lead-review REVIEW 4 "$TT/pool" lg
w() { : > "$RPOOL_TMP_OWN/busy"; : > "$TT/rec.ready"; while :; do sleep 0.05; done; }
rpool_start r3 w
pid=""; for p in "${!_RPOOL_PIDS[@]}"; do pid=$p; done
for _ in $(seq 1 200); do [ -e "$TT/rec.ready" ] && break; sleep 0.05; done
kill -TERM "$pid"
for _ in $(seq 1 200); do _rpool_alive "$pid" || break; sleep 0.05; done
ls -A "$REVIEW_POOL_TMP_PATH" > "$TT/rec.before"
rpool_wait_all'
[ -e "$T/rec.ready" ] && ok || bad "O3 fixture: the worker never started"
[ -f "$T/rec.before" ] && [ ! -s "$T/rec.before" ] && ok || bad "O3 TERM: the worker's trap removed its dir before the collect ($(cat "$T/rec.before" 2>/dev/null))"
fx_empty && ok || bad "O3 the fixture /tmp is empty after TERM ($(ls -A "$FX"))"

# ══ O4 SIGKILL mid-run: the tick's collect ══════════════════════════════════
pool '
RPOOL_TMP_PREFIX=lr
rpool_init lead-review REVIEW 4 "$TT/pool" lg
w() { : > "$RPOOL_TMP_OWN/busy"; : > "$TT/rec.ready"; while :; do sleep 0.05; done; }
rpool_start r4 w
pid=""; for p in "${!_RPOOL_PIDS[@]}"; do pid=$p; done
for _ in $(seq 1 200); do [ -e "$TT/rec.ready" ] && break; sleep 0.05; done
kill -KILL "$pid"
for _ in $(seq 1 200); do _rpool_alive "$pid" || break; sleep 0.05; done
ls -A "$REVIEW_POOL_TMP_PATH" > "$TT/rec.before"
rpool_wait_all'
[ -e "$T/rec.ready" ] && ok || bad "O4 fixture: the worker never started"
grep -qE '^lr[0-9]+-r4$' "$T/rec.before" 2>/dev/null && ok || bad "O4 fixture: a SIGKILLed worker cannot run its trap, so its dir is still there before the collect ($(cat "$T/rec.before" 2>/dev/null))"
fx_empty && ok || bad "O4 a worker killed mid-run leaves no dir under the fixture /tmp after rpool_wait_all ($(ls -A "$FX"))"
[ "$(cat "$T/rec.results" 2>/dev/null)" = "r4 killed" ] && ok || bad "O4 the result is killed ($(cat "$T/rec.results" 2>/dev/null))"

# ══ O5 no prefix: review-prs unchanged ══════════════════════════════════════
pool '
rpool_init review-prs REVIEW 4 "$TT/pool" lg
w() { printf "[%s] %s\n" "${RPOOL_TMP_OWN-unset}" "$(env | grep -c "^RPOOL_TMP_OWN=")" > "$TT/rec.own"; ls -A "$REVIEW_POOL_TMP_PATH" > "$TT/rec.during"; RPOOL_RESULT=done; }
rpool_start r5 w; rpool_wait_all'
[ "$(cat "$T/rec.own" 2>/dev/null)" = "[] 0" ] && ok || bad "O5 with no prefix RPOOL_TMP_OWN is empty and not exported ($(cat "$T/rec.own" 2>/dev/null))"
[ -f "$T/rec.during" ] && [ ! -s "$T/rec.during" ] && ok || bad "O5 with no prefix no dir is made ($(cat "$T/rec.during" 2>/dev/null))"
# an inherited RPOOL_TMP_OWN is not trusted either
pool '
export RPOOL_TMP_OWN="$TT/elsewhere"
rpool_init review-prs REVIEW 4 "$TT/pool" lg
w() { printf "[%s] %s\n" "${RPOOL_TMP_OWN-unset}" "$(env | grep -c "^RPOOL_TMP_OWN=")" > "$TT/rec.own"; RPOOL_RESULT=done; }
rpool_start r5 w; rpool_wait_all'
[ "$(cat "$T/rec.own" 2>/dev/null)" = "[] 0" ] && ok || bad "O5 an inherited RPOOL_TMP_OWN is dropped in the worker ($(cat "$T/rec.own" 2>/dev/null))"

# ══ O6 rpool_finish ═════════════════════════════════════════════════════════
pool '
RPOOL_TMP_PREFIX=lr
rpool_init lead-review REVIEW 4 "$TT/pool" lg
mkdir -p "$REVIEW_POOL_TMP_PATH/lr$$-r9/x" "$REVIEW_POOL_TMP_PATH/lr$$-r10" "$REVIEW_POOL_TMP_PATH/lr$$0-r9" "$REVIEW_POOL_TMP_PATH/lr1-r9"
echo $$ > "$TT/rec.tick"
rpool_finish'
tick=$(cat "$T/rec.tick" 2>/dev/null)
[ -n "$tick" ] && [ ! -e "$FX/lr$tick-r9" ] && [ ! -e "$FX/lr$tick-r10" ] && ok || bad "O6 rpool_finish removes this tick's leftover lr<pid>-* ($(ls -A "$FX"))"
[ -n "$tick" ] && [ -d "$FX/lr1-r9" ] && [ -d "$FX/lr${tick}0-r9" ] && ok || bad "O6 rpool_finish keeps another tick's lr dirs ($(ls -A "$FX"))"

# ══ O7 the dir cannot be made ═══════════════════════════════════════════════
pool '
RPOOL_TMP_PREFIX=lr
rpool_init lead-review REVIEW 4 "$TT/pool" lg
: > "$REVIEW_POOL_TMP_PATH/lr$$-r7"
w() { printf "[%s] %s\n" "${RPOOL_TMP_OWN-unset}" "$(env | grep -c "^RPOOL_TMP_OWN=")" > "$TT/rec.own"; RPOOL_RESULT=done; }
rpool_start r7 w; rpool_wait_all'
[ "$(cat "$T/rec.own" 2>/dev/null)" = "[] 0" ] && ok || bad "O7 mkdir failed: RPOOL_TMP_OWN is empty and not exported ($(cat "$T/rec.own" 2>/dev/null))"
[ "$(grep -c 'worker r7: cannot make' "$T/log" 2>/dev/null)" = 1 ] && ok || bad "O7 one log line names the failed mkdir ($(cat "$T/log" 2>/dev/null))"

echo "review-pool-tmp-own.bh-6041: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
