#!/bin/bash
# tests/context-gate-self-heal-test.sh — bin drift must HEAL from the checkout
# and let the build run, but only from a checkout that is safe to copy from.
#
# The case (2026-09-15 12:27Z): a lane hot-patched bin/queue-line-drop.sh on the
# hub and all 8 boxes without committing it. context-gate then refused every
# box-side build fleet-wide for 77 minutes — four unrelated refusal lines in four
# project logs, no incident, and a fleet that had simply stopped. Rules had
# self-healed from the checkout since August; bin was the half that did not.
#
# What this pins:
#   * a drifted bin file is restored from the checkout, by temp+mv, and the
#     build PROCEEDS (exit 0) with one "BIN SELF-HEAL <f> <old8> -> <new8>" line
#     and exactly ONE alert;
#   * healing is refused — and the old refusal kept — whenever the checkout is
#     not a clean origin/main, because that checkout is what we would copy FROM;
#   * flags/bin-self-heal-off puts it back the way it was.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"; CK="$T/ck"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$T/build" "$CK/bin"

cp "$DIR/bin/context-gate.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H/bin/"

# --- the checkout: a real git repo at origin/main, no network ---------------
git init -q -b main "$CK"
printf '#!/bin/bash\necho canonical\n' > "$CK/bin/queue-line-drop.sh"
printf '#!/bin/bash\necho also-canonical\n' > "$CK/bin/free-slots.sh"
chmod +x "$CK/bin"/*.sh
git -C "$CK" add -A
git -C "$CK" -c user.email=t@t -c user.name=t commit -qm init
git -C "$CK" update-ref refs/remotes/origin/main HEAD

# --- shims -----------------------------------------------------------------
# The checkout is fresh: this gate's step 0 is not what is under test.
printf '#!/bin/bash\necho "fresh %s"\nexit 0\n' "$(git -C "$CK" rev-parse --short HEAD)" > "$H/bin/harness-sync.sh"
# Stand-in for bin/context-signature.sh doing the same maxdepth-1 cmp the real
# one does, over the fixture's own trees (the real one reads /root/harness).
cat > "$H/bin/context-signature.sh" <<'SIG'
#!/bin/bash
CK="${HARNESS_CHECKOUT:?}"; HH="${HARNESS:?}"
S=true
while IFS= read -r f; do
  [ -n "$f" ] || continue
  cmp -s "$CK/bin/$f" "$HH/bin/$f" || { S=false; break; }
done < <(cd "$CK/bin" && find . -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
printf '{ "harness_bin_in_sync": %s, "machine_rules_in_sync": true }\n' "$S"
SIG
printf '#!/bin/bash\nshift\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin"/*.sh

live() { cat "$H/bin/queue-line-drop.sh" 2>/dev/null; }
drift() { printf '#!/bin/bash\necho HOT-PATCHED\n' > "$H/bin/queue-line-drop.sh"; chmod +x "$H/bin/queue-line-drop.sh"; }
sync_live() { cp -p "$CK/bin"/*.sh "$H/bin/"; }
reset_logs() { : > "$T/alerts.txt"; : > "$H/logs/ALERTS.log"; : > "$H/logs/agent-rules.log"; }
gate() { ( HARNESS="$H" HARNESS_CHECKOUT="$CK" bash "$H/bin/context-gate.sh" demo-os "$T/build" "$T/repo" ); }
alerts() { cat "$T/alerts.txt" 2>/dev/null; }
nalerts() { grep -c . "$T/alerts.txt" 2>/dev/null || true; }

# ── 1. clean bin: accepted, nothing healed, nothing said ───────────────────
sync_live; reset_logs
OUT=$(gate); RC=$?
[ "$RC" -eq 0 ] && grep -q 'context accepted' <<<"$OUT" && ok || bad "a clean box must be accepted (rc=$RC out=$OUT)"
[ "$(nalerts)" = 0 ] && ok || bad "a clean box must not alert (got: $(alerts))"

# ── 2. drifted bin, clean checkout at origin/main: HEALED, build proceeds ──
sync_live; reset_logs; drift
OLD=$(sha256sum "$H/bin/queue-line-drop.sh" | cut -c1-8)
NEW=$(sha256sum "$CK/bin/queue-line-drop.sh" | cut -c1-8)
OUT=$(gate); RC=$?
[ "$RC" -eq 0 ] && ok || bad "bin drift with a clean checkout must HEAL and proceed, not refuse (rc=$RC out=$OUT)"
[ "$(live)" = "$(cat "$CK/bin/queue-line-drop.sh")" ] && ok || bad "the checkout copy must be restored over the hot-patch (live: $(live))"
grep -qF "BIN SELF-HEAL queue-line-drop.sh $OLD -> $NEW" "$H/logs/agent-rules.log" \
  && ok || bad "the heal must log 'BIN SELF-HEAL <file> <old sha8> -> <new sha8>' (got: $(cat "$H/logs/agent-rules.log"))"
# ONE alert, not one per file and not none: a box running bin no commit records
# is exactly the thing 2026-09-15 had no incident for.
[ "$(nalerts)" = 1 ] && ok || bad "the heal must write exactly ONE alert (got $(nalerts): $(alerts))"
grep -qi 'BIN SELF-HEAL' <<<"$(alerts)" && ok || bad "the alert must name the heal (got: $(alerts))"
grep -q 'BUILD REFUSED' "$H/logs/ALERTS.log" && bad "a healed box must not also write a refusal" || ok
# temp+mv, never in place: no scratch file survives, and the mode is preserved.
[ -z "$(ls "$H/bin"/.ctxheal-* 2>/dev/null)" ] && ok || bad "the heal left a temp file behind"
[ -x "$H/bin/queue-line-drop.sh" ] && ok || bad "the restored file must stay executable"
# What was overwritten was, by definition, code no commit records — on
# 2026-09-15 it was somebody's hot patch. A heal that destroys it silently is a
# worse trade than the refusal it replaces.
grep -qr 'HOT-PATCHED' "$H/state/bin-selfheal/" 2>/dev/null \
  && ok || bad "the displaced live copy must be kept under state/bin-selfheal/"

# ── 3. a file the box LOST is restored too ────────────────────────────────
sync_live; reset_logs; rm -f "$H/bin/free-slots.sh"
OUT=$(gate); RC=$?
[ "$RC" -eq 0 ] && [ -f "$H/bin/free-slots.sh" ] && ok || bad "a missing bin file must be restored, not refused (rc=$RC out=$OUT)"
grep -qE 'BIN SELF-HEAL free-slots\.sh - -> [0-9a-f]{8}' "$H/logs/agent-rules.log" \
  && ok || bad "an absent live file logs '-' as its old sha (got: $(cat "$H/logs/agent-rules.log"))"

# ── 4. dirty checkout: REFUSE, and never copy from it ─────────────────────
# The checkout is the source we would copy FROM. Someone mid-edit in it means
# healing would push a half-finished file onto every lane on the box.
sync_live; reset_logs; drift
echo "half-written" > "$CK/bin/free-slots.sh"
OUT=$(gate); RC=$?
[ "$RC" -eq 1 ] && ok || bad "a dirty checkout must keep refusing (rc=$RC out=$OUT)"
grep -q 'HOT-PATCHED' <<<"$(live)" && ok || bad "nothing may be copied from a dirty checkout"
grep -q 'BUILD REFUSED' "$H/logs/ALERTS.log" && ok || bad "the refusal must still reach ALERTS.log"
grep -qi 'uncommitted work in the checkout' "$H/logs/ALERTS.log" \
  && ok || bad "the refusal must say WHY the heal was skipped (got: $(cat "$H/logs/ALERTS.log"))"
git -C "$CK" checkout -q -- bin/free-slots.sh

# ── 5. untracked file in the checkout counts as dirty ─────────────────────
sync_live; reset_logs; drift
: > "$CK/bin/scratch-note.txt"
OUT=$(gate); RC=$?
[ "$RC" -eq 1 ] && grep -q 'HOT-PATCHED' <<<"$(live)" \
  && ok || bad "an untracked file in the checkout must count as dirty (rc=$RC out=$OUT)"
rm -f "$CK/bin/scratch-note.txt"

# ── 6. checkout ahead of / behind origin/main: REFUSE ─────────────────────
# CI runners have no git identity, so commit-tree without -c user.* used to
# fail, 2>/dev/null swallowed it, origin/main never moved, and the gate
# correctly healed. Pin identity the same way the fixture's init commit does.
sync_live; reset_logs; drift
OTHER=$(git -C "$CK" -c user.email=t@t -c user.name=t \
  commit-tree "$(git -C "$CK" rev-parse 'HEAD^{tree}')" -m other)
git -C "$CK" update-ref refs/remotes/origin/main "$OTHER"
OUT=$(gate); RC=$?
[ "$RC" -eq 1 ] && grep -q 'HOT-PATCHED' <<<"$(live)" \
  && ok || bad "a checkout that is not AT origin/main must keep refusing (rc=$RC out=$OUT)"
grep -qi 'not origin/main' "$H/logs/ALERTS.log" \
  && ok || bad "the refusal must name the origin/main mismatch (got: $(cat "$H/logs/ALERTS.log"))"
git -C "$CK" update-ref refs/remotes/origin/main HEAD

# ── 7. kill flag puts the old refusal back ────────────────────────────────
sync_live; reset_logs; drift
touch "$H/flags/bin-self-heal-off"
OUT=$(gate); RC=$?
[ "$RC" -eq 1 ] && grep -q 'HOT-PATCHED' <<<"$(live)" \
  && ok || bad "flags/bin-self-heal-off must restore the refusal (rc=$RC out=$OUT)"
grep -qi 'bin-self-heal-off' "$H/logs/ALERTS.log" && ok || bad "the refusal must name the flag that disabled healing"
rm -f "$H/flags/bin-self-heal-off"

echo "context-gate-self-heal-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
