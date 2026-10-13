#!/bin/bash
# tests/mrb-detect.bh-3685-test.sh — main-red-bisect, the detect half (BH-3695,
# split child 3 of 5 of BH-3685): mrb_detect_episodes and mrb_episode_still_red
# in bin/lib/mrb-detect.sh, driven through the real lib, the real gh_rest and a
# real scratch git origin. Only `gh` and `curl` are stubs.
#
# Rows: F0-F7 the flag source, N1-N4 the nightly source, S1-S5 still_red,
# M1-M3 mutations of a copied lib that must each turn their row red (D1).
# Every row also asserts that nothing called curl and nothing called a GraphQL
# verb (`gh pr|run|issue`).
#
# No network, no clock (every commit date is pinned below).
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/mrb-detect.bh-3685-test.sh   (exit 0 = all pass)
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
k=$(key "${2:-}")                    # gh api <path>: log / zip bytes
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

# ── a real origin: main = C0 then first-parent merges M1..M3 ──────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_AUTHOR_DATE='2026-09-01T00:00:00Z' GIT_COMMITTER_DATE='2026-09-01T00:00:00Z'
G() { git -C "$T/w" "$@" >/dev/null 2>&1 || { echo "setup: git $* failed"; exit 1; }; }
git init -q --bare -b main "$T/origin.git" || exit 1
git init -q -b main "$T/w" || exit 1
# the batch red suite is on main, as a real one is: BH-4875 drops a batch red
# suite that main's tree at the merge-base does not have
mkdir -p "$T/w/tests"; echo 'exit 0' > "$T/w/tests/x-test.sh"
echo 0 > "$T/w/a"; G add a tests; G commit -m C0
C0=$(git -C "$T/w" rev-parse HEAD)
for i in 1 2 3; do
  G checkout -b "f$i"; echo "$i" > "$T/w/f$i"; G add "f$i"; G commit -m "f$i"
  G checkout main; G merge --no-ff "f$i" -m "Merge f$i"
  eval "M$i=\$(git -C \"\$T/w\" rev-parse HEAD)"
done
G remote add origin "$T/origin.git"; G push origin main
git clone -q "$T/origin.git" "$T/repo" || exit 1
# pushed AFTER the clone, so the lib has to fetch them
G checkout -b side "$M1"; echo x > "$T/w/x"; G add x; G commit -m side
X=$(git -C "$T/w" rev-parse HEAD)
G checkout -b mergify/merge-queue/main/x "$M2"; echo b > "$T/w/b"; G add b; G commit -m "batch x"
B=$(git -C "$T/w" rev-parse HEAD)
G checkout -b mergify/merge-queue/main/y "$C0"; echo y > "$T/w/y"; G add y; G commit -m "batch y"
B1=$(git -C "$T/w" rev-parse HEAD)
G push origin side mergify/merge-queue/main/x mergify/merge-queue/main/y
git -C "$T/repo" cat-file -e "$B^{commit}" 2>/dev/null && bad "setup: batch head must not be in the clone yet"

# ── fixtures in the production shapes ─────────────────────────────────────────
S=o/r
FLAG="$T/h/flags/main-red-o-r"
flagfile() { # flagfile <sha> <reason> [run-url]  — main-red-detector.sh:1133's writer
  { echo "sha=$1"; echo "workflow=Harness CI"; echo "path=.github/workflows/harness-ci.yml"
    echo "job=Tests, traced (shard 1/4)"; echo "since=2026-09-30T10:00:00Z"; echo "streak=2"
    [ -n "${3:-}" ] && echo "run=$3"; echo "detected=2026-09-30T10:05:00Z"; echo "reason=$2"; } > "$FLAG"
}
pairflag() { # main-red-pr-pair.sh's writer: no sha=, no run=
  printf 'owner=main-red-pr-pair\nreason=pr-pair-suspected\ndetected=2026-09-30T10:05:00Z\nprs=12 13\n' > "$FLAG"
}
runjson() { # runjson <id> <head> <branch> [conclusion] [path] [wfid]
  jq -nc --argjson id "$1" --arg h "$2" --arg b "$3" --arg c "${4:-failure}" \
    --arg p "${5:-.github/workflows/harness-ci.yml}" --argjson w "${6:-7}" \
    '{id:$id,head_sha:$h,head_branch:$b,workflow_id:$w,name:"Harness CI",path:$p,status:"completed",conclusion:$c}'
}
runs() { # runs <id:sha:branch[:conclusion]>...  → a workflow_runs list
  local a=() r
  for r in "$@"; do IFS=: read -r i h b c <<<"$r"; a+=("$(runjson "$i" "$h" "$b" "${c:-success}")"); done
  printf '%s\n' ${a[@]+"${a[@]}"} | jq -sc '{total_count:length, workflow_runs:.}'
}
JOBS='{"total_count":3,"jobs":[
 {"id":554,"name":"decisions","conclusion":"failure"},
 {"id":555,"name":"Tests, traced (shard 1/4)","conclusion":"failure"},
 {"id":556,"name":"Tests, traced (shard 2/4)","conclusion":"success"}]}'
LOG555='2026-09-30T10:00:01.1234567Z --- tests/a-test.sh rc=0 2s
2026-09-30T10:00:02.1234567Z --- tests/x-test.sh rc=1 3s
2026-09-30T10:00:02.2234567Z boom: expected 3 got 4
2026-09-30T10:00:03.1234567Z HIT rm -rf /root/harness/state/x'
WFRUNS_MAIN="actions/workflows/7/runs?status=success&branch=main&per_page=100"
WFRUNS_ALL="actions/workflows/7/runs?status=success&per_page=100"
NIGHTLY="repos/$S/actions/workflows/harness-nightly.yml/runs?branch=main&status=completed&per_page=1"
NGREEN="repos/$S/actions/workflows/harness-nightly.yml/runs?status=success&branch=main&per_page=100"
mkzip() { # mkzip <out.zip> <member> <text> [<member> <text>...]
  python3 - "$@" <<'PY'
import sys, zipfile
out, rest = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(out, "w") as z:
    for i in range(0, len(rest), 2):
        z.writestr(rest[i], rest[i+1])
PY
}

reset() { # a clean tick: no flag, no fixtures, empty out-dir, empty call logs
  rm -rf "$T/rest" "$T/bytes" "$T/out" "$T"/st-* "$T"/bst-* "$FLAG"
  mkdir -p "$T/rest" "$T/bytes" "$T/out"
  : > "$T/gh-calls.txt"; : > "$T/curl-calls.txt"
}
f1_fixture() {
  flagfile "$M3" streak "https://github.com/$S/actions/runs/101"
  rest "repos/$S/actions/runs/101" "$(runjson 101 "$M3" main)"
  rest "repos/$S/actions/runs/101/jobs?filter=latest&per_page=100" "$JOBS"
  printf '%s\n' "$LOG555" | bytes "repos/$S/actions/jobs/555/logs"
  rest "repos/$S/$WFRUNS_MAIN" "$(runs "99:$M2:main" "98:$M1:main")"
}
n1_fixture() {
  rest "$NIGHTLY" "$(runs "201:$M3:main:failure" | jq -c '.workflow_runs[0].path=".github/workflows/harness-nightly.yml"')"
  rest "repos/$S/actions/runs/201/artifacts?per_page=100" \
    '{"total_count":2,"artifacts":[{"id":301,"name":"nightly-verdict-0","expired":false},{"id":302,"name":"nightly-verdict-strict","expired":false}]}'
  mkzip "$T/a301.zip" shard-0.log $'2026-09-30T03:00:00.1Z --- tests/y-test.sh rc=2 9s\n2026-09-30T03:00:01.1Z --- tests/a-test.sh rc=0 1s\n' shard-0.txt 'pass=fail'
  mkzip "$T/a302.zip" strict.log $'--- tests/strict-test.sh rc=1\n' strict.md '# strict'
  bytes "repos/$S/actions/artifacts/301/zip" < "$T/a301.zip"
  bytes "repos/$S/actions/artifacts/302/zip" < "$T/a302.zip"
  rest "$NGREEN" "$(runs "200:$M2:main" "199:$M1:main")"
}

# The parse is BH-3694's. While mrb_suites_from_log is still the contract stub
# (a result line gives no output) the suite installs the minimal parse the
# contract documents, and says so: the behaviour under test here is detect.
STUBPARSE=0
if [ -z "$(bash -c '. "$1"; printf -- "--- tests/q.sh rc=1\n" | mrb_suites_from_log' _ "$PROBE")" ]; then
  STUBPARSE=1
  echo "NOTE: mrb_suites_from_log is still the BH-3694 stub; this suite parses '--- tests/<x> rc=<n>' itself"
fi

# detect <lib> — one tick in a fresh subshell: rc to $T/rc, stderr to $T/err
detect() {
  ( . "$PROBE"; . "$1"
    if [ "$STUBPARSE" = 1 ]; then
      mrb_suites_from_log() { grep -oE -- '--- tests/[^ ]+ rc=[1-9][0-9]*' | awk '{print $2}' | sort -u; }
    fi
    mrb_detect_episodes "$S" "$T/repo" "$T/out" ) 2> "$T/err"
  echo $? > "$T/rc"
}
still() { ( . "$PROBE"; . "$DETECT"; mrb_episode_still_red "$1" ) 2>> "$T/err"; echo $?; }
val() { sed -n "s/^$2=//p" "$1" | tail -1; }         # val <file> <key>, last line wins
keys() { sed 's/=.*//' "$1" | tr '\n' ' '; }
files() { find "$T/out" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tr '\n' ' '; }
clean() { # every row: no curl, no GraphQL verb
  eq "$1 curl calls" "$(cat "$T/curl-calls.txt")" ""
  eq "$1 graphql verbs" "$(grep -cE '^(pr|run|issue) ' "$T/gh-calls.txt")" 0
}

# ── F0: sourcing prints nothing, defines both, keeps the signatures ──────────
out=$(bash -c '. "$1" && . "$2"' _ "$PROBE" "$DETECT" 2>&1); eq "F0 source rc" "$?" 0
eq "F0 source output" "$out" ""
eq "F0 two contract functions" "$(grep -cE '^(mrb_detect_episodes|mrb_episode_still_red)\(\)' "$DETECT")" 2
out=$(bash -c '. "$1"; declare -F gh_rest gh_auth_for | wc -l' _ "$DETECT"); eq "F0 no deps at source time" "$out" 0

# ── F1: flag + failed traced job + its log → one complete episode ────────────
reset; f1_fixture; detect "$DETECT"
EP="$T/out/flag-101.ep"
eq "F1 rc" "$(cat "$T/rc")" 0
eq "F1 files" "$(files)" "flag-101.ep "
eq "F1 key order" "$(keys "$EP")" "source slug red green run wf job suites outcome "
eq "F1 source" "$(val "$EP" source)" flag
eq "F1 slug" "$(val "$EP" slug)" "$S"
eq "F1 red" "$(val "$EP" red)" "$M3"
eq "F1 green" "$(val "$EP" green)" "$M2"
eq "F1 run" "$(val "$EP" run)" 101
eq "F1 wf" "$(val "$EP" wf)" harness-ci.yml
eq "F1 job" "$(val "$EP" job)" 555
eq "F1 suites" "$(val "$EP" suites)" tests/x-test.sh
eq "F1 outcome" "$(grep -c '^outcome=$' "$EP")" 1
grep -q 'actions/jobs/555/logs' "$T/gh-calls.txt" && ok || bad "F1: job 555's log was never read"
grep -q 'actions/jobs/556/logs' "$T/gh-calls.txt" && bad "F1: a passing job's log was read" || ok
clean F1
cp "$EP" "$T/f1.ep"

# ── F2: the job log is gone (404) → nosuite, still an episode ────────────────
reset; f1_fixture; bst "repos/$S/actions/jobs/555/logs" 404; detect "$DETECT"
eq "F2 rc" "$(cat "$T/rc")" 0
eq "F2 outcome" "$(val "$T/out/flag-101.ep" outcome)" nosuite
eq "F2 red kept" "$(val "$T/out/flag-101.ep" red)" "$M3"
grep -q '^culprit=' "$T/out/flag-101.ep" && bad "F2: a culprit from absent data" || ok
clean F2

# ── F2b: the log has only HIT lines and passing suites → nosuite ─────────────
reset; f1_fixture
printf '2026-09-30T10:00:03.1Z HIT rm -rf /root/harness/x\n2026-09-30T10:00:04.1Z --- tests/a-test.sh rc=0 1s\n' | bytes "repos/$S/actions/jobs/555/logs"
detect "$DETECT"
eq "F2b rc" "$(cat "$T/rc")" 0
eq "F2b outcome" "$(val "$T/out/flag-101.ep" outcome)" nosuite
eq "F2b suites" "$(val "$T/out/flag-101.ep" suites)" ""
clean F2b

# ── F2c: only a non-traced job failed → nosuite, no log read at all ──────────
reset; f1_fixture
rest "repos/$S/actions/runs/101/jobs?filter=latest&per_page=100" '{"jobs":[{"id":554,"name":"decisions","conclusion":"failure"}]}'
detect "$DETECT"
eq "F2c outcome" "$(val "$T/out/flag-101.ep" outcome)" nosuite
eq "F2c job" "$(val "$T/out/flag-101.ep" job)" ""
grep -q '/logs' "$T/gh-calls.txt" && bad "F2c: read a log with no traced job" || ok

# ── F3: a merge-queue batch red → red is the merge-base on main ──────────────
f3() {
  reset
  flagfile "$B" queue "https://github.com/$S/actions/runs/102/attempts/2"
  rest "repos/$S/actions/runs/102" "$(runjson 102 "$B" mergify/merge-queue/main/x)"
  rest "repos/$S/actions/runs/102/jobs?filter=latest&per_page=100" "$JOBS"
  printf '%s\n' "$LOG555" | bytes "repos/$S/actions/jobs/555/logs"
  # a main success at M1 is the wrong class for a batch red; batch y (off C0) anchors
  rest "repos/$S/$WFRUNS_ALL" "$(runs "97:$M1:main" "96:$B1:mergify/merge-queue/main/y")"
  detect "$1"
}
f3 "$DETECT"
EP="$T/out/flag-102.ep"
eq "F3 rc" "$(cat "$T/rc")" 0
eq "F3 red" "$(val "$EP" red)" "$M2"
[ "$(val "$EP" red)" != "$B" ] && ok || bad "F3: red is the batch head"
grep -q "$B" "$EP" && bad "F3: the batch head sha is in the episode" || ok
eq "F3 green (batch anchor, via merge-base)" "$(val "$EP" green)" "$C0"
eq "F3 run (attempts/2 parsed)" "$(val "$EP" run)" 102
clean F3

# ── F3b: a PR-branch run is refused, never guessed ───────────────────────────
reset
flagfile "$X" streak "https://github.com/$S/actions/runs/103"
rest "repos/$S/actions/runs/103" "$(runjson 103 "$X" ticket/bh-1)"
detect "$DETECT"
eq "F3b rc" "$(cat "$T/rc")" 0
eq "F3b files" "$(files)" ""
grep -q 'skipped' "$T/err" && ok || bad "F3b: no skip line: $(cat "$T/err")"

# ── F4: pr-pair-suspected has no run → skipped with a line, no file ──────────
reset; pairflag; detect "$DETECT"
eq "F4 rc" "$(cat "$T/rc")" 0
eq "F4 files" "$(files)" ""
grep -q 'skipped' "$T/err" && ok || bad "F4: no skip line: $(cat "$T/err")"
grep -q 'pr-pair-suspected' "$T/err" && ok || bad "F4: skip line does not name the reason"
clean F4

# ── F4b: no flag, no nightly workflow → no episode, rc 0 ─────────────────────
reset; detect "$DETECT"
eq "F4b rc" "$(cat "$T/rc")" 0
eq "F4b files" "$(files)" ""

# ── F5: the run read answers 503 → rc 75, nothing written ────────────────────
reset; f1_fixture; st "repos/$S/actions/runs/101" 503; detect "$DETECT"
eq "F5 rc" "$(cat "$T/rc")" 75
eq "F5 files" "$(files)" ""
clean F5
reset; f1_fixture; st "repos/$S/actions/runs/101/jobs?filter=latest&per_page=100" 503; detect "$DETECT"
eq "F5 jobs-503 rc" "$(cat "$T/rc")" 75
eq "F5 jobs-503 files" "$(files)" ""
reset; f1_fixture; st "repos/$S/$WFRUNS_MAIN" 429; detect "$DETECT"
eq "F5 anchor-429 rc" "$(cat "$T/rc")" 75
eq "F5 anchor-429 files" "$(files)" ""

# ── F5b: the job-log bytes answer 503 → rc 75, nothing written ───────────────
f5b() { reset; f1_fixture; bst "repos/$S/actions/jobs/555/logs" "${2:-503}"; detect "$1"; }
f5b "$DETECT"
eq "F5b rc" "$(cat "$T/rc")" 75
eq "F5b files" "$(files)" ""
clean F5b
f5b "$DETECT" 403
eq "F5b 403 rc" "$(cat "$T/rc")" 75
eq "F5b 403 files" "$(files)" ""

# ── F6: the only success is not an ancestor of red → noanchor ────────────────
f6() { reset; f1_fixture; rest "repos/$S/$WFRUNS_MAIN" "$(runs "90:$X:main")"; detect "$1"; }
f6 "$DETECT"
EP="$T/out/flag-101.ep"
eq "F6 rc" "$(cat "$T/rc")" 0
eq "F6 outcome" "$(val "$EP" outcome)" noanchor
eq "F6 green" "$(val "$EP" green)" ""
eq "F6 suites kept" "$(val "$EP" suites)" tests/x-test.sh
# the only success is red itself: strict, so never its own anchor
reset; f1_fixture; rest "repos/$S/$WFRUNS_MAIN" "$(runs "91:$M3:main")"; detect "$DETECT"
eq "F6 green==red outcome" "$(val "$EP" outcome)" noanchor

# ── F7: the anchor is deeper than MAIN_RED_BISECT_MAX_MERGES → noanchor ──────
reset; f1_fixture; rest "repos/$S/$WFRUNS_MAIN" "$(runs "98:$M1:main")"
MAIN_RED_BISECT_MAX_MERGES=1 detect "$DETECT"
eq "F7 max=1 outcome" "$(val "$EP" outcome)" noanchor
eq "F7 max=1 green" "$(val "$EP" green)" ""
reset; f1_fixture; rest "repos/$S/$WFRUNS_MAIN" "$(runs "98:$M1:main")"
MAIN_RED_BISECT_MAX_MERGES=2 detect "$DETECT"
eq "F7 max=2 green" "$(val "$EP" green)" "$M1"
eq "F7 max=2 outcome" "$(val "$EP" outcome)" ""
reset; f1_fixture; MAIN_RED_BISECT_MAX_MERGES=abc detect "$DETECT"
eq "F7 max=abc falls back to 40" "$(cat "$EP")" "$(cat "$T/f1.ep")"

# ── N1: a failed nightly → nightly episode from the shard-*.log artifacts ────
reset; n1_fixture; detect "$DETECT"
EP="$T/out/nightly-201.ep"
eq "N1 rc" "$(cat "$T/rc")" 0
eq "N1 files" "$(files)" "nightly-201.ep "
eq "N1 key order" "$(keys "$EP")" "source slug red green run wf job suites outcome "
eq "N1 source" "$(val "$EP" source)" nightly
eq "N1 red" "$(val "$EP" red)" "$M3"
eq "N1 green" "$(val "$EP" green)" "$M2"
eq "N1 run" "$(val "$EP" run)" 201
eq "N1 wf" "$(val "$EP" wf)" harness-nightly.yml
eq "N1 suites (strict.log is not a shard log)" "$(val "$EP" suites)" tests/y-test.sh
eq "N1 outcome" "$(grep -c '^outcome=$' "$EP")" 1
clean N1
cp "$EP" "$T/n1.ep"

# flag and nightly both red → two files
reset; f1_fixture; n1_fixture; detect "$DETECT"
eq "N1 both sources" "$(files)" "flag-101.ep nightly-201.ep "

# ── N2: the newest nightly is a success → no nightly file ────────────────────
reset; n1_fixture; rest "$NIGHTLY" "$(runs "202:$M3:main:success")"; detect "$DETECT"
eq "N2 rc" "$(cat "$T/rc")" 0
eq "N2 files" "$(files)" ""

# ── N3: the only artifact expired → nosuite ──────────────────────────────────
reset; n1_fixture
rest "repos/$S/actions/runs/201/artifacts?per_page=100" '{"artifacts":[{"id":301,"name":"nightly-verdict-0","expired":true}]}'
detect "$DETECT"
eq "N3 rc" "$(cat "$T/rc")" 0
eq "N3 outcome" "$(val "$T/out/nightly-201.ep" outcome)" nosuite
grep -q 'artifacts/301/zip' "$T/gh-calls.txt" && bad "N3: an expired artifact was downloaded" || ok
clean N3

# ── N4: the artifact bytes answer 502 → rc 75, nothing written ───────────────
reset; n1_fixture; bst "repos/$S/actions/artifacts/301/zip" 502; detect "$DETECT"
eq "N4 rc" "$(cat "$T/rc")" 75
eq "N4 files" "$(files)" ""
reset; n1_fixture; st "$NIGHTLY" 503; detect "$DETECT"
eq "N4 nightly-list-503 rc" "$(cat "$T/rc")" 75

# ── S1-S5: mrb_episode_still_red ─────────────────────────────────────────────
reset; : > "$T/err"
eq "S1 flag cleared" "$(still "$T/f1.ep")" 1
flagfile "$M3" streak "https://github.com/$S/actions/runs/101"
eq "S2 flag unchanged" "$(still "$T/f1.ep")" 0
flagfile "$M3" streak "https://github.com/$S/actions/runs/150"
eq "S2 new run, same red sha" "$(still "$T/f1.ep")" 0
flagfile "$X" streak "https://github.com/$S/actions/runs/151"
eq "S2 new run, new sha" "$(still "$T/f1.ep")" 1
pairflag
eq "S2 pr-pair flag" "$(still "$T/f1.ep")" 1
n1_fixture
eq "S4 nightly unchanged" "$(still "$T/n1.ep")" 0
rest "$NIGHTLY" "$(runs "202:$M3:main:success")"
eq "S3 newer nightly is green" "$(still "$T/n1.ep")" 1
rest "$NIGHTLY" "$(runs "203:$M3:main:failure")"
eq "S3 newer nightly red again" "$(still "$T/n1.ep")" 1
n1_fixture; st "$NIGHTLY" 503
eq "S5 nightly unreadable fails closed" "$(still "$T/n1.ep")" 1
eq "S5 missing episode" "$(still "$T/nope.ep")" 1
printf 'source=other\nslug=o/r\n' > "$T/odd.ep"
eq "S5 unknown source" "$(still "$T/odd.ep")" 1
eq "S5 empty root" "$(HARNESS= still "$T/f1.ep")" 1

# empty root on detect → 75, never "no episodes"
reset; f1_fixture; HARNESS= detect "$DETECT"
eq "S5 detect empty root rc" "$(cat "$T/rc")" 75
reset; ( . "$PROBE"; . "$DETECT"; mrb_detect_episodes "$S" "$T/nowhere" "$T/out" ) 2>/dev/null
eq "S5 detect bad repo-dir rc" "$?" 75

# ── M1-M3: each mutation of a copied lib turns its row red (D1) ──────────────
# The copy lives in a copy of bin/lib, so its lazy deps load exactly as the
# real one's do. Each row asserts the WRONG answer the mutation produces, so a
# mutant that merely failed to run can never count as caught.
mkdir -p "$T/mut"; cp -r "$DIR/bin/lib" "$T/mut/lib"
mutate() { # mutate <name> <sed-expr>  → path of the mutated copy; rc 1 if the sed changed nothing
  sed "$2" "$DETECT" > "$T/mut/lib/mrb-detect.sh"
  cmp -s "$DETECT" "$T/mut/lib/mrb-detect.sh" && return 1
  echo "$T/mut/lib/mrb-detect.sh"
}
if L=$(mutate M1 's/git -C "\$repo" merge-base --is-ancestor "\$s" "\$red"/true/'); then
  f6 "$L"
  eq "M1 mutant anchors on the non-ancestor" "$(val "$T/out/flag-101.ep" green)" "$X"
  [ "$(val "$T/out/flag-101.ep" outcome)" = noanchor ] && bad "M1: F6 stayed green with the ancestor check gone" || ok
else bad "M1: the mutation did not apply"; fi
if L=$(mutate M2 's/\*"HTTP 404"\*|\*"HTTP 410"\*)/*"HTTP "*)/'); then
  f5b "$L"
  eq "M2 mutant writes nosuite on a 503" "$(cat "$T/rc") $(val "$T/out/flag-101.ep" outcome)" "0 nosuite"
  [ "$(cat "$T/rc")" = 75 ] && bad "M2: F5b stayed green with 5xx mapped to nosuite" || ok
else bad "M2: the mutation did not apply"; fi
if L=$(mutate M3 's/red=\$(git -C "\$repo" merge-base "\$sha" origin\/main)/red=$sha/'); then
  f3 "$L"
  eq "M3 mutant records the batch head" "$(val "$T/out/flag-102.ep" red)" "$B"
  [ "$(val "$T/out/flag-102.ep" red)" = "$M2" ] && bad "M3: F3 stayed green with the batch head as red" || ok
else bad "M3: the mutation did not apply"; fi

echo "mrb-detect: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
