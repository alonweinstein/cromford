#!/bin/bash
# tests/reconcile-prs-hooks.bh-1607-test.sh — the BH-1595 contract's shell half
# (BH-1607): the owner heartbeat hook and the once-per-tick memory flush that
# bin/reconcile-prs.sh calls, before either has a body.
#
# What is proved:
#   A5. rcr_owner_beat (bin/lib/reconcile-owner-beat.sh) is rc 0 and silent;
#   A6. rcr_memory_hydrate / rcr_memory_flush (bin/lib/reconcile-read.sh) are
#       rc 0 and silent with no tick dir, and rcr_tick_begin calls hydrate
#       (BH-1610 filled the bodies in and wired it);
#   A7. the call sites sit where the contract puts them: the beat lib sourced
#       with a fallback, the jobs client sourced after the flock and before the
#       beat, the flush in the EXIT trap and after rcr_tick_summary;
#   A8. driven: a non-owner box never beats;
#   A9. driven: the owner beats once and flushes ONCE per tick although the
#       summary and the EXIT trap both ask, also on an early-exit tick; with the
#       beat lib missing the tick still runs and prints no "command not found".
# Run from anywhere: tests/reconcile-prs-hooks.bh-1607-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ── A5: the beat stub ───────────────────────────────────────────────────────
OUT=$(bash -c '. "$1" && rcr_owner_beat' _ "$DIR/bin/lib/reconcile-owner-beat.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A5 rcr_owner_beat must be rc 0 and silent, got rc=$RC out='$OUT'"

# ── A6: the memory hooks, silent with no tick, and hydrate wired in ────────
OUT=$(HARNESS="$T/a6" bash -c '. "$1" && rcr_memory_hydrate && rcr_memory_flush' _ "$DIR/bin/lib/reconcile-read.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A6a rcr_memory_hydrate/flush must be rc 0 and silent, got rc=$RC out='$OUT'"
BEGIN_BODY=$(bash -c '. "$1" && declare -f rcr_tick_begin' _ "$DIR/bin/lib/reconcile-read.sh" 2>/dev/null)
[ -n "$BEGIN_BODY" ] && ok || bad "A6b rcr_tick_begin must still be defined"
grep -q rcr_memory_hydrate <<<"$BEGIN_BODY" && ok || bad "A6c rcr_tick_begin must call rcr_memory_hydrate (BH-1610 wired it)"

# ── A7: call-site order in bin/reconcile-prs.sh ─────────────────────────────
L="$DIR/bin/reconcile-prs.sh"
ln_of() { grep -nE "$1" "$L" | head -1 | cut -d: -f1; }
SRC=$(grep -E '^\. .*bin/lib/reconcile-owner-beat\.sh' "$L")
grep -q '2>/dev/null' <<<"$SRC" && grep -qF 'rcr_owner_beat() { :; }' <<<"$SRC" \
  && ok || bad "A7a the beat lib is sourced 2>/dev/null with a rcr_owner_beat() { :; } fallback: '$SRC'"
SKIP=$(ln_of '^rcr_owner_skip && exit 0'); FLK=$(ln_of '^flock -n 5 \|\| exit 0')
JC=$(ln_of '^\[ -r "\$HARNESS/bin/jobs-client\.sh" \] && \. '); BEAT=$(ln_of '^rcr_owner_beat$')
[ -n "$SKIP" ] && [ -n "$FLK" ] && [ -n "$JC" ] && [ -n "$BEAT" ] \
  && [ "$SKIP" -lt "$FLK" ] && [ "$FLK" -lt "$JC" ] && [ "$JC" -lt "$BEAT" ] \
  && ok || bad "A7b order must be owner_skip < flock < jobs-client source < beat, got $SKIP $FLK $JC $BEAT"
[ "$(grep -cE '^[^#]*\. "\$HARNESS/bin/jobs-client\.sh"' "$L")" = 1 ] \
  && ok || bad "A7c exactly one jobs-client.sh source line"
grep -qE "^trap 'rm -f \"\\\$GH_ETAG_COUNT_FILE\"; _rcr_flush_once; rcr_tick_end' EXIT$" "$L" \
  && ok || bad "A7d the EXIT trap flushes once before rcr_tick_end: $(grep -n '^trap' "$L")"
SUM=$(ln_of '^rcr_tick_summary$')
[ -n "$SUM" ] && [ "$(sed -n "$((SUM + 1))p" "$L")" = "_rcr_flush_once" ] \
  && ok || bad "A7e _rcr_flush_once runs on the line after rcr_tick_summary"

# ── A8/A9: the lane driven whole ────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$H/bin/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$H" "$DIR" || exit 1
# The stubs count their calls; the flush override is appended to the COPIED
# reconcile-read.sh, so it replaces whatever body the real one carries.
printf 'rcr_owner_beat() { echo beat >> "%s/beats"; }\n' "$T" > "$H/bin/lib/reconcile-owner-beat.sh"
printf '\nrcr_memory_flush() { echo flush >> "%s/flushes"; }\n' "$T" >> "$H/bin/lib/reconcile-read.sh"
cp "$H/bin/lib/reconcile-owner-beat.sh" "$T/beat-lib"
printf 'example-os Example/example https://example.example /api/board 2 box-a\n' > "$H/fleet.conf"
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\n' > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
# The console answers an empty unmerged list, or fails when $T/console-down exists.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
[ -e "$T/console-down" ] && exit 7
case "\${!#}" in
  *"/api/builds/unmerged") printf '{"builds":[]}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
tick() { # tick [owner] — one pass; the box is fixture-hub (the hub)
  rm -f "$T/beats" "$T/flushes"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      RECONCILE_PRS_OWNER="${1:-hub}" bash "$H/bin/reconcile-prs.sh" >"$T/tick.out" 2>"$T/tick.err" ); TRC=$?
}
count() { grep -c . "$1" 2>/dev/null || echo 0; }

tick other-box
[ ! -e "$T/beats" ] && ok || bad "A8a a non-owner box never beats: $(count "$T/beats") beat(s)"
[ ! -e "$T/flushes" ] && ok || bad "A8b ...and never flushes: $(count "$T/flushes")"

tick
[ "$TRC" = 0 ] && ok || bad "A9a an owner tick exits 0, got $TRC: $(cat "$T/tick.err")"
[ "$(count "$T/beats")" = 1 ] && ok || bad "A9b the owner beats once per tick, got $(count "$T/beats")"
[ "$(count "$T/flushes")" = 1 ] && ok || bad "A9c the summary and the trap flush ONCE between them, got $(count "$T/flushes")"

: > "$T/console-down"; tick; rm -f "$T/console-down"
[ "$(count "$T/flushes")" = 1 ] && ok || bad "A9d a tick that exits early (console down) still flushes once, from the trap: $(count "$T/flushes")"

rm -f "$H/bin/lib/reconcile-owner-beat.sh"; tick
[ "$TRC" = 0 ] && ok || bad "A9e with the beat lib missing the tick still exits 0, got $TRC"
grep -q 'command not found' "$T/tick.err" "$H/logs/reconcile.log" 2>/dev/null \
  && bad "A9f ...and prints no 'command not found': $(cat "$T/tick.err")" || ok
[ "$(count "$T/flushes")" = 1 ] && ok || bad "A9g ...and the tick still ran to its flush: $(count "$T/flushes")"
cp "$T/beat-lib" "$H/bin/lib/reconcile-owner-beat.sh"

echo "reconcile-prs-hooks: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
