#!/bin/bash
# tests/cli-version-check.bh-1494-test.sh — the hub's daily check covers grok,
# and it reads grok the way the LANES run it.
#
# BH-1494's item 2 says "bin/cli-version-check.sh and state/cli-versions-fleet.tsv
# then cover grok with no further change; verify they do." They did not. Two
# things were in the way, and this suite pins both:
#
#   1. the probe iterated a hardcoded `for c in claude codex`, so no grok row
#      was ever produced, from any box.
#   2. it resolved each CLI on the CRON PATH (/usr/bin:/bin). xAI's installer
#      never links into /usr/bin — it writes ~/.grok/bin/grok and symlinks into
#      ~/.local/bin or /usr/local/bin only when its own PATH check says it must
#      — and every lane reaches grok by PREPENDING $HOME/.grok/bin
#      (bin/agent-call.sh, bin/lane-probe.sh, bin/orchestrate.sh). A PATH-only
#      read would have alerted "grok MISSING on the cron PATH" for the entire
#      fleet on the day this merged, which is the opposite of the truth.
#
# DRIVEN, NOT GREPPED, through the same stub ssh the sibling suite uses: the
# real probe runs against a per-box fake filesystem and the assertions are on
# logs/ALERTS.log, state/cli-versions-fleet.tsv and the DB request body.
#   1. a box below the 1.0.40 floor -> exactly one ALERTS line, a TSV row, an
#      ok=0 DB row.
#   2. a box AT the floor -> no line at all, rc 0.
#   3. a box with no grok anywhere -> one line naming it MISSING.
#   4. an old grok on both PATHs but a current launcher -> ok, because that is
#      the binary the lanes execute.
#   5. the CLI list comes from the catalog, not from the script.
# Run from anywhere: tests/cli-version-check.bh-1494-test.sh  (exit 0 = all pass)
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
SECRET="grokcheck-secret-DO-NOT-LEAK-2ab7"
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

fake_cli() { # fake_cli <path> <version-line>
  printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s"\nexit 0\n' "$2" > "$1"; chmod +x "$1"
}
# make_box <name> <claude> <codex> <launcher-grok|-> <path-grok|-> [env-line]
#   claude/codex are placed identically on both PATHs (no split); the grok
#   launcher lives at <box>/home/.grok/bin/grok, which is where CLI_CHECK_HOME
#   points the probe.
make_box() {
  local b="$FLEET/$1"; mkdir -p "$b/cronbin" "$b/loginbin" "$b/shim" "$b/home/.grok/bin"
  fake_cli "$b/cronbin/claude" "$2 (Claude Code)";  fake_cli "$b/loginbin/claude" "$2 (Claude Code)"
  fake_cli "$b/cronbin/codex"  "codex-cli $3";      fake_cli "$b/loginbin/codex"  "codex-cli $3"
  [ "$4" != - ] && fake_cli "$b/home/.grok/bin/grok" "grok $4 (eb1a2256660d)"
  if [ "$5" != - ]; then
    fake_cli "$b/cronbin/grok" "grok $5 (eb1a2256660d)"; fake_cli "$b/loginbin/grok" "grok $5 (eb1a2256660d)"
  fi
  printf '#!/bin/bash\necho "SHELL=/bin/bash"; echo "PATH=%s"\n' "$b/cronbin" > "$b/shim/crontab"; chmod +x "$b/shim/crontab"
  { echo "HARNESS_SECRET=$SECRET"; [ $# -ge 6 ] && printf '%s\n' "$6"; } > "$b/global.env"
  return 0
}
cat > "$TMP/fake-ssh.sh" <<'EOF2'
#!/bin/bash
BOX="${1#root@}"; ROOT="$FLEET/$BOX"
[ -d "$ROOT" ] || exit 255
PATH="$ROOT/shim:$SYS_PATH" CLI_CHECK_ENV_FILE="$ROOT/global.env" \
  CLI_CHECK_LOGIN_PATH="$ROOT/loginbin:$ROOT/cronbin" CLI_CHECK_HOME="$ROOT/home" bash -s
EOF2
chmod +x "$TMP/fake-ssh.sh"

run() { # run <boxes> [catalog] -> OUT, RC, NEW (ALERTS lines this run added)
  local before=0
  local -a EXTRA=()
  [ -n "${2:-}" ] && EXTRA=(CLI_CHECK_CATALOG="$2")
  [ -f "$H/logs/ALERTS.log" ] && before=$(wc -l < "$H/logs/ALERTS.log")
  : > "$TMP/req.log"
  OUT=$(env PATH="$FLEET/hub/shim:$TMP/fakebin:$PATH" SYS_PATH="$TMP/fakebin:$PATH" FLEET="$FLEET" \
        HARNESS="$H" HARNESS_CHECKOUT="$DIR" CLI_CHECK_BOXES="$1" CLI_CHECK_SSH="$TMP/fake-ssh.sh" \
        CLI_CHECK_ENV_FILE="$FLEET/hub/global.env" CLI_CHECK_LOGIN_PATH="$FLEET/hub/loginbin:$FLEET/hub/cronbin" \
        CLI_CHECK_HOME="$FLEET/hub/home" ${EXTRA[@]+"${EXTRA[@]}"} \
        REQ_SINK="$TMP/req.log" "$CHECK" 2>&1); RC=$?
  NEW=$(tail -n +$((before+1)) "$H/logs/ALERTS.log" 2>/dev/null)
  BODY=$(grep 'cli-versions' "$TMP/req.log" 2>/dev/null | sed 's/^POST [^ ]* //')
}

# The hub: current everywhere, grok through its launcher exactly as the fleet
# carries it after the 2026-09-22 hand install.
make_box hub 2.1.261 0.155.1 1.0.40 -

# ===========================================================================
# 1. a box below the 1.0.40 floor: ONE line, a TSV row, an ok=0 DB row.
# ===========================================================================
make_box box-alpha 2.1.261 0.155.1 1.0.13 -
run "local box-alpha"
[ "$RC" = 1 ] && ok || bad "1: a box below a floor must exit 1 (rc=$RC): $OUT"
A=$(grep '\[alpha\] CLI VERSIONS' <<<"$NEW")
[ "$(grep -c '\[alpha\]' <<<"$NEW")" = 1 ] && ok || bad "1: alpha must get exactly one line: $NEW"
grep -q 'grok 1.0.13 below the 1.0.40 floor for grok-4.6' <<<"$A" && ok || bad "1: the floor is not named: $A"
grep -q 'grok 1.0.13 behind hub 1.0.40' <<<"$A" && ok || bad "1: behind-hub is not named: $A"
grep -qP '^alpha\tgrok\t1.0.13\t' "$H/state/cli-versions-fleet.tsv" && ok \
  || bad "1: no grok row in the fleet table: $(cat "$H/state/cli-versions-fleet.tsv")"
jq -e '.rows[] | select(.box=="alpha" and .cli=="grok") | .version_after=="1.0.13" and .ok=="0" and (.note|test("floor for grok-4.6"))' <<<"$BODY" >/dev/null && ok \
  || bad "1: the grok DB row: $(jq -c '.rows[]|select(.cli=="grok")' <<<"$BODY" 2>/dev/null)"
# every probed box contributes a row per CLI in the catalog
[ "$(jq '.rows|length' <<<"$BODY")" = 6 ] && ok || bad "1: expected 6 rows (2 boxes x 3 CLIs): $(jq -c '.rows|length' <<<"$BODY")"
grep -q 'hub claude 2.1.261 codex 0.155.1 grok 1.0.40' <<<"$OUT" && ok || bad "1: the summary must report the hub's grok: $OUT"
if grep -rq "$SECRET" "$H/logs" "$H/state" "$TMP/req.log" 2>/dev/null || grep -q "$SECRET" <<<"$OUT"; then
  bad "1: the env secret leaked"; else ok; fi

# ===========================================================================
# 2. a box AT the floor: no line at all, rc 0.
# ===========================================================================
scratch_rm "$FLEET/box-alpha"
make_box box-alpha 2.1.261 0.155.1 1.0.40 -
run "local box-alpha"
[ "$RC" = 0 ] && ok || bad "2: a fleet at the floor must exit 0 (rc=$RC): $OUT"
[ -z "$NEW" ] && ok || bad "2: a fleet at the floor wrote ALERTS: $NEW"
grep -qP '^alpha\tgrok\t1.0.40\t.*\tok$' "$H/state/cli-versions-fleet.tsv" && ok \
  || bad "2: the TSV must record grok ok: $(cat "$H/state/cli-versions-fleet.tsv")"

# ===========================================================================
# 3. no grok anywhere on the box (small's shape on 2026-09-22)
# ===========================================================================
scratch_rm "$FLEET/box-alpha"
make_box box-alpha 2.1.261 0.155.1 - -
run "local box-alpha"
[ "$(grep -c '\[alpha\]' <<<"$NEW")" = 1 ] && ok || bad "3: one line for a box with no grok: $NEW"
grep -q 'grok MISSING' <<<"$NEW" && ok || bad "3: MISSING is not named: $NEW"
[ "$RC" = 1 ] && ok || bad "3: rc=$RC"

# ===========================================================================
# 4. THE READ THAT MATTERS. An old grok on both PATHs, a current launcher: the
#    lanes prepend ~/.grok/bin, so this box is fine and must not be alerted —
#    and it must not be reported as a cron-vs-login split either.
#    Mutation: delete the launcher-first branch in the probe and this section
#    goes red twice (a floor line and a split line).
# ===========================================================================
scratch_rm "$FLEET/box-alpha"
make_box box-alpha 2.1.261 0.155.1 1.0.40 0.2.118
run "local box-alpha"
[ -z "$NEW" ] && ok || bad "4: the launcher the lanes run is current, so nothing should alert: $NEW"
[ "$RC" = 0 ] && ok || bad "4: rc=$RC: $OUT"
grep -qP '^alpha\tgrok\t1.0.40\t' "$H/state/cli-versions-fleet.tsv" && ok \
  || bad "4: the TSV must carry the launcher's version, not PATH's: $(grep grok "$H/state/cli-versions-fleet.tsv")"
grep -q 'split' <<<"$OUT" && bad "4: a box read consistently must not report a split: $OUT" || ok

# ===========================================================================
# 5. the CLI list is the CATALOG's, not the script's. A catalog with no grok
#    entry produces no grok rows — which is also what proves the list is not a
#    second hardcoded copy.
# ===========================================================================
cat > "$TMP/catalog-no-grok.json" <<'CAT'
{
  "clis": { "claude": {}, "codex": {} },
  "models": { "claude-fable-5-1": { "cli": "claude", "min": "2.1.251" } },
  "fleet_defaults": ["claude-fable-5-1"]
}
CAT
run "local box-alpha" "$TMP/catalog-no-grok.json"
grep -q 'grok' "$H/state/cli-versions-fleet.tsv" && bad "5: a catalog without grok still produced grok rows" || ok
[ "$(jq '.rows|length' <<<"$BODY")" = 4 ] && ok || bad "5: expected 4 rows (2 boxes x 2 CLIs): $(jq -c '.rows|length' <<<"$BODY")"

# --- the check still never heals ----------------------------------------------
grep -q . <<<"$(grep -nE 'npm install|install latest|ln -s|scp |rsync ' "$CHECK" | grep -v '^[0-9]*:#')" \
  && bad "cli-version-check.sh gained an install/relink action — detection only" || ok

echo "cli-version-check.bh-1494-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
