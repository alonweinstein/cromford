#!/bin/bash
# tests/main-red-stale-page.bh-1927-test.sh — BH-1927: a stale GitHub runs page
# never raises (or clears) a main-red freeze.
#
#   THE INCIDENT (2026-09-24, project-5, 09:00-10:06Z). GitHub's
#   `actions/runs?branch=main` sometimes answers with a STALE page: caught live
#   from the hub, `total_count=4355` with week-old runs, then 7094 on the very
#   next call. The stale page carried two red `monitor.yml` pushes, which is a
#   two-red streak, so bin/main-red-detector.sh froze every merge lane and paged
#   --critical; the next fresh page cleared it a minute later, and round it went.
#
#   THE PROPERTY UNDER TEST. The detector keeps the newest `total_count` and the
#   newest run's created_at it has accepted for each repo in the `ledgers` table
#   (kind=main_red_runs), and a page whose newest run goes BACKWARDS decides
#   nothing; a lower count under the same newest run is retention and is
#   accepted (S11, S12), so a run finishing red or re-run green is never hidden. And before it raises a NEW flag it re-reads the page and requires
#   the same arm, workflow and sha, which is the only guard left when the
#   ledger cannot be reached. The controls (S3, S4, S9) prove it still freezes
#   on a real red, and S7 proves it is the guard, not the fixture, that holds.
#
# The ledger is a shim over a scratch dir here, standing in for the D1 row the
# real bin/jobs-client.sh reads and writes. Every timestamp is a literal.
# Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-stale-page.bh-1927-test: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin" "$T/pages" "$T/ledger"
cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# The coordination-DB client the detector sources. flag_set is a recorder; the
# two ledger verbs keep the same contract as bin/lib/jobs/jobs.sh (get: rc 0 +
# status, rc 2 no row, rc 1 outage; put: rc 0) over one file per row, standing
# in for the ledgers table.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/' '-')"; }
job_ledger_get() {
  [ -f "$LEDGER_DIR/.down" ] && return 1
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2
  cat "$f"; return 0
}
job_ledger_put() {
  [ -f "$LEDGER_DIR/.down" ] && return 1
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$LEDGER_DIR/.puts"
  printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0
}
SHIM

# gh shim. Every runs read (not the jobs read) serves the NEXT page of the
# queue $T/pages/1.json, 2.json, …; once the queue runs out the last page
# repeats. It answers the projection the detector ASKS for: `total_count`
# beside the runs when the -q names it, the bare runs array when it does not.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)
    n=$(( $(cat "$T/pages/.served" 2>/dev/null || echo 0) + 1 ))
    [ -s "$T/pages/$n.json" ] || n=$(( n - 1 ))
    [ -s "$T/pages/$n.json" ] || exit 1
    echo "$n" > "$T/pages/.served"
    R='[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]'
    case "$*" in *total_count*) jq -c "{total:.total_count, runs:$R}" "$T/pages/$n.json" ;;
                 *)             jq -c "$R" "$T/pages/$n.json" ;; esac ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
MON=".github/workflows/monitor.yml"
LINT=".github/workflows/lint.yml"
FLAG="$T/flags/main-red-o-r"
VERDICT="$T/state/main-red/o-r.verdict"
LROW="$T/ledger/main_red_runs__o-r"

page() { # page <queue-slot> <total_count> <name|path|conclusion|created_at|sha[|status]>...
  local slot="$1" total="$2" out='[' first=1 spec n p c t s sha; shift 2
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" \
      --arg c "$c" --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end),
        created_at:$t, head_sha:$sha, html_url:$u, id:($t|gsub("[^0-9]";"")|tonumber)}')
  done
  jq -nc --argjson r "$out]" --argjson tc "$total" '{total_count:$tc, workflow_runs:$r}' > "$T/pages/$slot.json"
}
# The two shapes of the incident, as seen from the hub.
fresh_green() { page "$1" 7094 \
  "Harness CI|$CI|success|2026-09-24T09:05:00Z|fresh0001" \
  "Harness CI|$CI|success|2026-09-24T09:00:00Z|fresh0000"; }
stale_red() { page "$1" 4355 \
  "Monitor|$MON|failure|2026-09-21T12:00:00Z|stale0002" \
  "Monitor|$MON|failure|2026-09-21T11:00:00Z|stale0001" \
  "Harness CI|$CI|success|2026-09-17T10:00:00Z|stale0000"; }
real_red() { page "$1" "${2:-7096}" \
  "Harness CI|$CI|failure|2026-09-24T09:30:00Z|red00002" \
  "Harness CI|$CI|failure|2026-09-24T09:20:00Z|red00001" \
  "Harness CI|$CI|success|2026-09-24T09:05:00Z|fresh0001"; }

drive() { # drive [args...] — one tick; stdout in $T/out.txt
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" PUBLISH_SINK="$T/publish.txt" LEDGER_DIR="$T/ledger" \
           JOBS_ANSWER="${JOBS_ANSWER:-}" MAIN_RED_STALE_GUARD="${MAIN_RED_STALE_GUARD:-}"
    [ -n "$MAIN_RED_STALE_GUARD" ] || unset MAIN_RED_STALE_GUARD
    unset GH_TOKEN
    bash "$T/bin/main-red-detector.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
next_tick() { rm -f "$T/pages"/*.json "$T/pages/.served"; : > "$T/gh.txt"; }
mrlog()     { cat "$T/logs/main-red.log" 2>/dev/null; }
alerts()    { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
publishes() { awk 'END{print NR+0}' "$T/publish.txt" 2>/dev/null; }
puts()      { awk 'END{print NR+0}' "$T/ledger/.puts" 2>/dev/null; }
runs_reads(){ grep -c 'actions/runs -f branch=main' "$T/gh.txt" 2>/dev/null | tr -d ' '; }
verdict()   { cat "$VERDICT" 2>/dev/null; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"; : > "$T/ledger/.puts"
  rm -f "$T"/flags/* "$T"/locks/* "$T/ledger/.down" "$LROW"
  scratch_rm "$T/state/main-red"
  next_tick
}
floor() { printf 'total=%s newest=%s' "$1" "$2" > "$LROW"; }

JOBS_ANSWER="Pure-logic gate fixtures"

# ── S1 — THE TICKET'S FIXTURE: fresh, stale, fresh ─────────────────────────
reset_case
fresh_green 1; drive o/r
[ -e "$FLAG" ] && bad "S1/t1: a green page raised: $(cat "$FLAG")" || ok
case "$(verdict)" in *"decision=green"*) ok ;; *) bad "S1/t1: verdict: $(verdict)" ;; esac
case "$(cat "$LROW" 2>/dev/null)" in "total=7094 newest=2026-09-24T09:05:00Z") ok ;;
  *) bad "S1/t1: the floor was not recorded in the ledger: '$(cat "$LROW" 2>/dev/null)' puts=$(cat "$T/ledger/.puts")" ;; esac
next_tick; stale_red 1; drive o/r
[ -e "$FLAG" ] && bad "S1/t2: the STALE page raised the freeze: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ]    && ok || bad "S1/t2: paged on a stale page: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "S1/t2: published a pause row: $(cat "$T/publish.txt")"
case "$(verdict)" in *"decision=none"*"reason=stale-page"*) ok ;; *) bad "S1/t2: verdict: $(verdict)" ;; esac
case "$(mrlog)" in *"stale"*"4355"*"7094"*) ok ;; *) bad "S1/t2: the log does not name the counts: $(mrlog)" ;; esac
case "$(cat "$LROW" 2>/dev/null)" in "total=7094 "*) ok ;;
  *) bad "S1/t2: a stale page lowered the floor: $(cat "$LROW" 2>/dev/null)" ;; esac
next_tick; fresh_green 1; drive o/r
[ -e "$FLAG" ] && bad "S1/t3: raised on the fresh page after the stale one: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "S1/t3: paged: $(cat "$T/alerts.txt")"
case "$(verdict)" in *"decision=green"*) ok ;; *) bad "S1/t3: verdict: $(verdict)" ;; esac

# ── S2 — no floor at all (the ledger is down): the confirm re-read holds ───
reset_case; touch "$T/ledger/.down"
stale_red 1; fresh_green 2; drive o/r
[ -e "$FLAG" ] && bad "S2: raised on a page the re-read contradicts: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ]     && ok || bad "S2: paged: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ]  && ok || bad "S2: published: $(cat "$T/publish.txt")"
[ "$(runs_reads)" = 2 ] && ok || bad "S2: made $(runs_reads) runs reads, want 2 (the page and the re-read): $(cat "$T/gh.txt")"
case "$(verdict)" in *"decision=none"*"reason=unconfirmed"*) ok ;; *) bad "S2: verdict: $(verdict)" ;; esac
case "$(mrlog)" in *"not confirmed"*) ok ;; *) bad "S2: the log does not say the re-read disagreed: $(mrlog)" ;; esac

# ── S3 — CONTROL: a real red, confirmed on the re-read, still freezes ──────
reset_case; floor 7094 2026-09-24T09:05:00Z
real_red 1; drive o/r
[ -s "$FLAG" ] && ok || bad "S3: a confirmed real red did not raise (log: $(mrlog)) err=$(cat "$T/err.txt")"
grep -q '^sha=red00002$'    "$FLAG" 2>/dev/null && ok || bad "S3: flag sha: $(cat "$FLAG" 2>/dev/null)"
grep -q '^reason=streak$'   "$FLAG" 2>/dev/null && ok || bad "S3: flag reason: $(cat "$FLAG" 2>/dev/null)"
[ "$(alerts)" = 1 ]     && ok || bad "S3: sent $(alerts) alerts, want 1: $(cat "$T/alerts.txt")"
case "$(cat "$T/alerts.txt")" in "--critical main-red o/r main is RED"*) ok ;; *) bad "S3: wrong alert: $(cat "$T/alerts.txt")" ;; esac
[ "$(publishes)" = 1 ]  && ok || bad "S3: published $(publishes), want 1"
[ "$(runs_reads)" = 2 ] && ok || bad "S3: made $(runs_reads) runs reads, want 2: $(cat "$T/gh.txt")"
case "$(verdict)" in *"decision=red"*"reason=streak"*) ok ;; *) bad "S3: verdict: $(verdict)" ;; esac
case "$(cat "$LROW" 2>/dev/null)" in "total=7096 newest=2026-09-24T09:30:00Z") ok ;;
  *) bad "S3: the floor did not move up: $(cat "$LROW" 2>/dev/null)" ;; esac
#     and the next tick, same sha: the still-red path, no re-read, no second page.
next_tick; : > "$T/alerts.txt"; real_red 1; drive o/r
[ "$(alerts)" = 0 ]     && ok || bad "S3/t2: paged twice: $(cat "$T/alerts.txt")"
[ "$(runs_reads)" = 1 ] && ok || bad "S3/t2: a standing flag was re-read: $(cat "$T/gh.txt")"

# ── S4 — the re-read is FRESHER but decides the same: still freezes ─────────
reset_case; floor 7094 2026-09-24T09:05:00Z
real_red 1
page 2 7097 \
  "Lint|$LINT|null|2026-09-24T09:31:00Z|red00002|in_progress" \
  "Harness CI|$CI|failure|2026-09-24T09:30:00Z|red00002" \
  "Harness CI|$CI|failure|2026-09-24T09:20:00Z|red00001" \
  "Harness CI|$CI|success|2026-09-24T09:05:00Z|fresh0001"
drive o/r
[ -s "$FLAG" ] && ok || bad "S4: same verdict on a fresher re-read did not raise: $(mrlog)"
[ "$(alerts)" = 1 ] && ok || bad "S4: sent $(alerts) alerts, want 1"
case "$(cat "$LROW" 2>/dev/null)" in "total=7097 newest=2026-09-24T09:31:00Z") ok ;;
  *) bad "S4: the floor does not reflect the re-read: $(cat "$LROW" 2>/dev/null)" ;; esac

# ── S5 — a higher count but an OLDER newest run is still stale ─────────────
reset_case; floor 7094 2026-09-24T09:05:00Z
page 1 7100 \
  "Harness CI|$CI|failure|2026-09-24T08:30:00Z|old00002" \
  "Harness CI|$CI|failure|2026-09-24T08:20:00Z|old00001" \
  "Harness CI|$CI|success|2026-09-24T08:00:00Z|old00000"
drive o/r
[ -e "$FLAG" ] && bad "S5: a page older than the floor raised: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "S5: paged: $(cat "$T/alerts.txt")"
case "$(verdict)" in *"reason=stale-page"*) ok ;; *) bad "S5: verdict: $(verdict)" ;; esac
case "$(mrlog)" in *"stale"*"2026-09-24T08:30:00Z"*) ok ;; *) bad "S5: the log does not name the old run: $(mrlog)" ;; esac

# ── S6 — a stale all-green page never CLEARS a standing freeze ─────────────
reset_case; floor 7096 2026-09-24T09:30:00Z
{ echo "sha=red00002"; echo "workflow=Harness CI"; echo "path=$CI"; echo "job=x";
  echo "since=2026-09-24T09:20:00Z"; echo "streak=2"; echo "run=u"; echo "detected=d"; echo "reason=streak"; } > "$FLAG"
page 1 4355 \
  "Harness CI|$CI|success|2026-09-17T10:00:00Z|stale0000" \
  "Harness CI|$CI|success|2026-09-17T09:00:00Z|stale0009"
drive o/r
[ -s "$FLAG" ] && ok || bad "S6: a stale green page cleared the freeze: $(mrlog)"
[ "$(alerts)" = 0 ]    && ok || bad "S6: sent a resolve on a stale page: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "S6: published on a stale page: $(cat "$T/publish.txt")"

# ── S7 — the knob: MAIN_RED_STALE_GUARD=0 is the pre-BH-1927 detector ──────
reset_case; floor 7094 2026-09-24T09:05:00Z
stale_red 1
MAIN_RED_STALE_GUARD=0 drive o/r
[ -s "$FLAG" ] && ok || bad "S7: with the guard off the stale red did not raise — the fixture is not a red: $(mrlog)"
[ "$(runs_reads)" = 1 ] && ok || bad "S7: guard off made $(runs_reads) runs reads, want 1"
[ "$(puts)" = 0 ]       && ok || bad "S7: guard off wrote the ledger: $(cat "$T/ledger/.puts")"

# ── S8 — --explain is read-only: it says stale and writes no ledger row ────
reset_case; floor 7094 2026-09-24T09:05:00Z
stale_red 1; drive --explain o/r
case "$(cat "$T/out.txt")" in *"stale"*) ok ;; *) bad "S8: --explain did not say the page is stale: $(cat "$T/out.txt")" ;; esac
[ "$(puts)" = 0 ]  && ok || bad "S8: --explain wrote the ledger: $(cat "$T/ledger/.puts")"
[ -e "$FLAG" ]     && bad "S8: --explain wrote a flag" || ok
[ -e "$VERDICT" ]  && bad "S8: --explain wrote a verdict: $(verdict)" || ok
#     and over a fresh page it records nothing either.
next_tick; page 1 7200 "Harness CI|$CI|success|2026-09-24T10:00:00Z|fresh0002"
drive --explain o/r
[ "$(puts)" = 0 ] && ok || bad "S8: --explain raised the floor: $(cat "$T/ledger/.puts")"

# ── S9 — retention: a LOWER count with a NEWER run is fresh, and resets ────
reset_case; floor 7094 2026-09-24T09:05:00Z
page 1 7000 \
  "Harness CI|$CI|success|2026-09-24T09:40:00Z|fresh0003" \
  "Harness CI|$CI|success|2026-09-24T09:05:00Z|fresh0001"
drive o/r
case "$(verdict)" in *"decision=green"*) ok ;; *) bad "S9: a newer page was rejected: $(verdict) / $(mrlog)" ;; esac
case "$(cat "$LROW" 2>/dev/null)" in "total=7000 newest=2026-09-24T09:40:00Z") ok ;;
  *) bad "S9: the floor did not reset to the newer page: $(cat "$LROW" 2>/dev/null)" ;; esac

# ── S10 — the BH-1451 deep re-read answering a stale page is ignored ───────
reset_case; floor 7094 2026-09-24T09:05:00Z
page 1 7110 \
  "Harness CI|$CI|null|2026-09-24T09:50:00Z|head0003|in_progress" \
  "Harness CI|$CI|null|2026-09-24T09:45:00Z|head0002|in_progress"
stale_red 2
drive o/r
[ "$(runs_reads)" = 2 ] && ok || bad "S10: expected the page and the deep read: $(cat "$T/gh.txt")"
[ -e "$FLAG" ] && bad "S10: raised from a stale deep page: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "S10: paged: $(cat "$T/alerts.txt")"
case "$(mrlog)" in *"deeper"*"stale"*|*"stale"*"deeper"*) ok ;; *) bad "S10: the log does not say the deep page was stale: $(mrlog)" ;; esac

# ── S11 — a SAME-newest page with a lower count is fresh: a red lands ─────
#     The floor is taken while the two newest runs are still in flight; GitHub
#     then deletes old runs (retention, or by hand), so total_count drops; then
#     both finish red. The newest run has not gone backwards, so the page is
#     fresh: the freeze raises, and the floor count resets to the page's.
reset_case
page 1 7096 \
  "Harness CI|$CI|null|2026-09-24T09:30:00Z|red00002|in_progress" \
  "Harness CI|$CI|null|2026-09-24T09:20:00Z|red00001|in_progress" \
  "Harness CI|$CI|success|2026-09-24T09:05:00Z|fresh0001"
drive o/r
[ -e "$FLAG" ] && bad "S11/t1: raised while the tip was in flight: $(cat "$FLAG")" || ok
case "$(cat "$LROW" 2>/dev/null)" in "total=7096 newest=2026-09-24T09:30:00Z") ok ;;
  *) bad "S11/t1: the floor was not taken on the in-flight page: $(cat "$LROW" 2>/dev/null)" ;; esac
next_tick; real_red 1 7050; drive o/r
[ -s "$FLAG" ] && ok || bad "S11/t2: a same-newest lower-count page hid a real red (verdict: $(verdict)) log: $(mrlog)"
grep -q '^sha=red00002$' "$FLAG" 2>/dev/null && ok || bad "S11/t2: flag sha: $(cat "$FLAG" 2>/dev/null)"
[ "$(alerts)" = 1 ] && ok || bad "S11/t2: sent $(alerts) alerts, want 1: $(cat "$T/alerts.txt")"
case "$(verdict)" in *"reason=stale-page"*) bad "S11/t2: called the page stale: $(verdict)" ;; *) ok ;; esac
case "$(cat "$LROW" 2>/dev/null)" in "total=7050 newest=2026-09-24T09:30:00Z") ok ;;
  *) bad "S11/t2: the floor count did not reset to the page's: $(cat "$LROW" 2>/dev/null)" ;; esac
#     and the tick after, same page: still fresh against the reset floor.
next_tick; : > "$T/alerts.txt"; real_red 1 7050; drive o/r
case "$(verdict)" in *"reason=stale-page"*) bad "S11/t3: the reset floor rejected the same page: $(verdict)" ;; *) ok ;; esac
[ -s "$FLAG" ] && ok || bad "S11/t3: the flag did not survive the next tick: $(mrlog)"

# ── S12 — a same-newest lower-count re-run to GREEN clears a standing flag ─
#     A re-run keeps the run's created_at, so the newest run is unchanged.
reset_case; floor 7096 2026-09-24T09:30:00Z
{ echo "sha=red00002"; echo "workflow=Harness CI"; echo "path=$CI"; echo "job=x";
  echo "since=2026-09-24T09:20:00Z"; echo "streak=2"; echo "run=u"; echo "detected=d"; echo "reason=streak"; } > "$FLAG"
page 1 7050 \
  "Harness CI|$CI|success|2026-09-24T09:30:00Z|red00002" \
  "Harness CI|$CI|failure|2026-09-24T09:20:00Z|red00001" \
  "Harness CI|$CI|success|2026-09-24T09:05:00Z|fresh0001"
drive o/r
[ -e "$FLAG" ] && bad "S12: a same-newest re-run to green did not clear the flag (verdict: $(verdict)) log: $(mrlog)" || ok
case "$(verdict)" in *"reason=stale-page"*) bad "S12: called the page stale: $(verdict)" ;; *) ok ;; esac
case "$(cat "$LROW" 2>/dev/null)" in "total=7050 newest=2026-09-24T09:30:00Z") ok ;;
  *) bad "S12: the floor count did not reset to the page's: $(cat "$LROW" 2>/dev/null)" ;; esac

# ── S13 — the incident shape (OLDER newest AND a lower count) stays stale ──
reset_case; floor 7094 2026-09-24T09:05:00Z
page 1 7000 \
  "Harness CI|$CI|failure|2026-09-24T09:00:00Z|old00012" \
  "Harness CI|$CI|failure|2026-09-24T08:50:00Z|old00011" \
  "Harness CI|$CI|success|2026-09-24T08:40:00Z|old00010"
drive o/r
[ -e "$FLAG" ] && bad "S13: an older, lower page raised: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "S13: paged: $(cat "$T/alerts.txt")"
case "$(verdict)" in *"decision=none"*"reason=stale-page"*) ok ;; *) bad "S13: verdict: $(verdict)" ;; esac
case "$(cat "$LROW" 2>/dev/null)" in "total=7094 newest=2026-09-24T09:05:00Z") ok ;;
  *) bad "S13: a stale page moved the floor: $(cat "$LROW" 2>/dev/null)" ;; esac

echo "main-red-stale-page.bh-1927-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
