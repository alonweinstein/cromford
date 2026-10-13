#!/bin/bash
# tests/main-red-bisect-p1-confirm.bh-4318-test.sh — BH-4318: a red at P0 alone
# never files a "no culprit merge" ticket. `notmerge` needs P1 red too, and the
# ticket it files says both shas were probed red.
#
# #4318 was filed from a one-row bisect table (`9d50520 red`): verdict() took
# P0 red as notmerge without probing P1, and the ticket then claimed P0 "is
# still green" and P1 "is red". The same four suites probed green at 9d50520.
#
#   N1  P0 red, P1 green -> flake, one warn naming both shas, no act, probes
#       at GREEN then RED
#   N2  P0 red, P1 red   -> notmerge once, a two-row table handed to the act,
#       no mrb_bisect
#   N3  P0 red, P1 norun -> aborted, no act
#   N4  P0 norun         -> aborted, P1 never probed, no act
#   N5  the real mrb_act_notmerge: the issue body says P0 and P1 were probed
#       red and never says "is still green"
#
# N1-N4 drive the REAL bin/main-red-bisect.sh with the same recording fakes as
# tests/main-red-bisect.bh-3685-test.sh (MAIN_RED_BISECT_FIXTURE, sandbox only).
# N5 sources the real bin/lib/mrb-act.sh with its caller-provided functions
# (gh_rest, gh_rest_issue_list, job_ledger_*, metric_flake_quarantine_put)
# defined as recorders.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-bisect-p1-confirm.bh-4318-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null 2>&1 || { echo "main-red-bisect-p1-confirm.bh-4318-test: SKIPPED — jq missing"; exit 0; }

NOW="2026-10-04T12:00:00Z"
export GIT_AUTHOR_DATE="$NOW" GIT_COMMITTER_DATE="$NOW"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

H="$T/h"
mkdir -p "$H/bin/lib" "$H/state" "$H/flags" "$H/logs" "$H/catalog"
# The lane and every bin/lib file it sources (BH-4552): a lib it grows later
# reaches this tree without an edit here.
scratch_install_closure bin/main-red-bisect.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
LANE="$H/bin/main-red-bisect.sh"

cat > "$H/bin/jobs-client.sh" <<SH
#!/bin/bash
[ "\${BASH_SOURCE[0]}" = "\$0" ] || return 0
case "\${1:-}" in
  ledger-get)
    s=\$(awk -v k="\$2" -v y="\$3" '\$1==k && \$2==y {s=\$3} END {print s}' "$T/ledger" 2>/dev/null)
    [ -n "\$s" ] && { printf '%s' "\$s"; exit 0; }
    exit 2 ;;
  ledger-put) echo "\$2 \$3 \$4" >> "$T/ledger"; exit 0 ;;
esac
exit 0
SH
printf '#!/bin/bash\necho "$*" >> "%s/alerts"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"

cat > "$T/fakes.sh" <<SH
F="$T"
mrb_detect_episodes() { cp "\$F"/ep-src/* "\$3"/ 2>/dev/null; return 0; }
mrb_probe() {
  echo "probe \$2" >> "\$F/calls"
  cat "\$F/answers/\$2" 2>/dev/null || echo red
}
mrb_bisect() { echo "bisect \$*" >> "\$F/calls"; echo "aborted - 0"; }
mrb_episode_still_red() { echo "still_red \$1" >> "\$F/calls"; return 0; }
_fake_act() {
  local n b
  n=\$(( \$(cat "\$F/actn" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "\$F/actn"
  echo "act_\$1 \$2" >> "\$F/calls"
  cp "\$2" "\$F/acted.\$n"
  b=\$(awk -F= '\$1=="bisect" {v=substr(\$0, 8)} END {print v}' "\$2")
  [ -n "\$b" ] && [ -f "\$b" ] && cp "\$b" "\$F/acted.\$n.bisect"
  return 0
}
mrb_act_culprit()  { _fake_act culprit "\$1"; }
mrb_act_notmerge() { _fake_act notmerge "\$1"; }
SH

# ── the scratch repo: base, then 3 PR merges ────────────────────────────────
R="$T/repos/cromford"
mkdir -p "$R"
git -C "$R" init -q -b main
echo base > "$R/f"; git -C "$R" add f; git -C "$R" commit -q -m init
GREEN=$(git -C "$R" rev-parse HEAD)
for n in 101 102 103; do
  git -C "$R" checkout -q -b "ticket/bh-$n" main
  echo "$n" > "$R/f.$n"; git -C "$R" add "f.$n"; git -C "$R" commit -q -m "work on bh-$n"
  git -C "$R" checkout -q main
  git -C "$R" merge -q --no-ff "ticket/bh-$n" -m "Merge pull request #$n from example-org/ticket/bh-$n"
done
RED=$(git -C "$R" rev-parse HEAD)

SLUG=example-org/cromford
reset() { # reset <P0 answer> [P1 answer] — a fresh tick world
  rm -rf "$T/calls" "$T/alerts" "$T/ledger" "$T/actn" "$T"/acted.* "$T/answers" "$T/ep-src" \
    "$H/state/main-red-bisect" "$H/logs/main-red-bisect.log"
  mkdir -p "$T/answers" "$T/ep-src"
  echo local > "$H/state/box-name"
  echo "$1" > "$T/answers/$GREEN"
  [ -n "${2:-}" ] && echo "$2" > "$T/answers/$RED"
  printf 'source=flag\nslug=%s\nred=%s\ngreen=%s\nrun=1\nwf=Harness CI\njob=2\nsuites=tests/a.sh tests/b.sh\noutcome=\n' \
    "$SLUG" "$RED" "$GREEN" > "$T/ep-src/ep1"
}
run() {
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    MAIN_RED_BISECT_FIXTURE="$T/fakes.sh" REPOS_ROOT="$T/repos" bash "$LANE" >"$T/out" 2>&1
}
cnt() { local n; n=$(grep -cE -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }
rows() { cnt "$T/ledger" " $1\$"; }
acts() { cnt "$T/calls" '^act_'; }
warns() { cnt "$T/alerts" '^--severity warn '; }
probe_seq() { grep '^probe ' "$T/calls" 2>/dev/null | cut -d' ' -f2 | tr '\n' ' '; }

# ── N1: P0 red, P1 green — the #4318 shape ──────────────────────────────────
reset red green
run
check "N1 row flake (ledger: $(cat "$T/ledger" 2>/dev/null))" '[ "$(rows flake)" = 1 ] && [ "$(wc -l < "$T/ledger")" = 1 ]'
check "N1 no notmerge act" '[ "$(cnt "$T/calls" "^act_notmerge ")" = 0 ]'
check "N1 no culprit act" '[ "$(cnt "$T/calls" "^act_culprit ")" = 0 ]'
check "N1 exactly one warn" '[ "$(warns)" = 1 ]'
check "N1 the warn names both shas" '[ "$(cnt "$T/alerts" "$GREEN.*$RED")" = 1 ]'
check "N1 probes GREEN then RED (got: $(probe_seq))" '[ "$(probe_seq)" = "$GREEN $RED " ]'
check "N1 no bisect" '[ "$(cnt "$T/calls" "^bisect ")" = 0 ]'

# ── N2: P0 red, P1 red — a real red main never had green ────────────────────
reset red red
run
check "N2 mrb_act_notmerge once" '[ "$(cnt "$T/calls" "^act_notmerge ")" = 1 ] && [ "$(acts)" = 1 ]'
check "N2 row notmerge" '[ "$(rows notmerge)" = 1 ]'
check "N2 the act gets a two-row table, P0 then P1" \
  '[ -f "$T/acted.1.bisect" ] && [ "$(tr "\t\n" ": " < "$T/acted.1.bisect")" = "$GREEN:red $RED:red " ]'
check "N2 mrb_bisect never called" '[ "$(cnt "$T/calls" "^bisect ")" = 0 ]'

# ── N3: P0 red, P1 norun ────────────────────────────────────────────────────
reset red norun
run
check "N3 row aborted" '[ "$(rows aborted)" = 1 ]'
check "N3 no act" '[ "$(acts)" = 0 ]'
check "N3 P1 was probed" '[ "$(probe_seq)" = "$GREEN $RED " ]'

# ── N4: P0 norun ────────────────────────────────────────────────────────────
reset norun red
run
check "N4 row aborted" '[ "$(rows aborted)" = 1 ]'
check "N4 no act" '[ "$(acts)" = 0 ]'
check "N4 exactly one probe, at GREEN (got: $(probe_seq))" '[ "$(probe_seq)" = "$GREEN " ]'

# ── N5: the real mrb_act_notmerge and the body it files ─────────────────────
A="$T/act"; mkdir -p "$A/bin" "$A/catalog"
: > "$A/catalog/test-impact-always.txt"
printf '#!/bin/bash\necho "$*" >> "%s/act-alerts"\n' "$T" > "$A/bin/lane-alert.sh"
chmod +x "$A/bin/lane-alert.sh"
G40=$(printf 'a%.0s' {1..40}); R40=$(printf 'b%.0s' {1..40})
printf '%s\tred\n%s\tred\n' "$G40" "$R40" > "$T/n5.bisect"
printf 'source=flag\nslug=o/r\nred=%s\ngreen=%s\nrun=4343\nsuites=tests/a.sh\nbisect=%s\noutcome=notmerge\n' \
  "$R40" "$G40" "$T/n5.bisect" > "$T/n5.ep"
(
  job_ledger_row() { return 2; }
  job_ledger_put() { return 0; }
  metric_flake_quarantine_put() { return 0; }
  gh_rest_issue_list() { echo '[]'; }
  gh_rest() { # gh_rest POST <path> --input <file>
    [ "$1 $2" = "POST repos/o/r/issues" ] && cp "$4" "$T/n5.payload"
    GH_REST_STATUS=201; echo '{"number":7,"html_url":"https://github.com/o/r/issues/7"}'
  }
  . "$DIR/bin/lib/mrb-act.sh"
  HARNESS="$A" mrb_act_notmerge "$T/n5.ep"
) > "$T/n5.out" 2>&1
N5RC=$?
BODY=$(jq -r '.body' "$T/n5.payload" 2>/dev/null)
check "N5 rc 0 (got $N5RC)" '[ "$N5RC" = 0 ]'
check "N5 an issue was POSTed" '[ -n "$BODY" ]'
check "N5 body: P0 probed red" '[[ "$BODY" == *"P0: $G40 (last CI-green sha) probed red."* ]]'
check "N5 body: P1 probed red" '[[ "$BODY" == *"P1: $R40 (first red sha) probed red."* ]]'
check "N5 body never says is still green" '[[ "$BODY" != *"is still green"* ]]'
check "N5 body still carries the table" '[[ "$BODY" == *"$G40	red"* ]]'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
