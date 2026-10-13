#!/bin/bash
# tests/wake-cursor-key-lowercase.bh-1267-test.sh — the box name the wake loop
# sends is LOWERCASED, so a box whose name carries an uppercase letter reads,
# writes and claims on exactly the same key as every other box (BH-1267 item 1;
# re-pointed by BH-2637).
#
# TEST-CHANGE BH-2637: this file used to pin the `wake-cursor.<box>` SETTINGS
# TEST-CHANGE BH-2637: key (mirror PUT + seed GET) and state/wake-cursor. BH-2637
# TEST-CHANGE BH-2637: deleted both; the watermark is the worker's wake_cursors
# TEST-CHANGE BH-2637: row keyed by `box`, and the same `box` string is also the
# TEST-CHANGE BH-2637: claim's owner and the cooldown taker. BH-1267's invariant
# TEST-CHANGE BH-2637: is unchanged, so every case is re-pointed onto that key.
#
# WHAT WAS BROKEN (BH-1267). bin/wake-loop.sh built its key from the box name
# verbatim, and the name preserves case from BOX_NAME / state/box-name /
# hostname. The worker compares box names case-sensitively and the wake_cursors
# rows it seeded are lowercase, so a box called `box-project-3-1` would read
# NO cursor row (and rescan from the hub's watermark or from 0), claim under a
# second identity (so the claim rows would stop deduping against its own
# earlier claims), and write a second cursor row nobody else reads.
#
# So the assertions are about the KEY, at EVERY end of the same identity (D17 —
# normalise once, identically, wherever it is sent):
#   * a mixed-case box sends ONE lowercase string as the claim body `box`, the
#     cursor GET `?box=`, the cursor PUT `box` and the cooldown take `box`;
#   * that string matches a lowercase pre-seeded row, which is honoured;
#   * ownership (fleet.conf's lowercase `box` column) still resolves;
#   * stripping and lowercasing compose (`Orgo-Desktop.1`);
#   * an already-lowercase box is byte-identical (the D17 inverse case).
#
# Drives the REAL bin/wake-loop.sh, the REAL jobs-client and the REAL
# bin/box-name.sh against the stub worker in tests/lib/wake-claim-stub.sh.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-cursor-key-lowercase.bh-1267-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

H="$T/h"
# The whole point of this file: an UPPERCASE letter in the box name. JOBS_RETRIES=0
# so nothing sleeps a retry.
export HARNESS="$H" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 JOBS_RETRIES=0
export WCS_WAKES="$T/wakes.json" BOX_NAME=box-project-3-1
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE JOBS_BOX
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train apply-migrations"

# reset [owner] — a new harness tree and stub worker; project-3 is placed on
# <owner> in fleet.conf (default box-project-3-1, lowercase as fleet.conf is).
reset() {
  scratch_rm "$H"
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags" "$H/calls"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
  cp "$DIR/bin/wake-loop.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/wake-lanes.sh" "$DIR"/bin/lib/wake-class-*.sh "$H/bin/lib/"
  wcs_install "$H/bin"
  wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
  printf '%s' "${1:-box-project-3-1}" > "$H/fleet-owner"
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo) echo example-org/project-3 ;;
  project-3/box)  cat "$HARNESS/fleet-owner"; echo ;;
  project-3/board_prefix) echo /api/feature-board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
  done
  printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
  printf '#!/bin/bash\necho "[]"\n' > "$H/bin/gh"
  printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
  chmod +x "$H/bin/"*.sh "$H/bin/gh" "$H/bin/setsid"
  for c in push deploy; do touch "$H/flags/wake-lanes-$c"; done
  wakes
}
export PATH="$H/bin:$PATH"

wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <kind> <key>
  printf '{"id":%s,"repo":"example-org/project-3","kind":"%s","key":"%s","event":"ev","at":"2026-09-12T11:39:04Z"}' \
    "$1" "$2" "$3"
}
# Quiesce rather than sleep: the loop launches lanes detached.
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    cur=$(cat "$H/calls/"* 2>/dev/null | wc -c | tr -d " ")
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
run() { BOX_NAME="${1:-$BOX_NAME}" "$H/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
REQ() { wcs_log; }
LOG() { cat "$H/logs/wake-loop.log" 2>/dev/null; }
calls() { if [ -f "$H/calls/$1" ]; then wc -l < "$H/calls/$1" | tr -d " "; else echo 0; fi; }
body_of() { # body_of <METHOD> <path> — the JSON body of the first such request
  REQ | awk -v m="$1" -v p="$2" '$1==m && $2==p { $1=""; $2=""; sub(/^  /, ""); print; exit }'
}
claim_box() { jq -r .box <<<"$(body_of POST /api/wakes/claim)" 2>/dev/null; }
put_box()   { jq -r .box <<<"$(body_of PUT /api/wakes/cursor)" 2>/dev/null; }
take_box()  { jq -r .box <<<"$(body_of POST /api/wakes/cooldown/take)" 2>/dev/null; }
get_box()   { REQ | awk '$1=="GET" && $2 ~ /^\/api\/wakes\/cursor\?box=/ { sub(/.*box=/, "", $2); print $2; exit }'; }
row() { cat "$H/state/wcs/cursor.$1" 2>/dev/null; }
L=box-project-3-1

# ---------------------------------------------------------------------------
# 1. a mixed-case box sends ONE lowercase box string on every wake route
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: was "the cursor file holds 24; one mirror PUT keyed
# wake-cursor.testbox carrying 24; the ack still sent". The key is now the
# wake_cursors row's `box`, which is also the claim owner and the cooldown taker.
reset; echo 20 > "$H/state/wcs/cursor.$L"
wakes "$(W 15 deploy below)" "$(W 24 push s1)"
run
[ "$(claim_box)" = "$L" ] && ok || bad "the claim body box was not lowercased: $(body_of POST /api/wakes/claim)"
[ "$(get_box)" = "$L" ] && ok \
  || bad "the cursor GET did not carry the lowercased ?box=: $(REQ | grep '^GET /api/wakes/cursor')"
[ "$(put_box)" = "$L" ] && REQ | grep -qxF "PUT /api/wakes/cursor {\"box\":\"$L\",\"cursor\":24}" && ok \
  || bad "the cursor PUT is not the lowercased row at 24: $(REQ | grep '^PUT')"
[ "$(take_box)" = "$L" ] && ok \
  || bad "the cooldown take box was not lowercased: $(body_of POST /api/wakes/cooldown/take)"
REQ | grep -q '^POST /api/wakes/ack' && ok || bad "the ack must still be sent after the cursor PUT"
! grep -q 'box-project-3-1' <<<"$(REQ)" && ok \
  || bad "the mixed-case spelling reached the worker: $(REQ | grep 'box-project-3-1')"
[ ! -e "$H/state/wake-cursor" ] && [ ! -e "$H/state/wcs/cursor.box-project-3-1" ] && ok \
  || bad "a second identity (file or mixed-case row) was written: $(ls "$H/state" "$H/state/wcs")"

# ---------------------------------------------------------------------------
# 2. …and HONOURS the lowercase row it matches
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: was "seeds from the same settings key". The read half of
# D17 is now: the pre-seeded lowercase row IS this box's cursor — no hub seed,
# and the row below it (15) is not claimed; the row above it (24) is.
[ "$(REQ | grep -c '^GET /api/wakes/cursor')" = 1 ] && ok \
  || bad "a matched own row must be the only cursor read (no hub fallback): $(REQ | grep '^GET')"
[ -s "$H/state/wcs/claimed.$L" ] && ! grep -qx 15 "$H/state/wcs/claimed.$L" && ok \
  || bad "row 15 sits below the seeded lowercase row (20) and was claimed: $(cat "$H/state/wcs/claimed.$L")"
[ "$(calls postmerge-qa)" = 0 ] && [ "$(calls deploy-train)" = 1 ] && ok \
  || bad "the lowercase row was not honoured (postmerge-qa=$(calls postmerge-qa) deploy-train=$(calls deploy-train)): $(LOG)"
grep -q 'cursor seeded' "$H/logs/wake-loop.log" 2>/dev/null && bad "seeded over a matched own row: $(LOG)" || ok

# ---------------------------------------------------------------------------
# 3. ownership still resolves from fleet.conf's lowercase box column
# ---------------------------------------------------------------------------
# TEST-CHANGE BH-2637: new with the per-box claim — a mixed-case name that did
# not match fleet.conf would own nothing and exit before any request.
[ "$(jq -c .repos <<<"$(body_of POST /api/wakes/claim)")" = '["example-org/project-3"]' ] && ok \
  || bad "the mixed-case box did not own project-3: $(body_of POST /api/wakes/claim) / $(LOG)"
! grep -q 'owns no fleet repo' "$H/logs/wake-loop.log" 2>/dev/null && ok || bad "the mixed-case box owned nothing: $(LOG)"

# ---------------------------------------------------------------------------
# 4. stripping and lowercasing COMPOSE — `Orgo-Desktop.1`
# ---------------------------------------------------------------------------
# bin/box-name.sh drops anything outside A-Za-z0-9._- ; case is the only
# transform the loop adds, and the composed key must still be the one string.
# TEST-CHANGE BH-2637: was the settings key `wake-cursor.orgo-desktop.1`; now the
# claim, cursor and cooldown `box` are all `orgo-desktop.1`.
reset orgo-desktop.1; wakes "$(W 31 push s9)"
run 'Orgo-Desktop.1'
[ "$(claim_box)" = orgo-desktop.1 ] && [ "$(put_box)" = orgo-desktop.1 ] && [ "$(take_box)" = orgo-desktop.1 ] && ok \
  || bad "a dotted, hyphenated, mixed-case box built the wrong key: $(REQ)"

# ---------------------------------------------------------------------------
# 5. an ALREADY-lowercase box is byte-identical (D17 inverse case)
# ---------------------------------------------------------------------------
# The negative: no double normalisation, no second PUT, same key, and the same
# requests on the wire as the mixed-case run in section 1.
reset; echo 20 > "$H/state/wcs/cursor.$L"
wakes "$(W 15 deploy below)" "$(W 24 push s1)"
run box-project-3-1; MIXED=$(REQ); MIXED_CALLS="$(calls deploy-train)/$(calls postmerge-qa)"
reset; echo 20 > "$H/state/wcs/cursor.$L"
wakes "$(W 15 deploy below)" "$(W 24 push s1)"
run "$L"
[ "$(REQ | grep -c '^PUT /api/wakes/cursor')" = 1 ] && ok \
  || bad "a lowercase box now writes $(REQ | grep -c '^PUT /api/wakes/cursor') PUT(s) — behaviour changed where it must not"
[ "$(claim_box)" = "$L" ] && [ "$(get_box)" = "$L" ] && [ "$(put_box)" = "$L" ] && [ "$(take_box)" = "$L" ] && ok \
  || bad "a lowercase box's key moved: $(REQ)"
[ "$(REQ)" = "$MIXED" ] && [ "$(calls deploy-train)/$(calls postmerge-qa)" = "$MIXED_CALLS" ] && ok \
  || bad "the mixed-case and lowercase boxes sent different requests:
--- mixed ---
$MIXED
--- lower ---
$(REQ)"

echo "wake-cursor-key-lowercase-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
