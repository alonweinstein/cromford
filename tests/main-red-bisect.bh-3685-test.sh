#!/bin/bash
# tests/main-red-bisect.bh-3685-test.sh — BH-3696 (BH-3685.3): the
# main-red-bisect lane, driven through the REAL bin/main-red-bisect.sh.
#
# WHAT IS REAL. The driver, bin/lib/lane-gate.sh, bin/lib/env-path.sh,
# bin/lib/hub-box.sh and the three contract libs (bin/lib/mrb-probe.sh,
# mrb-detect.sh, mrb-act.sh) are copied into a scratch harness and sourced by
# the driver as on a box. A real scratch git repo stands in for the checkout:
# main carries twelve `git merge --no-ff` merges whose subjects are
# `Merge pull request #101..#112 from example-org/ticket/bh-<n>`.
#
# WHAT IS STUBBED. bin/jobs-client.sh is a stateful ledger (a `kind key status`
# file, rc 0 row / 2 miss, rc 1 when $T/ledger-503 exists; source-safe, since
# lane-gate.sh sources it). bin/lane-alert.sh appends its argv to $T/alerts.
# MAIN_RED_BISECT_FIXTURE=$T/fakes.sh (sandbox only) redefines the contract's
# functions as recording fakes, so the suite never depends on a sibling's body:
#   mrb_detect_episodes   copies $T/ep-src/* into the out-dir, rc $T/detect-rc
#   mrb_probe             logs `probe <sha> <suites>`, answers $T/answers/<sha>
#                         (default red)
#   mrb_bisect            probes candidates newest first up to its budget, then
#                         prints per $T/bisect-mode (found|bounded|aborted)
#   mrb_episode_still_red rc $T/stale-rc
#   mrb_act_culprit/notmerge copy the episode to $T/acted.<n>, rc $T/act-rc
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-bisect.bh-3685-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

NOW="2026-09-30T12:00:00Z"
export GIT_AUTHOR_DATE="$NOW" GIT_COMMITTER_DATE="$NOW"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

H="$T/h"
mkdir -p "$H/bin/lib" "$H/state" "$H/flags" "$H/logs"
[ -f "$DIR/bin/main-red-bisect.sh" ] || echo "FAIL: $DIR/bin/main-red-bisect.sh is missing (every case below runs anyway)"
cp "$DIR/bin/main-red-bisect.sh" "$H/bin/" 2>/dev/null
for f in lane-gate.sh env-path.sh hub-box.sh mrb-probe.sh mrb-detect.sh mrb-act.sh deployment.sh; do
  cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
mkdir -p "$H/catalog"
LANE="$H/bin/main-red-bisect.sh"

cat > "$H/bin/jobs-client.sh" <<SH
#!/bin/bash
[ "\${BASH_SOURCE[0]}" = "\$0" ] || return 0
echo "\$*" >> "$T/ledger.calls"
case "\${1:-}" in
  ledger-get)
    [ -e "$T/ledger-503" ] && exit 1
    s=\$(awk -v k="\$2" -v y="\$3" '\$1==k && \$2==y {s=\$3} END {print s}' "$T/ledger" 2>/dev/null)
    [ -n "\$s" ] && { printf '%s' "\$s"; exit 0; }
    exit 2 ;;
  ledger-put)
    [ -e "$T/ledger-503" ] && exit 1
    [ -e "$T/put-fail" ] && exit 1
    echo "\$2 \$3 \$4" >> "$T/ledger"; exit 0 ;;
esac
exit 0
SH
printf '#!/bin/bash\necho "$*" >> "%s/alerts"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"

cat > "$T/fakes.sh" <<SH
F="$T"
mrb_detect_episodes() {
  echo "detect \$*" >> "\$F/calls"
  local rc; rc=\$(cat "\$F/detect-rc" 2>/dev/null || echo 0)
  [ "\$rc" = 0 ] || return "\$rc"
  cp "\$F"/ep-src/* "\$3"/ 2>/dev/null
  return 0
}
mrb_probe() {
  echo "probe \$2 \$(tr '\n' ' ' < "\$3")" >> "\$F/calls"
  cat "\$F/answers/\$2" 2>/dev/null || echo red
}
mrb_bisect() {
  local fn="\$1" budget="\$2"; shift 2
  local c=("\$@") i=\$((\$# - 1)) n=0
  echo "bisect budget=\$budget n=\$#" >> "\$F/calls"
  while [ "\$n" -lt "\$budget" ] && [ "\$i" -ge 0 ]; do
    "\$fn" "\${c[\$i]}" >/dev/null; n=\$((n+1)); i=\$((i-1))
  done
  case "\$(cat "\$F/bisect-mode" 2>/dev/null)" in
    found)   echo "found \$(cat "\$F/bisect-found") \$n" ;;
    bounded) echo "bounded \${c[0]} \${c[\$((\$# - 1))]} \$n" ;;
    *)       echo "aborted - \$n" ;;
  esac
}
mrb_episode_still_red() {
  echo "still_red \$1" >> "\$F/calls"
  return "\$(cat "\$F/stale-rc" 2>/dev/null || echo 0)"
}
_fake_act() {
  local n b
  n=\$(( \$(cat "\$F/actn" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$F/actn"
  echo "act_\$1 \$2" >> "\$F/calls"
  cp "\$2" "\$F/acted.\$n"
  b=\$(awk -F= '\$1=="bisect" {v=substr(\$0, 8)} END {print v}' "\$2")
  [ -n "\$b" ] && [ -f "\$b" ] && cp "\$b" "\$F/acted.\$n.bisect"
  return "\$(cat "\$F/act-rc" 2>/dev/null || echo 0)"
}
mrb_act_culprit()  { _fake_act culprit "\$1"; }
mrb_act_notmerge() { _fake_act notmerge "\$1"; }
SH

# ── the scratch repo: base, then 12 PR merges ───────────────────────────────
R="$T/repos/cromford"
mkdir -p "$R"
git -C "$R" init -q -b main
echo base > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
GREEN=$(git -C "$R" rev-parse HEAD)
for n in $(seq 101 112); do
  git -C "$R" checkout -q -b "ticket/bh-$n" main
  echo "$n" > "$R/f.$n"; git -C "$R" add "f.$n"; git -C "$R" commit -q -m "work on bh-$n"
  git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff "ticket/bh-$n" -m "Merge pull request #$n from example-org/ticket/bh-$n" -m "Title for bh-$n"
  eval "M$n=$(git -C "$R" rev-parse HEAD)"
done
RED=$(git -C "$R" rev-parse HEAD)
TREE=$(git -C "$R" rev-parse 'HEAD^{tree}')
# shellcheck disable=SC2154
X102="$M102"

SLUG=example-org/cromford
write_ep() { # write_ep [outcome] [suites]
  mkdir -p "$T/ep-src"; rm -f "$T/ep-src"/*
  printf 'source=flag\nslug=%s\nred=%s\ngreen=%s\nrun=1\nwf=Harness CI\njob=2\nsuites=%s\noutcome=%s\n' \
    "$SLUG" "$RED" "$GREEN" "${2:-tests/a.sh}" "${1:-}" > "$T/ep-src/ep1"
}
reset() { # a fresh tick world: no calls, no ledger, no pending, default fakes
  rm -rf "$T/calls" "$T/alerts" "$T/ledger" "$T/ledger.calls" "$T/ledger-503" "$T/put-fail" "$T/detect-rc" \
    "$T/answers" "$T/bisect-mode" "$T/bisect-found" "$T/stale-rc" "$T/act-rc" "$T/actn" \
    "$T"/acted.* "$H/state/main-red-bisect" "$H/logs/main-red-bisect.log" "$H/flags"/*
  mkdir -p "$T/answers"
  echo local > "$H/state/box-name"
  echo green > "$T/answers/$GREEN"
  write_ep
}
run() { # run [VAR=value ...]
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    MAIN_RED_BISECT_FIXTURE="$T/fakes.sh" REPOS_ROOT="$T/repos" "$@" bash "$LANE" >"$T/out" 2>&1
}
cnt() { # cnt <file> <ERE> -> matching line count (0 for a missing file)
  local n; n=$(grep -cE -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"
}
rows() { cnt "$T/ledger" " $1\$"; }
probes() { cnt "$T/calls" '^probe '; }
acts() { cnt "$T/calls" '^act_'; }
warns() { cnt "$T/alerts" '^--severity warn '; }
pending() { ls "$H/state/main-red-bisect/pending/"*.ep 2>/dev/null | wc -l; }
epget() { awk -F= -v k="$2" '$1==k {v=substr($0, length(k)+2)} END {print v}' "$1" 2>/dev/null; }

# ── C-off: the lane-off flag ────────────────────────────────────────────────
reset; : > "$H/flags/lane-off-main-red-bisect"
run; rc=$?
check "C-off rc 0 (got $rc)" '[ "$rc" = 0 ]'
check "C-off makes no fake call" '[ ! -s "$T/calls" ]'
check "C-off makes no ledger call" '[ "$(cnt "$T/ledger.calls" "^ledger-")" = 0 ]'

# ── C-nothub ────────────────────────────────────────────────────────────────
reset; echo box-7 > "$H/state/box-name"
run; rc=$?
check "C-nothub rc 0 (got $rc)" '[ "$rc" = 0 ]'
check "C-nothub makes no call" '[ ! -s "$T/calls" ] && [ "$(cnt "$T/ledger.calls" "^ledger-")" = 0 ]'

# ── C-unsupported ───────────────────────────────────────────────────────────
reset
run MAIN_RED_BISECT_REPOS="other/repo"; rc=$?
check "C-unsupported rc 0 (got $rc)" '[ "$rc" = 0 ]'
check "C-unsupported logs the slug unsupported" '[ "$(cnt "$H/logs/main-red-bisect.log" "other/repo unsupported")" = 1 ]'
check "C-unsupported never calls detect" '[ "$(cnt "$T/calls" "^detect ")" = 0 ]'

# ── C-forge75 ───────────────────────────────────────────────────────────────
reset; echo 75 > "$T/detect-rc"
run; rc=$?
check "C-forge75 rc 0 (got $rc)" '[ "$rc" = 0 ]'
check "C-forge75 logs forge-unreachable" '[ "$(cnt "$H/logs/main-red-bisect.log" "$SLUG forge-unreachable")" = 1 ]'
check "C-forge75 makes no probe and no row" '[ "$(probes)" = 0 ] && [ ! -s "$T/ledger" ]'

# ── C-ledger503 ─────────────────────────────────────────────────────────────
reset; : > "$T/ledger-503"
run; rc=$?
check "C-ledger503 rc 0 (got $rc)" '[ "$rc" = 0 ]'
check "C-ledger503 makes no probe, no act, no row" '[ "$(probes)" = 0 ] && [ "$(acts)" = 0 ] && [ ! -s "$T/ledger" ]'
check "C-ledger503 logs ledger-unreachable" '[ "$(cnt "$H/logs/main-red-bisect.log" "ledger-unreachable")" = 1 ]'
check "C-ledger503 read the ledger before anything else" '[ "$(cnt "$T/ledger.calls" "^ledger-get main_red_bisect $SLUG@$RED@")" = 1 ]'

# ── C-nosuite ───────────────────────────────────────────────────────────────
reset; write_ep nosuite ""
run
check "C-nosuite one warn line" '[ "$(warns)" = 1 ]'
check "C-nosuite row nosuite" '[ "$(rows nosuite)" = 1 ]'
check "C-nosuite no probe" '[ "$(probes)" = 0 ]'
reset; write_ep noanchor
run
check "C-noanchor one warn line and row noanchor" '[ "$(warns)" = 1 ] && [ "$(rows noanchor)" = 1 ] && [ "$(probes)" = 0 ]'

# ── C-A4: MAX_STEPS=3, 12 candidates, bounded ───────────────────────────────
reset; echo bounded > "$T/bisect-mode"
run MAIN_RED_BISECT_MAX_STEPS=3
check "C-A4 row bounded" '[ "$(rows bounded)" = 1 ]'
check "C-A4 no act" '[ "$(acts)" = 0 ]'
check "C-A4 exactly one warn, naming the range" '[ "$(warns)" = 1 ] && [ "$(cnt "$T/alerts" "$M101\.\.$M112")" = 1 ]'
check "C-A4 at most 3 probes (got $(probes))" '[ "$(probes)" -le 3 ] && [ "$(probes)" -ge 1 ]'
check "C-A4 every probe runs only the failing list" '[ "$(cnt "$T/calls" "^probe [0-9a-f]+ tests/a\.sh \$")" = "$(probes)" ]'
check "C-A4 bisect saw 12 candidates, budget 1" '[ "$(cnt "$T/calls" "^bisect budget=1 n=12\$")" = 1 ]'

# ── C-maxmerges ─────────────────────────────────────────────────────────────
reset; echo found > "$T/bisect-mode"; echo "$X102" > "$T/bisect-found"
run MAIN_RED_BISECT_MAX_MERGES=5
check "C-maxmerges row bounded" '[ "$(rows bounded)" = 1 ]'
check "C-maxmerges never calls mrb_bisect" '[ "$(cnt "$T/calls" "^bisect ")" = 0 ]'
check "C-maxmerges one warn naming green..red and the count" '[ "$(warns)" = 1 ] && [ "$(cnt "$T/alerts" "$GREEN\.\.$RED.*12")" = 1 ]'
check "C-maxmerges no act" '[ "$(acts)" = 0 ]'

# ── C-notmerge: P0 red ──────────────────────────────────────────────────────
reset; echo red > "$T/answers/$GREEN"
run
check "C-notmerge mrb_act_notmerge once" '[ "$(cnt "$T/calls" "^act_notmerge ")" = 1 ]'
check "C-notmerge mrb_act_culprit never" '[ "$(cnt "$T/calls" "^act_culprit ")" = 0 ]'
check "C-notmerge row notmerge" '[ "$(rows notmerge)" = 1 ]'
check "C-notmerge the acted episode says outcome=notmerge" '[ "$(epget "$T/acted.1" outcome)" = notmerge ]'

# ── C-flake: P1 green ───────────────────────────────────────────────────────
reset; echo green > "$T/answers/$RED"
run
check "C-flake row flake" '[ "$(rows flake)" = 1 ]'
check "C-flake no act, one warn" '[ "$(acts)" = 0 ] && [ "$(warns)" = 1 ]'

# ── C-norun: P0 norun ───────────────────────────────────────────────────────
reset; echo norun > "$T/answers/$GREEN"
run
check "C-norun row aborted, no act" '[ "$(rows aborted)" = 1 ] && [ "$(acts)" = 0 ]'
reset; echo norun > "$T/answers/$RED"
run
check "C-norun at P1 row aborted, no act" '[ "$(rows aborted)" = 1 ] && [ "$(acts)" = 0 ]'

# ── C-found ─────────────────────────────────────────────────────────────────
reset; echo found > "$T/bisect-mode"; echo "$X102" > "$T/bisect-found"
ls -d /tmp/mrb-* 2>/dev/null | sort > "$T/tmp.before"
run; rc=$?
ls -d /tmp/mrb-* 2>/dev/null | sort > "$T/tmp.after"
check "C-found rc 0 (got $rc)" '[ "$rc" = 0 ]'
check "C-found mrb_act_culprit once" '[ "$(cnt "$T/calls" "^act_culprit ")" = 1 ] && [ "$(acts)" = 1 ]'
check "C-found culprit is merge #102" '[ "$(epget "$T/acted.1" culprit)" = "$X102" ]'
check "C-found pr=102" '[ "$(epget "$T/acted.1" pr)" = 102 ]'
check "C-found pr_branch" '[ "$(epget "$T/acted.1" pr_branch)" = ticket/bh-102 ]'
check "C-found pr_title is the merge body line" '[ "$(epget "$T/acted.1" pr_title)" = "Title for bh-102" ]'
check "C-found steps is bisect steps + 2 (got $(epget "$T/acted.1" steps))" '[ "$(epget "$T/acted.1" steps)" = 8 ]'
check "C-found outcome=culprit is the last outcome" '[ "$(epget "$T/acted.1" outcome)" = culprit ]'
check "C-found bisect table handed to the act, >=2 rows" '[ -f "$T/acted.1.bisect" ] && [ "$(wc -l < "$T/acted.1.bisect")" -ge 2 ]'
check "C-found the table opens with P0 then P1" '[ "$(head -2 "$T/acted.1.bisect" | tr "\t\n" ": ")" = "$GREEN:green $RED:red " ]'
check "C-found row culprit" '[ "$(rows culprit)" = 1 ]'
check "C-found .last says outcome=culprit" '[ "$(epget "$H/state/main-red-bisect/example-org-cromford.last" outcome)" = culprit ]'
check "C-found one log line for the slug" '[ "$(cnt "$H/logs/main-red-bisect.log" " $SLUG ")" = 1 ]'
check "C-found no pending file left" '[ "$(pending)" = 0 ]'
check "C-found no /tmp/mrb-* dir left" 'cmp -s "$T/tmp.before" "$T/tmp.after"'
check "C-found the stale check ran before the act" '[ "$(grep -nE "^(still_red|act_)" "$T/calls" | head -1 | cut -d" " -f1 | cut -d: -f2)" = still_red ]'

# ── C-twice: the same red again ─────────────────────────────────────────────
rm -f "$T/calls"
run
check "C-twice second tick makes no probe and no act" '[ "$(probes)" = 0 ] && [ "$(acts)" = 0 ]'
check "C-twice writes no second row" '[ "$(rows culprit)" = 1 ]'

# ── C-nonpr: a found sha that is not a PR merge ─────────────────────────────
for subj in "Merge branch 'x'" "Revert \"Merge pull request #7 from o/b\"" "Merge pull request #12 from o"; do
  reset; echo found > "$T/bisect-mode"
  git -C "$R" commit-tree "$TREE" -p "$M105" -m "$subj" > "$T/bisect-found"
  run
  check "C-nonpr [$subj] row aborted, no act, one warn" '[ "$(rows aborted)" = 1 ] && [ "$(acts)" = 0 ] && [ "$(warns)" = 1 ]'
done

# ── C-stale ─────────────────────────────────────────────────────────────────
reset; echo found > "$T/bisect-mode"; echo "$X102" > "$T/bisect-found"; echo 1 > "$T/stale-rc"
run
check "C-stale no act" '[ "$(acts)" = 0 ]'
check "C-stale row stale" '[ "$(rows stale)" = 1 ]'

# ── C-act64: the contract stub's rc ─────────────────────────────────────────
reset; echo found > "$T/bisect-mode"; echo "$X102" > "$T/bisect-found"; echo 64 > "$T/act-rc"
run
P1N=$(probes)
check "C-act64 tick 1 acts once" '[ "$(acts)" = 1 ]'
check "C-act64 tick 1 writes no row" '[ ! -s "$T/ledger" ]'
check "C-act64 tick 1 keeps a pending file" '[ "$(pending)" = 1 ]'
check "C-act64 tick 1 logs the act rc" '[ "$(cnt "$H/logs/main-red-bisect.log" "act-rc=64")" = 1 ]'
rm -f "$T/calls"
run
check "C-act64 tick 2 re-dispatches the act" '[ "$(acts)" = 1 ]'
check "C-act64 tick 2 makes no new probe (tick 1 made $P1N)" '[ "$(probes)" = 0 ] && [ "$P1N" -gt 0 ]'
check "C-act64 tick 2 still no row" '[ ! -s "$T/ledger" ]'
check "C-act64 tick 2 hands the same culprit" '[ "$(epget "$T/acted.2" culprit)" = "$X102" ] && [ -f "$T/acted.2.bisect" ]'
rm -f "$T/calls"; echo 0 > "$T/act-rc"
run
check "C-act64 tick 3 act rc 0 writes the row" '[ "$(rows culprit)" = 1 ] && [ "$(acts)" = 1 ] && [ "$(probes)" = 0 ]'
check "C-act64 tick 3 removes the pending file" '[ "$(pending)" = 0 ]'

# ── C-putfail: act rc 0, then the row write fails. The act must not rerun ──
reset; echo found > "$T/bisect-mode"; echo "$X102" > "$T/bisect-found"; touch "$T/put-fail"
run
check "C-putfail tick 1 acts once" '[ "$(acts)" = 1 ]'
check "C-putfail tick 1 writes no row" '[ ! -s "$T/ledger" ]'
check "C-putfail tick 1 keeps a pending file marked acted" '[ "$(pending)" = 1 ] && [ "$(epget "$(ls "$H/state/main-red-bisect/pending/"*.ep)" acted)" = 1 ]'
check "C-putfail tick 1 logs ledger-put-failed" '[ "$(cnt "$H/logs/main-red-bisect.log" "ledger-put-failed")" = 1 ]'
rm -f "$T/calls" "$T/put-fail"
run
check "C-putfail tick 2 makes no act" '[ "$(acts)" = 0 ]'
check "C-putfail tick 2 makes no probe and no still-red check" '[ "$(probes)" = 0 ] && [ "$(cnt "$T/calls" "^still_red ")" = 0 ]'
check "C-putfail tick 2 writes one culprit row" '[ "$(rows culprit)" = 1 ] && [ "$(wc -l < "$T/ledger")" = 1 ]'
check "C-putfail tick 2 removes the pending file" '[ "$(pending)" = 0 ]'
rm -f "$T/calls"
run
check "C-putfail tick 3 is seen: no act, no probe, no new row" '[ "$(acts)" = 0 ] && [ "$(probes)" = 0 ] && [ "$(wc -l < "$T/ledger")" = 1 ]'

# ── outputs: no episodes is `outcome=none` ──────────────────────────────────
reset; rm -f "$T/ep-src"/*
run
check "C-none logs episodes=0" '[ "$(cnt "$H/logs/main-red-bisect.log" "$SLUG episodes=0")" = 1 ]'
check "C-none .last outcome=none" '[ "$(epget "$H/state/main-red-bisect/example-org-cromford.last" outcome)" = none ]'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
