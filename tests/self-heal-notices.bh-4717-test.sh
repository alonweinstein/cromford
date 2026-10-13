#!/bin/bash
# tests/self-heal-notices.bh-4717-test.sh — BH-4724 (BH-4717.4): the two notices
# that report a fix the harness already made go info-level and are counted.
#
# `[$PROJECT] BUILD RESTARTED on the fresh harness` (bin/context-gate.sh) and
# `rescued review = APPROVE` (bin/review-rescue.sh) paged as critical because
# their emitters passed no --severity. They now go through bin/lib/self-heal.sh:
# alert-line.sh --severity info (beat.sh logs info-only and never sends), plus
# one `self_heal` ledger row the daily digest counts.
#
# What is pinned, against the REAL emitters in a scratch harness (beat.sh and
# jobs-client.sh are recorders that append their argv):
#   L:  the lib refuses an empty root (rc 1, nothing written).
#   H1: context-gate stale checkout -> the RESTARTED beat carries
#       severity info; no beat lacks one. A DEFERRED run beats with no severity.
#   H2: one `ledger-put self_heal context-gate:<project>:<build-basename>`, detail <= 300.
#   H3: review-rescue APPROVE -> info beat + one review-rescue ledger put.
#   H4: review-rescue "still blocked after re-scan" keeps no severity.
#   H5: lib absent -> both lines still beat info, no ledger call, rc unchanged.
#   H6: jobs-client fails -> rc unchanged, lines present and info.
#   D5: dd_render prints the Self-healed line; ok:false renders the failed(...)
#       form (`Self-healed: n/a (read failed: <err>) <console>/alerts`); no key, no line.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# install_recorders <harness>: beat.sh records its payload, jobs-client.sh its argv.
install_recorders() {
  cat > "$1/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$T/beats.jsonl"
exit 0
EOF
  # lane-gate.sh SOURCES jobs-client.sh for its flag reads: sourced, it defines nothing.
  cat > "$1/bin/jobs-client.sh" <<EOF
#!/bin/bash
[ "\${BASH_SOURCE[0]}" != "\$0" ] && return 0
printf '%s\n' "\$*" >> "$T/ledger.txt"
exit "\$(cat "$T/jc-rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$1/bin/beat.sh" "$1/bin/jobs-client.sh"
}
# The ledger put is detached: wait for it, bounded, never on a clock compare.
wait_ledger() { local i=0; while [ "$i" -lt 50 ] && [ "$(cat "$T/ledger.txt" 2>/dev/null | grep -c .)" -lt "$1" ]; do sleep 0.1; i=$((i+1)); done; }
beat_of() { grep -F "$1" "$T/beats.jsonl" 2>/dev/null | head -1; }
sev_of()  { beat_of "$1" | jq -r 'if has("severity") then .severity else "NONE" end' 2>/dev/null; }
ledger_n() { cat "$T/ledger.txt" 2>/dev/null | grep -c "^ledger-put self_heal $1"; }
clear_rec() { : > "$T/beats.jsonl"; : > "$T/ledger.txt"; echo 0 > "$T/jc-rc"; }

# ── L: the lib on its own ────────────────────────────────────────────────────
( unset HARNESS H; . "$DIR/bin/lib/self-heal.sh" || exit 9; self_heal_note src key text ); RC=$?
[ "$RC" = 1 ] && ok || bad "L: an empty root must refuse with rc 1 (rc=$RC)"

# ══ context-gate ════════════════════════════════════════════════════════════
CG="$T/cg"
mkdir -p "$CG/bin/lib" "$CG/logs" "$CG/flags" "$T/build-BH-1-20261005"
install_recorders "$CG"
scratch_install_closure bin/context-gate.sh "$CG" >/dev/null || { echo "FAIL: scratch_install_closure bin/context-gate.sh"; exit 1; }
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$CG/bin/"
printf '#!/bin/bash\necho "{ \\"harness_bin_in_sync\\": true, \\"machine_rules_in_sync\\": true }"\n' > "$CG/bin/context-signature.sh"
cat > "$CG/bin/harness-sync.sh" <<SYNC
#!/bin/bash
if [ "\${1:-}" = --check ]; then echo "behind origin by 3"; exit 10; fi
echo "synced aaa..bbb"
exit "\$(cat "$T/sync-rc" 2>/dev/null || echo 0)"
SYNC
chmod +x "$CG/bin"/*.sh
CGB="$T/build-BH-1-20261005"
gate() { ( HARNESS="$CG" HARNESS_CHECKOUT="$T/ck" bash "$CG/bin/context-gate.sh" demo-os "$CGB" "$T/repo" ) >/dev/null 2>&1; }

# H1 + H2
clear_rec; : > "$CG/logs/ALERTS.log"; echo 0 > "$T/sync-rc"
gate; RC=$?
[ "$RC" = 3 ] && ok || bad "H1: a synced stale checkout must still answer rc 3 (rc=$RC)"
grep -q 'BUILD RESTARTED on the fresh harness' "$CG/logs/ALERTS.log" && ok || bad "H1: RESTARTED line missing from ALERTS.log ($(cat "$CG/logs/ALERTS.log"))"
[ "$(sev_of 'BUILD RESTARTED')" = info ] && ok || bad "H1: the RESTARTED beat must carry severity info (beat: $(beat_of 'BUILD RESTARTED'))"
[ "$(jq -s '[.[] | select(has("severity") | not)] | length' "$T/beats.jsonl")" = 0 ] && ok \
  || bad "H1: no beat without a severity may be sent ($(cat "$T/beats.jsonl"))"
wait_ledger 1
[ "$(ledger_n "context-gate:demo-os:build-BH-1-20261005 logged ")" = 1 ] && ok \
  || bad "H2: exactly one context-gate ledger put keyed <project>:<build-basename> (got: $(cat "$T/ledger.txt"))"
DETAIL=$(grep '^ledger-put self_heal context-gate:' "$T/ledger.txt" | head -1 | sed 's/^ledger-put self_heal [^ ]* logged //')
case "$DETAIL" in *"BUILD RESTARTED"*) ok ;; *) bad "H2: the ledger detail must carry the notice text (got: $DETAIL)" ;; esac
[ "${#DETAIL}" -le 300 ] && ok || bad "H2: the ledger detail must be <= 300 chars (got ${#DETAIL})"

# H1 negative: DEFERRED (sync failed) still pages, no severity, no ledger row.
clear_rec; : > "$CG/logs/ALERTS.log"; echo 20 > "$T/sync-rc"
gate; RC=$?
[ "$RC" = 1 ] && ok || bad "H1: a failed sync is still refused (rc=$RC)"
[ "$(sev_of 'BUILD DEFERRED')" = NONE ] && ok || bad "H1: DEFERRED must beat with no severity (beat: $(beat_of 'BUILD DEFERRED'))"
sleep 0.3; [ ! -s "$T/ledger.txt" ] && ok || bad "H1: DEFERRED is not a self-heal (ledger: $(cat "$T/ledger.txt"))"

# H6: the ledger put fails -> nothing else changes.
clear_rec; : > "$CG/logs/ALERTS.log"; echo 0 > "$T/sync-rc"; echo 1 > "$T/jc-rc"
gate; RC=$?
[ "$RC" = 3 ] && ok || bad "H6: a failed ledger put must not change context-gate's rc (rc=$RC)"
[ "$(sev_of 'BUILD RESTARTED')" = info ] && ok || bad "H6: RESTARTED is still info when the ledger fails"
grep -q 'BUILD RESTARTED' "$CG/logs/ALERTS.log" && ok || bad "H6: RESTARTED still in ALERTS.log"

# H5: the lib is not on this box yet -> raw alert-line --severity info.
rm -f "$CG/bin/lib/self-heal.sh"
clear_rec; : > "$CG/logs/ALERTS.log"
gate; RC=$?
[ "$RC" = 3 ] && ok || bad "H5: context-gate rc 3 without the lib (rc=$RC)"
[ "$(sev_of 'BUILD RESTARTED')" = info ] && ok || bad "H5: the fallback must still beat info (beat: $(beat_of 'BUILD RESTARTED'))"
[ "$(grep -c 'BUILD RESTARTED' "$CG/logs/ALERTS.log")" = 1 ] && ok || bad "H5: exactly one RESTARTED line ($(cat "$CG/logs/ALERTS.log"))"
sleep 0.3; [ ! -s "$T/ledger.txt" ] && ok || bad "H5: no ledger call without the lib (ledger: $(cat "$T/ledger.txt"))"

# ══ review-rescue ═══════════════════════════════════════════════════════════
# The fixture is tests/review-rescue-test.sh's, cut to the two branches used here.
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PRURL="https://github.com/example-org/project-5/pull/777"
export HARNESS="$T/h"; H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$T/fakebin" "$T/repos"
install_recorders "$H"
scratch_install_closure bin/review-rescue.sh "$H" >/dev/null || { echo "FAIL: scratch_install_closure bin/review-rescue.sh"; exit 1; }
cp "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/fleet-projects-or-alert.sh" "$DIR/bin/test-tamper-scan.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H/bin/"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/hold-fixture.sh" && hold_fixture_libs "$DIR" "$H" || exit 1
: > "$H/env/global.env"
export REPOS_ROOT="$T/repos"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" project-5
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -k) shift 2 ;; -*) shift ;; [0-9]*) shift; break ;; *) break ;; esac; done
exec "$@"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr create"*) echo "$PRURL"; exit 0 ;;
  *"-i -X GET"*"/issues/"*"/comments"*) printf 'HTTP/2 200\r\n\r\n[]' ;;
  *"-i -X GET"*"/issues/"*) printf 'HTTP/2 200\r\n\r\n{"state":"open"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/flock" "$T/fakebin/timeout" "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/agent-call.sh"; chmod +x "$H/bin/agent-call.sh"

ORIGIN="$T/origin.git"; git init -q --bare "$ORIGIN"
W="$T/work"; mkdir -p "$W/tests"
(
  cd "$W" || exit 1
  git -c init.defaultBranch=main init -q .
  git config user.email t@t; git config user.name t
  printf "describe('thing', () => {\n  it('adds', () => { expect(add(1,2)).toBe(3) })\n})\n" > tests/thing.test.js
  echo src > app.js; git add -A; git commit -qm init; git branch -M main
  git remote add origin "$ORIGIN"; git push -q -u origin main
  git checkout -q -b ticket/TK-551; echo feature >> app.js
  printf "it('multiplies', () => { expect(mul(2,3)).toBe(6) })\n" >> tests/thing.test.js
  git add -A; git commit -qm "TK-551"; git push -q -u origin ticket/TK-551
  git checkout -q main; git checkout -q -b ticket/TK-552
  git rm -q tests/thing.test.js; echo more >> app.js
  git add -A; git commit -qm "TK-552"; git push -q -u origin ticket/TK-552
) >/dev/null 2>&1
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$T/repos/project-5"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

ago() { date -d "-$1 minutes" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"$1"M +%Y%m%d%H%M.%S; }
TAMPER_RESULT="REVIEW_BLOCKED test-tamper: TAMPER_COUNT: 1 (deleted_files=0 deleted_cases=1 added_skips=0) — no TEST-CHANGE justification; see /x/test-tamper.txt"
reset_rr() { scratch_rm "$H/builds"; mkdir -p "$H/builds"; : > "$H/logs/ALERTS.log"; clear_rec; }
# mkbuild <name> [review.md body]: an aged tamper-blocked candidate.
mkbuild() {
  local D="$H/builds/$1"; mkdir -p "$D"
  printf '%s\n' "$TAMPER_RESULT" > "$D/RESULT"
  printf '# %s\n\n## Tasks\n' "$1" > "$D/plan.md"
  [ -n "${2:-}" ] && printf '%s' "$2" > "$D/review.md"
  touch -t "$(ago 200)" "$D/RESULT"; echo "$D"
}
APPROVED='findings
TIER: 2
VERDICT: APPROVE
'
rr() { bash "$H/bin/review-rescue.sh" >>"$T/rr.log" 2>&1; }
CAND=pool-project-5-TK-551-202609131444

# H3: the standing APPROVE ships -> info + one ledger row.
reset_rr; D=$(mkbuild "$CAND" "$APPROVED")
rr; RC0=$?
[ "$(head -1 "$D/RESULT")" = "PR_CREATED $PRURL" ] && ok || bad "H3: the APPROVE branch must have run (RESULT: $(head -1 "$D/RESULT"))"
grep -q "\[review-rescue\] \[project-5/TK-551\] $CAND: rescued review = APPROVE" "$H/logs/ALERTS.log" && ok \
  || bad "H3: the APPROVE line keeps its text ($(cat "$H/logs/ALERTS.log"))"
[ "$(sev_of 'rescued review = APPROVE')" = info ] && ok || bad "H3: the APPROVE beat must carry severity info (beat: $(beat_of 'rescued review = APPROVE'))"
wait_ledger 1
[ "$(ledger_n "review-rescue:project-5/TK-551:$CAND logged ")" = 1 ] && ok \
  || bad "H3: one review-rescue ledger put keyed <project>/<KEY>:<cand> (got: $(cat "$T/ledger.txt"))"

# H4: a real deletion -> the hand-off line keeps no severity.
reset_rr; D=$(mkbuild pool-project-5-TK-552-202609131444)
rr
grep -q 'still blocked after re-scan' "$H/logs/ALERTS.log" && ok || bad "H4: the hand-off line must fire ($(cat "$H/logs/ALERTS.log"))"
[ "$(sev_of 'still blocked after re-scan')" = NONE ] && ok || bad "H4: the hand-off beat must carry no severity (beat: $(beat_of 'still blocked after re-scan'))"
sleep 0.3; [ ! -s "$T/ledger.txt" ] && ok || bad "H4: a hand-off is not a self-heal (ledger: $(cat "$T/ledger.txt"))"

# H6: the ledger put fails -> same rc, line present and info.
git -C "$T/repos/project-5" push -q origin --delete ticket/TK-551 >/dev/null 2>&1
git -C "$W" push -q -f origin ticket/TK-551 >/dev/null 2>&1
reset_rr; D=$(mkbuild "$CAND" "$APPROVED"); echo 1 > "$T/jc-rc"
rr; RC=$?
[ "$RC" = "$RC0" ] && ok || bad "H6: review-rescue rc must not change when the ledger fails (rc=$RC want $RC0)"
[ "$(sev_of 'rescued review = APPROVE')" = info ] && ok || bad "H6: APPROVE still info when the ledger fails"

# H5: lib absent -> raw alert-line --severity info, no ledger call.
rm -f "$H/bin/lib/self-heal.sh"
reset_rr; D=$(mkbuild "$CAND" "$APPROVED")
rr; RC=$?
[ "$RC" = "$RC0" ] && ok || bad "H5: review-rescue rc unchanged without the lib (rc=$RC want $RC0)"
[ "$(sev_of 'rescued review = APPROVE')" = info ] && ok || bad "H5: the fallback must still beat info (beat: $(beat_of 'rescued review = APPROVE'))"
[ "$(grep -c 'rescued review = APPROVE' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "H5: exactly one APPROVE line"
sleep 0.3; [ ! -s "$T/ledger.txt" ] && ok || bad "H5: no ledger call without the lib (ledger: $(cat "$T/ledger.txt"))"

# ══ D5: the digest line ═════════════════════════════════════════════════════
. "$DIR/bin/lib/daily-digest-render.sh" || exit 1
FIX="$DIR/tests/fixtures/daily-digest/fixture-day.json"
OUT=$(dd_render "$FIX" https://console.test - 0 5 -)
grep -qxF 'Self-healed: 2 (context-gate 1, review-rescue 1) https://console.test/alerts' <<<"$OUT" && ok \
  || bad "D5: the Self-healed line (got: $(grep 'Self-healed' <<<"$OUT"))"
[ "$(sed -n '/^Tripwires:/,$p' <<<"$OUT" | grep -m1 -v '^  ' | head -1)" = "Tripwires: 8 https://console.test/alerts" ] && \
  [ "$(sed -n '/^Tripwires:/,$p' <<<"$OUT" | grep -v '^  ' | sed -n 2p | cut -c1-12)" = "Self-healed:" ] && ok \
  || bad "D5: Self-healed follows the Tripwires block"
jq '.self_heals = {ok: false, error: "no such table: ledgers"}' "$FIX" > "$T/fail.json"
grep -qxF 'Self-healed: n/a (read failed: no such table: ledgers) https://console.test/alerts' <<<"$(dd_render "$T/fail.json" https://console.test - 0 5 -)" && ok \
  || bad "D5: ok:false must render the failed(...) form"
jq '.self_heals = {ok: true, n: 0, by_source: {}, rows: [], truncated: false}' "$FIX" > "$T/zero.json"
grep -qxF 'Self-healed: 0 https://console.test/alerts' <<<"$(dd_render "$T/zero.json" https://console.test - 0 5 -)" && ok \
  || bad "D5: n 0 is a real 0 with its link"
jq 'del(.self_heals)' "$FIX" > "$T/old.json"
grep -q 'Self-healed' <<<"$(dd_render "$T/old.json" https://console.test - 0 5 -)" && bad "D5: a JSON without self_heals renders no line" || ok

echo "self-heal-notices: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
