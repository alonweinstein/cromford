#!/bin/bash
# tests/served-sha-watch.bh-4936-test.sh — bin/served-sha-watch.sh and
# bin/lib/served-sha-watch.sh (BH-4936, the tracer of #4916): the hub lane that
# compares what each Vercel production domain serves with main HEAD.
#
# WHY. project-3 #467 merged 2026-10-06T16:10Z as 2b2272a4, Vercel never created
# a deployment for it, prod served a ~5h old build and nothing noticed.
#
# The J/D/U cases drive the lib's functions directly; every S/H case runs the
# REAL bin/served-sha-watch.sh through its entry point in the scratch harness
# tests/lib/served-sha-fixture.sh builds (stub curl answering Vercel, stub gh
# answering GitHub, nothing leaving the box).
#   J1-J8  ssw_judge: prefix match, compare identical/behind, the inclusive age
#          boundary, failed alerts at once, empty/short/non-hex is unreadable,
#          an unread compare is unreadable, no head date is wait
#   D1-D4  ssw_dep_state: building/ready/failed/none/unread off /v6/deployments
#   U1-U3  ssw_state_read / ssw_state_write
#   S1     served == HEAD -> in_sync=1, no state, no POST
#   S2     the observable outcome: HEAD 25m old, no deployment -> alert state,
#          log line, summary; no alert sent, no POST
#   S2b/c  no committer date -> first_seen fallback; a new head resets it
#   S7a-d  alias 500, commits/main 429, no git sha, compare 429 -> unreadable,
#          state left byte-identical
#   S8a-c  lag 0 / lane-off flag -> zero requests; a bad lag falls back to 20
#   S9a/b  the token is never written anywhere; no auth file -> not configured
#   S10    a held lock skips the tick; S11 a corrupt state is rewritten
#   S12    SERVED_SHA_CONF; S13 ENDPOINT_VERCEL registry default; S14 timeout
#   S15    SERVED_SHA_AUTODEPLOY normalised for hooks
#   H1-H3  the hook contract: argv, env, a failing hook, lexical order
#   M1/M2  mutations of the judge turn J3/J5 red
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/served-sha-watch.bh-4936-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/served-sha-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); [ "${QUIET:-0}" = 1 ] || echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
SRC="$DIR/bin/served-sha-watch.sh"
JLIB="$DIR/bin/lib/served-sha-watch.sh"
for f in "$SRC" "$JLIB"; do [ -s "$f" ] || bad "setup: $f is missing or empty"; done

ssw_fx_setup || bad "setup: ssw_fx_setup failed (is bin/served-sha-watch.sh there?)"
H="$T/h"
LOG="$H/logs/served-sha-watch.log"
SF="$H/state/served-sha-watch/demo-os.json"
H40=2b2272a4e1f0c3d5b6a7980112233445566778899
H40=${H40:0:40}
S40=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok formats a pinned epoch, reads no clock

# ── J: the judge, pure ───────────────────────────────────────────────────────
J() { ( . "$JLIB" 2>/dev/null; ssw_judge "$@" ) 2>/dev/null; }
jis() { local want="$1" name="$2"; shift 2; local got; got=$(J "$@")
  [ "$got" = "$want" ] && ok || bad "$name: ssw_judge $* -> '$got', want $want"; }
case_j() {
  jis in-sync J1 "$NOW" $((NOW-60)) 1200 "$H40" "$H40" "" none
  jis in-sync J2a "$NOW" $((NOW-60)) 1200 "$H40" "${H40:0:8}" "" none
  jis unreadable J2b "$NOW" $((NOW-60)) 1200 "$H40" "${H40:0:7}" "" none
  jis alert J3 "$NOW" $((NOW-1200)) 1200 "$H40" "$S40" ahead none
  jis wait J4 "$NOW" $((NOW-1199)) 1200 "$H40" "$S40" ahead none
  jis alert J5 "$NOW" $((NOW-60)) 1200 "$H40" "$S40" ahead failed
  jis in-sync J6a "$NOW" $((NOW-9999)) 1200 "$H40" "$S40" behind none
  jis in-sync J6b "$NOW" $((NOW-9999)) 1200 "$H40" "$S40" identical none
  jis unreadable J7a "$NOW" $((NOW-9999)) 1200 "$H40" "" ahead none
  jis unreadable J7b "$NOW" $((NOW-9999)) 1200 "" "$S40" ahead none
  jis unreadable J7c "$NOW" $((NOW-9999)) 1200 "$H40" zzzzzzzz ahead none
  jis unreadable J8a "$NOW" $((NOW-9999)) 1200 "$H40" "$S40" "" none
  jis alert J8b "$NOW" $((NOW-1300)) 1200 "$H40" "$S40" diverged none
  jis wait J8c "$NOW" "" 1200 "$H40" "$S40" ahead none
  jis wait J8d "$NOW" $((NOW-600)) 1200 "$H40" "$S40" ahead building
}
case_j

# ── D: dep_state off the curl stub ───────────────────────────────────────────
dep() { ( . "$JLIB" 2>/dev/null; SSW_BASE=https://vercel.stub SSW_TOKEN=x; ssw_dep_state team_x prj_x "$H40" ) 2>/dev/null; }
row() { jq -nc --arg s "$1" --arg st "$2" '{uid:"dpl_\($st)", state:$st, meta:{githubCommitSha:$s}}'; }
dis() { local want="$1" name="$2" json="$3" code="${4:-200}" got
  ssw_fx_reset; ssw_fx_list "$json"; printf '%s' "$code" > "$T/fx/list.code"
  got=$(dep); [ "$got" = "$want" ] && ok || bad "$name: dep_state -> '$got', want $want"; }
dis building D1 "{\"deployments\":[$(row "$H40" BUILDING)]}"
dis building D2 "{\"deployments\":[$(row "$H40" CANCELED),$(row "$H40" BUILDING)]}"
dis ready D3 "{\"deployments\":[$(row "$H40" READY)]}"
dis failed D4a "{\"deployments\":[$(row "$H40" ERROR)]}"
dis none D4b '{"deployments":[]}'
dis none D4c "{\"deployments\":[$(row "$S40" ERROR),$(row "$S40" READY)]}"
dis unread D4d '{"error":"x"}' 500
dis unread D4e 'not json'
grep -q "/v6/deployments?projectId=prj_x&teamId=team_x&target=production&limit=20" "$T/req/argv.lines" \
  && ok || bad "D5 the list read is target=production limit=20: $(cat "$T/req/argv.lines")"

# ── U: state helpers ─────────────────────────────────────────────────────────
U() { ( . "$JLIB" 2>/dev/null; "$@" ) 2>/dev/null; }
out=$(U ssw_state_read "$T/nope.json"); rc=$?
[ "$rc" = 0 ] && [ "$out" = '{}' ] && ok || bad "U1 missing state reads {} rc 0, got rc=$rc '$out'"
printf 'not json' > "$T/bad.json"
U ssw_state_read "$T/bad.json" >/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "U2 corrupt state is rc 2, got $rc"
printf 'x' > "$T/afile"
U ssw_state_write "$T/afile/s.json" '{"a":1}'; rc=$?
[ "$rc" != 0 ] && ok || bad "U3a a write under a non-directory must fail"
mkdir -p "$T/isdir/s.json"
U ssw_state_write "$T/isdir/s.json" '{"a":1}'; rc=$?
[ "$rc" != 0 ] && ok || bad "U3b a write onto a directory must fail"
[ -z "$(find "$T/isdir" -name '*.tmp.*')" ] && ok || bad "U3c a failed write left a .tmp file"
U ssw_state_write "$T/good/s.json" 'not json'; rc=$?
[ "$rc" != 0 ] && [ ! -e "$T/good/s.json" ] && ok || bad "U3d invalid JSON must not be written"
U ssw_state_write "$T/good/s.json" '{"head":"abc","first_seen":5}' && \
  [ "$(U ssw_state_read "$T/good/s.json" | jq -c .)" = '{"head":"abc","first_seen":5}' ] \
  && ok || bad "U3e a good write round-trips"

# ── S: the real driver ───────────────────────────────────────────────────────
summary() { grep -o 'checked=.*' "$LOG" 2>/dev/null | tail -n 1; }
nopost() { grep -q '^POST' "$T/req/argv.lines" && bad "$1 sent a POST: $(cat "$T/req/argv.lines")" || ok; }
noreq() { [ ! -s "$T/req/argv.lines" ] && [ ! -s "$T/req/gh.lines" ] && ok || bad "$1 made requests: $(cat "$T/req/argv.lines" "$T/req/gh.lines")"; }
notoken() {
  grep -rq "$SSW_FX_TOKEN" "$H/logs" "$H/state" "$T/req/argv.lines" "$T/req/gh.lines" "$T/out" \
    && bad "$1 the token reached a log, state, argv or stdout" || ok
  grep -q 'Authorization: Bearer <redacted>' "$T/req/stdin.lines" && ok || bad "$1 no Authorization header reached curl's stdin config"
}
s2_fixture() { ssw_fx_head "$H40" "$(iso $((NOW-1500)))"; ssw_fx_served "$S40"; ssw_fx_compare ahead; ssw_fx_list '{"deployments":[]}'; }

case_s1() {
  ssw_fx_reset; ssw_fx_head "$H40"; ssw_fx_served "$H40"; ssw_fx_list '{"deployments":[]}'
  ssw_fx_run
  [ "$SSW_RC" = 0 ] && ok || bad "S1 rc 0, got $SSW_RC: $(cat "$T/out")"
  [ "$(summary)" = "checked=1 in_sync=1 wait=0 alert=0 unreadable=0" ] && ok || bad "S1 summary: $(cat "$LOG")"
  [ ! -e "$SF" ] && ok || bad "S1 in-sync leaves no state file"
  grep -q compare "$T/req/gh.lines" && bad "S1 compare read although the shas match" || ok
  nopost S1; notoken S1
}
case_s1

# S1b: the project caught up — the state an earlier wait tick left is deleted.
ssw_fx_reset; ssw_fx_head "$H40"; ssw_fx_served "$H40"; ssw_fx_list '{"deployments":[]}'
mkdir -p "$(dirname "$SF")"; printf '{"head":"%s","first_seen":1,"last_verdict":"wait"}\n' "$H40" > "$SF"
ssw_fx_run
[ ! -e "$SF" ] && ok || bad "S1b an in-sync tick deletes the earlier state: $(cat "$SF" 2>&1)"

case_s2() {
  ssw_fx_reset; s2_fixture
  ssw_fx_run
  [ "$SSW_RC" = 0 ] && ok || bad "S2 rc 0, got $SSW_RC: $(cat "$T/out")"
  [ "$(jq -r '.last_verdict' "$SF" 2>/dev/null)" = alert ] && ok || bad "S2 state last_verdict alert: $(cat "$SF" 2>&1)"
  [ "$(jq -r '.head' "$SF" 2>/dev/null)" = "$H40" ] && ok || bad "S2 state head"
  [ "$(jq -r '.first_seen' "$SF" 2>/dev/null)" = "$NOW" ] && ok || bad "S2 state first_seen == NOW"
  [ "$(jq -r '.served' "$SF" 2>/dev/null)" = "$S40" ] && [ "$(jq -r '.dep_state' "$SF" 2>/dev/null)" = none ] \
    && ok || bad "S2 state served/dep_state: $(cat "$SF" 2>&1)"
  grep -q "demo-os alert served=${S40:0:8} head=${H40:0:8} age=25m deployment: none$" "$LOG" \
    && ok || bad "S2 log line: $(cat "$LOG")"
  [ "$(summary)" = "checked=1 in_sync=0 wait=0 alert=1 unreadable=0" ] && ok || bad "S2 summary: $(cat "$LOG")"
  [ ! -e "$T/alerts.txt" ] && ok || bad "S2 an alert was sent: $(cat "$T/alerts.txt")"
  grep -q "compare/$S40...$H40" "$T/req/gh.lines" && ok || bad "S2 compare served...head read: $(cat "$T/req/gh.lines")"
  nopost S2; notoken S2
}
case_s2

# D1b: through the driver, HEAD 10m old and still building is a wait that says so.
ssw_fx_reset; s2_fixture; ssw_fx_head "$H40" "$(iso $((NOW-600)))"
ssw_fx_list "{\"deployments\":[$(row "$H40" BUILDING)]}"; ssw_fx_run
grep -q "demo-os wait served=${S40:0:8} head=${H40:0:8} age=10m deployment: building$" "$LOG" \
  && ok || bad "D1b driver logs wait … deployment: building: $(cat "$LOG")"

case_s2b() {
  ssw_fx_reset; s2_fixture; ssw_fx_head "$H40" -
  ssw_fx_run
  [ "$(jq -r '.last_verdict' "$SF" 2>/dev/null)" = wait ] && ok || bad "S2b no committer date first tick is wait: $(cat "$LOG")"
  [ "$(jq -r '.first_seen' "$SF" 2>/dev/null)" = "$NOW" ] && ok || bad "S2b first_seen == NOW"
  SERVED_SHA_NOW=$((NOW+1200)); ssw_fx_run; unset SERVED_SHA_NOW
  [ "$(jq -r '.last_verdict' "$SF" 2>/dev/null)" = alert ] && ok || bad "S2b first_seen+1200 alerts: $(cat "$LOG")"
  [ "$(jq -r '.first_seen' "$SF" 2>/dev/null)" = "$NOW" ] && ok || bad "S2b first_seen kept for the same head"
}
case_s2b

case_s2c() {
  ssw_fx_reset; s2_fixture; ssw_fx_head "$H40" -
  mkdir -p "$(dirname "$SF")"
  jq -nc --arg s "$S40" '{head:$s, first_seen:1000, last_verdict:"alert"}' > "$SF"
  ssw_fx_run
  [ "$(jq -r '.first_seen' "$SF" 2>/dev/null)" = "$NOW" ] && ok || bad "S2c a new head resets first_seen: $(cat "$SF")"
  [ "$(jq -r '.last_verdict' "$SF" 2>/dev/null)" = wait ] && ok || bad "S2c a new head with no date waits"
}
case_s2c

seed_state() { mkdir -p "$(dirname "$SF")"; printf '{"head":"%s","first_seen":1,"last_verdict":"wait","x":"keep"}\n' "$H40" > "$SF"; cp "$SF" "$T/seed.json"; }
unread_case() { # <name> <log-fragment>
  ssw_fx_run
  [ "$SSW_RC" = 0 ] && ok || bad "$1 rc 0, got $SSW_RC"
  [ "$(summary)" = "checked=1 in_sync=0 wait=0 alert=0 unreadable=1" ] && ok || bad "$1 summary: $(cat "$LOG")"
  grep -q "demo-os unreadable ($2)" "$LOG" && ok || bad "$1 log names ($2): $(cat "$LOG")"
  grep -qE 'demo-os (alert|wait|in-sync)' "$LOG" && bad "$1 a verdict other than unreadable: $(cat "$LOG")" || ok
  cmp -s "$SF" "$T/seed.json" && ok || bad "$1 state not left byte-identical"
}
ssw_fx_reset; s2_fixture; seed_state; printf 500 > "$T/fx/alias.code"; unread_case S7a 'alias:500'; notoken S7a
ssw_fx_reset; s2_fixture; seed_state; printf 429 > "$T/fx/head.code"; unread_case S7b 'head:rc75'
ssw_fx_reset; s2_fixture; ssw_fx_served -; seed_state; unread_case S7c 'served:no-git-sha'
ssw_fx_reset; s2_fixture; seed_state; printf 429 > "$T/fx/compare.code"; unread_case S7d 'compare:unread'

ssw_fx_reset; s2_fixture; SERVED_SHA_LAG_MIN=0 ssw_fx_run
[ "$SSW_RC" = 0 ] && ok || bad "S8a rc 0"; noreq S8a
grep -q 'off (SERVED_SHA_LAG_MIN=0)' "$LOG" && ok || bad "S8a logs off: $(cat "$LOG" 2>&1)"
ssw_fx_reset; s2_fixture; touch "$H/flags/lane-off-served-sha-watch"; ssw_fx_run
[ "$SSW_RC" = 0 ] && ok || bad "S8b rc 0"; noreq S8b
rm -f "$H/flags/lane-off-served-sha-watch"
ssw_fx_reset; s2_fixture; ssw_fx_head "$H40" "$(iso $((NOW-1200)))"; SERVED_SHA_LAG_MIN=abc ssw_fx_run
grep -q "SERVED_SHA_LAG_MIN='abc' is not a whole number" "$LOG" && ok || bad "S8c logs the fallback: $(cat "$LOG")"
[ "$(jq -r '.last_verdict' "$SF" 2>/dev/null)" = alert ] && ok || bad "S8c falls back to 20m and alerts at 1200s"

ssw_fx_reset; s2_fixture; SERVED_SHA_VERCEL_AUTH="$T/no-such-auth.json" ssw_fx_run
[ "$SSW_RC" = 0 ] && ok || bad "S9b rc 0"; noreq S9b
grep -q 'not configured (no Vercel CLI auth file)' "$LOG" && ok || bad "S9b not configured: $(cat "$LOG" 2>&1)"

ssw_fx_reset; s2_fixture
# The holder takes the lock, says so, and lets go only when the case is done:
# the handshake is two files, never a timed sleep standing in for "acquired".
rm -f "$T/held" "$T/release"
( exec 8>"$H/locks/served-sha-watch.lock"; flock 8; : > "$T/held"
  while [ ! -e "$T/release" ]; do sleep 0.05; done ) &  # determinism: ok polls a file the suite writes, bounded below
LPID=$!
for _ in $(seq 1 200); do [ -e "$T/held" ] && break; sleep 0.05; done  # determinism: ok waits for the holder's own signal
[ -e "$T/held" ] && ok || bad "S10 setup: the holder never took the lock"
ssw_fx_run
[ "$SSW_RC" = 0 ] && ok || bad "S10 rc 0"; noreq S10
[ -z "$(summary)" ] && ok || bad "S10 a held lock still ran: $(cat "$LOG")"
: > "$T/release"; wait "$LPID" 2>/dev/null

ssw_fx_reset; s2_fixture; mkdir -p "$(dirname "$SF")"; printf '{broken' > "$SF"; ssw_fx_run
grep -q 'demo-os state corrupt, treated as empty' "$LOG" && ok || bad "S11 logs the corrupt state: $(cat "$LOG")"
[ "$(jq -r '.last_verdict' "$SF" 2>/dev/null)" = alert ] && ok || bad "S11 rewritten as valid JSON with the verdict"

ssw_fx_reset; s2_fixture; printf '# none\n' > "$T/empty.conf"; SERVED_SHA_CONF="$T/empty.conf" ssw_fx_run
[ "$(summary)" = "checked=0 in_sync=0 wait=0 alert=0 unreadable=0" ] && ok || bad "S12a SERVED_SHA_CONF is read: $(cat "$LOG")"
ssw_fx_reset; s2_fixture; ssw_fx_run
[ "$(summary)" = "checked=1 in_sync=0 wait=0 alert=1 unreadable=0" ] && ok || bad "S12b unset reads \$H/vercel.conf"

ssw_fx_reset; s2_fixture; ( unset ENDPOINT_VERCEL; ssw_fx_run )
grep -q '^GET https://api.vercel.com/v4/aliases/demo.example.com?teamId=team_x ' "$T/req/argv.lines" \
  && ! grep -qv '^GET https://api.vercel.com/' "$T/req/argv.lines" && ok || bad "S13 registry default base: $(cat "$T/req/argv.lines")"

ssw_fx_reset; s2_fixture; SERVED_SHA_HTTP_TIMEOUT=7 ssw_fx_run
grep -q 'max-time=7$' "$T/req/argv.lines" && ! grep -qv 'max-time=7$' "$T/req/argv.lines" \
  && ok || bad "S14 --max-time 7: $(cat "$T/req/argv.lines")"

# ── H: the hook contract ─────────────────────────────────────────────────────
HD="$H/bin/lib/served-sha-watch.d"
probe() { mkdir -p "$HD"; cat > "$HD/99-probe.sh" <<'SH'
ssw_hook_probe() {
  { printf 'argv'; printf ' %s' "$@"; printf '\n'
    printf 'env %s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$SSW_SLUG" "$SSW_TEAM" "$SSW_PID" "$SSW_VNAME" \
      "$SSW_NOW" "$SSW_LAG_S" "$SSW_DOMAIN" "$H" "$SSW_AUTODEPLOY"; } >> "$SSW_FX_T/probe.txt"
}
SH
}
ssw_fx_reset; s2_fixture; probe; ssw_fx_run
[ "$(sed -n 1p "$T/probe.txt" 2>/dev/null)" = "argv demo-os alert $H40 $S40 none 1500 $SF" ] \
  && ok || bad "H1 hook argv: $(cat "$T/probe.txt" 2>&1)"
[ "$(sed -n 2p "$T/probe.txt" 2>/dev/null)" = "env example-org/demo-os|team_x|prj_x|demo-os|$NOW|1200|demo.example.com|$H|0" ] \
  && ok || bad "H1 hook env: $(cat "$T/probe.txt" 2>&1)"

ssw_fx_reset; s2_fixture; probe
printf 'ssw_hook_fail() { return 3; }\n' > "$HD/10-fail.sh"; ssw_fx_run
grep -q 'hook ssw_hook_fail rc=3' "$LOG" && ok || bad "H2 failing hook logged: $(cat "$LOG")"
[ -s "$T/probe.txt" ] && [ "$SSW_RC" = 0 ] && ok || bad "H2 the probe still ran and the tick is rc 0"

ssw_fx_reset; s2_fixture; mkdir -p "$HD"
printf 'ssw_hook_b() { echo b >> "$SSW_FX_T/order.txt"; }\n' > "$HD/20-b.sh"
printf 'ssw_hook_a() { echo a >> "$SSW_FX_T/order.txt"; }\n' > "$HD/05-a.sh"
rm -f "$T/order.txt"; ssw_fx_run
[ "$(tr '\n' ' ' < "$T/order.txt" 2>/dev/null)" = "a b " ] && ok || bad "H3 hooks in order a b: $(cat "$T/order.txt" 2>&1)"

ssw_fx_reset; s2_fixture; ssw_fx_head "$H40"; ssw_fx_served "$H40"; probe; ssw_fx_run
grep -q "^argv demo-os in-sync " "$T/probe.txt" 2>/dev/null && [ ! -e "$SF" ] \
  && ok || bad "H4 hooks run on in-sync and the state is deleted after: $(cat "$T/probe.txt" 2>&1)"

ssw_fx_reset; s2_fixture; probe; SERVED_SHA_AUTODEPLOY=yes ssw_fx_run
[ "$(sed -n 2p "$T/probe.txt" | awk -F'|' '{print $NF}')" = 0 ] && ok || bad "S15a AUTODEPLOY=yes is 0 for hooks"
ssw_fx_reset; s2_fixture; probe; SERVED_SHA_AUTODEPLOY=1 ssw_fx_run
[ "$(sed -n 2p "$T/probe.txt" | awk -F'|' '{print $NF}')" = 1 ] && ok || bad "S15b AUTODEPLOY=1 is 1 for hooks"

# ── M: break the judge, confirm J3/J5 go red, restore ────────────────────────
mutate() { # mutate <name> <sed-expr> -> $T/mut.sh differs from the lib
  sed "$2" "$JLIB" > "$T/mut.sh"
  ! cmp -s "$JLIB" "$T/mut.sh" && ok || bad "$1 mutation changed nothing"
}
mutate M1 's/-ge "\$lag/-gt "$lag/'
[ "$(JLIB="$T/mut.sh" J "$NOW" $((NOW-1200)) 1200 "$H40" "$S40" ahead none)" = wait ] \
  && ok || bad "M1 -ge to -gt must turn J3 to wait"
mutate M2 '/# ssw-judge: failed/d'
[ "$(JLIB="$T/mut.sh" J "$NOW" $((NOW-60)) 1200 "$H40" "$S40" ahead failed)" = wait ] \
  && ok || bad "M2 dropping the failed arm must turn J5 to wait"

echo "served-sha-watch.bh-4936: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
