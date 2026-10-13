#!/bin/bash
# tests/pr-url-reconcile-test.sh — THE RECONCILER THAT RE-LINKS A BUILD RECORD TO
# THE PR IT ACTUALLY OPENED, AND PAGES WHEN THERE IS NONE.
#
# THE DEFECT (BH-848, 2026-09-18). A build whose `gh pr create` died on the App
# GraphQL cap writes `PR_CREATE_FAILED` as line 1. bin/merge-sweep.sh and
# bin/pipeline-health.sh both walk only records whose line 1 is `PR_CREATED
# https://…`, so once the PR is opened by a later path nothing on the hub ever
# re-links the record — ten CI-green APPROVE PRs sat unswept and the only symptom
# was that merges had flatlined. Silence, not an alert.
#
# WHAT THIS SUITE PINS (bin/pr-url-reconcile.sh, driven as the cron lane runs it,
# against a scratch $HARNESS and a stub `gh`):
#   (a) a failed record with an open PR on its branch is linked — ONE `PR:` line,
#       line 1 rewritten so the sweep can see it, the original kept as
#       RECONCILED_FROM:, one log line;
#   (b) a second run changes not one byte (idempotent, marker-terminal);
#   (c) HTTP 403 is UNKNOWN: no write, no alert — an outage is not "no PR" (D11);
#   (d) a record that already links a DIFFERENT, correct PR is never overwritten;
#   (e) a non-PR_CREATE_FAILED record is never touched;
#   (f) the cap is honoured and the skipped count is reported, never dropped (D12);
#   (g) APPROVE + no open PR = exactly one ALERTS line, once;
#   (h) BLOCK + no open PR = no alert (nothing is owed);
#   (i) a record whose `PR:` disagrees with the branch = one mislink alert, no write;
#   (k) a record that already carries the RIGHT `PR:` line still gets line 1
#       rewritten — a marker without a visible line 1 is a record lost for good;
#   (l) APPROVE + no OPEN PR but the PR is MERGED = no alert, nothing owed;
#   (l2) a PR that opened between the two reads = no alert either;
#   (m) APPROVE + the only PR on the branch CLOSED unmerged = an alert that says so;
#   (n) the fix command's `--base` is the stack's parent branch, not a blanket main;
#   (o) a REBUILD record (pipeline.log names ticket/<key>-r2) is asked about -r2,
#       never the stem — the r1 PR still open on the stem is NOT linked to it;
#   (o2) the same record with no open PR is paged for -r2, in the fix command too;
#   (o3) a pipeline.log that names only a STACKED parent falls back to the stem,
#       and the log says the record named no branch of its own;
#   (o4) a pipeline.log carrying only the taken-name bump line still resolves
#       -r2 off the last exact `<stem>-rN` name — the grep fallback, exercised;
#   (p) a MERGED answer marks the record terminal — the next tick reads nothing;
#   (q) a mislink marks the record terminal; removing the marker re-arms it;
#   (r) a record paged earlier for something ELSE still gets its mislink page,
#       exactly once, off the page's own marker;
#   (s) the UNKNOWN line quotes the stderr THIS read wrote — never another
#       record's, and the line it did write is quoted after `gh said:`;
#   (t) a RESUME_BUILD clears EVERY marker this lane writes;
#   (u) an already-paged APPROVE record still takes the state=all read: a PR
#       merged by hand seals it terminal, no second page; no PR = still re-readable.
#
# Run from anywhere: bash tests/pr-url-reconcile-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
# ONE clock read for the whole file (bin/test-determinism-lint.sh). Nothing below
# compares times; it only keeps the fixture record names unique and stable.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive the reconciler"; exit 1; }

LANE="$DIR/bin/pr-url-reconcile.sh"
[ -x "$LANE" ] || { echo "FAIL: bin/pr-url-reconcile.sh does not exist or is not executable"; exit 1; }
U834="https://github.com/example-org/cromford/pull/834"
U803="https://github.com/example-org/cromford/pull/803"
U812="https://github.com/example-org/cromford/pull/812"

# ── the stub gh ──────────────────────────────────────────────────────────────
# One response file per hub ($H/gh-response), raw over the wire, status line and
# all — the lane must read the HTTP status BEFORE the body. Every call is
# recorded; no token value is ever printed.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUBHUB/gh-calls.log"
# $STUBHUB/gh-stderr, when present, is what gh says on stderr for THIS call —
# case (s) asserts the lane quotes exactly that and nothing older.
[ -f "$STUBHUB/gh-stderr" ] && cat "$STUBHUB/gh-stderr" >&2
[ "${1:-}" = api ] || exit 1
# The state=all read is the lane's SECOND question ("is the PR simply finished?")
# and gets its own fixture, so a case can answer open and all differently.
case "$*" in
  *state=all*) [ -f "$STUBHUB/gh-response.all" ] && { cat "$STUBHUB/gh-response.all"; exit 0; } ;;
esac
# A per-HEAD fixture ($STUBHUB/gh-response.head.<owner>_<branch with / as _>) lets
# one case answer the stem and its -r2 differently — the rebuild cases need that.
HEADK=$(printf '%s' "$*" | grep -oE 'head=[^&]+' | head -n 1 | sed 's/^head=//; s#[/:]#_#g')
[ -n "$HEADK" ] && [ -f "$STUBHUB/gh-response.head.$HEADK" ] && { cat "$STUBHUB/gh-response.head.$HEADK"; exit 0; }
[ -f "$STUBHUB/gh-response" ] || { echo "stub gh: no fixture" >&2; exit 1; }
cat "$STUBHUB/gh-response"
STUB
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"

# ── a scratch hub ────────────────────────────────────────────────────────────
mkhub() { # mkhub <name> -> H is the scratch $HARNESS
  H="$T/$1"; scratch_rm "$H"
  mkdir -p "$H/bin/lib" "$H/builds" "$H/logs" "$H/locks" "$H/flags"
  cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
  cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-pr-create.sh" "$DIR/bin/lib/result-pr-url.sh" "$H/bin/lib/" 2>/dev/null
  printf 'cromford example-org/cromford - - 3 box-small 10.0.0.7\n' > "$H/fleet.conf"
  : > "$H/gh-calls.log"
  MAXV=50
}
record() { # record <name> <dir suffix> <RESULT line 1> [extra lines...]
  local d="$H/builds/$2"; mkdir -p "$d"
  shift 2
  printf '%s\n' "$@" > "$d/RESULT"
  printf 'VERDICT: APPROVE\nTIER: 2\n' > "$d/review.md"
  echo "$d"
}
resp() { # resp <status> <body>  — the state=open read
  printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2" > "$H/gh-response"
}
resp_head() { # resp_head <branch> <status> <body>  — the state=open read for ONE head
  printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$2" "$3" \
    > "$H/gh-response.head.example-org_$(sed 's#/#_#g' <<<"$1")"
}
resp_all() { # resp_all <status> <body>  — the state=all read
  printf 'HTTP/2.0 %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2" > "$H/gh-response.all"
}
run_lane() { # run_lane [extra env assignments...] -> the lane's true exit code
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" STUBHUB="$H"
    export PR_URL_RECONCILE_MAX="${MAXV:-50}"
    bash "$LANE" ) >"$H/stdout.txt" 2>&1
}

# ══ (a) a failed record gets linked ══════════════════════════════════════════
mkhub a
D=$(record a "pool-cromford-BH-800-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded for installation ID 161623167. — refused a url-less create claim carrying ''" \
  "TIER: 2" "BUILD_DIR: pool-cromford-BH-800")
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
RC=$?
[ "$RC" = 0 ] && ok || bad "(a) the lane must exit 0, got $RC: $(cat "$H/stdout.txt")"
head -1 "$D/RESULT" | grep -qE "^PR_CREATED $U834 \| RECONCILED " \
  && ok || bad "(a) line 1 must become 'PR_CREATED <url> | RECONCILED …' so the sweep can see it, got: $(head -1 "$D/RESULT")"
[ "$(grep -c "^PR: $U834$" "$D/RESULT")" = 1 ] \
  && ok || bad "(a) exactly one PR: line, got: $(cat "$D/RESULT")"
[ "$(grep -c '^RECONCILED_FROM: PR_CREATE_FAILED' "$D/RESULT")" = 1 ] \
  && ok || bad "(a) the original line 1 must be kept as RECONCILED_FROM:, got: $(cat "$D/RESULT")"
[ "$(grep -c 'linked' "$H/logs/pr-url-reconcile.log")" = 1 ] \
  && ok || bad "(a) exactly one 'linked' log line, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
grep -q "$(basename "$D")" "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(a) the log line must name the record dir"
[ -f "$H/logs/ALERTS.log" ] && bad "(a) a record that linked cleanly must not alert" || ok

# ══ (b) a second run changes nothing ═════════════════════════════════════════
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
run_lane
SHA2=$(sha256sum "$D/RESULT" | awk '{print $1}')
[ "$SHA1" = "$SHA2" ] && ok || bad "(b) a second run must leave the RESULT byte-identical"
[ "$(grep -c 'linked' "$H/logs/pr-url-reconcile.log")" = 1 ] \
  && ok || bad "(b) a second run must not re-link, got: $(grep -c 'linked' "$H/logs/pr-url-reconcile.log") lines"
# Write THEN mark: the marker is what makes a linked record terminal, whatever
# any later hand-edit does to line 1. A link with no marker would be re-asked.
[ -f "$D/.pr-url-reconciled" ] \
  && ok || bad "(b) a linked record must carry the terminal marker .pr-url-reconciled"

# ══ (c) HTTP 403 is UNKNOWN: no write, no alert ══════════════════════════════
mkhub c
D=$(record c "pool-cromford-BH-801-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
resp '403 Forbidden' '{"message":"API rate limit exceeded."}'
run_lane
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(c) a 403 must leave the RESULT byte-identical, got: $(cat "$D/RESULT")"
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(c) a failed READ is UNKNOWN, never 'no PR' — it must not alert: $(cat "$H/logs/ALERTS.log")" || ok
grep -qi 'unknown' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(c) the log must record the read as UNKNOWN, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"

# ══ (d) a correct link is never overwritten ══════════════════════════════════
mkhub d
D=$(record d "pool-cromford-BH-802-2026091808$NOW" \
  "PR_CREATED https://github.com/example-org/cromford/pull/5" "TIER: 2")
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
resp '200 OK' '[{"html_url":"https://github.com/example-org/cromford/pull/6"}]'
run_lane
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(d) a record already linked to a PR must never be rewritten, got: $(cat "$D/RESULT")"
[ "$(grep -c 'api' "$H/gh-calls.log")" = 0 ] \
  && ok || bad "(d) a linked record must not even be asked about, got: $(cat "$H/gh-calls.log")"

# ══ (e) a non-create-failure record is never touched ═════════════════════════
mkhub e
D=$(record e "pool-cromford-BH-803-2026091808$NOW" "PLAN_BLOCKED the thread is ambiguous")
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(e) a PLAN_BLOCKED record must be untouched, got: $(cat "$D/RESULT")"

# ══ (f) the cap is honoured AND the remainder is reported ════════════════════
mkhub f
for i in $(seq 1 60); do
  record f "pool-cromford-BH-9$i-2026091808$NOW" \
    "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''" >/dev/null
done
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
MAXV=10 run_lane
LINKED=$(grep -c 'linked' "$H/logs/pr-url-reconcile.log" 2>/dev/null || true)
[ "$LINKED" = 10 ] && ok || bad "(f) PR_URL_RECONCILE_MAX=10 must link exactly 10, got $LINKED"
grep -q 'unwalked=50' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(f) the summary must report unwalked=50, got: $(grep 'tick' "$H/logs/pr-url-reconcile.log" 2>/dev/null)"

# ══ (g) APPROVE + no open PR = exactly one ALERT ═════════════════════════════
mkhub g
D=$(record g "pool-cromford-BH-1-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
printf 'lots of review text\nVERDICT: APPROVE\n' > "$D/review.md"
resp '200 OK' '[]'
run_lane
[ "$(grep -c 'no open PR on ticket/bh-1' "$H/logs/ALERTS.log" 2>/dev/null || true)" = 1 ] \
  && ok || bad "(g) an APPROVE record with no PR must write ONE ALERTS line, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'gh pr create --head ticket/bh-1' "$H/logs/ALERTS.log" \
  && ok || bad "(g) the ALERT must name the command that fixes it"
run_lane
[ "$(grep -c 'no open PR on ticket/bh-1' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(g) a second run must not repeat the alert, got: $(cat "$H/logs/ALERTS.log")"

# ══ (h) BLOCK + no open PR = no alert ════════════════════════════════════════
mkhub h
D=$(record h "pool-cromford-BH-2-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
printf 'lots of review text\nVERDICT: BLOCK\n' > "$D/review.md"
resp '200 OK' '[]'
run_lane
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(h) a BLOCKed build owes no PR — it must not alert: $(cat "$H/logs/ALERTS.log")" || ok

# ══ (i) a disagreeing PR: line is alerted, never rewritten ═══════════════════
mkhub i
D=$(record i "pool-cromford-BH-776-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ' | STACKED on ticket/bh-775 (example-org/cromford PR 803)'" \
  "TIER: 2" "PR: $U803")
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
resp '200 OK' "[{\"html_url\":\"$U812\"}]"
run_lane
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(i) a mislinked record must be left alone, got: $(cat "$D/RESULT")"
[ "$(grep -c 'mislinked' "$H/logs/ALERTS.log" 2>/dev/null || true)" = 1 ] \
  && ok || bad "(i) a mislinked record must produce ONE alert, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "$U812" "$H/logs/ALERTS.log" \
  && ok || bad "(i) the alert must name the PR the branch really resolves to"
# (q) terminal: a human edit is the only exit, so the next tick must not spend a
# REST read on it — and removing the marker re-arms exactly one read, no re-page.
[ -f "$D/.pr-url-reconcile-mislinked" ] \
  && ok || bad "(q) a mislinked record must carry .pr-url-reconcile-mislinked"
: > "$H/gh-calls.log"
run_lane
[ "$(grep -c 'api' "$H/gh-calls.log")" = 0 ] \
  && ok || bad "(q) a marked mislink must not be asked about again, got: $(cat "$H/gh-calls.log")"
rm -f "$D/.pr-url-reconcile-mislinked"
run_lane
[ "$(grep -c 'api' "$H/gh-calls.log")" = 1 ] \
  && ok || bad "(q) removing the marker must re-arm exactly one read, got: $(cat "$H/gh-calls.log")"
[ "$(grep -c 'mislinked' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(q) re-arming must not page a second time, got: $(cat "$H/logs/ALERTS.log")"
[ -f "$D/.pr-url-reconcile-mislinked" ] \
  && ok || bad "(q) the re-armed walk must mark it terminal again"

# ══ (j) the kill switch ══════════════════════════════════════════════════════
mkhub j
D=$(record j "pool-cromford-BH-804-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
touch "$H/flags/pr-url-reconcile-off"
run_lane
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(j) flags/pr-url-reconcile-off must stop the lane before the walk"
[ "$(grep -c 'api' "$H/gh-calls.log")" = 0 ] \
  && ok || bad "(j) the kill switch must make zero GitHub calls"

# ══ (k) a record that already carries the RIGHT PR: still gets line 1 ════════
# The hand-backfill shape: `PR: <url>` appended, line 1 left saying the create
# failed. bin/merge-sweep.sh never reads past line 1, so marking this terminal
# without rewriting it would make the record invisible FOREVER, with a marker
# claiming it was handled.
mkhub k
D=$(record k "pool-cromford-BH-805-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''" \
  "TIER: 2" "PR: $U834")
resp '200 OK' "[{\"html_url\":\"$U834\"}]"
run_lane
head -1 "$D/RESULT" | grep -qE "^PR_CREATED $U834 \| RECONCILED " \
  && ok || bad "(k) line 1 must be rewritten for a record that already carries the link, got: $(head -1 "$D/RESULT")"
[ "$(grep -c "^PR: $U834$" "$D/RESULT")" = 1 ] \
  && ok || bad "(k) the PR: line it already had must not be appended twice, got: $(cat "$D/RESULT")"
[ "$(grep -c '^RECONCILED_FROM: PR_CREATE_FAILED' "$D/RESULT")" = 1 ] \
  && ok || bad "(k) the original line 1 must be kept as RECONCILED_FROM:, got: $(cat "$D/RESULT")"
[ -f "$D/.pr-url-reconciled" ] \
  && ok || bad "(k) the record must be marked terminal once line 1 is right"
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(k) a record whose link agrees with the branch must not alert: $(cat "$H/logs/ALERTS.log")" || ok
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
run_lane
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(k) a second run must leave it byte-identical"

# ══ (l) APPROVE, no OPEN PR, but the PR is MERGED = nothing owed ═════════════
# Wrong advice is worse than none: "open it by hand" about a PR already in main
# sends an operator to open a duplicate. The lane asks state=all before it pages.
mkhub l
D=$(record l "pool-cromford-BH-806-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
SHA1=$(sha256sum "$D/RESULT" | awk '{print $1}')
resp '200 OK' '[]'
resp_all '200 OK' "[{\"html_url\":\"$U803\",\"state\":\"closed\",\"merged_at\":\"2026-09-17T10:00:00Z\"}]"
run_lane
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(l) a merged PR owes nothing — the lane must not page: $(cat "$H/logs/ALERTS.log")" || ok
grep -q 'is merged' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(l) the log must say the PR is merged, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
[ "$(sha256sum "$D/RESULT" | awk '{print $1}')" = "$SHA1" ] \
  && ok || bad "(l) a merged PR is not linked over a state=open answer of [] — nothing is written"
# (p) terminal: nothing about a merged PR can change, so it must stop costing two
# REST reads a tick at the head of the newest-first walk.
[ -f "$D/.pr-url-reconciled" ] \
  && ok || bad "(p) a merged answer must mark the record terminal with .pr-url-reconciled"
: > "$H/gh-calls.log"
run_lane
[ "$(grep -c 'api' "$H/gh-calls.log")" = 0 ] \
  && ok || bad "(p) a merged, marked record must not be read again, got: $(cat "$H/gh-calls.log")"

# ══ (m) APPROVE, the only PR on the branch is CLOSED unmerged = alert, in its
#        own words ════════════════════════════════════════════════════════════
mkhub m
D=$(record m "pool-cromford-BH-807-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
resp '200 OK' '[]'
resp_all '200 OK' "[{\"html_url\":\"$U803\",\"state\":\"closed\",\"merged_at\":null}]"
run_lane
[ "$(grep -c 'CLOSED without merging' "$H/logs/ALERTS.log" 2>/dev/null || true)" = 1 ] \
  && ok || bad "(m) a closed, unmerged PR must alert in its own words, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "$U803" "$H/logs/ALERTS.log" \
  && ok || bad "(m) the alert must name the closed PR"

# ══ (l2) a PR opened BETWEEN the two reads is not paged for ═════════════════
mkhub l2
D=$(record l2 "pool-cromford-BH-809-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
resp '200 OK' '[]'
resp_all '200 OK' "[{\"html_url\":\"$U812\",\"state\":\"open\",\"merged_at\":null}]"
run_lane
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(l2) a PR that opened between the two reads must not page: $(cat "$H/logs/ALERTS.log")" || ok
grep -q 'is open as of the second read' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(l2) the log must say the PR is open, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"

# ══ (n) the fix command names the STACK's base, never a blanket main ═════════
# A stacked child's base is its parent's branch. `--base main` pasted onto a
# stacked head opens a PR carrying the parent's commits as well.
mkhub n
D=$(record n "pool-cromford-BH-808-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ' | STACKED on ticket/bh-775 (example-org/cromford PR 803)'")
resp '200 OK' '[]'
run_lane
grep -q 'gh pr create --head ticket/bh-808 --base ticket/bh-775 ' "$H/logs/ALERTS.log" \
  && ok || bad "(n) the fix command must name the parent branch as the base, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ══ (o) a REBUILD record is asked about ticket/<key>-r2, never the stem ══════
# bin/run-build.sh builds a rebuild on ticket/<key>-rN (taken-name bump, or the
# resolver after it closed the stale PR on the stem) while the build dir carries
# no suffix. Asking about the STEM links the r2 record to the r1 PR — the exact
# mislink this lane exists to kill. The branch comes from the record's own
# pipeline.log, which every pool record ships.
mkhub o
D=$(record o "pool-cromford-BH-810-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
printf '2026-09-18 10:01:00Z [cromford/BH-810] branch name taken on remote — building as ticket/bh-810-r2\n2026-09-18 10:40:00Z [cromford/BH-810] pr create failed and no open PR exists on ticket/bh-810-r2: GraphQL: API rate limit already exceeded\n' > "$D/pipeline.log"
resp_head ticket/bh-810 '200 OK' "[{\"html_url\":\"$U834\"}]"        # the r1 PR, still open on the stem
resp_head ticket/bh-810-r2 '200 OK' "[{\"html_url\":\"$U812\"}]"     # this build's own PR
resp '200 OK' '[]'
run_lane
head -1 "$D/RESULT" | grep -qE "^PR_CREATED $U812 \| RECONCILED " \
  && ok || bad "(o) an r2 record must link its OWN branch's PR, got: $(head -1 "$D/RESULT")"
grep -q "$U834" "$D/RESULT" \
  && bad "(o) the r1 PR on the stem must NOT be linked to the r2 record: $(cat "$D/RESULT")" || ok
grep -q 'head=example-org:ticket/bh-810-r2&' "$H/gh-calls.log" \
  && ok || bad "(o) the read must ask about ticket/bh-810-r2, got: $(cat "$H/gh-calls.log")"
grep -q 'head=example-org:ticket/bh-810&' "$H/gh-calls.log" \
  && bad "(o) the stem must not be asked about when the record names its branch: $(cat "$H/gh-calls.log")" || ok
grep -q 'names ticket/bh-810-r2 as its branch' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(o) the log must say which branch the record named, got: $(cat "$H/logs/pr-url-reconcile.log")"

# ══ (o2) the same record with no open PR is paged for -r2, fix command too ═══
# Stem closed by the resolver, r2's PR missing: the old lane read the stem,
# found it closed, and told a human to `gh pr create --head ticket/<stem>`.
mkhub o2
D=$(record o2 "pool-cromford-BH-810-2026091809$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
printf '2026-09-18 10:40:00Z [cromford/BH-810] pr create failed and no open PR exists on ticket/bh-810-r2: GraphQL: API rate limit already exceeded\n' > "$D/pipeline.log"
resp '200 OK' '[]'
resp_all '200 OK' '[]'
run_lane
grep -q 'no open PR on ticket/bh-810-r2 ' "$H/logs/ALERTS.log" \
  && ok || bad "(o2) the alert must name the -r2 branch, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'gh pr create --head ticket/bh-810-r2 ' "$H/logs/ALERTS.log" \
  && ok || bad "(o2) the fix command must name the -r2 branch, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# ══ (o3) a log that names only a STACKED parent falls back to the stem ═══════
mkhub o3
D=$(record o3 "pool-cromford-BH-811-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ' | STACKED on ticket/bh-775 (example-org/cromford PR 803)'")
printf '2026-09-18 10:00:00Z [cromford/BH-811] STACKED on ticket/bh-775 — base is the parent branch\n' > "$D/pipeline.log"
resp '200 OK' "[{\"html_url\":\"$U812\"}]"
run_lane
grep -q 'head=example-org:ticket/bh-811&' "$H/gh-calls.log" \
  && ok || bad "(o3) with no own branch on record the stem is asked, got: $(cat "$H/gh-calls.log")"
grep -q 'ticket/bh-775' "$H/gh-calls.log" \
  && bad "(o3) a parent's STACKED name must never become this record's branch: $(cat "$H/gh-calls.log")" || ok
grep -q 'names no branch of its own .* asking the stem ticket/bh-811' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(o3) the stem fallback must say so, so a following mislink alert reads right, got: $(cat "$H/logs/pr-url-reconcile.log")"

# ══ (o4) only the taken-name bump line on record still resolves -r2 ══════════
# The `pr create failed and no open PR exists on <BRANCH>:` line is the primary
# read. A record that died before writing it still carries `branch name taken on
# remote — building as ticket/<key>-r2`, and the last exact `<stem>-rN` name in
# the log is the next rung. Case (o) carries both lines, so that rung was never
# exercised for a rebuild (review round 2, finding 6).
mkhub o4
D=$(record o4 "pool-cromford-BH-810-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
printf '2026-09-18 10:01:00Z [cromford/BH-810] branch name taken on remote — building as ticket/bh-810-r2\n' > "$D/pipeline.log"
resp_head ticket/bh-810 '200 OK' "[{\"html_url\":\"$U834\"}]"        # the r1 PR, still open on the stem
resp_head ticket/bh-810-r2 '200 OK' "[{\"html_url\":\"$U812\"}]"     # this build's own PR
resp '200 OK' '[]'
run_lane
head -1 "$D/RESULT" | grep -qE "^PR_CREATED $U812 \| RECONCILED " \
  && ok || bad "(o4) the bump line alone must resolve -r2 and link its PR, got: $(head -1 "$D/RESULT")"
grep -q 'head=example-org:ticket/bh-810&' "$H/gh-calls.log" \
  && bad "(o4) the stem must not be asked about when the log names -r2 at all: $(cat "$H/gh-calls.log")" || ok
grep -q 'names ticket/bh-810-r2 as its branch' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(o4) the log must say which branch the record named, got: $(cat "$H/logs/pr-url-reconcile.log")"

# ══ (r) a record paged for something ELSE still gets its mislink page ════════
# THE STATE THIS LANE MUST NEVER PRODUCE. alert() touches
# .pr-url-reconcile-alerted for every family it pages — "APPROVE, no PR",
# "closed unmerged" — so hanging the mislink page off that same flag meant a
# record paged once for anything was immune to the mislink page, while the
# mislink marker below still sealed it out of the lane for good. A build going
# invisible with nobody told is the whole defect this lane exists to kill.
mkhub r
D=$(record r "pool-cromford-BH-813-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''" \
  "TIER: 2" "PR: $U803")
# An earlier tick already paged this record for a missing PR.
touch "$D/.pr-url-reconcile-alerted"
resp '200 OK' "[{\"html_url\":\"$U812\"}]"
run_lane
[ "$(grep -c 'mislinked' "$H/logs/ALERTS.log" 2>/dev/null || true)" = 1 ] \
  && ok || bad "(r) a record paged earlier for a missing PR must still be paged for the mislink, got: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ -f "$D/.pr-url-reconcile-mislinked" ] \
  && ok || bad "(r) the mislinked record must still be marked terminal"
[ -f "$D/.pr-url-reconcile-mislink-alerted" ] \
  && ok || bad "(r) the mislink page must leave its OWN memory, not alert()'s shared flag"
# And the page is still exactly once per record: the terminal marker stops the
# walk, and removing it re-arms a read that does not page again.
rm -f "$D/.pr-url-reconcile-mislinked"
run_lane
[ "$(grep -c 'mislinked' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "(r) re-arming must not page a second time, got: $(cat "$H/logs/ALERTS.log")"

# ══ (s) the UNKNOWN line quotes THIS read's stderr, never another record's ═══
# logs/pr-url-reconcile.stderr.log is append-only and shared by every record and
# every tick. Quoting its tail attributes whatever failed last — possibly another
# record, on another tick — to this read, and a misattributed reason is worse
# than a bare `HTTP none`. The byte offset is taken before the call.
mkhub s
D=$(record s "pool-cromford-BH-814-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
printf 'gh: error from SOME OTHER RECORD on an earlier tick\n' > "$H/logs/pr-url-reconcile.stderr.log"
# A body with no HTTP status line at all: the read answers no status and writes
# nothing of its own to stderr — the exact shape that used to borrow a reason.
printf '[]\n' > "$H/gh-response"
run_lane
grep -q 'HTTP none' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(s) a read with no status must log UNKNOWN, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
grep -q 'SOME OTHER RECORD' "$H/logs/pr-url-reconcile.log" \
  && bad "(s) the UNKNOWN line must not quote a line this read did not write: $(cat "$H/logs/pr-url-reconcile.log")" || ok
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(s) a read with no status is UNKNOWN, never 'no PR': $(cat "$H/logs/ALERTS.log")" || ok
# The positive half: a line THIS read writes is the one quoted. Without it the
# case above passes whether or not stderr_since ever sees this read's bytes.
mkhub s2
D=$(record s2 "pool-cromford-BH-814-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
printf 'gh: error from SOME OTHER RECORD on an earlier tick\n' > "$H/logs/pr-url-reconcile.stderr.log"
printf 'gh: HTTP 503 Service Unavailable, THIS READ (https://api.github.com/repos/example-org/cromford/pulls)\n' > "$H/gh-stderr"
printf '[]\n' > "$H/gh-response"
run_lane
grep -q 'HTTP none .*gh said: gh: HTTP 503 Service Unavailable, THIS READ' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(s) the UNKNOWN line must quote the stderr THIS read wrote after 'gh said:', got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
grep -q 'SOME OTHER RECORD' "$H/logs/pr-url-reconcile.log" \
  && bad "(s) the older line must still not be quoted: $(cat "$H/logs/pr-url-reconcile.log")" || ok

# ══ (t) a RESUME_BUILD clears EVERY marker this lane writes ══════════════════
# bin/run-build.sh drops the reconciler's markers with the stale RESULT, because
# a resumed build that reaches a FRESH PR_CREATE_FAILED must not be skipped by a
# marker its previous life earned. That line named the first two markers by hand,
# so every marker added since was a silent hole. This checks the SET, not two
# names, so the next one cannot be forgotten either.
RMBLOCK=$(sed -n '/rm -f "\$BUILD\/RESULT"/,/^fi$/p' "$RB_ALL")
MISSING=""
for M in $(grep -oE '\.pr-url-reconcile[a-z-]*' "$LANE" | sort -u); do
  grep -q -- "$M" <<<"$RMBLOCK" || MISSING="${MISSING:+$MISSING }$M"
done
[ -n "$RMBLOCK" ] \
  && ok || bad "(t) the RESUME_BUILD clear in bin/run-build.sh could not be found"
[ -z "$MISSING" ] \
  && ok || bad "(t) a RESUME_BUILD must clear every marker this lane writes; not cleared: $MISSING"

# ══ (u) an already-paged APPROVE record still takes the state=all read ═══════
# A record paged once for "APPROVE, no PR" used to short-circuit ahead of the
# state=all read, so the PR an operator then opened by hand and MERGED was never
# seen: the record cost one REST read a tick forever and counted against MAX,
# with nothing left to learn (review round 2, finding 5). It goes terminal on the
# merged answer, and is never paged a second time.
mkhub u
D=$(record u "pool-cromford-BH-815-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
touch "$D/.pr-url-reconcile-alerted"
resp '200 OK' '[]'
resp_all '200 OK' "[{\"html_url\":\"$U803\",\"state\":\"closed\",\"merged_at\":\"2026-09-17T10:00:00Z\"}]"
run_lane
grep -q 'state=all' "$H/gh-calls.log" \
  && ok || bad "(u) an already-paged record must still take the state=all read, got: $(cat "$H/gh-calls.log")"
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(u) an already-paged record is never paged again: $(cat "$H/logs/ALERTS.log")" || ok
[ -f "$D/.pr-url-reconciled" ] \
  && ok || bad "(u) a merged answer must seal the already-paged record with .pr-url-reconciled"
grep -q 'is merged' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(u) the log must say the PR is merged, got: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null)"
: > "$H/gh-calls.log"
run_lane
[ "$(grep -c 'api' "$H/gh-calls.log")" = 0 ] \
  && ok || bad "(u) the sealed record must not be read again, got: $(cat "$H/gh-calls.log")"
# And the same record whose PR is still nowhere: read, not re-paged, not sealed.
mkhub u2
D=$(record u2 "pool-cromford-BH-816-2026091808$NOW" \
  "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ''")
touch "$D/.pr-url-reconcile-alerted"
resp '200 OK' '[]'
resp_all '200 OK' '[]'
run_lane
[ -f "$H/logs/ALERTS.log" ] \
  && bad "(u) no PR yet and already paged = no second page: $(cat "$H/logs/ALERTS.log")" || ok
[ -f "$D/.pr-url-reconciled" ] \
  && bad "(u) a record whose PR is still nowhere must stay re-readable — a hand-opened PR must link" || ok
grep -q 'already paged for it' "$H/logs/pr-url-reconcile.log" \
  && ok || bad "(u) the log must say the record was already paged, got: $(cat "$H/logs/pr-url-reconcile.log")"

echo "pr-url-reconcile-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
