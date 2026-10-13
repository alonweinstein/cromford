#!/bin/bash
# tests/fly-pool-pr-verify.bh-781-test.sh — the pool's reap-time PR_CREATED
# gate, now reading GitHub through bin/lib/gh-rest.sh, and the rule that has
# not changed since BH-709: A FAILED READ IS NEVER A STATE.
#
# WHAT BH-781 MOVED. The gate used to carry its own REST reader
# (`gh_rest_read` / `pr_state_rest`) and ask twice, with a sleep between the
# tries. The reader is now the fleet's one contract — `gh_rest_pr_state`, three
# exit codes — and the gate asks ONCE: rc 75 means "skip this tick, leave state
# exactly as it is", and the next `*/2` reap is the retry. The three answers the
# gate may give are:
#
#   rc 0  + open|merged  -> verified, RESULT untouched, nothing logged
#   rc 0  + closed       -> relabel RESULT_UNVERIFIED (a closed, unmerged PR)
#   rc 44 + repo 200     -> relabel RESULT_UNVERIFIED (no such PR)
#   rc 44 + repo 404     -> the 2026-09-12 INVISIBLE alert, RESULT as-is
#   rc 44 + repo 75      -> UNVERIFIABLE naming the PROBE's status, RESULT as-is
#   rc 75 / lib absent   -> RESULT byte-identical, exactly ONE gh_rest_alert
#
# HOW IT DRIVES: the gate is EXTRACTED VERBATIM from bin/fly-pool.sh by its
# `# >>>` / `# <<<` markers and run against a mktemp'd $HARNESS with a stub `gh`
# on PATH and the REAL bin/lib/gh-rest.sh sourced. Assertions are on artifacts —
# the bytes of $LOCAL/RESULT, the lines of ALERTS.log, the stub's invocation
# log. No network, no real box.
#
# Run from anywhere: tests/fly-pool-pr-verify.bh-781-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s)
PASS=0; FAIL=0
DRIVE_PATH_PREFIX=""
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive this gate"; exit 1; }

PRURL="https://github.com/example-org/cromford/pull/7"
SLUG="example-org/cromford"
# A recognisable fixture token. It is the AMBIENT credential here, the way a
# pool machine's env bundle hands one to the tick, so gh_rest_alert must label
# it `explicit` — and its VALUE must never reach a log.
TOKFIX="ghp_FIXTURE_BH781_do_not_ship"
LINE2='TIER: 2 | QA: manual — no browser on this box | migration: none'

# ── the production block, lifted verbatim ────────────────────────────────────
marked() { # marked <start> <end> <file>
  awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"
}
GATE="$T/gate.sh"; HELPERS="$T/helpers.sh"; VERIFY="$T/verify.sh"
marked '# >>> pr verify rest (BH-709)' '# <<< pr verify rest'   "$DIR/bin/fly-pool.sh" > "$HELPERS"
marked '# >>> pr verify gate (BH-709)' '# <<< pr verify gate'   "$DIR/bin/fly-pool.sh" > "$GATE"
marked '# >>> PR_CREATED verify'       '# <<< PR_CREATED verify' "$DIR/bin/fly-pool.sh" > "$VERIFY"
sed -n '/^STAMP() {/p;/^say() {/p' "$DIR/bin/fly-pool.sh" > "$T/saystamp.sh"

# ── the stub gh ──────────────────────────────────────────────────────────────
# Fixture-driven per PATH, with a per-path attempt counter so "the second read"
# is expressible. `<code>` on line 1, body from line 2 on. `none` = no status
# line at all (network, DNS, no gh); `empty` = a 200 whose body is empty.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
[ "${1:-}" = api ] || exit 1
P=""
for a in "$@"; do case "$a" in repos/*) P="$a" ;; esac; done
case "$P" in */pulls/*) K=pr ;; *) K=repo ;; esac
N=$(( $(cat "$CASE/$K.n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$N" > "$CASE/$K.n"
F="$CASE/$K-$N.resp"; [ -f "$F" ] || F=$(ls "$CASE"/$K-*.resp 2>/dev/null | tail -1)
[ -n "$F" ] && [ -f "$F" ] || exit 1
CODE=$(head -n 1 "$F"); BODY=$(tail -n +2 "$F")
[ "$CODE" = none ] && exit 1
if [ "$CODE" = empty ]; then CODE=200; BODY=""; fi
case "$CODE" in
  200) TXT="OK" ;; 404) TXT="Not Found" ;; 403) TXT="Forbidden" ;;
  429) TXT="Too Many Requests" ;; 500) TXT="Internal Server Error" ;;
  502) TXT="Bad Gateway" ;; *) TXT="Status" ;;
esac
case " $* " in
  *" -i "*) printf 'HTTP/2.0 %s %s\nx-stub: 1\n\n%s' "$CODE" "$TXT" "${BODY:+$BODY
}" ;;
  *) [ -n "$BODY" ] && printf '%s\n' "$BODY" ;;
esac
case "$CODE" in 2*) exit 0 ;; *) exit 1 ;; esac
STUB
chmod +x "$T/bin/gh"

# ── the driver: the real block, nothing restated ─────────────────────────────
cat > "$T/drive.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
LOG="$HARNESS/logs/fly-pool.log"
. "$SAYSTAMP"
RLINE=$(head -n 1 "$LOCAL/RESULT")
# shellcheck source=/dev/null
. "$HELPERS"
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
# shellcheck source=/dev/null
. "$GATE"
printf 'done\n' > "$CASE/drive.done"
DRIVE

resp() { printf '%s\n%s\n' "$2" "$3" > "$1"; }
newcase() { # newcase <name> — a fresh harness tree with a PR_CREATED RESULT
  CASE="$T/case-$1"; export CASE
  H="$CASE/harness"; LOCAL="$H/builds/pool-cromford-BH-781-$NOW"
  mkdir -p "$LOCAL" "$H/logs" "$H/env" "$H/flags" "$H/bin/lib"
  cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-app-auth.sh" \
     "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$H/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
  printf 'PR_CREATED %s\n%s\n' "$PRURL" "$LINE2" > "$LOCAL/RESULT"
  resp "$CASE/pr-1.resp"   200 '{"state":"open","merged_at":null}'
  resp "$CASE/repo-1.resp" 200 '{"id":42,"full_name":"example-org/cromford"}'
}
drive() {
  # DRIVE_PATH_PREFIX lets one case shadow a coreutil (C8 breaks mktemp) without
  # putting that stub in front of every other case's PATH.
  PATH="${DRIVE_PATH_PREFIX:+$DRIVE_PATH_PREFIX:}$T/bin:$PATH" \
    HARNESS="$H" LOCAL="$LOCAL" P=cromford KEY=BH-781 \
    GATE="${1:-$GATE}" HELPERS="${2:-$HELPERS}" SAYSTAMP="$T/saystamp.sh" \
    GH_TOKEN="$TOKFIX" bash "$T/drive.sh" >/dev/null 2>&1
}
line1()   { head -n 1 "$LOCAL/RESULT"; }
alerts()  { cat "$H/logs/ALERTS.log" 2>/dev/null; }
nalerts() { alerts | grep -c . ; }
calls()   { cat "$CASE/gh-calls.log" 2>/dev/null; }
prreads() { calls | grep -c '/pulls/' ; }

untouched() { # untouched <case> — the RESULT is exactly what the builder wrote
  [ "$(line1)" = "PR_CREATED $PRURL" ] && ok \
    || bad "$1: a real PR's RESULT was relabeled — line 1 is '$(line1)'"
  [ "$(sed -n 2p "$LOCAL/RESULT")" = "$LINE2" ] && ok \
    || bad "$1: line 2 of the RESULT did not survive byte-identical"
  [ "$(wc -l < "$LOCAL/RESULT")" = 2 ] && ok \
    || bad "$1: the RESULT grew or shrank: $(cat "$LOCAL/RESULT")"
}
one_unreadable() { # one_unreadable <status-or-reason> <case>
  [ "$(nalerts)" = 1 ] && ok || bad "$2: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
  alerts | grep -q 'unverifiable, left as-is this tick' && ok \
    || bad "$2: the alert must use the library's UNVERIFIABLE register: $(alerts)"
  alerts | grep -q -- "$1" && ok || bad "$2: the alert must name '$1': $(alerts)"
  alerts | grep -q 'token=explicit' && ok \
    || bad "$2: the alert must name WHICH identity answered: $(alerts)"
  grep -q 'no such PR' <<<"$(alerts)" && bad "$2: a failed read must never say 'no such PR'" || ok
  grep -q 'rewritten RESULT_UNVERIFIED' <<<"$(alerts)" \
    && bad "$2: an unreadable API must never claim the RESULT was rewritten" || ok
  grep -rq "$TOKFIX" "$H/logs" 2>/dev/null \
    && bad "$2: the token VALUE reached a log" || ok
}

# ══ H — the extraction itself (a suite that extracted nothing FAILS) ════════
[ -s "$GATE" ] && ok \
  || bad "H: could not extract the PR_CREATED gate from bin/fly-pool.sh (# >>> pr verify gate markers empty)"
[ -s "$VERIFY" ] && ok \
  || bad "H: bin/fly-pool.sh carries no '# >>> PR_CREATED verify' block — the ticket's marker is missing"
[ -s "$HELPERS" ] && ok \
  || bad "H: the '# >>> pr verify rest' block is empty — the gate sources no REST reader at all"
grep -q 'RLINE#PR_CREATED ' "$GATE" && ok \
  || bad "H: the extracted block is not the gate — its PR_CREATED entry condition is missing"
grep -q 'gh_rest_pr_state' "$VERIFY" && ok \
  || bad "H: the verify block does not read the PR through gh_rest_pr_state"
# (D5) The block may not describe a two-try GraphQL probe it no longer has.
for STALE in 'two attempts' 'gh pr view' 'POOL_PR_VERIFY_SLEEP' 'pr_state_rest' 'gh_rest_read'; do
  grep -q -- "$STALE" "$GATE" \
    && bad "H: the gate still describes or calls '$STALE', which BH-781 removed" || ok
done
grep -q -- 'POOL_PR_VERIFY_SLEEP' "$DIR/bin/fly-pool.sh" \
  && bad "H: POOL_PR_VERIFY_SLEEP is retired — bin/fly-pool.sh must not mention it" || ok

# ══ A — a verified OPEN PR: RESULT kept, one read, nothing logged ═══════════
newcase a
drive
untouched A
[ "$(nalerts)" = 0 ] && ok || bad "A: an OPEN PR must not alert: $(alerts)"
[ "$(prreads)" = 1 ] && ok || bad "A: the gate must read the PR exactly once, got $(prreads): $(calls)"
calls | grep -q -- '-i -X GET repos/example-org/cromford/pulls/7' && ok \
  || bad "A: the read must be the library's REST GET: $(calls)"

# ══ B — 404 on the PR, repo visible: the only shape that may relabel ════════
newcase b
resp "$CASE/pr-1.resp"   404 '{"message":"Not Found"}'
resp "$CASE/repo-1.resp" 200 '{"id":42}'
drive
[ "$(line1)" = "RESULT_UNVERIFIED PR_CREATED $PRURL" ] && ok \
  || bad "B: an affirmative 404 over a visible repo must relabel — line 1 is '$(line1)'"
[ "$(sed -n 2p "$LOCAL/RESULT")" = "$LINE2" ] && ok || bad "B: line 2 must survive byte-identical"
[ "$(nalerts)" = 1 ] && ok || bad "B: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
alerts | grep -q 'no such PR' && ok || bad "B: the relabel alert must say what GitHub answered: $(alerts)"
alerts | grep -q "$LOCAL" && ok || bad "B: the alert must name the build record: $(alerts)"

# ══ B2 — 404 on the PR and 404 on the repo: the 2026-09-12 invisible shape ══
newcase b2
resp "$CASE/pr-1.resp"   404 '{"message":"Not Found"}'
resp "$CASE/repo-1.resp" 404 '{"message":"Not Found"}'
cp "$LOCAL/RESULT" "$CASE/RESULT.before"
drive
cmp -s "$CASE/RESULT.before" "$LOCAL/RESULT" && ok \
  || bad "B2: an invisible repo must leave the RESULT byte-identical: $(cat "$LOCAL/RESULT")"
[ "$(nalerts)" = 1 ] && ok || bad "B2: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
alerts | grep -q 'INVISIBLE' && ok || bad "B2: the 2026-09-12 INVISIBLE wording must survive: $(alerts)"
grep -q 'RESULT_UNVERIFIED' <<<"$(alerts)" && bad "B2: an invisible repo must never relabel" || ok

# ══ B3 — 404 on the PR, 403 on the repo probe: UNVERIFIABLE, not INVISIBLE ══
# repo-1 is the seam's visibility probe (it answered, so an identity CAN see the
# repo); repo-2 is the gate's own 404-confirming read, and that one is refused.
newcase b3
resp "$CASE/pr-1.resp"   404 '{"message":"Not Found"}'
resp "$CASE/repo-1.resp" 200 '{"id":42}'
resp "$CASE/repo-2.resp" 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
cp "$LOCAL/RESULT" "$CASE/RESULT.before"
drive
cmp -s "$CASE/RESULT.before" "$LOCAL/RESULT" && ok \
  || bad "B3: a repo probe that itself failed must leave the RESULT byte-identical"
[ "$(nalerts)" = 1 ] && ok || bad "B3: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
alerts | grep -q 'HTTP 403' && ok \
  || bad "B3: the alert must name the PROBE's own status, not a guess: $(alerts)"
grep -q 'INVISIBLE' <<<"$(alerts)" \
  && bad "B3: a 403 on the repo probe is not proof the repo is invisible: $(alerts)" || ok

# ══ C — the read failed: RESULT byte-identical, exactly one alert ═══════════
unreadable() { # unreadable <case> <code> <body> <must-appear>
  newcase "$1"
  resp "$CASE/pr-1.resp" "$2" "$3"
  cp "$LOCAL/RESULT" "$CASE/RESULT.before"
  drive
  cmp -s "$CASE/RESULT.before" "$LOCAL/RESULT" && ok \
    || bad "$1: a failed read must leave the RESULT byte-identical: $(cat "$LOCAL/RESULT")"
  one_unreadable "$4" "$1"
}
unreadable C  403 '{"message":"API rate limit exceeded for user ID 2220366"}' 'HTTP 403'
alerts | grep -q '(rate-limit)' && ok || bad "C: a rate-limit 403 must be classified as one: $(alerts)"
unreadable C2 429 '{"message":"You have exceeded a secondary rate limit"}'     'HTTP 429'
unreadable C3 none ''                                                          'HTTP 000'
alerts | grep -q '(network)' && ok || bad "C3: a reader that answered nothing is a network failure: $(alerts)"
unreadable C4 empty ''                                                         'HTTP 200'
alerts | grep -q '(empty)' && ok || bad "C4: an empty body on a 2xx GET is never a state: $(alerts)"
unreadable C5 500 '<html><title>Server Error</title></html>'                   'HTTP 500'
unreadable C6 200 '{"nothing":"useful"}'                                       'HTTP 200'

# ══ C7 — the library is absent (a box mid-sync): fail-safe, never a relabel ══
newcase c7
rm -f "$H/bin/lib/gh-rest.sh"
cp "$LOCAL/RESULT" "$CASE/RESULT.before"
drive
cmp -s "$CASE/RESULT.before" "$LOCAL/RESULT" && ok \
  || bad "C7: with bin/lib/gh-rest.sh absent the RESULT must be byte-identical"
[ "$(nalerts)" = 1 ] && ok || bad "C7: a missing library must alert exactly once, got $(nalerts): $(alerts)"
[ "$(prreads)" = 0 ] && ok || bad "C7: with no library there is no read to make: $(calls)"

# ══ C8 — mktemp itself fails: still exactly ONE alert, never silence ════════
# The gate's read must go through a FILE (GH_REST_STATUS dies in a `$( )`), so a
# box that cannot mktemp cannot verify anything. That is rc 75 by another route
# and takes the rc-75 treatment: RESULT byte-identical, no read attempted, and
# ONE ALERTS line — a `say` to the pool log nobody greps is the same as silence,
# and the block comment, docs/verification-map/pr-verify-gate.md and the plan all
# promise an alert on EVERY unverifiable path.
newcase c8
mkdir -p "$T/nomktemp"
cat > "$T/nomktemp/mktemp" <<'MK'
#!/bin/bash
# Fails ONLY the gate's own template, so the case is about the gate's arm and
# not about breaking every helper that happens to want a temp file.
for a in "$@"; do case "$a" in *pool-prstate*) exit 1 ;; esac; done
for c in /usr/bin/mktemp /bin/mktemp; do [ -x "$c" ] && exec "$c" "$@"; done
exit 1
MK
chmod +x "$T/nomktemp/mktemp"
cp "$LOCAL/RESULT" "$CASE/RESULT.before"
DRIVE_PATH_PREFIX="$T/nomktemp" drive
DRIVE_PATH_PREFIX=""
cmp -s "$CASE/RESULT.before" "$LOCAL/RESULT" && ok \
  || bad "C8: a box that cannot mktemp must leave the RESULT byte-identical: $(cat "$LOCAL/RESULT")"
[ "$(prreads)" = 0 ] && ok || bad "C8: with no temp file there is no read to make: $(calls)"
[ "$(nalerts)" = 1 ] && ok || bad "C8: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
alerts | grep -q 'HTTP 000 (no-tmp)' && ok \
  || bad "C8: the alert must name why no request was made: $(alerts)"
alerts | grep -q 'unverifiable, left as-is this tick' && ok \
  || bad "C8: the alert must use the library's UNVERIFIABLE register: $(alerts)"
grep -q 'RESULT_UNVERIFIED' <<<"$(alerts)" \
  && bad "C8: a box that could not read must never claim a relabel: $(alerts)" || ok

# ══ D — a MERGED PR is a verified handoff (state closed + merged_at set) ════
newcase d
resp "$CASE/pr-1.resp" 200 '{"state":"closed","merged_at":"2026-09-18T08:39:44Z"}'
drive
untouched D
[ "$(nalerts)" = 0 ] && ok || bad "D: a MERGED PR must not alert: $(alerts)"

# ══ E — closed and unmerged: not a handoff, relabeled ══════════════════════
newcase e
resp "$CASE/pr-1.resp" 200 '{"state":"closed","merged_at":null}'
drive
[ "$(line1)" = "RESULT_UNVERIFIED PR_CREATED $PRURL" ] && ok \
  || bad "E: a closed, unmerged PR must be relabeled — line 1 is '$(line1)'"
[ "$(nalerts)" = 1 ] && ok || bad "E: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
alerts | grep -q 'CLOSED, unmerged PR' && ok || bad "E: the alert must say what GitHub answered: $(alerts)"

# ══ F — an already-relabeled RESULT: zero calls, zero writes (idempotence) ══
newcase f
printf 'RESULT_UNVERIFIED PR_CREATED %s\n%s\n' "$PRURL" "$LINE2" > "$LOCAL/RESULT"
cp "$LOCAL/RESULT" "$CASE/RESULT.before"
drive
cmp -s "$CASE/RESULT.before" "$LOCAL/RESULT" && ok || bad "F: a re-reap rewrote an already-relabeled RESULT"
[ -z "$(calls)" ] && ok || bad "F: a re-reap must ask GitHub nothing, called: $(calls)"
[ "$(nalerts)" = 0 ] && ok || bad "F: a re-reap must alert nothing: $(alerts)"

# ══ G — field 2 is not a PR url: the BH-765 shape branch, no credential ═════
newcase g
printf 'PR_CREATED  | SIZE: 614 product lines\n%s\n' "$LINE2" > "$LOCAL/RESULT"
drive
[ "$(line1)" = "RESULT_MALFORMED PR_CREATED  | SIZE: 614 product lines" ] && ok \
  || bad "G: a url-less PR_CREATED claim must be rewritten RESULT_MALFORMED — line 1 is '$(line1)'"
[ -z "$(calls)" ] && ok || bad "G: the shape branch must make no gh call at all, called: $(calls)"

# ══ I — mutation check (D1): each core arm, broken once ════════════════════
# 1. The rc-75 arm made to relabel: C must go red.
MUT="$T/gate-mut.sh"
sed 's/^          \*) _VUNREADABLE=1 ;;$/          *) _VRELABEL="mutant relabel" ;;/' "$GATE" > "$MUT"
if cmp -s "$GATE" "$MUT"; then
  bad "I: the rc-75 mutation matched nothing in the extracted gate — the mutation check is vacuous"
else
  newcase i1
  resp "$CASE/pr-1.resp" 403 '{"message":"API rate limit exceeded"}'
  drive "$MUT"
  [ "$(line1)" = "RESULT_UNVERIFIED PR_CREATED $PRURL" ] && ok \
    || bad "I: with the rc-75 arm mutated to relabel, case C's assertion did not go red — it proves nothing"
fi
# 2. The merged_at read removed from the library COPY the gate sources: D must
#    go red (a merged PR would read as plain `closed` and be relabeled).
newcase i2
resp "$CASE/pr-1.resp" 200 '{"state":"closed","merged_at":"2026-09-18T08:39:44Z"}'
sed -i 's/\.merged_at!=null/false/' "$H/bin/lib/gh-rest.sh"
if grep -q 'merged_at!=null' "$H/bin/lib/gh-rest.sh"; then
  bad "I: the merged_at mutation matched nothing in bin/lib/gh-rest.sh — the mutation check is vacuous"
else
  drive
  [ "$(line1)" = "RESULT_UNVERIFIED PR_CREATED $PRURL" ] && ok \
    || bad "I: with merged_at ignored, case D's assertion did not go red — it proves nothing"
fi

echo "fly-pool-pr-verify.bh-781: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
