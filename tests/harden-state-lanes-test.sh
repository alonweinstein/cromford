#!/bin/bash
# tests/harden-state-lanes-test.sh — the box-lifecycle lanes of the hardening
# work (BH-390.4): bin/healthcheck.sh reports hardened=N/M and alerts when the
# figure is short or unknown, bin/bootstrap-machine.sh arms the box it just
# built, and docs/OPERATOR-SETUP.md tells the operator how to live with +i.
#
# THE PROPERTY: the figure never reads better than it is. A short count, a
# harden-state.sh that cannot run, a line that is not a count at all — each of
# those pages, and none of them is allowed to pass for "hardened".
#
# ORDER, on purpose: the source pins (A8) and the doc pins (A9) run FIRST and
# need no chattr, so they still execute where `chattr +i` is refused — which is
# every GitHub runner, i.e. the only place this suite runs on a schedule. The
# SKIP gate sits after them and covers A6/A7 only, because those are the cases
# that drive real immutable files.
#
# A8 IS A SOURCE PIN AND SAYS SO: bin/bootstrap-machine.sh cannot be executed in
# a fixture (it apt-gets, clones repos and opens a paid claude session), so the
# four edits it owns are pinned by exact grep counts and line order. Every pin
# asserts a count, so a call that vanished fails here instead of matching
# nothing quietly.
#
# MUTATION CHECK (D1), each run once against this suite before it was called done:
#   delete the `# >>> hardened report` block from bin/healthcheck.sh -> A6a, A6b, A7 red
#   force HS_OK=1 unconditionally                                    -> A6b, A7 red
#   drop the `--rearm` call from bin/bootstrap-machine.sh            -> A8 red
#   drop the already-600 `continue` from the preflight chmod loop     -> A8a red
#
# Run from anywhere: tests/harden-state-lanes-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

BOOT="$DIR/bin/bootstrap-machine.sh"
HCSRC="$DIR/bin/healthcheck.sh"
DOC="$DIR/docs/OPERATOR-SETUP.md"
H="$T/harness"

# count <label> <expected> <fixed-string> <file> — grep -c, never unguarded:
# a pattern with no hits reports 0 and FAILS, which is the whole point of a pin.
count() {
  local label="$1" want="$2" pat="$3" file="$4" got
  got=$(grep -cF -- "$pat" "$file")
  [ "$got" = "$want" ] && ok || bad "$label: expected $want hit(s) for [$pat] in ${file##*/}, got $got"
}
# atleast <label> <n> <fixed-string> <file> — for prose, where the exact number
# of mentions is the writer's business but zero of them is a missing sentence.
atleast() {
  local label="$1" want="$2" pat="$3" file="$4" got
  got=$(grep -cF -- "$pat" "$file")
  [ "$got" -ge "$want" ] && ok || bad "$label: expected at least $want hit(s) for [$pat] in ${file##*/}, got $got"
}
# lineno <fixed-string> <file> — first matching line number, empty when absent.
lineno() { grep -nF -- "$1" "$2" | cut -d: -f1 | sed -n 1p; }
# before <label> <a> <b> <file> — a's first hit is above b's first hit, both present.
before() {
  local label="$1" a b
  a=$(lineno "$2" "$4"); b=$(lineno "$3" "$4")
  if [ -z "$a" ] || [ -z "$b" ]; then
    bad "$label: one of the two anchors is missing ([$2]=${a:-none} [$3]=${b:-none})"
  elif [ "$a" -lt "$b" ]; then ok
  else bad "$label: [$2] is at line $a, expected above [$3] at line $b"
  fi
}

# ---------- A8: bootstrap-machine.sh source pins (SOURCE PIN, not behaviour) ----------
# (a) the chmod loop never chmods a file that is already right, and a file that
# is BOTH wrong and immutable goes through harden-state.sh, never a raw chattr.
# The lsattr-skip this used to pin was replaced in BH-619: lsattr only covered
# the already-600 case, and chmod still died with EPERM on a +i file whose mode
# was wrong. The property is unchanged and now also has a behaviour test that
# drives this exact block (tests/bootstrap-hardened-env-test.sh case a/b/d).
count "A8a chmod loop skips a file already at 600" 1 '= 600 ] && continue' "$BOOT"
count "A8a an immutable+wrong file is released by harden-state" 1 '"$HERE/harden-state.sh" --release "$f"' "$BOOT"
count "A8a an immutable+wrong file is re-armed by harden-state" 1 '"$HERE/harden-state.sh" --rearm "$f"' "$BOOT"
count "A8a blanket chmod is gone"   0 'chmod 600 "$HENV"/*.env' "$BOOT"
# (b) the global.env seeds run between a release and a rearm, under the lock
count "A8b release call"  1 '"$HERE/harden-state.sh" --release "$HENV/global.env"' "$BOOT"
count "A8b rearm call"    1 '"$HERE/harden-state.sh" --rearm "$HENV/global.env"' "$BOOT"
count "A8b holds the re-arm lock" 1 'flock -w 60 8' "$BOOT"
before "A8b release precedes the BUILD_SLOTS seed" \
  '--release "$HENV/global.env"' 'echo "BUILD_SLOTS=0" >> "$HENV/global.env"' "$BOOT"
before "A8b the RUNNER_ seed precedes the rearm" \
  'RUNNER_${s}_FALLBACK' '--rearm "$HENV/global.env"' "$BOOT"
# (c) the singleton filter drops the harden-state line so a re-bootstrap keeps one copy
count "A8c singleton filter drops harden-state" 1 'grep -v harden-state' "$BOOT"
before "A8c the filter reads the live crontab first" 'crontab -l' 'grep -v harden-state' "$BOOT"
before "A8c the filter runs before the box lines are re-emitted" \
  'grep -v harden-state' 'cron_box_lines "$FLY_CRON"' "$BOOT"
# (d) the box is armed after the smoke test and before COMPLETE, and a failure is fatal
count "A8d arms at the end" 1 '"$HERE/harden-state.sh" || {' "$BOOT"
# The smoke turn runs through agent-call on lane claude-auth-check (BH-2535).
before "A8d arming follows the claude smoke test" 'AGENT_CALL_LANE=claude-auth-check' '"$HERE/harden-state.sh" || {' "$BOOT"
before "A8d arming precedes BOOTSTRAP COMPLETE" \
  '"$HERE/harden-state.sh" || {' 'BOOTSTRAP COMPLETE' "$BOOT"

# ---------- A9: operator doc pins (DOC PIN) ----------
S6=$(lineno '## Step 6: the env files' "$DOC")
S7=$(lineno '## Step 7: bootstrap the box' "$DOC")
S8=$(grep -n '^## ' "$DOC" | awk -F: -v s="${S7:-0}" '$1 > s {print $1; exit}')
if [ -z "$S6" ] || [ -z "$S7" ] || [ -z "$S8" ]; then
  bad "A9 could not locate Step 6 / Step 7 in ${DOC##*/} (6=${S6:-none} 7=${S7:-none} end=${S8:-none})"
else
  ok
  awk -v a="$S6" -v b="$S7" 'NR>a && NR<b' "$DOC" > "$T/step6.md"
  awk -v a="$S7" -v b="$S8" 'NR>a && NR<b' "$DOC" > "$T/step7.md"
  count "A9 Step 6 shows the release/edit/rearm cycle" 1 'bin/harden-state.sh --release env/global.env' "$T/step6.md"
  count "A9 Step 6 shows the rearm"                    1 'bin/harden-state.sh --rearm env/global.env' "$T/step6.md"
  count "A9 Step 6 shows --status"                     1 'bin/harden-state.sh --status' "$T/step6.md"
  # The hub has no project row with a prod URL, so healthcheck never runs there:
  # the doc must send the operator to --status and the ledger, not to a lane
  # that does not fire.
  count "A9 Step 6 names the hub's own figure" 1 'logs/harden-state.log' "$T/step6.md"
  count "A9 no claim that the hub healthcheck prints the figure" 0 'hub healthcheck prints' "$DOC"
  # Every ledger the script actually arms is named — the ticket says eight, the
  # array says ten, and the doc has to match the array or it lies the day
  # someone reads it.
  LEDGERS_FOUND=0
  while read -r NAME; do
    [ -n "$NAME" ] || continue
    LEDGERS_FOUND=$((LEDGERS_FOUND+1))
    atleast "A9 Step 6 names ledger $NAME" 1 "$NAME" "$T/step6.md"
  done < <(awk '/^LEDGERS=\(/{f=1;next} f&&/^\)/{exit} f{gsub(/[ \t]/,""); if ($0 != "") print}' "$DIR/bin/harden-state.sh")
  [ "$LEDGERS_FOUND" = 10 ] && ok || bad "A9 expected 10 ledger names in bin/harden-state.sh LEDGERS, read $LEDGERS_FOUND"
  atleast "A9 Step 6 says ALERTS.log can no longer be rotated" 1 'rotated' "$T/step6.md"
  atleast "A9 Step 7 says bootstrap ends by arming" 1 'bin/harden-state.sh' "$T/step7.md"
  atleast "A9 Step 7 says a box it cannot arm is not bootstrapped" 1 'fails' "$T/step7.md"
  # The Orgo restore/merge path overwrote env/* once already (#388). Against +i
  # that copy now fails, so the doc has to say --release first.
  RESTORE=$(grep -cF -- '#388' "$DOC")
  [ "$RESTORE" -ge 2 ] && ok || bad "A9 expected the restore/merge sentence to cite #388 alongside the existing one (hits=$RESTORE)"
  atleast "A9 the restore/merge sentence is in Step 6" 1 'restore' "$T/step6.md"
fi

# ---------- A0: chattr probe — A6/A7 need real immutable files ----------
probe=$(mktemp)
if ! chattr +i "$probe" 2>/dev/null; then
  rm -f "$probe"
  echo "SKIP: chattr +i refused here — A6/A7 (the live healthcheck report) not run"
  echo "harden-state-lanes-test: $PASS pass, $FAIL fail (A6/A7 SKIPPED)"
  [ "$FAIL" -eq 0 ]
  exit
fi
chattr -i "$probe" 2>/dev/null || true
rm -f "$probe"

# ---------- Fixture: the 16 targets of tests/harden-state-test.sh ----------
# Same shape on purpose: two suites that disagree about what a hardened box
# looks like are two suites nobody can read.
mkdir -p "$H/bin/lib" "$H/env/accounts.d" "$H/env/tokens.d" "$H/logs" "$H/locks" "$H/ssh" "$T/tmp"
printf 'GLOBAL=1\n' > "$H/env/global.env"
printf 'ACCT=1\n'   > "$H/env/accounts.d/primary.env"
printf 'TOKEN=1\n'  > "$H/env/tokens.d/api.token"
printf 'PEM=1\n'    > "$H/env/github-app.pem"
printf 'DOT=1\n'    > "$H/env/.watchdog-secret"
ln -s /etc/hostname "$H/env/link"
touch "$H/ssh/id_ed25519" "$H/ssh/id_ed25519.pub" "$H/ssh/authorized_keys"
for name in cost.csv ALERTS.log harden-state.log alerts-state.log agent-rules.log findings.log medic.log blocked-resolver.log; do
  touch "$H/logs/$name"
done
cp "$DIR/bin/harden-state.sh" "$DIR/bin/healthcheck.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H/bin/"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
printf '#!/bin/bash\nprintf -- "-\\n"\n' > "$H/bin/prod-url.sh"
cat > "$H/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$H/beats.log"
EOF
chmod +x "$H/bin/prod-url.sh" "$H/bin/beat.sh"

# An armed fixture cannot be deleted by the scratch lib's cleanup, so hand the
# flags back before it runs. chattr, not harden-state.sh: A7 replaces that copy
# with a stub, and cleanup still has to work afterwards.
lanes_cleanup() {
  chattr -R -i "$H/env" "$H/ssh" 2>/dev/null
  chattr -R -a "$H/logs" 2>/dev/null
  scratch_cleanup
}
trap lanes_cleanup EXIT

HS_REAL="$H/bin/harden-state.sh"
ARM() { HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" bash "$HS_REAL" "$@"; }
# The production entry point, whole (D2): the real script, its own early exits,
# a fake prod-url that answers "-" so the run ends right after the report.
HC() { HARNESS="$H" HARDEN_SSH_DIR="$H/ssh" HEALTHCHECK_TMP_ROOT="$T/tmp" \
       bash "$H/bin/healthcheck.sh" some-project 2>&1; }
alerts() { grep -cF -- "$1" "$H/logs/ALERTS.log"; }
# fleet_alert pages only: since BH-2364 each ALERTS line also beats one kind:"alert" table note
beats()  { local n; n=$(grep -c '"kind":"fleet_alert"' "$H/beats.log" 2>/dev/null); echo "${n:-0}"; }

OUT=$(ARM); RC=$?
[ "$RC" -eq 0 ] && ok || bad "fixture: arm-all rc 0 (got $RC, out: $OUT)"
[ "$OUT" = "hardened=16/16 changed=16" ] && ok || bad "fixture: arm-all output (got: $OUT)"

# ---------- A6a: a fully hardened box reports, and does NOT alert ----------
OUT=$(HC); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6a healthcheck rc 0 on a hardened box (got $RC, out: $OUT)"
grep -qF 'hardened=16/16' <<<"$OUT" && ok || bad "A6a healthcheck must print the figure (got: $OUT)"
# The fake prod-url answers "-", so the script exits immediately after the
# report: printing it at all proves the report sits BEFORE that early exit.
[ "$(beats)" = 0 ] && ok || bad "A6a a hardened box must not raise a beat (beats=$(beats))"
[ ! -s "$H/beats.log" ] && ok || bad "A6a a hardened box must not raise a beat of any kind, alert notes included (beats.log: $(cat "$H/beats.log"))"
[ "$(alerts 'HARDEN:')" = 0 ] && ok || bad "A6a a hardened box must not write an ALERTS line"

# ---------- A6b: one released ledger is short, pages once, and recovers ----------
ARM --release "$H/logs/cost.csv"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6b release of one ledger rc 0 (got $RC)"
OUT=$(HC); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6b healthcheck stays fail-open when the figure is short (got $RC)"
grep -qF 'hardened=15/16' <<<"$OUT" && ok || bad "A6b healthcheck must print the short figure (got: $OUT)"
[ "$(alerts 'HARDEN: hardened=15/16')" = 1 ] && ok || bad "A6b exactly one ALERTS line for the short figure"
[ "$(beats)" = 1 ] && ok || bad "A6b exactly one beat for the short figure (beats=$(beats))"
grep -qF '"kind":"fleet_alert"' "$H/beats.log" && ok || bad "A6b the beat must be a fleet_alert"
grep -qF '"akey":"hardened:' "$H/beats.log" && ok || bad "A6b the beat must carry the hardened: akey"

ARM --rearm "$H/logs/cost.csv"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6b rearm rc 0 (got $RC)"
OUT=$(HC); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6b healthcheck rc 0 once the ledger is back (got $RC)"
grep -qF 'hardened=16/16' <<<"$OUT" && ok || bad "A6b figure is whole again (got: $OUT)"
[ "$(beats)" = 1 ] && ok || bad "A6b a recovered box must not beat again (beats=$(beats))"

# ---------- A7: unknown never reads as OK ----------
# harden-state.sh itself cannot run (no chattr, lock timeout): rc 2, no output.
printf '#!/bin/bash\nexit 2\n' > "$HS_REAL"
OUT=$(HC); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A7 healthcheck stays fail-open when the status is unknown (got $RC)"
grep -qF 'hardened=unknown' <<<"$OUT" && ok || bad "A7 an unrunnable harden-state must print unknown (got: $OUT)"
[ "$(alerts 'HARDEN: hardened=unknown')" = 1 ] && ok || bad "A7 unknown must write exactly one ALERTS line"
[ "$(beats)" = 2 ] && ok || bad "A7 unknown must beat (beats=$(beats))"

# A line that is not a count at all — a truncated read, a future flag, a stray
# banner. "Not a number" is not "fine".
printf '#!/bin/bash\necho hardened=abc\n' > "$HS_REAL"
OUT=$(HC); RC=$?
[ "$RC" -eq 0 ] && ok || bad "A7 healthcheck stays fail-open on a malformed figure (got $RC)"
[ "$(alerts 'HARDEN: hardened=abc')" = 1 ] && ok || bad "A7 a malformed figure must alert"
[ "$(beats)" = 3 ] && ok || bad "A7 a malformed figure must beat (beats=$(beats))"

# N>M, or a count with a non-numeric half, is malformed too.
printf '#!/bin/bash\necho hardened=9/x\n' > "$HS_REAL"
OUT=$(HC); RC=$?
[ "$(alerts 'HARDEN: hardened=9/x')" = 1 ] && ok || bad "A7 a half-numeric figure must alert"
[ "$(beats)" = 4 ] && ok || bad "A7 a half-numeric figure must beat (beats=$(beats))"

echo "harden-state-lanes-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
