#!/bin/bash
# tests/ci-runners-status.bh-1206-test.sh — BH-1206: "NO RUNNERS" AND "COULD NOT
# ASK" MUST NOT BE THE SAME ANSWER.
#
# Harness CI has no GitHub-hosted fallback: when the Fly `bh-ci` pool is down
# the jobs QUEUE. That is the right failure and it is completely silent, so
# bin/ci-runners-status.sh is the thing that says the pool is empty — and the
# one way it could be worse than nothing is by saying "0 runners" when what
# actually happened is that the token could not read the endpoint. A 403 parses
# as perfectly good JSON. So the script has three outcomes and this suite drives
# all of them against a FAKE `gh` on PATH: an online pool (rc 0), a pool that
# answered with nothing online (rc 1, the alert), and every way the read can go
# wrong (rc 2 — an error body, a non-JSON body, an empty body, a failing gh).
#
# It also pins the counting itself, which is where a quiet wrong answer lives:
# `busy` runners are ONLINE (a full pool is not an empty one), offline runners
# are neither idle nor busy, and a self-hosted runner that does NOT carry the
# pool label must not make an empty bh-ci pool look staffed.
#
# No network, no secrets, no clock, no dice. Run from anywhere: exit 0 = pass.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SUT="${BH1206_STATUS:-$DIR/bin/ci-runners-status.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$SUT" ] || { echo "FAIL: $SUT is missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ci-runners-status.bh-1206-test.sh: SKIP (no jq)"; exit 0; }

mkdir -p "$T/bin"
# The fake gh prints $T/body and exits $T/rc, and records that it was called so
# a test can prove the script asked rather than answered from somewhere else.
# Page-aware: it answers $T/body-<page> when that file exists and $T/body
# otherwise, so a test can hand it a multi-page pool without the script knowing
# it is being tested. The page is read off the URL the script actually built —
# if the script stops asking for a page, page 1 is all it ever sees.
cat > "$T/bin/gh" <<EOF
#!/bin/sh
echo "\$@" >> "$T/gh-calls"
P=\$(printf '%s\n' "\$@" | sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "\$P" ] || P=1
if [ -f "$T/body-\$P" ]; then cat "$T/body-\$P"
else cat "$T/body" 2>/dev/null; fi
exit \$(cat "$T/rc" 2>/dev/null || echo 0)
EOF
chmod 755 "$T/bin/gh"

runner() { # runner <name> <status> <busy true|false> <label...>
  local name="$1" status="$2" busy="$3"; shift 3
  local labels="" l
  for l in "$@"; do labels="$labels{\"name\":\"$l\"},"; done
  printf '{"name":"%s","status":"%s","busy":%s,"labels":[%s]}' \
    "$name" "$status" "$busy" "${labels%,}"
}
body() { printf '{"total_count":%s,"runners":[%s]}\n' "$#" "$(IFS=,; echo "$*")" > "$T/body"; echo 0 > "$T/rc"; }

run_sut() { # run_sut <args...> → rc; stdout+stderr in $T/out
  rm -f "$T/gh-calls"
  ( PATH="$T/bin:$PATH" HARNESS="$T/h" "$SUT" "$@" >"$T/out" 2>&1 ); echo $?
}

# ── a healthy pool ──────────────────────────────────────────────────────────
body "$(runner fly-a-0 online false self-hosted linux bh-ci)" \
     "$(runner fly-a-1 online true  self-hosted linux bh-ci)" \
     "$(runner fly-a-2 offline false self-hosted linux bh-ci)"
RC=$(run_sut --json)
if [ "$RC" = 0 ]; then ok; else bad "an online pool must be rc 0 (rc=$RC): $(cat "$T/out")"; fi
GOT=$(cat "$T/out")
case "$GOT" in
  *'"total":3'*) ok ;; *) bad "total must be 3: $GOT" ;;
esac
case "$GOT" in
  *'"online":2'*) ok ;; *) bad "a BUSY runner is online — online must be 2: $GOT" ;;
esac
case "$GOT" in
  *'"idle":1'*) ok ;; *) bad "idle must be 1: $GOT" ;;
esac
case "$GOT" in
  *'"busy":1'*) ok ;; *) bad "busy must be 1: $GOT" ;;
esac
case "$GOT" in
  *'"offline":1'*) ok ;; *) bad "offline must be 1: $GOT" ;;
esac
# It asked GitHub, over REST, for the runners of the repo it was given.
CALLS=$(cat "$T/gh-calls" 2>/dev/null)
case "$CALLS" in
  *"actions/runners"*) ok ;; *) bad "the script did not read actions/runners: $CALLS" ;;
esac
case "$CALLS" in
  *graphql*) bad "the script reached for GraphQL: $CALLS" ;; *) ok ;;
esac

# The human form names each runner, which is how an operator sees that seven of
# eight registered and one did not.
RC=$(run_sut)
if [ "$RC" = 0 ]; then ok; else bad "the human form must also be rc 0 (rc=$RC)"; fi
case "$(cat "$T/out")" in
  *fly-a-0*fly-a-1*) ok ;; *) bad "the human form must list the runners: $(cat "$T/out")" ;;
esac

# ── the alert: registered, none online ──────────────────────────────────────
body "$(runner fly-a-0 offline false self-hosted linux bh-ci)" \
     "$(runner fly-a-1 offline false self-hosted linux bh-ci)"
RC=$(run_sut --json)
if [ "$RC" = 1 ]; then ok; else bad "a pool with nothing online must be rc 1 (rc=$RC): $(cat "$T/out")"; fi
case "$(cat "$T/out")" in
  *'"online":0'*) ok ;; *) bad "online must be 0: $(cat "$T/out")" ;;
esac
# The refusal has to say what it means for CI, or it is a number nobody acts on.
case "$(cat "$T/out")" in
  *queue*) ok ;; *) bad "the zero-online message must say the jobs will queue: $(cat "$T/out")" ;;
esac

# An EMPTY runner list is the same alert, not a read failure: the app never
# registered, which is exactly the outage this exists for.
printf '{"total_count":0,"runners":[]}\n' > "$T/body"; echo 0 > "$T/rc"
RC=$(run_sut --json)
if [ "$RC" = 1 ]; then ok; else bad "an empty pool must be rc 1 (rc=$RC): $(cat "$T/out")"; fi

# A runner without the pool label must not staff the pool.
body "$(runner other-0 online false self-hosted linux some-other-lane)"
RC=$(run_sut --json)
if [ "$RC" = 1 ]; then ok; else bad "a runner without the bh-ci label must not count (rc=$RC): $(cat "$T/out")"; fi
case "$(cat "$T/out")" in
  *'"total":0'*) ok ;; *) bad "an unlabelled runner must not be in total: $(cat "$T/out")" ;;
esac
# …and --label selects it, so the same script reads a second pool.
RC=$(run_sut --label some-other-lane --json)
if [ "$RC" = 0 ]; then ok; else bad "--label must select the other pool (rc=$RC): $(cat "$T/out")"; fi

# ── pagination: the pool outgrew one page ───────────────────────────────────
# THE FAILURE THIS CATCHES IS WRONG IN THE REASSURING DIRECTION. The endpoint
# defaults to 30 per page; the fleet is past 70 registrations. A single
# unpaginated read reports a third of the pool, every count is understated, and
# the script still answers rc 0 "plenty online" when the truth might be none.
# That is the exact failure it exists to catch, so it must not be the failure
# it has.
rm -f "$T/body"
page_of() { # page_of <file> <total_count> <n-online> <n-offline> <name-prefix>
  # Arithmetic loops, not `seq 1 $n`: BSD seq COUNTS DOWN on `seq 1 0` and
  # emits two values, so a page asked for zero offline runners would quietly
  # get two — a fixture that is wrong by exactly the amount the assertion is
  # checking, on the reviewer's laptop and not on the runner.
  local f="$1" total="$2" on="$3" off="$4" pre="$5" i out=""
  for ((i = 1; i <= on;  i++)); do out="$out$(runner "$pre-on-$i" online false self-hosted linux bh-ci),"; done
  for ((i = 1; i <= off; i++)); do out="$out$(runner "$pre-off-$i" offline false self-hosted linux bh-ci),"; done
  printf '{"total_count":%s,"runners":[%s]}\n' "$total" "${out%,}" > "$f"
}
# 120 registered over two pages: a full page of 100, then 20.
page_of "$T/body-1" 120 100 0 p1
page_of "$T/body-2" 120 10 10 p2
echo 0 > "$T/rc"
RC=$(run_sut --json)
if [ "$RC" = 0 ]; then ok; else bad "pagination: rc must be 0 (rc=$RC): $(cat "$T/out")"; fi
case "$(cat "$T/out")" in
  *'"total":120'*) ok ;;
  *) bad "pagination: all 120 runners must be counted, not one page: $(cat "$T/out")" ;;
esac
case "$(cat "$T/out")" in
  *'"offline":10'*) ok ;;
  *) bad "pagination: page 2's offline runners must be counted: $(cat "$T/out")" ;;
esac
# It asked for a second page, and asked with a page size worth asking for.
case "$(cat "$T/gh-calls")" in
  *"page=2"*) ok ;;
  *) bad "pagination: the script never asked for page 2: $(cat "$T/gh-calls")" ;;
esac
case "$(cat "$T/gh-calls")" in
  *"per_page=100"*) ok ;;
  *) bad "pagination: per_page must be 100, or a big pool costs a page per 30: $(cat "$T/gh-calls")" ;;
esac

# A SHORT LISTING IS rc 2, NOT A SMALLER POOL. If page 2 comes back empty while
# total_count still says 120, something dropped a page — and reporting the 100
# we did get as the whole pool is the understated answer again, now with a
# green exit code.
printf '{"total_count":120,"runners":[]}\n' > "$T/body-2"
RC=$(run_sut --json)
if [ "$RC" = 2 ]; then ok; else bad "pagination: a short listing must be rc 2 (rc=$RC): $(cat "$T/out")"; fi

# A FAILURE ON PAGE 2 IS rc 2 TOO — never "the pool is however big page 1 said".
printf '{"message":"Bad credentials","status":"401"}\n' > "$T/body-2"
RC=$(run_sut --json)
if [ "$RC" = 2 ]; then ok; else bad "pagination: an error body on page 2 must be rc 2 (rc=$RC): $(cat "$T/out")"; fi

# One short page is the whole pool and must NOT provoke a second request.
rm -f "$T/body-1" "$T/body-2"
body "$(runner solo online false self-hosted linux bh-ci)"
RC=$(run_sut --json)
if [ "$RC" = 0 ]; then ok; else bad "pagination: a single short page must be rc 0 (rc=$RC)"; fi
case "$(cat "$T/gh-calls")" in
  *"page=2"*) bad "pagination: asked for page 2 after a short first page" ;;
  *) ok ;;
esac

# ── rc 2: nothing is known ──────────────────────────────────────────────────
# A 403 body. Valid JSON, no runner list — the failure that must never read as
# an empty pool, because one of those answers pages someone.
printf '{"message":"Resource not accessible by personal access token","status":"403"}\n' > "$T/body"
echo 0 > "$T/rc"
RC=$(run_sut --json)
if [ "$RC" = 2 ]; then ok; else bad "a 403 body must be rc 2, never rc 1 (rc=$RC): $(cat "$T/out")"; fi

printf 'not json at all\n' > "$T/body"; echo 0 > "$T/rc"
RC=$(run_sut --json)
if [ "$RC" = 2 ]; then ok; else bad "a non-JSON body must be rc 2 (rc=$RC): $(cat "$T/out")"; fi

: > "$T/body"; echo 0 > "$T/rc"
RC=$(run_sut --json)
if [ "$RC" = 2 ]; then ok; else bad "an empty body must be rc 2 (rc=$RC): $(cat "$T/out")"; fi

body "$(runner fly-a-0 online false self-hosted linux bh-ci)"; echo 1 > "$T/rc"
RC=$(run_sut --json)
if [ "$RC" = 2 ]; then ok; else bad "a failing gh must be rc 2 (rc=$RC): $(cat "$T/out")"; fi

# `runners` present but not a list is the same unknown.
printf '{"runners":"nope"}\n' > "$T/body"; echo 0 > "$T/rc"
RC=$(run_sut --json)
if [ "$RC" = 2 ]; then ok; else bad "a malformed runners field must be rc 2 (rc=$RC)"; fi

# ── misuse is rc 2, never a silent default ──────────────────────────────────
body "$(runner fly-a-0 online false self-hosted linux bh-ci)"
RC=$(run_sut --repo not-a-slug)
if [ "$RC" = 2 ]; then ok; else bad "--repo without owner/repo must be rc 2 (rc=$RC)"; fi
RC=$(run_sut --nonsense)
if [ "$RC" = 2 ]; then ok; else bad "an unknown flag must be rc 2 (rc=$RC)"; fi
case "$(cat "$T/out")" in
  *usage*) ok ;; *) bad "an unknown flag must print usage: $(cat "$T/out")" ;;
esac

echo "ci-runners-status.bh-1206-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
