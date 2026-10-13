#!/bin/bash
# tests/box-self-report.bh-2626-test.sh — BH-2532.4 (BH-2626): boxes self-report
# their runner CLI versions and the md5 of their rendered CLAUDE.md, and the two
# hub checks read that row before they ssh.
#
# DRIVEN, NOT GREPPED. Every case runs the shipped script — bin/box-self-report.sh,
# bin/rules-drift-check.sh, bin/cli-version-check.sh — against a scratch harness
# holding the real bin/jobs-client.sh, with a stub curl answering GET /api/boxes
# from a fixture and sinking every request, and a stub ssh that counts its calls.
#   S1-S6  the box lane: exact POST body, hang -> one failure line and no POST,
#          curl failure -> no retry loop, held lock -> nothing, switch 0 ->
#          nothing, the cron render carries the line.
#   R1-R5  rules-drift-check: a fresh matching row skips ssh (while the box's
#          last full ssh probe is recent); a fresh differing
#          row with ssh down raises RULES DRIFT; a stale row, a failed read and
#          the window at 0 all fall back to ssh; plus the adversarial negatives
#          (future at, unparseable at, empty hash, a look-alike box name).
#   R6-R8  the full probe the row cannot replace: never probed / probe too old
#          -> ssh anyway, so RTK.md and settings.json drift still alerts; a due
#          probe that does not answer is UNREACHABLE; the window at 0 -> ssh.
#   C1-C5  cli-version-check: the same shape, plus the trust rule (the newest
#          CLI stamp must be the self-report's own) and "no source=check row for
#          a box the hub did not observe".
#   C6-C8  the full probe: never probed / too old -> ssh (grok, model floors and
#          the PATH split run), a due probe that does not answer is UNREACHABLE,
#          the window at 0 -> ssh.
# Run from anywhere: tests/box-self-report.bh-2626-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SELF="$DIR/bin/box-self-report.sh"
DRIFT="$DIR/bin/rules-drift-check.sh"
CHECK="$DIR/bin/cli-version-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

SECRET="self-report-secret-4d2a"
FB="$T/fakebin"; mkdir -p "$FB"
# The stub curl: records "<METHOD> <URL> <BODY>" to $REQ_SINK, fails with
# $CURL_RC when set, answers GET /api/boxes with $BOXES_FILE and anything else
# with an empty 200.
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
[ -n "${CURL_RC:-}" ] && exit "$CURL_RC"
case "$METHOD $URL" in
  "GET "*/api/boxes) cat "${BOXES_FILE:-/dev/null}"; printf '\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
CURL
chmod +x "$FB/curl"
# The stub ssh: counts, then either runs the probe (SSH_MODE=up) or fails.
cat > "$FB/ssh" <<'SSH'
#!/bin/bash
echo x >> "$SSH_COUNT"
[ "${SSH_MODE:-down}" = up ] || exit 255
shift; shift
exec bash -s
SSH
chmod +x "$FB/ssh"

HN=0
new_harness() { # new_harness -> H, a scratch harness with the real jobs client
  HN=$((HN+1)); H="$T/h$HN"
  mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/env" "$H/locks"
  cp "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  echo "HARNESS_SECRET=$SECRET" > "$H/env/global.env"
  : > "$T/req.log"; : > "$T/ssh.count"
}
ssh_calls() { grep -c . "$T/ssh.count"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW=$(date +%s)
FRESH_AT=$(iso $((NOW - 600)))
STALE_AT=$(iso $((NOW - 3*3600)))
FUTURE_AT=$(iso $((NOW + 3600)))
OLDER_AT=$(iso $((NOW - 1200)))

# ============================== S: the box lane ==============================
mkdir -p "$T/clis" "$T/claude"
# HANG=1 makes the stub a CLI that never answers; the sleep IS the hang under test, not a wait.
printf '#!/bin/bash\n[ -n "${HANG:-}" ] && sleep 60\n[ "$1" = --version ] && echo "2.1.300 (Claude Code)"\n' > "$T/clis/claude"   # determinism: ok race-sleep the stub simulates a hung CLI; nothing synchronises on it
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.150.1"\n' > "$T/clis/codex"
chmod +x "$T/clis/claude" "$T/clis/codex"
printf 'rendered rules fixture\n' > "$T/claude/CLAUDE.md"
FIX_MD5=$(md5sum "$T/claude/CLAUDE.md" | cut -d' ' -f1)

self() { # self [VAR=val ...] -> runs the shipped box lane once
  env PATH="$T/clis:$FB:$PATH" HARNESS="$H" JOBS_URL=http://jobs.test JOBS_BOX=box-project-3-2 \
    JOBS_RETRY_SLEEP=0 REQ_SINK="$T/req.log" BOX_SELF_REPORT_CLAUDE_DIR="$T/claude" "$@" "$SELF" >/dev/null 2>&1
}
posts() { grep -c '^POST .*/api/boxes/self-report ' "$T/req.log"; }

# S1: the exact POST body; the hash is md5sum of the fixture, "-" when absent
new_harness; self; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 rc=$RC"
[ "$(posts)" = 1 ] && ok || bad "S1 expected one POST: $(cat "$T/req.log")"
BODY=$(grep '/api/boxes/self-report' "$T/req.log" | head -1 | sed 's/^POST [^ ]* //')
jq -e --arg h "$FIX_MD5" '.box=="box-project-3-2" and .cli_version=="2.1.300" and .codex_version=="0.150.1"
  and .rules_hash==$h and (.at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (keys|sort)==["at","box","cli_version","codex_version","rules_hash"]' <<<"$BODY" >/dev/null \
  && ok || bad "S1 body: $BODY"
grep -q "box-self-report: claude=2.1.300 codex=0.150.1 rules=${FIX_MD5:0:8}" "$H/logs/box-self-report.log" \
  && ok || bad "S1 log: $(cat "$H/logs/box-self-report.log" 2>/dev/null)"
new_harness; self BOX_SELF_REPORT_CLAUDE_DIR="$T/nowhere"
BODY=$(grep '/api/boxes/self-report' "$T/req.log" | head -1 | sed 's/^POST [^ ]* //')
jq -e '.rules_hash=="-"' <<<"$BODY" >/dev/null && ok || bad "S1 absent CLAUDE.md must report '-': $BODY"

# S2: a hanging CLI -> killed by the bound, ONE failure line, no POST
new_harness; START=$(date +%s); self HANG=1 BOX_SELF_REPORT_TIMEOUT=2; RC=$?; EL=$(( $(date +%s) - START ))
[ "$RC" = 0 ] && ok || bad "S2 rc=$RC"
[ "$EL" -lt 9 ] && ok || bad "S2 the bound did not bound: ${EL}s"
[ "$(posts)" = 0 ] && ok || bad "S2 a timed-out report must not POST: $(cat "$T/req.log")"
[ "$(grep -c 'box-self-report: failed rc=124' "$H/logs/box-self-report.log" 2>/dev/null)" = 1 ] \
  && ok || bad "S2 expected one failure line: $(cat "$H/logs/box-self-report.log" 2>/dev/null)"
[ "$(wc -l < "$H/logs/box-self-report.log")" = 1 ] && ok || bad "S2 exactly one log line"

# S3: the worker is unreachable -> one failure line; the only repeat is the
# jobs client's single transport retry, never a loop
new_harness; self CURL_RC=7; RC=$?
[ "$RC" = 0 ] && ok || bad "S3 rc=$RC"
N=$(posts); [ "$N" -ge 1 ] && [ "$N" -le 2 ] && ok || bad "S3 expected 1-2 attempts, got $N"
[ "$(grep -c 'box-self-report: failed rc=1' "$H/logs/box-self-report.log" 2>/dev/null)" = 1 ] \
  && ok || bad "S3 expected one failure line: $(cat "$H/logs/box-self-report.log" 2>/dev/null)"
grep -q 'box-self-report: claude=' "$H/logs/box-self-report.log" && bad "S3 a failed POST logged as success" || ok

# S4: the lock is held -> skip at once, nothing posted, nothing logged
new_harness
flock "$H/locks/box-self-report.lock" sleep 5 & HOLDER=$!   # determinism: ok race-sleep the holder only has to outlive the run below; readiness is polled
for _ in $(seq 1 50); do flock -n "$H/locks/box-self-report.lock" true 2>/dev/null || break; sleep 0.1; done   # determinism: ok race-sleep bounded poll for the holder to own the lock
START=$(date +%s); self; EL=$(( $(date +%s) - START ))
[ "$(posts)" = 0 ] && ok || bad "S4 a held lock must mean no POST"
[ "$EL" -lt 4 ] && ok || bad "S4 flock must not wait (${EL}s)"
[ -s "$H/logs/box-self-report.log" ] && bad "S4 a deduped run logged" || ok
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# S5: the switch at 0 -> nothing
new_harness; self BOX_SELF_REPORT_ENABLED=0
[ "$(posts)" = 0 ] && ok || bad "S5 BOX_SELF_REPORT_ENABLED=0 must not POST"
[ -e "$H/locks/box-self-report.lock" ] && bad "S5 switched off, yet it took the lock" || ok

# S6: the cron render carries the lane, once
[ "$("$DIR/bin/render-cron.sh" project-1 2>/dev/null | grep -c 'box-self-report.sh')" = 1 ] \
  && ok || bad "S6 render-cron project-1 must carry one box-self-report line"

# ========================= R: rules-drift-check ==============================
CK="$T/ck"; mkdir -p "$CK/rules"
printf 'canon rules\n' > "$CK/rules/CLAUDE.md"; printf 'rtk\n' > "$CK/rules/RTK.md"; printf '{}\n' > "$CK/rules/settings.json"
CANON=$(md5sum "$CK/rules/CLAUDE.md" | cut -d' ' -f1)
OTHER=$(printf other | md5sum | cut -d" " -f1)
boxes_json() { # boxes_json <box> <rules_hash> <rules_reported_at> [cli codex cli_checked_at] -> $T/boxes.json
  jq -n --arg b "$1" --arg h "$2" --arg r "$3" --arg c "${4:-}" --arg x "${5:-}" --arg ca "${6:-}" \
    '{boxes:[{box:$b, rules_hash:(if $h=="" then null else $h end), rules_reported_at:(if $r=="" then null else $r end),
      cli_version:(if $c=="" then null else $c end), codex_version:(if $x=="" then null else $x end),
      cli_checked_at:(if $ca=="" then null else $ca end)}]}' > "$T/boxes.json"
}
# stamp_rd <age-s> — the box's last full rules probe answered <age-s> ago
stamp_rd() { mkdir -p "$H/state/rules-drift"; echo $((NOW - $1)) > "$H/state/rules-drift/fullprobe-box-project-3-2"; }
drift() { # drift [VAR=val ...] -> OUT RC NEW
  local before=0
  [ -f "$H/logs/ALERTS.log" ] && before=$(wc -l < "$H/logs/ALERTS.log")
  OUT=$(env PATH="$FB:$PATH" HARNESS="$H" HARNESS_CHECKOUT="$CK" JOBS_URL=http://jobs.test \
    JOBS_RETRY_SLEEP=0 REQ_SINK="$T/req.log" BOXES_FILE="$T/boxes.json" SSH_COUNT="$T/ssh.count" \
    RULES_DRIFT_BOXES=box-project-3-2 RULES_DRIFT_SSH="$FB/ssh" "$@" "$DRIFT" 2>&1); RC=$?
  NEW=$(tail -n +$((before+1)) "$H/logs/ALERTS.log" 2>/dev/null)
}

# R1: a fresh row whose hash is canon -> judged from the row, no ssh, no alert.
# The row is under a different generation suffix (box-project-3-1 vs -project-3-2):
# the same cron box id, so it answers for the box.
# The box's last full ssh probe answered an hour ago, inside RULES_DRIFT_FULL_PROBE_S.
new_harness; stamp_rd 3600; boxes_json box-project-3-1 "$CANON" "$FRESH_AT"; drift
[ "$(ssh_calls)" = 0 ] && ok || bad "R1 a fresh matching row must not ssh ($(ssh_calls) calls): $OUT"
[ -z "$NEW" ] && ok || bad "R1 no ALERTS expected: $NEW"
[ "$RC" = 0 ] && ok || bad "R1 rc=$RC: $OUT"
grep -q "box-project-3-2 ok (CLAUDE.md via self-report $FRESH_AT; RTK.md/settings.json via ssh $(iso $((NOW - 3600))))" <<<"$OUT" \
  && ok || bad "R1 the report line must say what the row verified and when the rest was: $OUT"
grep -q '1 converged, 0 drifted, 0 unreachable' <<<"$OUT" && ok || bad "R1 summary: $OUT"
# ...and it clears an earlier unreach note for that box, since the row proves it alive
new_harness; stamp_rd 3600; : > "$H/state/rules-drift/unreach-box-project-3-2"
boxes_json box-project-3-2 "$CANON" "$FRESH_AT"; drift
[ -e "$H/state/rules-drift/unreach-box-project-3-2" ] && bad "R1 the unreach note survived a fresh matching row" || ok

# R2: a fresh DIFFERING row and ssh down -> RULES DRIFT from the row, not "could not probe"
new_harness; boxes_json box-project-3-2 "$OTHER" "$FRESH_AT"; drift
[ "$(ssh_calls)" -ge 1 ] && ok || bad "R2 a differing row must still try ssh (only it can tell overlay/render/checkout apart)"
grep -q "\[box-project-3-2\] RULES DRIFT: /root/.claude/CLAUDE.md self-reported ${OTHER:0:8}" <<<"$NEW" \
  && ok || bad "R2 expected a RULES DRIFT line from the row: $NEW"
grep -q 'could not probe' <<<"$NEW" && bad "R2 the row proves the box alive; no unreach alert: $NEW" || ok
[ "$RC" = 1 ] && ok || bad "R2 rc must be 1 (drift): $RC"

# R3: a stale row (3 h) -> ssh, exactly as before
new_harness; boxes_json box-project-3-2 "$CANON" "$STALE_AT"; drift
[ "$(ssh_calls)" -ge 1 ] && ok || bad "R3 a stale row must ssh"
grep -q 'could not probe' <<<"$NEW" && ok || bad "R3 stale row + ssh down must still say unreachable: $NEW"

# R4: the reader fails (curl rc 7) -> ssh every box, one log line
new_harness; boxes_json box-project-3-2 "$CANON" "$FRESH_AT"; drift CURL_RC=7
[ "$(ssh_calls)" -ge 1 ] && ok || bad "R4 a failed read must fall back to ssh"
grep -q 'self-report read failed; ssh for every box' "$H/logs/rules-drift.log" && ok || bad "R4 the failed read was not logged"

# R5: the window at 0 -> self-reports ignored
new_harness; boxes_json box-project-3-2 "$CANON" "$FRESH_AT"; drift RULES_DRIFT_SELF_REPORT_FRESH_S=0
[ "$(ssh_calls)" -ge 1 ] && ok || bad "R5 RULES_DRIFT_SELF_REPORT_FRESH_S=0 must ssh"
[ "$(grep -c '/api/boxes' "$T/req.log")" = 0 ] && ok || bad "R5 with the window at 0 the DB is not even read"

# negatives: none of these may skip ssh
for neg in "future|box-project-3-2|$CANON|$FUTURE_AT" "unparseable|box-project-3-2|$CANON|yesterday-ish" \
           "empty-hash|box-project-3-2||$FRESH_AT" "look-alike|box-project-3-1x|$CANON|$FRESH_AT"; do
  IFS='|' read -r name b h a <<<"$neg"
  new_harness; boxes_json "$b" "$h" "$a"; drift
  [ "$(ssh_calls)" -ge 1 ] && ok || bad "R-neg $name must ssh: $OUT"
  grep -q 'self-report' <<<"$OUT" && bad "R-neg $name judged from the row: $OUT" || ok
done
# a hub row is never used: the hub is always probed locally
new_harness; boxes_json box-hub "$OTHER" "$FRESH_AT"
drift RULES_DRIFT_BOXES=local RULES_DRIFT_CLAUDE_DIR="$T/nowhere"
grep -q 'self-reported' <<<"$NEW" && bad "R-local the hub row must not be read: $NEW" || ok

# R6: a fresh matching row but NO full probe on record -> ssh anyway; RTK.md
# drift on the box (which the row cannot see) alerts, and the probe is stamped
LIVE="$T/live"; mkdir -p "$LIVE"
cp "$CK/rules/CLAUDE.md" "$CK/rules/settings.json" "$LIVE/"; printf 'hand-edited rtk\n' > "$LIVE/RTK.md"
new_harness; boxes_json box-project-3-2 "$CANON" "$FRESH_AT"; drift SSH_MODE=up RULES_DRIFT_CLAUDE_DIR="$LIVE"
[ "$(ssh_calls)" = 1 ] && ok || bad "R6 never fully probed must ssh once ($(ssh_calls)): $OUT"
grep -q '\[box-project-3-2\] RULES DRIFT: /root/.claude/RTK.md' <<<"$NEW" && ok || bad "R6 RTK.md drift must alert: $NEW"
[ "$RC" = 1 ] && ok || bad "R6 rc must be 1: $RC"
E=$(cat "$H/state/rules-drift/fullprobe-box-project-3-2" 2>/dev/null)
[ -n "$E" ] && [ $(( $(date +%s) - E )) -lt 120 ] && ok || bad "R6 a probe that answered must be stamped: '$E'"
# ...and the next run, inside the window, is judged from the row again
drift SSH_MODE=up RULES_DRIFT_CLAUDE_DIR="$LIVE"
[ "$(ssh_calls)" = 1 ] && ok || bad "R6 a just-stamped box must not be ssh'd again ($(ssh_calls))"
# a clean box on its full probe converges
cp "$CK/rules/RTK.md" "$LIVE/RTK.md"
new_harness; stamp_rd 90000; boxes_json box-project-3-2 "$CANON" "$FRESH_AT"; drift SSH_MODE=up RULES_DRIFT_CLAUDE_DIR="$LIVE"
[ "$(ssh_calls)" = 1 ] && ok || bad "R6 a probe older than the day default must ssh ($(ssh_calls))"
[ -z "$NEW" ] && [ "$RC" = 0 ] && ok || bad "R6 a clean box on its full probe: rc=$RC $NEW"

# R7: the full probe is due and ssh does not answer -> UNREACHABLE, saying the
# row vouched for CLAUDE.md only; not stamped, so the next run tries again
new_harness; stamp_rd 90000; boxes_json box-project-3-2 "$CANON" "$FRESH_AT"; drift
[ "$(ssh_calls)" = 1 ] && ok || bad "R7 a due full probe must ssh"
grep -q 'could not probe the box over ssh — CLAUDE.md matches canon by its self-report' <<<"$NEW" \
  && ok || bad "R7 expected the partial unreach alert: $NEW"
grep -q 'RTK.md and settings.json are unverified' <<<"$NEW" && ok || bad "R7 the alert must name what is unverified: $NEW"
[ "$RC" = 2 ] && ok || bad "R7 rc must be 2: $RC"
drift
[ "$(ssh_calls)" = 2 ] && ok || bad "R7 an unanswered full probe must be re-tried next run ($(ssh_calls))"

# R8: RULES_DRIFT_FULL_PROBE_S=0 -> ssh every run, however recent the stamp
new_harness; stamp_rd 60; boxes_json box-project-3-2 "$CANON" "$FRESH_AT"; drift RULES_DRIFT_FULL_PROBE_S=0
[ "$(ssh_calls)" = 1 ] && ok || bad "R8 RULES_DRIFT_FULL_PROBE_S=0 must ssh"

# ========================= C: cli-version-check ==============================
HUBF="$T/hubbox"; mkdir -p "$HUBF/cronbin" "$HUBF/shim" "$HUBF/home/.grok/bin"
fake_cli() { printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s"\n' "$2" > "$1"; chmod +x "$1"; }
fake_cli "$HUBF/cronbin/claude" "2.1.300 (Claude Code)"
fake_cli "$HUBF/cronbin/codex" "codex-cli 0.160.0"
fake_cli "$HUBF/home/.grok/bin/grok" "grok 1.0.40"
printf '#!/bin/bash\necho "PATH=%s"\n' "$HUBF/cronbin" > "$HUBF/shim/crontab"; chmod +x "$HUBF/shim/crontab"
echo "HARNESS_SECRET=$SECRET" > "$HUBF/global.env"
cvc() { # cvc [VAR=val ...] -> OUT RC NEW
  local before=0
  [ -f "$H/logs/ALERTS.log" ] && before=$(wc -l < "$H/logs/ALERTS.log")
  OUT=$(env PATH="$HUBF/shim:$FB:$PATH" HARNESS="$H" HARNESS_CHECKOUT="$DIR" JOBS_URL=http://jobs.test \
    JOBS_RETRY_SLEEP=0 REQ_SINK="$T/req.log" BOXES_FILE="$T/boxes.json" SSH_COUNT="$T/ssh.count" \
    CLI_CHECK_BOXES="local box-project-3-2" CLI_CHECK_SSH="$FB/ssh" \
    CLI_CHECK_ENV_FILE="$HUBF/global.env" CLI_CHECK_LOGIN_PATH="$HUBF/cronbin" CLI_CHECK_HOME="$HUBF/home" \
    "$@" "$CHECK" 2>&1); RC=$?
  NEW=$(tail -n +$((before+1)) "$H/logs/ALERTS.log" 2>/dev/null)
}
# stamp_cv <age-s> — project-3's last full CLI probe answered <age-s> ago
stamp_cv() { mkdir -p "$H/state/cli-version-check"; echo $((NOW - $1)) > "$H/state/cli-version-check/fullprobe-project-3"; }
check_rows_for() { # check_rows_for <box-id> -> count of source=check rows for it in the sink
  grep 'POST .*/api/metrics/cli-versions' "$T/req.log" | sed 's/^POST [^ ]* //' \
    | jq -r --arg b "$1" '[.rows[]? | select(.box==$b and .source=="check")] | length' 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

# C1: a trusted fresh row equal to the hub, last full probe a day ago -> no
# ssh, no alert, no source=check row for it
new_harness; stamp_cv 86400; boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.300 0.160.0 "$FRESH_AT"; cvc
[ "$(ssh_calls)" = 0 ] && ok || bad "C1 a trusted row must not ssh ($(ssh_calls)): $OUT"
[ -z "$NEW" ] && ok || bad "C1 no ALERTS expected: $NEW"
[ "$RC" = 0 ] && ok || bad "C1 rc=$RC: $OUT"
grep -q '2 ok, 0 need attention, 0 unreachable' <<<"$OUT" && ok || bad "C1 summary: $OUT"
[ "$(check_rows_for project-3)" = 0 ] && ok || bad "C1 the hub re-posted a self-reported version as source=check"
[ "$(check_rows_for hub)" -ge 1 ] && ok || bad "C1 the hub's own rows must still be posted"
grep -qP "^project-3\tclaude\t2.1.300\tself-report@$FRESH_AT\t" "$H/state/cli-versions-fleet.tsv" \
  && ok || bad "C1 TSV path column: $(cat "$H/state/cli-versions-fleet.tsv")"
grep -q "project-3 ok (claude/codex via self-report $FRESH_AT; grok, model floors, PATH split via ssh $(iso $((NOW - 86400))))" <<<"$OUT" \
  && ok || bad "C1 the report line must say what the row verified and when the rest was: $OUT"

# C2: a trusted row behind the hub -> CLI VERSIONS alert, still no ssh
new_harness; stamp_cv 86400; boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.290 0.160.0 "$FRESH_AT"; cvc
[ "$(ssh_calls)" = 0 ] && ok || bad "C2 a trusted row must not ssh"
grep -q '\[project-3\] CLI VERSIONS: claude 2.1.290 behind hub 2.1.300' <<<"$NEW" && ok || bad "C2 expected a behind-hub alert: $NEW"
[ "$RC" = 1 ] && ok || bad "C2 rc must be 1: $RC"

# C3: a stale row -> ssh
new_harness; boxes_json box-project-3-2 "$CANON" "$STALE_AT" 2.1.300 0.160.0 "$STALE_AT"; cvc
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C3 a stale row must ssh"
grep -q '\[project-3\] cli-version-check could not probe' <<<"$NEW" && ok || bad "C3 unreachable expected: $NEW"

# C4: the reader fails -> ssh
new_harness; boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.300 0.160.0 "$FRESH_AT"; cvc CURL_RC=7
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C4 a failed read must fall back to ssh"
grep -q 'self-report read failed; ssh for every box' "$H/logs/cli-version-check.log" && ok || bad "C4 the failed read was not logged"

# C5: the window at 0 -> ssh
new_harness; boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.300 0.160.0 "$FRESH_AT"; cvc CLI_CHECK_SELF_REPORT_FRESH_S=0
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C5 CLI_CHECK_SELF_REPORT_FRESH_S=0 must ssh"

# negatives: the newest CLI stamp is not the self-report's own; codex empty;
# a future stamp; an unparseable stamp — each must ssh
new_harness; boxes_json box-project-3-2 "$CANON" "$OLDER_AT" 2.1.300 0.160.0 "$FRESH_AT"; cvc
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C-neg cli_checked_at newer than rules_reported_at must ssh"
new_harness; boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.300 "" "$FRESH_AT"; cvc
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C-neg an empty codex_version must ssh"
new_harness; boxes_json box-project-3-2 "$CANON" "$FUTURE_AT" 2.1.300 0.160.0 "$FUTURE_AT"; cvc
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C-neg a future stamp must ssh"
new_harness; boxes_json box-project-3-2 "$CANON" "garbage" 2.1.300 0.160.0 "garbage"; cvc
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C-neg an unparseable stamp must ssh"

# C6: a trusted row but no full probe on record, or one older than the week
# default -> ssh anyway (the probe's grok/model/PATH checks run), rows posted
# as source=check, and the probe stamped
for age in none 700000; do
  new_harness; [ "$age" = none ] || stamp_cv "$age"
  boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.300 0.160.0 "$FRESH_AT"; cvc SSH_MODE=up
  [ "$(ssh_calls)" = 1 ] && ok || bad "C6[$age] a due full probe must ssh ($(ssh_calls)): $OUT"
  grep -q 'self-report@' "$H/state/cli-versions-fleet.tsv" && bad "C6[$age] judged from the row: $(cat "$H/state/cli-versions-fleet.tsv")" || ok
  grep -qP '^project-3\tgrok\t' "$H/state/cli-versions-fleet.tsv" && ok || bad "C6[$age] the full probe must read grok: $(cat "$H/state/cli-versions-fleet.tsv")"
  [ "$(check_rows_for project-3)" -ge 1 ] && ok || bad "C6[$age] an observed box posts source=check rows"
  E=$(cat "$H/state/cli-version-check/fullprobe-project-3" 2>/dev/null)
  [ -n "$E" ] && [ $(( $(date +%s) - E )) -lt 120 ] && ok || bad "C6[$age] a probe that answered must be stamped: '$E'"
done

# C7: the full probe is due and ssh does not answer -> UNREACHABLE, not stamped
new_harness; stamp_cv 700000; boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.300 0.160.0 "$FRESH_AT"; cvc
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C7 a due full probe must ssh"
grep -q '\[project-3\] cli-version-check could not probe' <<<"$NEW" && ok || bad "C7 unreachable expected: $NEW"
[ "$(cat "$H/state/cli-version-check/fullprobe-project-3")" = $((NOW - 700000)) ] && ok || bad "C7 an unanswered probe must not be stamped"

# C8: CLI_CHECK_FULL_PROBE_S=0 -> ssh however recent the stamp
new_harness; stamp_cv 60; boxes_json box-project-3-2 "$CANON" "$FRESH_AT" 2.1.300 0.160.0 "$FRESH_AT"; cvc CLI_CHECK_FULL_PROBE_S=0
[ "$(ssh_calls)" -ge 1 ] && ok || bad "C8 CLI_CHECK_FULL_PROBE_S=0 must ssh"

echo "box-self-report.bh-2626-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
