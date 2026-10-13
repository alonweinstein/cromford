#!/bin/bash
# tests/archie-fm-queue-mode-cache.bh-5943-test.sh — BH-5943 (BH-5938.3): when
# the single-key archie.manage read fails (a worker 503 at the quarter-hour
# burst), bin/archie-fm-queue.sh takes the mode from the box settings cache
# (state/settings-cache.json, lane-gate's list read) if that cache is at most
# ARCHIE_FMQ_MODE_CACHE_MAX_S old (default 1200). Otherwise it skips the
# project as before, and the skip line names the cause.
#
# THE WORLD is tests/archie-fm-queue.bh-4584-test.sh's, copied: project `fixt`
# -> acme/fixt, the ARCHIE_FMQ_FIXTURE stub of _jobs_req and the REST reads.
# One change: with $T/settings.down, GET /api/settings/archie.manage* answers 503 and
# writes `http=503` to JOBS_STATUS_FILE, as bin/lib/jobs/req.sh does.
#
#   AT-2a settings row on, cache 120 s old, settings down: the project is
#         processed (settle row, open-PR read, `using the box settings cache`)
#   AT-2b the cache says observe: would_* rows only, no write
#   AT-2c the cache is older than the knob: skipped, the line names the cause
#   AT-2d knob 0, fetched_at 0, a future fetched_at, cache `off`: no action
#   AT-2e no archie.manage key in a fresh cache: the default `on`; not JSON
#         or missing: skipped
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-queue-mode-cache.bh-5943-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-queue-mode-cache: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-queue-mode-cache: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

for f in "$DIR/bin/archie-fm-queue.sh" "$DIR/bin/lib/archie-fm-queue/common.sh" "$DIR/catalog/lanes.d/archie-fm-queue.json"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "archie-fm-queue-mode-cache: 0 passed, 1 failed"; exit 1; }
done

NOW=1791184500                       # 2026-10-05T07:15:00Z
DAY=2026-10-05
export HOME="$T/home"
mkdir -p "$T/home" "$T/tmp"
sha() { printf '%040x' "$1"; }
MAIN=$(sha 999999)

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
printf 'fixt acme/fixt hub -\n' > "$H/fleet.conf"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/lead-verdict.sh" "$H/bin/merge-conductor.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) echo fixt ;;
  --*) ;;
  *) [ "${2:-}" = repo ] && echo "acme/$1" ;;
esac
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/lead-verdict.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/verdicts.log"
rc=$(cat "$FXT/lv.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] && echo "recorded verdict #7: BLOCK (lead)"
[ "$rc" = 1 ] && echo "lead-verdict: HTTP 403 lead token required" >&2
exit "$rc"
SH
cat > "$H/bin/merge-conductor.sh" <<'SH'
#!/bin/bash
printf 'MC_ONLY_PR=%s\n' "${MC_ONLY_PR:-}" >> "$FXT/kick.log"
exit 0
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/lead-verdict.sh" "$H/bin/merge-conductor.sh"
# Nothing reaches the network: gh and curl log and fail.
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

cat > "$T/fx.sh" <<'SH'
fx_clock() { date -u -d "@$ARCHIE_FMQ_NOW" +%Y-%m-%dT%H:%M:%SZ; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/flags*|/api/lanes*|/api/verdicts*|/api/job*|/api/pr-*) JOBS_HTTP=404; return 2 ;; esac
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  t=$(fx_clock)
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
      case "${p#/api/settings/}" in archie.manage*) [ -f "$FXT/settings.down" ] && { JOBS_HTTP=503; [ -n "${JOBS_STATUS_FILE:-}" ] && echo http=503 > "$JOBS_STATUS_FILE"; return 1; } ;; esac
      key=${p#/api/settings/}
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; } ;;
    "POST /api/archie/actions")
      key=$(jq -r .dedupe_key <<<"$b")
      out=$(jq -c --arg k "$key" '.actions[] | select(.dedupe_key == $k)' "$db")
      if [ -z "$out" ]; then
        jq --argjson b "$b" --arg t "$t" '.actions += [$b + {id: ((.actions | length) + 1), day: $t[0:10], attempts: 1,
            evidence: ($b.evidence // {}), created_at: $t, updated_at: $t}]' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c --arg k "$key" '{ok: true, created: true, action: (.actions[] | select(.dedupe_key == $k))}' "$db"); code=201
      elif jq -e --argjson b "$b" '.project == $b.project and .repo == $b.repo and .pr == $b.pr and .playbook == $b.playbook and .mode == $b.mode' <<<"$out" >/dev/null; then
        out=$(jq -c '{ok: true, existing: true, action: .}' <<<"$out")
      else
        out=$(jq -c '{error: "different payload", action: .}' <<<"$out"); JOBS_HTTP=409; JOBS_BODY=$out; printf '%s' "$out"; return 9
      fi ;;
    "POST /api/archie/actions/outcome")
      out=$(jq -c --argjson b "$b" '.actions[] | select(.id == $b.id and .dedupe_key == $b.dedupe_key)' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; }
      if ! jq -e --argjson b "$b" '(.outcome + ">" + $b.outcome) as $tr
           | ["started>done","started>requested","started>would","started>deferred","started>failed","deferred>started","deferred>failed"]
           | index($tr) != null' <<<"$out" >/dev/null || ! jq -e --argjson b "$b" '.updated_at == $b.expect_updated_at' <<<"$out" >/dev/null; then
        out=$(jq -c '{error: "stale or illegal", action: .}' <<<"$out"); JOBS_HTTP=409; JOBS_BODY=$out; printf '%s' "$out"; return 9
      fi
      jq --argjson b "$b" --arg t "$t" '.actions |= map(if .id == $b.id then
          .outcome = $b.outcome | .action = ($b.action // .action) | .why = ($b.why // .why)
          | .evidence = ($b.evidence // .evidence) | .updated_at = $t else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db") ;;
    "GET /api/archie/actions")
      [ -f "$FXT/count.down" ] && { JOBS_HTTP=503; return 1; }
      local d pb; d=$(qp day); pb=$(qp playbook)
      out=$(jq -c --arg d "$d" --arg pb "$pb" '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] as $r
        | {ok: true, day: $d, actions: $r,
           counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][$x.outcome] += 1)), truncated: false}' "$db") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
fx_enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g'; }
gh_rest() {
  local m="$1" p="$2" f
  printf '%s %s\n' "$m" "$p" >> "$FXT/ghrest.log"
  [ -f "$FXT/gh.down" ] && { GH_REST_STATUS=502; return 75; }
  f="$FXT/gh/$(fx_enc "$p")"
  [ -f "$f" ] || { GH_REST_STATUS=404; return 44; }
  GH_REST_STATUS=200; cat "$f"; return 0
}
gh_rest_pr_list_var() {
  local v="$1" slug="$2" state="$3" out
  printf 'list %s %s\n' "$slug" "$state" >> "$FXT/ghrest.log"
  [ -f "$FXT/gh.down" ] && { printf -v "$v" '%s' ''; GH_REST_STATUS=502; return 75; }
  if [ "$state" = closed ]; then out=$(cat "$FXT/closed.json"); else out=$(cat "$FXT/open.json"); fi
  printf -v "$v" '%s' "$out"; GH_REST_STATUS=200; return 0
}
gh_rest_issue_list() { printf 'ilist %s\n' "$1" >> "$FXT/ghrest.log"; cat "$FXT/issues.json"; }
gh_rest_pr_list_all() { printf 'plist %s\n' "$1" >> "$FXT/ghrest.log"; cat "$FXT/open.json"; }
gh_rest_comment() {
  printf 'comment %s %s\n' "$1" "$2" >> "$FXT/writes.log"
  mkdir -p "$FXT/comments"; cat "$3" >> "$FXT/comments/$2"
  [ -f "$FXT/comment.refuse" ] && return 75
  return 0
}
mc_enqueue_mergify() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$FXT/enqueue.log"
  printf 'enqueue %s\n' "$2" >> "$FXT/writes.log"
  cat "$FXT/enqueue.out" 2>/dev/null
  return "$(cat "$FXT/enqueue.rc" 2>/dev/null || echo 0)"
}
conductor_settle() {
  printf '%s\n' "$*" >> "$FXT/settle.log"
  printf 'settle %s\n' "$1" >> "$FXT/writes.log"
  [ -f "$FXT/settle.noop" ] && return 0
  mc_transition "$1" MERGED "${12}" "$8" "$9" "$2" "${10}" "${11}" "$6" >/dev/null
}
mc_queue_provider() { cat "$FXT/provider" 2>/dev/null || printf mergify; }
mc_mergify_witness() { [ -f "$FXT/witness.$(basename "$2")" ]; }
to_lane_hold() { printf 'tolanehold %s\n' "$3" >> "$FXT/ghrest.log"; [ -f "$FXT/held" ]; }
to_lane_lead_fence() {
  TO_LEAD_CLEARED=0
  [ -f "$FXT/lead.down" ] && return 2
  [ -f "$FXT/lead.$3" ] && return 0
  [ -f "$FXT/leadcleared.$3" ] && TO_LEAD_CLEARED=1
  return 1
}
bg_scan() {
  [ -f "$FXT/bg.down" ] && { printf 'head-time'; return 2; }
  [ -f "$FXT/bgblock.$2" ] && { printf 'https://github.com/x\toperator\t2026-10-05T06:00:00Z\t1'; return 1; }
  return 0
}
vd_standing() {
  [ -f "$FXT/vd.down" ] && return 2
  [ -f "$FXT/verdict.$2" ] || return 1
  [ -f "$FXT/verdict.$2.head" ] && [ "$(cat "$FXT/verdict.$2.head")" != "$3" ] && return 1
  printf '%s\tlead\t1\t2026-10-05T07:00:00Z\t-\tlead\n' "$(cat "$FXT/verdict.$2")"
}
pq_run_title() { printf 'prequeue pr=%s head=%s main=%s' "$1" "$2" "$3"; }
pq_dispatch() {
  local path
  printf '%s %s %s %s\n' "$2" "$3" "$4" "${5:-}" >> "$FXT/dispatch.log"
  printf 'dispatch %s\n' "$2" >> "$FXT/writes.log"
  if [ -f "$FXT/dispatch.nofp" ]; then path=$(pq_key "$1" "$2" "$3" "$4"); else path=$(pq_key "$1" "$2" "$3" "$4" "${6:-}"); fi
  [ -n "$(pq_cache_get "$path")" ] && return 3
  pq_cache_put "$path" pending "$(date +%s)" - "" || return 4
  return "$(cat "$FXT/dispatch.rc" 2>/dev/null || echo 0)"
}
pq_read_run() {
  local n; n=${2#prequeue pr=}; n=${n%% *}
  printf 'readrun %s\n' "$n" >> "$FXT/ghrest.log"
  cat "$FXT/run.$n" 2>/dev/null
  return 0
}
flaky_run_tests_strict() { [ -f "$FXT/runlog.$2" ] || return 2; cat "$FXT/runlog.$2"; }
bs_batch() { :; }
[ -f "$FXT/nopool" ] && unset -f pq_dispatch pq_read_run pq_run_title
[ -f "$FXT/no4550" ] && unset -f bs_batch
:
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
       MC_REHYDRATE=0 TMPDIR="$T/tmp" MC_AUTOENQUEUE_CHECK=ci
unset ARCHIE_FMQ_ENABLED ARCHIE_FMQ_RETRY_S ARCHIE_FMQ_PROJECTS_PER_TICK ARCHIE_FMQ_KICK_TIMEOUT_S \
  ARCHIE_FMQ_SOLO_TIMEOUT_S ARCHIE_FMQ_BATCH_WINDOW_S ARCHIE_FMQ_NOW ARCHIE_FMQ_FIXTURE ARCHIE_FMQ_TIMED \
  ARCHIE_FMQ_TICK_CEILING_S 2>/dev/null || true

ROWS="$H/state/merge-conductor/pr-state.tsv"
ATT="$H/state/merge-conductor/attempts.txt"
# world — a fresh db, GitHub, conductor state and logs. Merges are on.
world() {
  local p
  for p in gh db.json reqlog ghrest.log net.log alerts.log writes.log enqueue.log settle.log verdicts.log kick.log \
           dispatch.log comments open.json closed.json issues.json provider held gh.down settings.down count.down \
           vd.down enqueue.rc enqueue.out lv.rc dispatch.rc comment.refuse nopool no4550 dispatch.nofp settle.noop \
           lead.down bg.down out rc; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/witness.* "$T"/verdict.* "$T"/run.* "$T"/runlog.* "$T"/lead.* "$T"/leadcleared.* "$T"/bgblock.*
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/flags" || exit 1
  scratch_rm "$H/logs/archie-fm-queue.log" || exit 1; scratch_rm "$H/logs/merge-conductor.log" || exit 1
  mkdir -p "$T/gh" "$H/state/merge-conductor" "$H/flags" "$H/locks"
  : > "$ROWS"; : > "$ATT"
  touch "$H/flags/merge-conductor-merge" "$H/flags/merge-conductor-actions"
  echo '[]' > "$T/open.json"; echo '[]' > "$T/closed.json"; echo '[]' > "$T/issues.json"
  jq -n '{settings: {"archie.manage": "on"}, actions: []}' > "$T/db.json"
  : > "$T/reqlog"; : > "$T/ghrest.log"; : > "$T/writes.log"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
ghput() { printf '%s\n' "$2" > "$T/gh/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }
rowput() { # rowput <n> <state> <age-s> <head> <reason>
  printf 'acme/fixt#%s\t%s\t%s\t%s\t%s\t-\t%s\thttps://github.com/acme/fixt/pull/%s\n' \
    "$1" "$2" "$((NOW - $3))" "$4" "$4" "$5" "$1" >> "$ROWS"
}
# pull <n> <head> <state open|closed|merged> [mergeable_state] [body] — the pulls/<n> GET.
pull() {
  ghput "repos/acme/fixt/pulls/$1" "$(jq -nc --argjson n "$1" --arg h "$2" --arg st "$3" --arg ms "${4:-clean}" --arg b "${5:-}" \
    '{number: $n, state: (if $st == "open" then "open" else "closed" end),
      merged_at: (if $st == "merged" then "2026-10-05T06:30:00Z" else null end), draft: false,
      mergeable_state: $ms, body: $b, user: {login: "someone"}, labels: [],
      html_url: ("https://github.com/acme/fixt/pull/" + ($n | tostring)),
      head: {ref: ("ticket/bh-" + ($n | tostring)), sha: $h, repo: {full_name: "acme/fixt"}}, base: {ref: "main"}}')"
}
# listpr <n> <head> [jq-update] — one PR in the open list (the gh_rest_pr_list shape).
listpr() {
  jq --argjson n "$1" --arg h "$2" "map(select(.number != \$n)) + [({number: \$n, state: \"open\", draft: false, merged_at: null,
      html_url: (\"https://github.com/acme/fixt/pull/\" + (\$n | tostring)), labels: [], user: {login: \"collaborator-1\"},
      head: {ref: (\"feature/x-\" + (\$n | tostring)), sha: \$h, repo: {full_name: \"acme/fixt\"}}, base: {ref: \"main\"}} | ${3:-.})]" \
    "$T/open.json" > "$T/open.tmp" && mv "$T/open.tmp" "$T/open.json"
}
greenchecks() { # greenchecks <head> [conclusion] [status]
  ghput "repos/acme/fixt/commits/$1/check-runs?per_page=100" "$(jq -nc --arg c "${2:-success}" --arg s "${3:-completed}" \
    '{total_count: 1, check_runs: [{id: 1, name: "ci", status: $s, conclusion: (if $s == "completed" then $c else null end)}]}')"
  ghput "repos/acme/fixt/commits/$1/status" '{"state": "success", "total_count": 1}'
}
approve() { # approve <n> <commit-id> [state]
  ghput "repos/acme/fixt/pulls/$1/reviews?per_page=100" "$(jq -nc --arg c "$2" --arg s "${3:-APPROVED}" \
    '[{id: 1, user: {login: "operator"}, state: $s, commit_id: $c, submitted_at: "2026-10-05T06:00:00Z"}]')"
}
tick() { # tick [VAR=value ...] — one tick of the shipped lane at NOW
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FMQ_NOW="$NOW" ARCHIE_FMQ_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 "$@" \
    bash "$H/bin/archie-fm-queue.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rows()   { jq '.actions | length' "$T/db.json"; }
rowsof() { jq --arg a "$1" '[.actions[] | select(.action == $a)] | length' "$T/db.json"; }
rowf()   { jq -r --arg a "$1" --arg f "$2" '[.actions[] | select(.action == $a)][0] | getpath($f | split(".")) // "null" | tostring' "$T/db.json"; }
nlines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
rstate() { awk -F'\t' -v k="acme/fixt#$1" '$1 == k { print $2 }' "$ROWS"; }
qlog()   { cat "$H/logs/archie-fm-queue.log" 2>/dev/null; }

H41=$(sha 41)
ejected_world() { # Q-EJECTED's world: a PR merged on GitHub, logged ejected
  world
  rowput 41 BLOCKED_HUMAN 7200 "$H41" "br-ladder-rebuild: fresh rebuild requested"
  echo "ejected acme/fixt#41 $H41" >> "$ATT"
  pull 41 "$H41" merged
}
CACHE="$H/state/settings-cache.json"
# cache <fetched_at> <values-json> [seeded-json] — the box settings cache, in
# the shape lane-gate's _lg_settings_refresh writes.
cache() {
  mkdir -p "$H/state"
  jq -nc --argjson fa "$1" --argjson v "$2" --argjson s "${3:-{\}}" '{fetched_at:$fa, values:$v, seeded:$s}' > "$CACHE"
}
processed() { [ "$(rowsof settle_merged)" = 1 ] && [ "$(rowf settle_merged outcome)" = done ] && grep -q '^list acme/fixt open' "$T/ghrest.log"; }
skipped() { [ "$(rows)" = 0 ] && [ ! -s "$T/ghrest.log" ] && [ ! -s "$T/settle.log" ]; }

# ── AT-2a: the row is on, the read fails, the cache is 120 s old ────────────
ejected_world; setting archie.manage.fixt on; : > "$T/settings.down"
cache $((NOW - 120)) '{"archie.manage.fixt":"on"}'
tick
check "AT-2a rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "AT-2a the project is processed: settle row done, open-PR list read ($(qlog | tail -3))" processed
check "AT-2a the log says where the mode came from" \
  'qlog | grep -qF "fixt: the archie.manage settings could not be read (http=503); using the box settings cache from 120s ago: mode=on"'
check "AT-2a no skip line" '! qlog | grep -q "skipped this tick"'
check "AT-2a the tick left the cache file as written" '[ "$(jq -c .fetched_at "$CACHE")" = "$((NOW - 120))" ]'
check "AT-2a the status file is gone with the tick" '[ -z "$(ls "$T/tmp" 2>/dev/null | grep -i afq)" ]'

# the inclusive bound: exactly 1200 s old is used
ejected_world; : > "$T/settings.down"; cache $((NOW - 1200)) '{"archie.manage.fixt":"on"}'; tick
check "AT-2a a cache exactly 1200 s old is used" 'processed && qlog | grep -q "from 1200s ago: mode=on"'
# the per-project key wins over archie.manage, and seeded rows count
ejected_world; : > "$T/settings.down"; cache $((NOW - 60)) '{"archie.manage":"off"}' '{"archie.manage.fixt":"on"}'; tick
check "AT-2a archie.manage.<p> (seeded) wins over archie.manage" 'processed && qlog | grep -q "mode=on"'

# ── AT-2b: the cache says observe ───────────────────────────────────────────
ejected_world; : > "$T/settings.down"; cache $((NOW - 120)) '{"archie.manage.fixt":"observe"}'; tick
check "AT-2b observe from the cache: one would row, zero writes ($(jq -c '[.actions[] | .mode + "/" + .outcome]' "$T/db.json"))" \
  '[ "$(rowsof would_settle_merged)" = 1 ] && [ "$(rowf would_settle_merged mode)" = observe ] && [ ! -s "$T/writes.log" ] && [ "$(rstate 41)" = BLOCKED_HUMAN ]'
check "AT-2b the log says mode=observe" 'qlog | grep -q "from 120s ago: mode=observe"'
ejected_world; : > "$T/settings.down"; cache $((NOW - 120)) '{"archie.manage.fixt":"maybe"}'; tick
check "AT-2b a value that is not on/observe/off reads as observe" \
  '[ "$(rowsof would_settle_merged)" = 1 ] && [ ! -s "$T/writes.log" ] && qlog | grep -q "mode=observe"'

# ── AT-2c: the cache is older than the knob ────────────────────────────────
ejected_world; : > "$T/settings.down"; cache $((NOW - 1300)) '{"archie.manage.fixt":"on"}'; tick
check "AT-2c 1300 s old: skipped, nothing read, no row" skipped
check "AT-2c the skip line names the cause ($(qlog | tail -1))" \
  'qlog | grep -qF "fixt: the archie.manage settings could not be read (http=503); skipped this tick (no action without the ledger)"'
ejected_world; : > "$T/settings.down"; cache $((NOW - 120)) '{"archie.manage.fixt":"on"}'; tick ARCHIE_FMQ_MODE_CACHE_MAX_S=60
check "AT-2c the knob bounds the age: 120 s with a 60 s knob is skipped" 'skipped && qlog | grep -q "skipped this tick"'

# ── AT-2d: no action when the cache cannot be trusted, or says off ─────────
ejected_world; : > "$T/settings.down"; cache $((NOW - 120)) '{"archie.manage.fixt":"on"}'; tick ARCHIE_FMQ_MODE_CACHE_MAX_S=0
check "AT-2d knob 0: skipped as before BH-5943" 'skipped && qlog | grep -q "skipped this tick"'
ejected_world; : > "$T/settings.down"; cache "$NOW" '{"archie.manage.fixt":"on"}'; tick ARCHIE_FMQ_MODE_CACHE_MAX_S=0
check "AT-2d knob 0 with a cache written this second: still skipped" 'skipped && qlog | grep -q "skipped this tick"'
ejected_world; : > "$T/settings.down"; cache 0 '{"archie.manage.fixt":"on"}'; tick
check "AT-2d fetched_at 0 (a write marked it stale): skipped" 'skipped && qlog | grep -q "skipped this tick"'
ejected_world; : > "$T/settings.down"; cache $((NOW + 300)) '{"archie.manage.fixt":"on"}'; tick
check "AT-2d fetched_at in the future: skipped" 'skipped && qlog | grep -q "skipped this tick"'
ejected_world; : > "$T/settings.down"; cache $((NOW - 120)) '{"archie.manage.fixt":"off"}'; tick
check "AT-2d cache says off: no GitHub read, no row" 'skipped && ! qlog | grep -q "skipped this tick"'
check "AT-2d cache says off: the log says mode=off" 'qlog | grep -q "from 120s ago: mode=off"'
ejected_world; : > "$T/settings.down"; cache $((NOW - 120)) '{"archie.manage.fixt":"on"}'; tick ARCHIE_FMQ_MODE_CACHE_MAX_S=99999
check "AT-2d an out-of-range knob is one warn line and the default 1200" \
  'processed && qlog | grep -q "ARCHIE_FMQ_MODE_CACHE_MAX_S=99999 is outside 0..3600; using the default 1200"'

# ── AT-2e: a fresh cache with no key; a cache that is not JSON ─────────────
ejected_world; : > "$T/settings.down"; cache $((NOW - 120)) '{"lane.other.knob":"1"}'; tick
check "AT-2e no archie.manage key in a fresh cache: the default on, processed" 'processed && qlog | grep -q "mode=on"'
ejected_world; : > "$T/settings.down"; mkdir -p "$H/state"; printf 'not json{' > "$CACHE"; tick
check "AT-2e a cache that is not JSON: skipped ($(qlog | tail -1))" 'skipped && qlog | grep -q "skipped this tick"'
check "AT-2e no stderr noise ($(head -c 300 "$T/out"))" '[ ! -s "$T/out" ]'
ejected_world; : > "$T/settings.down"; tick
check "AT-2e no cache file: skipped" 'skipped && qlog | grep -q "skipped this tick"'
# the readable path is unchanged: a working read never consults the cache
ejected_world; cache $((NOW - 120)) '{"archie.manage.fixt":"off"}'; tick
check "AT-2e the settings read works: the cache is not used" 'processed && ! qlog | grep -q "box settings cache"'

echo "archie-fm-queue-mode-cache: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
