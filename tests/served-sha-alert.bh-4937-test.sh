#!/bin/bash
# tests/served-sha-alert.bh-4937-test.sh — bin/lib/served-sha-watch.d/10-alert.sh
# (BH-4937, #4916 child 2): the served-sha watch's alert hook. An `alert`
# verdict becomes one `lane-alert.sh --severity critical --id
# served-behind:<p>:<head12>` page, an `in-sync` verdict one `--resolve` per
# open id.
#
# Every case runs the REAL bin/served-sha-watch.sh through
# tests/lib/served-sha-fixture.sh (stub curl/gh, recorder lane-alert writing
# $T/alerts.txt), with the repo's 10-alert.sh installed into the scratch hook dir.
#   S2   alert -> one critical page with the spelled-out text; open_ids == [id]
#   S3   a repeat tick re-calls lane-alert with the same id, open_ids stays 1;
#        S3r the REAL lane-alert dedupes it to one ALERTS.log line, then resolves
#   S4a  BUILDING under N -> wait, no page; S4b building / S4c failed:ERROR /
#        S4d ready-not-promoted deployment words
#   S5   in-sync after an alert -> one --resolve, state gone; S5n nothing open
#   S6   main moves while behind -> new id, old one kept; in-sync resolves both
#   S7   the hook's own compare read fails -> `? commits behind`, never 0;
#        S7n an unreadable tick pages nothing and resolves nothing
#   S8   a bad age -> `?m`, never 0m
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/served-sha-alert.bh-4937-test.sh  (exit 0 = pass)
# scratch-closure-allow: copies the hook file under test into the hook dir ssw_fx_reset empties; the lane's own closure is installed by ssw_fx_setup's scratch_install_closure
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/served-sha-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
HOOK="$DIR/bin/lib/served-sha-watch.d/10-alert.sh"
[ -s "$HOOK" ] || bad "setup: $HOOK is missing or empty"

ssw_fx_setup || { bad "setup: ssw_fx_setup failed"; exit 1; }
H="$T/h"
HD="$H/bin/lib/served-sha-watch.d"
SF="$H/state/served-sha-watch/demo-os.json"
AL="$T/alerts.txt"
cp "$H/bin/lane-alert.sh" "$T/recorder.sh"
H40=2b2272a4e1f0c3d5b6a7980112233445566778899
H40=${H40:0:40}
H2=7c6b5a4938271605f4e3d2c1b0a9f8e7d6c5b4a3
S40=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
ID="served-behind:demo-os:${H40:0:12}"
ID2="served-behind:demo-os:${H2:0:12}"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok formats a pinned epoch, reads no clock

install_hook() { mkdir -p "$HD" && cp "$HOOK" "$HD/10-alert.sh"; }
compare_ahead() { jq -nc --argjson n "$1" '{status:"ahead", ahead_by:$n, behind_by:0}' > "$T/fx/compare.json"; }
reset() { ssw_fx_reset; install_hook; }
base() { ssw_fx_head "${1:-$H40}" "$(iso $((NOW-${2:-1500})))"; ssw_fx_served "$S40"; compare_ahead 3; ssw_fx_list '{"deployments":[]}'; }
lines() { [ -f "$AL" ] && wc -l < "$AL" || echo 0; }
nopen() { jq -r '(.open_ids // []) | length' "$SF" 2>/dev/null || echo "-"; }
listrow() { jq -nc --arg s "$H40" --arg st "$1" '{deployments:[{uid:"dpl_x", target:"production", state:$st, meta:{githubCommitSha:$s}}]}'; }

# ── S2: the observable outcome ───────────────────────────────────────────────
reset; base; ssw_fx_run
L1=$(sed -n 1p "$AL" 2>/dev/null)
[ "$(lines)" = 1 ] && ok || bad "S2 exactly one alert line: $(cat "$AL" 2>&1) :: $(cat "$H/logs/served-sha-watch.log")"
for want in "--severity critical" "--id $ID" " served-sha-watch " \
            "demo-os: prod serves ${S40:0:8}, main is ${H40:0:8}" "merged 25m ago" \
            "3 commits behind" "deployment for ${H40:0:8}: none"; do
  case "$L1" in *"$want"*) ok ;; *) bad "S2 line lacks '$want': $L1" ;; esac
done
! grep -qP '\x{2014}' "$AL" 2>/dev/null && ok || bad "S2 an em dash in the alert: $L1"
! grep -rq fixture-token-1 "$AL" "$H/logs" 2>/dev/null && ok || bad "S2 the Vercel token leaked into an alert or log"
grep -q "/compare/$S40...$H40" "$T/req/gh.lines" && ok || bad "S2 compare read: $(cat "$T/req/gh.lines")"
[ "$(jq -c '.open_ids' "$SF" 2>/dev/null)" = "[\"$ID\"]" ] && ok || bad "S2 open_ids: $(cat "$SF" 2>&1)"
grep -q 'hook ssw_hook_alert rc=' "$H/logs/served-sha-watch.log" && bad "S2 hook rc non-zero: $(cat "$H/logs/served-sha-watch.log")" || ok

# ── S3: a repeat tick ────────────────────────────────────────────────────────
ssw_fx_run
[ "$(lines)" = 2 ] && [ "$(grep -c -- "--id $ID " "$AL")" = 2 ] && ok || bad "S3 two calls, same id: $(cat "$AL")"
[ "$(nopen)" = 1 ] && ok || bad "S3 open_ids deduped to 1: $(cat "$SF" 2>&1)"

# S3r: the REAL lane-alert behind the hook dedupes the page and resolves it.
reset; base
rm -f "$H/bin/lane-alert.sh"
scratch_install_closure bin/lane-alert.sh "$H" >/dev/null || bad "S3r install lane-alert closure"
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
: > "$T/alerts.conf"
ALERTS_CONF="$T/alerts.conf" ssw_fx_run; ALERTS_CONF="$T/alerts.conf" ssw_fx_run
SID="served-behind_demo-os_${H40:0:12}"
n=$(grep -c '\[orchestrator/served-sha-watch\] demo-os: prod serves' "$H/logs/ALERTS.log" 2>/dev/null)
[ "$n" = 1 ] && ok || bad "S3r one ALERTS.log line over two ticks, got $n: $(cat "$H/logs/ALERTS.log" 2>&1)"
[ -f "$H/state/alerts/$SID.json" ] && ok || bad "S3r state/alerts/$SID.json: $(ls "$H/state/alerts" 2>&1)"
ssw_fx_served "$H40"; ALERTS_CONF="$T/alerts.conf" ssw_fx_run
n=$(grep -c 'RESOLVED' "$H/logs/ALERTS.log" 2>/dev/null)
[ "$n" = 1 ] && ok || bad "S3r one RESOLVED line, got $n: $(cat "$H/logs/ALERTS.log" 2>&1)"
[ ! -e "$SF" ] && ok || bad "S3r state file deleted on in-sync"
rm -f "$H/bin/lane-alert.sh"; cp "$T/recorder.sh" "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"

# ── S4: deployment words ─────────────────────────────────────────────────────
reset; base "$H40" 600; ssw_fx_list "$(listrow BUILDING)"; ssw_fx_run
[ "$(lines)" = 0 ] && ok || bad "S4a BUILDING under N must not page: $(cat "$AL")"
reset; base; ssw_fx_list "$(listrow BUILDING)"; ssw_fx_run
[ "$(lines)" = 1 ] && grep -q "deployment for ${H40:0:8}: building)" "$AL" && ok || bad "S4b building: $(cat "$AL" 2>&1)"
reset; base "$H40" 600; ssw_fx_list "$(listrow ERROR)"; ssw_fx_run
[ "$(lines)" = 1 ] && grep -q "deployment for ${H40:0:8}: failed:ERROR)" "$AL" && grep -q "merged 10m ago" "$AL" \
  && ok || bad "S4c failed:ERROR: $(cat "$AL" 2>&1)"
reset; base; ssw_fx_list "$(listrow READY)"; ssw_fx_run
[ "$(lines)" = 1 ] && grep -q "deployment for ${H40:0:8}: ready-not-promoted)" "$AL" && ok || bad "S4d ready-not-promoted: $(cat "$AL" 2>&1)"

# ── S5: resolve ──────────────────────────────────────────────────────────────
reset; base; ssw_fx_run; ssw_fx_served "$H40"; ssw_fx_run
[ "$(lines)" = 2 ] && [ "$(sed -n 2p "$AL")" = "--resolve --id $ID served-sha-watch demo-os: prod serves ${H40:0:8}, main is ${H40:0:8}, back in sync" ] \
  && ok || bad "S5 one resolve: $(cat "$AL" 2>&1)"
[ ! -e "$SF" ] && ok || bad "S5 state gone after in-sync"
reset; ssw_fx_head "$H40"; ssw_fx_served "$H40"; ssw_fx_list '{"deployments":[]}'; ssw_fx_run
[ "$(lines)" = 0 ] && ok || bad "S5n in-sync with nothing open sends nothing: $(cat "$AL")"

# ── S6: main moves while behind ──────────────────────────────────────────────
reset; base; ssw_fx_run; ssw_fx_head "$H2" "$(iso $((NOW-1500)))"; ssw_fx_run
[ "$(lines)" = 2 ] && sed -n 2p "$AL" | grep -q -- "--id $ID2 " && ! grep -q -- --resolve "$AL" \
  && ok || bad "S6 new head pages its own id, no resolve: $(cat "$AL" 2>&1)"
[ "$(nopen)" = 2 ] && ok || bad "S6 open_ids keeps both: $(cat "$SF" 2>&1)"
ssw_fx_served "$H2"; ssw_fx_run
[ "$(grep -c -- '^--resolve ' "$AL")" = 2 ] && grep -q -- "--resolve --id $ID " "$AL" && grep -q -- "--resolve --id $ID2 " "$AL" \
  && ok || bad "S6b both ids resolved: $(cat "$AL" 2>&1)"
[ ! -e "$SF" ] && ok || bad "S6b state gone"

# ── S7: the hook's own compare read fails ────────────────────────────────────
reset; base
printf 'ssw_hook_aflip() { printf 500 > "$SSW_FX_T/fx/compare.code"; }\n' > "$HD/05-flip.sh"
ssw_fx_run
[ "$(lines)" = 1 ] && grep -q '? commits behind' "$AL" && ! grep -q ' 0 commits behind' "$AL" \
  && ok || bad "S7 unread compare is '? commits behind': $(cat "$AL" 2>&1) :: $(cat "$H/logs/served-sha-watch.log")"
reset; base; ssw_fx_run; printf 500 > "$T/fx/alias.code"; ssw_fx_run
[ "$(lines)" = 1 ] && ok || bad "S7n an unreadable tick neither pages nor resolves: $(cat "$AL" 2>&1)"

# ── S8: a bad age is ?m ──────────────────────────────────────────────────────
reset; base
( . "$HD/10-alert.sh"; export SSW_SLUG=example-org/demo-os; mkdir -p "$H/state/served-sha-watch"
  ssw_hook_alert demo-os alert "$H40" "$S40" none "" "$SF" ) >/dev/null 2>&1
grep -q 'merged ?m ago' "$AL" && ! grep -q 'merged 0m ago' "$AL" && ok || bad "S8 empty age is ?m: $(cat "$AL" 2>&1)"

echo "served-sha-alert.bh-4937: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
