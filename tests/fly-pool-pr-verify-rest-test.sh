#!/bin/bash
# tests/fly-pool-pr-verify-rest-test.sh — the pool's reap-time PR_CREATED gate
# reads GitHub over REST, and a FAILED READ IS NEVER A STATE.
#
# THE DEFECT (BH-709, 2026-09-17). bin/fly-pool.sh verified a reaped
# `PR_CREATED` RESULT with `gh pr view --json state` — a GraphQL call. The
# org-admin PAT's GraphQL budget is chronically exhausted on this fleet ("API
# rate limit already exceeded for user ID 2220366", 20:15Z), so the view exited
# non-zero, `PRSTATE` came back EMPTY, and the guard that was supposed to catch
# that asked `gh api repos/<slug>` — REST, a different budget, which succeeded.
# `_VSEEN=1`, the `elif [ "$PRSTATE" != "OPEN" ]` branch fired, and a real OPEN
# PR's RESULT was rewritten to `RESULT_UNVERIFIED` with an alert blaming a
# builder death. 75 such alerts across 17 tickets in one day; PR 707 was OPEN
# 2m23s before its own alert.
#
# WHAT THIS SUITE PINS: only an affirmative REST 404, with the repo itself
# provably visible to the same token, may relabel a RESULT. 403 / 429 / 5xx / a
# reader that answered nothing / an unparseable 200 all leave the RESULT alone
# and alert as UNVERIFIABLE. The 2026-09-12 token-scope invariant (a real PR is
# never filed as unverified over token scope) must survive intact.
#
# WHAT BH-781 CHANGED, AND WHY THIS SUITE MOVED WITH IT. The gate's own REST
# reader is gone: it now reads through bin/lib/gh-rest.sh, the fleet's one
# contract (rc 0 = act on the body, rc 44 = an affirmative 404, rc 75 =
# UNVERIFIABLE), and it asks ONCE — 75 means "skip this tick, leave state
# exactly as it is", and the next */2 reap is the retry. So A5 pins one read and
# no sleep where it used to pin two with a pause, the UNVERIFIABLE register is
# the library's own one-line alert, and Section B drives gh_rest_pr_state
# instead of the file-local pr_state_rest that no longer exists. The invariants
# above are unchanged: they are what this suite is for.
#
# HOW IT DRIVES: the gate and the library-source block are EXTRACTED VERBATIM
# from bin/fly-pool.sh by their `# >>>` / `# <<<` markers (falling back to the
# legacy anchor range, so this suite runs against the merge base too and goes
# red there for the right reason — the relabel — rather than for a missing
# marker) and run against a mktemp'd $HARNESS with a stub `gh` on PATH.
# Assertions are on artifacts: the first line of $LOCAL/RESULT and the contents
# of ALERTS.log. No network, no real box, no real ledger.
#
# Run from anywhere: tests/fly-pool-pr-verify-rest-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# jq is a hard dependency of bin/fly-pool.sh itself, so a box without it cannot
# run the lane either. Fail loudly rather than skip: a suite that exits 0 on a
# missing tool is the vacuous green this file exists to stop.
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive this gate"; exit 1; }

PRURL="https://github.com/example-org/cromford/pull/707"
SLUG="example-org/cromford"
# Recognisable fixture tokens. Neither may ever reach a log, an alert or stdout.
TOKFIX="ghp_FIXTURE_BH709_do_not_ship"
APPFIX="ghs_FIXTURE_BH765_do_not_ship"
LINE2='TIER: 2 | QA: manual — no browser on this box | migration: none'

# ── the production block, lifted verbatim ────────────────────────────────────
marked() { # marked <start> <end> <file>
  awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"
}
GATE="$T/gate.sh"; HELPERS="$T/helpers.sh"; VERIFY="$T/verify.sh"
marked '# >>> pr verify rest (BH-709)' '# <<< pr verify rest' "$DIR/bin/fly-pool.sh" > "$HELPERS"
marked '# >>> pr verify gate (BH-709)' '# <<< pr verify gate' "$DIR/bin/fly-pool.sh" > "$GATE"
# BH-781's inner markers. The OUTER range is what this suite drives — the shape
# branch and the entry condition live there and cases A11/A12 are about them —
# but the inner block is the one the ticket named, and an extraction that found
# nothing must fail loudly rather than silently assert less.
marked '# >>> PR_CREATED verify' '# <<< PR_CREATED verify' "$DIR/bin/fly-pool.sh" > "$VERIFY"
GATE_SRC=markers
if [ ! -s "$GATE" ]; then
  # The merge base carries no markers. Take the legacy anchor range instead, so
  # the cases below drive the OLD gate and fail on what it DOES.
  awk '/# --- GATE: PR_CREATED is verified/{f=1} f{print} f && /^    fi$/{exit}' \
    "$DIR/bin/fly-pool.sh" > "$GATE"
  GATE_SRC=legacy-anchor
fi
# STAMP and say are the pool's own one-liners; the alert format is theirs.
sed -n '/^STAMP() {/p;/^say() {/p' "$DIR/bin/fly-pool.sh" > "$T/saystamp.sh"

# ── the stub gh ──────────────────────────────────────────────────────────────
# Answers from per-attempt response files in $CASE (`<code>\n<body>`), records
# every invocation, and never prints a token: only the WORD default|admin, the
# same discipline bin/lib/gh-repo-token.sh keeps.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
W=default
[ -n "${GH_TOKEN:-}" ] && [ "${GH_TOKEN:-}" = "${TOKFIX:-x}" ] && W=admin
[ -n "${GH_TOKEN:-}" ] && [ "${GH_TOKEN:-}" = "${APPFIX:-x}" ] && W=app
printf 'token=%s %s\n' "$W" "$*" >> "$CASE/gh-calls.log"
# `gh pr view` is GraphQL. Under the ticket's rate limit it exits non-zero with
# nothing on stdout — the shape that started all of this.
[ "${1:-}" = api ] || exit 1
KIND=repo
for a in "$@"; do case "$a" in repos/*/pulls/*) KIND=pr ;; esac; done
# The library's repo probe is `-i -X GET repos/o/r`; the seam's visibility probe
# is `repos/o/r -q .id`. Both are repo reads and both answer from repo-N.resp.
if [ "$KIND" = pr ]; then
  N=$(( $(cat "$CASE/pr.n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$N" > "$CASE/pr.n"
  F="$CASE/pr-$N.resp"; [ -f "$F" ] || F=$(ls "$CASE"/pr-*.resp 2>/dev/null | tail -1)
else
  # A per-attempt counter for the REPO reads too (BH-781): the seam's visibility
  # probe and the gate's own 404-confirming probe are two different requests,
  # and A10 is about them answering differently. A case that files only
  # repo-1.resp gets it for every attempt, which is what every other case wants.
  N=$(( $(cat "$CASE/repo.n" 2>/dev/null || echo 0) + 1 )); printf '%s\n' "$N" > "$CASE/repo.n"
  F="$CASE/repo-$N.resp"; [ -f "$F" ] || F="$CASE/repo-1.resp"
  # A repo only the admin PAT can see: every other identity gets the 404 the
  # real API gives it, for the visibility probe AND the `-i` confirmation read.
  if [ -f "$CASE/repo-adminonly" ] && [ "$W" != admin ]; then
    printf 'HTTP/2.0 404 Not Found\nx-stub: 1\n\n{"message":"Not Found"}\n' | \
      { case " $* " in *" -i "*) cat ;; *) cat >/dev/null ;; esac; }
    exit 1
  fi
fi
[ -n "$F" ] && [ -f "$F" ] || exit 1
CODE=$(head -n 1 "$F"); BODY=$(tail -n +2 "$F")
[ "$CODE" = none ]    && exit 1     # a reader that answered nothing at all
[ "$CODE" = none127 ] && exit 127   # gh not on PATH: rc 127, empty stdout
case "$CODE" in
  200) TXT="OK" ;; 404) TXT="Not Found" ;; 403) TXT="Forbidden" ;;
  429) TXT="Too Many Requests" ;; 502) TXT="Bad Gateway" ;; *) TXT="Status" ;;
esac
case " $* " in
  *" -i "*)
    if [ "$CODE" = crlf ]; then
      printf 'HTTP/2.0 200 OK\r\nx-stub: 1\r\n\r\n%s\n' "$BODY"; exit 0
    fi
    printf 'HTTP/2.0 %s %s\nx-stub: 1\n\n%s\n' "$CODE" "$TXT" "$BODY" ;;
  *) printf '%s\n' "$BODY" ;;
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
# The pool's own pause between attempts is not the behaviour under test, and a
# real one would make the merge-base run of this suite a minute long. Recorded,
# never taken.
sleep() { printf 'sleep %s\n' "$*" >> "$CASE/sleeps.log"; }
RLINE=$(head -n 1 "$LOCAL/RESULT")
. "$HELPERS"
# Where bin/fly-pool.sh sources it (BH-765): top level, before the reap loop, so
# the lib captures the tick's own identity as "the caller's".
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
. "$GATE"
printf 'done\n' > "$CASE/drive.done"
DRIVE

resp() { printf '%s\n%s\n' "$2" "$3" > "$1"; }
newcase() { # newcase <name> — a fresh harness tree, PR_CREATED RESULT, open PR
  CASE="$T/case-$1"; export CASE
  H="$CASE/harness"; LOCAL="$H/builds/pool-cromford-BH-709-$NOW"
  mkdir -p "$LOCAL" "$H/logs" "$H/env" "$H/flags" "$H/bin/lib"
  # The real seam, not a paraphrase of it: this is the file bin/fly-pool.sh
  # sources for "which credential can see this repo".
  cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-app-auth.sh" \
     "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$H/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
  printf 'PR_CREATED %s\n%s\n' "$PRURL" "$LINE2" > "$LOCAL/RESULT"
  resp "$CASE/pr-1.resp" 200 '{"state":"open","merged_at":null}'
  resp "$CASE/repo-1.resp" 200 '{"id":42,"full_name":"example-org/cromford"}'
}
drive() {
  PATH="$T/bin:$PATH" HARNESS="$H" LOCAL="$LOCAL" P=cromford KEY=BH-709 \
    GATE="$GATE" HELPERS="$HELPERS" SAYSTAMP="$T/saystamp.sh" TOKFIX="$TOKFIX" \
    APPFIX="$APPFIX" POOL_PR_VERIFY_SLEEP=0 bash "$T/drive.sh" >/dev/null 2>&1
}
line1()   { head -n 1 "$LOCAL/RESULT"; }
alerts()  { cat "$H/logs/ALERTS.log" 2>/dev/null; }
nalerts() { alerts | grep -c . ; }
calls()   { cat "$CASE/gh-calls.log" 2>/dev/null; }
poollog() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
prreads() { calls | grep -c '/pulls/' ; }

untouched() { # untouched <case> — the RESULT is exactly what the builder wrote
  [ "$(line1)" = "PR_CREATED $PRURL" ] && ok \
    || bad "$1: a real PR's RESULT was relabeled — line 1 is '$(line1)'"
  [ "$(sed -n 2p "$LOCAL/RESULT")" = "$LINE2" ] && ok \
    || bad "$1: line 2 of the RESULT did not survive byte-identical"
}
one_unverifiable() { # one_unverifiable <code-or-why> <case>
  [ "$(nalerts)" = 1 ] && ok || bad "$2: expected exactly 1 ALERTS line, got $(nalerts)"
  alerts | grep -q 'unverifiable, left as-is this tick' && ok \
    || bad "$2: the alert must use the library's UNVERIFIABLE register: $(alerts)"
  alerts | grep -q -- "$1" && ok || bad "$2: the alert must name '$1': $(alerts)"
  alerts | grep -q 'token=' && ok || bad "$2: the alert must name WHICH identity answered: $(alerts)"
  grep -q 'no such PR' <<<"$(alerts)" && bad "$2: a failed read must never say 'no such PR'" || ok
  grep -q 'rewritten RESULT_UNVERIFIED' <<<"$(alerts)" \
    && bad "$2: an unreadable API must never claim the RESULT was rewritten" || ok
}

# ── Section C — the extraction itself (a suite that extracted nothing FAILS) ──
[ -s "$GATE" ] && ok || bad "C: could not extract the PR_CREATED gate from bin/fly-pool.sh (markers and legacy anchor both empty)"
grep -q 'RLINE#PR_CREATED ' "$GATE" && ok || bad "C: the extracted block is not the gate — its PR_CREATED entry condition is missing"
# (BH-765) The gate asks the seam which credential can see the repo; it does not
# read env/github-admin.env itself. The extraction above is asserted non-empty
# first, so this negative cannot pass by matching nothing.
grep -q 'github-admin.env' "$GATE" && bad "C: the gate reads env/github-admin.env by hand again — that question belongs to bin/lib/gh-repo-token.sh" || ok
grep -q 'gh_repo_use_token' "$GATE" && ok || bad "C: the gate no longer resolves its token through bin/lib/gh-repo-token.sh"
# (BH-781) The reader moved to the library and the two-try loop went with it.
[ -s "$VERIFY" ] && ok \
  || bad "C: bin/fly-pool.sh carries no '# >>> PR_CREATED verify' block — BH-781's marker is missing"
grep -q 'gh_rest_pr_state' "$VERIFY" && ok \
  || bad "C: the verify block does not read the PR through gh_rest_pr_state"
for STALE in 'pr_state_rest' 'gh_rest_read' 'POOL_PR_VERIFY_SLEEP'; do
  grep -q -- "$STALE" "$GATE" && bad "C: the gate still calls or describes '$STALE', which BH-781 removed" || ok
done
echo "gate source: $GATE_SRC ($(wc -l < "$GATE") lines)"

# ── Section A — the gate, driven ─────────────────────────────────────────────
# A1 — the ticket's own incident: GraphQL/REST rate limited.
newcase a1; resp "$CASE/pr-1.resp" 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
drive
untouched A1
one_unverifiable 403 A1

# A2 — 429 with a retry-after body.
newcase a2; resp "$CASE/pr-1.resp" 429 '{"message":"You have exceeded a secondary rate limit"}'
drive
untouched A2
one_unverifiable 429 A2

# A3 — 502 with an HTML body: the status must be read BEFORE the body.
newcase a3; resp "$CASE/pr-1.resp" 502 '<html><head><title>Server Error</title></head></html>'
drive
untouched A3
one_unverifiable 502 A3

# A4 — the reader answered nothing at all (rc 1, empty stdout).
newcase a4; resp "$CASE/pr-1.resp" none ''
drive
untouched A4
one_unverifiable 'HTTP 000' A4

# A5 — ONE READ PER TICK (BH-781). The gate used to ask twice with a pause
# between; rc 75 now means "skip this tick", and the next */2 reap is the retry.
# A second in-tick read would spend a request on the same rate limit and leave
# GH_REST_STATUS ambiguous for the alert.
newcase a5
resp "$CASE/pr-1.resp" 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
resp "$CASE/pr-2.resp" 200 '{"state":"open","merged_at":null}'
drive
untouched A5
[ "$(prreads)" = 1 ] && ok || bad "A5: the gate must read the PR exactly once, got $(prreads): $(calls)"
one_unverifiable 403 A5
[ ! -s "$CASE/sleeps.log" ] && ok \
  || bad "A5: the tick must not sleep for a retry it no longer makes: $(cat "$CASE/sleeps.log")"

# A6 — MERGED passes, and it passes on .merged_at, not on .state: a PR the
# harness itself merged reads `state: closed`, and state alone would relabel
# every merged handoff.
newcase a6; resp "$CASE/pr-1.resp" 200 '{"state":"closed","merged_at":"2026-09-18T08:39:44Z"}'
drive
untouched A6
[ "$(nalerts)" = 0 ] && ok || bad "A6: a MERGED PR must not alert ($(alerts))"

# A7 — closed and unmerged: still not a handoff, still relabeled (2026-08-14).
newcase a7; resp "$CASE/pr-1.resp" 200 '{"state":"closed","merged_at":null}'
drive
[ "$(line1)" = "RESULT_UNVERIFIED PR_CREATED $PRURL" ] && ok \
  || bad "A7: a closed, unmerged PR must be relabeled — line 1 is '$(line1)'"
[ "$(nalerts)" = 1 ] && ok || bad "A7: expected exactly 1 ALERTS line, got $(nalerts)"
alerts | grep -q "$LOCAL" && ok || bad "A7: the alert must name the build record"

# A8 — the only shape that may relabel over absence: 404 on the PR, repo visible.
newcase a8
resp "$CASE/pr-1.resp" 404 '{"message":"Not Found"}'
resp "$CASE/repo-1.resp" 200 '{"id":42}'
drive
[ "$(line1)" = "RESULT_UNVERIFIED PR_CREATED $PRURL" ] && ok \
  || bad "A8: an affirmative 404 with a visible repo must relabel — line 1 is '$(line1)'"
[ "$(nalerts)" = 1 ] && ok || bad "A8: expected exactly 1 ALERTS line, got $(nalerts)"
# (BH-765) The FIRST call is now the seam's visibility probe — which credential
# can see this repo is asked before the repo is read on one. What A8 has always
# protected is the order of the other two: the 404-confirming `-i` repo probe
# runs LAST, after a `/pulls/` read, so a 404 is only ever believed once the
# same token answered 200 for the repo.
calls | head -n 1 | grep -q "repos/$SLUG -q .id" && ok \
  || bad "A8: the first call must be the seam's visibility probe, got '$(calls | head -n 1)'"
calls | tail -n 1 | grep -q -- "-i -X GET repos/$SLUG$" && ok \
  || bad "A8: the 404-confirming repo probe must be the LAST call, got '$(calls | tail -n 1)'"
[ "$(calls | grep -n '/pulls/' | head -n 1 | cut -d: -f1)" -lt "$(calls | grep -c .)" ] && ok \
  || bad "A8: a /pulls/ read must precede the 404-confirming repo probe: $(calls)"

# A9 — 404 on the PR and 404 on the repo: the 2026-09-12 token-scope shape.
newcase a9
resp "$CASE/pr-1.resp" 404 '{"message":"Not Found"}'
resp "$CASE/repo-1.resp" 404 '{"message":"Not Found"}'
drive
untouched A9
[ "$(nalerts)" = 1 ] && ok || bad "A9: expected exactly 1 ALERTS line, got $(nalerts)"
alerts | grep -q 'is INVISIBLE to the' && ok || bad "A9: the 2026-09-12 INVISIBLE wording must survive"

# A10 — 404 on the PR, and the 404-CONFIRMING repo probe is itself refused.
# repo-1 is the seam's visibility probe (an identity can see the repo), repo-2
# is the gate's own confirmation. A probe that could not answer is not proof the
# PR is absent, so the RESULT stands and the alert names the probe's own status
# rather than blaming token scope (BH-781).
newcase a10
resp "$CASE/pr-1.resp" 404 '{"message":"Not Found"}'
resp "$CASE/repo-1.resp" 200 '{"id":42}'
resp "$CASE/repo-2.resp" 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
drive
untouched A10
alerts | grep -q 'HTTP 403' && ok || bad "A10: the alert must name the probe's own status: $(alerts)"
grep -q 'rewritten RESULT_UNVERIFIED' <<<"$(alerts)" && bad "A10: a failed repo probe must never relabel" || ok

# A11 — a RESULT already relabeled by an earlier pass: idempotent, no gh call.
newcase a11
printf 'RESULT_UNVERIFIED PR_CREATED %s\n%s\n' "$PRURL" "$LINE2" > "$LOCAL/RESULT"
drive
[ "$(line1)" = "RESULT_UNVERIFIED PR_CREATED $PRURL" ] && ok \
  || bad "A11: a re-reap must leave an already-relabeled RESULT alone — line 1 is '$(line1)'"
[ -z "$(calls)" ] && ok || bad "A11: a re-reap must ask GitHub nothing, called: $(calls)"

# A12 — a non-PR_CREATED RESULT is not this gate's business at all.
newcase a12
printf 'PLAN_BLOCKED ambiguous ticket\n%s\n' "$LINE2" > "$LOCAL/RESULT"
drive
[ "$(line1)" = "PLAN_BLOCKED ambiguous ticket" ] && ok || bad "A12: a PLAN_BLOCKED RESULT was touched"
[ -z "$(calls)" ] && ok || bad "A12: a PLAN_BLOCKED RESULT must ask GitHub nothing, called: $(calls)"

# ── Section D — fail-open: the tick survives an unwritable alert log ─────────
# ALERTS.log is a DIRECTORY here, not a read-only file: these suites run as
# root, and root writes through mode bits.
newcase d1; resp "$CASE/pr-1.resp" 403 '{"message":"API rate limit exceeded"}'
mkdir -p "$H/logs/ALERTS.log"
drive
untouched D1
[ -f "$CASE/drive.done" ] && ok || bad "D1: the gate aborted the tick when it could not append to ALERTS.log"

# ── Section E — hygiene ──────────────────────────────────────────────────────
# E1 — no gate may reach GitHub over GraphQL (`gh pr view`).
newcase e1; resp "$CASE/pr-1.resp" 200 '{"state":"open","merged_at":null}'
drive
grep -qx 'pr' <<<"$(calls | awk '{print $2}')" && bad "E1: the gate still calls 'gh pr view' (GraphQL)" || ok
[ -n "$(calls)" ] && ok || bad "E1: the gate asked GitHub nothing at all — the drive did not run"
# (BH-765) …and it costs exactly two requests: one visibility probe, one PR
# read. The tried-words sentence probes the rungs the ladder did not need, so it
# is composed only on a path that is about to write an alert — this one is not.
[ "$(calls | grep -c .)" = 2 ] && ok \
  || bad "E1: a verified OPEN PR must cost 2 requests (probe + read), it cost $(calls | grep -c .): $(calls)"

# E2 — the admin token is used by name and never printed. (BH-765: only for a
# repo the DEFAULT PAT cannot see. The ladder tries default before admin, so a
# configured admin token is no longer spent on repos the default one reaches.)
newcase e2
printf 'export GH_ADMIN_TOKEN=%s\n' "$TOKFIX" > "$H/env/github-admin.env"
touch "$CASE/repo-adminonly"
resp "$CASE/pr-1.resp" 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
drive
calls | grep -q 'token=admin' && ok || bad "E2: the admin token in env/github-admin.env was not used for the read: $(calls)"
# The ALERTS line is the library's and names the identity as a LABEL; the pool's
# own log line names the rung by word. Neither ever carries the value.
alerts | grep -q 'token=explicit' && ok || bad "E2: the alert must label the identity that answered: $(alerts)"
poollog | grep -q 'admin' && ok || bad "E2: the pool log must say WHICH token was used: $(poollog)"
LEAK=$(grep -rl "$TOKFIX" "$CASE" 2>/dev/null | grep -v 'env/github-admin.env')
[ -z "$LEAK" ] && ok || bad "E2: the token value leaked into: $LEAK"

# E3 — an armed box reads the PR on the App installation token (BH-765).
newcase e3
: > "$H/env/github-app.env"
printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$APPFIX" > "$H/bin/gh-token.sh"
chmod +x "$H/bin/gh-token.sh"
resp "$CASE/pr-1.resp" 403 '{"message":"API rate limit exceeded for user ID 2220366"}'
drive
untouched E3
calls | grep '/pulls/' | grep -q 'token=app' && ok \
  || bad "E3: an armed box must read the PR on the App token: $(calls)"
poollog | grep -q 'app token' && ok \
  || bad "E3: the pool log must name the identity it used: $(poollog)"
LEAK=$(grep -rl "$APPFIX" "$CASE" 2>/dev/null | grep -v 'bin/gh-token.sh')
[ -z "$LEAK" ] && ok || bad "E3: the App token value leaked into: $LEAK"

# E4 — no identity can see the repo: no PR read at all, and the alert says what
# each rung answered instead of naming one token as the culprit.
newcase e4
resp "$CASE/repo-1.resp" 404 '{"message":"Not Found"}'
resp "$CASE/pr-1.resp" 200 '{"state":"open","merged":false}'
drive
untouched E4
[ "$(prreads)" = 0 ] && ok || bad "E4: a repo no identity can see must cost no PR read, called: $(calls)"
[ "$(nalerts)" = 1 ] && ok || bad "E4: expected exactly 1 ALERTS line, got $(nalerts): $(alerts)"
alerts | grep -q 'is INVISIBLE to the' && ok || bad "E4: the 2026-09-12 INVISIBLE wording must survive: $(alerts)"
alerts | grep -q 'tried the App installation token' && ok \
  || bad "E4: the alert must say which of the three it tried: $(alerts)"

# ── Section B — the state reader the gate now uses, driven directly ─────────
# bin/lib/gh-rest.sh is BH-784's file, consumed here and never edited: what this
# section pins is the mapping the GATE depends on — which answers are a state,
# which are 44, and which are 75. A reader that started calling a 403 "closed"
# would relabel real PRs, and that is the whole reason #768 happened.
cat > "$T/drive-b.sh" <<'DRIVEB'
#!/bin/bash
set -uo pipefail
HARNESS="$H"
# shellcheck source=/dev/null
. "$HELPERS"
gh_rest_pr_state "$1" "$2" > "$CASE/b.out"
printf '%s %s\n' "$?" "$GH_REST_STATUS"
DRIVEB
b() { # b <case> <expected "rc status state"> <http code> <body> [slug] [num]
  local got st
  newcase "$1"; resp "$CASE/pr-1.resp" "$3" "$4"
  st=$(PATH="$T/bin:$PATH" H="$H" CASE="$CASE" HELPERS="$HELPERS" TOKFIX="$TOKFIX" \
       bash "$T/drive-b.sh" "${5:-$SLUG}" "${6:-707}" 2>/dev/null)
  got="$st $(cat "$CASE/b.out" 2>/dev/null)"
  [ "$got" = "$2" ] && ok || bad "$1: expected '$2' (rc status state), got '$got'"
}
if [ ! -s "$HELPERS" ]; then
  bad "B: bin/fly-pool.sh defines no '# >>> pr verify rest' block — the gate sources no reader at all"
else
  b B1  "0 200 open"   200 '{"state":"open","merged_at":null}'
  b B2  "0 200 merged" 200 '{"state":"closed","merged_at":"2026-09-18T08:39:44Z"}'
  b B3  "0 200 closed" 200 '{"state":"closed","merged_at":null}'
  b B4  "75 200 "      200 '{}'
  b B5  "75 403 "      403 '{"message":"API rate limit exceeded for user ID 2220366"}'
  b B6  "75 429 "      429 '{"message":"secondary rate limit"}'
  b B7  "75 502 "      502 '<html><title>Server Error</title></html>'
  b B8  "75 000 "      none ''
  b B9  "75 000 "      none127 ''
  b B10 "75 000 "      200 '{"state":"open"}' "nope" 707
  [ -z "$(calls)" ] && ok || bad "B10: a malformed slug must make no gh call at all, called: $(calls)"
  b B11 "44 404 "      404 '{"message":"Not Found"}'
  b B12 "0 200 open"   crlf '{"state":"open","merged_at":null}'
fi

echo "fly-pool-pr-verify-rest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
