#!/bin/bash
# tests/wake-loop-conductor-owed.bh-3453-test.sh — a conductor run the wake loop
# could not launch is OWED, and a checks wake's head sha names its PR (BH-3453,
# child of BH-3436: why the webhook wake missed project-5#3415).
#
# OWED (cases O1-O8): a pr/checks wake held by the per-invocation cap or by a
# refused/unreachable `cooled pr fleet` writes its keys (or `*`) to
# state/wake-conductor-owed, and a later granted cycle pays the debt with ONE
# launch — even a cycle that claimed no rows. The debt is moved away before the
# launch, put back if the launch cannot start, and left alone by a refused
# cooldown or flags/wake-loop-off.
# SHA KEYS (cases K1-K6): with WAKE_CONDUCTOR_KEYED=1 a `checks` row keyed on a
# 7-64 hex head sha resolves through state/merge-conductor/pr-state.tsv to its
# owner/repo#n (same repo, prefix both ways, 7-char floor). An unresolved sha
# makes the launch unkeyed; KEYED=0 is main's argv and env; `abc12`/`zzzzzzz`
# never resolve and never force unkeyed.
#
# The real bin/wake-loop.sh runs as the hub (BOX_NAME=box-hub). The
# worker is tests/lib/wake-claim-stub.sh; the conductor is a recorder writing
# `argv1 TAB MC_ONLY_PR=… TAB argv`.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/wake-loop-conductor-owed.bh-3453-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/jobs" "$T/h/env" "$T/h/logs" "$T/h/locks" "$T/h/state" "$T/h/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/h/env/global.env"

cp "$DIR/bin/wake-loop.sh"      "$T/h/bin/wake-loop.sh"
cp "$DIR/bin/jobs-client.sh"    "$T/h/bin/jobs-client.sh"
cp "$DIR/bin/lib/env-path.sh"   "$T/h/bin/lib/env-path.sh"
cp "$DIR"/bin/lib/jobs/*.sh     "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/revdep-lib.sh" "$T/h/bin/lib/revdep-lib.sh"
cp "$DIR/bin/lib/gh-budget.sh"  "$T/h/bin/lib/gh-budget.sh"
cp "$DIR/bin/lib/heartbeat.sh"  "$T/h/bin/lib/heartbeat.sh"
cp "$DIR/bin/fleet-conf.sh"     "$T/h/bin/fleet-conf.sh"
cp "$DIR/bin/box-for.sh"        "$T/h/bin/box-for.sh"
chmod +x "$T/h/bin/wake-loop.sh" "$T/h/bin/jobs-client.sh" "$T/h/bin/fleet-conf.sh" "$T/h/bin/box-for.sh"

printf 'project-3 example-org/project-3 https://o.example /api/board 2 local\nproject-5 example-org/project-5 https://t.example /api/board 2 local\n' > "$T/h/fleet.conf"

for s in setsid; do printf '#!/bin/bash\nexec "$@"\n' > "$T/h/bin/$s"; done
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/flock"
for s in run-triage.sh deploy-train.sh postmerge-qa.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; done
printf '#!/bin/bash\nexit 1\n' > "$T/h/bin/unblocked-children.sh"
chmod +x "$T/h/bin/setsid" "$T/h/bin/flock" "$T/h/bin/run-triage.sh" "$T/h/bin/deploy-train.sh" \
         "$T/h/bin/postmerge-qa.sh" "$T/h/bin/unblocked-children.sh"

wcs_install "$T/h/bin"
wcs_identity "$T/h/bin" || { echo "wcs_identity failed"; exit 1; }
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE \
      WAKE_CONDUCTOR_PER_TICK WAKE_CONDUCTOR_KEYED WAKE_COOLDOWN_S WAKE_LOOP_CYCLES
cat > "$T/h/bin/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\n' ;;
  *) echo "" ;;
esac
exit 0
SH
chmod +x "$T/h/bin/gh"

SHA40=3f1a9c0d5e7b2a4f6c8e0d1b3a5f7c9e1d3b5a70
OWED="$T/h/state/wake-conductor-owed"
PRS="$T/h/state/merge-conductor/pr-state.tsv"

W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"ev","at":"2026-09-29T12:00:00Z"}' "$1" "$2" "$3" "$4"; }
wakes() { printf '{"wakes":[%s]}\n' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/h/wakes.json"; }

reset() {
  rm -rf "$T/h/calls" "$T/h/state" "$T/h/flags" "$T/h/wakes.json"
  mkdir -p "$T/h/calls" "$T/h/state/wcs" "$T/h/state/merge-conductor"
  : > "$T/h/logs/wake-loop.log"
  printf 'example-org/project-5#3415\tready\t0\t%s\t-\t-\t-\thttps://x/3415\n' "$SHA40" > "$PRS"
  printf 'example-org/project-3#5\tready\t0\tabc\t-\t-\t-\thttps://x/5\n' >> "$PRS"
  cat > "$T/h/bin/merge-conductor.sh" <<'SH'
#!/bin/bash
printf '%s\tMC_ONLY_PR=%s\t%s\n' "${1:-}" "${MC_ONLY_PR:-}" "$*" >> "$HARNESS/calls/merge-conductor"
SH
  chmod +x "$T/h/bin/merge-conductor.sh"
  wakes
}
# A new invocation sees only rows above the cursor; the claim rows dedupe the rest.
newrows() { rm -f "$T/h/state/wcs/claimed."*; wakes "$@"; }

run() {
  PATH="$T/h/bin:$PATH" HARNESS="$T/h" BOX_NAME=box-hub \
    WAKE_LOOP_CYCLES="${WAKE_LOOP_CYCLES:-1}" WAKE_LOOP_INTERVAL_S=0 \
    WAKE_COOLDOWN_S="${WAKE_COOLDOWN_S:-0}" FLEET_CONF="$T/h/fleet.conf" \
    WAKE_CONDUCTOR_KEYED="${WAKE_CONDUCTOR_KEYED:-1}" \
    bash "$T/h/bin/wake-loop.sh" >/dev/null 2>&1 || true
  local prev="" cur i
  for i in 1 2 3 4 5 6; do
    sleep 0.25
    cur=$(cat "$T/h/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
}
launches() { grep -c . "$T/h/calls/merge-conductor" 2>/dev/null || echo 0; }
only() { awk -F'\t' -v n="${1:-1}" 'NR==n {sub(/^MC_ONLY_PR=/,"",$2); print $2; exit}' "$T/h/calls/merge-conductor" 2>/dev/null; }
owed() { sort "$OWED" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
taking() { ls "$T/h/state/" 2>/dev/null | grep -c '^wake-conductor-owed\.taking\.' ; }
ACKS() { grep '/api/wakes/ack' "$T/h/state/wcs/curl.log" 2>/dev/null; }

# O1. Cooldown refused, one checks row keyed on #3415's head -> no launch, the
# resolved key is owed, the wake is still acked, and the log says so.
reset; wakes "$(W 1 example-org/project-5 checks "$SHA40")"
COOL_MODE=false run
[ "$(launches)" = 0 ] && ok || bad "O1: a refused cooldown must launch nothing (got $(launches))"
[ "$(owed)" = "example-org/project-5#3415" ] && ok || bad "O1: owed must hold example-org/project-5#3415 (got '$(owed)')"
ACKS | grep -q '1' && ok || bad "O1: the held wake must still be acked"
grep -q 'pr/checks: conductor run owed — 1 line(s) in state/wake-conductor-owed (cooldown)' "$T/h/logs/wake-loop.log" \
  && ok || bad "O1: missing the owed log line: $(cat "$T/h/logs/wake-loop.log")"

# O1c. The debt stays put while the cooldown keeps refusing: zero rows, no launch.
cp "$OWED" "$T/owed.before" 2>/dev/null || : > "$T/owed.before"
COOL_MODE=false run
[ "$(launches)" = 0 ] && ok || bad "O1c: a refused cooldown must not pay the debt (got $(launches))"
cmp -s "$OWED" "$T/owed.before" && ok || bad "O1c: a refused cooldown must leave the owed file byte-identical"

# O2. Next invocation, zero rows, cooldown granted -> exactly one launch keyed
# on the debt; the owed file and any taking file are gone.
run
[ "$(launches)" = 1 ] && ok || bad "O2: an empty drain must pay the debt with ONE launch (got $(launches))"
[ "$(only)" = "example-org/project-5#3415" ] && ok || bad "O2: MC_ONLY_PR must be the owed key (got '$(only)')"
[ ! -e "$OWED" ] && ok || bad "O2: the owed file must be gone after the pay (got '$(owed)')"
[ "$(taking)" = 0 ] && ok || bad "O2: no wake-conductor-owed.taking.* may be left behind"
grep -q 'pr/checks owed\[example-org/project-5#3415\]: launched merge-conductor.sh' "$T/h/logs/wake-loop.log" \
  && ok || bad "O2: missing the owed launch line"
# …and a debt pays once: another invocation launches nothing more.
run
[ "$(launches)" = 1 ] && ok || bad "O2: a paid debt must not pay twice (got $(launches))"

# O1b. Cooldown row unreachable (HTTP 500) is owed the same way.
reset; wakes "$(W 1 example-org/project-5 checks "$SHA40")"
COOL_MODE=500 run
[ "$(launches)" = 0 ] && ok || bad "O1b: an unreachable cooldown must launch nothing (got $(launches))"
[ "$(owed)" = "example-org/project-5#3415" ] && ok || bad "O1b: owed must hold the key (got '$(owed)')"

# O3. Cap 1, two cycles each claiming one pr wake -> 1 launch, the 2nd owed;
# the next invocation (zero rows) pays it.
reset; wakes "$(W 1 example-org/project-3 pr 5)" "$(W 2 example-org/project-3 pr 6)"
WAKE_CLAIM_LIMIT=1 WAKE_CONDUCTOR_PER_TICK=1 WAKE_LOOP_CYCLES=2 run
[ "$(launches)" = 1 ] && ok || bad "O3: cap 1 must buy one launch (got $(launches))"
[ "$(only 1)" = "example-org/project-3#5" ] && ok || bad "O3: the first launch carries #5 (got '$(only 1)')"
[ "$(owed)" = "example-org/project-3#6" ] && ok || bad "O3: the capped wake must be owed (got '$(owed)')"
grep -q 'conductor run owed — 1 line(s) in state/wake-conductor-owed (cap)' "$T/h/logs/wake-loop.log" \
  && ok || bad "O3: missing the (cap) owed line"
run
[ "$(launches)" = 2 ] && ok || bad "O3: the next invocation must pay the debt (got $(launches))"
[ "$(only 2)" = "example-org/project-3#6" ] && ok || bad "O3: the pay carries #6 (got '$(only 2)')"
[ ! -e "$OWED" ] && ok || bad "O3: owed must be gone after the pay"

# O4. flags/wake-loop-off -> owed untouched, no launch.
reset; printf 'example-org/project-5#3415\n' > "$OWED"; cp "$OWED" "$T/owed.before"
mkdir -p "$T/h/flags"; touch "$T/h/flags/wake-loop-off"
run
[ "$(launches)" = 0 ] && ok || bad "O4: the off flag must launch nothing (got $(launches))"
cmp -s "$OWED" "$T/owed.before" && ok || bad "O4: the off flag must leave the owed file untouched"

# O5. The conductor cannot start (not executable) -> no launch, the lines come
# back, no taking file.
reset; printf 'example-org/project-5#3415\nexample-org/project-3#6\n' > "$OWED"
chmod -x "$T/h/bin/merge-conductor.sh"
run
[ "$(launches)" = 0 ] && ok || bad "O5: a non-executable conductor launches nothing"
[ "$(owed)" = "example-org/project-3#6 example-org/project-5#3415" ] && ok \
  || bad "O5: a launch that could not start must put its lines back (got '$(owed)')"
[ "$(taking)" = 0 ] && ok || bad "O5: no taking file may be left behind"

# O6. A `*` in the debt -> one unkeyed launch. TEST-CHANGE BH-5521: that is
# the legacy path now, pinned under WAKE_CONDUCTOR_FULL=1; the default drops the
# `*` (tests/conductor-events.bh-5521-test.sh E10/E10b).
reset; printf 'example-org/project-5#3415\n*\n' > "$OWED"
WAKE_CONDUCTOR_FULL=1 WAKE_CONDUCTOR_SHA_LOOKUPS=0 run
[ "$(launches)" = 1 ] && ok || bad "O6: one launch expected (got $(launches))"
[ "$(only)" = "" ] && ok || bad "O6: a * debt must launch unkeyed (got '$(only)')"
grep -q 'pr/checks owed: launched merge-conductor.sh' "$T/h/logs/wake-loop.log" && ok || bad "O6: unkeyed owed label"

# O7. KEYED=0 -> the debt pays unkeyed.
reset; printf 'example-org/project-5#3415\n' > "$OWED"
WAKE_CONDUCTOR_KEYED=0 run
[ "$(launches)" = 1 ] && ok || bad "O7: one launch expected (got $(launches))"
[ "$(only)" = "" ] && ok || bad "O7: KEYED=0 pays unkeyed (got '$(only)')"

# O8. A debt plus a new pr wake under cap 1 -> the debt pays (one launch), the
# batch's key becomes the debt.
reset; printf 'example-org/project-5#3415\n' > "$OWED"; wakes "$(W 1 example-org/project-3 pr 5)"
WAKE_CONDUCTOR_PER_TICK=1 run
[ "$(launches)" = 1 ] && ok || bad "O8: exactly one launch under cap 1 (got $(launches))"
[ "$(only)" = "example-org/project-5#3415" ] && ok || bad "O8: the owed launch goes first (got '$(only)')"
[ "$(owed)" = "example-org/project-3#5" ] && ok || bad "O8: the capped batch key is now owed (got '$(owed)')"

# K1. pr 5 + checks <sha of #3415> -> MC_ONLY_PR carries both keys.
reset; wakes "$(W 1 example-org/project-3 pr 5)" "$(W 2 example-org/project-5 checks "$SHA40")"
run
[ "$(launches)" = 1 ] && ok || bad "K1: one launch expected (got $(launches))"
v=$(only)
case ",$v," in *,example-org/project-3#5,*) ok ;; *) bad "K1: missing project-3#5 (got '$v')" ;; esac
case ",$v," in *,example-org/project-5#3415,*) ok ;; *) bad "K1: missing project-5#3415 (got '$v')" ;; esac

# K1b. An 8-char prefix of the head (upper case) still resolves.
reset; wakes "$(W 1 example-org/project-5 checks "$(printf %s "${SHA40:0:8}" | tr a-f A-F)")"
run
[ "$(only)" = "example-org/project-5#3415" ] && ok || bad "K1b: a short prefix must resolve (got '$(only)')"

# K2. An unknown sha -> one launch, unkeyed; held, the debt is `*`.
# TEST-CHANGE BH-5521 (K2, K5, K6): an unplaced sha forcing an unkeyed launch is
# the legacy path, pinned under WAKE_CONDUCTOR_FULL=1 with no GitHub lookup; the
# default keeps the batch keyed (tests/conductor-events.bh-5521-test.sh E6-E9).
reset; wakes "$(W 1 example-org/project-3 pr 5)" "$(W 2 example-org/project-5 checks 0123456789abcdef0123456789abcdef01234567)"
WAKE_CONDUCTOR_FULL=1 WAKE_CONDUCTOR_SHA_LOOKUPS=0 run
[ "$(launches)" = 1 ] && ok || bad "K2: one launch expected (got $(launches))"
[ "$(only)" = "" ] && ok || bad "K2: an unresolved sha must launch unkeyed (got '$(only)')"
reset; wakes "$(W 1 example-org/project-3 pr 5)" "$(W 2 example-org/project-5 checks 0123456789abcdef0123456789abcdef01234567)"
WAKE_CONDUCTOR_FULL=1 WAKE_CONDUCTOR_SHA_LOOKUPS=0 COOL_MODE=false run
[ "$(owed)" = "*" ] && ok || bad "K2: a held unresolved batch is owed as * (got '$(owed)')"

# K3. KEYED=0 -> main's argv, env and label exactly.
reset; wakes "$(W 1 example-org/project-3 pr 5)" "$(W 2 example-org/project-5 checks "$SHA40")"
WAKE_CONDUCTOR_KEYED=0 run
[ "$(cat "$T/h/calls/merge-conductor" 2>/dev/null)" = "$(printf '\tMC_ONLY_PR=\t')" ] && ok \
  || bad "K3: KEYED=0 must be main's argv/env (got '$(cat "$T/h/calls/merge-conductor" 2>/dev/null)')"
grep -q 'pr/checks: launched merge-conductor.sh' "$T/h/logs/wake-loop.log" && ok || bad "K3: main's label"

# K4. abc12 / zzzzzzz never resolve and never force unkeyed.
reset; wakes "$(W 1 example-org/project-3 pr 5)" "$(W 2 example-org/project-5 checks abc12)" "$(W 3 example-org/project-5 checks zzzzzzz)"
run
[ "$(only)" = "example-org/project-3#5" ] && ok || bad "K4: MC_ONLY_PR must be exactly project-3#5 (got '$(only)')"

# K5. #3415's head arriving on another repo's checks row does not resolve.
reset; wakes "$(W 1 example-org/project-3 pr 5)" "$(W 2 example-org/project-3 checks "$SHA40")"
WAKE_CONDUCTOR_FULL=1 WAKE_CONDUCTOR_SHA_LOOKUPS=0 run
[ "$(only)" = "" ] && ok || bad "K5: a cross-repo sha must not resolve (got '$(only)')"

# K6. A pr-state head under 7 chars never matches (project-3#5's head is `abc`).
reset; wakes "$(W 1 example-org/project-5 pr 9)" "$(W 2 example-org/project-3 checks abcdef0)"
WAKE_CONDUCTOR_FULL=1 WAKE_CONDUCTOR_SHA_LOOKUPS=0 run
[ "$(only)" = "" ] && ok || bad "K6: a short pr-state head must not match (got '$(only)')"

# The stale */5 comments are gone (T1a).
[ "$(grep -c 'cron \*/5' "$DIR/bin/wake-loop.sh")" = 0 ] && ok || bad "bin/wake-loop.sh still says cron */5"

echo "wake-loop-conductor-owed: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
