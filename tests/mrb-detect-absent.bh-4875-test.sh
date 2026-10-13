#!/bin/bash
# tests/mrb-detect-absent.bh-4875-test.sh — BH-4875: a merge-queue batch red
# on a suite that is not in main's tree at the merge-base is the batch's own
# suite. mrb_detect_episodes drops it from the episode, with one log line, and
# writes no file when no red suite is left. #4875 was filed because
# tests/cromford-docs-site.bh-4084-test.sh, added by a PR inside batch
# 37489866946, was probed on main where it does not exist; bash exited 127,
# mrb_probe scored that red at both P0 and P1, and the verdict was notmerge.
# Driven through the real bin/lib/mrb-detect.sh, the real gh_rest and a real
# scratch git origin. Only `gh` and `curl` are stubs (the pattern of
# tests/mrb-detect-batch.bh-4329-test.sh, copied here, not sourced).
#
# Rows: A1-A4 the production entry point mrb_detect_episodes (A1 is the #4875
# reproduction: it must write no flag-<id>.ep), A5 _mrb_present_at on a sha
# the clone does not have, M1-M2 mutants of a copied lib (D1).
#
# No network, no clock (every commit date is pinned below).
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/mrb-detect-absent.bh-4875-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
DETECT="$DIR/bin/lib/mrb-detect.sh"
PROBE="$DIR/bin/lib/mrb-probe.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }

# ── stubs: gh (REST arm + bytes arm) and curl ─────────────────────────────────
export MRBT="$T"
mkdir -p "$T/bin" "$T/rest" "$T/bytes" "$T/h/flags"
cp "$DIR/tests/lib/rest-emit.sh" "$T/bin/restpr"; chmod +x "$T/bin/restpr"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$MRBT/gh-calls.txt"
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
[ "${1:-}" = api ] || exit 1
if [ "${2:-}" = -i ]; then           # gh api -i -X GET <path>: gh_rest
  k=$(key "${5:-}")
  if [ -f "$MRBT/st-$k" ]; then restpr --raw "$(cat "$MRBT/st-$k")" '{"message":"Server Error"}'; exit 1; fi
  if [ -f "$MRBT/rest/$k" ]; then restpr --raw 200 "$(cat "$MRBT/rest/$k")"; exit 0; fi
  restpr --raw 404 '{"message":"Not Found"}'; exit 1
fi
k=$(key "${2:-}")                    # gh api <path>: log bytes
if [ -f "$MRBT/bst-$k" ]; then echo "gh: Error (HTTP $(cat "$MRBT/bst-$k"))" >&2; exit 1; fi
if [ -f "$MRBT/bytes/$k" ]; then cat "$MRBT/bytes/$k"; exit 0; fi
echo "gh: Not Found (HTTP 404)" >&2; exit 1
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$MRBT/curl-calls.txt"\nexit 1\n' > "$T/bin/curl"
chmod +x "$T/bin/gh" "$T/bin/curl"
export PATH="$T/bin:$PATH" GH_ETAG=0 HARNESS="$T/h"
key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
rest()  { printf '%s' "$2" > "$T/rest/$(key "$1")"; }     # rest <path> <json>
bytes() { cat > "$T/bytes/$(key "$1")"; }                 # bytes <path> < data

# ── a real origin: main = C0, M1, M2 (M2 adds tests/present.sh); a batch off
#    M2 adds tests/batch-only.sh ─────────────────────────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-10-06T00:00:00Z' GIT_COMMITTER_DATE='2026-10-06T00:00:00Z'
G() { git -C "$T/w" "$@" >/dev/null 2>&1 || { echo "setup: git $* failed"; exit 1; }; }
PR=tests/present.sh
BO=tests/batch-only.sh
git init -q --bare -b main "$T/origin.git" || exit 1
git init -q -b main "$T/w" || exit 1
echo 0 > "$T/w/a"; G add a; G commit -m C0
G checkout -b f1; echo 1 > "$T/w/f1"; G add f1; G commit -m f1
G checkout main; G merge --no-ff f1 -m "Merge f1"; M1=$(git -C "$T/w" rev-parse HEAD)
G checkout -b f2; mkdir -p "$T/w/tests"; echo 'exit 0' > "$T/w/$PR"; G add "$PR"; G commit -m f2
G checkout main; G merge --no-ff f2 -m "Merge f2"; M2=$(git -C "$T/w" rev-parse HEAD)
G remote add origin "$T/origin.git"; G push origin main
git clone -q "$T/origin.git" "$T/repo" || exit 1
G checkout -b mergify/merge-queue/84d3542a46 "$M2"; echo 'exit 1' > "$T/w/$BO"; G add "$BO"; G commit -m "batch of 8"
B=$(git -C "$T/w" rev-parse HEAD)
G push origin mergify/merge-queue/84d3542a46
git -C "$T/repo" cat-file -e "$M2:$PR" 2>/dev/null && ok || bad "setup: $PR is not in main at M2"
git -C "$T/repo" cat-file -e "$M2:$BO" 2>/dev/null && bad "setup: $BO is in main at M2" || ok

# ── fixtures in the production shapes (run 37489866946) ──────────────────────
S=o/r
FLAG="$T/h/flags/main-red-o-r"
RUN=37489866946
flagfile() { # flagfile <sha> <reason> <run-url>  — main-red-detector.sh's writer
  { echo "sha=$1"; echo "workflow=Harness CI"; echo "path=.github/workflows/harness-ci.yml"
    echo "job=Tests, traced (shard 3/8)"; echo "since=2026-10-06T05:00:00Z"; echo "streak=1"
    echo "run=$3"; echo "detected=2026-10-06T05:10:00Z"; echo "reason=$2"; } > "$FLAG"
}
runjson() { # runjson <id> <head> <branch> [conclusion] [wfid] [event]
  jq -nc --argjson id "$1" --arg h "$2" --arg b "$3" --arg c "${4:-failure}" \
    --argjson w "${5:-7}" --arg e "${6:-workflow_dispatch}" \
    '{id:$id,head_sha:$h,head_branch:$b,workflow_id:$w,event:$e,name:"Harness CI",path:".github/workflows/harness-ci.yml",status:"completed",conclusion:$c}'
}
shardjobs() { # shardjobs <first-id> <conclusion>  → 8 traced shards + a lint job
  local n=1 id="$1" a=('{"id":1,"name":"lint","conclusion":"success"}')
  while [ "$n" -le 8 ]; do a+=("{\"id\":$((id+n)),\"name\":\"Tests, traced (shard $n/8)\",\"conclusion\":\"$2\"}"); n=$((n+1)); done
  printf '%s\n' "${a[@]}" | jq -sc '{total_count:length, jobs:.}'
}
LIST="repos/$S/actions/workflows/7/runs?branch=main&head_sha=$M2&status=success&per_page=5"
# batch_flag <suite>... — batch run $RUN red, shard 3's log names each suite rc=1
batch_flag() {
  local s
  flagfile "$B" queue "https://github.com/$S/actions/runs/$RUN"
  rest "repos/$S/actions/runs/$RUN" "$(runjson "$RUN" "$B" mergify/merge-queue/84d3542a46 failure 7 pull_request)"
  rest "repos/$S/actions/runs/$RUN/jobs?filter=latest&per_page=100" "$(shardjobs 500 success | jq -c '.jobs[3].conclusion="failure"')"
  for s in "$@"; do printf '2026-10-06T05:20:01.1Z --- %s rc=1 4s\n' "$s"; done | bytes "repos/$S/actions/jobs/503/logs"
  rest "repos/$S/actions/workflows/7/runs?status=success&per_page=100" '{"total_count":0,"workflow_runs":[]}'
}
# main_cleared_present — main's own run 900 at M2 ran tests/present.sh rc=0
main_cleared_present() {
  rest "$LIST" "$(runjson 900 "$M2" main success 7 | jq -sc '{total_count:length, workflow_runs:.}')"
  rest "repos/$S/actions/runs/900/jobs?filter=latest&per_page=100" "$(shardjobs 9000 success)"
  local n; for n in 1 2 3 4 5 6 7 8; do
    printf '2026-10-06T05:00:32.1Z --- %s rc=0 1s\r\n' "$([ "$n" = 3 ] && echo "$PR" || echo "tests/other-$n.sh")" \
      | bytes "repos/$S/actions/jobs/$((9000+n))/logs"
  done
}
reset() {
  rm -rf "$T/rest" "$T/bytes" "$T/out" "$T"/st-* "$T"/bst-* "$FLAG"
  mkdir -p "$T/rest" "$T/bytes" "$T/out"
  : > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"
}
# detect <lib> — one tick of the production entry point: rc to $T/rc, stderr to $T/err
detect() {
  ( . "$PROBE"; . "$1"; mrb_detect_episodes "$S" "$T/repo" "$T/out" ) 2> "$T/err"
  echo $? > "$T/rc"
}
files() { find "$T/out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }
val() { sed -n "s/^$2=//p" "$1" | tail -1; }

# ── A1: the #4875 shape — the only red suite is the batch's own ──────────────
reset; batch_flag "$BO"; detect "$DETECT"
eq "A1 rc" "$(cat "$T/rc")" 0
eq "A1 no episode" "$(files)" ""
grep -q "$BO.*not in main at $M2" "$T/err" && ok || bad "A1: no drop line naming $BO and $M2: $(cat "$T/err")"
eq "A1 curl calls" "$(cat "$T/curl-calls.txt")" ""

# ── A2: absent + present → written with the present suite only ──────────────
reset; batch_flag "$BO" "$PR"; detect "$DETECT"
EP="$T/out/flag-$RUN.ep"
eq "A2 rc" "$(cat "$T/rc")" 0
eq "A2 episode written" "$(files)" "flag-$RUN.ep "
eq "A2 suites" "$(val "$EP" suites)" "$PR"
eq "A2 red is the merge-base" "$(val "$EP" red)" "$M2"
eq "A2 outcome" "$(val "$EP" outcome)" "noanchor"
grep -q "$BO.*not in main at $M2" "$T/err" && ok || bad "A2: no drop line: $(cat "$T/err")"

# ── A3: A2 plus main's run at M2 cleared tests/present.sh → no file ──────────
reset; batch_flag "$BO" "$PR"; main_cleared_present; detect "$DETECT"
eq "A3 rc" "$(cat "$T/rc")" 0
eq "A3 no episode" "$(files)" ""
grep -q 'ran them all rc=0' "$T/err" && ok || bad "A3: no BH-4329 skip line: $(cat "$T/err")"

# ── A4: a main-class flag is not filtered ────────────────────────────────────
reset
flagfile "$M2" streak "https://github.com/$S/actions/runs/950"
rest "repos/$S/actions/runs/950" "$(runjson 950 "$M2" main failure 7 push)"
rest "repos/$S/actions/runs/950/jobs?filter=latest&per_page=100" "$(shardjobs 600 success | jq -c '.jobs[3].conclusion="failure"')"
printf '2026-10-06T05:20:01.1Z --- %s rc=1 4s\n' "$BO" | bytes "repos/$S/actions/jobs/603/logs"
rest "repos/$S/actions/workflows/7/runs?status=success&branch=main&per_page=100" "$(runjson 800 "$M1" main success 7 | jq -sc '{total_count:length, workflow_runs:.}')"
detect "$DETECT"
eq "A4 rc" "$(cat "$T/rc")" 0
eq "A4 episode written" "$(files)" "flag-950.ep "
eq "A4 suites unfiltered" "$(val "$T/out/flag-950.ep" suites)" "$BO"
eq "A4 green" "$(val "$T/out/flag-950.ep" green)" "$M1"
grep -q 'not in main' "$T/err" && bad "A4: a main-class flag was filtered" || ok

# ── A5: a tree that cannot be read is 75, never "absent" ─────────────────────
NOPE=0123456789abcdef0123456789abcdef01234567
x=$( ( . "$PROBE"; . "$DETECT"; _mrb_present_at "$T/repo" "$NOPE" "$PR $BO"; echo "rc=$? kept=[$_MRB_KEPT] absent=[$_MRB_ABSENT]" ) 2>&1 )
eq "A5 unreadable tree" "$x" "rc=75 kept=[] absent=[]"
x=$( ( . "$PROBE"; . "$DETECT"; _mrb_present_at "$T/repo" "$M2" "$BO $PR"; echo "rc=$? kept=[$_MRB_KEPT] absent=[$_MRB_ABSENT]" ) 2>&1 )
eq "A5 split at M2" "$x" "rc=0 kept=[$PR] absent=[$BO]"

# ── M1-M2: each mutation of a copied lib turns its row red (D1) ──────────────
# The copy lives in a copy of bin/lib, so its lazy deps load as the real one's.
mkdir -p "$T/mut"; cp -r "$DIR/bin/lib" "$T/mut/lib"
mutate() { # mutate <sed-expr> → path of the mutated copy; rc 1 if the sed changed nothing
  sed "$1" "$DETECT" > "$T/mut/lib/mrb-detect.sh"
  cmp -s "$DETECT" "$T/mut/lib/mrb-detect.sh" && return 1
  echo "$T/mut/lib/mrb-detect.sh"
}
if L=$(mutate 's/^    _mrb_present_at "\$repo" "\$red" "\$suites" || .*$/    :/'); then
  reset; batch_flag "$BO"; detect "$L"
  eq "M1 filter-removed mutant writes the #4875 episode" "$(files)" "flag-$RUN.ep "
else bad "M1: the mutation did not apply"; fi
if L=$(mutate 's/^    if git -C "\$repo" cat-file -e "\$sha:\$s" 2>\/dev\/null; then/    if true; then/'); then
  reset; batch_flag "$BO" "$PR"; detect "$L"
  eq "M2 keep-absent mutant carries both suites" "$(val "$T/out/flag-$RUN.ep" suites)" "$BO $PR"
else bad "M2: the mutation did not apply"; fi

echo "mrb-detect-absent: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
