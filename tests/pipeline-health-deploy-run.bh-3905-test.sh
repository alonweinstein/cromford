#!/bin/bash
# tests/pipeline-health-deploy-run.bh-3905-test.sh — "the CI worker deploy went
# red", the deploy workers run block extracted VERBATIM from
# bin/pipeline-health.sh by its markers and driven against a scratch tree with a
# pinned clock and a gh_rest stub answering fixture JSON.
#
# WHY IT EXISTS (BH-3905, BH-4089). Worker deploys move off the hub into the
# `Deploy workers` workflow, and the main-red detector skips any workflow named
# deploy, so a red deploy run on main would otherwise say nothing while the live
# workers and console go stale. The block reads the newest completed main run of
# deploy-workers.yml once an hour (DEPLOY_WORKERS_EVERY) and pages on anything
# but success; a later success resolves it. A 404 (workflow not on main yet) is
# silent, and an unverifiable GitHub (gh_rest rc 75) retries next tick without
# advancing the stamp.
#
# Run from anywhere: tests/pipeline-health-deploy-run.bh-3905-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PH="$DIR/bin/pipeline-health.sh"
NOW=$(date +%s)
SLUG=example-org/cromford
KEY="deployworkers:$SLUG"
URL="https://github.com/$SLUG/actions/runs/987"
SHA=abcdef1234567890abcdef1234567890abcdef12

awk '/^# >>> deploy workers run/{f=1;next} /^# <<< deploy workers run/{exit} f' "$PH" > "$T/block.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$PH" > "$T/cap.sh"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$PH" > "$T/alert.sh"
awk '/^cpd_resolve\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$PH" > "$T/cpd.sh"

# --- PD5: the block exists, sits after the console drift block, reads only through gh_rest
[ -s "$T/block.sh" ] && ok || bad "PD5 could not extract the deploy workers run block — markers missing?"
for f in cap.sh alert.sh cpd.sh; do [ -s "$T/$f" ] && ok || bad "PD5 could not extract $f from bin/pipeline-health.sh"; done
CPD_END=$(awk '/^# <<< console pages drift/{print NR; exit}' "$PH")
DW_BEGIN=$(awk '/^# >>> deploy workers run/{print NR; exit}' "$PH")
[ -n "$CPD_END" ] && [ -n "$DW_BEGIN" ] && [ "$DW_BEGIN" -gt "$CPD_END" ] \
  && ok || bad "PD5 the block must start after '# <<< console pages drift' (${CPD_END:-missing}), starts at ${DW_BEGIN:-missing}"
CODE=$(sed 's/^[[:space:]]*#.*$//' "$T/block.sh")
grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]' <<<"$CODE" && bad "PD5 the block calls raw gh: $(grep -En '(^|[^[:alnum:]_-])gh[[:space:]]' <<<"$CODE" | head -1)" || ok
grep -Eq '\$\([[:space:]]*gh_rest|`[[:space:]]*gh_rest' <<<"$CODE" && bad "PD5 the block wraps gh_rest in a command substitution" || ok
[ "$(grep -c 'gh_rest GET' <<<"$CODE")" = 1 ] && ok || bad "PD5 the block must make exactly one gh_rest GET"

# Sinks: alert-line.sh is where alert() and cpd_resolve() both land a line.
cat > "$T/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SH
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$BEAT_SINK"
exit 0
SH
chmod +x "$T/bin/alert-line.sh" "$T/bin/beat.sh"
export ALERT_SINK="$T/alerts.txt" BEAT_SINK="$T/beat.txt"

run() { # run <conclusion> — one newest completed run fixture
  jq -n --arg c "$1" --arg s "$SHA" --arg u "$URL" \
    '{total_count:1,workflow_runs:[{id:987,head_sha:$s,conclusion:$c,html_url:$u}]}' > "$T/body.json"
}
reset() { rm -f "$T/state/deploy-workers.stamp" "$T/state/deploy-workers.red"
          : > "$T/alerts.txt"; : > "$T/beat.txt"; : > "$T/logs/pipeline-health.log"; : > "$T/fired"
          echo '{}' > "$T/state/health-alerted.json"; }
drive() { # drive [VAR=val ...] — runs the block with gh_rest answering GHR_RC + body.json
  : > "$T/ghrest.calls"
  ( export HARNESS="$T" T="$T" H="$T" NOW="$NOW" DEDUP="$T/state/health-alerted.json" \
      FIRED="$T/fired" GHR_RC=0 GHR_REASON="" "$@"
    bash -c '
      set -uo pipefail
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      gh_rest() { printf "%s\n" "$*" >> "$T/ghrest.calls"; GH_REST_REASON=$GHR_REASON
        [ "$GHR_RC" = 0 ] && cat "$T/body.json"; return "$GHR_RC"; }
      gh_repo_use_token() { return 0; }
      gh_repo_token_reset() { :; }
      . "$T/cap.sh"; . "$T/alert.sh"; . "$T/cpd.sh"; . "$0"' "$T/block.sh" </dev/null >/dev/null 2>"$T/err.txt" )
}
nlines() { grep -c . "$1" 2>/dev/null || true; }

# --- PD1: a failed newest run pages once, with run id, sha7, conclusion and URL
reset; run failure; drive
[ "$(nlines "$T/alerts.txt")" = 1 ] && ok || bad "PD1 a failure run must page exactly once, alerts: $(cat "$T/alerts.txt")"
grep -qF "Deploy workers run 987 on main abcdef1 ended failure" "$T/alerts.txt" && ok || bad "PD1 alert text lacks run id/sha7/conclusion: $(cat "$T/alerts.txt")"
grep -qF "$URL" "$T/alerts.txt" && ok || bad "PD1 alert text lacks the run URL"
grep -qF "LIVE WORKERS/CONSOLE MAY BE STALE" "$T/alerts.txt" && ok || bad "PD1 alert text lacks the stale warning"
[ "$(jq -r --arg k "$KEY" '.[$k] // empty' "$T/state/health-alerted.json")" = "$NOW" ] && ok || bad "PD1 dedupe key $KEY not stamped in DEDUP: $(cat "$T/state/health-alerted.json")"
[ -f "$T/state/deploy-workers.red" ] && ok || bad "PD1 the red mark must exist after a page"
[ "$(cat "$T/state/deploy-workers.stamp" 2>/dev/null)" = "$NOW" ] && ok || bad "PD1 stamp must be NOW after a decisive read"
[ "$(cat "$T/ghrest.calls")" = "GET repos/$SLUG/actions/workflows/deploy-workers.yml/runs?branch=main&status=completed&per_page=1" ] \
  && ok || bad "PD1 gh_rest args wrong: $(cat "$T/ghrest.calls")"
[ -s "$T/err.txt" ] && bad "PD1 block wrote to stderr: $(head -3 "$T/err.txt")" || ok
# Still red half an hour later (cadence forced to every tick): no duplicate inside the TTL.
drive NOW=$((NOW + 1800)) DEPLOY_WORKERS_EVERY=0
[ "$(nlines "$T/ghrest.calls")" = 1 ] && ok || bad "PD1 DEPLOY_WORKERS_EVERY=0 must read every tick"
[ "$(nlines "$T/alerts.txt")" = 1 ] && ok || bad "PD1 a still-red run must not page twice inside an hour: $(cat "$T/alerts.txt")"
# An hour on, still red: one more line (one per TTL), not silence.
drive NOW=$((NOW + 3600)) DEPLOY_WORKERS_EVERY=0
[ "$(nlines "$T/alerts.txt")" = 2 ] && ok || bad "PD1 a still-red run re-pages once per hour, alerts: $(nlines "$T/alerts.txt")"

# --- PD2: success after a page resolves once and clears the mark; success with no mark is silent
run success; drive NOW=$((NOW + 7200))
[ "$(nlines "$T/alerts.txt")" = 3 ] && ok || bad "PD2 success after a page must write one RESOLVED line"
tail -1 "$T/alerts.txt" | grep -qF "RESOLVED $KEY" && ok || bad "PD2 last line must be RESOLVED $KEY: $(tail -1 "$T/alerts.txt")"
tail -1 "$T/alerts.txt" | grep -qF "Deploy workers run 987 on main abcdef1 succeeded" && ok || bad "PD2 RESOLVED text: $(tail -1 "$T/alerts.txt")"
[ -f "$T/state/deploy-workers.red" ] && bad "PD2 the red mark must be removed on success" || ok
[ "$(jq -r --arg k "$KEY" '.[$k] // "gone"' "$T/state/health-alerted.json")" = gone ] && ok || bad "PD2 RESOLVED must clear the dedupe key"
drive NOW=$((NOW + 10800))
[ "$(nlines "$T/alerts.txt")" = 3 ] && ok || bad "PD2 a second success must stay silent"
reset; run success; drive
[ "$(nlines "$T/alerts.txt")" = 0 ] && ok || bad "PD2 success with no mark must be silent: $(cat "$T/alerts.txt")"
[ "$(cat "$T/state/deploy-workers.stamp" 2>/dev/null)" = "$NOW" ] && ok || bad "PD2 success advances the stamp"

# --- PD3: 404 (workflow not on main yet) and an empty run list are silent, stamp advanced
reset; drive GHR_RC=44
[ "$(nlines "$T/alerts.txt")" = 0 ] && ok || bad "PD3 a 404 must be silent: $(cat "$T/alerts.txt")"
[ "$(cat "$T/state/deploy-workers.stamp" 2>/dev/null)" = "$NOW" ] && ok || bad "PD3 a 404 is decisive: stamp = NOW"
reset; echo '{"total_count":0,"workflow_runs":[]}' > "$T/body.json"; drive
[ "$(nlines "$T/alerts.txt")" = 0 ] && ok || bad "PD3 no completed run must be silent: $(cat "$T/alerts.txt")"
[ "$(cat "$T/state/deploy-workers.stamp" 2>/dev/null)" = "$NOW" ] && ok || bad "PD3 no run is decisive: stamp = NOW"

# --- PD4: rc 75 skips without the stamp; the stamp gates the hour; non-success other than failure pages
reset; run failure; drive GHR_RC=75 GHR_REASON=rate-limit
[ "$(nlines "$T/alerts.txt")" = 0 ] && ok || bad "PD4 rc 75 must never page: $(cat "$T/alerts.txt")"
[ -f "$T/state/deploy-workers.stamp" ] && bad "PD4 rc 75 must not advance the stamp" || ok
grep -q 'deploy workers check skipped: GitHub unverifiable (rate-limit)' "$T/logs/pipeline-health.log" \
  && ok || bad "PD4 rc 75 must log one skipped line naming the reason: $(cat "$T/logs/pipeline-health.log")"
reset; echo 'not json' > "$T/body.json"; drive
[ "$(nlines "$T/alerts.txt")" = 0 ] && ok || bad "PD4 unparseable JSON must never page"
[ -f "$T/state/deploy-workers.stamp" ] && bad "PD4 unparseable JSON must not advance the stamp" || ok
reset; echo '{"message":"x"}' > "$T/body.json"; drive
[ "$(nlines "$T/alerts.txt")" = 0 ] && [ ! -f "$T/state/deploy-workers.stamp" ] && ok || bad "PD4 a body with no workflow_runs is unparseable, not 'no run'"
reset; run failure; echo $((NOW - 60)) > "$T/state/deploy-workers.stamp"; drive
[ "$(nlines "$T/ghrest.calls")" = 0 ] && ok || bad "PD4 a stamp 60s old must skip the read entirely: $(cat "$T/ghrest.calls")"
[ "$(nlines "$T/alerts.txt")" = 0 ] && ok || bad "PD4 no read, no page"
for c in cancelled timed_out startup_failure; do
  reset; run "$c"; drive
  grep -qF "ended $c" "$T/alerts.txt" && ok || bad "PD4 a $c run is non-success and must page: $(cat "$T/alerts.txt")"
done

# --- PD6: a non-numeric cadence reads as 3600; the manifest registers the same default
reset; run failure; echo $((NOW - 1800)) > "$T/state/deploy-workers.stamp"; drive DEPLOY_WORKERS_EVERY=abc
[ "$(nlines "$T/ghrest.calls")" = 0 ] && ok || bad "PD6 DEPLOY_WORKERS_EVERY=abc must behave as 3600 (stamp 1800s old, no read)"
echo $((NOW - 3600)) > "$T/state/deploy-workers.stamp"; drive DEPLOY_WORKERS_EVERY=abc
[ "$(nlines "$T/ghrest.calls")" = 1 ] && ok || bad "PD6 DEPLOY_WORKERS_EVERY=abc at 3600s must read"
[ -s "$T/err.txt" ] && bad "PD6 non-numeric cadence wrote to stderr: $(head -3 "$T/err.txt")" || ok
MD=$(jq '.knobs[] | select(.env=="DEPLOY_WORKERS_EVERY") | .default' "$DIR/catalog/lanes.d/pipeline-health.json" 2>/dev/null)
[ "$MD" = 3600 ] && ok || bad "PD6 catalog/lanes.d/pipeline-health.json must register DEPLOY_WORKERS_EVERY default 3600, got '${MD}'"
grep -qF '"${DEPLOY_WORKERS_EVERY:-3600}"' "$T/block.sh" && ok || bad "PD6 the block's default must equal the manifest's (3600)"

echo "pipeline-health-deploy-run.bh-3905: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
