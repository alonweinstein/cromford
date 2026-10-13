#!/bin/bash
# tests/main-red-queue-attr.bh-3886-test.sh — BH-3890 (3 of 5 of BH-3886):
# bin/lib/main-red-queue-attr.sh, the rule that decides whether a red
# merge-queue batch was broken by one of its OWN PRs (`own`, not counted toward
# main-red) or not (`untouched`/`unreadable`, counted as before).
#
# THE DATA IS REAL. tests/fixtures/bh-3886/attr/ holds `gh run view <id>
# --log-failed` of the three red batches of 2026-10-02 (plain-text excerpts of the
# bytes gh printed: every failure line plus five lines of context around it and
# around 36966459398's bin/test-impact-gate.sh line, leakcheck-clean for the
# public mirror) and `gh api …/pulls/<n>/files` of their five PRs. 36969794399
# (#3882 + #3855 + #3881) failed on bin/lib/mc-foreign-red.sh, a #3881 file;
# 36967597297 (#3847) and 36966459398 (#3873) failed on a suite neither touches.
# The queue/main pages are BH-3888's tests/fixtures/bh-3886/*-2026-10-02.json,
# cut at 06:01:00Z and rebased onto NOW.
#
#   C1  the incident: 36969794399 is attributed to #3881, two reds are left, no
#       freeze, no alert, the log line names #3881 and the path, verdicts cached
#   C2  the knob at 0: the freeze is up with streak=3 and no log is read
#   C3  a failed-log read is `unreadable`: counted, logged, never cached
#       (C3b over FLAKY_LOG_MAX, C3c an empty log, C3d a PR file list failing)
#   C4  a second tick answers from the ledger with zero reads (C4b ledger down:
#       it reads again, same verdict)
#   C5a a PR path on a NON-failure line does not attribute (real log, #3873)
#   C5b exact equality both ways: foo-test.sh vs foo-test.sh.bak
#   C5c only the batch's own PRs are read and matched
#   C6  the lib absent: today's freeze, one `attribution is off` line, rc 0
#   M1-M7 each core behaviour broken once in a copy of the lib turns its case red
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-queue-attr.bh-3886-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  [ -n "${CI:-}" ] && { echo "FAIL: jq/python3 missing on a CI runner"; exit 1; }
  echo "main-red-queue-attr.bh-3886-test: SKIPPED — jq/python3 is not installed"; exit 0; }
FX="$DIR/tests/fixtures/bh-3886"
ATTR="$FX/attr"
LIB="$DIR/bin/lib/main-red-queue-attr.sh"
[ -s "$FX/queue-2026-10-02.json" ] && [ -s "$FX/main-2026-10-02.json" ] && [ -s "$ATTR/log-36969794399.txt" ] || {
  echo "FAIL: the bh-3886 fixtures are missing"; exit 1; }
REG=$(rendered_registry)

NOW=$(date +%s)                     # the ONLY clock read in this file
SLUG=example-org/cromford
CUT=2026-10-02T06:01:00Z            # 3 independent reds counted; the greens of 05:54Z still running

# tree <dir> — a scratch harness root around the REAL detector, with the REAL
# attribution lib installed (C6 removes it).
tree() {
  mkdir -p "$1/bin/lib" "$1/logs" "$1/state" "$1/flags" "$1/locks" "$1/env" "$1/fakebin" "$1/ledger"
  cp "$DIR/bin/main-red-detector.sh" "$1/bin/main-red-detector.sh"
  cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/lane-gate.sh" "$1/bin/lib/"
  cp "$DIR/bin/lib/main-red-queue-attr.sh" "$1/bin/lib/"
  : > "$1/env/global.env"
  cat > "$1/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
  chmod +x "$1/bin/lane-alert.sh"
  # The coordination-DB client: ledger verbs over files (every put logged),
  # /api/settings from $ROWS. LEDGER_DOWN=1 makes a get answer rc 1, unusable.
  cat > "$1/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/#' '-_')"; }
job_ledger_get() { [ -n "${LEDGER_DOWN:-}" ] && return 1; local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2; cat "$f"; return 0; }
job_ledger_put() { printf 'put %s %s %s\n' "$1" "$2" "$3" >> "$LEDGER_DIR.puts"; printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0; }
_jobs_req() {
  case "$2" in
    /api/settings)
      local out="[]" kv IFS=$'\n'
      for kv in ${ROWS:-}; do
        out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "$out" ;;
    *) return 1 ;;
  esac
}
SHIM
  # The gh fake: the pages through the -q filter the detector passed, the
  # failed-log of a run from $ATTR_DIR/log-<id>.txt, a PR's files from
  # $ATTR_DIR/files-<n>.txt. LOG_FAIL / FILES_FAIL name ids that answer rc 1;
  # LOG_EMPTY=1 answers rc 0 with nothing.
  cat > "$1/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
q=""; a=("$@"); for i in "${!a[@]}"; do [ "${a[$i]}" = -q ] && q="${a[$((i+1))]}"; done
case "$*" in
  "run view "*"--log-failed"*)
    id="$3"
    case " ${LOG_FAIL:-} " in *" $id "*) exit 1 ;; esac
    [ -n "${LOG_EMPTY:-}" ] && exit 0
    [ -f "$ATTR_DIR/log-$id.txt" ] || exit 1
    cat "$ATTR_DIR/log-$id.txt" ;;
  "api repos/"*"/pulls/"*"/files"*)
    n=$(printf '%s' "$2" | sed -E 's#.*/pulls/([0-9]+)/files.*#\1#')
    case " ${FILES_FAIL:-} " in *" $n "*) exit 1 ;; esac
    [ -f "$ATTR_DIR/files-$n.txt" ] || exit 1
    cat "$ATTR_DIR/files-$n.txt" ;;
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/runs/"*"/jobs"*) exit 1 ;;
  *"event=pull_request"*) [ -s "$PAGES/queue.json" ] || exit 1; jq -c "$q" "$PAGES/queue.json" ;;
  *"actions/runs"*)       [ -s "$PAGES/main.json" ]  || exit 1; jq -c "$q" "$PAGES/main.json" ;;
  *) echo "" ;;
esac
SHIM
  chmod +x "$1/fakebin/gh"
}
R="$T/r"
tree "$R"
PAGES="$T/pages"; mkdir -p "$PAGES"

# page <queue|main> <cut-iso> — the fixture runs whose updated_at <= cut, every
# timestamp shifted by ONE offset (05:53:34Z lands one minute before NOW).
page() {
  python3 - "$FX/$1-2026-10-02.json" "$2" "$NOW" "$PAGES/$1.json" <<'PY'
import calendar, json, sys, time
src, cut, now, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
P = lambda s: calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
F = lambda e: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))
off = now - 60 - P("2026-10-02T05:53:34Z")
runs = [r for r in json.load(open(src))["workflow_runs"] if P(r["updated_at"]) <= P(cut)]
for r in runs:
    r["created_at"] = F(P(r["created_at"]) + off); r["updated_at"] = F(P(r["updated_at"]) + off)
json.dump({"workflow_runs": runs}, open(out, "w"))
PY
}
page main "$CUT"; page queue "$CUT"

# drive — one tick of the detector; its rc in $DRC.
drive() {
  ( export PATH="$R/fakebin:$PATH" HARNESS="$R" PAGES="$PAGES" GH_SINK="$R/gh.txt" LANE_REGISTRY="$REG" \
           ALERT_SINK="$R/alerts.txt" PUBLISH_SINK="$R/publish.txt" LEDGER_DIR="$R/ledger" ROWS="${ROWS:-}" \
           ATTR_DIR="${ATTR_DIR:-$ATTR}" MAIN_RED_QUEUE_REPOS="$SLUG"; unset GH_TOKEN
    bash "$R/bin/main-red-detector.sh" "$SLUG" >/dev/null 2>>"$R/err.txt" ); DRC=$?
}
# reset [lib] — a clean tree, with that lib installed (default the real one;
# `none` installs nothing).
reset() {
  local p lib="${1:-$LIB}"
  for p in ledger state/main-red state/lane-gate state/settings-cache.json; do scratch_rm "$R/$p" || exit 1; done
  mkdir -p "$R/ledger"
  rm -f "$R"/flags/main-red-* "$R/ledger.puts" "$R/bin/lib/main-red-queue-attr.sh"
  [ "$lib" = none ] || cp "$lib" "$R/bin/lib/main-red-queue-attr.sh"
  : > "$R/alerts.txt"; : > "$R/gh.txt"; : > "$R/logs/main-red.log"; : > "$R/publish.txt"; : > "$R/err.txt"
  ROWS=""
}
FLAG="$R/flags/main-red-example-org-cromford"
LOG="$R/logs/main-red.log"
VERDICT="$R/state/main-red/example-org-cromford.verdict"
fl()   { sed -n "s/^$1=//p" "$FLAG" 2>/dev/null | head -1; }
row()  { cat "$R/ledger/main_red_qattr__example-org-cromford_$1" 2>/dev/null; }
reads(){ grep -c -- "$1" "$R/gh.txt" 2>/dev/null; }

# lcall <lib> <args...> — mrqa_attr sourced on its own, the way the detector
# sources it: log() and the ledger verbs defined, the fake gh on PATH. Prints
# "<verdict>|<pr>|<why>"; its gh calls land in $T/lgh.txt.
lcall() {
  local lib="$1"; shift
  ( export PATH="$R/fakebin:$PATH" GH_SINK="$T/lgh.txt" LEDGER_DIR="$T/lledger" ATTR_DIR="${ATTR_DIR:-$ATTR}"
    log() { printf '%s\n' "$*" >> "$T/llog.txt"; }
    EXPLAIN=0
    . "$R/bin/jobs-client.sh"
    . "$lib"
    mrqa_attr "$@" </dev/null
    printf '%s|%s|%s\n' "$MRQA_VERDICT" "$MRQA_PR" "$MRQA_WHY" )
}
lreset() { scratch_rm "$T/lledger" || exit 1; mkdir -p "$T/lledger"; : > "$T/lgh.txt"; : > "$T/llog.txt"; }

# mutant <name> <sed-script> — a copy of the lib with one behaviour broken. A
# sed that changes nothing is a FAIL of its own (a mutation check that mutates
# nothing proves nothing).
mutant() {
  local out="$T/mut-$1.sh"
  sed -e "$2" "$LIB" > "$out"
  if cmp -s "$LIB" "$out"; then bad "$1: the mutation changed nothing in the lib"; return 1; fi
  printf '%s\n' "$out"
}

# ── Header: the gh-identity line the ratchet reads.
[ "$(sed -n 2p "$LIB")" = "# gh-identity: raw-by-design — sourced by bin/main-red-detector.sh after it has armed the repo's identity (gh_default_auth_for_slug); minting a second token here would override it" ] && ok \
  || bad "header: line 2 must be the ticket's gh-identity line: $(sed -n 2p "$LIB")"

# ── C1. the incident.
c1() { # c1 <lib> — rc 0 when the incident does NOT freeze
  reset "$1"; drive; [ ! -f "$FLAG" ]
}
if c1 "$LIB"; then ok; else bad "C1: 36969794399 attributed leaves two reds — no flag ($(cat "$FLAG" 2>/dev/null | tr '\n' ' '); log=$(tail -5 "$LOG"))"; fi
[ "$(grep -c '^--critical' "$R/alerts.txt")" = 0 ] && [ ! -s "$R/alerts.txt" ] && ok || bad "C1: no alert: $(cat "$R/alerts.txt")"
[ "$(grep -cE "queue batch 36969794399 .* attributed to #3881, not counted toward main-red — .*bin/lib/mc-foreign-red.sh" "$LOG")" = 1 ] && ok \
  || bad "C1: one log line names #3881 and the path: $(grep 'queue batch' "$LOG")"
grep -q '^decision=red' "$VERDICT" 2>/dev/null && bad "C1: the verdict must not be red: $(cat "$VERDICT")" || ok
[ -s "$VERDICT" ] && ok || bad "C1: a verdict file is written"
[ "$(row 36969794399)" = "own pr=3881 path=bin/lib/mc-foreign-red.sh" ] && ok || bad "C1: ledger row for 36969794399: '$(row 36969794399)'"
[ "$(row 36967597297)" = untouched ] && [ "$(row 36966459398)" = untouched ] && ok \
  || bad "C1: the other two are cached untouched: '$(row 36967597297)' '$(row 36966459398)'"
grep -q 'pulls/3881/files.*--paginate' "$R/gh.txt" && grep -q 'run view 36969794399 -R example-org/cromford --log-failed' "$R/gh.txt" && ok \
  || bad "C1: the failed-log and the paginated PR file list are read: $(grep -E 'log-failed|pulls' "$R/gh.txt")"
grep -q 'unbound variable' "$R/err.txt" && bad "C1: set -u tripped: $(cat "$R/err.txt")" || ok
# M1: the lib always answers untouched — the incident freezes again.
if M=$(mutant M1 's/^mrqa_attr() {$/mrqa_attr() { MRQA_VERDICT=untouched; MRQA_PR=""; MRQA_WHY=""; return 0;/'); then
  c1 "$M" && bad "M1: a lib that always says untouched must let the freeze up" || ok
fi

# ── C2. the knob at 0.
reset; ( export MAIN_RED_QUEUE_ATTR=0; drive )
{ [ "$(fl reason)" = queue ] && [ "$(fl streak)" = 3 ] && [ "$(reads log-failed)" = 0 ]; } && ok \
  || bad "C2: knob 0 — the freeze is up (reason=queue streak=3) and no log is read (flag=$(cat "$FLAG" 2>/dev/null | tr '\n' ' '); reads=$(reads log-failed))"

# ── C3. a failed-log read: unreadable, counted, logged, never cached.
c3() { # c3 <lib> — rc 0 when the failed read leaves the freeze up
  reset "$1"; ( export LOG_FAIL=36969794399; drive ); [ -f "$FLAG" ] && [ "$(fl streak)" = 3 ]
}
if c3 "$LIB"; then ok; else bad "C3: an unreadable batch stays counted (flag=$(cat "$FLAG" 2>/dev/null | tr '\n' ' '))"; fi
grep -q "$SLUG: queue batch 36969794399 attribution unreadable (.*) — it stays counted" "$LOG" && ok \
  || bad "C3: the unreadable batch is logged: $(grep -i unreadable "$LOG")"
[ -z "$(row 36969794399)" ] && ! grep -q 36969794399 "$R/ledger.puts" 2>/dev/null && ok || bad "C3: unreadable is never cached: '$(row 36969794399)'"
if M=$(mutant M2 's/_mrqa_fail "the failed-log read answered rc $rc"; return 0;/MRQA_VERDICT=own; MRQA_PR="${prs[0]}"; MRQA_WHY=mutant; return 0;/'); then
  c3 "$M" && bad "M2: a read failure answered as own must take the freeze down" || ok
fi
# C3b. a log over the cap.
reset; ( export FLAKY_LOG_MAX=1000; drive )
{ [ -f "$FLAG" ] && [ "$(fl streak)" = 3 ] && [ "$(grep -oE 'queue batch [0-9]+ attribution unreadable \(the failed-log is [0-9]+ bytes, over FLAKY_LOG_MAX 1000\)' "$LOG" | sort -u | wc -l)" = 3 ] && [ -z "$(ls "$R/ledger")" ]; } && ok \
  || bad "C3b: every log over FLAKY_LOG_MAX is unreadable and the freeze is up (log=$(grep -i attribution "$LOG"))"
# C3c. an empty log (rc 0, no bytes).
lreset; out=$( export LOG_EMPTY=1; lcall "$LIB" "$SLUG" 36969794399 3882 3855 3881 )
{ [ "${out%%|*}" = unreadable ] && [ -z "$(ls "$T/lledger")" ]; } && ok || bad "C3c: an empty log is unreadable and not cached: $out"
# C3d. one PR's file list unreadable.
reset; ( export FILES_FAIL=3881; drive )
{ [ -f "$FLAG" ] && [ "$(fl streak)" = 3 ] && grep -q 'queue batch 36969794399 attribution unreadable' "$LOG" && [ -z "$(row 36969794399)" ]; } && ok \
  || bad "C3d: a PR file list that cannot be read is unreadable (flag=$( [ -f "$FLAG" ] && echo up); log=$(grep -i attribution "$LOG"))"

# ── C4. the second tick answers from the ledger.
c4() { # c4 <lib> — rc 0 when tick 2 reads nothing and still has no flag
  reset "$1"; drive; : > "$R/gh.txt"; drive
  [ "$(reads log-failed)" = 0 ] && [ "$(reads 'pulls/.*/files')" = 0 ] && [ ! -f "$FLAG" ]
}
if c4 "$LIB"; then ok; else bad "C4: tick 2 reads no log and no PR files (log reads=$(reads log-failed); file reads=$(reads 'pulls/.*/files'); flag=$( [ -f "$FLAG" ] && echo up))"; fi
grep -q 'attributed to #3881, not counted toward main-red — cached: #3881 changes bin/lib/mc-foreign-red.sh' "$LOG" && ok \
  || bad "C4: the cached verdict says so: $(grep 'queue batch' "$LOG" | tail -1)"
if M=$(mutant M3 's/job_ledger_put "$MRQA_KIND"/true "$MRQA_KIND"/'); then
  c4 "$M" && bad "M3: with no cache write tick 2 must read again" || ok
fi
# C4b. the ledger unusable on tick 2: it reads again, same verdict.
reset; drive; : > "$R/gh.txt"; ( export LEDGER_DOWN=1; drive )
{ [ "$(reads log-failed)" = 3 ] && [ ! -f "$FLAG" ]; } && ok \
  || bad "C4b: a ledger that answers rc 1 is re-read, same verdict (log reads=$(reads log-failed); flag=$( [ -f "$FLAG" ] && echo up))"

# ── C5a. a PR path on a non-failure line does not attribute (real data).
[ "$(grep -c 'bin/test-impact-gate.sh' "$ATTR/log-36966459398.txt")" -gt 0 ] && grep -qx bin/test-impact-gate.sh "$ATTR/files-3873.txt" && ok \
  || bad "C5a precondition: the real 36966459398 log names #3873's bin/test-impact-gate.sh somewhere"
c5a() { lreset; [ "$(lcall "$1" "$SLUG" 36966459398 3873 | cut -d'|' -f1)" = untouched ]; }
if c5a "$LIB"; then ok; else bad "C5a: 36966459398 vs #3873 is untouched: $(lcall "$LIB" "$SLUG" 36966459398 3873)"; fi
if M=$(mutant M4 's/grep -aE -- "$MRQA_FAIL_RE"/cat/'); then
  c5a "$M" && bad "M4: reading every line must attribute 36966459398 to #3873" || ok
fi

# ── C5b. exact equality, both directions. The log is the real `raw gh call`
# line with its path rewritten by sed — the shape production prints.
SYN="$T/syn"; mkdir -p "$SYN"
RAWLINE=$(grep -m1 'mc-foreign-red.sh:270 raw gh call' "$ATTR/log-36969794399.txt")
[ -n "$RAWLINE" ] && ok || bad "C5b precondition: the real raw gh call line"
sed 's#bin/lib/mc-foreign-red.sh#tests/foo-test.sh#' <<<"$RAWLINE" > "$SYN/log-1001.txt"
sed 's#bin/lib/mc-foreign-red.sh#tests/foo-test.sh.bak#' <<<"$RAWLINE" > "$SYN/log-1002.txt"
echo tests/foo-test.sh.bak > "$SYN/files-11.txt"
echo tests/foo-test.sh > "$SYN/files-12.txt"
c5b()  { lreset; [ "$( export ATTR_DIR="$SYN"; lcall "$1" "$SLUG" 1001 11 | cut -d'|' -f1)" = untouched ]; }
c5br() { lreset; [ "$( export ATTR_DIR="$SYN"; lcall "$1" "$SLUG" 1002 12 | cut -d'|' -f1)" = untouched ]; }
if c5b "$LIB"; then ok; else bad "C5b: failing tests/foo-test.sh vs a PR changing tests/foo-test.sh.bak is untouched"; fi
if c5br "$LIB"; then ok; else bad "C5b reverse: failing tests/foo-test.sh.bak vs a PR changing tests/foo-test.sh is untouched"; fi
# the positive control: the same synthetic line against the exact path IS own.
lreset; [ "$( export ATTR_DIR="$SYN"; lcall "$LIB" "$SLUG" 1001 12)" = "own|12|$(sed -E 's/^[^\t]*\t[^\t]*\t//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z ?//; s/^[[:space:]]+//' <<<"$RAWLINE" | sed 's#bin/lib/mc-foreign-red.sh#tests/foo-test.sh#' | cut -c1-160) (#12 changes tests/foo-test.sh)" ] && ok \
  || bad "C5b control: an exact path is own, with the excerpt in WHY: $( export ATTR_DIR="$SYN"; lreset; lcall "$LIB" "$SLUG" 1001 12)"
if M=$(mutant M5 's/grep -Fxq -- "$p"/grep -Fq -- "$p"/'); then
  c5b "$M" && bad "M5: a substring match must attribute foo-test.sh to a PR changing foo-test.sh.bak" || ok
fi
if M=$(mutant M6 's#\[A-Za-z0-9_.\\/-\]+(:\[0-9\]+)?#[A-Za-z0-9_.\\/-]+\\.(sh|js|mjs|ts|py|json|yml|yaml|sql|md)#'); then
  c5br "$M" && bad "M6: backtracking token extraction must read foo-test.sh.bak as foo-test.sh" || ok
fi

# ── C5c. only this batch's PRs.
c5c() { lreset; [ "$(lcall "$1" "$SLUG" 36969794399 3882 3855 | cut -d'|' -f1)" = untouched ]; }
if c5c "$LIB"; then ok; else bad "C5c: 36969794399 without #3881 is untouched"; fi
grep -q 'pulls/3881/files' "$T/lgh.txt" && bad "C5c: #3881's files must not be read: $(grep pulls "$T/lgh.txt")" || ok
if M=$(mutant M7 's/local -a prs=("$@")/local -a prs=("$@" 3881)/'); then
  c5c "$M" && bad "M7: a foreign batch's PR in the list must attribute" || ok
fi

# ── C6. the lib absent: today's behaviour.
reset none; drive
{ [ "$DRC" = 0 ] && [ "$(fl reason)" = queue ] && [ "$(fl streak)" = 3 ] \
  && [ "$(grep -c 'attribution is off: bin/lib/main-red-queue-attr.sh is not installed' "$LOG")" = 1 ] \
  && [ "$(reads log-failed)" = 0 ]; } && ok \
  || bad "C6: no lib — rc 0, freeze up with streak=3, one 'attribution is off', no log read (rc=$DRC; flag=$(cat "$FLAG" 2>/dev/null | tr '\n' ' '))"

echo "main-red-queue-attr.bh-3886: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
