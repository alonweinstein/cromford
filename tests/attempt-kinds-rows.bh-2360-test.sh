#!/bin/bash
# tests/attempt-kinds-rows.bh-2360-test.sh — BH-2360 (BH-2311.3): the
# conductor, queue and tier2 call-site kinds go through the BH-2311.0 verbs.
#
# WHY. `red`, `mergifyhold`, `mergefail`, the eject strikes and the tier2
# `aeskip`/`aewould` lines grepped and appended $MC_ATTEMPTS by hand. The
# writes among them never reached the pr_attempts row twin. Through the verbs
# (mc_attempt_count / _lines / _put_n / _has / _put) the file bytes and every
# count stay what they were with pr-state-rows DOWN, and with it UP those
# writes become rows too.
#
# WHAT IT PINS.
#   R  red: mc_attempt_count red KEY counts every head of KEY, the same as the
#      old grep, and not KEY0's lines or a `redx` kind.
#   F  mergefail: count 0, 1, 2 across two put_n; a longer head is not the head.
#   E  mc_eject_strikes, both branches, equals the pre-BH-2360 function on the same
#      ledger; a missing ledger is 0; no temp file is left; an ejectconflict on
#      another PR's head cancels nothing.
#   T  tier2 _ae_skip through the REAL verbs: once per line, flag down and up.
#   D  flag down, one scripted sequence against the pre-BH-2360 libs and today's
#      writes a byte-identical attempts.txt.
#   U  flag up: aeskip / aewould / mergefail / mergifyhold reach the worker as
#      pr-attempts PUTs. U2: the worker answers 500 — the file line is still
#      written, _ae_once still answers rc 0 the first time, the latch logs once.
#   M  the REAL bin/merge-conductor.sh, twice, on a Mergify PR whose queue never
#      answers (enqueue rc 3): one then two `mergifyhold` lines, the "for 1 held
#      tick(s)" throttle line, byte-identical to the pre-BH-2360 conductor flag
#      down, and
#      a `mergifyhold` PUT flag up. Then a no-queue repo whose merge fails
#      twice, and a native-queue repo whose enqueue fails twice: two
#      `mergefail` lines each, attempt 1 then 2, handed on at the second.
#   G  static exact allowlist: the only direct $MC_ATTEMPTS access left in the
#      three files is the identityalert block.
#
# THE BASELINE IS REBUILT, NOT FETCHED. "pre-BH-2360" is today's file with
# exactly the BH-2360 call-site text put back (old_tree below), each swap
# asserted to apply its expected number of times. origin/main is not used: the
# impact gate runs a git-less snapshot, and after the merge origin/main IS this
# change, so a comparison against it would pass by construction.
# BH2360_BASE_SRC (default: this checkout) names the tree the baseline's three
# files are copied from, so a mutation run can break today's files and still
# compare them against an unbroken baseline.
#
# Run from anywhere: tests/attempt-kinds-rows.bh-2360-test.sh  (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers it from list.json.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# Real-shaped keys and heads (D4): <owner/repo>#<n> and 40-hex shas.
K=example-org/x-os#12; K0=example-org/x-os#120
HA=1111111111111111111111111111111111111111
HB=2222222222222222222222222222222222222222
HC=3333333333333333333333333333333333333333
HAX=${HA}0   # a longer "head" that must not count as HA

# ── the pre-BH-2360 call sites ───────────────────────────────────────────────
# swap <file> <want-count> <new-text> <old-text> — put the old text back.
swap() {
  local n
  n=$(NEW="$3" OLD="$4" perl -0777 -i -pe '$c = s/\Q$ENV{NEW}\E/$ENV{OLD}/g; print STDERR ($c + 0), "\n"' "$1" 2>&1 >/dev/null)
  [ "$n" = "$2" ] || { echo "FAIL: baseline: '${3%%$'\n'*}' in ${1##*/} replaced $n time(s), want $2 — the BH-2360 call site moved; update old_tree"; exit 1; }
}
BASE_SRC="${BH2360_BASE_SRC:-$DIR}"
old_tree() { # old_tree <harness-dir> — the three files from BASE_SRC, BH-2360 text reverted
  local d="$1" f
  for f in bin/merge-conductor.sh bin/lib/mc/queue.sh bin/lib/autoenqueue.sh; do cp "$BASE_SRC/$f" "$d/$f" || exit 1; done
  swap "$d/bin/merge-conductor.sh" 1 'REDS=$(mc_attempt_count red "$KEY")' 'REDS=$(grep -c "^red $KEY " "$MC_ATTEMPTS" || true)'
  swap "$d/bin/merge-conductor.sh" 1 'HELDN=$(mc_attempt_count mergifyhold "$KEY" "$HEAD")' 'HELDN=$(grep -c "^mergifyhold $KEY $HEAD\$" "$MC_ATTEMPTS" 2>/dev/null)'
  swap "$d/bin/merge-conductor.sh" 2 'mc_attempt_put_n mergifyhold "$KEY" "$HEAD"' 'echo "mergifyhold $KEY $HEAD" >> "$MC_ATTEMPTS"'
  swap "$d/bin/merge-conductor.sh" 2 'N=$(mc_attempt_count mergefail "$KEY" "$HEAD"); mc_attempt_put_n mergefail "$KEY" "$HEAD"' \
    'N=$(grep -c "^mergefail $KEY $HEAD" "$MC_ATTEMPTS" || true); echo "mergefail $KEY $HEAD" >> "$MC_ATTEMPTS"'
  swap "$d/bin/lib/mc/queue.sh" 1 '#   verbatim. An unreadable file counts 0, as the grep did.
#   Both reads go through the attempt verbs (BH-2360); the awk runs over the
#   lines mc_attempt_lines copies out, in file order.
mc_eject_strikes() {
  if [ "${MC_EJECT_REBASE:-}" = 0 ]; then
    mc_attempt_count "ejected|reejected" "$1"
    return 0
  fi
  local t
  t=$(mktemp "${TMPDIR:-/tmp}/mc-eject.XXXXXX") || { echo 0; return 0; }
  mc_attempt_lines "ejected|reejected|ejectconflict" "$1" "$t"
  awk' '#   verbatim. An unreadable file counts 0, as the grep did.
mc_eject_strikes() {
  if [ "${MC_EJECT_REBASE:-}" = 0 ]; then
    grep -cE "^(ejected|reejected) $1 " "$MC_ATTEMPTS" || true
    return 0
  fi
  awk'
  swap "$d/bin/lib/mc/queue.sh" 1 'print n }'"'"' "$t" 2>/dev/null || echo 0
  rm -f "$t"
}' 'print n }'"'"' "$MC_ATTEMPTS" 2>/dev/null || echo 0
}'
  swap "$d/bin/lib/autoenqueue.sh" 1 '# Through mc_attempt_has / mc_attempt_put (BH-2360), which bin/lib/mc/locks.sh
# defines: merge-conductor.sh sources merge-conductor-lib.sh before this file.
_ae_once() {
  local line="$*"
  mc_attempt_has "$line" 2>/dev/null && return 1
  mc_attempt_put "$line"
}' '_ae_once() {
  local line="$*"
  grep -qxF "$line" "$MC_ATTEMPTS" 2>/dev/null && return 1
  echo "$line" >> "$MC_ATTEMPTS"
}'
}

# ── the lib trees: BR = today's files, MN = the pre-BH-2360 call sites ───────
mk_lib_tree() { # mk_lib_tree <dest> <branch|main>
  local d="$1" f
  mkdir -p "$d/bin/lib/jobs" "$d/bin/lib/mc" "$d/env" "$d/flags" "$d/logs" "$d/state/merge-conductor"
  cp "$DIR/bin/jobs-client.sh" "$d/bin/" || exit 1
  cp "$DIR"/bin/lib/jobs/*.sh "$d/bin/lib/jobs/" || exit 1
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/autoenqueue.sh" "$d/bin/lib/" || exit 1
  cp "$DIR"/bin/lib/mc/*.sh "$d/bin/lib/mc/" || exit 1
  if [ "$2" = main ]; then old_tree "$d"; rm -f "$d/bin/merge-conductor.sh"; fi
}
BR="$T/br"; MN="$T/mn"
mk_lib_tree "$BR" branch; mk_lib_tree "$MN" main
mkdir -p "$T/fakebin"
REQ="$T/req.log"; ERR="$T/err.log"; : > "$REQ"; : > "$ERR"

# The worker shim: logs "METHOD URL BODY". /api/flags/* 404 (the flag FILE
# decides). pr-attempts is the real route's contract over a row store,
# $REQ_LOG.rows: PUT stores (deduped on repo/number/kind/sha); a GET with a sha
# is 200 for a stored row, else 404; a GET without one is ALWAYS 200 with
# {attempts, count}, newest first — a list 404 is an outage to pr_attempt_list
# (BH-2357), which would latch the twin off. $ROWS_MODE=down answers 500 to
# every pr-attempts call. Everything else 404 (ledger PUTs 200).
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary|-d|--data) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w|-o) shift 2;;
    -*) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
case "$URL" in
  */api/flags/*) printf '{"error":"no such flag"}\n404\n' ;;
  */api/pr-attempts*)
    if [ "${ROWS_MODE:-miss}" = down ]; then printf '{"error":"boom"}\n500\n'; exit 0; fi
    ROWS="${REQ_LOG:-/dev/null}.rows"; touch "$ROWS"
    dec() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
    repo=""; num=""; kind=""; sha=""
    if [ -n "$BODY" ]; then
      repo=$(jq -r .repo <<<"$BODY"); num=$(jq -r .number <<<"$BODY")
      kind=$(jq -r .kind <<<"$BODY"); sha=$(jq -r .sha <<<"$BODY")
    else
      q="${URL#*\?}"; [ "$q" = "$URL" ] && q=""
      IFS='&' read -r -a kv <<<"$q"
      for p in "${kv[@]}"; do
        v=$(dec "${p#*=}")
        case "${p%%=*}" in repo) repo="$v" ;; number) num="$v" ;; kind) kind="$v" ;; sha) sha="$v" ;; esac
      done
    fi
    row=$(printf '%s\t%s\t%s\t%s' "$repo" "$num" "$kind" "$sha")
    if [ "$METHOD" = PUT ]; then
      grep -qxF "$row" "$ROWS" || printf '%s\n' "$row" >> "$ROWS"
      printf '{"ok":true}\n200\n'
    elif [ -n "$sha" ]; then
      if grep -qxF "$row" "$ROWS"; then printf '{"ok":true}\n200\n'; else printf '{"error":"no row"}\n404\n'; fi
    else
      awk -F'\t' -v r="$repo" -v n="$num" -v k="$kind" '$1==r && $2==n && (k=="" || $3==k) {print $4}' "$ROWS" \
        | tac | jq -Rsc 'split("\n") | map(select(. != "")) | {attempts: map({sha: .}), count: length}'
      printf '200\n'
    fi ;;
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
chmod +x "$T/fakebin/curl"

cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 91
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/autoenqueue.sh" >/dev/null 2>&1 || exit 92
eval "$DRIVE_CODE"
DRV

drv() { # drv <tree> <code>
  env DRIVE_CODE="$2" ROWS_MODE="${ROWS_MODE:-miss}" \
    PATH="$T/fakebin:$PATH" HARNESS="$1" HARNESS_SECRET=x JOBS_BOX=testbox \
    JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" \
    bash "$T/drive.sh" 2>>"$ERR"
}
att() { printf '%s/state/merge-conductor/attempts.txt' "$1"; }
reset() { # reset <tree> [flag-up]
  : > "$REQ"; rm -f "$REQ.rows"; : > "$ERR"; : > "$(att "$1")"; : > "$1/logs/merge-conductor.log"
  rm -f "$1/flags/pr-state-rows"; [ "${2:-}" = up ] && : > "$1/flags/pr-state-rows"
  return 0
}
nput_kind() { grep "^PUT http://jobs.test/api/pr-attempts" "$REQ" 2>/dev/null | grep -c "\"kind\":\"$1\"" || true; }
nreq() { grep -c "^$1 http://jobs.test/api/pr-attempts" "$REQ" 2>/dev/null || true; }

echo "== R. red counts every head of KEY, nothing else =="
reset "$BR"
printf '%s\n' "red $K $HA" "red $K $HB" "red $K0 $HA" "redx $K $HC" "requeued $K $HA" "identityalert example-org/x-os pat 2026-09-27" > "$(att "$BR")"
OUT=$(drv "$BR" "mc_attempt_count red '$K'")
OLD=$(grep -c "^red $K " "$(att "$BR")" || true)
[ "$OUT" = 2 ] && ok || bad "R: mc_attempt_count red KEY must be 2 (two heads), got '$OUT'"
[ "$OUT" = "$OLD" ] && ok || bad "R: the verb ($OUT) and the old grep ($OLD) disagree on a real-shaped ledger"

echo "== F. mergefail: 0, 1, 2 on one head; a longer head is another head =="
reset "$BR"
echo "mergefail $K $HAX" > "$(att "$BR")"
OUT=$(drv "$BR" "n0=\$(mc_attempt_count mergefail '$K' '$HA'); mc_attempt_put_n mergefail '$K' '$HA'
  n1=\$(mc_attempt_count mergefail '$K' '$HA'); mc_attempt_put_n mergefail '$K' '$HA'
  n2=\$(mc_attempt_count mergefail '$K' '$HA'); echo \"\$n0 \$n1 \$n2\"")
[ "$OUT" = "0 1 2" ] && ok || bad "F: mergefail counts must be '0 1 2', got '$OUT'"
[ "$(grep -cxF "mergefail $K $HA" "$(att "$BR")")" = 2 ] && ok || bad "F: two exact mergefail lines expected: $(cat "$(att "$BR")")"

echo "== E. mc_eject_strikes equals the pre-BH-2360 function, both branches =="
EJ="ejected $K $HA
reejected $K $HB
ejectconflict $K $HB
ejected $K0 $HC
ejectconflict $K0 $HA
identityalert example-org/x-os pat 2026-09-27"
for tree in "$BR" "$MN"; do reset "$tree"; printf '%s\n' "$EJ" > "$(att "$tree")"; done
TMPD="$T/tmpd"; mkdir -p "$TMPD"
S_BR=$(TMPDIR="$TMPD" drv "$BR" "mc_eject_strikes '$K'; MC_EJECT_REBASE=0 mc_eject_strikes '$K'" | tr '\n' ' ')
S_MN=$(TMPDIR="$TMPD" drv "$MN" "mc_eject_strikes '$K'; MC_EJECT_REBASE=0 mc_eject_strikes '$K'" | tr '\n' ' ')
[ "$S_BR" = "1 2 " ] && ok || bad "E: want default 1 (HB cancelled by its own ejectconflict; K0's conflict on HA cancels nothing) and REBASE=0 2, got '$S_BR'"
[ "$S_BR" = "$S_MN" ] && ok || bad "E: branch '$S_BR' != pre-BH-2360 '$S_MN' on the same ledger"
rm -f "$(att "$BR")"
S_MISS=$(TMPDIR="$TMPD" drv "$BR" "mc_eject_strikes '$K'; MC_EJECT_REBASE=0 mc_eject_strikes '$K'" | tr '\n' ' ')
[ "$S_MISS" = "0 0 " ] && ok || bad "E: a missing ledger must read 0 on both branches, got '$S_MISS'"
LEFT=$(find "$TMPD" -name 'mc-eject.*' | wc -l | tr -d ' ')
[ "$LEFT" = 0 ] && ok || bad "E: $LEFT mc-eject temp file(s) left behind"

echo "== T. tier2 _ae_skip once per line, through the real verbs =="
reset "$BR"
AE="_ae_skip '$K' '$HA' verdict 'not approved'; echo rc=\$?; _ae_skip '$K' '$HA' verdict 'not approved'; echo rc=\$?"
OUT=$(drv "$BR" "$AE" | tr '\n' ' ')
[ "$OUT" = "rc=0 rc=0 " ] && ok || bad "T: _ae_skip rc: $OUT $(cat "$ERR")"
[ "$(grep -cxF "aeskip $K $HA verdict" "$(att "$BR")")" = 1 ] && ok || bad "T: exactly one aeskip line: $(cat "$(att "$BR")")"
[ "$(grep -c "AUTOENQUEUE $K not enqueued" "$BR/logs/merge-conductor.log")" = 1 ] && ok || bad "T: exactly one refusal log line: $(cat "$BR/logs/merge-conductor.log")"
[ "$(nreq GET)$(nreq PUT)" = 00 ] && ok || bad "T: flag down makes no pr-attempts request: $(cat "$REQ")"
reset "$BR" up
drv "$BR" "$AE" >/dev/null
# Rows first (BH-2357): each call asks the row; the first misses and PUTs, the
# second finds that row. One GET per call, one PUT in all.
[ "$(nreq GET)" = 2 ] && ok || bad "T: flag up, each call asks the row once (GET), the second finds the first's row: $(cat "$REQ")"
[ "$(nput_kind aeskip)" = 1 ] && ok || bad "T: flag up, one PUT kind=aeskip: $(cat "$REQ")"
[ "$(grep -cxF "aeskip $K $HA verdict" "$(att "$BR")")" = 1 ] && ok || bad "T: flag up, still one file line: $(cat "$(att "$BR")")"

echo "== D. flag down: the pre-BH-2360 libs and today's write the same bytes =="
SEQ="_ae_skip '$K' '$HA' verdict x; _ae_skip '$K' '$HA' verdict x; _ae_skip '$K' '$HB' ci y
  _ae_once aewould '$K' '$HA'; _ae_once aewould '$K' '$HA'
  echo \"strikes \$(mc_eject_strikes '$K') \$(MC_EJECT_REBASE=0 mc_eject_strikes '$K')\" >> \"\$MC_ATTEMPTS.out\""
for tree in "$BR" "$MN"; do reset "$tree"; printf '%s\n' "$EJ" > "$(att "$tree")"; : > "$(att "$tree").out"; drv "$tree" "$SEQ" >/dev/null; done
cmp -s "$(att "$BR")" "$(att "$MN")" && ok || bad "D: attempts.txt differs from pre-BH-2360: $(diff "$(att "$MN")" "$(att "$BR")")"
cmp -s "$(att "$BR").out" "$(att "$MN").out" && ok || bad "D: counts differ from pre-BH-2360: $(cat "$(att "$MN").out") vs $(cat "$(att "$BR").out")"
[ "$(grep -c '^ae' "$(att "$BR")")" = 3 ] && ok || bad "D: the sequence must write 3 ae lines (non-vacuous): $(cat "$(att "$BR")")"

echo "== U. flag up: the bypassing kinds become rows =="
reset "$BR" up
drv "$BR" "_ae_skip '$K' '$HA' verdict x; _ae_once aewould '$K' '$HA'
  mc_attempt_put_n mergefail '$K' '$HA'; mc_attempt_put_n mergifyhold '$K' '$HA'" >/dev/null
for k in aeskip aewould mergefail mergifyhold; do
  [ "$(nput_kind "$k")" = 1 ] && ok || bad "U: one PUT with kind=$k expected: $(cat "$REQ")"
done

echo "== U2. flag up, worker down: the file still carries it, latched once =="
reset "$BR" up
OUT=$(ROWS_MODE=down drv "$BR" "MC_TICK_ID=t-u2; _ae_once aeskip '$K' '$HA' verdict; echo rc=\$?
  _ae_once aeskip '$K' '$HB' verdict; echo rc=\$?" | tr '\n' ' ')
[ "$OUT" = "rc=0 rc=0 " ] && ok || bad "U2: an outage is 'not attempted' — both first calls rc 0, got '$OUT'"
[ "$(grep -c '^aeskip ' "$(att "$BR")")" = 2 ] && ok || bad "U2: both file lines written despite the outage: $(cat "$(att "$BR")")"
[ "$(grep -c 'row reads/writes latched off' "$BR/logs/merge-conductor.log")" = 1 ] && ok || bad "U2: the latch is logged exactly once: $(cat "$BR/logs/merge-conductor.log")"
[ "$(nreq GET)" = 1 ] && ok || bad "U2: after the trip no further row call is made (GETs: $(nreq GET)): $(cat "$REQ")"

# ════════════════════════════════════════════════════════════════════════════
# M. The REAL bin/merge-conductor.sh (tests/conductor-gates.bh-2199-test.sh's
#    G4/G5 fixture: a Mergify repo whose queue never answers), plus a no-queue
#    repo whose `gh pr merge` fails.
# ════════════════════════════════════════════════════════════════════════════
MHEAD=aaaaaaaa00000000000000000000000000000041
PHEAD=bbbbbbbb00000000000000000000000000000051
QHEAD=cccccccc00000000000000000000000000000061
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')
mk_ctree() { # mk_ctree <dest> <branch|main>
  local d="$1"
  mkdir -p "$d/bin/lib/mc" "$d/bin/lib/jobs" "$d/logs" "$d/state" "$d/flags" "$d/locks" "$d/builds" "$d/env" "$d/tmp"
  cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" \
     "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$DIR/bin/lib/block-gate.sh" "$d/bin/lib/"
  cp "$DIR"/bin/lib/mc/*.sh "$d/bin/lib/mc/"
  cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$d/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$d/bin/lib/jobs/"
  cp "$DIR/bin/merge-conductor.sh" "$d/bin/merge-conductor.sh"
  if [ "$2" = main ]; then old_tree "$d"; rm -f "$d/bin/lib/autoenqueue.sh"; fi
  printf 'mgfy example-org/mgfy-os - - 2 box-m\nplain example-org/plain-os - - 2 box-m\nqueued example-org/queued-os - - 2 box-m\n' > "$d/fleet.conf"
  : > "$d/env/global.env"
  printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$d/bin/agent-call.sh"
  for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$d/bin/$s.sh"; done
  chmod +x "$d"/bin/*.sh
  local rec
  rec="$d/builds/pool-mgfy-MG-41-202609270041"; mkdir -p "$rec"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/41" > "$rec/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$rec/review.md"; echo "$MHEAD" > "$rec/reviewed-sha"; : > "$rec/pipeline.log"
  rec="$d/builds/pool-plain-PL-51-202609270051"; mkdir -p "$rec"
  echo "PR_CREATED https://github.com/example-org/plain-os/pull/51" > "$rec/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$rec/review.md"; echo "$PHEAD" > "$rec/reviewed-sha"; : > "$rec/pipeline.log"
  rec="$d/builds/pool-queued-QU-61-202609270061"; mkdir -p "$rec"
  echo "PR_CREATED https://github.com/example-org/queued-os/pull/61" > "$rec/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$rec/review.md"; echo "$QHEAD" > "$rec/reviewed-sha"; : > "$rec/pipeline.log"
  touch "$d/flags/merge-conductor-actions" "$d/flags/merge-conductor-merge" "$d/labels-41" "$d/labels-51" "$d/labels-61"
}
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The gh stub: Mergify repo mgfy-os (PR 41) answers no check run ever (the
# queue is silent), plain-os (PR 51) has no queue, queued-os (PR 61) has
# GitHub's native queue (a merge_queue ruleset rule), and every `gh pr merge`
# fails with the PR left open. $OPEN names which repo's PR is listed.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$CT/gh-calls.txt"
case "\$*" in
  *mgfy-os*) HEAD=$MHEAD; N=41 ;;
  *queued-os*) HEAD=$QHEAD; N=61 ;;
  *) HEAD=$PHEAD; N=51 ;;
esac
LBL=\$(tr '\n' ',' < "\$CT/labels-\$N" 2>/dev/null | sed 's/,\$//')
Q=""; prev=""; for a in "\$@"; do [ "\$prev" = -q ] && Q="\$a"; prev="\$a"; done
fx() { if [ -n "\$Q" ]; then printf '%s\n' "\$1" | jq -r "\$Q"; else printf '%s\n' "\$1"; fi; }
case "\$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "api -X GET repos/"*"/reviews"*) fx '[]' ;;
  "api -X GET repos/"*"/pulls/"*) fx "{\"number\":\$N,\"base\":{\"ref\":\"main\"}}" ;;
  *"api -i -X GET repos/example-org/queued-os/rulesets/9"*)
    restpr --raw 200 '{"id":9,"enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"merge_queue"}]}' ;;
  *"api -i -X GET repos/example-org/queued-os/rulesets"*) restpr --raw 200 '[{"id":9,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/"*"/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/"*"/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 '{"check_runs":[]}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) : ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "\$CT/label-adds.txt"; printf 'merge-queue\n' >> "\$CT/labels-\$N"; sort -u -o "\$CT/labels-\$N" "\$CT/labels-\$N" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "\$CT/merge-calls.txt"; echo "GraphQL: Base branch was modified (mergePullRequest)" >&2; exit 1 ;;
  *"pr comment"*) : ;;
  *v3.diff*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*) restpr OPEN "\$HEAD" "ticket/x-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open","number":'"\$N"'}' ;;
  *"api repos/example-org/"*" -q .id"*) echo 1 ;;
  *"pr list -R example-org/\$OPEN --state open"*) cat "\$CT/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

list_for() { # list_for <tree> <slug> <n> <head>
  local lbl="[]" csv
  csv=$(tr '\n' ',' < "$1/labels-$3" 2>/dev/null | sed 's/,$//')
  [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
  printf '[{"number":%s,"url":"https://github.com/example-org/%s/pull/%s","headRefOid":"%s","headRefName":"ticket/x-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s}]\n' \
    "$3" "$2" "$3" "$4" "$3" "$lbl" > "$1/list.json"
}
ctick() { # ctick <tree> <repo> — one real conductor tick, only <repo>'s PR open
  local n=41 h=$MHEAD
  case "$2" in plain-os) n=51; h=$PHEAD ;; queued-os) n=61; h=$QHEAD ;; esac
  list_for "$1" "$2" "$n" "$h"
  ( cd "$1" && PATH="$T/fakebin:$PATH" HARNESS="$1" FLEET_CONF="$1/fleet.conf" HARNESS_SECRET=x CT="$1" OPEN="$2" \
    REQ_LOG="$1/req.log" ROWS_MODE=miss JOBS_URL=http://jobs.test JOBS_RETRIES=0 JOBS_ALERT=0 \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    bash "$1/bin/merge-conductor.sh" >/dev/null 2>"$1/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$1/tick.err"; }
}
CB="$T/cb"; CM="$T/cm"; CU="$T/cu"
mk_ctree "$CB" branch; mk_ctree "$CM" main; mk_ctree "$CU" branch
: > "$CU/flags/pr-state-rows"
MK=example-org/mgfy-os#41; PK=example-org/plain-os#51; QK=example-org/queued-os#61

echo "== M. real conductor ticks: mergifyhold =="
for tree in "$CB" "$CM" "$CU"; do ctick "$tree" mgfy-os; done
CATT="$CB/state/merge-conductor/attempts.txt"
[ "$(grep -cxF "mergifyhold $MK $MHEAD" "$CATT" 2>/dev/null)" = 1 ] && ok || bad "M: tick 1 writes exactly one mergifyhold line: $(cat "$CATT" 2>/dev/null); log: $(tail -5 "$CB/logs/merge-conductor.log")"
for tree in "$CB" "$CM" "$CU"; do ctick "$tree" mgfy-os; done
[ "$(grep -cxF "mergifyhold $MK $MHEAD" "$CATT")" = 2 ] && ok || bad "M: tick 2 reads HELDN=1 and appends a second line: $(cat "$CATT")"
grep -q "$MK MERGE_HELD: the mergify queue has acknowledged nothing at ${MHEAD:0:8} for 1 held tick(s)" "$CB/logs/merge-conductor.log" && ok \
  || bad "M: tick 2 logs the throttle line for 1 held tick: $(grep -F '#41' "$CB/logs/merge-conductor.log" | tail -3)"
[ "$(grep -c 'issues/41/labels' "$CB/label-adds.txt" 2>/dev/null)" = 1 ] && ok || bad "M: the throttled tick asks nothing (asks: $(cat "$CB/label-adds.txt" 2>/dev/null))"
cmp -s "$CATT" "$CM/state/merge-conductor/attempts.txt" && ok || bad "M: flag down the branch's attempts.txt differs from the pre-BH-2360 conductor: $(diff "$CM/state/merge-conductor/attempts.txt" "$CATT")"
[ "$(grep "^PUT http://jobs.test/api/pr-attempts" "$CB/req.log" 2>/dev/null | grep -c .)" = 0 ] && ok || bad "M: flag down makes no pr-attempts PUT: $(grep pr-attempts "$CB/req.log")"
N_UP=$(grep "^PUT http://jobs.test/api/pr-attempts" "$CU/req.log" 2>/dev/null | grep -c '"kind":"mergifyhold"')
[ "$N_UP" = 2 ] && ok || bad "M: flag up, each held tick PUTs a mergifyhold row (got $N_UP): $(grep pr-attempts "$CU/req.log" 2>/dev/null)"
cmp -s "$CATT" "$CU/state/merge-conductor/attempts.txt" && ok || bad "M: flag up writes the same file lines: $(diff "$CATT" "$CU/state/merge-conductor/attempts.txt")"

echo "== M. real conductor ticks: mergefail on a no-queue repo =="
for tree in "$CB" "$CM" "$CU"; do ctick "$tree" plain-os; done
[ "$(grep -cxF "mergefail $PK $PHEAD" "$CATT")" = 1 ] && ok || bad "M: merge failure 1 writes one mergefail line: $(cat "$CATT"); log: $(grep -F '#51' "$CB/logs/merge-conductor.log" | tail -3)"
grep -q "$PK merge FAILED (GraphQL: Base branch was modified (mergePullRequest)) attempt 1" "$CB/logs/merge-conductor.log" && ok || bad "M: attempt 1 logged: $(grep -F '#51' "$CB/logs/merge-conductor.log" | tail -3)"
for tree in "$CB" "$CM" "$CU"; do ctick "$tree" plain-os; done
[ "$(grep -cxF "mergefail $PK $PHEAD" "$CATT")" = 2 ] && ok || bad "M: merge failure 2 writes a second mergefail line: $(cat "$CATT")"
grep -q "$PK merge FAILED (GraphQL: Base branch was modified (mergePullRequest)) attempt 2" "$CB/logs/merge-conductor.log" && ok || bad "M: attempt 2 logged: $(grep -F '#51' "$CB/logs/merge-conductor.log" | tail -3)"
grep -q "$PK BLOCKED_AGENT merge-failed-twice" "$CB/logs/merge-conductor.log" && ok || bad "M: the second failure hands the PR on: $(grep -F '#51' "$CB/logs/merge-conductor.log" | tail -3)"
cmp -s "$CATT" "$CM/state/merge-conductor/attempts.txt" && ok || bad "M: flag down, mergefail bytes differ from the pre-BH-2360 conductor: $(diff "$CM/state/merge-conductor/attempts.txt" "$CATT")"
N_UP=$(grep "^PUT http://jobs.test/api/pr-attempts" "$CU/req.log" 2>/dev/null | grep '"kind":"mergefail"' | grep -c '"number":51')
[ "$N_UP" = 2 ] && ok || bad "M: flag up, each merge failure PUTs a mergefail row (got $N_UP)"

echo "== M. real conductor ticks: mergefail on a native-queue enqueue =="
for tree in "$CB" "$CM" "$CU"; do ctick "$tree" queued-os; done
[ "$(grep -cxF "mergefail $QK $QHEAD" "$CATT")" = 1 ] && ok || bad "M: enqueue failure 1 writes one mergefail line: $(cat "$CATT"); log: $(grep -F '#61' "$CB/logs/merge-conductor.log" | tail -3)"
grep -q "$QK enqueue FAILED on the github queue (GraphQL: Base branch was modified (mergePullRequest)) attempt 1" "$CB/logs/merge-conductor.log" && ok || bad "M: enqueue attempt 1 logged: $(grep -F '#61' "$CB/logs/merge-conductor.log" | tail -3)"
for tree in "$CB" "$CM" "$CU"; do ctick "$tree" queued-os; done
[ "$(grep -cxF "mergefail $QK $QHEAD" "$CATT")" = 2 ] && ok || bad "M: enqueue failure 2 writes a second mergefail line: $(cat "$CATT")"
grep -q "$QK enqueue FAILED on the github queue (GraphQL: Base branch was modified (mergePullRequest)) attempt 2" "$CB/logs/merge-conductor.log" && ok || bad "M: enqueue attempt 2 logged: $(grep -F '#61' "$CB/logs/merge-conductor.log" | tail -3)"
grep -q "$QK BLOCKED_AGENT queue-enqueue-failed-twice" "$CB/logs/merge-conductor.log" && ok || bad "M: the second enqueue failure hands the PR on: $(grep -F '#61' "$CB/logs/merge-conductor.log" | tail -3)"
cmp -s "$CATT" "$CM/state/merge-conductor/attempts.txt" && ok || bad "M: flag down, enqueue mergefail bytes differ from the pre-BH-2360 conductor: $(diff "$CM/state/merge-conductor/attempts.txt" "$CATT")"
N_UP=$(grep "^PUT http://jobs.test/api/pr-attempts" "$CU/req.log" 2>/dev/null | grep '"kind":"mergefail"' | grep -c '"number":61')
[ "$N_UP" = 2 ] && ok || bad "M: flag up, each enqueue failure PUTs a mergefail row (got $N_UP)"

echo "== G. static guard: only the identityalert block touches \$MC_ATTEMPTS directly =="
GOT=$(cd "$DIR" && cat bin/merge-conductor.sh bin/lib/mc/queue.sh bin/lib/autoenqueue.sh \
  | grep -vE '^[[:space:]]*#' | grep -E '\$\{?MC_ATTEMPTS' | sed -E 's/^[[:space:]]+//' | sort)
WANT=$(printf '%s\n' \
  'grep -qxF "identityalert $SLUG $MC_IDENTITY_WORD $IDDAY" "$MC_ATTEMPTS" 2>/dev/null && exit 0' \
  'echo "identityalert $SLUG $MC_IDENTITY_WORD $IDDAY" >> "$MC_ATTEMPTS"; printf 1' \
  ') 9>>"$MC_ATTEMPTS.lock" 2>/dev/null )' | sort)
[ "$(printf '%s\n' "$GOT" | grep -c .)" = 3 ] && ok || bad "G: want exactly 3 direct \$MC_ATTEMPTS lines, got $(printf '%s\n' "$GOT" | grep -c .):
$GOT"
[ "$GOT" = "$WANT" ] && ok || bad "G: direct \$MC_ATTEMPTS access outside the identityalert allowlist:
$(diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT"))"

echo "attempt-kinds-rows.bh-2360-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
