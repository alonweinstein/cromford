#!/bin/bash
# tests/main-red-schedule-skip.bh-3769-test.sh — BH-3769: a scheduled report or
# prod-health workflow going red on main must not freeze every merge lane.
#
#   THE INCIDENTS (2026-10-01). project-3's "Production QA" (.github/workflows/
#   e2e-prod.yml) went red against prod and froze project-3's merges: its NAME
#   matched nothing in MAIN_RED_SKIP_RE, only its path did. project-5's
#   quarterly access-review report, a `schedule` run, went red on a sha main
#   had already passed CI on, and the tip arm froze project-5. Neither run said
#   anything about main's code. This suite drives the real
#   bin/main-red-detector.sh (and pr_head_error from bin/main-red-pr-pair.sh)
#   and pins:
#     S1/S2  the skip regex matches a workflow's name OR its path;
#     S3-S6  a `schedule` run is never freeze evidence: no streak, no tip, and
#            an in-flight one does not hold a real push streak;
#     S3/S7/S8/S9  a scheduled red sends ONE warn per run id (never critical),
#            and a skip-listed one sends nothing;
#     S10    --explain says WOULD ALERT(warn) and writes nothing;
#     S11    a scheduled run in flight does not trigger the burst re-read;
#     K1-K4  MAIN_RED_SKIP_RE resolves settings row > env > default, and an
#            invalid regex falls back to the default with a warn;
#     K5     pr_head_error reads the same knob by name OR path.
# Every timestamp is a literal. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/main-red-schedule-skip.bh-3769-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-schedule-skip.bh-3769-test: SKIPPED — jq/python3 is not installed"; exit 0; }
[ -f "$DIR/bin/main-red-detector.sh" ] && [ -f "$DIR/bin/main-red-pr-pair.sh" ] || {
  echo "FAIL: the detector or the pr-pair lane is missing"; echo "main-red-schedule-skip.bh-3769: 0 passed, 1 failed"; exit 1; }
REG=$(rendered_registry)

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin" "$T/ledger"
cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
: > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# The coordination-DB client: flag_set records; the ledger verbs keep
# bin/lib/jobs/jobs.sh's contract (get rc 0 + status, rc 2 no row) over files;
# _jobs_req answers /api/settings from $ROWS (key=value lines, so a regex may
# hold a space) and refuses the
# rest, which the detector already reads as "unreadable".
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/#' '-_')"; }
job_ledger_get() {
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2
  cat "$f"; return 0
}
job_ledger_put() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$LEDGER_DIR/.puts"
  printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0
}
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

# gh shim. Runs on main from $T/runs.json through the projection the detector
# asks for (event included). A jobs read fails: the infra check then answers
# "not infra" and the raise names "(job list unavailable)", as in prod on a 5xx.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/runs/"*"/jobs"*) exit 1 ;;
  *"event=pull_request"*)
    [ -s "$T/queue.json" ] || exit 1
    jq -c '[.[] | {n:.name, p:.path, s:"completed", c:.conclusion, sha:.head_sha, hb:.head_branch, dt:.display_title, t:.created_at, u:"q", id:.id}]' "$T/queue.json" ;;
  *"actions/runs"*)
    [ -s "$T/runs.json" ] || exit 1
    R='[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id, e:.event}]'
    jq -c "{total:.total_count, runs:$R}" "$T/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

# runs <spec>... — spec: name|path|conclusion|created_at|sha|status|event
# (status defaults to completed, event to push; the id is the timestamp digits).
runs() {
  local out='[' first=1 spec n p c t sha s e
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s e <<<"$spec"; s=${s:-completed}; e=${e:-push}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" --arg c "$c" --arg e "$e" \
      --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end), event:$e,
        created_at:$t, head_sha:$sha, html_url:$u, id:($t|gsub("[^0-9]";"")|tonumber)}')
  done
  jq -nc --argjson r "$out]" '{total_count:($r|length), workflow_runs:$r}' > "$T/runs.json"
}
drive() { # drive [args...] — one tick against o/r; stdout in $T/out.txt
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" LANE_REGISTRY="$REG" \
           ALERT_SINK="$T/alerts.txt" PUBLISH_SINK="$T/publish.txt" LEDGER_DIR="$T/ledger" ROWS="${ROWS:-}"
    unset GH_TOKEN MAIN_RED_SKIP_RE MAIN_RED_INFRA_RERUN MAIN_RED_STALE_GUARD MAIN_RED_TIP_RED
    bash "$T/bin/main-red-detector.sh" "$@" o/r >"$T/out.txt" 2>"$T/err.txt" )
}
reset_all() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"
  rm -rf "$T"/flags/main-red-* "$T/state/main-red" "$T/queue.json" "$T/state/settings-cache.json" "$T/state/lane-gate" "$T/ledger"
  mkdir -p "$T/ledger"; : > "$T/ledger/.puts"; : > "$T/env/global.env"; ROWS=""
}
n_alerts() { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
n_crit()   { grep -c -- '--critical' "$T/alerts.txt" 2>/dev/null; }
n_warn()   { grep -c -- '--severity warn' "$T/alerts.txt" 2>/dev/null; }
verdict()  { sed -n "s/^$1=//p" "$T/state/main-red/o-r.verdict" 2>/dev/null; }
FLAG="$T/flags/main-red-o-r"
CI=".github/workflows/ci.yml"
QA="Production QA"; AR="Access review (quarterly)"; ARP=".github/workflows/access-review.yml"

# ── S1 name-miss / path-hit: project-3's Production QA, red twice on the tip ──────
reset_all
runs "$QA|.github/workflows/e2e-prod.yml|failure|2026-10-01T09:20:00Z|aaaa111" \
     "$QA|.github/workflows/e2e-prod.yml|failure|2026-10-01T09:10:00Z|aaaa111" \
     "CI|$CI|success|2026-10-01T09:00:00Z|aaaa111"
drive
{ [ ! -f "$FLAG" ] && [ "$(n_crit)" = 0 ] && [ "$(verdict decision)" = green ]; } && ok \
  || bad "S1 a red workflow whose PATH matches the skip regex froze main: flag=$([ -f "$FLAG" ] && echo yes) verdict=$(verdict decision) alerts=$(cat "$T/alerts.txt")"

# ── S2 control: the same page with a path that matches nothing ───────────────
reset_all
runs "$QA|.github/workflows/prod-qa.yml|failure|2026-10-01T09:20:00Z|aaaa111" \
     "$QA|.github/workflows/prod-qa.yml|failure|2026-10-01T09:10:00Z|aaaa111" \
     "CI|$CI|success|2026-10-01T09:00:00Z|aaaa111"
drive
{ [ -f "$FLAG" ] && [ "$(n_crit)" = 1 ]; } && ok \
  || bad "S2 a required workflow (name and path both miss) red twice must still freeze: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"

# ── S3 project-5: a scheduled red on a sha CI already passed ─────────────────
S3_PAGE=( "$AR|$ARP|failure|2026-10-01T06:00:00Z|xxxx999|completed|schedule"
          "CI|$CI|success|2026-09-30T20:00:00Z|xxxx999"
          "$AR|$ARP|success|2026-07-01T06:00:00Z|xxxx999|completed|schedule" )
reset_all
runs "${S3_PAGE[@]}"
drive
[ ! -e "$FLAG" ] && ok || bad "S3 a scheduled red froze main: $(cat "$FLAG" 2>/dev/null)"
[ "$(n_crit)" = 0 ] && ok || bad "S3 a scheduled red paged critical: $(cat "$T/alerts.txt")"
{ [ "$(n_alerts)" = 1 ] && [ "$(n_warn)" = 1 ] && grep -q "scheduled workflow \"$AR\"" "$T/alerts.txt"; } && ok \
  || bad "S3 expected exactly one warn naming the scheduled workflow: $(cat "$T/alerts.txt")"
grep -q 'merges are NOT frozen' "$T/alerts.txt" && ok || bad "S3 the warn must say merges are not frozen: $(cat "$T/alerts.txt")"
grep -q 'https://github.com/o/r/actions/runs/20261001060000' "$T/alerts.txt" && ok || bad "S3 the warn must carry the run url: $(cat "$T/alerts.txt")"
grep -qx 'main_red_sched o/r#20261001060000 warned' "$T/ledger/.puts" && ok \
  || bad "S3 the warn must be recorded in the ledger before the send: $(cat "$T/ledger/.puts")"
grep -q 'SCHED: o/r' "$T/logs/main-red.log" && ok || bad "S3 no SCHED: line in the log: $(cat "$T/logs/main-red.log")"
[ "$(verdict decision)" = green ] && ok || bad "S3 the push CI is green, so the verdict must be green: $(verdict decision) $(verdict reason)"

# ── S7 once per run: the same page again, ledger kept ────────────────────────
: > "$T/alerts.txt"
drive
[ "$(n_alerts)" = 0 ] && ok || bad "S7 the same scheduled run warned twice: $(cat "$T/alerts.txt")"
grep -q 'already warned' "$T/logs/main-red.log" && ok || bad "S7 the repeat must log 'already warned': $(cat "$T/logs/main-red.log")"

# ── S8 a NEW scheduled red run warns again, once ─────────────────────────────
: > "$T/alerts.txt"
runs "$AR|$ARP|failure|2026-10-01T07:00:00Z|xxxx999|completed|schedule" "${S3_PAGE[@]}"
drive
{ [ "$(n_alerts)" = 1 ] && [ "$(n_warn)" = 1 ] && grep -q 'actions/runs/20261001070000' "$T/alerts.txt"; } && ok \
  || bad "S8 a new scheduled red run must warn exactly once, naming its url: $(cat "$T/alerts.txt")"
[ ! -e "$FLAG" ] && ok || bad "S8 two scheduled reds in a row froze main"

# ── S4 two scheduled reds in a row are not a streak ──────────────────────────
reset_all
runs "$AR|$ARP|failure|2026-10-01T06:00:00Z|xxxx999|completed|schedule" \
     "$AR|$ARP|failure|2026-09-30T06:00:00Z|xxxx999|completed|schedule" \
     "CI|$CI|success|2026-09-29T20:00:00Z|xxxx999"
drive
{ [ ! -e "$FLAG" ] && [ "$(n_crit)" = 0 ]; } && ok || bad "S4 two scheduled reds made a streak: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"
{ [ "$(n_warn)" = 1 ] && grep -q 'actions/runs/20261001060000' "$T/alerts.txt"; } && ok \
  || bad "S4 exactly one warn, for the NEWEST scheduled run: $(cat "$T/alerts.txt")"

# ── S5 the same workflow red twice on PUSH still freezes, as today ───────────
reset_all
runs "$AR|$ARP|failure|2026-10-01T06:00:00Z|xxxx999" \
     "CI|$CI|success|2026-09-30T20:00:00Z|xxxx999" \
     "$AR|$ARP|failure|2026-07-01T06:00:00Z|xxxx999"
drive
{ [ -f "$FLAG" ] && grep -q '^reason=streak$' "$FLAG" && [ "$(n_crit)" = 1 ]; } && ok \
  || bad "S5 a push red streak must freeze exactly as before: flag=$(cat "$FLAG" 2>/dev/null) alerts=$(cat "$T/alerts.txt")"
[ "$(n_warn)" = 0 ] && ok || bad "S5 a push red must not send the scheduled warn: $(cat "$T/alerts.txt")"

# ── S6 a scheduled run in flight does not hold a push streak ─────────────────
reset_all
runs "CI|$CI|null|2026-10-01T08:00:00Z|bbbb222|in_progress|schedule" \
     "CI|$CI|failure|2026-10-01T07:00:00Z|bbbb222" \
     "CI|$CI|failure|2026-10-01T06:00:00Z|cccc333"
drive
{ [ -f "$FLAG" ] && grep -q '^reason=streak$' "$FLAG"; } && ok \
  || bad "S6 an in-flight scheduled run held a push streak: flag=$(cat "$FLAG" 2>/dev/null) verdict=$(verdict decision)/$(verdict reason)"
[ "$(verdict decision)" != held ] && ok || bad "S6 the verdict must not be held"

# ── S9 a skip-listed scheduled red stays pipeline-health's business ──────────
reset_all
runs "Nightly|.github/workflows/nightly.yml|failure|2026-10-01T03:00:00Z|xxxx999|completed|schedule" \
     "CI|$CI|success|2026-09-30T20:00:00Z|xxxx999"
drive
{ [ "$(n_alerts)" = 0 ] && [ ! -e "$FLAG" ]; } && ok || bad "S9 a skip-listed scheduled red alerted: $(cat "$T/alerts.txt")"

# ── S10 --explain is read-only ───────────────────────────────────────────────
reset_all
runs "${S3_PAGE[@]}"
drive --explain
grep -q 'WOULD ALERT(warn)' "$T/out.txt" && ok || bad "S10 --explain must print WOULD ALERT(warn): $(cat "$T/out.txt")"
grep -q 'main_red_sched' "$T/ledger/.puts" && bad "S10 --explain wrote the ledger: $(cat "$T/ledger/.puts")" || ok
[ "$(n_alerts)" = 0 ] && ok || bad "S10 --explain sent an alert: $(cat "$T/alerts.txt")"
[ ! -e "$T/state/main-red/o-r.verdict" ] && ok || bad "S10 --explain wrote a verdict"
grep -q 'WOULD WRITE' "$T/out.txt" && bad "S10 --explain would raise a flag on a scheduled red: $(cat "$T/out.txt")" || ok

# ── S11 a scheduled run in flight does not buy the burst re-read ─────────────
reset_all
runs "CI|$CI|null|2026-10-01T08:00:00Z|bbbb222|in_progress|schedule" \
     "$QA|.github/workflows/e2e-prod.yml|null|2026-10-01T08:01:00Z|bbbb222|in_progress"
drive
grep -q 'per_page=100' "$T/gh.txt" && bad "S11 an in-flight scheduled or path-skipped run triggered the deeper re-read: $(cat "$T/gh.txt")" || ok
[ "$(verdict reason)" = no-required ] && ok || bad "S11 a page of only scheduled/skipped runs must say no-required: $(verdict reason)"

# ── S12 a scheduled run in flight on a newer sha does not arm the burst arm ─
# One completed push red behind a head whose only in-flight run is a cron one:
# nothing required is in flight, so nothing is "still busy" and no arm fires.
reset_all
runs "CI|$CI|null|2026-10-01T08:00:00Z|dddd444|in_progress|schedule" \
     "CI|$CI|failure|2026-10-01T07:00:00Z|bbbb222" \
     "CI|$CI|success|2026-10-01T06:00:00Z|cccc333"
drive
{ [ ! -e "$FLAG" ] && [ "$(verdict reason)" = below-streak ]; } && ok \
  || bad "S12 an in-flight scheduled run armed the burst back-walk: flag=$(cat "$FLAG" 2>/dev/null) verdict=$(verdict decision)/$(verdict reason)"

# ── Q1 the merge-queue arm skips by path too ─────────────────────────────────
# Three independent red merge-queue batches of Production QA (e2e path) are not
# three red batches of a REQUIRED workflow.
q_batches() { # q_batches <path>
  local i out='['
  for i in 1 2 3; do
    [ "$i" = 1 ] || out+=','
    out+=$(jq -nc --arg p "$1" --argjson i "$i" '{name:"Production QA", path:$p, conclusion:"failure",
      head_sha:("q\($i)"), head_branch:("mergify/merge-queue/b\($i)"),
      display_title:("merge queue: embarking main (abc) and #\(100+$i) together"),
      created_at:("2026-10-01T0\($i):00:00Z"), id:(900+$i)}')
  done
  printf '%s]' "$out" > "$T/queue.json"
}
reset_all
runs "CI|$CI|success|2026-10-01T05:00:00Z|aaaa111"
q_batches .github/workflows/e2e-prod.yml
MAIN_RED_QUEUE_REPOS=o/r drive
[ ! -e "$FLAG" ] && ok || bad "Q1 red merge-queue batches of an e2e-path workflow froze main: $(cat "$FLAG" 2>/dev/null)"
reset_all
runs "CI|$CI|success|2026-10-01T05:00:00Z|aaaa111"
q_batches .github/workflows/prod-qa.yml
MAIN_RED_QUEUE_REPOS=o/r drive
{ [ -f "$FLAG" ] && grep -q '^reason=queue$' "$FLAG"; } && ok \
  || bad "Q1 control: three independent red batches of a required workflow must freeze: flag=$(cat "$FLAG" 2>/dev/null) log=$(tail -3 "$T/logs/main-red.log")"

# ── K1-K4 the skip regex: settings row > env > default, invalid -> default ───
ARK=".github/workflows/ar.yml"
k_page() { runs "$AR|$ARK|failure|2026-10-01T06:00:00Z|kkkk111" "$AR|$ARK|failure|2026-09-30T06:00:00Z|kkkk000"; }
KEY=lane.main-red-pr-pair.main_red_skip_re
reset_all; k_page; ROWS="$KEY=(e2e|nightly|access review)"
drive
[ ! -e "$FLAG" ] && ok || bad "K1 the settings row did not skip the workflow: $(cat "$FLAG" 2>/dev/null) err=$(cat "$T/err.txt")"
grep -q 'skip regex .* from settings' "$T/logs/main-red.log" && ok || bad "K1 the log must say the regex came from settings: $(grep 'skip regex' "$T/logs/main-red.log")"

reset_all; k_page
echo "MAIN_RED_SKIP_RE='(e2e|nightly|smoke|publish|deploy|access review)'" > "$T/env/global.env"
drive
[ ! -e "$FLAG" ] && ok || bad "K2 the env/global.env regex did not skip the workflow"
grep -q 'skip regex .* from env' "$T/logs/main-red.log" && ok || bad "K2 the log must say the regex came from env: $(grep 'skip regex' "$T/logs/main-red.log")"
reset_all; k_page
echo "MAIN_RED_SKIP_RE='(e2e|nightly|smoke|publish|deploy|access review)'" > "$T/env/global.env"
ROWS="$KEY=(e2e|nightly|smoke|publish|deploy)"
drive
[ -f "$FLAG" ] && ok || bad "K2 the settings row must win over env: no flag, log=$(grep 'skip regex' "$T/logs/main-red.log")"

reset_all; k_page
drive
[ -f "$FLAG" ] && ok || bad "K3 the default regex must not skip an access review"
grep -q 'skip regex (e2e|nightly|smoke|publish|deploy) from default' "$T/logs/main-red.log" && ok \
  || bad "K3 the log must say the default won: $(grep 'skip regex' "$T/logs/main-red.log")"

reset_all
runs "CI|$CI|failure|2026-10-01T06:00:00Z|kkkk111" "CI|$CI|failure|2026-09-30T06:00:00Z|kkkk000"
ROWS="$KEY=(e2e"
drive
[ -f "$FLAG" ] && ok || bad "K4 an invalid regex disarmed the detector: no flag, log=$(cat "$T/logs/main-red.log")"
{ [ "$(n_warn)" = 1 ] && grep -- '--severity warn' "$T/alerts.txt" | grep -qF '(e2e'; } && ok \
  || bad "K4 one warn naming the invalid value: $(cat "$T/alerts.txt")"
grep -q 'invalid' "$T/logs/main-red.log" && ok || bad "K4 the log must say the regex is invalid"
[ "$(n_crit)" = 1 ] && ok || bad "K4 the red CI must still page critical: $(cat "$T/alerts.txt")"

# ── K5 pr_head_error reads the same knob by name OR path ─────────────────────
# The function, as shipped, out of the lane script: the lane's own tick needs a
# PR list, a pair and a ledger to reach it, and this is the one read that moved.
PHE=$(awk '/^pr_head_error\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$DIR/bin/main-red-pr-pair.sh")
case "$PHE" in "pr_head_error() {"*) ok ;; *) bad "K5 pr_head_error not found in bin/main-red-pr-pair.sh" ;; esac
k5() { # k5 <runs-json-file> [pair-window-s] -> pr_head_error's stdout, rc in K5RC
  K5OUT=$( export PATH="$T/fakebin:$PATH" T="$T" GH_SINK="$T/gh.txt" K5RUNS="$1"
    SKIP_RE='(e2e|nightly|smoke|publish|deploy)'; PAIR_WINDOW="${2:-3600}"
    first_error_of_job() { printf 'boom'; return 0; }
    eval "$PHE"; pr_head_error o/r hhhh111 2026-10-01T06:00:00Z ); K5RC=$?
}
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  *"/actions/runs/"*"/jobs"*) printf 'QA job\t77\n' ;;
  *"actions/runs"*) jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url, id:.id}]' "$K5RUNS" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"
cat > "$T/k5a.json" <<'JSON'
{"workflow_runs":[
 {"name":"Production QA","path":".github/workflows/e2e-prod.yml","status":"completed","conclusion":"failure","created_at":"2026-10-01T06:05:00Z","html_url":"u1","id":11},
 {"name":"CI","path":".github/workflows/ci.yml","status":"completed","conclusion":"success","created_at":"2026-10-01T06:01:00Z","html_url":"u2","id":12}]}
JSON
k5 "$T/k5a.json"
{ [ "$K5RC" = 0 ] && [ "$K5OUT" = "$(printf -- '-\t-\t-')" ]; } && ok \
  || bad "K5 a red Production QA (e2e path) must not be the head's error: rc=$K5RC out=$K5OUT"
cat > "$T/k5b.json" <<'JSON'
{"workflow_runs":[
 {"name":"Production QA","path":".github/workflows/e2e-prod.yml","status":"in_progress","conclusion":null,"created_at":"2026-10-01T06:05:00Z","html_url":"u1","id":11},
 {"name":"CI","path":".github/workflows/ci.yml","status":"completed","conclusion":"success","created_at":"2026-10-01T06:01:00Z","html_url":"u2","id":12}]}
JSON
k5 "$T/k5b.json"
{ [ "$K5RC" = 0 ] && [ "$K5OUT" = "$(printf -- '-\t-\t-')" ]; } && ok \
  || bad "K5 an in-flight Production QA (e2e path) must not keep the head pending: rc=$K5RC out=$K5OUT"
# A head whose only COMPLETED run is the e2e-path one has no required run done:
# inside the pair window that is "ask again", never an error to group on.
cat > "$T/k5d.json" <<'JSON'
{"workflow_runs":[
 {"name":"Production QA","path":".github/workflows/e2e-prod.yml","status":"completed","conclusion":"failure","created_at":"2026-10-01T06:05:00Z","html_url":"u1","id":11}]}
JSON
k5 "$T/k5d.json" 999999999
{ [ "$K5RC" = 1 ] && [ -z "$K5OUT" ]; } && ok \
  || bad "K5 an e2e-path run must not count as a required run done: rc=$K5RC out=$K5OUT"
cat > "$T/k5c.json" <<'JSON'
{"workflow_runs":[
 {"name":"Production QA","path":".github/workflows/prod-qa.yml","status":"completed","conclusion":"failure","created_at":"2026-10-01T06:05:00Z","html_url":"u1","id":11}]}
JSON
k5 "$T/k5c.json"
{ [ "$K5RC" = 0 ] && [ "$(cut -f1 <<<"$K5OUT")" = "QA job" ]; } && ok \
  || bad "K5 control: a required red (name and path both miss) must be the head's error: rc=$K5RC out=$K5OUT"

echo "main-red-schedule-skip.bh-3769: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
