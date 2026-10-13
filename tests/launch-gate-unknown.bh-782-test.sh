#!/bin/bash
# tests/launch-gate-unknown.bh-782-test.sh — BH-782: a GitHub read we could not
# make must arrive at a launch gate as an HTTP status, never as a fact about
# GitHub's state.
#
# THE INCIDENT THIS PINS (#768, 2026-09-18 02:49-03:05Z). A rate-limited
# GraphQL-backed `gh pr list` exited 0 and printed NOTHING. Five separate launch
# gates mapped that silence to `[]` — "this repo has no open PRs" — and acted on
# it: five real PRs were rewritten RESULT_UNVERIFIED and TK-2302 was launched
# three times on top of work that was already written.
#
# THE RULE, ONE SENTENCE. A non-200 (or a 2xx with an unusable body) is UNKNOWN:
# the launch is skipped for this tick with a log line naming the status. A 200
# with `[]` is a real empty and the launch proceeds.
#
# HOW IT IS DRIVEN. The REAL scripts, against a scratch $HARNESS, with a `gh`
# stub on PATH that replays a canned `-i` response (status line, blank line,
# body) per route and appends its argv to $GH_ARGV. Every assertion reads
# stdout, an exit code, logs/<project>.log, logs/overlap-guard.log or state/ —
# never a grep over the script's own source. The one exception is §F1, which is
# a marker census and is guarded by the decision-guard suite's own absent case.
#
# Sections: §A preplan-candidates  §B triage-gate  §C dep-verify
#           §D overlap-guard  §F gh-pr-list  §E mutation checks (D1)
#           §G the fixture-stub hygiene rule this suite's own round 1 broke
#
# Run from anywhere: bash tests/launch-gate-unknown.bh-782-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

# ONE clock read for the whole suite (bin/test-determinism-lint.sh): every
# relative timestamp below is derived from it, so a suite that starts at 23:59Z
# reads exactly like one that starts at noon.
NOW=$(date +%s)

H="$T/h"
SLUG=example-org/proj
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export GH_ARGV="$T/gh-argv" GH_CTL="$T/ctl"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/plans" "$H/flags" "$H/env" \
         "$H/builds" "$H/locks" "$H/prompts" "$T/fakebin" "$T/ctl"

for f in preplan-candidates.sh triage-gate.sh overlap-guard.sh dep-verify.sh \
         fleet-conf.sh project-of.sh; do
  cp "$DIR/bin/$f" "$H/bin/"
done
# BH-1485: gh-rest-var.sh rides with gh-rest.sh, which sources it by path from
# beside itself; the gate's PR-state vector calls gh_rest_pr_state_var.
for f in gh-rest.sh gh-rest-var.sh gh-pr-list.sh preplan-lib.sh dep-verify-lib.sh \
         hotfix-lib.sh scheduler-conf.sh test-home-lib.sh; do
  cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
# bin/lib/gh-app-auth.sh and bin/lib/gh-repo-token.sh are deliberately NOT
# copied: both mint/probe credentials, every caller guards them with
# `command -v`, and a suite that lets them run would be measuring the token
# ladder rather than the launch gates.

printf 'proj %s - - 0 local -\n' "$SLUG" > "$H/fleet.conf"
# The one place a GitHub-Issues project's KEY prefix is written down
# (bin/lib/preplan-lib.sh:preplan_key_prefix reads the rendered triage prompt).
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$H/prompts/proj.md"
: > "$H/logs/READY-QUEUE.log"

# ── the gh stub ──────────────────────────────────────────────────────────────
# `gh api -i …` (what bin/lib/gh-rest.sh runs) replays a status line, a blank
# line and a body, per ROUTE. `gh api …` without -i (dep-verify's
# pulls/N/files) replays the body alone. `gh pr|issue|run …` is the GraphQL
# family: its mode is a control file, because "exits 0 and prints nothing" is
# the exact #768 shape and has to be drivable.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_ARGV"
ctl="$GH_CTL"
rd() { [ -f "$ctl/$1" ] && cat "$ctl/$1"; }
case "${1:-}" in
  api)
    shift
    inc=0; path=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -i) inc=1; shift ;;
        -X|-f|-F|-H) shift 2 ;;
        --paginate) shift ;;
        -*) shift ;;
        *) path="$1"; shift; break ;;
      esac
    done
    key=other
    case "$path" in
      repos/*/pulls/*/files*) key=pr-files ;;
      repos/*/pulls/[0-9]*)   key=pull-one ;;
      repos/*/pulls*)         key=pulls ;;
      repos/*/issues/[0-9]*)  key=issue-one ;;
      repos/*/issues*)        key=issues ;;
    esac
    st=$(rd "$key.status"); [ -n "$st" ] || st=$(rd default.status); [ -n "$st" ] || st=200
    body=""
    [ -f "$ctl/$key.body" ] && body=$(cat "$ctl/$key.body")
    if [ "$inc" = 1 ]; then
      # 000 is the network case: gh writes no status line at all.
      [ "$st" = 000 ] && exit 1
      printf 'HTTP/2.0 %s\r\n' "$st"
      printf 'content-type: application/json\r\n'
      printf '\r\n'
      [ -n "$body" ] && printf '%s\n' "$body"
      case "$st" in 2*) exit 0 ;; *) exit 1 ;; esac
    fi
    [ -n "$body" ] && printf '%s\n' "$body"
    case "$st" in 2*) exit 0 ;; *) exit 1 ;; esac
    ;;
  pr|issue|run)
    mode=$(rd graphql.mode); [ -n "$mode" ] || mode=ok
    a=""
    while [ $# -gt 0 ]; do case "$1" in --author) a="$2"; shift 2 ;; *) shift ;; esac; done
    case "$mode" in
      silent) exit 0 ;;          # #768: exit 0, print nothing
      fail)   exit 1 ;;
    esac
    f="$ctl/graphql-$(printf '%s' "$a" | tr '/' '_').body"
    [ -f "$f" ] && { cat "$f"; exit 0; }
    exit 0
    ;;
esac
exit 1
GH
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

ctl_reset() {
  rm -f "$T/ctl"/*
  echo 200 > "$T/ctl/default.status"
  echo ok  > "$T/ctl/graphql.mode"
  : > "$GH_ARGV"
}
ctl() { # ctl <route> <status> [body]
  printf '%s' "$2" > "$T/ctl/$1.status"
  if [ $# -ge 3 ]; then printf '%s' "$3" > "$T/ctl/$1.body"; fi
}
RATE_BODY='{"message":"API rate limit exceeded for installation."}'
FORBID_BODY='{"message":"Resource not accessible by integration"}'

# Two open ai-build issues. #7 is plannable; #8 is a PULL REQUEST that the REST
# /issues endpoint returns alongside issues (N8) and must never be planned.
ISSUES_OK='[
 {"number":7,"state":"open","title":"add the rollup","body":"do the thing",
  "comments":3,"updated_at":"2026-09-19T10:00:00Z","labels":[{"name":"ai-build"}]},
 {"number":8,"state":"open","title":"BH-7: a PR, not an issue","body":"",
  "comments":1,"updated_at":"2026-09-19T11:00:00Z","labels":[{"name":"ai-build"}],
  "pull_request":{"url":"https://api.github.com/repos/example-org/proj/pulls/8"}}
]'
# One open PR that claims nothing (#99 is not an issue number on this board).
PULLS_OK='[
 {"number":99,"title":"chore: unrelated","body":"nothing here",
  "state":"open","merged_at":null,
  "head":{"ref":"chore/unrelated","sha":"sha99"},"base":{"ref":"main"},
  "draft":false,"user":{"login":"operator","type":"User"},
  "created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T00:00:00Z",
  "closed_at":null,"labels":[],"html_url":"https://github.com/example-org/proj/pull/99"}
]'

# ════════════════════════════════════════════════════════════════════════════
# §A — bin/preplan-candidates.sh
# ════════════════════════════════════════════════════════════════════════════
preplan() { # preplan -> OUT / RC
  OUT=$("$H/bin/preplan-candidates.sh" proj 2>/dev/null); RC=$?
}

a_setup() {
  ctl_reset
  : > "$H/logs/proj.log"
  ctl issues 200 "$ISSUES_OK"
  ctl pulls  200 "$PULLS_OK"
}

# A1 — 200 on both, a populated PR list that claims nothing (N2): the candidate
# row is emitted, which also proves the jq -> Python shape mapping (R9).
a_setup
preplan
[ "$RC" = 0 ] && ok || bad "A1: preplan must exit 0 (rc $RC)"
grep -qP '^AB-7\t7\tahead$' <<<"$OUT" && ok || bad "A1: the candidate row for #7 is missing (got: $OUT)"

# A6 — the PR the /issues endpoint returned is NOT planned (N8).
! grep -q '^AB-8' <<<"$OUT" && ok || bad "A6: a pull_request row was planned as an issue (got: $OUT)"

# A3 — a 200 with a literal empty PR list is a REAL empty: the launch proceeds.
a_setup
ctl pulls 200 '[]'
preplan
grep -qP '^AB-7\t7\tahead$' <<<"$OUT" && ok || bad "A3: 200 + [] must still emit the candidate (got: $OUT)"

# A2 — 403 rate-limit on the PR list: ZERO candidate rows, exit 0, exactly one
# log line naming the status.
a_setup
printf 'AB-5 5 — waiting on merge project=proj\n' > "$H/logs/READY-QUEUE.log"
ctl pulls 403 "$RATE_BODY"
preplan
[ "$RC" = 0 ] && ok || bad "A2: an unknown answer must not kill the tick (rc $RC)"
! grep -qE '^AB-7' <<<"$OUT" && ok || bad "A2: a candidate row was emitted under a 403 (got: $OUT)"
[ "$(grep -c 'launch gate UNKNOWN (HTTP 403' "$H/logs/proj.log")" = 1 ] && ok \
  || bad "A2: expected exactly one 'launch gate UNKNOWN (HTTP 403' line (got: $(cat "$H/logs/proj.log"))"
grep -q 'rate-limit' "$H/logs/proj.log" && ok || bad "A2: the rate-limit reason is not named"

# A4 — the queued class is not GitHub's to withhold.
grep -q '^AB-5' <<<"$OUT" && ok || bad "A4: the READY-QUEUE row must survive a 403 (got: $OUT)"
: > "$H/logs/READY-QUEUE.log"

# A5 — a bare 403 names HTTP 403 and invents no reason (D10/D26); and a 403 on
# the ISSUE list alone takes the same arm.
a_setup
ctl pulls 403 "$FORBID_BODY"
preplan
grep -q 'launch gate UNKNOWN (HTTP 403)' "$H/logs/proj.log" && ok \
  || bad "A5: a bare 403 must log 'HTTP 403' with no invented reason (got: $(cat "$H/logs/proj.log"))"
! grep -q 'rate-limit' "$H/logs/proj.log" && ok || bad "A5: a bare 403 must not claim rate-limit"

a_setup
ctl issues 403 "$RATE_BODY"
preplan
[ "$RC" = 0 ] && ok || bad "A5b: a 403 on the issue list must still exit 0 (rc $RC)"
! grep -qE '^AB-7' <<<"$OUT" && ok || bad "A5b: a candidate was emitted under a 403 issue list (got: $OUT)"
grep -q 'launch gate UNKNOWN (HTTP 403' "$H/logs/proj.log" && ok \
  || bad "A5b: the issue-list 403 was not logged"

# A8 — THE 2xx HALF OF THE RULE. gh_rest answers 0 for ANY non-empty 2xx body,
# so a 200 carrying a proxy page / a truncated response / an error object
# reaches the mapping jq and fails there. That is a read we could not USE, and
# it must take the same arm as a 403: zero candidate rows and a log line. It
# used to land in `PRS='[]'` — the exact mapping this ticket removes, one layer
# further in.
a_setup
ctl pulls 200 '{"message":"Moved Permanently"}'
preplan
[ "$RC" = 0 ] && ok || bad "A8: an unusable 2xx must not kill the tick (rc $RC)"
! grep -qE '^AB-7' <<<"$OUT" && ok \
  || bad "A8: a candidate row was emitted on a 2xx body we could not parse (got: $OUT)"
grep -q 'the PR list body would not parse' "$H/logs/proj.log" && ok \
  || bad "A8: the unusable-body reason is not in the log (got: $(cat "$H/logs/proj.log"))"

# A9 — the issue-list arm of the same rule. No candidates was always the answer
# here; saying nothing about why was the gap (a stop nobody is told about).
a_setup
ctl issues 200 '{"message":"Moved Permanently"}'
preplan
[ "$RC" = 0 ] && ok || bad "A9: an unusable 2xx issue list must not kill the tick (rc $RC)"
! grep -qE '^AB-7' <<<"$OUT" && ok || bad "A9: a candidate was emitted (got: $OUT)"
grep -q 'the issue list body would not parse' "$H/logs/proj.log" && ok \
  || bad "A9: the issue-list arm skipped the tick with no log line (got: $(cat "$H/logs/proj.log"))"

# A7 — no token value ever reaches a log.
a_setup
ctl pulls 403 "$RATE_BODY"
OUT=$(GH_TOKEN=shhh-secret-value "$H/bin/preplan-candidates.sh" proj 2>/dev/null)
! grep -rq 'shhh-secret-value' "$H/logs/" && ok || bad "A7: a token value reached logs/"

# ════════════════════════════════════════════════════════════════════════════
# §B — bin/triage-gate.sh
# ════════════════════════════════════════════════════════════════════════════
gate() { OUT=$("$H/bin/triage-gate.sh" proj ${1:+"$1"} 2>/dev/null); RC=$?; }

b_setup() {
  ctl_reset
  ctl issues 200 "$ISSUES_OK"
  ctl pulls  200 "$PULLS_OK"
  rm -f "$H/state/proj.gate.json" "$H/state/proj.gate-meta" \
        "$H/state/proj.queuefp" "$H/state/proj.gate.pending"
  scratch_rm "$H/state/remote-results"
  : > "$H/logs/READY-QUEUE.log"
  printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
}

# B1 — 200 on both reads: a stable fingerprint, and the same input twice SKIPs.
b_setup
gate --seed
grep -q '^SEEDED' <<<"$OUT" && ok || bad "B1: --seed must succeed on a 200/200 tick (got: $OUT)"
printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
gate
grep -q '^SKIP no-change' <<<"$OUT" && ok || bad "B1: an unchanged board must SKIP (got: $OUT)"

# B4 — a new comment still wakes the tick (the REST `comments` COUNT is the same
# wake signal the GraphQL field was).
gate --seed
printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
ctl issues 200 "$(jq -c '.[0].comments = 4' <<<"$ISSUES_OK")"
gate
grep -q '^RUN board-changed' <<<"$OUT" && ok || bad "B4: a comment bump must wake the tick (got: $OUT)"

# B5 — a rebase (head sha moves) still wakes the tick.
ctl issues 200 "$ISSUES_OK"
gate --seed
printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
ctl pulls 200 "$(jq -c '.[0].head.sha = "sha99b"' <<<"$PULLS_OK")"
gate
grep -q '^RUN board-changed' <<<"$OUT" && ok || bad "B5: a moved head sha must wake the tick (got: $OUT)"

# B2 — a 403 on the issue list keeps today's documented fail-OPEN-to-RUN.
b_setup
gate --seed
printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
ctl issues 403 "$RATE_BODY"
gate
grep -q '^RUN' <<<"$OUT" && ok || bad "B2: a 403 must fail OPEN to RUN (got: $OUT)"
! grep -q '^SKIP' <<<"$OUT" && ok || bad "B2: a 403 must never SKIP (got: $OUT)"

# B6 — the case that makes "fail-OPEN" true rather than usually-true: a board
# that genuinely has NO open PRs. Substituting prs:[] for an unreadable list
# produces a fingerprint byte-identical to the stored one, and the tick SKIPs
# off a read it never made. The fetch must fail instead.
b_setup
ctl pulls 200 '[]'
gate --seed
printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
ctl pulls 403 "$RATE_BODY"
gate
! grep -q '^SKIP' <<<"$OUT" && ok \
  || bad "B6: a 403 PR list on a zero-open-PR board must never SKIP (got: $OUT)"
grep -q '^RUN' <<<"$OUT" && ok || bad "B6: a 403 PR list must RUN (got: $OUT)"

# B6b — and the second tick of the same outage, on a board that DOES have open
# PRs: bin/lib/rt/gate.sh promotes gate.pending into the stored fingerprint once
# a session has run, so a substitute written on tick 1 would be matched and
# SKIPped on tick 2. Promotion is simulated exactly as that lib does it (mv).
b_setup
gate --seed
printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
ctl pulls 403 "$RATE_BODY"
gate
grep -q '^RUN' <<<"$OUT" && ok || bad "B6b: tick 1 of the outage must RUN (got: $OUT)"
[ -f "$H/state/proj.gate.pending" ] \
  && mv -f "$H/state/proj.gate.pending" "$H/state/proj.gate.json"
printf '%s\n' "$NOW" > "$H/state/proj.gate-meta"
gate
! grep -q '^SKIP' <<<"$OUT" && ok \
  || bad "B6b: tick 2 of the outage SKIPped off a fingerprint nothing could read (got: $OUT)"

# B3 — the queue gate's per-PR state vector. Three ticks: one to store the
# vector, one to prove it is stable (a real read), one with a 403 that must
# empty PRV and RUN.
b_setup
printf 'AB-5 5 — waiting on PR #99 project=proj\n' > "$H/logs/READY-QUEUE.log"
ctl pull-one 200 '{"number":99,"state":"open","merged_at":null}'
gate
grep -q '^RUN queue-pending' <<<"$OUT" && ok || bad "B3: the first queue tick must RUN (got: $OUT)"
age_back() { # rewrite the queuefp stamp so the next tick lands in the PR-gate window
  local f="$H/state/proj.queuefp"
  awk -v s="$((NOW - 3000))" 'NR==2{print s; next}{print}' "$f" > "$f.n" && mv -f "$f.n" "$f"
}
age_back
gate
grep -q '^RUN queue-pending' <<<"$OUT" && ok || bad "B3: the second tick stores the vector and RUNs (got: $OUT)"
age_back
gate
grep -q '^SKIP queue-gates-unchanged' <<<"$OUT" && ok \
  || bad "B3: an unchanged PR-state vector must SKIP — proves the REST read round-trips (got: $OUT)"
age_back
ctl pull-one 403 "$RATE_BODY"
gate
grep -q '^RUN queue-pending' <<<"$OUT" && ok \
  || bad "B3: a 403 on the PR state read must empty PRV and RUN (got: $OUT)"
: > "$H/logs/READY-QUEUE.log"

# N4 — a 404 on a single PR is a real ABSENT (rc 44), never "open".
b_setup
ctl pull-one 404 '{"message":"Not Found"}'
RC=0
S=$( . "$H/bin/lib/gh-rest.sh"; gh_rest_pr_state "$SLUG" 99 ) || RC=$?
[ "$RC" = 44 ] && ok || bad "N4: a 404 on one PR must be rc 44 (rc $RC)"
[ -z "$S" ] && ok || bad "N4: a 404 must print no state word (got: $S)"

# ════════════════════════════════════════════════════════════════════════════
# §C — bin/dep-verify.sh
# ════════════════════════════════════════════════════════════════════════════
dv() { OUT=$("$H/bin/dep-verify.sh" proj 7 6 2>/dev/null); RC=$?; }

c_setup() {
  ctl_reset
  scratch_rm "$H/state/dep-verify"
  mkdir -p "$H/plans/proj-AB-7"
  printf 'src/child/only.ts\n' > "$H/plans/proj-AB-7/planned-files.txt"
  # plan.md carries the DEPENDS line; C2b writes one and every other case needs
  # it absent, so the reset owns it.
  rm -f "$H/plans/proj-AB-7/plan.md"
  scratch_rm "$H/plans/proj-AB-6"
  ctl issue-one 200 '{"number":7,"body":"a plain body with no markers"}'
  ctl pulls 200 '[]'
  unset DEP_PRS_FILE DEP_CHILD_BODY_FILE
}

# C1 — a 403 on the PR list: UNKNOWN naming the status, exit 0.
c_setup
ctl pulls 403 "$RATE_BODY"
dv
[ "$RC" = 0 ] && ok || bad "C1: dep-verify always exits 0 (rc $RC)"
grep -qE '^UNKNOWN .*HTTP 403' <<<"$OUT" && ok \
  || bad "C1: a 403 PR list must answer UNKNOWN naming the status (got: $OUT)"
grep -q '#6' <<<"$OUT" && ok || bad "C1: the UNKNOWN must name the blocker (got: $OUT)"

# C3 — that UNKNOWN is never cached: an outage cannot freeze in.
[ ! -d "$H/state/dep-verify" ] || [ -z "$(find "$H/state/dep-verify" -type f 2>/dev/null)" ] \
  && ok || bad "C3: an UNKNOWN under a 403 was written to state/dep-verify/"

# C2 — a 403 on the child's issue body: UNKNOWN naming the body, never an empty
# body that silently drops the author's hard-marker escape hatch.
c_setup
ctl issue-one 403 "$RATE_BODY"
dv
grep -qE '^UNKNOWN .*HTTP 403' <<<"$OUT" && ok \
  || bad "C2: an unreadable body must answer UNKNOWN naming the status (got: $OUT)"
grep -q 'body' <<<"$OUT" && ok || bad "C2: the UNKNOWN must say it is the body (got: $OUT)"

# C2b — AND IT COSTS NOTHING ELSE. UNKNOWN is not a hold: DEP_UNKNOWN_MODE
# defaults to soft and soft RELEASES the child (bin/unblocked-children.sh), so
# an UNKNOWN recorded AT the body read would throw away the two verdicts below
# it that can still answer HARD — and turn a fail-closed hold into a go because
# github.com answered 403. Here the child's own pre-plan, a file on LOCAL disk,
# declares the dependency hard.
c_setup
printf 'DEPENDS: #6 hard — needs the symbol #6 adds\n' > "$H/plans/proj-AB-7/plan.md"
ctl issue-one 403 "$RATE_BODY"
dv
grep -qE '^HARD .*DEPENDS' <<<"$OUT" && ok \
  || bad "C2b: a local pre-plan's DEPENDS hard must survive a 403 on the issue body (got: $OUT)"

# C2c — the other one: the file overlap, computed from a PR list that WAS read.
c_setup
ctl issue-one 403 "$RATE_BODY"
ctl pulls 200 '[
 {"number":41,"title":"AB-6: the parent","body":"",
  "state":"open","merged_at":null,
  "head":{"ref":"ticket/ab-6","sha":"sha41"},"base":{"ref":"main"},
  "draft":false,"user":{"login":"operator","type":"User"},
  "created_at":"2026-09-17T00:00:00Z","updated_at":"2026-09-18T00:00:00Z",
  "closed_at":null,"labels":[],
  "html_url":"https://github.com/example-org/proj/pull/41"}
]'
ctl pr-files 200 '[{"filename":"src/child/only.ts"}]'
dv
grep -qE '^HARD .*overlap' <<<"$OUT" && ok \
  || bad "C2c: a file overlap from a PR list that read fine must survive a 403 on the body (got: $OUT)"

# C4 — 200 with a MERGED parent (REST says merged with merged_at, not a state
# word) is ranked MERGED and its files are the evidence.
c_setup
ctl pulls 200 '[
 {"number":41,"title":"AB-6: the parent","body":"",
  "state":"closed","merged_at":"2026-09-18T09:00:00Z",
  "head":{"ref":"ticket/ab-6","sha":"sha41"},"base":{"ref":"main"},
  "draft":false,"user":{"login":"operator","type":"User"},
  "created_at":"2026-09-17T00:00:00Z","updated_at":"2026-09-18T00:00:00Z",
  "closed_at":"2026-09-18T09:00:00Z","labels":[],
  "html_url":"https://github.com/example-org/proj/pull/41"}
]'
ctl pr-files 200 '[{"filename":"src/child/only.ts"}]'
dv
grep -qE '^HARD .*overlap' <<<"$OUT" && ok \
  || bad "C4: a merged parent whose files overlap must answer HARD (got: $OUT)"
grep -q 'merged PR' <<<"$OUT" && ok \
  || bad "C4: merged_at must rank as MERGED, not as CLOSED (got: $OUT)"

# C5 — DEP_PRS_FILE short-circuits the whole read: not one gh invocation.
c_setup
echo '[]' > "$T/prs-given.json"
printf 'a plain body\n' > "$T/child-body.txt"
: > "$GH_ARGV"
OUT=$(DEP_PRS_FILE="$T/prs-given.json" DEP_CHILD_BODY_FILE="$T/child-body.txt" \
      "$H/bin/dep-verify.sh" proj 7 6 2>/dev/null); RC=$?
[ ! -s "$GH_ARGV" ] && ok || bad "C5: DEP_PRS_FILE must cost no gh call (got: $(cat "$GH_ARGV"))"
grep -q '^UNKNOWN' <<<"$OUT" && ok || bad "C5: no evidence anywhere is UNKNOWN (got: $OUT)"

# C6 — A DEGRADED TICK IS NOT SERVED FROM THE CACHE (BH-782 review r2). The
# fingerprint is built from BSRCID, and BSRCID is read out of the PR list — which
# on a failed read is the `[]` this script wrote itself. So a blocker whose
# evidence is its own pre-plan (no PR) fingerprints IDENTICALLY whether the list
# said "no PR" or could not be read at all, and one healthy tick would otherwise
# let every later 403 replay that tick's SOFT with rc 0. SOFT is a RELEASE: the
# child builds on the strength of a read that never happened, and §2b — the
# whole point of this change — is never reached.
c_setup
mkdir -p "$H/plans/proj-AB-6"
printf 'src/parent/far.ts\n' > "$H/plans/proj-AB-6/planned-files.txt"
printf 'DEPENDS: #6 soft — same area, different files\n' > "$H/plans/proj-AB-7/plan.md"
dv
grep -qE '^SOFT ' <<<"$OUT" && ok \
  || bad "C6: a healthy tick with disjoint files and a soft DEPENDS must answer SOFT (got: $OUT)"
[ -n "$(find "$H/state/dep-verify" -type f 2>/dev/null)" ] && ok \
  || bad "C6: a definite verdict must still be cached"
# The same tick again, still healthy: the cache is served, and cheaply.
dv
grep -qE '^SOFT ' <<<"$OUT" && ok || bad "C6: a healthy re-ask must replay the cached SOFT (got: $OUT)"
# Now the list cannot be read. Nothing moved, so the fingerprint still matches —
# and that is exactly the trap: the answer must be UNKNOWN, not the cached SOFT.
ctl pulls 403 "$RATE_BODY"
dv
grep -qE '^UNKNOWN .*HTTP 403' <<<"$OUT" && ok \
  || bad "C6: a 403 on the PR list must not replay a cached SOFT (got: $OUT)"
[ "$RC" = 0 ] && ok || bad "C6: dep-verify always exits 0 (rc $RC)"
# …and the healthy answer is still there once the read works again: the degraded
# tick neither served the cache nor destroyed it.
ctl pulls 200 '[]'
dv
grep -qE '^SOFT ' <<<"$OUT" && ok \
  || bad "C6: the cached SOFT must survive the outage that refused to serve it (got: $OUT)"

# ════════════════════════════════════════════════════════════════════════════
# §D — bin/overlap-guard.sh
# ════════════════════════════════════════════════════════════════════════════
CF="$H/state/overlap-guard/proj-prs.json"
og() { OUT=$("$H/bin/overlap-guard.sh" proj AB-1 2>/dev/null); RC=$?; }
# Where the D5/D6 fixture lib records what the guard asked it.
export GHRT_USED="$T/ghrt-used" GHRT_ALERTED="$T/ghrt-alerted"

d_setup() {
  ctl_reset
  scratch_rm "$H/state/overlap-guard"
  mkdir -p "$H/plans/proj-AB-1"
  printf 'src/lib/pay.ts\n' > "$H/plans/proj-AB-1/planned-files.txt"
  : > "$H/logs/overlap-guard.log"
  # The DEFER arm's alert is once per project per UTC day, so the day flag is
  # part of the fixture: leaving it behind would make the next case's alert
  # assertion pass or fail on the order the cases run in.
  : > "$H/logs/ALERTS.log"
  rm -f "$H/flags"/alerted-overlap-gh-unknown-*
  # D5/D6 drop a FIXTURE bin/lib/gh-repo-token.sh into the scratch tree; every
  # other case in this file is about a box that has no such lib (see the copy
  # list at the top), so the reset owns removing it.
  rm -f "$H/bin/lib/gh-repo-token.sh"
  : > "$GHRT_USED"; : > "$GHRT_ALERTED"
}

# D1 — the open-PR list is unreadable and there is NO cache: DEFER, rc 1.
# The guard asks for `files`, a GraphQL-only LIST field, so this read rides the
# per-author path by design (BH-782 ASSUMPTIONS A2) and the status word is the
# honest `n/a` rather than an HTTP number nothing saw (D26).
d_setup
echo fail > "$T/ctl/graphql.mode"
og
[ "$RC" = 1 ] && ok || bad "D1: an unreadable PR list with no cache must DEFER rc 1 (rc $RC, out: $OUT)"
grep -qE '^DEFER AB-1 gh unknown \(HTTP [^)]*\)' <<<"$OUT" && ok \
  || bad "D1: the DEFER line must name the gh-unknown reason (got: $OUT)"
grep -q 'gh unknown' "$H/logs/overlap-guard.log" && ok \
  || bad "D1: the reason must be in logs/overlap-guard.log (got: $(cat "$H/logs/overlap-guard.log"))"

# D1a — STOPPING IS AN ALERT, NOT A WHISPER. This arm holds back every ticket of
# the project for as long as the read fails, and logs/overlap-guard.log is a
# per-guard log nobody polls. One ALERTS.log line, once per project per UTC day
# (a 2-minute cron must not turn an outage into a thousand lines), naming what
# is stuck and what would unstick it.
[ "$(grep -c 'overlap-guard/proj' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "D1a: expected exactly one ALERTS.log line (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"
grep -q 'Needs (operator)' "$H/logs/ALERTS.log" && ok \
  || bad "D1a: the alert must name what is needed and from whom"
og; og
[ "$(grep -c 'overlap-guard/proj' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "D1a: the alert must not repeat every tick (got $(grep -c 'overlap-guard/proj' "$H/logs/ALERTS.log") lines)"
[ "$RC" = 1 ] && ok || bad "D1a: the DEFER itself must still stand on later ticks (rc $RC)"

# D1b — the #768 shape exactly: every author exits 0 and prints NOTHING.
d_setup
echo silent > "$T/ctl/graphql.mode"
og
[ "$RC" = 1 ] && ok || bad "D1b: all-authors-silent must DEFER, not launch (rc $RC, out: $OUT)"
grep -q '^DEFER AB-1 gh unknown' <<<"$OUT" && ok || bad "D1b: wrong verdict shape (got: $OUT)"

# D1c — an outage NEVER overwrites the cache.
d_setup
mkdir -p "$H/state/overlap-guard"
printf '[{"number":77,"url":"u","headRefName":"ticket/ab-77","isDraft":false,"files":[{"path":"src/other/far.ts"}]}]' > "$CF"
BEFORE=$(sha256sum < "$CF")
echo silent > "$T/ctl/graphql.mode"
og
AFTER=$(sha256sum < "$CF")
[ "$BEFORE" = "$AFTER" ] && ok || bad "D1c: a failed read overwrote the cache"

# D2 — a present cache is authoritative when the fresh read fails: judged from
# it, never the gh-unknown DEFER (N7, R16).
[ "$RC" = 0 ] && ok || bad "D2: a disjoint cache must still LAUNCH under an outage (rc $RC, out: $OUT)"
! grep -q 'gh unknown' <<<"$OUT" && ok || bad "D2: a present cache must not answer gh unknown (got: $OUT)"
# …and the same cache holding a COLLIDING PR defers on the files, not on gh.
d_setup
mkdir -p "$H/state/overlap-guard"
printf '[{"number":78,"url":"u","headRefName":"ticket/ab-78","isDraft":false,"files":[{"path":"src/lib/pay.ts"}]}]' > "$CF"
echo silent > "$T/ctl/graphql.mode"
og
[ "$RC" = 1 ] && ok || bad "D2b: a colliding cached PR must DEFER (rc $RC, out: $OUT)"
grep -q '^DEFER AB-1 vs PR#78' <<<"$OUT" && ok || bad "D2b: the DEFER must name the cached PR (got: $OUT)"

# D3 — the kill switch reads nothing and never DEFERs (N5).
d_setup
echo fail > "$T/ctl/graphql.mode"
OUT=$(OVERLAP_GUARD=0 "$H/bin/overlap-guard.sh" proj AB-1 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "D3: OVERLAP_GUARD=0 must exit 0 (rc $RC)"
[ ! -s "$GH_ARGV" ] && ok || bad "D3: the kill switch must stop it before any gh call"
! grep -q DEFER <<<"$OUT" && ok || bad "D3: the kill switch must never DEFER (got: $OUT)"

# D4 — no `gh` binary at all keeps the PRE-EXISTING fail-open (N6). The new
# DEFER is only for "we asked and could not read the answer".
# A PATH with every /usr/bin and /bin command EXCEPT gh. `command -v gh` is what
# the guard checks, and this box has a real gh installed — so simply trimming
# PATH to /usr/bin:/bin would still find one and this case would silently test
# "a real gh that failed" instead of "no gh at all".
nogh_path() {
  local d="$T/nogh"
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    find /usr/bin /bin -maxdepth 1 \( -type f -o -type l \) ! -name gh -print0 2>/dev/null \
      | xargs -0 -r ln -sf -t "$d"
  fi
  printf '%s' "$d"
}
d_setup
OUT=$(PATH="$(nogh_path)" "$H/bin/overlap-guard.sh" proj AB-1 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "D4: no gh binary must LAUNCH (rc $RC, out: $OUT)"
grep -q '^LAUNCH AB-1' <<<"$OUT" && ok || bad "D4: no gh binary must print LAUNCH (got: $OUT)"

# D5 — A REPO NO CREDENTIAL CAN SEE IS NOT AN OUTAGE (BH-782 review r2).
# #768's lie was weather: a read that failed this tick and answers next tick, so
# re-offering the ticket costs two minutes. "The hub's default PAT 404s on this
# repo" — the documented example-org/project-5 case — is not weather. The same
# three rungs answer the same 404 on every one of the 2-minute ticks, so a DEFER
# there means the project never builds again and the only remedy is a kill flag
# somebody has to notice. That is the FAIL-OPEN case this guard was built for.
#
# The real bin/lib/gh-repo-token.sh probes live credentials, so what is pinned
# here is the CONTRACT this guard has with it: ask gh_repo_use_token BEFORE the
# list, and read rc 1 as "nobody can see it" -> one gh_repo_invisible_alert and
# a LAUNCH.
d_setup
cat > "$H/bin/lib/gh-repo-token.sh" <<'RT'
gh_repo_use_token() { printf '%s\n' "$1" >> "$GHRT_USED"; return 1; }
gh_repo_invisible_alert() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$GHRT_ALERTED"; }
RT
echo fail > "$T/ctl/graphql.mode"
og
[ "$RC" = 0 ] && ok || bad "D5: an invisible repo must LAUNCH, not DEFER for ever (rc $RC, out: $OUT)"
grep -q '^LAUNCH AB-1 no gh credential can see' <<<"$OUT" && ok \
  || bad "D5: the LAUNCH must say which question could not be asked (got: $OUT)"
grep -qx "$SLUG" "$GHRT_USED" && ok \
  || bad "D5: the guard must ask the ladder which credential can see the repo (got: $(cat "$GHRT_USED"))"
grep -q "^overlap-guard|$SLUG|" "$GHRT_ALERTED" && ok \
  || bad "D5: an invisible repo must raise the fleet's invisible-repo alert (got: $(cat "$GHRT_ALERTED"))"
! grep -q DEFER <<<"$OUT" && ok || bad "D5: an invisible repo must never DEFER (got: $OUT)"

# D6 — and the arm above does NOT swallow the real outage. Same unreadable list,
# but a rung CAN see the repo: that is weather, so the DEFER still stands and no
# invisible-repo alert is raised.
d_setup
cat > "$H/bin/lib/gh-repo-token.sh" <<'RT'
gh_repo_use_token() { printf '%s\n' "$1" >> "$GHRT_USED"; return 0; }
gh_repo_invisible_alert() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$GHRT_ALERTED"; }
RT
echo fail > "$T/ctl/graphql.mode"
og
[ "$RC" = 1 ] && ok || bad "D6: a VISIBLE repo whose list is unreadable must still DEFER (rc $RC, out: $OUT)"
grep -qx "$SLUG" "$GHRT_USED" && ok \
  || bad "D6: the ladder must be armed BEFORE the list, not after it"
[ ! -s "$GHRT_ALERTED" ] && ok \
  || bad "D6: a repo a credential CAN see must not raise the invisible-repo alert"

# D7 — the per-project kill flag. The DEFER arm holds back a whole project, so
# its remedy must not be "turn the guard off for the entire fleet".
d_setup
: > "$H/flags/overlap-guard-off-proj"
echo fail > "$T/ctl/graphql.mode"
og
rm -f "$H/flags/overlap-guard-off-proj"
[ "$RC" = 0 ] && ok || bad "D7: flags/overlap-guard-off-<project> must exit 0 (rc $RC)"
[ ! -s "$GH_ARGV" ] && ok || bad "D7: the per-project kill flag must stop it before any gh call"
[ -z "$OUT" ] && ok || bad "D7: the per-project kill flag must print nothing (got: $OUT)"

# D7b — PER project: another project's flag must not silence this one.
d_setup
: > "$H/flags/overlap-guard-off-other"
echo fail > "$T/ctl/graphql.mode"
og
rm -f "$H/flags/overlap-guard-off-other"
[ "$RC" = 1 ] && ok \
  || bad "D7b: another project's kill flag must not silence this one (rc $RC, out: $OUT)"

# ════════════════════════════════════════════════════════════════════════════
# §F — bin/lib/gh-pr-list.sh
# ════════════════════════════════════════════════════════════════════════════
# F1 — the marker census (R2).
for f in bin/lib/gh-rest.sh bin/lib/gh-pr-list.sh bin/preplan-candidates.sh \
         bin/triage-gate.sh bin/overlap-guard.sh bin/dep-verify.sh; do
  if grep -qx '# gh-rest: no-graphql' "$DIR/$f"; then ok
  else bad "F1: $f does not carry the '# gh-rest: no-graphql' marker"; fi
done

# drive <lib> <expr> — source a gh-pr-list.sh and evaluate one call in a
# subshell that carries the stub's environment.
drive() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" GH_ARGV="$GH_ARGV" GH_CTL="$GH_CTL"
    unset HARNESS_PR_AUTHORS GH_PR_LIST_REST_PAGES
    # shellcheck source=/dev/null
    . "$1"; eval "$2" )
}
LIB="$H/bin/lib/gh-pr-list.sh"

f_case() { # f_case <label> <route-status> [body] -> RC
  ctl_reset
  ctl pulls "$1" "${2-}"
  RC=0
  drive "$LIB" 'harness_pr_list example-org/proj open number,title 10' >/dev/null 2>&1 || RC=$?
}

# F2 — 404 is rc 44.
f_case 404 '{"message":"Not Found"}'
[ "$RC" = 44 ] && ok || bad "F2: a 404 REST list must be rc 44 (rc $RC)"
! grep -q 'pr list' "$GH_ARGV" && ok || bad "F4: a 404 was retried over GraphQL (got: $(cat "$GH_ARGV"))"

# F3 — everything else unreadable is rc 75, and none of it is retried (F4).
f_case 403 "$RATE_BODY"
[ "$RC" = 75 ] && ok || bad "F3: a 403 REST list must be rc 75 (rc $RC)"
! grep -q 'pr list' "$GH_ARGV" && ok || bad "F4: a 403 was retried over GraphQL"
f_case 429 "$RATE_BODY"
[ "$RC" = 75 ] && ok || bad "F3: a 429 REST list must be rc 75 (rc $RC)"
! grep -q 'pr list' "$GH_ARGV" && ok || bad "F4: a 429 was retried over GraphQL"
f_case 000
[ "$RC" = 75 ] && ok || bad "F3: a network failure (no status line) must be rc 75 (rc $RC)"
! grep -q 'pr list' "$GH_ARGV" && ok || bad "F4: a network failure was retried over GraphQL"
f_case 200 '{"message":"not an array"}'
[ "$RC" = 75 ] && ok || bad "F3: a 2xx non-array body must be rc 75 (rc $RC)"
! grep -q 'pr list' "$GH_ARGV" && ok || bad "F4: a non-array body was retried over GraphQL"
f_case 200
[ "$RC" = 75 ] && ok || bad "F3: a 2xx EMPTY body must be rc 75 (rc $RC)"
! grep -q 'pr list' "$GH_ARGV" && ok || bad "F4: an empty body was retried over GraphQL"

# N1/N3 — a 200 that really says [] is a real empty, and a 2xx whose body
# happens to contain "rate limit" is a SUCCESSFUL read (D10).
ctl_reset; ctl pulls 200 '[]'
RC=0; O=$(drive "$LIB" 'harness_pr_list example-org/proj open number,title 10' 2>/dev/null) || RC=$?
[ "$RC" = 0 ] && [ "$O" = "[]" ] && ok || bad "N1: 200 + [] must be rc 0 and [] (rc $RC, out: $O)"
ctl_reset
ctl pulls 200 "$(jq -c '.[0].title = "handle rate limit errors"' <<<"$PULLS_OK")"
RC=0; O=$(drive "$LIB" 'harness_pr_list example-org/proj open number,title 10' 2>/dev/null) || RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$O")" = "[99]" ] && ok \
  || bad "N3: a 2xx body containing 'rate limit' is a successful read (rc $RC, out: $O)"

# F5 — the per-author path (an unmappable field) counts a SILENT author as a
# FAILED author, never as an empty list.
# TEST-CHANGE (BH-1585): `files` is a lazy REST field now, so the per-author
# path is reached through a field no read carries (potentialMergeCommit) with
# the opt-in GH_PR_LIST_GRAPHQL_FALLBACK=1 — here and in E2 below. The
# assertions are unchanged.
ctl_reset; echo silent > "$T/ctl/graphql.mode"
RC=0; O=$(drive "$LIB" 'GH_PR_LIST_GRAPHQL_FALLBACK=1 harness_pr_list example-org/proj open number,potentialMergeCommit 10' 2>/dev/null) || RC=$?
[ "$RC" = 1 ] && ok || bad "F5: every author silent must be rc 1, not an empty list (rc $RC, out: $O)"
ctl_reset
printf '[{"number":5,"files":[{"path":"a.ts"}]}]' > "$T/ctl/graphql-operator.body"
RC=0; O=$(drive "$LIB" 'GH_PR_LIST_GRAPHQL_FALLBACK=1 harness_pr_list example-org/proj open number,potentialMergeCommit 10' 2>/dev/null) || RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[].number]' <<<"$O")" = "[5]" ] && ok \
  || bad "F5: one silent author must not sink the one that answered (rc $RC, out: $O)"

# F6 — BH-847's token-rung retry still arms off a REST rate-limit shape.
rung_drive() { # rung_drive <lib> -> RC, and $GH_ARGV counts the REST attempts
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" GH_ARGV="$GH_ARGV" GH_CTL="$GH_CTL"
    unset HARNESS_PR_AUTHORS GH_PR_LIST_REST_PAGES
    gh_repo_current_rung() { echo app; }
    gh_repo_next_rung() { _GHRT_RUNG=admin; return 0; }
    # shellcheck source=/dev/null
    . "$1"
    harness_pr_list example-org/proj open number,title 10 >/dev/null 2>&1 )
}
ctl_reset; ctl pulls 429 "$RATE_BODY"
rung_drive "$LIB"; RC=$?
[ "$RC" = 75 ] && ok || bad "F6: a 429 on both rungs still answers 75 (rc $RC)"
[ "$(grep -c 'api -i' "$GH_ARGV")" = 2 ] && ok \
  || bad "F6: the rung retry must fire exactly once (REST attempts: $(grep -c 'api -i' "$GH_ARGV"))"

# ════════════════════════════════════════════════════════════════════════════
# §E — mutation checks (D1). Each mutation is applied to a COPY, the named
# case is re-run against it, and the case must go RED.
# ════════════════════════════════════════════════════════════════════════════
MUT="$T/mut"; mkdir -p "$MUT"

# E1 — restore the GraphQL retry after a REST failure ⇒ F4 goes red.
cp "$LIB" "$MUT/e1.sh"
python3 - "$MUT/e1.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "# gh-mutate: rest-failure-is-final"
i = s.index(anchor)
j = s.index("\n", i) + 1
# put the #768 retry back exactly where the anchor says it was removed
s = s[:j] + '      _harness_pr_list_fallback "$slug" "$state" "$fields" "$limit"; return $?\n' + s[j:]
open(p, "w").write(s)
PY
ctl_reset; ctl pulls 403 "$RATE_BODY"
printf '[{"number":1,"title":"x"}]' > "$T/ctl/graphql-operator.body"
drive "$MUT/e1.sh" 'harness_pr_list example-org/proj open number,title 10' >/dev/null 2>&1
grep -q 'pr list' "$GH_ARGV" && ok \
  || bad "E1 vacuous: restoring the GraphQL retry did NOT make F4 red"

# E2 — restore ${out:-[]} in the per-author path ⇒ F5 / D1b go red.
cp "$LIB" "$MUT/e2.sh"
python3 - "$MUT/e2.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
assert "# gh-mutate: empty-is-failure" in s, "the empty-is-failure anchor is gone"
s = s.replace('if out=$(gh pr list -R "$slug" --state "$state" --author "$a" --limit "$limit" --json "$fields" 2>"$err_file") && [ -n "$out" ]; then',
              'if out=$(gh pr list -R "$slug" --state "$state" --author "$a" --limit "$limit" --json "$fields" 2>"$err_file"); then')
s = s.replace('ok=1; acc="$acc$out"', 'ok=1; acc="$acc${out:-[]}"')
open(p, "w").write(s)
PY
ctl_reset; echo silent > "$T/ctl/graphql.mode"
RC=0; drive "$MUT/e2.sh" 'GH_PR_LIST_GRAPHQL_FALLBACK=1 harness_pr_list example-org/proj open number,potentialMergeCommit 10' >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && ok || bad "E2 vacuous: restoring \${out:-[]} did NOT make F5 red (rc $RC)"

# E3 — restore `[ -n "$PRS" ] || PRS='[]'` in preplan-candidates.sh ⇒ A2 red.
# The mutant lives in $H/bin: the script resolves its libs from $(dirname $0)/lib,
# so a copy anywhere else would die on a missing lib rather than on the mutation.
cp "$H/bin/preplan-candidates.sh" "$H/bin/preplan-mutant.sh"
python3 - "$H/bin/preplan-mutant.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# The UNKNOWN arm on the PR list becomes the old "empty means none" mapping.
s2 = s.replace('gh_rest_pr_list "$REPO" open "" 100 > "$GF" || gate_unknown',
               'gh_rest_pr_list "$REPO" open "" 100 > "$GF" 2>/dev/null || : > "$GF"\n'
               '  [ -s "$GF" ] || printf \'[]\' > "$GF"', 1)
assert s2 != s, "the preplan PR-list UNKNOWN arm did not match — E3 cannot mutate"
open(p, "w").write(s2)
PY
a_setup
ctl pulls 403 "$RATE_BODY"
MOUT=$("$H/bin/preplan-mutant.sh" proj 2>/dev/null)
grep -qE '^AB-7' <<<"$MOUT" && ok \
  || bad "E3 vacuous: restoring PRS='[]' did NOT make A2 red (got: $MOUT)"

# E4 — delete the _HPL_LIMITED line the REST classifier sets ⇒ F6 red.
cp "$LIB" "$MUT/e4.sh"
python3 - "$MUT/e4.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
out = [l for l in lines if "# gh-mutate: rung-arm" not in l]
assert len(out) != len(lines), "the rung-arm anchor is gone — E4 cannot mutate"
open(p, "w").write("\n".join(out))
PY
ctl_reset; ctl pulls 429 "$RATE_BODY"
rung_drive "$MUT/e4.sh"
[ "$(grep -c 'api -i' "$GH_ARGV")" = 1 ] && ok \
  || bad "E4 vacuous: deleting the rung arm did NOT stop the retry (attempts: $(grep -c 'api -i' "$GH_ARGV"))"

# ════════════════════════════════════════════════════════════════════════════
# §G — NO UNESCAPED BACKTICK INSIDE AN UNQUOTED HEREDOC, ANYWHERE IN tests/
# ════════════════════════════════════════════════════════════════════════════
# THE BUG THIS PINS (BH-782 round 1, caught in review). A `gh` stub was written
# with `cat > "$T/fakebin/gh" <<EOF` — an UNQUOTED delimiter, because the stub
# interpolates $T — and the explanatory comment added just above one of its case
# arms quoted a command in backticks. Inside an unquoted heredoc a backtick pair
# is a COMMAND SUBSTITUTION performed by the shell writing the file: the suite
# ran a real `gh api -i -X GET .../pulls?state=...` against api.github.com and
# spliced the answer into the stub it was generating. On a box where gh is
# installed that answer is multi-line and unbalanced, the stub no longer parses,
# and the suite went 108/0 -> 73/35. On a box without gh the substitution is
# empty and everything passes — which is why CI was green and the bug shipped.
#
# So the rule is a SCAN, not a rerun: it cannot depend on whether the runner has
# gh, or on what github.com happens to answer today.
#
# determinism: ok-file this section reads only file contents, no clock, no dice.
hd_scan() { # hd_scan <root> -> "file:line: text" per offender on stdout
  python3 - "$1" <<'HD'
import os, re, sys
root = sys.argv[1]
# Every heredoc is TRACKED; only the body of an UNQUOTED one is scanned. Quoted
# bodies (`<<'W'` / `<<"W"`) are literal text, and skipping them is also what
# keeps this suite — whose own §G fixtures contain the bad shape as DATA — from
# reporting itself. `<<<` is a here-STRING, not a heredoc: the lookarounds drop
# it. `\<<` and `2<<` cannot occur in this corpus and are not modelled.
OPEN = re.compile(r"""(?<!<)<<(?!<)-?\s*(?:'([A-Za-z_][A-Za-z0-9_]*)'|"([A-Za-z_][A-Za-z0-9_]*)"|([A-Za-z_][A-Za-z0-9_]*))\s*(?:$|[;)&|])""")
hits = []
for dirpath, _dirs, files in os.walk(os.path.join(root, "tests")):
    for fn in sorted(files):
        if not fn.endswith(".sh"):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, root)
        delim = None
        raw = False
        for i, line in enumerate(open(path, encoding="utf-8", errors="replace").read().split("\n"), 1):
            if delim is None:
                if line.lstrip().startswith("#"):
                    continue          # a heredoc never opens inside a comment
                m = OPEN.search(line)
                if m:
                    q1, q2, bare = m.groups()
                    delim = q1 or q2 or bare
                    raw = bare is None   # quoted delimiter -> literal body
                continue
            if line.strip() == delim:
                delim = None
                continue
            if raw:
                continue
            # A BACKSLASHED backtick is a literal one and is the documented way
            # to quote a command inside one of these bodies.
            if "`" in re.sub(r"\\.", "", line):
                hits.append("%s:%d: %s" % (rel, i, line.strip()[:100]))
for h in hits:
    print(h)
HD
}

# G1 — the scanner FINDS the shape, on a tree built here rather than on trust.
mkdir -p "$T/hd/tests"
cat > "$T/hd/tests/bad-test.sh" <<'BAD'
#!/bin/bash
cat > "$T/stub" <<EOF
# this comment runs `date` while the stub is being written
echo hi
EOF
BAD
cat > "$T/hd/tests/good-test.sh" <<'GOOD'
#!/bin/bash
cat > "$T/stub" <<'LIT'
# a quoted delimiter makes `date` literal
LIT
cat > "$T/other" <<EOF
# an escaped \`date\` is literal too
EOF
grep -q x <<<"a `echo b`"
GOOD
G=$(hd_scan "$T/hd")
grep -q 'tests/bad-test\.sh:3:' <<<"$G" && ok \
  || bad "G1: the scanner missed a backtick in an unquoted heredoc (got: $G)"
! grep -q 'good-test' <<<"$G" && ok \
  || bad "G1: the scanner flagged a quoted delimiter, an escaped backtick or a here-string (got: $G)"

# G2 — and the real tests/ tree is clean.
G=$(hd_scan "$DIR")
[ -z "$G" ] && ok || bad "G2: a test writes a stub that runs commands as it writes it:
$G"

echo "launch-gate-unknown.bh-782: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
