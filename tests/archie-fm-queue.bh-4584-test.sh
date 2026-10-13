#!/bin/bash
# tests/archie-fm-queue.bh-4584-test.sh — BH-4584 (BH-4574.2): Archie's queue
# doctor, driven through the SHIPPED bin/archie-fm-queue.sh (the ticket's
# tests/archie-fm-queue-test.sh, keyed to the ticket per house rule).
#
# THE WORLD. One project `fixt` -> acme/fixt on a GitHub-Issues board, with the
# conductor's real state files (state/merge-conductor/pr-state.tsv, 8 columns,
# and attempts.txt) under a scratch $HARNESS. Every GitHub read goes through a
# stubbed gh_rest that answers from $T/gh/<path> files (a missing file is a
# 404, $T/gh.down is a 502), so each case writes exactly the REST answers the
# lane reads.
#
# WHAT IS STUBBED, and only this. ARCHIE_FMQ_FIXTURE=$T/fx.sh (sandbox-only):
#   _jobs_req             the jq model of /api/settings/<key> and the three
#                         /api/archie/actions routes (wave 1's model, whose
#                         worker side runs for real in
#                         worker/jobs/test/archie-actions.bh-4584.test.js);
#   gh_rest, gh_rest_pr_list_var, gh_rest_issue_list, gh_rest_pr_list_all
#                         the REST reads, logged to $T/ghrest.log;
#   mc_enqueue_mergify    logs to $T/enqueue.log, rc from $T/enqueue.rc;
#   conductor_settle      logs to $T/settle.log, then the real mc_transition
#                         to MERGED (the issue close / deploy it would run are
#                         the conductor's, not this lane's);
#   mc_queue_provider, mc_mergify_witness, vd_standing (head-bound when
#                         $T/verdict.<n>.head names a head), to_lane_hold,
#                         to_lane_lead_fence, bg_scan
#                         answered from $T files. pdg_hold is the REAL gate,
#                         reading the same stubbed REST answers;
#   pq_dispatch, pq_read_run, pq_run_title, flaky_run_tests_strict, bs_batch
#                         #4550's CI-pool contract (pq_dispatch writes its
#                         `pending` cache line first, as the real one does, on
#                         the fp key; $T/dispatch.nofp drops the fp the way
#                         #4548's does; $T/no4550 unsets bs_batch);
#   gh_rest_comment       copies the body to $T/comments/<n>.
# $H/bin/lead-verdict.sh logs argv to $T/verdicts.log and $H/bin/merge-conductor.sh
# logs MC_ONLY_PR to $T/kick.log: the lane calls both by path.
#
# Cases: Q-EJECTED (+ the settle negatives), Q-CAP, Q-WAITCI, Q-WAITCI-NEG,
# Q-DEP-SIBLING, Q-DEP-OPEN, Q-DEP-ISSUE, Q-ENQ-EXTERNAL, Q-ENQ-NEG,
# Q-BATCH-READ, Q-SOLO-DEDUP, Q-BATCH-5, Q-BATCH-ONE, Q-MAIN-MOVES, Q-MERGED-WITNESS,
# Q-CULPRIT-NEG, Q-OBSERVE, Q-OFF,
# Q-LOCK, Q-CLAIM, Q-STALE, Q-SCOPE, Q-STATIC, Q-ENQ-GATE, Q-FP, Q-SETTLE-RC,
# X mutations.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-queue.bh-4584-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-queue: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-queue: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${ARCHIE_FMQ_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-fm-queue.sh" "$DIR/bin/lib/archie-fm-queue/common.sh" \
         "$DIR/bin/lib/archie-fm-queue/reconcile.sh" "$DIR/bin/lib/archie-fm-queue/enqueue.sh" \
         "$DIR/bin/lib/archie-fm-queue/culprit.sh" "$DIR/worker/jobs/src/routes/archie-actions.js" \
         "$DIR/catalog/lanes.d/archie-fm-queue.json" "$DIR/cron/lanes/726-archie-fm-queue.cron"; do
  if [ -f "$f" ]; then ok "ships ${f#"$DIR"/}"; else bad "missing $f"; fi
done
if [ ! -f "$DIR/bin/archie-fm-queue.sh" ]; then
  echo "archie-fm-queue: $PASS passed, $FAIL failed"; exit 1
fi

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
      [ -f "$FXT/settings.down" ] && { JOBS_HTTP=503; return 1; }
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

H41=$(sha 41); H42=$(sha 42); H43=$(sha 43); H44=$(sha 44); H45=$(sha 45); H46=$(sha 46); H50=$(sha 50)

# ── Q-EJECTED: merged on GitHub, logged ejected -> settled MERGED ───────────
ejected_world() { # the reason moved on (br-ladder), the attempts line is BH-4562's
  world
  rowput 41 BLOCKED_HUMAN 7200 "$H41" "br-ladder-rebuild: fresh rebuild requested"
  echo "ejected acme/fixt#41 $H41" >> "$ATT"
  pull 41 "$H41" merged
}
q_ejected() {
  ejected_world; tick
  [ "$(cat "$T/rc")" = 0 ] && [ "$(nlines "$T/settle.log")" = 1 ] && [ "$(rstate 41)" = MERGED ] \
    && [ "$(rows)" = 1 ] && [ "$(rowf settle_merged outcome)" = done ]
}
check "Q-EJECTED conductor_settle once, the row MERGED, one settle_merged/done row ($(cat "$T/out" 2>/dev/null))" q_ejected
eq "Q-EJECTED the settle is the conductor's, with merges on and the archie reason" \
  "$(cut -d' ' -f1-3,11- "$T/settle.log")" "acme/fixt#41 https://github.com/acme/fixt/pull/41 fixt CLEAN by:archie-fm-queue (merged on GitHub, logged ejected)"
eq "Q-EJECTED the key" "$(rowf settle_merged dedupe_key)" "queue-reconcile:acme/fixt#41:settle:$H41:on"
eq "Q-EJECTED evidence prev_state" "$(rowf settle_merged evidence.prev_state)" BLOCKED_HUMAN
eq "Q-EJECTED evidence eject_lines" "$(rowf settle_merged evidence.eject_lines)" 1
check "Q-EJECTED the handoff is released (merged)" 'grep -rqs "merged$" "$H/state/merge-conductor/handoff-released/"'
: > "$T/reqlog"; tick
check "Q-EJECTED a second tick writes nothing" '[ "$(nlines "$T/settle.log")" = 1 ] && [ "$(rows)" = 1 ] && ! grep -q "^POST" "$T/reqlog"'
check "Q-EJECTED a summary line counts the settle" 'qlog | grep -q "settled=1"'

# reason still queue-ejected (no attempts line) is a candidate too
world; rowput 41 WAIT_CI 600 "$H41" "queue-ejected"; pull 41 "$H41" merged; tick
check "Q-EJECTED a row still reasoned queue-ejected settles" '[ "$(rstate 41)" = MERGED ] && [ "$(rowsof settle_merged)" = 1 ]'
# negatives (invariants c, Settle)
ejected_world; pull 41 "$H41" closed; tick
check "Q-EJECTED-NEG closed, not merged: no settle, no row" '[ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rows)" = 0 ] && [ "$(rstate 41)" = BLOCKED_HUMAN ]'
world; rowput 41 WAIT_CI 600 "$H41" "ci-pending"; pull 41 "$H41" merged; tick
check "Q-EJECTED-NEG merged but no ejection evidence: left to the conductor" '[ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rows)" = 0 ]'
ejected_world
( exec 8>"$H/locks/merge-conductor-fixt-41.lock"; flock -n 8; exec sleep 8 ) & LP=$!
wait_holder "$LP"; tick; kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
check "Q-EJECTED-NEG the conductor holds the PR lock: no claim, no settle" '[ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rows)" = 0 ]'
ejected_world; rm -f "$T/gh/repos_acme_fixt_pulls_41"; : > "$T/gh.down"; tick
check "Q-EJECTED-NEG the pulls read fails: nothing" '[ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rows)" = 0 ]'
ejected_world; rm -f "$H/flags/merge-conductor-merge"; tick
check "Q-EJECTED-NEG merges off: no settle, no row (deferred, not burned), one line, no alert" \
  '[ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rows)" = 0 ] && qlog | grep -q "merges are off or paused" && [ "$(nlines "$T/alerts.log")" = 0 ]'
touch "$H/flags/merge-conductor-merge"; tick
check "Q-EJECTED-NEG ...and the first tick with merges back on settles it" '[ "$(nlines "$T/settle.log")" = 1 ] && [ "$(rstate 41)" = MERGED ]'
# ── Q-SETTLE-RC: a settle that did not take is never recorded done ──────────
ejected_world; : > "$T/settle.noop"; tick
check "Q-SETTLE-RC the row did not move: settle_merged closes failed, one alert ($(qlog | tail -1))" \
  '[ "$(nlines "$T/settle.log")" = 1 ] && [ "$(rstate 41)" = BLOCKED_HUMAN ] && [ "$(rowf settle_merged outcome)" = failed ] && [ "$(nlines "$T/alerts.log")" = 1 ]'

# ── Q-CAP: the per-day cap is honoured ───────────────────────────────────────
cap_world() {
  ejected_world
  rowput 42 WAIT_CI 600 "$H42" "queue-ejected-twice"; pull 42 "$H42" merged
}
q_cap_one() { cap_world; setting archie.cap.queue-reconcile 1; tick
  [ "$(nlines "$T/settle.log")" = 1 ] && [ "$(rows)" = 1 ] && qlog | grep -q "cap reached (1 of 1 queue-reconcile"; }
check "Q-CAP cap=1, two candidates: exactly one settles, the other logs cap reached and writes no row" q_cap_one
cap_world; setting archie.cap.queue-reconcile 0; tick
check "Q-CAP cap=0: the playbook is off" '[ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rows)" = 0 ] && qlog | grep -q "archie.cap.queue-reconcile=0"'
cap_world; : > "$T/count.down"; tick
check "Q-CAP an unreadable count: nothing is done" '[ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rows)" = 0 ]'

# ── Q-WAITCI: stale WAIT_CI with all checks green -> one keyed conductor run ─
waitci_world() { world; rowput 43 WAIT_CI 3600 "$H43" "ci-pending"; pull 43 "$H43" open clean; greenchecks "$H43"; }
q_waitci() { waitci_world; tick; [ "$(cat "$T/kick.log" 2>/dev/null)" = "MC_ONLY_PR=acme/fixt#43" ] && [ "$(rowf kick_ci outcome)" = done ]; }
check "Q-WAITCI the conductor runs once, keyed to acme/fixt#43 ($(cat "$T/out" 2>/dev/null))" q_waitci
eq "Q-WAITCI the post-run state is evidence" "$(rowf kick_ci evidence.post_state)" WAIT_CI
tick
check "Q-WAITCI a second tick: no second run on the same head" '[ "$(nlines "$T/kick.log")" = 1 ] && [ "$(rows)" = 1 ]'
waitci_world; greenchecks "$H43" success in_progress; tick
check "Q-WAITCI-NEG one check in_progress: no run, no row" '[ "$(nlines "$T/kick.log")" = 0 ] && [ "$(rows)" = 0 ]'
waitci_world; pull 43 "$(sha 4343)" open clean; tick
check "Q-WAITCI-NEG the head differs: no run, no row" '[ "$(nlines "$T/kick.log")" = 0 ] && [ "$(rows)" = 0 ]'
world; rowput 43 WAIT_CI 600 "$H43" "ci-pending"; pull 43 "$H43" open clean; greenchecks "$H43"; tick
check "Q-WAITCI-NEG a 10 minute old row: no run, no row" '[ "$(nlines "$T/kick.log")" = 0 ] && [ "$(rows)" = 0 ]'
waitci_world; pull 43 "$H43" open dirty; tick
check "Q-WAITCI-NEG mergeable_state dirty: no run, no row" '[ "$(nlines "$T/kick.log")" = 0 ] && [ "$(rows)" = 0 ]'
waitci_world; ( exec 8>"$H/locks/merge-conductor-fixt-43.lock"; flock -n 8; exec sleep 8 ) & LP=$!
wait_holder "$LP"; tick; kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
check "Q-WAITCI-NEG the conductor is working the PR (its lock held): no run, no row" '[ "$(nlines "$T/kick.log")" = 0 ] && [ "$(rows)" = 0 ]'

# ── Q-DEP-*: a dependency hold whose dependency has landed ───────────────────
issue() { # issue <n> <state> <body> [is-pr]
  ghput "repos/acme/fixt/issues/$1" "$(jq -nc --argjson n "$1" --arg s "$2" --arg b "$3" --arg pr "${4:-}" \
    '{number: $n, state: $s, body: $b} + (if $pr == "" then {} else {pull_request: {merged_at: null}} end)')"
}
dep_sibling_world() { # #44 (Order 2 of 2) held behind sibling issue #143's PR #45, whose row is QUEUED
  world
  rowput 44 READY 3600 "$H44" "ready"; echo "depwaithold acme/fixt#44 $H44" >> "$ATT"
  pull 44 "$H44" open clean "Closes #144"
  issue 144 open $'Part of #100\nOrder: 2 of 2'
  jq -n '[{number: 143, body: "Part of #100\nOrder: 1 of 2"}, {number: 144, body: "Part of #100\nOrder: 2 of 2"}]' > "$T/issues.json"
  listpr 45 "$H45" '.head.ref = "ticket/bh-143" | .body = "Closes #143"'
  rowput 45 QUEUED 3600 "$H45" "queued"
}
dep_sibling_world; pull 45 "$H45" merged; tick
check "Q-DEP-SIBLING the stale sibling row reads MERGED ($(cat "$T/out"))" '[ "$(rstate 45)" = MERGED ] && [ "$(nlines "$T/settle.log")" = 1 ]'
check "Q-DEP-SIBLING one release_dep_hold/done row, keyed on the held PR and the sibling" \
  '[ "$(rows)" = 1 ] && [ "$(rowf release_dep_hold outcome)" = done ] && [ "$(rowf release_dep_hold dedupe_key)" = "queue-reconcile:acme/fixt#44:dephold:$H44:45:on" ]'
check "Q-DEP-SIBLING the held row itself is not touched" '[ "$(rstate 44)" = READY ]'
dep_sibling_world; pull 45 "$H45" closed; tick
check "Q-DEP-SIBLING a sibling closed unmerged: its row reads CLOSED" '[ "$(rstate 45)" = CLOSED ] && [ "$(nlines "$T/settle.log")" = 0 ] && [ "$(rowsof release_dep_hold)" = 1 ]'
dep_sibling_world; pull 45 "$H45" merged; : > "$T/settle.noop"; tick
check "Q-SETTLE-RC the sibling row did not move: release_dep_hold closes failed, one alert" \
  '[ "$(rstate 45)" = QUEUED ] && [ "$(rowf release_dep_hold outcome)" = failed ] && [ "$(nlines "$T/alerts.log")" = 1 ]'
dep_sibling_world; pull 45 "$H45" open; tick
check "Q-DEP-OPEN the sibling PR is open: no row, no write" '[ "$(rows)" = 0 ] && [ "$(rstate 45)" = QUEUED ] && [ ! -s "$T/writes.log" ]'
dep_sibling_world; tick
check "Q-DEP-OPEN an unreadable sibling: no row, no write" '[ "$(rows)" = 0 ] && [ "$(rstate 45)" = QUEUED ]'
dep_issue_world() { # #46 links issue #146, which is Blocked-by #140; #140 is open, PR #47 that closes it merged
  world
  rowput 46 READY 3600 "$H46" "ready"; echo "depwaithold acme/fixt#46 $H46" >> "$ATT"
  pull 46 "$H46" open clean "Closes #146"
  issue 146 open "Blocked-by: #140"
  issue 140 open "the parent"
  jq -n '[{number: 47, state: "closed", merged_at: "2026-10-05T05:00:00Z", body: "Closes #140", draft: false,
           head: {ref: "ticket/bh-140", sha: "x"}, base: {ref: "main"}, updated_at: "2026-10-05T05:00:00Z", title: "BH-140"}]' > "$T/closed.json"
}
dep_issue_world; tick
check "Q-DEP-ISSUE one report_dep_hold row (requested) and exactly one ALERTS line ($(cat "$T/out"))" \
  '[ "$(rows)" = 1 ] && [ "$(rowf report_dep_hold outcome)" = requested ] && [ "$(nlines "$T/alerts.log")" = 1 ]'
check "Q-DEP-ISSUE the alert names the held PR, the open issue, the merged PR and the command" \
  'grep -q "acme/fixt#46" "$T/alerts.log" && grep -q "#140" "$T/alerts.log" && grep -q "PR #47" "$T/alerts.log" && grep -q "gh issue close 140 -R acme/fixt" "$T/alerts.log"'
check "Q-DEP-ISSUE no write to the issue or the PR" '[ ! -s "$T/writes.log" ] && [ "$(rstate 46)" = READY ]'
tick
check "Q-DEP-ISSUE a second tick adds neither a row nor an alert" '[ "$(rows)" = 1 ] && [ "$(nlines "$T/alerts.log")" = 1 ]'
dep_issue_world; issue 140 open "the parent" pr; tick
check "Q-DEP-OPEN the dependency is an open PR: no row, no alert" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/alerts.log")" = 0 ]'
dep_issue_world; echo '[]' > "$T/closed.json"; tick
check "Q-DEP-OPEN an open issue with no merged closer: no row" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/alerts.log")" = 0 ]'
dep_issue_world; echo "depwaitrelease acme/fixt#46 $H46" >> "$ATT"; tick
check "Q-DEP-ISSUE a hold the gate already released is not read" '[ "$(rows)" = 0 ]'

# ── Q-ENQ-EXTERNAL: an external PR with a head-bound MERGE verdict is enqueued once
verdict() { echo "${3:-MERGE}" > "$T/verdict.$1"; echo "$2" > "$T/verdict.$1.head"; }
enq_world() { world; listpr 50 "$H50"; approve 50 "$H50"; verdict 50 "$H50"; greenchecks "$H50"; pull 50 "$H50" open clean; }
q_enq() { enq_world; tick; [ "$(cat "$T/enqueue.log" 2>/dev/null)" = "acme/fixt https://github.com/acme/fixt/pull/50 $H50" ] && [ "$(rowf enqueue outcome)" = done ]; }
check "Q-ENQ-EXTERNAL mc_enqueue_mergify once with that head, one enqueue/done row ($(cat "$T/out"))" q_enq
eq "Q-ENQ-EXTERNAL the key" "$(rowf enqueue dedupe_key)" "queue-enqueue:acme/fixt#50:$H50:on"
tick
check "Q-ENQ-EXTERNAL a second tick: zero calls" '[ "$(nlines "$T/enqueue.log")" = 1 ] && [ "$(rows)" = 1 ]'
enq_world; echo 4 > "$T/enqueue.rc"; echo "refused: lead-verdict withheld on abc: protected path" > "$T/enqueue.out"; tick
check "Q-ENQ-EXTERNAL a lead-authority refusal closes failed with its text" \
  '[ "$(rowf enqueue outcome)" = failed ] && [[ "$(rowf enqueue why)" == *"protected path"* ]]'
tick
check "Q-ENQ-EXTERNAL ...and is not retried on the same head" '[ "$(nlines "$T/enqueue.log")" = 1 ]'
enq_world; approve 50 "$(sha 1)" COMMENTED; echo MERGE > "$T/verdict.50"; tick
check "Q-ENQ-EXTERNAL a standing lead MERGE on the head is an approval" '[ "$(nlines "$T/enqueue.log")" = 1 ]'
enq_world; rowput 50 READY 3600 "$H50" "ready"; tick
check "Q-ENQ-EXTERNAL a harness row READY 60 min with no ask on the head is enqueued" '[ "$(nlines "$T/enqueue.log")" = 1 ]'

# --pr narrows a tick to one PR, as the header documents; a malformed one is a usage error.
enq_world; H51=$(sha 51); listpr 51 "$H51"; approve 51 "$H51"; verdict 51 "$H51"; greenchecks "$H51"; pull 51 "$H51" open clean
env HARNESS_TEST_SANDBOX=1 ARCHIE_FMQ_NOW="$NOW" ARCHIE_FMQ_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 \
  bash "$H/bin/archie-fm-queue.sh" tick --pr 'acme/fixt#51' > "$T/out" 2>&1; echo $? > "$T/rc"
check "Q-NARROW tick --pr acme/fixt#51 enqueues #51 and nothing else ($(cat "$T/out"))" \
  '[ "$(cat "$T/rc")" = 0 ] && [ "$(cat "$T/enqueue.log")" = "acme/fixt https://github.com/acme/fixt/pull/51 $H51" ]'
env HARNESS_TEST_SANDBOX=1 ARCHIE_FMQ_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-queue.sh" --pr 51 > "$T/out" 2>&1; echo $? > "$T/rc"
check "Q-NARROW a malformed --pr is rc 2 with the usage line" '[ "$(cat "$T/rc")" = 2 ] && grep -q "wants <owner/repo#n>" "$T/out"'

# ── Q-ENQ-NEG: ten fixtures that must NOT enqueue ────────────────────────────
enq_neg() { # enq_neg <name> <setup...>
  local name="$1"; shift
  enq_world; eval "$*"; tick
  if [ "$(nlines "$T/enqueue.log")" = 0 ] && [ "$(rows)" = 0 ]; then ok "Q-ENQ-NEG $name"
  else bad "Q-ENQ-NEG $name: enqueue=$(nlines "$T/enqueue.log") rows=$(rows) ($(qlog | tail -3))"; fi
}
enq_neg "approval on an older head" 'approve 50 "$(sha 49)"; verdict 50 "$(sha 49)"'
enq_neg "a GitHub APPROVED on the head with no harness verdict (any login can approve)" 'rm -f "$T/verdict.50" "$T/verdict.50.head"'
enq_neg "a GitHub APPROVED on the head and a verdict on an older head" 'verdict 50 "$(sha 49)"'
enq_neg "a standing verdict that is not MERGE" 'verdict 50 "$H50" REQUEST-CHANGES'
enq_neg "a required check failed" 'greenchecks "$H50" failure'
enq_neg "a required check pending" 'greenchecks "$H50" success queued'
enq_neg "mergeable_state blocked" 'pull 50 "$H50" open blocked'
enq_neg "mergeable_state dirty" 'pull 50 "$H50" open dirty'
enq_neg "already labelled merge-queue" 'listpr 50 "$H50" ".labels = [{name: \"merge-queue\"}]"'
enq_neg "provider none" 'echo none > "$T/provider"'
enq_neg "conductor row READY 5 min with a fresh ask" \
  'rowput 50 READY 300 "$H50" ready; mkdir -p "$H/state/merge-conductor/mergify-asked"; printf "%s\t@mergifyio queue\n" "$H50" > "$H/state/merge-conductor/mergify-asked/acme_fixt_50"'
enq_neg "conductor row READY 60 min but asked on this head" \
  'rowput 50 READY 3600 "$H50" ready; mkdir -p "$H/state/merge-conductor/mergify-asked"; printf "%s\t@mergifyio queue\n" "$H50" > "$H/state/merge-conductor/mergify-asked/acme_fixt_50"'
enq_neg "a standing BLOCK on the head" 'verdict 50 "$H50" BLOCK'
enq_neg "a draft" 'listpr 50 "$H50" ".draft = true"'
enq_neg "flags/merge-conductor-merge absent" 'rm -f "$H/flags/merge-conductor-merge"'
enq_neg "a mergify/merge-queue draft" 'listpr 50 "$H50" ".draft = true | .head.ref = \"mergify/merge-queue/main/abc\""'
enq_neg "the tier-2 ledger already enqueued this head" \
  'printf "https://github.com/acme/fixt/pull/50 %s enqueued 2026-10-05T07:00:00Z\n" "$H50" > "$H/state/tier2-autoenqueue.txt"'
enq_neg "Mergify already witnesses it" ': > "$T/witness.50"'
enq_neg "a later CHANGES_REQUESTED from the approver" \
  'ghput "repos/acme/fixt/pulls/50/reviews?per_page=100" "$(jq -nc --arg c "$H50" "[{id:1,user:{login:\"operator\"},state:\"APPROVED\",commit_id:\$c},{id:2,user:{login:\"operator\"},state:\"CHANGES_REQUESTED\",commit_id:\$c}]")"'
enq_neg "the verdict read is down" ': > "$T/vd.down"'
enq_neg "a HOLD" ': > "$T/held"'
enq_neg "the head moved since the list" 'pull 50 "$(sha 5050)" open clean'
enq_neg "a harness PR the conductor has not classified yet (no row)" 'listpr 50 "$H50" ".head.ref = \"ticket/bh-50\""'

# ── Q-ENQ-GATE: the conductor READY arm's own gates, each failing closed ─────
enq_neg "a human BLOCK on the thread (bg_scan)" ': > "$T/bgblock.50"'
enq_neg "the block gate cannot read the thread" ': > "$T/bg.down"'
enq_neg "a lead PR waiting on its lead (the lead fence holds)" ': > "$T/lead.50"'
enq_neg "the lead fence cannot be read" ': > "$T/lead.down"'
enq_neg "a cleared lead PR (a Mergify label cannot pin it, BH-1606)" ': > "$T/leadcleared.50"'
enq_neg "the PR-dependency gate holds (its declared dependency is an open PR)" \
  'pull 50 "$H50" open clean "Depends on #60"; ghput "repos/acme/fixt/issues/60" "{\"number\": 60, \"state\": \"open\", \"body\": \"\", \"pull_request\": {\"merged_at\": null}}"'
enq_neg "the PR-dependency gate cannot read its dependency" 'pull 50 "$H50" open clean "Depends on #61"'
readywhy() { # readywhy <n> <head> <kind> — the conductor's ready-why note, as mc_ready_why writes it
  mkdir -p "$H/state/merge-conductor/ready-why"
  printf '%s\t%s\t%s\t%s\n' "$NOW" "$2" "$3" "held" > "$H/state/merge-conductor/ready-why/acme_fixt_$1"
}
for k in dep-hold ticket-hold prequeue-pending lead-held lead-unread; do
  enq_neg "a READY row the conductor holds on this head ($k)" "rowput 50 READY 3600 \"\$H50\" ready; readywhy 50 \"\$H50\" $k"
done
enq_world; rowput 50 READY 3600 "$H50" "ready"; readywhy 50 "$H50" merges-off; tick
check "Q-ENQ-GATE a READY row whose only note is merges-off (merges are on now) is enqueued" '[ "$(nlines "$T/enqueue.log")" = 1 ]'
enq_world; rowput 50 READY 3600 "$H50" "ready"; readywhy 50 "$(sha 49)" dep-hold; tick
check "Q-ENQ-GATE a hold note on an older head does not hold this head" '[ "$(nlines "$T/enqueue.log")" = 1 ]'
check "Q-ENQ-GATE the HOLD read is to_lane_hold, the conductor's fail-closed one" 'grep -q "^tolanehold 50$" "$T/ghrest.log"'
check "Q-ENQ-GATE no mc_hold_keeps_pr (it fails open) in the enqueue gate" '! grep -n "mc_hold_keeps_pr" "$DIR/bin/lib/archie-fm-queue/enqueue.sh"'
# The refute repro: #44 is Order 2 of 2 behind sibling #45, whose PR is OPEN and
# QUEUED. #44 is approved, green, clean and READY 60 min with no ask, and the
# conductor's dep-hold note is NOT on disk: the live dependency gate holds it.
dep_sibling_world; pull 45 "$H45" open; approve 44 "$H44"; verdict 44 "$H44"; greenchecks "$H44"; listpr 44 "$H44" '.head.ref = "ticket/bh-144"'; tick
check "Q-ENQ-GATE a READY row held by the dependency gate behind an open sibling is NOT enqueued ($(qlog | tail -2 | tr '\n' ' '))" \
  '[ "$(nlines "$T/enqueue.log")" = 0 ] && [ "$(rowsof enqueue)" = 0 ] && [ "$(rstate 45)" = QUEUED ]'
for f in to_lane_hold pdg_hold to_lane_lead_fence bg_scan; do
  enq_world; printf 'unset -f %s\n' "$f" >> "$T/fx.sh"; tick; sed -i '$d' "$T/fx.sh"
  check "Q-ENQ-GATE $f not loaded: no enqueue, one line" '[ "$(nlines "$T/enqueue.log")" = 0 ] && [ "$(rows)" = 0 ] && qlog | grep -q "$f is not loaded"'
done

# ── Q-BATCH-*: a failed Mergify batch, members solo-run on the CI pool ──────
batch_world() { # batch_world [n-members] — draft #9100 failed on a run naming tests/foo-test.sh
  local n=${1:-5} i members=""
  world
  for i in $(seq 1 "$n"); do members="$members${members:+ + }#$((9100 + i))"; pull $((9100 + i)) "$(sha $((9100 + i)))" open clean; done
  jq -n --arg t "merge queue: checking $members together on main (abc1234)" --arg h "$(sha 9100)" \
    '[{number: 9100, state: "closed", merged_at: null, draft: true, title: $t, updated_at: "2026-10-05T07:00:00Z",
       head: {ref: "mergify/merge-queue/main/abc", sha: $h}, base: {ref: "main"}}]' > "$T/closed.json"
  ghput "repos/acme/fixt/actions/runs?head_sha=$(sha 9100)&per_page=100" \
    '{"total_count": 1, "workflow_runs": [{"id": 777, "head_branch": "mergify/merge-queue/main/abc", "conclusion": "failure"}]}'
  printf 'P\ttests/foo-test.sh\n' > "$T/runlog.777"
  ghput "repos/acme/fixt/commits/main" "{\"sha\": \"$MAIN\"}"
}
FP=$(printf 'tests/foo-test.sh\n' | sha1sum | cut -c1-12)
cache() { # cache <member> <line> — the shared pq_key store
  local d="$H/state/merge-conductor/prequeue"
  mkdir -p "$d"; printf '%s\n' "$2" > "$d/acme_fixt_$1_$(sha "$1")_${MAIN}_$FP"
}
batch_world; tick
eq "Q-BATCH-READ five members dispatched, each alone onto current main with the batch's suite ($(cat "$T/out"))" \
  "$(cat "$T/dispatch.log" 2>/dev/null)" "$(for i in 1 2 3 4 5; do printf '%s %s %s tests/foo-test.sh\n' $((9100 + i)) "$(sha $((9100 + i)))" "$MAIN"; done)"
eq "Q-BATCH-READ one solo_run row per member, on the queue-solo playbook" \
  "$(jq '[.actions[] | select(.action == "solo_run" and .playbook == "queue-solo" and .outcome == "done")] | length' "$T/db.json")" 5
check "Q-BATCH-READ no verdict while the solo runs are pending" '[ ! -s "$T/verdicts.log" ]'
: > "$T/dispatch.log"; tick
check "Q-SOLO-DEDUP a second tick reads the pending runs and dispatches nothing" \
  '[ "$(nlines "$T/dispatch.log")" = 0 ] && [ "$(grep -c "^readrun" "$T/ghrest.log")" = 5 ]'
batch_world; for i in 1 2 3 4 5; do cache $((9100 + i)) "green 1791180000 555 tests/foo-test.sh"; done; tick
check "Q-SOLO-DEDUP a cached green verdict: zero dispatches, zero verdicts" '[ "$(nlines "$T/dispatch.log")" = 0 ] && [ ! -s "$T/verdicts.log" ] && [ "$(rows)" = 0 ]'
check "Q-SOLO-DEDUP ...and the innocents are counted" 'qlog | grep -q "innocent=5"'
batch_world; printf 'J\tjob:build\n' > "$T/runlog.777"; tick
check "Q-BATCH-READ a run that names only job: lines: no dispatch, suites unknown" \
  '[ "$(nlines "$T/dispatch.log")" = 0 ] && qlog | grep -q "suites unknown"'
batch_world; rm -f "$T/runlog.777"; tick
check "Q-BATCH-READ an unreadable log: no dispatch" '[ "$(nlines "$T/dispatch.log")" = 0 ] && qlog | grep -q "suites unknown"'
batch_world; : > "$T/nopool"; tick
check "Q-BATCH-READ without #4548's runner on the box: no dispatch, one line saying so" \
  '[ "$(nlines "$T/dispatch.log")" = 0 ] && [ "$(qlog | grep -c "solo runner")" = 1 ]'

# ── Q-FP: #4548's pq_dispatch alone (no fp) never dispatches a suite-scoped run
batch_world; : > "$T/no4550"; : > "$T/dispatch.nofp"; tick
check "Q-FP #4548's runner without #4550's (pq_dispatch drops the fp): no dispatch, no plain-key entry, one line" \
  '[ "$(nlines "$T/dispatch.log")" = 0 ] && [ "$(qlog | grep -c "fp-keyed CI-pool solo runner")" = 1 ] && ! ls "$H/state/merge-conductor/prequeue/" 2>/dev/null | grep -q "_${MAIN}$"'
batch_world; : > "$T/no4550"; tick PQ_DISPATCH_FP=1
check "Q-FP PQ_DISPATCH_FP=1 is the other way to say the runner honours the fp" '[ "$(nlines "$T/dispatch.log")" = 5 ]'
batch_world; : > "$T/dispatch.nofp"; tick
check "Q-FP a pq_dispatch that ignores its fp anyway: ONE dispatch, closed failed, one alert, no more dispatches ($(qlog | tail -1))" \
  '[ "$(nlines "$T/dispatch.log")" = 1 ] && [ "$(rowf solo_run outcome)" = failed ] && [ "$(nlines "$T/alerts.log")" = 1 ] && grep -q "plain pre-queue" "$T/alerts.log" && [ ! -s "$T/verdicts.log" ]'

batch5_world() { # #9103 reproduces alone on main, the other four are clean
  batch_world
  for i in 1 2 4 5; do cache $((9100 + i)) "green 1791180000 55$i tests/foo-test.sh"; done
  cache 9103 "red 1791180000 553 tests/foo-test.sh"
}
q_batch5() { batch5_world; tick
  [ "$(cat "$T/verdicts.log" 2>/dev/null | cut -d' ' -f1-5)" = "post acme/fixt 9103 $(sha 9103) BLOCK" ] \
    && [ -f "$T/comments/9103" ] && [ "$(ls "$T/comments" | tr '\n' ' ')" = "9103 " ] \
    && [ "$(rowsof block_verdict)" = 1 ] && [ "$(rowf block_verdict outcome)" = done ]; }
check "Q-BATCH-5 exactly one BLOCK, on #9103's head, one comment, one block_verdict/done row ($(cat "$T/out"))" q_batch5
check "Q-BATCH-5 zero verdict, comment, label or dequeue calls on 9101 9102 9104 9105" \
  '! grep -qE "910[1245]" "$T/verdicts.log" "$T/writes.log" && [ "$(nlines "$T/enqueue.log")" = 0 ] && [ "$(nlines "$T/dispatch.log")" = 0 ]'
check "Q-BATCH-5 the verdict is lead-sourced and its note names the suite and main" \
  'grep -q -- "--source lead" "$T/verdicts.log" && grep -q "reproduces tests/foo-test.sh when merged alone onto main ${MAIN:0:12} (batch #9100)" "$T/verdicts.log"'
eq "Q-BATCH-5 the comment, verbatim" "$(cat "$T/comments/9103")" \
"This PR fails \`tests/foo-test.sh\` when it is merged alone onto main at ${MAIN:0:12}. That suite failed merge queue batch #9100, and the other members pass it on their own, so I've blocked this head with a lead verdict and left the rest of the batch alone.

Solo run: https://github.com/acme/fixt/actions/runs/553

Push a fix and the new head goes back through review. (archie-fm-queue)"
check "Q-BATCH-5 the four innocents are counted, not touched" 'qlog | grep -q "blocked=1 innocent=4"'
tick
check "Q-BATCH-5 a second tick adds nothing" '[ "$(nlines "$T/verdicts.log")" = 1 ] && [ "$(ls "$T/comments" | wc -l)" = 1 ] && [ "$(rows)" = 1 ]'
batch_world; for i in 1 2 4 5; do cache $((9100 + i)) "green 1791180000 55$i tests/foo-test.sh"; done
cache 9103 "pending $NOW - "; printf 'red 553 tests/foo-test.sh\n' > "$T/run.9103"; tick
check "Q-BATCH-5 a pending run read red this tick blocks the same way" '[ "$(nlines "$T/verdicts.log")" = 1 ] && grep -q "^red " "$H/state/merge-conductor/prequeue/acme_fixt_9103_"*'
batch5_world; echo 1 > "$T/lv.rc"; tick
check "Q-BATCH-5 a refused verdict (403): failed, no comment, one alert" \
  '[ "$(rowf block_verdict outcome)" = failed ] && [ ! -e "$T/comments/9103" ] && [ "$(nlines "$T/alerts.log")" = 1 ]'
batch5_world; echo 3 > "$T/lv.rc"; tick
check "Q-BATCH-5 a moved head: failed, no comment, no alert" \
  '[ "$(rowf block_verdict outcome)" = failed ] && [ ! -e "$T/comments/9103" ] && [ "$(nlines "$T/alerts.log")" = 0 ]'
batch5_world; : > "$T/comment.refuse"; tick
check "Q-BATCH-5 a comment that fails after the verdict: done, comment failed in evidence, not re-posted" \
  '[ "$(rowf block_verdict outcome)" = done ] && [ "$(rowf block_verdict evidence.comment)" = failed ]'

# ── Q-MAIN-MOVES: main moves between ticks; the batch stays pinned to its main ─
MAIN2=$(printf 'a%039x' 888888)   # a distinct 12-hex prefix: the verdict note names main by its first 12
batch_world; tick
ghput "repos/acme/fixt/commits/main" "{\"sha\": \"$MAIN2\"}"
for i in 1 2 4 5; do printf 'green 55%s tests/foo-test.sh\n' "$i" > "$T/run.$((9100 + i))"; done
printf 'red 553 tests/foo-test.sh\n' > "$T/run.9103"
: > "$T/dispatch.log"; tick
check "Q-MAIN-MOVES main moved after the dispatch: zero new dispatches, zero new solo_run rows ($(qlog | tail -2 | tr '\n' ' '))" \
  '[ "$(nlines "$T/dispatch.log")" = 0 ] && [ "$(rowsof solo_run)" = 5 ]'
check "Q-MAIN-MOVES ...and exactly one BLOCK, on #9103, against the main the runs used" \
  '[ "$(nlines "$T/verdicts.log")" = 1 ] && grep -q "^post acme/fixt 9103 " "$T/verdicts.log" && grep -q "main ${MAIN:0:12} (batch #9100)" "$T/verdicts.log" && ! grep -q "${MAIN2:0:12}" "$T/verdicts.log"'
batch_world; for i in 1 2 4 5; do cache $((9100 + i)) "green 1791180000 55$i tests/foo-test.sh"; done
ghput "repos/acme/fixt/commits/main" "{\"sha\": \"$MAIN2\"}"; pull 9103 "$(sha 19103)" open clean; tick
check "Q-MAIN-MOVES a member whose head moved is dispatched onto the batch's main, not the new tip" \
  '[ "$(cat "$T/dispatch.log")" = "9103 $(sha 19103) $MAIN tests/foo-test.sh" ]'
batch_world; cache 9103 "green 1700000000 553 tests/foo-test.sh"; ghput "repos/acme/fixt/commits/main" "{\"sha\": \"$MAIN2\"}"; tick
check "Q-MAIN-MOVES an entry older than the batch window does not pin main: the current tip is used" \
  '[ "$(nlines "$T/dispatch.log")" = 5 ] && [ "$(grep -c " $MAIN2 " "$T/dispatch.log")" = 5 ]'

# ── Q-MERGED-WITNESS: a member Mergify already merged counts as green ────────
batch_world; for i in 1 2 4 5; do pull $((9100 + i)) "$(sha $((9100 + i)))" merged; done
cache 9103 "red 1791180000 553 tests/foo-test.sh"; ghput "repos/acme/fixt/commits/main" "{\"sha\": \"$MAIN2\"}"; tick
check "Q-MERGED-WITNESS four merged innocents, one red open member: one BLOCK on #9103, zero dispatches ($(qlog | tail -2 | tr '\n' ' '))" \
  '[ "$(nlines "$T/verdicts.log")" = 1 ] && grep -q "^post acme/fixt 9103 " "$T/verdicts.log" && [ "$(nlines "$T/dispatch.log")" = 0 ] && [ "$(ls "$T/comments" | tr "\n" " ")" = "9103 " ]'
check "Q-MERGED-WITNESS nothing is written on the merged members" '! grep -qE "910[1245]" "$T/verdicts.log" "$T/writes.log"'
batch_world; for i in 1 2 4 5; do pull $((9100 + i)) "$(sha $((9100 + i)))" closed; done
cache 9103 "red 1791180000 553 tests/foo-test.sh"; tick
check "Q-MERGED-WITNESS a member closed unmerged is no witness: no BLOCK" '[ ! -s "$T/verdicts.log" ]'

# ── Q-CULPRIT-NEG: adversarial negatives for the BLOCK ───────────────────────
cneg() { # cneg <name> <setup>
  local name="$1"; shift
  batch5_world; eval "$*"; tick
  if [ ! -s "$T/verdicts.log" ] && [ ! -d "$T/comments" ] && [ "$(rowsof block_verdict)" = 0 ]; then ok "Q-CULPRIT-NEG $name"
  else bad "Q-CULPRIT-NEG $name: verdicts=$(nlines "$T/verdicts.log") ($(qlog | tail -3))"; fi
}
cneg "every member red (main is the likely cause)" 'for i in 1 2 3 4 5; do cache $((9100 + i)) "red 1791180000 55$i tests/foo-test.sh"; done'
cneg "the red member could-not-run" 'cache 9103 "could-not-run 1791180000 dispatch-refused"'
cneg "the red member conflicts" 'cache 9103 "conflict 1791180000 553"'
cneg "another member still pending" 'cache 9101 "pending $NOW -"'
cneg "the red member's head moved since (a new solo run is needed)" 'pull 9103 "$(sha 19103)" open clean'
cneg "the run was cancelled, not failed" \
  'ghput "repos/acme/fixt/actions/runs?head_sha=$(sha 9100)&per_page=100" "{\"total_count\": 1, \"workflow_runs\": [{\"id\": 777, \"conclusion\": \"cancelled\"}]}"'
cneg "the batch merged" 'jq ".[0].merged_at = \"2026-10-05T07:00:00Z\"" "$T/closed.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/closed.json"'
cneg "the provider is not mergify" 'echo none > "$T/provider"'
batch_world 1; cache 9101 "red 1791180000 551 tests/foo-test.sh"; tick
check "Q-BATCH-ONE a batch of one, main green: one BLOCK on #9101, the only-member comment ($(qlog | tail -2 | tr '\n' ' '))" \
  '[ "$(nlines "$T/verdicts.log")" = 1 ] && grep -q "^post acme/fixt 9101 " "$T/verdicts.log" && grep -q "where it was the only member" "$T/comments/9101"'
batch_world 1; cache 9101 "red 1791180000 551 tests/foo-test.sh"; touch "$H/flags/main-red-fixt"; tick
if [ ! -s "$T/verdicts.log" ] && [ ! -d "$T/comments" ] && [ "$(rowsof block_verdict)" = 0 ] && qlog | grep -q "main is red (main-red-fixt)"; then
  ok "Q-CULPRIT-NEG batch of one, main red: no verdict, no comment, one line"
else bad "Q-CULPRIT-NEG batch of one, main red: verdicts=$(nlines "$T/verdicts.log") ($(qlog | tail -3))"; fi
batch_world 1; cache 9101 "red 1791180000 551 tests/foo-test.sh"; printf 'unset -f main_red_flag\n' >> "$T/fx.sh"; tick; sed -i '$d' "$T/fx.sh"
check "Q-CULPRIT-NEG batch of one, freeze reader not loaded: no verdict (fail closed)" \
  '[ ! -s "$T/verdicts.log" ] && [ ! -d "$T/comments" ] && qlog | grep -q "freeze reader not loaded"'
batch_world; for i in 1 2 4 5; do pull $((9100 + i)) "$(sha $((9100 + i)))" merged; done
cache 9103 "red 1791180000 553 tests/foo-test.sh"; tick
check "Q-MERGED-WITNESS the comment names the merged witness, not a solo pass" \
  'grep -q "another member of that batch has merged since" "$T/comments/9103" && ! grep -q "pass it on their own" "$T/comments/9103"'
batch_world 14; tick
check "Q-CULPRIT-NEG a batch of 14: no dispatch, one line" '[ "$(nlines "$T/dispatch.log")" = 0 ] && [ "$(qlog | grep -c "14 members")" = 1 ]'

# ── Q-OBSERVE: every playbook in observe writes would_* rows and nothing else ─
world; setting archie.manage observe
rowput 41 BLOCKED_HUMAN 7200 "$H41" "br-ladder-rebuild"; echo "ejected acme/fixt#41 $H41" >> "$ATT"; pull 41 "$H41" merged
rowput 43 WAIT_CI 3600 "$H43" "ci-pending"; pull 43 "$H43" open clean; greenchecks "$H43"
listpr 50 "$H50"; approve 50 "$H50"; verdict 50 "$H50"; greenchecks "$H50"; pull 50 "$H50" open clean
for i in 1 2 3 4 5; do pull $((9100 + i)) "$(sha $((9100 + i)))" open clean; done
jq -n --arg h "$(sha 9100)" '[{number: 9100, state: "closed", merged_at: null, draft: true, updated_at: "2026-10-05T07:00:00Z",
  title: "merge queue: checking #9101 + #9102 + #9103 + #9104 + #9105 together on main (abc1234)",
  head: {ref: "mergify/merge-queue/main/abc", sha: $h}, base: {ref: "main"}}]' > "$T/closed.json"
ghput "repos/acme/fixt/actions/runs?head_sha=$(sha 9100)&per_page=100" '{"total_count": 1, "workflow_runs": [{"id": 777, "conclusion": "failure"}]}'
printf 'P\ttests/foo-test.sh\n' > "$T/runlog.777"; ghput "repos/acme/fixt/commits/main" "{\"sha\": \"$MAIN\"}"
for i in 1 2 4 5; do cache $((9100 + i)) "green 1791180000 55$i tests/foo-test.sh"; done; cache 9103 "red 1791180000 553 tests/foo-test.sh"
tick
eq "Q-OBSERVE one would row per playbook action" \
  "$(jq -r '[.actions[] | "\(.mode)/\(.action)/\(.outcome)"] | sort | join(" ")' "$T/db.json")" \
  "observe/would_block_verdict/would observe/would_enqueue/would observe/would_kick_ci/would observe/would_settle_merged/would"
check "Q-OBSERVE zero writes: no settle, kick, enqueue, verdict, comment or dispatch" \
  '[ ! -s "$T/writes.log" ] && [ ! -s "$T/kick.log" ] && [ ! -s "$T/verdicts.log" ] && [ "$(rstate 41)" = BLOCKED_HUMAN ]'
batch_world; setting archie.manage observe; tick
check "Q-OBSERVE an undispatched member is a would_solo_run row, no dispatch" \
  '[ "$(rowsof would_solo_run)" = 5 ] && [ "$(nlines "$T/dispatch.log")" = 0 ]'

# ── Q-OFF, Q-LOCK ────────────────────────────────────────────────────────────
ejected_world; setting archie.manage off; tick
check "Q-OFF archie.manage=off: zero GitHub reads, zero rows" '[ ! -s "$T/ghrest.log" ] && [ "$(rows)" = 0 ] && [ "$(cat "$T/rc")" = 0 ]'
ejected_world; setting archie.manage.fixt off; tick
check "Q-OFF archie.manage.fixt=off: the same" '[ ! -s "$T/ghrest.log" ] && [ "$(rows)" = 0 ]'
ejected_world; tick ARCHIE_FMQ_ENABLED=0
check "Q-OFF ARCHIE_FMQ_ENABLED=0: nothing read" '[ ! -s "$T/ghrest.log" ] && [ ! -s "$T/reqlog" ] && [ "$(cat "$T/rc")" = 0 ]'
ejected_world; : > "$T/settings.down"; tick
check "Q-OFF settings unreadable: the project is skipped, nothing read" '[ ! -s "$T/ghrest.log" ] && [ "$(rows)" = 0 ] && qlog | grep -q "could not be read"'
ejected_world; ( exec 9>"$H/locks/archie-fm-queue.lock"; flock -n 9; exec sleep 8 ) & LP=$!
wait_holder "$LP"; tick; kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
check "Q-LOCK the lane lock held: exit 0, no reads" '[ "$(cat "$T/rc")" = 0 ] && [ ! -s "$T/ghrest.log" ] && [ ! -s "$T/reqlog" ]'

# ── Q-CLAIM, Q-STALE ─────────────────────────────────────────────────────────
seedrow() { # seedrow <key> <outcome> <updated_at>
  jq --arg k "$1" --arg o "$2" --arg u "$3" '.actions += [{id: 1, dedupe_key: $k, day: "2026-10-05", project: "fixt",
     repo: "acme/fixt", pr: 50, playbook: "queue-enqueue", mode: "on", action: "enqueue", outcome: $o, why: "x",
     evidence: {}, attempts: 1, actor: "archie-fm-queue", created_at: $u, updated_at: $u}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
enq_world; seedrow "queue-enqueue:acme/fixt#50:$H50:on" done 2026-10-05T07:00:00Z; tick
check "Q-CLAIM a claim on an existing key is not ours: no write" \
  '[ "$(nlines "$T/enqueue.log")" = 0 ] && [ "$(rows)" = 1 ] && [ "$(grep -c "^POST /api/archie/actions " "$T/reqlog")" = 1 ]'
enq_world; seedrow "queue-enqueue:acme/fixt#50:$H50:on" started 2026-10-05T05:15:00Z; tick
check "Q-STALE a 2 h old started row: closed failed, one ALERTS line, no action" \
  '[ "$(rowf enqueue outcome)" = failed ] && [ "$(nlines "$T/alerts.log")" = 1 ] && [ "$(nlines "$T/enqueue.log")" = 0 ]'
tick
check "Q-STALE ...and it is never reclaimed or re-alerted" '[ "$(nlines "$T/alerts.log")" = 1 ] && [ "$(nlines "$T/enqueue.log")" = 0 ]'
enq_world; seedrow "queue-enqueue:acme/fixt#50:$H50:on" started 2026-10-05T07:10:00Z; tick
check "Q-STALE a fresh started row is left alone" '[ "$(rowf enqueue outcome)" = started ] && [ "$(nlines "$T/alerts.log")" = 0 ]'
# The key is never claimed again (the head moved on): the per-tick sweep closes it.
world; seedrow "queue-enqueue:acme/fixt#50:$(sha 49):on" started 2026-10-05T05:15:00Z; tick
check "Q-STALE a 2 h old started row whose key is never claimed again: the sweep closes it failed, one ALERTS line" \
  '[ "$(rowf enqueue outcome)" = failed ] && [ "$(nlines "$T/alerts.log")" = 1 ] && grep -q "left started" "$T/alerts.log"'
tick
check "Q-STALE ...a second tick does not re-alert" '[ "$(nlines "$T/alerts.log")" = 1 ]'
world; seedrow "queue-enqueue:acme/fixt#50:$(sha 49):on" started 2026-10-05T07:10:00Z; tick
check "Q-STALE the sweep leaves a fresh started row alone" '[ "$(rowf enqueue outcome)" = started ] && [ "$(nlines "$T/alerts.log")" = 0 ]'
world; seedrow "queue-enqueue:acme/fixt#50:$(sha 49):on" started 2026-10-04T23:00:00Z
jq '.actions[0].day = "2026-10-04"' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; tick
check "Q-STALE the sweep reads yesterday's rows too" '[ "$(rowf enqueue outcome)" = failed ] && [ "$(nlines "$T/alerts.log")" = 1 ]'

# ── the cron line, the registry, scope ───────────────────────────────────────
check "cron: one hub-lease-gated */10 line for bin/archie-fm-queue.sh" \
  '[ "$(grep -c "^\*/10 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/archie-fm-queue.sh >/dev/null 2>&1$" "$DIR/cron/lanes/726-archie-fm-queue.cron")" = 1 ]'
check "registry: hub lane, flag switch, seams not settable" \
  'jq -e ".scope == \"hub\" and .script == \"bin/archie-fm-queue.sh\" and .switch.name == \"lane-off-archie-fm-queue\" and ([.knobs[] | select(.env == \"ARCHIE_FMQ_FIXTURE\" or .env == \"ARCHIE_FMQ_NOW\") | .settable] == [false, false])" "$DIR/catalog/lanes.d/archie-fm-queue.json" >/dev/null'
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1 && git -C "$DIR" merge-base origin/main HEAD >/dev/null 2>&1; then
  # Scoped to THIS ticket's commits, not the whole origin/main...HEAD diff: in a
  # Mergify batch HEAD also carries the siblings, and a sibling that edits
  # .mergify.yml (#5049, BH-4979, in batch #5113) is not this PR touching it.
  # A commit is this ticket's when its subject names BH-4584 or it touches one
  # of the paths this ticket ships; there must be at least one.
  q_scope_commits() {
    { git -C "$DIR" log --no-merges -i --format=%H --grep='bh-4584' origin/main..HEAD
      git -C "$DIR" log --no-merges --format=%H origin/main..HEAD -- bin/archie-fm-queue.sh \
        bin/lib/archie-fm-queue catalog/lanes.d/archie-fm-queue.json cron/lanes/726-archie-fm-queue.cron \
        tests/archie-fm-queue.bh-4584-test.sh worker/jobs/src/routes/archie-actions.js; } | sort -u
  }
  q_scope() {
    local c hit=0
    for c in $(q_scope_commits); do
      [ "$(git -C "$DIR" diff-tree --no-commit-id --name-only -r "$c" | grep -cE "^(\.mergify\.yml|config/mergify/)")" = 0 ] || hit=$((hit+1))
    done
    [ "$hit" = 0 ]
  }
  # TEST-CHANGE (fix-main-red): the "at least one BH-4584 commit" half held only
  # while BH-4584's own PR was open. Once #4675 merged, origin/main..HEAD carries
  # no BH-4584 commit on main or in any later batch, so the check failed
  # everywhere. With none in range there is nothing to scope: say so and pass.
  if [ -n "$(q_scope_commits)" ]; then
    check "Q-SCOPE no BH-4584 commit touches .mergify.yml or config/mergify" q_scope
  else
    echo "note: Q-SCOPE skipped (no BH-4584 commits in origin/main..HEAD; the ticket has merged)"
  fi
else
  echo "note: Q-SCOPE skipped (no origin/main merge base in this checkout)"
fi
check "Q-STATIC no new file merges, pushes or force-holds" \
  '! grep -nE "gh pr merge|git push|hold_push" "$DIR/bin/archie-fm-queue.sh" "$DIR"/bin/lib/archie-fm-queue/*.sh'
check "Q-STATIC no /root/harness default in the libs (D43)" '! grep -n "/root/harness" "$DIR"/bin/lib/archie-fm-queue/*.sh'

# ═════ X: mutations, each must turn its case red ═════════════════════════════
mutate() { # mutate <lib-relative-path> <python-expr over s>
  local rel="$1" lib="$H/$1"
  rm -f "$lib"
  python3 -c "import sys; s=open(sys.argv[1]).read(); $2; open(sys.argv[2],'w').write(s)" "$DIR/$rel" "$lib"
  cmp -s "$lib" "$DIR/$rel" && { echo "mutation did not change $rel"; return 1; }
  return 0
}
restore() { rm -f "$H/$1"; ln -s "$DIR/$1" "$H/$1"; }
if command -v python3 >/dev/null 2>&1; then
  R=bin/lib/archie-fm-queue/reconcile.sh
  if mutate "$R" 's=s.replace("[ \"$AFQ_PR_STATE\" = closed ] && [ -n \"$AFQ_PR_MERGED_AT\" ]", "[ \"$AFQ_PR_STATE\" = closed ]")'; then
    ejected_world; pull 41 "$H41" closed; tick
    if [ "$(nlines "$T/settle.log")" = 0 ]; then bad "X1 dropping the merged check must settle a closed PR"; else ok "X1 RED: without the merged check a closed PR is settled MERGED"; fi
  else bad "X1 mutation not applied"; fi
  restore "$R"
  C=bin/lib/archie-fm-queue/common.sh
  if mutate "$C" 's=s.replace("if [ \"$used\" -ge \"$((10#$cap))\" ]; then", "if false; then")'; then
    if q_cap_one; then bad "X2 bypassing the cap must break Q-CAP"; else ok "X2 RED: bypassing the cap breaks Q-CAP"; fi
  else bad "X2 mutation not applied"; fi
  restore "$C"
  U=bin/lib/archie-fm-queue/culprit.sh
  if mutate "$U" 's=s.replace("green) AFQ_WORD=green ;;", "green) AFQ_WORD=red ;;")'; then
    if q_batch5; then bad "X3 reading green as red must break Q-BATCH-5"; else ok "X3 RED: reading green as red breaks Q-BATCH-5"; fi
  else bad "X3 mutation not applied"; fi
  restore "$U"
  E=bin/lib/archie-fm-queue/enqueue.sh
  if mutate "$E" 's=s.replace("    1) return 1 ;;\n    *) return 2 ;;", "    1) ;;\n    *) return 2 ;;", 1)'; then
    enq_world; rm -f "$T/verdict.50" "$T/verdict.50.head"; tick
    if [ "$(nlines "$T/enqueue.log")" = 0 ]; then bad "X4 dropping the verdict requirement must enqueue a GitHub-only approval"; else ok "X4 RED: without the verdict requirement a GitHub-only approval is enqueued"; fi
  else bad "X4 mutation not applied"; fi
  restore "$E"
  B=bin/archie-fm-queue.sh
  if mutate "$B" 's=s.replace("  afq_reconcile \"$P\" \"$SLUG\" \"$MODE\"\n", "")'; then
    if q_ejected; then bad "X5 deleting the reconcile call site must break Q-EJECTED"; else ok "X5 RED: deleting the reconcile call site breaks Q-EJECTED"; fi
  else bad "X5 mutation not applied"; fi
  restore "$B"
  if mutate "$B" 's=s.replace("    afq_enqueue \"$P\" \"$SLUG\" \"$MODE\" \"$LIST\"\n", "")'; then
    if q_enq; then bad "X6 deleting the enqueue call site must break Q-ENQ-EXTERNAL"; else ok "X6 RED: deleting the enqueue call site breaks Q-ENQ-EXTERNAL"; fi
  else bad "X6 mutation not applied"; fi
  restore "$B"
  if mutate "$U" 's=s.replace("if [ -n \"$wit\" ]; then", "if true; then")'; then
    batch5_world; for i in 1 2 3 4 5; do cache $((9100 + i)) "red 1791180000 55$i tests/foo-test.sh"; done; tick
    if [ ! -s "$T/verdicts.log" ]; then bad "X7 dropping the clean witness must block an all-red batch"; else ok "X7 RED: without the clean witness every member of an all-red batch is blocked"; fi
  else bad "X7 mutation not applied"; fi
  restore "$U"
  if mutate "$E" 's=s.replace("  if ! afq_conductor_gates ", "  if false && ! afq_conductor_gates ", 1)'; then
    dep_sibling_world; pull 45 "$H45" open; approve 44 "$H44"; verdict 44 "$H44"; greenchecks "$H44"; listpr 44 "$H44" '.head.ref = "ticket/bh-144"'; tick
    if [ "$(nlines "$T/enqueue.log")" = 0 ]; then bad "X8 skipping the conductor gates must enqueue the dependency-held READY row ($(qlog | tail -4 | tr "\n" " "))"; else ok "X8 RED: without the conductor gates a dependency-held READY row is enqueued"; fi
  else bad "X8 mutation not applied"; fi
  restore "$E"
  if mutate "$U" 's=s.replace("if [ \"$drc\" = 0 ] && [ -z \"$(pq_cache_get \"$path\")\" ]; then", "if false; then", 1)'; then
    batch_world; : > "$T/dispatch.nofp"; tick
    if [ "$(nlines "$T/dispatch.log")" = 1 ]; then bad "X9 dropping the fp-key check must let every member dispatch"; else ok "X9 RED: without the fp-key check every member is dispatched onto the plain key"; fi
  else bad "X9 mutation not applied"; fi
  restore "$U"
  R2=bin/lib/archie-fm-queue/reconcile.sh
  if mutate "$R2" 's=s.replace("  if ! afq_row_now \"$key\" MERGED; then", "  if false; then", 1)'; then
    ejected_world; : > "$T/settle.noop"; tick
    if [ "$(rowf settle_merged outcome)" = failed ]; then bad "X10 dropping the read-back must record a settle that did not take as done"; else ok "X10 RED: without the read-back a settle that did not take is recorded done"; fi
  else bad "X10 mutation not applied"; fi
  restore "$R2"
  check "X the restored files are the shipped ones" \
    '[ "$(readlink "$H/$R")" = "$DIR/$R" ] && [ "$(readlink "$H/$C")" = "$DIR/$C" ] && [ "$(readlink "$H/$U")" = "$DIR/$U" ] && [ "$(readlink "$H/$E")" = "$DIR/$E" ] && [ "$(readlink "$H/$B")" = "$DIR/$B" ]'
else
  bad "X python3 is required for the mutations"
fi

echo "archie-fm-queue: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
