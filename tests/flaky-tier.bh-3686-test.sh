#!/bin/bash
# tests/flaky-tier.bh-3686-test.sh — BH-3701 (4 of 5 of BH-3686): the daily
# auto-quarantine lane, bin/flaky-tier.sh, driven as shipped.
#
# The real lane runs against a scratch $HARNESS. The seams are stubbed, and
# nothing else is:
#   bin/jobs-client.sh  sources the REAL bin/lib/jobs/cost.sh clients and puts
#                       a stateful _jobs_req under them (a PUT upserts the row
#                       the next read returns, the way the worker does)
#   gh (on PATH)        answers `gh api -i` with an HTTP status line and a body
#                       per route, so the real bin/lib/gh-rest*.sh parse it
#   bin/lane-alert.sh   records its argv
# Every call lands in calls.log, one line each, in order.
#
# Cases: F1 quarantine (ticket, then row, then variable) and a quiet second
# tick; F1b label read-back; F1c PATCH; F2 under threshold; F3 protected pages
# and resolves; F3b a console row for a protected suite is not projected; F4
# mass cap; F5a rows unreadable stops; F5b issue search rc 75; F5c evidence
# unreadable still projects; F6 the release cutoff; F7 dry-run, ACT=0, a held
# lock; F7b a bad knob; F8 one tick line and no token anywhere.
#
# Run from anywhere: tests/flaky-tier.bh-3686-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LANE="$DIR/bin/flaky-tier.sh"
FAKE_NOW=1790769600            # 2026-09-30 12:00:00Z; window 7d => since 2026-09-23
SLUG=example-org/cromford
TOKEN=ghp_FIXTURE_ADMIN_TOKEN
H="$T/h"; FX="$T/fx"; CALLS="$T/calls.log"
mkdir -p "$H/bin/lib" "$H/env" "$H/tests" "$H/catalog" "$T/stubbin"
for f in env-path.sh gh-rest.sh gh-rest-list.sh gh-rest-var.sh test-protected.sh gh-ci-read.sh flaky-tier-release.sh; do
  ln -s "$DIR/bin/lib/$f" "$H/bin/lib/$f"
done
ln -s "$LANE" "$H/bin/flaky-tier.sh"
for s in a b c d e switch-x; do printf '#!/bin/bash\n' > "$H/tests/$s-test.sh"; done
printf 'tests/switch-x-test.sh   fixture protected suite\n' > "$H/catalog/test-quarantine-protected.txt"
printf 'GH_ADMIN_TOKEN=%s\n' "$TOKEN" > "$H/env/github-admin.env"

cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "ALERT \$*" >> "$CALLS"
EOF

cat > "$H/bin/jobs-client.sh" <<EOF
#!/bin/bash
# shellcheck source=/dev/null
. "$DIR/bin/lib/jobs/cost.sh"
_jobs_req() {
  echo "JOBS \$1 \$2 \${3:-}" >> "$CALLS"
  case "\$1 \$2" in
    "GET /api/metrics/flakes/quarantine?"*) [ -f "$FX/rows.fail" ] && return 1; cat "$FX/rows.json" ;;
    "GET /api/metrics/flakes?"*) [ -f "$FX/flakes.fail" ] && return 1; cat "$FX/flakes.json" ;;
    "PUT /api/metrics/flakes/quarantine")
      [ -f "$FX/put.fail" ] && return 1
      jq -c --argjson b "\$3" '.rows = ([.rows[] | select(.test != \$b.test)] + [\$b + {updated_at: "2026-09-30 12:00:00"}])' \
        "$FX/rows.json" > "$FX/rows.tmp" && mv "$FX/rows.tmp" "$FX/rows.json"
      echo '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
EOF

cat > "$T/stubbin/gh" <<EOF
#!/bin/bash
# gh api -i -X <M> <path> [args...]
shift; M=; P=
while [ \$# -gt 0 ]; do case "\$1" in -i) shift ;; -X) M="\$2"; shift 2 ;; *) P="\$1"; shift; break ;; esac; done
tok=other; [ "\${GH_TOKEN:-}" = "$TOKEN" ] && tok=admin
echo "GH \$M \$P tok=\$tok | \$*" >> "$CALLS"
val=; body=
for a in "\$@"; do case "\$a" in value=*) val="\${a#value=}" ;; body=@*) body="\${a#body=@}" ;; esac; done
reply() { printf 'HTTP/2 %s X\r\n\r\n%s\n' "\$1" "\${2:-}"; }
case "\$M \$P" in
  "GET repos/$SLUG/issues") reply "\$(cat "$FX/issues.status" 2>/dev/null || echo 200)" "\$(cat "$FX/issues.json" 2>/dev/null || echo '[]')" ;;
  "POST repos/$SLUG/issues")
    n=\$(( \$(cat "$FX/next" 2>/dev/null || echo 40) + 1 )); echo "\$n" > "$FX/next"
    cp "\$body" "$FX/issue-body.\$n"
    if [ -f "$FX/drop-label" ]; then reply 201 "{\"number\":\$n,\"labels\":[]}"
    else reply 201 "{\"number\":\$n,\"labels\":[{\"name\":\"ai-build\"}]}"; fi ;;
  "POST repos/$SLUG/issues/"*/labels) reply 200 '[{"name":"ai-build"}]' ;;
  "GET repos/$SLUG/actions/variables/CI_QUARANTINE")
    if [ -f "$FX/var" ]; then reply 200 "{\"name\":\"CI_QUARANTINE\",\"value\":\"\$(cat "$FX/var")\"}"; else reply 404 '{"message":"Not Found"}'; fi ;;
  "POST repos/$SLUG/actions/variables") printf '%s' "\$val" > "$FX/var"; reply 201 '{}' ;;
  "PATCH repos/$SLUG/actions/variables/CI_QUARANTINE") printf '%s' "\$val" > "$FX/var"; reply 204 '' ;;
  *) reply 500 '{}' ;;
esac
EOF
chmod +x "$H/bin/lane-alert.sh" "$T/stubbin/gh"

# reset — a fresh world: no rows, no flakes, no issues, no variable, no state.
reset() {
  local d; for d in "$FX" "$H/state" "$H/logs" "$H/locks"; do scratch_rm "$d" || exit 1; done; mkdir -p "$FX"
  : > "$CALLS"; : > "$FX/flakes.tsv"
  echo '{"rows":[]}' > "$FX/rows.json"; flakes_json
}
# fl <day> <suite> <head> [kind] — one ledger row.
fl() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-flake}" >> "$FX/flakes.tsv"; flakes_json; }
flakes_json() {
  jq -R -s -c --arg r "$SLUG" '{flakes: [split("\n")[] | select(. != "") | split("\t")
    | {day: .[0], repo: $r, workflow: "harness-ci", test: .[1], head: .[2], kind: .[3]}]}' "$FX/flakes.tsv" > "$FX/flakes.json"
}
# row <suite> <active> <actor> <updated_at> — one quarantine row.
row() { jq -c --arg t "$1" --argjson a "$2" --arg c "$3" --arg u "$4" \
  '.rows += [{test: $t, active: $a, actor: $c, updated_at: $u, reason: "fixture"}]' "$FX/rows.json" > "$FX/r" && mv "$FX/r" "$FX/rows.json"; }
# run [args] — one tick of the real lane; stdout+stderr to $T/out.
run() {
  env HARNESS="$H" PATH="$T/stubbin:$PATH" FLAKY_TIER_NOW="$FAKE_NOW" "$@" > "$T/out" 2>&1
}
cnt() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
cntx() { grep -cx -- "$1" "$CALLS" 2>/dev/null || true; }
three() { fl 2026-09-26 "$1" "${2}1"; fl 2026-09-27 "$1" "${2}2"; fl 2026-09-28 "$1" "${2}3"; }

# ── F1: three heads plus a repeat => ticket, then row, then variable ─────────
reset; three tests/a-test.sh aa; fl 2026-09-28 tests/a-test.sh aa3
run bash "$LANE" cromford; RC=$?
[ "$RC" = 0 ] && ok || bad "F1 rc=$RC: $(cat "$T/out")"
[ "$(cntx "GH POST repos/$SLUG/issues tok=other | .*")" = 1 ] && ok || bad "F1: issue POSTs=$(cntx "GH POST repos/$SLUG/issues tok=other | .*")"
[ "$(cnt 'labels\[\]=ai-build')" = 1 ] && ok || bad "F1: ai-build label not on the create"
[ "$(grep -c -- '<!-- harness-flaky-quarantine: tests/a-test.sh -->' "$FX/issue-body.41" 2>/dev/null)" = 1 ] && ok || bad "F1: issue body has no marker"
PUTS=$(cnt '^JOBS PUT /api/metrics/flakes/quarantine')
[ "$PUTS" = 1 ] && ok || bad "F1: PUTs=$PUTS"
PUTL=$(grep '^JOBS PUT' "$CALLS")
case "$PUTL" in *'"active":1'*'"actor":"flaky-tier"'*) ok ;; *) bad "F1: PUT body '$PUTL'" ;; esac
case "$PUTL" in *'fix #41'*) ok ;; *) bad "F1: PUT reason lacks fix #41: '$PUTL'" ;; esac
case "$PUTL" in *'3 flaky heads'*) ok ;; *) bad "F1: repeat head counted twice: '$PUTL'" ;; esac
LP=$(grep -n "^GH POST repos/$SLUG/issues tok" "$CALLS" | cut -d: -f1); LU=$(grep -n '^JOBS PUT' "$CALLS" | cut -d: -f1)
[ -n "$LP" ] && [ -n "$LU" ] && [ "$LP" -lt "$LU" ] && ok || bad "F1: POST line $LP not before PUT line $LU"
[ "$(cnt "^GH POST repos/$SLUG/actions/variables tok=admin")" = 1 ] && ok || bad "F1: variable POST (admin) count=$(cnt "^GH POST repos/$SLUG/actions/variables tok=admin")"
[ "$(cat "$FX/var" 2>/dev/null)" = tests/a-test.sh ] && ok || bad "F1: variable='$(cat "$FX/var" 2>/dev/null)'"
[ "$(cnt 'tok=admin')" = "$(cnt '/actions/variables')" ] && [ "$(cnt "issues tok=admin")" = 0 ] && ok || bad "F1: admin token outside the variable calls"
grep -c 'candidates=1 quarantined=1 protected=0 released=0 projection=updated$' "$H/logs/flaky-tier.log" >/dev/null && ok || bad "F1 tick line: $(cat "$H/logs/flaky-tier.log")"
# tick 2: the row is active now, the variable already says so => no writes.
: > "$CALLS"; run bash "$LANE" cromford
W2=$(grep -cE '^GH (POST|PATCH)|^JOBS PUT' "$CALLS")
[ "$W2" = 0 ] && ok || bad "F1 tick 2 wrote $W2 times: $(cat "$CALLS")"
grep -c 'candidates=0 quarantined=0 protected=0 released=0 projection=same$' "$H/logs/flaky-tier.log" >/dev/null && ok || bad "F1 tick 2 line: $(tail -1 "$H/logs/flaky-tier.log")"

# ── F1b: the create drops the label => one /labels POST, then the row ────────
reset; three tests/a-test.sh ab; touch "$FX/drop-label"; run bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues/41/labels ")" = 1 ] && ok || bad "F1b: /labels POSTs=$(cnt "/labels ")"
[ "$(cnt '^JOBS PUT')" = 1 ] && ok || bad "F1b: PUTs=$(cnt '^JOBS PUT')"

# ── F1c: a variable that differs => PATCH ────────────────────────────────────
reset; three tests/a-test.sh ac; printf '%s' '-' > "$FX/var"; run bash "$LANE" cromford
[ "$(cnt "^GH PATCH repos/$SLUG/actions/variables/CI_QUARANTINE tok=admin")" = 1 ] && [ "$(cnt '^GH POST repos/.*/actions/variables ')" = 0 ] \
  && ok || bad "F1c: $(grep variables "$CALLS")"
[ "$(cat "$FX/var")" = tests/a-test.sh ] && ok || bad "F1c: variable='$(cat "$FX/var")'"

# ── F2: two heads => nothing ─────────────────────────────────────────────────
reset; fl 2026-09-26 tests/a-test.sh f1; fl 2026-09-27 tests/a-test.sh f2; printf '%s' '-' > "$FX/var"
run bash "$LANE" cromford
W=$(grep -cE '^GH (POST|PATCH)|^JOBS PUT' "$CALLS"); [ "$W" = 0 ] && ok || bad "F2 wrote $W: $(cat "$CALLS")"
# adversarial negatives: red kind, one head x3, a lib path, a job: test, a deleted suite
reset; printf '%s' '-' > "$FX/var"
three tests/b-test.sh rb; sed -i 's/flake$/red/' "$FX/flakes.tsv"; flakes_json
fl 2026-09-26 tests/c-test.sh one; fl 2026-09-27 tests/c-test.sh one; fl 2026-09-28 tests/c-test.sh one
three tests/lib/x.sh lx; three job:harness-ci jx; three tests/gone-test.sh gx
run bash "$LANE" cromford
W=$(grep -cE '^GH (POST|PATCH)|^JOBS PUT' "$CALLS"); [ "$W" = 0 ] && ok || bad "F2 negatives wrote $W: $(cat "$CALLS")"

# ── F3: a protected suite pages, never quarantines; resolves below N ─────────
reset; three tests/switch-x-test.sh sx; run bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues")" = 0 ] && [ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "F3: quarantined a protected suite: $(cat "$CALLS")"
[ "$(cnt '^ALERT .*--id flaky-protected:tests/switch-x-test.sh --severity critical')" = 1 ] && ok || bad "F3: protected page count=$(cnt 'flaky-protected')"
grep -c 'protected=1' "$H/logs/flaky-tier.log" >/dev/null && ok || bad "F3 tick line: $(cat "$H/logs/flaky-tier.log")"
: > "$CALLS"; : > "$FX/flakes.tsv"; fl 2026-09-26 tests/switch-x-test.sh sx1; fl 2026-09-27 tests/switch-x-test.sh sx2
run bash "$LANE" cromford
[ "$(cnt '^ALERT --resolve --id flaky-protected:tests/switch-x-test.sh ')" = 1 ] && ok || bad "F3: no resolve: $(grep ALERT "$CALLS")"
: > "$CALLS"; run bash "$LANE" cromford
[ "$(cnt 'flaky-protected:')" = 0 ] && ok || bad "F3: resolve repeated: $(grep ALERT "$CALLS")"
# F3b: a console-written active row for the protected suite is not projected.
reset; row tests/switch-x-test.sh 1 console 2026-09-29; row tests/b-test.sh 1 main-red-bisect 2026-09-29
row tests/gone-test.sh 1 console 2026-09-29
run bash "$LANE" cromford
[ "$(cat "$FX/var" 2>/dev/null)" = tests/b-test.sh ] && ok || bad "F3b: variable='$(cat "$FX/var" 2>/dev/null)'"
grep -c 'row names a missing suite: tests/gone-test.sh' "$T/out" >/dev/null && ok || bad "F3b: missing suite not logged"

# ── F4: over the cap => none quarantined, one mass page ─────────────────────
reset; three tests/a-test.sh ma; three tests/b-test.sh mb; three tests/c-test.sh mc; three tests/d-test.sh md
run env FLAKY_TIER_MAX_NEW=3 bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues")" = 0 ] && [ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "F4: quarantined over the cap"
[ "$(cnt "^ALERT .*--id flaky-tier-mass:$SLUG --severity critical")" = 1 ] && ok || bad "F4: mass pages=$(cnt 'flaky-tier-mass')"

# ── F5a: rows unreadable => stop, one warn, no writes ───────────────────────
reset; three tests/a-test.sh ra; touch "$FX/rows.fail"; run bash "$LANE" cromford; RC=$?
[ "$RC" = 0 ] && ok || bad "F5a rc=$RC"
W=$(grep -cE '^GH |^JOBS PUT' "$CALLS"); [ "$W" = 0 ] && ok || bad "F5a: $W GitHub/PUT calls: $(cat "$CALLS")"
[ "$(cnt '^ALERT ')" = 1 ] && [ "$(cnt '^ALERT --id flaky-tier-rows-unreadable --severity warn ')" = 1 ] && ok || bad "F5a alerts: $(grep ALERT "$CALLS")"
grep -c 'projection=skipped$' "$H/logs/flaky-tier.log" >/dev/null && ok || bad "F5a tick: $(cat "$H/logs/flaky-tier.log")"
# the next good read resolves it
rm -f "$FX/rows.fail"; : > "$CALLS"; run bash "$LANE" cromford
[ "$(cnt '^ALERT --resolve --id flaky-tier-rows-unreadable ')" = 1 ] && ok || bad "F5a: no resolve"

# ── F5b: the issue search is rate-limited => skip, no POST, no PUT ──────────
reset; three tests/a-test.sh rl; echo 403 > "$FX/issues.status"; echo '{"message":"API rate limit exceeded"}' > "$FX/issues.json"
run bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues")" = 0 ] && [ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "F5b: wrote on an unknown search"
grep -c 'issue search unknown (HTTP 403)' "$T/out" >/dev/null && ok || bad "F5b: skip not logged: $(cat "$T/out")"

# ── F5c: evidence unreadable => no candidates, projection still runs ────────
reset; touch "$FX/flakes.fail"; row tests/b-test.sh 1 console 2026-09-29; run bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues")" = 0 ] && [ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "F5c: wrote on no evidence"
[ "$(cat "$FX/var" 2>/dev/null)" = tests/b-test.sh ] && ok || bad "F5c: projection did not run"

# ── F6: an inactive row's day is a cutoff ───────────────────────────────────
reset; row tests/a-test.sh 0 flaky-tier "2026-09-25 08:00:00"
fl 2026-09-24 tests/a-test.sh o1; fl 2026-09-25 tests/a-test.sh o2; fl 2026-09-26 tests/a-test.sh n1
printf '%s' '-' > "$FX/var"
run bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues")" = 0 ] && [ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "F6: old heads re-quarantined: $(cat "$CALLS")"
# three heads after the cutoff; the old ticket (#7) is closed, so not in the open list
: > "$CALLS"; fl 2026-09-27 tests/a-test.sh n2; fl 2026-09-28 tests/a-test.sh n3
run bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues tok")" = 1 ] && [ "$(cnt '^JOBS PUT')" = 1 ] && ok || bad "F6: three new heads did not quarantine: $(cat "$CALLS")"
# an open ticket with the marker is reused, never duplicated
reset; three tests/a-test.sh ru
printf '[{"number":9,"body":"x\\n<!-- harness-flaky-quarantine: tests/a-test.sh -->\\n"},{"number":8,"body":null}]' > "$FX/issues.json"
run bash "$LANE" cromford
[ "$(cnt "^GH POST repos/$SLUG/issues")" = 0 ] && [ "$(cnt '^JOBS PUT.*fix #9')" = 1 ] && ok || bad "F6: open ticket not reused: $(cat "$CALLS")"

# ── F7: dry-run and ACT=0 write nothing; a held lock is a no-op ─────────────
for mode in dry act0; do
  reset; three tests/a-test.sh dr; three tests/switch-x-test.sh dx
  if [ "$mode" = dry ]; then run bash "$LANE" cromford --dry-run; else run env FLAKY_TIER_ACT=0 bash "$LANE" cromford; fi
  W=$(grep -cE '^GH (POST|PATCH)|^JOBS PUT|^ALERT' "$CALLS"); [ "$W" = 0 ] && ok || bad "F7 $mode wrote $W: $(cat "$CALLS")"
  grep -c '^  would: ' "$T/out" >/dev/null && ok || bad "F7 $mode: no would: lines"
  grep -c '^  would: alert --id flaky-protected:tests/switch-x-test.sh --severity critical: .*protected suite' "$T/out" >/dev/null \
    && ok || bad "F7 $mode: the would-alert line does not say what it would send"
  grep -c ' \[dry-run\]$' "$H/logs/flaky-tier.log" >/dev/null && ok || bad "F7 $mode tick: $(cat "$H/logs/flaky-tier.log")"
  [ ! -e "$H/state/flaky-tier/protected-open.example-org_cromford" ] && ok || bad "F7 $mode wrote the state file"
done
reset; three tests/a-test.sh lk; mkdir -p "$H/locks"
( flock -n 9 || exit 1; run bash "$LANE" cromford; echo "$?" > "$T/lockrc" ) 9>"$H/locks/flaky-tier.lock"
[ "$(cat "$T/lockrc")" = 0 ] && [ ! -s "$CALLS" ] && ok || bad "F7 lock: rc=$(cat "$T/lockrc") calls=$(cat "$CALLS")"
# F7b: a bad knob says so and uses its default
reset; fl 2026-09-26 tests/a-test.sh k1; fl 2026-09-27 tests/a-test.sh k2
run env FLAKY_TIER_MIN=abc bash "$LANE" cromford
grep -c "FLAKY_TIER_MIN='abc' is not a positive integer; using 3" "$T/out" >/dev/null && ok || bad "F7b: no fallback line: $(cat "$T/out")"
[ "$(cnt '^JOBS PUT')" = 0 ] && ok || bad "F7b: 2 heads quarantined under MIN=abc"

# ── F8: one tick line per run; the admin token is nowhere ───────────────────
reset; three tests/a-test.sh tk; run bash "$LANE" cromford; cat "$T/out" > "$T/all-out"
[ "$(grep -c "flaky-tier $SLUG: candidates=" "$H/logs/flaky-tier.log")" = 1 ] && ok || bad "F8: tick lines after 1"
run bash "$LANE" cromford; cat "$T/out" >> "$T/all-out"
[ "$(grep -c "flaky-tier $SLUG: candidates=" "$H/logs/flaky-tier.log")" = 2 ] && ok || bad "F8: tick lines after 2"
LEAK=$(grep -rl -- "$TOKEN" "$H/logs" "$T/all-out" "$CALLS" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "F8: token leaked into $LEAK"
# the projection alert on a missing token never names a token either
reset; rm -f "$H/env/github-admin.env"; run bash "$LANE" cromford
[ "$(cnt "^ALERT --id flaky-tier-projection:$SLUG --severity warn .*no admin token")" = 1 ] && ok || bad "F8: no-token alert: $(grep ALERT "$CALLS")"
grep -c 'projection=failed$' "$H/logs/flaky-tier.log" >/dev/null && ok || bad "F8: no-token tick: $(cat "$H/logs/flaky-tier.log")"
printf 'GH_ADMIN_TOKEN=%s\n' "$TOKEN" > "$H/env/github-admin.env"

# -h prints the header, exit 0
bash "$LANE" -h > "$T/help" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -c 'flaky-tier.sh' "$T/help" >/dev/null && ok || bad "-h rc=$RC"

echo "flaky-tier: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
