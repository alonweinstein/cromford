#!/bin/bash
# tests/cli-version-check.bh-1636-test.sh — the grok requirement is per box and
# data-driven, and default-off.
#
# BH-1494 made the hub's daily check read grok on every box, so from the first
# 05:40Z run after it merged every box without grok reads "grok MISSING". BH-1636
# item 4: a box that never runs a grok lane is not expected to carry it, so the
# requirement becomes a settings row, CLI_CHECK_OPTIONAL
# (lane.cli-version-check.cli_check_optional), a space-separated list of
# <cli>@<box-id> pairs. A listed pair whose CLI is MISSING is not an alert. Only
# MISSING is waived: an installed grok below its floor is still a lane risk.
#
# DRIVEN through the same stub ssh as tests/cli-version-check.bh-1494-test.sh:
#   C1. knob empty -> MISSING alerts exactly as before (no silent waiver).
#   C2. grok@beta, beta without grok -> no ALERT, TSV note, DB ok=1, rc 0.
#   C3. grok@beta, beta on grok 1.0.13 -> still alerts on the floor.
#   C4. grok@beta waives neither grok@betax nor codex@beta.
#   C5. malformed tokens waive nothing, and the log names each one.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cli-version-check.bh-1636-test.sh
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
mkdir -p "$H/logs" "$H/state" "$H/env" "$H/bin" "$H/flags" "$TMP/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
echo "HARNESS_SECRET=grokcheck-1636" > "$H/env/global.env"
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

fake_cli() { printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s"\nexit 0\n' "$2" > "$1"; chmod +x "$1"; }
# make_box <name> <claude> <codex|-> <launcher-grok|->
make_box() {
  local b="$FLEET/$1"; mkdir -p "$b/cronbin" "$b/loginbin" "$b/shim" "$b/home/.grok/bin"
  fake_cli "$b/cronbin/claude" "$2 (Claude Code)"; fake_cli "$b/loginbin/claude" "$2 (Claude Code)"
  if [ "$3" != - ]; then fake_cli "$b/cronbin/codex" "codex-cli $3"; fake_cli "$b/loginbin/codex" "codex-cli $3"; fi
  [ "$4" != - ] && fake_cli "$b/home/.grok/bin/grok" "grok $4 (eb1a2256660d)"
  printf '#!/bin/bash\necho "PATH=%s"\n' "$b/cronbin" > "$b/shim/crontab"; chmod +x "$b/shim/crontab"
  : > "$b/global.env"
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

run() { # run <boxes> <CLI_CHECK_OPTIONAL> -> OUT RC NEW BODY LOGNEW
  local before=0 lbefore=0
  [ -f "$H/logs/ALERTS.log" ] && before=$(wc -l < "$H/logs/ALERTS.log")
  [ -f "$H/logs/cli-version-check.log" ] && lbefore=$(wc -l < "$H/logs/cli-version-check.log")
  : > "$TMP/req.log"
  OUT=$(env PATH="$FLEET/hub/shim:$TMP/fakebin:$PATH" SYS_PATH="$TMP/fakebin:$PATH" FLEET="$FLEET" \
        HARNESS="$H" HARNESS_CHECKOUT="$DIR" CLI_CHECK_BOXES="$1" CLI_CHECK_SSH="$TMP/fake-ssh.sh" \
        CLI_CHECK_ENV_FILE="$FLEET/hub/global.env" CLI_CHECK_LOGIN_PATH="$FLEET/hub/loginbin:$FLEET/hub/cronbin" \
        CLI_CHECK_HOME="$FLEET/hub/home" CLI_CHECK_OPTIONAL="$2" \
        REQ_SINK="$TMP/req.log" "$CHECK" 2>&1); RC=$?
  NEW=$(tail -n +$((before+1)) "$H/logs/ALERTS.log" 2>/dev/null)
  LOGNEW=$(tail -n +$((lbefore+1)) "$H/logs/cli-version-check.log" 2>/dev/null)
  BODY=$(grep 'cli-versions' "$TMP/req.log" 2>/dev/null | sed 's/^POST [^ ]* //')
}
reset_box() { scratch_rm "$FLEET/$1"; make_box "$@"; }

make_box hub 2.1.261 0.155.1 1.0.40
make_box box-beta 2.1.261 0.155.1 -

# C1. THE DEFAULT. Empty knob: a box without grok is alerted exactly as today.
run "local box-beta" ""
[ "$RC" = 1 ] && ok || bad "C1 empty knob, missing grok must exit 1 (rc=$RC): $OUT"
grep -q '\[beta\] CLI VERSIONS: grok MISSING on the cron PATH' <<<"$NEW" && ok || bad "C1 MISSING line changed or gone: $NEW"
grep -q 'not required on this box' "$H/state/cli-versions-fleet.tsv" && bad "C1 empty knob wrote a waiver note" || ok

# C2. THE LEVER. grok@beta: beta without grok is not an alert, and says why.
run "local box-beta" "grok@beta"
[ "$RC" = 0 ] && ok || bad "C2 a waived MISSING must exit 0 (rc=$RC): $OUT"
[ -z "$(grep '\[beta\]' <<<"$NEW")" ] && ok || bad "C2 beta was alerted anyway: $NEW"
grep -qP '^beta\tgrok\tmissing\t.*\tnot required on this box \(CLI_CHECK_OPTIONAL\)$' "$H/state/cli-versions-fleet.tsv" && ok \
  || bad "C2 TSV row note: $(grep grok "$H/state/cli-versions-fleet.tsv")"
jq -e '.rows[] | select(.box=="beta" and .cli=="grok") | .ok=="1" and .version_after=="missing" and (.note|test("not required on this box"))' <<<"$BODY" >/dev/null && ok \
  || bad "C2 grok DB row: $(jq -c '.rows[]|select(.box=="beta" and .cli=="grok")' <<<"$BODY" 2>/dev/null)"
grep -q 'beta ok' <<<"$OUT" && ok || bad "C2 the summary must count beta ok: $OUT"

# C3. Only MISSING is waived: an installed grok below the floor still alerts.
reset_box box-beta 2.1.261 0.155.1 1.0.13
run "local box-beta" "grok@beta"
[ "$RC" = 1 ] && ok || bad "C3 below-floor must still exit 1 (rc=$RC)"
grep -q '\[beta\].*grok 1.0.13 below the 1.0.40 floor' <<<"$NEW" && ok || bad "C3 the floor alert was waived: $NEW"

# C4. Exact pairs: grok@beta waives neither another box nor another CLI.
reset_box box-beta 2.1.261 - -
make_box box-betax 2.1.261 0.155.1 -
run "local box-beta box-betax" "grok@beta"
grep -q '\[betax\] CLI VERSIONS: grok MISSING' <<<"$NEW" && ok || bad "C4 grok@beta waived betax: $NEW"
B=$(grep '\[beta\]' <<<"$NEW")
grep -q 'codex MISSING' <<<"$B" && ok || bad "C4 grok@beta waived codex on beta: $NEW"
grep -q 'grok MISSING' <<<"$B" && bad "C4 grok on beta should be waived: $B" || ok
[ "$RC" = 1 ] && ok || bad "C4 rc=$RC"

# C5. Malformed tokens waive nothing, and each lands in the log by name.
reset_box box-beta 2.1.261 0.155.1 -
run "local box-beta" 'grok@ @beta GROK@beta;rm grok-beta'
grep -q '\[beta\] CLI VERSIONS: grok MISSING' <<<"$NEW" && ok || bad "C5 a malformed token waived grok on beta: $NEW"
for tok in 'grok@' '@beta' 'GROK@beta;rm' 'grok-beta'; do
  grep -qF "CLI_CHECK_OPTIONAL: ignored malformed token '$tok'" <<<"$LOGNEW" && ok || bad "C5 the log does not name '$tok': $LOGNEW"
done
# and a good token beside bad ones still works
run "local box-beta" '@beta grok@beta'
[ -z "$(grep '\[beta\]' <<<"$NEW")" ] && ok || bad "C5 a good token next to a bad one must still waive: $NEW"

echo "cli-version-check.bh-1636-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
