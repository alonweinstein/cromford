#!/bin/bash
# tests/cli-version-check-test.sh — bin/cli-version-check.sh (hub, daily) reads
# every box's runner CLIs under the PATH cron uses AND the login PATH, and
# writes exactly one ALERTS line per box that needs attention.
#
# BH-1494 changed what this suite covers, in three ways, and the cases below are
# edited rather than added to because the SPEC moved: the probe now iterates the
# catalog's `clis` (three of them, so every box contributes three rows), grok is
# read through ~/.grok/bin/grok before PATH (so every fake box here carries one),
# and the gpt-6-astra floor is 0.155.1 (so a fleet that means "current" says
# 0.155.1).
#
# DRIVEN, NOT GREPPED, through a stub ssh that runs the real probe against a
# per-box fake filesystem (a cronbin, a loginbin, a crontab shim, an env file):
#   1. a box matching the hub -> no alert, "ok" in the log and the fleet table.
#   2. one box behind the hub, below the fleet-default floor, missing codex on
#      cron's PATH and split between its two PATHs -> ONE line naming all four.
#   3. a box whose env pins a codex model with a floor its codex is below -> one
#      line naming the model (env model ids are read, nothing else from the env).
#   4. an unreachable box -> one line, and the sweep continues.
#   5. the whole table goes to the DB in ONE request (source=check), rc 1 when
#      anything is behind, rc 0 and no ALERTS on a clean fleet, the secret in
#      every env file never reaches stdout, the log, ALERTS or the TSV.
# Run from anywhere: tests/cli-version-check-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$DIR/bin/cli-version-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
TMP="$T"
FLEET="$TMP/fleet"; H="$TMP/harness"
SECRET="check-secret-DO-NOT-LEAK-4c1e"
mkdir -p "$H/logs" "$H/state" "$H/env" "$H/bin" "$H/flags" "$TMP/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
echo "HARNESS_SECRET=$SECRET" > "$H/env/global.env"
cat > "$TMP/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
printf '{"accepted":1,"inserted":1}\n200\n'
CURL
chmod +x "$TMP/fakebin/curl"

# make_box <name> <cron-claude|-> <cron-codex|-> <login-claude|-> <login-codex|-> [env-lines]
fake_cli() { # fake_cli <path> <version> <label>
  printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s (%s)"\n' "$2" "$3" > "$1"; chmod +x "$1"
}
make_box() {
  local b="$FLEET/$1"; mkdir -p "$b/cronbin" "$b/loginbin" "$b/shim" "$b/home/.grok/bin"
  # Every box's grok is current: this suite is about claude and codex, and a
  # grok reason on every line would drown the ones it asserts. The grok cases
  # are tests/cli-version-check.bh-1494-test.sh.
  fake_cli "$b/home/.grok/bin/grok" "grok 1.0.40" "x"
  [ "$2" != - ] && fake_cli "$b/cronbin/claude" "$2" "Claude Code"
  [ "$3" != - ] && fake_cli "$b/cronbin/codex" "codex-cli $3" "x"
  [ "$4" != - ] && fake_cli "$b/loginbin/claude" "$4" "Claude Code"
  [ "$5" != - ] && fake_cli "$b/loginbin/codex" "codex-cli $5" "x"
  printf '#!/bin/bash\necho "SHELL=/bin/bash"; echo "PATH=%s"\n' "$b/cronbin" > "$b/shim/crontab"; chmod +x "$b/shim/crontab"
  { echo "HARNESS_SECRET=$SECRET"; [ $# -ge 6 ] && printf '%s\n' "$6"; } > "$b/global.env"
}
# The stub ssh: $1=root@<box>, $2="bash -s", the probe on stdin. It runs the
# probe in the box's fake world; a box with no directory is unreachable.
cat > "$TMP/fake-ssh.sh" <<'EOF2'
#!/bin/bash
BOX="${1#root@}"; ROOT="$FLEET/$BOX"
[ -d "$ROOT" ] || exit 255
PATH="$ROOT/shim:$SYS_PATH" CLI_CHECK_ENV_FILE="$ROOT/global.env" \
  CLI_CHECK_LOGIN_PATH="$ROOT/loginbin:$ROOT/cronbin" CLI_CHECK_HOME="$ROOT/home" bash -s
EOF2
chmod +x "$TMP/fake-ssh.sh"

run() { # run <boxes> -> OUT, RC, NEW (ALERTS lines added by this run)
  local before=0
  [ -f "$H/logs/ALERTS.log" ] && before=$(wc -l < "$H/logs/ALERTS.log")
  OUT=$(PATH="$FLEET/hub/shim:$TMP/fakebin:$PATH" SYS_PATH="$TMP/fakebin:$PATH" FLEET="$FLEET" \
        HARNESS="$H" HARNESS_CHECKOUT="$DIR" CLI_CHECK_BOXES="$1" CLI_CHECK_SSH="$TMP/fake-ssh.sh" \
        CLI_CHECK_ENV_FILE="$FLEET/hub/global.env" CLI_CHECK_LOGIN_PATH="$FLEET/hub/loginbin:$FLEET/hub/cronbin" \
        CLI_CHECK_HOME="$FLEET/hub/home" REQ_SINK="$TMP/req.log" "$CHECK" 2>&1); RC=$?
  NEW=$(tail -n +$((before+1)) "$H/logs/ALERTS.log" 2>/dev/null)
}

# --- the fleet -----------------------------------------------------------------
make_box hub                       2.1.261 0.155.1 2.1.261 0.155.1
make_box box-alpha       2.1.261 0.155.1 2.1.261 0.155.1 "EXECUTE_MODEL=gpt-6-astra"
make_box box-beta-2      2.1.250 -       2.1.261 0.155.1          # behind, below floor, codex missing, split
make_box box-gamma       2.1.261 0.150.1 2.1.261 0.150.1 "CODEX_MODEL=gpt-6-astra"   # env model floor
: > "$TMP/req.log"
run "local box-alpha box-beta-2 box-gamma box-ghost"

[ "$RC" = 1 ] && ok || bad "rc must be 1 with boxes behind (rc=$RC): $OUT"
# 1. alpha and the hub: no alert
grep -q '^\S* \S* \[alpha\]' <<<"$NEW" && bad "alpha alerted: $NEW" || ok
grep -q '\[hub\]' <<<"$NEW" && bad "hub alerted: $NEW" || ok
grep -q 'alpha ok' <<<"$OUT" && ok || bad "alpha not reported ok: $OUT"
# 2. beta: ONE line, all four reasons
BETA=$(grep '\[beta\] CLI VERSIONS' <<<"$NEW")
[ "$(grep -c '\[beta\]' <<<"$NEW")" = 1 ] && ok || bad "beta must get exactly one line: $NEW"
grep -q 'claude 2.1.250 behind hub 2.1.261' <<<"$BETA" && ok || bad "beta: behind-hub missing: $BETA"
grep -q 'claude 2.1.250 below the 2.1.251 floor for claude-fable-5-1' <<<"$BETA" && ok || bad "beta: floor missing: $BETA"
grep -q 'codex MISSING on the cron PATH' <<<"$BETA" && ok || bad "beta: missing codex not named: $BETA"
grep -q 'claude split: cron PATH 2.1.250 (.*cronbin/claude) vs login PATH 2.1.261' <<<"$BETA" && ok || bad "beta: split not named: $BETA"
grep -q 'ssh root@box-beta-2 /root/harness/bin/cli-update.sh' <<<"$BETA" && ok || bad "beta: fix not named: $BETA"
# 3. gamma: the env's model floor, codex only
GAMMA=$(grep '\[gamma\] CLI VERSIONS' <<<"$NEW")
[ "$(grep -c '\[gamma\]' <<<"$NEW")" = 1 ] && ok || bad "gamma must get exactly one line: $NEW"
grep -q 'codex 0.150.1 below the 0.155.1 floor for gpt-6-astra' <<<"$GAMMA" && ok || bad "gamma: env model floor missing: $GAMMA"
grep -q 'codex 0.150.1 behind hub 0.155.1' <<<"$GAMMA" && ok || bad "gamma: behind hub missing: $GAMMA"
grep -q 'claude' <<<"$GAMMA" && bad "gamma: claude is fine and must not be named: $GAMMA" || ok
# 4. ghost: unreachable, one line, sweep continued (gamma came after it? no — order is
#    the list's; assert the summary counted it and everything else still ran)
[ "$(grep -c '\[ghost\]' <<<"$NEW")" = 1 ] && grep -q 'could not probe box-ghost' <<<"$NEW" && ok || bad "ghost: $NEW"
grep -q 'fleet CLI versions: 2 ok, 2 need attention, 1 unreachable — hub claude 2.1.261 codex 0.155.1 grok 1.0.40' <<<"$OUT" && ok || bad "summary: $OUT"
grep -q 'fleet CLI versions: 2 ok, 2 need attention, 1 unreachable' "$H/logs/cli-version-check.log" && ok || bad "summary not in the log"
# 5. the DB push: one request, every probed (box, cli), source=check
[ "$(grep -c 'POST .*/api/metrics/cli-versions' "$TMP/req.log")" = 1 ] && ok || bad "expected ONE push: $(cut -c1-120 "$TMP/req.log")"
BODY=$(grep 'cli-versions' "$TMP/req.log" | sed 's/^POST [^ ]* //')
[ "$(jq '.rows | length' <<<"$BODY")" = 12 ] && ok || bad "expected 12 rows (4 boxes x 3): $(jq -c '.rows|length' <<<"$BODY")"
jq -e '.rows | all(.source=="check" and .method=="check")' <<<"$BODY" >/dev/null && ok || bad "rows not source=check"
jq -e '.rows[] | select(.box=="beta" and .cli=="claude") | .version_after=="2.1.250" and .ok=="0" and (.note|test("behind hub"))' <<<"$BODY" >/dev/null && ok || bad "beta claude row: $(jq -c '.rows[]|select(.box=="beta")' <<<"$BODY")"
jq -e '.rows[] | select(.box=="beta" and .cli=="codex") | .version_after=="missing" and .ok=="0"' <<<"$BODY" >/dev/null && ok || bad "beta codex row missing"
jq -e '.rows[] | select(.box=="hub" and .cli=="claude") | .version_after=="2.1.261" and .ok=="1"' <<<"$BODY" >/dev/null && ok || bad "hub row"
# the fleet table on disk
grep -qP '^beta\tclaude\t2.1.250\t' "$H/state/cli-versions-fleet.tsv" && ok || bad "TSV beta row: $(cat "$H/state/cli-versions-fleet.tsv")"
grep -qP '^ghost\t-\tunreachable' "$H/state/cli-versions-fleet.tsv" && ok || bad "TSV ghost row"
# no secret anywhere
if grep -rq "$SECRET" "$H/logs" "$H/state" "$TMP/req.log" 2>/dev/null || grep -q "$SECRET" <<<"$OUT"; then
  bad "the env secret leaked"; else ok; fi

# --- a clean fleet: rc 0, no ALERTS line at all ------------------------------
scratch_rm "$FLEET/box-beta-2"; scratch_rm "$FLEET/box-gamma"
make_box box-beta-2 2.1.261 0.155.1 2.1.261 0.155.1
run "local box-alpha box-beta-2"
[ "$RC" = 0 ] && ok || bad "clean fleet rc=$RC: $OUT"
[ -z "$NEW" ] && ok || bad "clean fleet wrote ALERTS: $NEW"
grep -q 'fleet CLI versions: 3 ok, 0 need attention, 0 unreachable' <<<"$OUT" && ok || bad "clean summary: $OUT"

# --- the check never heals: no install/relink/copy over ssh in the script --------
grep -q . <<<"$(grep -nE 'npm install|install latest|ln -s|scp |rsync ' "$CHECK" | grep -v '^[0-9]*:#')" \
  && bad "cli-version-check.sh contains an install/relink action — detection only" || ok

echo "cli-version-check-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
