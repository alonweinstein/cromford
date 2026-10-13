#!/bin/bash
# tests/mrb-detect-batch.bh-4329-test.sh — BH-4329: a merge-queue batch red is
# NOT written as a main episode when main's own run of the same workflow, at
# the exact merge-base sha, already ran every red suite with rc=0. Driven
# through the real bin/lib/mrb-detect.sh, the real gh_rest and a real scratch
# git origin. Only `gh` and `curl` are stubs (the pattern of
# tests/mrb-detect.bh-3685-test.sh, copied here, not sourced).
#
# Rows: P1-P3 _mrb_passed_suites_from_log, B1-B8 _mrb_main_cleared,
# E1-E3 the production entry point mrb_detect_episodes (E1 is the BH-4329
# reproduction: the #4329 shape must write no flag-<id>.ep).
#
# No network, no clock (every commit date is pinned below).
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/mrb-detect-batch.bh-4329-test.sh   (exit 0 = all pass)
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
st()    { printf '%s' "$2" > "$T/st-$(key "$1")"; }       # st <path> <status>
bytes() { cat > "$T/bytes/$(key "$1")"; }                 # bytes <path> < data
bst()   { printf '%s' "$2" > "$T/bst-$(key "$1")"; }      # bst <path> <status>

# ── a real origin: main = C0 then first-parent merges M1..M2, a batch off M2 ──
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-10-04T00:00:00Z' GIT_COMMITTER_DATE='2026-10-04T00:00:00Z'
G() { git -C "$T/w" "$@" >/dev/null 2>&1 || { echo "setup: git $* failed"; exit 1; }; }
git init -q --bare -b main "$T/origin.git" || exit 1
git init -q -b main "$T/w" || exit 1
# both red suites are on main, as they were in production: BH-4875 drops a
# batch red suite that main's tree at the merge-base does not have
mkdir -p "$T/w/tests"
for s in lanes-registry.bh-2205-test.sh triage-state-pr-contract.bh-3418-test.sh; do echo 'exit 0' > "$T/w/tests/$s"; done
echo 0 > "$T/w/a"; G add a tests; G commit -m C0
C0=$(git -C "$T/w" rev-parse HEAD)
for i in 1 2; do
  G checkout -b "f$i"; echo "$i" > "$T/w/f$i"; G add "f$i"; G commit -m "f$i"
  G checkout main; G merge --no-ff "f$i" -m "Merge f$i"
  eval "M$i=\$(git -C \"\$T/w\" rev-parse HEAD)"
done
G remote add origin "$T/origin.git"; G push origin main
git clone -q "$T/origin.git" "$T/repo" || exit 1
G checkout -b mergify/merge-queue/6133cd635b "$M2"; echo b > "$T/w/b"; G add b; G commit -m "batch of 8"
B=$(git -C "$T/w" rev-parse HEAD)
G push origin mergify/merge-queue/6133cd635b
: "$C0"

# ── fixtures in the production shapes (run 37178276949 / 37175771401) ────────
S=o/r
FLAG="$T/h/flags/main-red-o-r"
LR=tests/lanes-registry.bh-2205-test.sh
TS=tests/triage-state-pr-contract.bh-3418-test.sh
flagfile() { # flagfile <sha> <reason> <run-url>  — main-red-detector.sh's writer
  { echo "sha=$1"; echo "workflow=Harness CI"; echo "path=.github/workflows/harness-ci.yml"
    echo "job=Tests, traced (shard 3/8)"; echo "since=2026-10-04T05:00:00Z"; echo "streak=1"
    echo "run=$3"; echo "detected=2026-10-04T05:10:00Z"; echo "reason=$2"; } > "$FLAG"
}
runjson() { # runjson <id> <head> <branch> [conclusion] [wfid] [event]
  jq -nc --argjson id "$1" --arg h "$2" --arg b "$3" --arg c "${4:-failure}" \
    --argjson w "${5:-7}" --arg e "${6:-workflow_dispatch}" \
    '{id:$id,head_sha:$h,head_branch:$b,workflow_id:$w,event:$e,name:"Harness CI",path:".github/workflows/harness-ci.yml",status:"completed",conclusion:$c}'
}
runs() { # runs <id:sha:branch[:conclusion[:wfid]]>...  → a workflow_runs list
  local a=() r i h b c w
  for r in "$@"; do IFS=: read -r i h b c w <<<"$r"; a+=("$(runjson "$i" "$h" "$b" "${c:-success}" "${w:-7}")"); done
  printf '%s\n' ${a[@]+"${a[@]}"} | jq -sc '{total_count:length, workflow_runs:.}'
}
shardjobs() { # shardjobs <first-id> <conclusion>  → 8 traced shards + a lint job
  local n=1 id="$1" a=('{"id":1,"name":"lint","conclusion":"success"}')
  while [ "$n" -le 8 ]; do a+=("{\"id\":$((id+n)),\"name\":\"Tests, traced (shard $n/8)\",\"conclusion\":\"$2\"}"); n=$((n+1)); done
  printf '%s\n' "${a[@]}" | jq -sc '{total_count:length, jobs:.}'
}
LIST="repos/$S/actions/workflows/7/runs?branch=main&head_sha=$M2&status=success&per_page=5"
WFRUNS_ALL="actions/workflows/7/runs?status=success&per_page=100"
mainlog() { # mainlog <job-id> <line>...  → a traced shard log with CRLF endings
  local j="$1"; shift
  { echo $'2026-10-04T05:00:30.1000000Z ##[group]Run tests\r'
    for l in "$@"; do printf '2026-10-04T05:00:32.4633291Z %s\r\n' "$l"; done
  } | bytes "repos/$S/actions/jobs/$j/logs"
}
# main's own run 900 at M2: shard 3 ran LR, shard 5 ran TS, both rc=0
main_green() {
  rest "$LIST" "$(runs "900:$M2:main")"
  rest "repos/$S/actions/runs/900/jobs?filter=latest&per_page=100" "$(shardjobs 9000 success)"
  local n; for n in 1 2 4 6 7 8; do mainlog $((9000+n)) "--- tests/other-$n.sh rc=0 1s"; done
  mainlog 9003 "--- $LR rc=0 38s" "--- tests/x.sh rc=0 1s"
  mainlog 9005 "--- $TS rc=0 2s"
}

reset() {
  rm -rf "$T/rest" "$T/bytes" "$T/out" "$T"/st-* "$T"/bst-* "$FLAG"
  mkdir -p "$T/rest" "$T/bytes" "$T/out"
  : > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"
}

# cleared <lib> <red> <suites> — one _mrb_main_cleared call in a fresh subshell
cleared() {
  ( . "$PROBE"; . "$1"; _MRB_TMP=$(mktemp -d "$T/mt.XXXXXX"); _mrb_deps || exit 99
    _mrb_main_cleared "$S" "$T/repo" 7 "$2" "$3" ) 2> "$T/err"
  echo $?
}
# detect <lib> — one tick of the production entry point: rc to $T/rc, stderr to $T/err
detect() {
  ( . "$PROBE"; . "$1"; mrb_detect_episodes "$S" "$T/repo" "$T/out" ) 2> "$T/err"
  echo $? > "$T/rc"
}
files() { find "$T/out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }
val() { sed -n "s/^$2=//p" "$1" | tail -1; }
pparse() { ( . "$PROBE"; . "$DETECT"; _mrb_passed_suites_from_log ) 2>&1; }

# ── P1-P3: _mrb_passed_suites_from_log ───────────────────────────────────────
eq "P1 timestamped CRLF rc=0" "$(printf '2026-10-04T05:00:32.4633291Z --- tests/a.sh rc=0 38s\r\n' | pparse)" tests/a.sh
eq "P2 ignores rc!=0, HIT, x---, bin/" "$(printf '%s\n' \
  '2026-10-04T05:00:32.1Z --- tests/b.sh rc=1 3s' '--- tests/c.sh rc=10 1s' \
  '2026-10-04T05:00:33.1Z HIT tests/a.sh' 'x--- tests/a.sh rc=0' '--- bin/a.sh rc=0 1s' \
  '--- tests/d.sh rc=01 1s' | pparse)" ""
eq "P3 sorted unique" "$(printf '%s\n' '--- tests/z.sh rc=0 1s' '--- tests/a.sh rc=0' '--- tests/z.sh rc=0 2s' '--- tests/B.sh rc=0 1s' | pparse | tr '\n' ' ')" "tests/B.sh tests/a.sh tests/z.sh "
# a big log is read to the end (no SIGPIPE upstream)
eq "P3 big log" "$( { seq 1 200000 | sed 's/^/noise /'; echo '--- tests/end.sh rc=0 1s'; } | pparse)" tests/end.sh

# ── B1-B8: _mrb_main_cleared ─────────────────────────────────────────────────
reset; main_green
eq "B1 cleared" "$(cleared "$DETECT" "$M2" "$LR $TS")" 0
grep -q 'actions/jobs/9003/logs' "$T/gh-calls.txt" && ok || bad "B1: shard 3's log was never read"
eq "B1 empty suite list" "$(cleared "$DETECT" "$M2" "")" 1
eq "B1 one suite" "$(cleared "$DETECT" "$M2" "$TS")" 0

reset; main_green
rest "repos/$S/actions/runs/900/jobs?filter=latest&per_page=100" "$(shardjobs 9000 skipped)"
eq "B2 push run, shards skipped" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1
grep -q '/logs' "$T/gh-calls.txt" && bad "B2: a skipped shard's log was read" || ok

reset; main_green
eq "B3 one red suite missing" "$(cleared "$DETECT" "$M2" "$LR $TS tests/never-ran.sh")" 1

reset; main_green
rest "$LIST" "$(runs "900:$M1:main")"
eq "B4 success at an ancestor" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1
rest "$LIST" "$(runs "900:$M2:main:success:8")"
eq "B4 success at red, other workflow" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1
rest "$LIST" "$(runs "900:$M2:mergify/merge-queue/zz")"
eq "B4 success at red, not on main" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1
rest "$LIST" "$(runs "900:$M2:main:failure")"
eq "B4 a failed main run" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1

reset; main_green
mainlog 9003 "--- $LR-old rc=0 38s" "--- x$LR rc=0 1s"
eq "B5 prefix-named suite only" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1
reset; main_green
mainlog 9003 "--- $LR rc=1 38s"
eq "B5 rc=1 on main is not evidence" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1

reset; main_green; st "repos/$S/actions/runs/900/jobs?filter=latest&per_page=100" 503
eq "B6 jobs read 503" "$(cleared "$DETECT" "$M2" "$LR $TS")" 75
reset; main_green; st "$LIST" 429
eq "B6 list read 429" "$(cleared "$DETECT" "$M2" "$LR $TS")" 75
reset; main_green; bst "repos/$S/actions/jobs/9005/logs" 502
eq "B6 log read 502" "$(cleared "$DETECT" "$M2" "$LR $TS")" 75

reset; main_green; rm -f "$T/rest/$(key "$LIST")"
eq "B7 list read 404" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1
reset; main_green; rest "$LIST" '{"total_count":0,"workflow_runs":[]}'
eq "B7 empty list" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1

reset; main_green; rm -f "$T"/bytes/*
eq "B8 every log 404" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1
reset; main_green; bst "repos/$S/actions/jobs/9005/logs" 410
eq "B8 TS's log gone" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1

# two main runs at red: the newer one lacks TS, the older has both → cleared by ONE run
reset; main_green
rest "$LIST" "$(runs "901:$M2:main" "900:$M2:main")"
rest "repos/$S/actions/runs/901/jobs?filter=latest&per_page=100" "$(shardjobs 9100 success)"
for n in 1 2 3 4 5 6 7 8; do mainlog $((9100+n)) "--- $LR rc=0 1s"; done
eq "B1 older run clears" "$(cleared "$DETECT" "$M2" "$LR $TS")" 0
# split across two runs is NOT cleared
for n in 1 2 3 4 5 6 7 8; do mainlog $((9000+n)) "--- $TS rc=0 1s"; done
eq "B3 suites split across runs" "$(cleared "$DETECT" "$M2" "$LR $TS")" 1

# ── E1-E3: the production entry point ────────────────────────────────────────
batch_flag() { # the #4329 shape: a merge-queue batch red on LR and TS
  flagfile "$B" queue "https://github.com/$S/actions/runs/37178276949"
  rest "repos/$S/actions/runs/37178276949" "$(runjson 37178276949 "$B" mergify/merge-queue/6133cd635b failure 7 pull_request)"
  rest "repos/$S/actions/runs/37178276949/jobs?filter=latest&per_page=100" "$(shardjobs 500 success | jq -c '.jobs[3].conclusion="failure" | .jobs[5].conclusion="failure"')"
  printf '%s\n' "2026-10-04T05:20:01.1Z --- $LR rc=1 40s" '2026-10-04T05:20:01.2Z 7 wired lanes read env knobs the registry does not carry' | bytes "repos/$S/actions/jobs/503/logs"
  printf '%s\n' "2026-10-04T05:20:02.1Z --- $TS rc=1 2s" '2026-10-04T05:20:02.2Z FAIL: (B1) bin/lib/rt/shards.sh is not edited' | bytes "repos/$S/actions/jobs/505/logs"
  rest "repos/$S/$WFRUNS_ALL" '{"total_count":0,"workflow_runs":[]}'
}
reset; batch_flag; main_green; detect "$DETECT"
eq "E1 rc" "$(cat "$T/rc")" 0
eq "E1 no episode" "$(files)" ""
grep -q 'ran them all rc=0' "$T/err" && ok || bad "E1: no skip line: $(cat "$T/err")"
grep -q 'main run 900' "$T/err" && ok || bad "E1: skip line does not name main run 900"
eq "E1 curl calls" "$(cat "$T/curl-calls.txt")" ""

reset; batch_flag; detect "$DETECT"
eq "E2 rc" "$(cat "$T/rc")" 0
eq "E2 episode written" "$(files)" "flag-37178276949.ep "
eq "E2 red is the merge-base" "$(val "$T/out/flag-37178276949.ep" red)" "$M2"
eq "E2 suites" "$(val "$T/out/flag-37178276949.ep" suites)" "$LR $TS"

reset; batch_flag; main_green; st "repos/$S/actions/runs/900/jobs?filter=latest&per_page=100" 503; detect "$DETECT"
eq "E2 main jobs 503 rc" "$(cat "$T/rc")" 75
eq "E2 main jobs 503 no file" "$(files)" ""

# E3: a main-class flag keeps today's behaviour even with a green main run around
reset; main_green
flagfile "$M2" streak "https://github.com/$S/actions/runs/950"
rest "repos/$S/actions/runs/950" "$(runjson 950 "$M2" main failure 7 push)"
rest "repos/$S/actions/runs/950/jobs?filter=latest&per_page=100" "$(shardjobs 600 success | jq -c '.jobs[3].conclusion="failure"')"
printf '%s\n' "2026-10-04T05:20:01.1Z --- $LR rc=1 40s" | bytes "repos/$S/actions/jobs/603/logs"
rest "repos/$S/actions/workflows/7/runs?status=success&branch=main&per_page=100" "$(runs "800:$M1:main")"
detect "$DETECT"
eq "E3 rc" "$(cat "$T/rc")" 0
eq "E3 episode written" "$(files)" "flag-950.ep "
eq "E3 green" "$(val "$T/out/flag-950.ep" green)" "$M1"
grep -q 'head_sha=' "$T/gh-calls.txt" && bad "E3: a main-class flag read main's runs at red" || ok

# ── M1-M5: each mutation of a copied lib turns its row red (D1) ──────────────
# The copy lives in a copy of bin/lib, so its lazy deps load as the real one's.
mkdir -p "$T/mut"; cp -r "$DIR/bin/lib" "$T/mut/lib"
mutate() { # mutate <sed-expr> → path of the mutated copy; rc 1 if the sed changed nothing
  sed "$1" "$DETECT" > "$T/mut/lib/mrb-detect.sh"
  cmp -s "$DETECT" "$T/mut/lib/mrb-detect.sh" && return 1
  echo "$T/mut/lib/mrb-detect.sh"
}
if L=$(mutate 's/^  \[ -n "\$suites" \] || return 1$/  [ -n "$suites" ] || return 1; return 0/'); then
  reset; main_green; rm -f "$T/rest/$(key "$LIST")"
  eq "M1 always-cleared mutant clears a 404" "$(cleared "$L" "$M2" "$LR $TS")" 0
else bad "M1: the mutation did not apply"; fi
if L=$(mutate 's/ and \.head_sha == \$red//'); then
  reset; main_green; rest "$LIST" "$(runs "900:$M1:main")"
  eq "M2 no-exact-sha mutant clears an ancestor" "$(cleared "$L" "$M2" "$LR $TS")" 0
else bad "M2: the mutation did not apply"; fi
if L=$(mutate 's/grep -qxF -- "\$s" "\$pass" || continue 2/grep -qxF -- "$s" "$pass" \&\& break/'); then
  reset; main_green
  eq "M3 any-suite mutant clears a partial match" "$(cleared "$L" "$M2" "$LR tests/never-ran.sh")" 0
else bad "M3: the mutation did not apply"; fi
if L=$(mutate 's/^    \[ "\$rc" = 0 \] || return 75$/    [ "$rc" = 0 ] || return 1/'); then
  reset; main_green; st "repos/$S/actions/runs/900/jobs?filter=latest&per_page=100" 503
  eq "M4 5xx-as-no-evidence mutant" "$(cleared "$L" "$M2" "$LR $TS")" 1
else bad "M4: the mutation did not apply"; fi
if L=$(mutate 's/if \[ "\$cls" = batch \] && \[ -n "\$suites" \]; then/if false; then/'); then
  reset; batch_flag; main_green; detect "$L"
  eq "M5 call-site-removed mutant writes the #4329 episode" "$(files)" "flag-37178276949.ep "
else bad "M5: the mutation did not apply"; fi

echo "mrb-detect-batch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
