#!/bin/bash
# tests/harness-sync-stamps-test.sh — bin/harness-sync.sh records WHEN it last
# deployed and WHEN it last refused, run whole against a scratch tree.
#
# WHY (BH-628). harness-sync's refusal on a dirty checkout was an append-only
# ALERTS line and nothing else. The hub refused every deploy for 16 hours, the
# drift check stayed green (it compares the CHECKOUT's HEAD to origin, and the
# ff-only pull keeps that current), and the only signal was one repeated line
# that alert-triage's deferral spool swallowed. "The hub has not synced in N
# hours" needs two facts nobody was writing down: when the last deploy
# succeeded, and whether the last attempt was refused. This is the writer side;
# tests/pipeline-health-hub-sync-test.sh is the detector that reads them.
#
# THE NEGATIVES CARRY THE WEIGHT: `--check` runs before every build on every box
# in the fleet, so a --check that stamped anything would make every box look
# like a refusing hub. And a transient rc 20 (lock busy, fetch failed) is not a
# refusal: stamping it would page for a busy lock followed by a quiet main.
#
# Run from anywhere: tests/harness-sync-stamps-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null && command -v flock >/dev/null \
  && command -v rsync >/dev/null || { echo "jq/git/flock/rsync missing — skipping"; exit 0; }

SUC="$T/state/harness-sync-last-success"
REF="$T/state/harness-sync-last-refused"

# ── a real bare origin and a real clone ──────────────────────────────────────
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() { # sync [--check] -> rc in $RC
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
shaof() { [ -f "$1" ] && sha256sum < "$1" | cut -d' ' -f1 || echo MISSING; }

# ── S0. SAFETY PROBE, and it runs before anything else ──────────────────────
# bin/harness-sync.sh's deploy path rsyncs $CHECKOUT/{bin,prompts,fly,catalog}
# and copies fleet.conf into $HARNESS. If it does not honour $HARNESS, every
# deploy below writes a scratch tree straight over the REAL /root/harness and
# replaces the live fleet.conf with this fixture's one-line file. That is not a
# hypothetical: it is what happened while this suite was being written.
#
# The probe is behavioural, not a grep: a DIRTY checkout refuses at rc 30 and
# writes its REFUSED line to $HARNESS/logs/ALERTS.log BEFORE reaching any rsync.
# If that line is not in the scratch tree, $HARNESS was ignored and we abort
# without ever running a deploy that could land.
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$T/logs/ALERTS.log" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC, nothing in $T/logs/ALERTS.log) —"
  echo "      refusing to run the deploy path, which would rsync this fixture over the live /root/harness."
  echo "harness-sync-stamps-test: 0 passed, 1 failed"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
: > "$T/logs/ALERTS.log"; rm -f "$REF"

# ============================================================================
# S1. a clean checkout deploys, and says when
# ============================================================================
sync
[ "$RC" = 0 ] && ok || bad "a clean deploy must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ -s "$SUC" ] && ok || bad "a successful deploy must write state/harness-sync-last-success"
date -u -d "$(head -1 "$SUC" 2>/dev/null)" +%s >/dev/null 2>&1 \
  && ok || bad "the success stamp must parse as a date: $(cat "$SUC" 2>/dev/null)"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$SUC" \
  && ok || bad "the success stamp must be explicit UTC: $(cat "$SUC")"
[ ! -f "$REF" ] && ok || bad "a clean deploy must not record a refusal"
S1_SUC=$(shaof "$SUC")

# ============================================================================
# S2. a dirty checkout refuses — and the refusal is now a FACT on disk, with
#     its reason, not just a line in a log nobody reads
# ============================================================================
echo x >> "$T/ck/bin/x.sh"
sync
[ "$RC" = 30 ] && ok || bad "a dirty bin/ must refuse with rc 30, got $RC: $(cat "$T/out.txt")"
[ -s "$REF" ] && ok || bad "a refused deploy must write state/harness-sync-last-refused"
date -u -d "$(head -1 "$REF" 2>/dev/null)" +%s >/dev/null 2>&1 \
  && ok || bad "the refused stamp's first line must parse as a date: $(head -1 "$REF" 2>/dev/null)"
grep -q 'dirty uncommitted: bin/x.sh' "$REF" \
  && ok || bad "the refused stamp must carry the reason: $(cat "$REF")"
[ "$(shaof "$SUC")" = "$S1_SUC" ] \
  && ok || bad "a refusal must not touch the success stamp"

# ============================================================================
# S3. it comes back: the success stamp moves past the refusal
# ============================================================================
git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm fix; git -C "$T/ck" push -q origin main
# Pin the stamp to something unmistakably old first: S1 and this deploy can land
# in the same second, and "the sha changed" would then be a coin flip on the
# clock rather than a statement about the code.
echo '2000-01-01T00:00:00Z' > "$SUC"
sync
[ "$RC" = 0 ] && ok || bad "a committed checkout must deploy again, got $RC: $(cat "$T/out.txt")"
[ "$(head -1 "$SUC")" != "2000-01-01T00:00:00Z" ] \
  && ok || bad "the success stamp must be rewritten by the recovery deploy"
SN=$(date -u -d "$(head -1 "$SUC")" +%s); RN=$(date -u -d "$(head -1 "$REF")" +%s)
[ "$SN" -ge "$RN" ] && ok || bad "after a recovery the success stamp must not be older than the refusal ($SN vs $RN)"
S3_SUC=$(shaof "$SUC"); S3_REF=$(shaof "$REF")

# ============================================================================
# S4. --check writes NOTHING. It runs before every build on every box; a
#     stamping --check would make the whole fleet look like a refusing hub.
# ============================================================================
echo y >> "$T/ck/bin/x.sh"
sync --check
[ "$RC" = 30 ] && ok || bad "--check on a dirty checkout must still report rc 30, got $RC: $(cat "$T/out.txt")"
[ "$(shaof "$SUC")" = "$S3_SUC" ] && ok || bad "--check must not write the success stamp"
[ "$(shaof "$REF")" = "$S3_REF" ] && ok || bad "--check must not write the refused stamp"

# ============================================================================
# S5. a transient rc 20 is not a refusal. No origin to fetch -> fetch-failed;
#     stamping that would page for a network blink on a quiet main.
# ============================================================================
git -C "$T/ck" checkout -q -- bin/x.sh
mv "$T/origin" "$T/origin.away"
sync
[ "$RC" = 20 ] && ok || bad "an unreachable origin must be UNKNOWN rc 20, got $RC: $(cat "$T/out.txt")"
[ "$(shaof "$REF")" = "$S3_REF" ] && ok || bad "a transient UNKNOWN must not be recorded as a refusal"
[ "$(shaof "$SUC")" = "$S3_SUC" ] && ok || bad "a transient UNKNOWN must not be recorded as a success"
mv "$T/origin.away" "$T/origin"

echo "harness-sync-stamps-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
