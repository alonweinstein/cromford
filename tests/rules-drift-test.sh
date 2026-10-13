#!/bin/bash
# tests/rules-drift-test.sh — bin/rules-drift-check.sh must catch every way a
# box's Claude Code config can stop matching the repo, and must stay quiet when
# it matches.
#
# This is the test for the check that would have caught the original incident:
# on 2026-08-13 three boxes were building client software under a 2.5KB CLAUDE.md
# while hub carried 12.4KB, and nothing in the fleet noticed. The 08-14 fix made
# the file repo-managed; this checker is what proves it STAYED that way. A
# checker that silently passes on a drifted box is worse than no checker, so the
# cases below all assert on the DRIFTED direction too.
#
# No ssh, no network: RULES_DRIFT_SSH points at a stub that runs the probe
# against a fake box directory tree, which is what makes remote drift testable.
# Run from anywhere: tests/rules-drift-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$DIR/bin/rules-drift-check.sh"
TMP="$T"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- a fake fleet ----------
CANON="$TMP/canon"
mkdir -p "$CANON/rules"
printf 'CANON RULES v1\niron law: never merge\n'  > "$CANON/rules/CLAUDE.md"
printf 'RTK v1\n'                                  > "$CANON/rules/RTK.md"
printf '{"hooks":1}\n'                             > "$CANON/rules/settings.json"
# fleet.conf: two live boxes and one PARKED (commented) row, which must be ignored.
cat > "$CANON/fleet.conf" <<'EOF'
# comment line
alpha-os example-org/alpha https://a / 1 box-alpha
beta-os  example-org/beta  https://b / 2 box-beta
# PARKED 2026-08-25: gamma-os example-org/gamma - - 0 box-gamma
EOF

FLEET="$TMP/fleet"
# make_box <name> — a box whose checkout and live config both match canon.
make_box() {
  local b="$FLEET/$1"
  mkdir -p "$b/.claude" "$b/harness-checkout/rules"
  cp "$CANON"/rules/* "$b/harness-checkout/rules/"
  cp "$CANON"/rules/CLAUDE.md "$b/.claude/CLAUDE.md"
  cp "$CANON"/rules/RTK.md "$b/.claude/RTK.md"
  cp "$CANON"/rules/settings.json "$b/.claude/settings.json"
}
make_box box-alpha; make_box box-beta

cat > "$TMP/fake-ssh.sh" <<'EOF'
#!/bin/bash
# stub ssh: $1=root@<box>, $2="bash -s", probe on stdin. A box with no directory
# is unreachable, which is how the unreachable path gets exercised.
BOX="${1#root@}"; ROOT="$FLEET/$BOX"
[ -d "$ROOT" ] || exit 255
HARNESS_CHECKOUT="$ROOT/harness-checkout" RULES_DRIFT_CLAUDE_DIR="$ROOT/.claude" bash -s
EOF
chmod +x "$TMP/fake-ssh.sh"

# run <label> -> stdout in $OUT, exit in $RC, ALERTS lines added by this run in $NEW
RUN=0
run() {
  RUN=$((RUN+1))
  local before=0
  [ -f "$TMP/harness/logs/ALERTS.log" ] && before=$(wc -l < "$TMP/harness/logs/ALERTS.log")
  OUT=$(FLEET="$FLEET" HARNESS="$TMP/harness" HARNESS_CHECKOUT="$CANON" \
        RULES_DRIFT_BOXES="box-alpha box-beta" RULES_DRIFT_SSH="$TMP/fake-ssh.sh" \
        "$CHECK" 2>&1); RC=$?
  NEW=$(tail -n +$((before+1)) "$TMP/harness/logs/ALERTS.log" 2>/dev/null)
}
reset_state() { scratch_rm "$TMP/harness"; }

# ---------- 1. a converged fleet is silent ----------
# The common case. If this ever alerts, the checker is noise and gets ignored,
# which is how a real alert gets missed.
reset_state; run
[ "$RC" -eq 0 ] && ok || bad "converged fleet: expected exit 0, got $RC ($OUT)"
grep -q "2 converged, 0 drifted, 0 unreachable" <<<"$OUT" && ok || bad "converged fleet: bad summary: $OUT"
[ -z "$NEW" ] && ok || bad "converged fleet wrote ALERTS lines: $NEW"

# ---------- 2. render drift: someone hand-edited the box copy ----------
# The box's checkout is right, so the file it SHOULD have is right — the live
# file just isn't it. This is the "local edit gets silently reverted at 05:17Z"
# case, and the window before that revert is a box building under unrecorded rules.
reset_state
printf 'CANON RULES v1\nhand-edited on the box\n' > "$FLEET/box-alpha/.claude/CLAUDE.md"
run
[ "$RC" -eq 1 ] && ok || bad "render drift: expected exit 1, got $RC"
grep -q "box-alpha DRIFT: CLAUDE.md(render)" <<<"$OUT" && ok || bad "render drift not reported: $OUT"
grep -q "RULES DRIFT" <<<"$NEW" && grep -q "update-runners.sh on box-alpha" <<<"$NEW" \
  && ok || bad "render drift ALERTS line missing or has no fix instruction: $NEW"
grep -q "box-beta ok" <<<"$OUT" && ok || bad "render drift on alpha wrongly implicated beta: $OUT"

# ---------- 3. alert once, then report the heal ----------
# A drifted box re-alerting every 15 minutes trains the operator to ignore it.
run
[ -z "$NEW" ] && ok || bad "second run on the same drift re-alerted: $NEW"
cp "$CANON/rules/CLAUDE.md" "$FLEET/box-alpha/.claude/CLAUDE.md"
run
[ "$RC" -eq 0 ] && ok || bad "after heal: expected exit 0, got $RC"
grep -q "RESOLVED on box-alpha" "$TMP/harness/logs/rules-drift.log" && ok \
  || bad "heal was not recorded in rules-drift.log"

# ---------- 4. checkout drift is NOT render drift ----------
# The box renders faithfully from a stale checkout: live == rendered, so a
# live-vs-checkout check (which is all context-gate.sh does) passes clean while
# the box runs superseded rules. Re-rendering would not fix it; syncing would.
reset_state
printf 'CANON RULES v0 (stale)\n' > "$FLEET/box-beta/harness-checkout/rules/CLAUDE.md"
cp "$FLEET/box-beta/harness-checkout/rules/CLAUDE.md" "$FLEET/box-beta/.claude/CLAUDE.md"
run
[ "$RC" -eq 1 ] && ok || bad "checkout drift: expected exit 1, got $RC"
grep -q "box-beta DRIFT: CLAUDE.md(checkout)" <<<"$OUT" && ok || bad "checkout drift not reported: $OUT"
grep -q "CHECKOUT DRIFT" <<<"$NEW" && grep -q "harness-sync.sh on box-beta" <<<"$NEW" \
  && ok || bad "checkout drift ALERTS line missing or names the wrong fix: $NEW"
grep -q "CLAUDE.md(render)" <<<"$OUT" && bad "stale-but-faithful box was miscalled as render drift: $OUT" || ok
make_box box-beta

# ---------- 5. the box-local overlay is legitimate, not drift ----------
# CLAUDE.local.md is the sanctioned per-box escape hatch: the render appends it,
# so live != canon by design. Flagging that would make every overlay box a
# permanent false alarm and push operators back to editing the live file.
reset_state
printf 'box-specific note\n' > "$FLEET/box-alpha/.claude/CLAUDE.local.md"
{ cat "$CANON/rules/CLAUDE.md"
  printf '\n\n<!-- box-specific, from %s -->\n\n' "$FLEET/box-alpha/.claude/CLAUDE.local.md"
  cat "$FLEET/box-alpha/.claude/CLAUDE.local.md"
} > "$FLEET/box-alpha/.claude/CLAUDE.md"
run
[ "$RC" -eq 0 ] && ok || bad "overlay box was called drifted (exit $RC): $OUT"
grep -q "box-alpha ok (overlay" <<<"$OUT" && ok || bad "overlay not surfaced in the report: $OUT"

# ---------- 5b. an overlay the live file does not include IS drift ----------
# Otherwise the overlay becomes a hole: drop a CLAUDE.local.md on a box, never
# render, and the checker would call it converged.
cp "$CANON/rules/CLAUDE.md" "$FLEET/box-alpha/.claude/CLAUDE.md"
reset_state; run
[ "$RC" -eq 1 ] && grep -q "CLAUDE.md(render)" <<<"$OUT" && ok \
  || bad "an unrendered overlay was not caught: exit $RC, $OUT"
rm -f "$FLEET/box-alpha/.claude/CLAUDE.local.md"; make_box box-alpha

# ---------- 6. RTK.md and settings.json are checked too ----------
# They ride the same render and drifted the same way (the rtk rollout patched 6
# boxes by hand, 2026-08-23). A checker that only watches CLAUDE.md leaves the
# two files next to it unguarded.
for F in RTK.md settings.json; do
  reset_state
  printf 'drifted\n' > "$FLEET/box-beta/.claude/$F"
  run
  grep -q "box-beta DRIFT: $F(render)" <<<"$OUT" && ok || bad "$F drift not caught: $OUT"
  make_box box-beta
done

# ---------- 7. a missing file is drift, not a pass ----------
# An absent file is the ENOSPC failure mode (a render that never ran on a fresh
# box), and "no file" must never compare equal to "the right file".
reset_state
rm -f "$FLEET/box-alpha/.claude/RTK.md"
run
[ "$RC" -eq 1 ] && grep -q "box-alpha DRIFT: RTK.md(render)" <<<"$OUT" && ok \
  || bad "a missing RTK.md passed as converged: exit $RC, $OUT"
make_box box-alpha

# ---------- 8. an unreachable box is reported, never assumed fine ----------
reset_state
OUT=$(FLEET="$FLEET" HARNESS="$TMP/harness" HARNESS_CHECKOUT="$CANON" \
      RULES_DRIFT_BOXES="box-alpha box-ghost" RULES_DRIFT_SSH="$TMP/fake-ssh.sh" \
      "$CHECK" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "unreachable box: expected exit 2, got $RC"
grep -q "box-ghost UNREACHABLE" <<<"$OUT" && ok || bad "unreachable box not reported: $OUT"
grep -q "unverified" "$TMP/harness/logs/ALERTS.log" && ok || bad "unreachable box wrote no ALERTS line"

# ---------- 9. drift outranks unreachability in the exit code ----------
# Both matter, but a confirmed drifted box is the actionable one; exit 2 would
# read as "just a network blip" to a caller that only checks for 1.
reset_state
printf 'hand-edited\n' > "$FLEET/box-alpha/.claude/CLAUDE.md"
OUT=$(FLEET="$FLEET" HARNESS="$TMP/harness" HARNESS_CHECKOUT="$CANON" \
      RULES_DRIFT_BOXES="box-alpha box-ghost" RULES_DRIFT_SSH="$TMP/fake-ssh.sh" \
      "$CHECK" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "drift+unreachable: expected exit 1 (drift wins), got $RC"
make_box box-alpha

# ---------- 10. the default box list comes from fleet.conf, parked rows excluded ----------
# A PARKED row is a stopped machine: probing it would alert forever, and the
# operator would learn to ignore this check.
reset_state
OUT=$(FLEET="$FLEET" HARNESS="$TMP/harness" HARNESS_CHECKOUT="$CANON" \
      RULES_DRIFT_SSH="$TMP/fake-ssh.sh" RULES_DRIFT_CLAUDE_DIR="$FLEET/box-alpha/.claude" \
      "$CHECK" 2>&1) || true
grep -q "box-alpha ok" <<<"$OUT" && grep -q "box-beta ok" <<<"$OUT" && ok \
  || bad "fleet.conf boxes were not probed by default: $OUT"
grep -q "box-gamma" <<<"$OUT" && bad "a PARKED fleet.conf row was probed: $OUT" || ok
grep -q "local" <<<"$OUT" && ok || bad "the hub itself was not checked: $OUT"

# ---------- 11. it never writes to a box ----------
# Read-only is the whole safety story: this runs on a schedule against every
# production box, and healing belongs to update-runners/context-gate.
grep -q . <<<"$(grep -nE '(^|[^-])(ssh|scp|rsync)[^"]*(cp|mv|>|tee)' "$CHECK" | grep -v '^[0-9]*:#')" \
  && bad "the checker appears to write to a remote box" || ok
# The healer scripts may only appear inside the note "..." alert text (as the fix
# a human should run), never as a command this script executes.
HEALER_EXEC=$(grep -nE 'harness-sync\.sh|update-runners\.sh' "$CHECK" \
  | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '^[0-9]+:[[:space:]]*note ' || true)
[ -z "$HEALER_EXEC" ] && ok || bad "the checker invokes a healer instead of only naming it:
$HEALER_EXEC"

echo "rules-drift-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
