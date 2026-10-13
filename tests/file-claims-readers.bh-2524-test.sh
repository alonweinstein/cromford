#!/bin/bash
# tests/file-claims-readers.bh-2524-test.sh — the two overlap readers
# (bin/plan-overlap.sh, bin/overlap-schedule.sh) consult the fleet's job_claims
# rows through fclaim_list_dir (BH-2630, slice 3 of BH-2524).
#
# Two scratch boxes, A and B, each with the REAL scripts and their OWN builds/
# and state/, so neither can see the other's plan on disk. The only thing they
# share is a fake bin/lib/file-claims.sh that answers fclaim_list_dir from one store
# ($T/store/<KEY>/{files,claimed_at,status}) exactly as the BH-2627 contract
# describes — or returns 1 with nothing written while $T/store/.outage exists.
# Until BH-5002 the fake defined fc_list_dir, the name the readers also called
# and the real lib had dropped in BH-2627, so this suite stayed green while no
# box ever read job_claims. tests/claims-cross-box.bh-5002-test.sh drives the
# REAL lib for that reason.
#
# The expensive way to be wrong: a defer on two plans that do not share a file,
# or on both sides of a real overlap, or an outage read as "nobody claims". So
# the negatives (own row, prefix-only paths, disjoint lists, a later peer, a
# finished peer, outage, kill flags) are cases here, not afterthoughts.
#
# No network, no gh, no LLM, no clock reads.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

STORE="$T/store"
mkdir -p "$STORE"

# The fake lib, with the store path baked in. Same shape as the contract:
# rc 0 = answered (dir written, own key included, first row per key); rc 1 =
# outage, dir untouched.
FAKE_LIB="$T/file-claims.fake.sh"
cat > "$FAKE_LIB" <<SH
fclaim_list_dir() {
  local project="\$1" out="\$2" d k
  [ -e "$STORE/.outage" ] && return 1
  : > "\$out/.claimed_at"
  for d in "$STORE"/*/; do
    [ -d "\$d" ] || continue
    k=\$(basename "\$d")
    [ "\$(cat "\$d/status" 2>/dev/null)" = running ] || continue
    [ -e "\$out/\$k" ] && continue
    cp "\$d/files" "\$out/\$k"
    printf '%s\t%s\n' "\$k" "\$(cat "\$d/claimed_at" 2>/dev/null)" >> "\$out/.claimed_at"
  done
  return 0
}
SH

mkbox() { # mkbox <dir> <bin-root> — a scratch harness serving the scripts in <bin-root>
  local H="$1" SRC="$2"
  mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/plans" "$H/builds" \
           "$H/locks" "$H/state/claims/proj" "$H/state/preplan-candidates"
  cp "$SRC/plan-overlap.sh" "$SRC/overlap-schedule.sh" "$DIR/bin/planned-files.sh" "$H/bin/"
  cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" \
     "$DIR/bin/lib/scheduler-conf.sh" "$H/bin/lib/"
  # plan-overlap.sh sources lib/lane-switch.sh (which sources lane-gate.sh) for
  # its plan-overlap-off switch; without them it exits 1 before judging anything.
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
  cp "$FAKE_LIB" "$H/bin/lib/file-claims.sh"
  printf 'proj  example-org/proj   -  -  0 local -\n' > "$H/fleet.conf"
}
A="$T/A"; B="$T/B"
mkbox "$A" "$DIR/bin"; mkbox "$B" "$DIR/bin"

mkbuild() { # mkbuild <box> <KEY> <file>... — a live build dir on that box
  local H="$1" K="$2"; shift 2
  local D="$H/builds/proj-$K-20260927000000"
  mkdir -p "$D"
  printf '# plan for %s\n' "$K" > "$D/plan.md"
  printf '%s\n' "$@" > "$D/planned-files.txt"
  printf '{"key":"%s"}\n' "$K" > "$D/ticket-meta.json"
}
claim() { # claim <KEY> <claimed_at> <status> <file>... — one job_claims row
  local K="$1" AT="$2" ST="$3"; shift 3
  mkdir -p "$STORE/$K"
  printf '%s\n' "$@" > "$STORE/$K/files"
  printf '%s\n' "$AT" > "$STORE/$K/claimed_at"
  printf '%s\n' "$ST" > "$STORE/$K/status"
}
reset() { # reset — no builds, no store rows, no outage, no ledger, no flags
  local H
  for H in "$A" "$B"; do
    scratch_rm "$H/builds"; scratch_rm "$H/state/claims/proj"
    mkdir -p "$H/builds" "$H/state/claims/proj"
    rm -f "$H/bin/jobs-client.sh" "$H/flags/plan-overlap-off"
    cp "$FAKE_LIB" "$H/bin/lib/file-claims.sh"
  done
  scratch_rm "$STORE"; mkdir -p "$STORE"
}
# po <box> <KEY> — run plan-overlap for that box's build; sets RC, OUT, ERR
po() {
  OUT=$(HARNESS="$1" bash "$1/bin/plan-overlap.sh" proj "$1/builds/proj-$2-20260927000000" 2>"$T/err.txt")
  RC=$?; ERR=$(cat "$T/err.txt")
}
ledger() { # ledger <box> <KEY>... — a jobs-client whose claimed rows are these keys
  local H="$1"; shift
  { echo 'queue_list() {'
    local k; for k in "$@"; do printf "  printf 'proj\\\\t%s\\\\t1\\\\tclaimed\\\\tbox\\\\t0\\\\tb\\\\t-\\\\t-\\\\t-\\\\n'\n" "$k"; done
    echo '}'; } > "$H/bin/jobs-client.sh"
}

S6() { # the S6 fixture: BH-A1 on A at 00:00, BH-B1 on B at 00:05, same file
  mkbuild "$A" BH-A1 bin/shared.sh
  mkbuild "$B" BH-B1 bin/shared.sh
  claim BH-A1 2026-09-27T00:00:00Z running bin/shared.sh
  claim BH-B1 2026-09-27T00:05:00Z running bin/shared.sh
}

# ---------- 1. S6: the later claimer defers, the first proceeds -------------
reset; S6
po "$A" BH-A1
[ "$RC" = 0 ] && ok || bad "case 1: box A (first claimer) must exit 0, got rc=$RC out=$OUT"
po "$B" BH-B1
[ "$RC" = 1 ] && ok || bad "case 1: box B (later claimer) must exit 1, got rc=$RC out=$OUT"
case "$OUT" in "OVERLAP_DEFER BH-B1 vs BH-A1 files=[bin/shared.sh"*) ok ;;
  *) bad "case 1: box B stdout must start 'OVERLAP_DEFER BH-B1 vs BH-A1 files=[bin/shared.sh', got: $OUT" ;; esac

# ---------- 2. the peer's job is no longer running -> rerun proceeds --------
printf 'done\n' > "$STORE/BH-A1/status"
po "$B" BH-B1
[ "$RC" = 0 ] && ok || bad "case 2: a finished peer must not defer B, got rc=$RC out=$OUT"

# ---------- 3. disjoint plans -> both proceed -------------------------------
reset
mkbuild "$A" BH-A1 bin/x.sh; mkbuild "$B" BH-B1 bin/y.sh
claim BH-A1 2026-09-27T00:00:00Z running bin/x.sh
claim BH-B1 2026-09-27T00:05:00Z running bin/y.sh
po "$A" BH-A1; [ "$RC" = 0 ] && ok || bad "case 3: disjoint, box A must exit 0, got rc=$RC out=$OUT"
po "$B" BH-B1; [ "$RC" = 0 ] && ok || bad "case 3: disjoint, box B must exit 0, got rc=$RC out=$OUT"

# ---------- 4. equal claimed_at -> exactly one defers, by key byte order -----
reset; S6
printf '2026-09-27T00:00:00Z\n' > "$STORE/BH-B1/claimed_at"
po "$A" BH-A1; RA=$RC
po "$B" BH-B1; RB=$RC
[ "$RA" = 0 ] && [ "$RB" = 1 ] && ok \
  || bad "case 4: equal timestamps must defer exactly B (BH-A1 < BH-B1), got A rc=$RA B rc=$RB"

# ---------- 5. no own row -> a live fleet claim blocks ----------------------
reset
mkbuild "$A" BH-A1 bin/shared.sh; mkbuild "$B" BH-B1 bin/shared.sh
claim BH-A1 2026-09-27T00:05:00Z running bin/shared.sh
po "$B" BH-B1
[ "$RC" = 1 ] && ok || bad "case 5: B has no row of its own, A's claim must defer it, got rc=$RC out=$OUT"

# a peer row with no files_claimed_at is a live claim of unknown age: it blocks
reset
mkbuild "$A" BH-A1 bin/shared.sh; mkbuild "$B" BH-B1 bin/shared.sh
claim BH-A1 "" running bin/shared.sh
claim BH-B1 2026-09-27T00:05:00Z running bin/shared.sh
po "$B" BH-B1
[ "$RC" = 1 ] && ok || bad "case 5: an unstamped peer claim must defer B, got rc=$RC out=$OUT"

# ---------- 6. own key only -> never defers on itself -----------------------
reset
mkbuild "$B" BH-B1 bin/shared.sh
claim BH-B1 2026-09-27T00:05:00Z running bin/shared.sh
po "$B" BH-B1
[ "$RC" = 0 ] && ok || bad "case 6: B's own row must never defer B, got rc=$RC out=$OUT"

# ---------- 7. prefix-only paths are not an overlap -------------------------
reset
mkbuild "$A" BH-A1 bin/a; mkbuild "$B" BH-B1 bin/ab
claim BH-A1 2026-09-27T00:00:00Z running bin/a
claim BH-B1 2026-09-27T00:05:00Z running bin/ab
po "$B" BH-B1
[ "$RC" = 0 ] && ok || bad "case 7: bin/a vs bin/ab must not defer, got rc=$RC out=$OUT"

# ---------- 8. outage == the file-only answer, byte for byte ----------------
reset; S6; touch "$STORE/.outage"
po "$B" BH-B1; O_RC=$RC; O_OUT=$OUT
rm -f "$B/bin/lib/file-claims.sh"
po "$B" BH-B1; N_RC=$RC; N_OUT=$OUT
[ "$O_RC" = 0 ] && [ "$O_RC" = "$N_RC" ] && [ "$O_OUT" = "$N_OUT" ] && ok \
  || bad "case 8: outage must equal no-lib (rc 0), got outage rc=$O_RC '$O_OUT' vs no-lib rc=$N_RC '$N_OUT'"
# a LOCAL claim still defers, with the lib under outage and without it
printf 'bin/shared.sh\n' > "$B/state/claims/proj/BH-L1"
po "$B" BH-B1; N_RC=$RC; N_OUT=$OUT
cp "$FAKE_LIB" "$B/bin/lib/file-claims.sh"
po "$B" BH-B1; O_RC=$RC; O_OUT=$OUT
[ "$O_RC" = 1 ] && [ "$N_RC" = 1 ] && [ "$O_OUT" = "$N_OUT" ] \
  && case "$O_OUT" in "OVERLAP_DEFER BH-B1 vs BH-L1 "*) true ;; *) false ;; esac && ok \
  || bad "case 8: a local claim must defer on BH-L1 either way, got outage rc=$O_RC '$O_OUT' vs no-lib rc=$N_RC '$N_OUT'"

# ---------- 9. an outage is not "no claims": UNJUDGED still fires -----------
reset
mkbuild "$B" BH-B1 bin/y.sh
claim BH-A1 2026-09-27T00:00:00Z running bin/x.sh
claim BH-B1 2026-09-27T00:05:00Z running bin/y.sh
ledger "$B" BH-A1
touch "$STORE/.outage"
po "$B" BH-B1
[ "$RC" = 0 ] && ok || bad "case 9: outage with disjoint data must exit 0, got rc=$RC"
case "$ERR" in *"OVERLAP_UNJUDGED BH-B1: BH-A1"*) ok ;;
  *) bad "case 9: outage must still report BH-A1 unjudged, stderr: $ERR" ;; esac
rm -f "$STORE/.outage"
po "$B" BH-B1
[ "$RC" = 0 ] && ok || bad "case 9: store answering, disjoint, must exit 0, got rc=$RC out=$OUT"
case "$ERR" in *OVERLAP_UNJUDGED*) bad "case 9: a key the store answered is not unjudged, stderr: $ERR" ;; *) ok ;; esac

# ---------- 10. kill flags exit 0 before any of it --------------------------
reset; S6
OUT=$(OVERLAP_SCHED=0 HARNESS="$B" bash "$B/bin/plan-overlap.sh" proj "$B/builds/proj-BH-B1-20260927000000" 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "case 10: OVERLAP_SCHED=0 must exit 0, got rc=$RC out=$OUT"
touch "$B/flags/plan-overlap-off"
po "$B" BH-B1
[ "$RC" = 0 ] && ok || bad "case 10: flags/plan-overlap-off must exit 0, got rc=$RC out=$OUT"

# ---------- 11. S8: overlap-schedule HOLDs on another box's running build ----
os() { # os <box> — run overlap-schedule full mode; sets RC, OUT, ERR
  OUT=$(HARNESS="$1" bash "$1/bin/overlap-schedule.sh" proj 2>"$T/err.txt"); RC=$?; ERR=$(cat "$T/err.txt")
}
S8() {
  printf 'BH-B2\t2\tahead\n' > "$B/state/preplan-candidates/proj.tsv"
  mkdir -p "$B/plans/proj-BH-B2"; printf 'bin/shared.sh\n' > "$B/plans/proj-BH-B2/planned-files.txt"
  claim BH-A1 2026-09-27T00:00:00Z running bin/shared.sh
}
reset; S8
os "$B"
case "$OUT" in *"HELD: BH-B2 overlaps in-flight BH-A1"*) ok ;;
  *) bad "case 11: a fleet claim on bin/shared.sh must HOLD BH-B2, got: $OUT" ;; esac
# no tie-break: B2 is held even when its own (hypothetical) claim would be older
claim BH-B2 2026-09-26T00:00:00Z done bin/shared.sh
os "$B"
case "$OUT" in *"HELD: BH-B2 overlaps in-flight BH-A1"*) ok ;;
  *) bad "case 11: overlap-schedule has no tie-break, BH-B2 must still be HELD, got: $OUT" ;; esac
touch "$STORE/.outage"
os "$B"; O_OUT=$OUT
rm -f "$B/bin/lib/file-claims.sh"
os "$B"; N_OUT=$OUT
[ "$O_OUT" = "$N_OUT" ] && ok || bad "case 11: outage output must equal no-lib output: '$O_OUT' vs '$N_OUT'"
case "$O_OUT" in *HELD*) bad "case 11: outage must not HOLD anything, got: $O_OUT" ;; *) ok ;; esac

# ---------- 12. S8 unjudged: a key the store answered is INFLIGHT -----------
reset; S8; ledger "$B" BH-A1
os "$B"
case "$ERR" in *"OVERLAP_UNJUDGED BH-A1"*) bad "case 12: store answered BH-A1, it must not be unjudged: $ERR" ;; *) ok ;; esac
touch "$STORE/.outage"
os "$B"
case "$ERR" in *"OVERLAP_UNJUDGED BH-A1"*) ok ;;
  *) bad "case 12: outage must leave BH-A1 unjudged, stderr: $ERR" ;; esac

# ---------- 13. mutation checks on copies of the real scripts ---------------
# Each mutant must CHANGE the copy (an anchor that no longer matches FAILS the
# case, it never passes it) and must turn a case above red.
mutant() { # mutant <name> <file> <sed-expr> — $T/mut-<name>/ holding the mutated scripts
  local M="$T/mut-$1"
  mkdir -p "$M"; cp "$DIR/bin/plan-overlap.sh" "$DIR/bin/overlap-schedule.sh" "$M/"
  sed -i "$3" "$M/$2"
  if cmp -s "$M/$2" "$DIR/bin/$2"; then bad "mutation $1: sed anchor did not match $2"; return 1; fi
  scratch_rm "$T/A"; scratch_rm "$T/B"; mkbox "$A" "$M"; mkbox "$B" "$M"
}
restore() { scratch_rm "$T/A"; scratch_rm "$T/B"; mkbox "$A" "$DIR/bin"; mkbox "$B" "$DIR/bin"; }

# 13a. the tie-break always says "blocks" -> the first claimer defers too
if mutant 13a plan-overlap.sh 's/fleet_claim_first "\$OK" || continue/:/'; then
  reset; S6; po "$A" BH-A1
  [ "$RC" = 1 ] && ok || bad "mutation 13a: without the tie-break box A must defer (red), got rc=$RC"
fi
# 13b. source 4 switched off -> the later claimer proceeds
if mutant 13b plan-overlap.sh 's/^if command -v fclaim_list_dir >\/dev\/null 2>&1 \&\& fclaim_list_dir/if false \&\& fclaim_list_dir/'; then
  reset; S6; po "$B" BH-B1
  [ "$RC" = 0 ] && ok || bad "mutation 13b: without source 4 box B must proceed (red), got rc=$RC"
fi
# 13c. overlap-schedule source 2b switched off -> no HELD
if mutant 13c overlap-schedule.sh 's/^if command -v fclaim_list_dir >\/dev\/null 2>&1 \&\& fclaim_list_dir/if false \&\& fclaim_list_dir/'; then
  reset; S8; os "$B"
  case "$OUT" in *HELD*) bad "mutation 13c: without source 2b there must be no HELD (red), got: $OUT" ;; *) ok ;; esac
fi
restore

echo "file-claims-readers.bh-2524: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
