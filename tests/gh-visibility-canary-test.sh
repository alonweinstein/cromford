#!/bin/bash
# tests/gh-visibility-canary-test.sh — bin/claude-auth-check.sh's 6h canary:
# every fleet.conf repo is probed with the DEFAULT gh PAT; a repo it cannot see
# is ONE alert naming the repo and whether the admin token can see it, deduped
# per day with a recovery line. (2026-09-12: the hub's default PAT 404'd on
# project-5 for days; every listing lane ran empty and nothing said so.)
# gh_visibility_canary is sourced directly (AUTH_CHECK_LIB=1 returns before the
# box loop), so this drives the real function against a gh shim.
# Run from anywhere: tests/gh-visibility-canary-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/locks" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ") printf 'ts\nbd\nmk\n' ;;
  "ts repo") echo "o/adminonly" ;;
  "bd repo") echo "o/seen" ;;
  "mk repo") echo "o/blind" ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  "api repos/o/seen -q .id")      exit 0 ;;
  "api repos/o/adminonly -q .id") [ "${GH_TOKEN:-}" = admintok ] && exit 0; [ -f "$T/healed" ] && exit 0; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
canary() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" BEAT_SINK="$T/beats.txt"; unset GH_TOKEN
    # shellcheck source=/dev/null
    AUTH_CHECK_LIB=1 . "$DIR/bin/claude-auth-check.sh" >/dev/null 2>&1
    gh_visibility_canary ) 2>"$T/err.txt"
}

# 1. first run: the two invisible repos page, each with the admin token's verdict; the visible one is silent
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
canary
grep -q "DEFAULT GH TOKEN CANNOT SEE o/adminonly (ts) (new): the admin token CAN see it" "$T/logs/ALERTS.log" \
  && ok || bad "admin-visible repo not paged as such: $(cat "$T/logs/ALERTS.log") err=$(cat "$T/err.txt")"
grep -q "DEFAULT GH TOKEN CANNOT SEE o/blind (mk) (new): the admin token cannot see it either" "$T/logs/ALERTS.log" \
  && ok || bad "blind repo not paged as such: $(cat "$T/logs/ALERTS.log")"
grep -q "o/seen" "$T/logs/ALERTS.log" && bad "a visible repo was paged" || ok
# BH-2337: only the repo NO token can see pages; the admin-covered one is a
# status row (tests/alert-hygiene.bh-2337-test.sh) and an ALERTS audit line.
[ "$(grep -c '"akey":"ghinvisible:' "$T/beats.txt")" = 1 ] && ok || bad "expected one ghinvisible beat (the blind repo): $(cat "$T/beats.txt")"
grep -q admintok "$T/logs/ALERTS.log" "$T/beats.txt" && bad "the admin token VALUE leaked" || ok
grep -qx "ghdefault-o_adminonly" "$T/state/claude-auth-down.txt" && ok || bad "state not latched: $(cat "$T/state/claude-auth-down.txt")"
# V1 alert hygiene: the akey is the CONDITION (no date, so the console keeps one
# row per repo), the state-machine id is the repo, and a fully blind repo pages
# critical. BH-2337: a repo the admin token covers does not beat at all.
grep -q '"akey":"ghinvisible:o/blind"' "$T/beats.txt" && ok || bad "V1: akey must be ghinvisible:<slug> with no date: $(cat "$T/beats.txt")"
grep -q '"alertid":"ghdefault-o_blind"' "$T/beats.txt" && ok || bad "V1: beat must carry the condition id: $(cat "$T/beats.txt")"
grep -q '"akey":"ghinvisible:o/adminonly"' "$T/beats.txt" && bad "BH-2337: an admin-covered repo must not beat: $(cat "$T/beats.txt")" || ok
BB=$(grep '"akey":"ghinvisible:o/blind"' "$T/beats.txt")
grep -q '"severity":"critical"' <<<"$BB" && ok || bad "V1: a repo no token sees stays critical: $(cat "$T/beats.txt")"
# 2. same day, still invisible: no second page
canary
[ "$(grep -c 'CANNOT SEE' "$T/logs/ALERTS.log")" = 2 ] && ok || bad "re-paged within the day: $(cat "$T/logs/ALERTS.log")"
# 3. the default token regains access: RECOVERED, state cleared
touch "$T/healed"
canary
grep -q "ghdefault-o_adminonly RECOVERED — the default gh token sees o/adminonly again" "$T/logs/ALERTS.log" \
  && ! grep -qx "ghdefault-o_adminonly" "$T/state/claude-auth-down.txt" \
  && ok || bad "no recovery: $(cat "$T/logs/ALERTS.log") state=$(cat "$T/state/claude-auth-down.txt")"

# 4. C-app (BH-765) — an App token that CAN see the repo must not silence the
#    canary. Its sentence is about the DEFAULT PAT: if the App rung answered for
#    it, a repo the default PAT is blind to would either go unreported or be
#    paged as "every gh consumer is blind" while an App token read it fine.
rm -f "$T/healed" "$T/state/claude-auth-down.txt" "$T"/flags/ghinvisible-*
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
cp "$DIR/bin/lib/gh-app-auth.sh" "$T/bin/lib/"
: > "$T/env/github-app.env"
printf '#!/bin/bash\nprintf "apptok\\n"\n' > "$T/bin/gh-token.sh"; chmod +x "$T/bin/gh-token.sh"
# The App token sees o/adminonly; so does the admin PAT; the default sees neither.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  "api repos/o/seen -q .id")      exit 0 ;;
  "api repos/o/adminonly -q .id") case "${GH_TOKEN:-}" in admintok|apptok) exit 0 ;; esac; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
canary
grep -q "DEFAULT GH TOKEN CANNOT SEE o/adminonly (ts) (new): the admin token CAN see it" "$T/logs/ALERTS.log" \
  && ok || bad "C-app: an App-visible repo must still page about the DEFAULT PAT: $(cat "$T/logs/ALERTS.log") err=$(cat "$T/err.txt")"
grep -rq apptok "$T/logs/ALERTS.log" "$T/beats.txt" && bad "C-app: the App token VALUE leaked" || ok
rm -f "$T/env/github-app.env" "$T/bin/gh-token.sh" "$T/bin/lib/gh-app-auth.sh"

echo "gh-visibility-canary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
