#!/bin/bash
# tests/pr-dep-gate-memo.bh-1735-test.sh — BH-1735: the dep gate's reads go
# through the quota-gated, ledgered gh_rest reader, and under a conductor tick
# a dependency issue is read ONCE per tick however many PRs name it.
#
# THE COST. Every lane calls pdg_hold inside `$(...)`, so _PDG_MEMO dies with
# each PR: N held PRs naming #612 paid N reads of #612 on every 5-minute tick,
# through raw `gh api`, which the quota gate never saw and the GitHub-call
# ledger never recorded.
#
# WHAT IS ASSERTED. pdg_hold is driven the way bin/merge-conductor.sh drives
# it: one `bash -u` process per PR, `X=$(pdg_hold …)`, MC_TICK_ID exported, the
# real merge-conductor-lib.sh and gh-rest.sh out of a fixture tree. The claims
# are counted on the fake gh's call log and on the ledger gh_rest writes to
# $HARNESS/state/gh-rest-ledger/ — never on source text.
#
# Every fixture value is a literal. Nothing here reads the wall clock, rolls a
# random number or sleeps; the reset in case H is a literal far-future epoch.
# Run from anywhere: tests/pr-dep-gate-memo.bh-1735-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LOG="$T/h/logs/pr-dep-gate.log"
LED="$T/h/state/gh-rest-ledger"
TICKDIR="$T/h/state/merge-conductor/tick"

mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state/merge-conductor" "$T/fakebin" "$T/answers" "$T/prbody" "$T/lists"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/pr-dep-gate.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" \
   "$DIR/bin/lib/gh-rest-ledger.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
: > "$T/gh-calls.txt"

# The fake gh answers only gh_rest's shape (`api -i -X GET <path>`) with a whole
# HTTP response. Issue answers live in $T/answers/<owner>-<repo>-<n>; an absent
# file is a 404. PR bodies live in $T/prbody/<n>. Anything else fails.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
HDR='X-RateLimit-Remaining: 4000\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Resource: core\r\n'
# \$T/lowquota: every answer reports a drained bucket on a window that has not
# reset, so each read's own reading keeps the persisted one below the reserve.
[ -e "$T/lowquota" ] && HDR='X-RateLimit-Remaining: 10\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Reset: 4102444800\r\nX-RateLimit-Resource: core\r\n'
case "\$*" in
  # BH-1678's Order lists, read through gh-rest-list.sh's paging shape
  # (\`api -i -X GET repos/<slug>/<issues|pulls> -f state=open …\`), answered
  # from \$T/lists/<issues|pulls>.json as one page; \$T/lists/fail makes it a 502.
  "api -i -X GET repos/"*"/issues -f "*|"api -i -X GET repos/"*"/pulls -f "*)
    case "\$5" in */issues) L=issues ;; *) L=pulls ;; esac
    if [ -e "$T/lists/fail" ]; then printf "HTTP/1.1 502 Bad Gateway\r\n\$HDR\r\n"; printf '{"message":"Bad Gateway"}'
    else printf "HTTP/1.1 200 OK\r\n\$HDR\r\n"; cat "$T/lists/\$L.json"; fi
    exit 0 ;;
  "api -i -X GET repos/"*"/issues/"*)
    P=\${5#repos/}; S=\${P%/issues/*}; N=\${P##*/}
    F="$T/answers/\${S//\//-}-\$N"
    if [ -f "\$F" ]; then printf "HTTP/1.1 200 OK\r\n\$HDR\r\n"; cat "\$F"
    else printf "HTTP/1.1 404 Not Found\r\n\$HDR\r\n"; printf '{"message":"Not Found"}'; fi
    exit 0 ;;
  "api -i -X GET repos/"*"/pulls/"*)
    N=\${5##*/}
    printf "HTTP/1.1 200 OK\r\n\$HDR\r\n"; jq -Rs '{body: .}' "$T/prbody/\$N"
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

issue() { # issue <owner-repo> <n> <open|closed> [merged_at]
  if [ "$3" = open ]; then printf '{"number":%s,"state":"open"}\n' "$2" > "$T/answers/$1-$2"
  else printf '{"number":%s,"state":"closed","pull_request":{"merged_at":"%s"}}\n' "$2" "${4:-2026-09-23T00:00:00Z}" > "$T/answers/$1-$2"; fi
}
body() { printf 'A change.\nDepends on #%s\n' "$2" > "$T/prbody/$1"; }
calls() { tr '\n' '|' < "$T/gh-calls.txt"; }
ncalls() { grep -c -- "$1" "$T/gh-calls.txt"; }
ledrows() { cat "$LED"/*.tsv 2>/dev/null | awk -F'\t' -v c="$1" -v s="${2:-}" '$5==c && (s=="" || $6==s)' | wc -l | tr -d ' '; }
reset() { : > "$T/gh-calls.txt"; : > "$LOG"; scratch_rm "$LED"; }
# memos <tick> — the tick's pdg-issue memo files, NOT their .lock files: a lock
# is taken before the read, so it exists even when nothing may be stored.
memos() { find "$TICKDIR" -maxdepth 1 -name "$1.memo-pdg-issue-*" ! -name '*.lock' ! -name '*.tmp.*' 2>/dev/null; }

# pr <slug> <num> [VAR=VAL ...] — the conductor's call shape, in its own process.
# Prints "<num> rc=<rc>".
pr() {
  local slug="$1" num="$2"; shift 2
  env HARNESS="$T/h" GH_ETAG=0 GH_TOKEN= "$@" bash -u -c \
    '. "$HARNESS/bin/lib/merge-conductor-lib.sh"
     X=$(pdg_hold "$1" "$2" "https://github.com/$1/pull/$2" ""); echo "$2 rc=$?"' \
    bash "$slug" "$num" 2>>"$T/allstderr"
}

# ══ A. one read per distinct issue per tick, and every read is ledgered ═════
reset
issue o-r 612 open; issue o-r 700 open
for n in 41 42 43 44; do body "$n" 612; done
for n in 45 46; do body "$n" 700; done
for n in 41 42 43 44 45 46; do pr o/r "$n" MC_TICK_ID=t1 > "$T/a-$n.out" & done
wait
for n in 41 42 43 44 45 46; do
  grep -qx "$n rc=0" "$T/a-$n.out" && ok || bad "A: PR $n must HOLD (rc 0), got '$(cat "$T/a-$n.out")'"
done
[ "$(ncalls 'issues/612')" = 1 ] && ok || bad "A: THE DEFECT — #612 read $(ncalls 'issues/612') times across 4 concurrent PRs in one tick, want 1: $(calls)"
[ "$(ncalls 'issues/700')" = 1 ] && ok || bad "A: #700 read $(ncalls 'issues/700') times across 2 concurrent PRs, want 1: $(calls)"
[ "$(grep -c '^api repos/' "$T/gh-calls.txt")" = 0 ] && ok || bad "A: a raw gh api read bypassed gh_rest: $(calls)"
[ "$(ledrows repos/o/r/issues/N 200)" = 2 ] && ok || bad "A: ledger must carry 2 issue rows (status 200), got $(ledrows repos/o/r/issues/N): $(cat "$LED"/*.tsv 2>/dev/null)"
[ "$(ledrows repos/o/r/pulls/N 200)" = 6 ] && ok || bad "A: ledger must carry 6 pulls rows (status 200), got $(ledrows repos/o/r/pulls/N)"
[ "$(grep -c 'open dependency .* — HOLD' "$LOG")" = 6 ] && ok || bad "A: six HOLD lines, got: $(cat "$LOG")"
[ "$(memos t1 | wc -l)" = 2 ] && ok || bad "A: one memo per issue at tick_memo_file pdg-issue …: $(ls "$TICKDIR" 2>&1)"
# The same six again, SEQUENTIALLY, in the same tick: a subshell call is a hit.
: > "$T/gh-calls.txt"
for n in 41 42 43 44 45 46; do pr o/r "$n" MC_TICK_ID=t1 > "$T/a2-$n.out"; done
[ "$(ncalls 'issues/')" = 0 ] && ok || bad "A: THE DEFECT — a later PR in the same tick re-read an issue: $(calls)"
for n in 41 42 43 44 45 46; do
  grep -qx "$n rc=0" "$T/a2-$n.out" && ok || bad "A: PR $n from memo must still HOLD, got '$(cat "$T/a2-$n.out")'"
done

# ══ B. a new tick re-reads ═════════════════════════════════════════════════
reset
issue o-r 612 closed
OUT=$(pr o/r 41 MC_TICK_ID=t2)
[ "$OUT" = "41 rc=1" ] && ok || bad "B: a closed #612 in a new tick passes (rc 1), got '$OUT' — the memo outlived its tick?"
[ "$(ncalls 'issues/612')" = 1 ] && ok || bad "B: a new tick must read #612 once, got: $(calls)"

# ══ C. a failed read is never memoised ═════════════════════════════════════
reset
rm -f "$T/answers/o-r-612"
OUT=$(pr o/r 41 MC_TICK_ID=t3)
[ "$OUT" = "41 rc=2" ] && ok || bad "C: an unreadable #612 is rc 2, got '$OUT'"
[ -n "$(memos t3)" ] && bad "C: a failed read left a memo file: $(ls "$TICKDIR")" || ok
[ "$(ledrows repos/o/r/issues/N 404)" = 1 ] && ok || bad "C: the 404 must be ledgered too: $(cat "$LED"/*.tsv 2>/dev/null)"
issue o-r 612 open
OUT=$(pr o/r 42 MC_TICK_ID=t3)
[ "$OUT" = "42 rc=0" ] && ok || bad "C: after the answer appears, same tick, PR 42 HOLDs, got '$OUT'"
[ "$(ncalls 'issues/612')" = 2 ] && ok || bad "C: the failed read must not be served from memo — want 2 reads, got: $(calls)"

# ══ D. MC_READ_MEMO=0 is the kill switch ═══════════════════════════════════
reset
for n in 41 42 43; do pr o/r "$n" MC_TICK_ID=t4 MC_READ_MEMO=0 > /dev/null; done
[ "$(ncalls 'issues/612')" = 3 ] && ok || bad "D: MC_READ_MEMO=0 must read every time — want 3, got: $(calls)"
[ -n "$(find "$TICKDIR" -maxdepth 1 -name "t4.*" 2>/dev/null)" ] && bad "D: MC_READ_MEMO=0 wrote a memo or lock file: $(ls "$TICKDIR")" || ok

# ══ E. outside a conductor tick nothing is memoised, but reads are ledgered ═
reset
scratch_rm "$TICKDIR"
for n in 41 42; do pr o/r "$n" MC_TICK_ID= > "$T/e-$n.out"; done
[ "$(ncalls 'issues/612')" = 2 ] && ok || bad "E: no tick id = today's per-shell behaviour, want 2 reads, got: $(calls)"
[ -n "$(ls -A "$TICKDIR" 2>/dev/null)" ] && bad "E: no tick id must write nothing under $TICKDIR: $(ls "$TICKDIR")" || ok
[ "$(ledrows repos/o/r/issues/N 200)" = 2 ] && ok || bad "E: both reads are ledgered outside the conductor too, got $(ledrows repos/o/r/issues/N)"
grep -qx '41 rc=0' "$T/e-41.out" && ok || bad "E: PR 41 HOLDs, got '$(cat "$T/e-41.out")'"

# ══ F. the repo is in the key, and a torn memo file is a miss ══════════════
reset
issue o-s 612 closed
OUT=$(pr o/r 41 MC_TICK_ID=t5); [ "$OUT" = "41 rc=0" ] && ok || bad "F: o/r#612 is open → HOLD, got '$OUT'"
OUT=$(pr o/s 41 MC_TICK_ID=t5); [ "$OUT" = "41 rc=1" ] && ok || bad "F: o/s#612 is closed → pass, got '$OUT' (served o/r's answer?)"
[ "$(ncalls 'repos/o/r/issues/612')" = 1 ] && [ "$(ncalls 'repos/o/s/issues/612')" = 1 ] && ok \
  || bad "F: one read per repo, got: $(calls)"
for f in "$TICKDIR"/t5.memo-pdg-issue-o_r_612-*; do printf 'garbage\n' > "$f"; done
: > "$T/gh-calls.txt"
OUT=$(pr o/r 42 MC_TICK_ID=t5); [ "$OUT" = "42 rc=0" ] && ok || bad "F: a torn memo must not change the answer, got '$OUT'"
[ "$(ncalls 'repos/o/r/issues/612')" = 1 ] && ok || bad "F: a torn memo is a miss → one fresh read, got: $(calls)"

# ══ H. the reserve gate never refuses the merge gate ═══════════════════════
# A persisted reading far below the reserve, on a window that has not reset
# (a literal far-future epoch). A lane that exported GH_REST_OPTIONAL=1 must
# still have its dependency read: the merge gate is decision-critical.
reset
mkdir -p "$LED"
printf '10 5000 4102444800 4102444000\n' > "$LED/.quota-pat-default"
OUT=$(pr o/r 41 MC_TICK_ID=t6 GH_REST_OPTIONAL=1 GH_QUOTA_RESERVE=600)
[ "$OUT" = "41 rc=0" ] && ok || bad "H: THE DEFECT — the reserve gate refused a merge-gate read (got '$OUT', log: $(cat "$LOG"))"
[ "$(ncalls 'issues/612')" = 1 ] && ok || bad "H: the dependency must be read, got: $(calls)"

# ══ G. the ticket half (BH-1678): the Order lists and the issue body ═══════
# o/r becomes a GitHub-Issues board (fleet.conf column 4 = `-`). PRs 141/142
# close #41/#42, both `Part of #9` with `Order: 2 of 2`, so each pays for the
# linked issue's body and for the two sibling lists, all through gh_rest. #40 is the Order-1 sibling
# with an open PR and no conductor row, so nothing waits and both pass.
reset
printf 'demo o/r - - 2 box-demo\n' > "$T/h/fleet.conf"
tissue() { jq -nc --argjson n "$1" --arg b "$2" '{number:$n, state:"open", body:$b}' > "$T/answers/o-r-$1"; }
tissue 40 "$(printf 'Part of #9\nOrder: 1 of 2')"
tissue 41 "$(printf 'Part of #9\nOrder: 2 of 2')"
tissue 42 "$(printf 'Part of #9\nOrder: 2 of 2')"
jq -s . "$T/answers/o-r-40" "$T/answers/o-r-41" "$T/answers/o-r-42" > "$T/lists/issues.json"
printf '[{"number":140,"head":{"ref":"ticket/demo-40"},"body":"Closes #40"}]\n' > "$T/lists/pulls.json"
printf 'Closes #41\n' > "$T/prbody/141"; printf 'Closes #42\n' > "$T/prbody/142"
for n in 141 142; do pr o/r "$n" MC_TICK_ID=t7 > "$T/g-$n.out" & done
wait
for n in 141 142; do
  grep -qx "$n rc=1" "$T/g-$n.out" && ok || bad "G: PR $n passes (no sibling waiting), got '$(cat "$T/g-$n.out")' log: $(cat "$LOG")"
done
[ "$(ncalls 'repos/o/r/issues -f state=open')" = 1 ] && ok || bad "G: THE DEFECT — the sibling issue list was read $(ncalls 'repos/o/r/issues -f state=open') times by 2 PRs in one tick, want 1: $(calls)"
[ "$(ncalls 'repos/o/r/pulls -f state=open')" = 1 ] && ok || bad "G: THE DEFECT — the open-PR list was read $(ncalls 'repos/o/r/pulls -f state=open') times by 2 PRs in one tick, want 1: $(calls)"
[ "$(ncalls 'issues/41')" = 1 ] && [ "$(ncalls 'issues/42')" = 1 ] && ok || bad "G: one body read per linked issue: $(calls)"
[ "$(ledrows repos/o/r/issues/N 200)" = 2 ] && ok || bad "G: the linked-issue body reads are ledgered (want 2 rows), got $(ledrows repos/o/r/issues/N)"
[ "$(ledrows repos/o/r/issues 200)" = 1 ] && ok || bad "G: the sibling issue list is ledgered (want 1 row), got $(ledrows repos/o/r/issues): $(cat "$LED"/*.tsv 2>/dev/null)"
[ "$(ledrows repos/o/r/pulls 200)" = 1 ] && ok || bad "G: the open-PR list is ledgered (want 1 row), got $(ledrows repos/o/r/pulls): $(cat "$LED"/*.tsv 2>/dev/null)"
[ "$(ncalls '--paginate')" = 0 ] && ok || bad "G: a raw gh api --paginate list read bypassed gh_rest: $(calls)"
: > "$T/gh-calls.txt"
for n in 141 142; do pr o/r "$n" MC_TICK_ID=t7 > "$T/g2-$n.out"; done
[ "$(ncalls 'state=open')" = 0 ] && [ "$(ncalls 'issues/')" = 0 ] && ok || bad "G: a later PR in the same tick re-read a list or an issue: $(calls)"
grep -qx "141 rc=1" "$T/g2-141.out" && ok || bad "G: PR 141 from memo still passes, got '$(cat "$T/g2-141.out")'"
# A failed list read is never memoised: same tick, the next PR reads again.
reset
: > "$T/lists/fail"
OUT=$(pr o/r 141 MC_TICK_ID=t8); [ "$OUT" = "141 rc=2" ] && ok || bad "G: an unreadable sibling list is rc 2, got '$OUT'"
rm -f "$T/lists/fail"
OUT=$(pr o/r 142 MC_TICK_ID=t8); [ "$OUT" = "142 rc=1" ] && ok || bad "G: after the list answers, same tick, PR 142 passes, got '$OUT' (log: $(cat "$LOG"))"
[ "$(ncalls 'repos/o/r/issues -f state=open')" = 2 ] && ok || bad "G: the failed list read must not be served from memo — want 2 reads, got: $(calls)"
[ "$(ledrows repos/o/r/issues 502)" = 1 ] && ok || bad "G: the failed list read is ledgered too (want 1 row, status 502), got $(ledrows repos/o/r/issues 502)"
# Outside a tick the lists are read per shell, as before.
reset
for n in 141 142; do pr o/r "$n" MC_TICK_ID= > /dev/null; done
[ "$(ncalls 'repos/o/r/issues -f state=open')" = 2 ] && ok || bad "G: no tick id = one list read per shell, want 2, got: $(calls)"
# The reserve gate never refuses the list reads either (case H's reading,
# far below the reserve, with the lane's GH_REST_OPTIONAL=1 exported). The
# fake keeps answering a drained bucket, or the PR-body and issue reads that
# run first would refresh the reading above the reserve before the lists.
reset
mkdir -p "$LED"
printf '10 5000 4102444800 4102444000\n' > "$LED/.quota-pat-default"
: > "$T/lowquota"
OUT=$(pr o/r 141 MC_TICK_ID=t9 GH_REST_OPTIONAL=1 GH_QUOTA_RESERVE=600)
[ "$OUT" = "141 rc=1" ] && ok || bad "G: THE DEFECT — the reserve gate refused a sibling-list read (got '$OUT', log: $(cat "$LOG"))"
[ "$(ncalls 'repos/o/r/issues -f state=open')" = 1 ] && [ "$(ncalls 'repos/o/r/pulls -f state=open')" = 1 ] && ok \
  || bad "G: under a low reserve both lists must still be read, got: $(calls)"
rm -f "$T/lowquota"
rm -f "$T/h/fleet.conf"

grep -q 'unbound variable' "$T/allstderr" 2>/dev/null \
  && bad "set-u-clean: $(grep 'unbound variable' "$T/allstderr" | head -3)" || ok

echo "pr-dep-gate-memo.bh-1735: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
