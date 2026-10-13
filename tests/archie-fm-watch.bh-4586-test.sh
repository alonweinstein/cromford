#!/bin/bash
# tests/archie-fm-watch.bh-4586-test.sh — BH-4586 (BH-4574.4): Archie's
# whole-factory watch, driven through the SHIPPED bin/archie-fm-watch.sh (the
# ticket's tests/archie-fm-watch-test.sh, keyed to the ticket per house rule).
#
# THE WORLD. Two fleet projects, fixt (acme/fixt, box box-fixt) and other, a
# scratch $HARNESS, and this box called `hubbox` (ARCHIE_FMW_HOST). Every alert
# id is minted by the detectors' own keyers (bin/lib/alert-state.sh's
# as_sanitize_id and alert_state_key; pipeline-health's ph-<key> fold), never
# typed by hand (D4).
#
# WHAT IS STUBBED, and only this. ARCHIE_FMW_FIXTURE=$T/fx.sh (sandbox-only):
#   _jobs_req   a jq model of /api/settings/<key>, the three /api/archie/actions
#               routes (+ ?dedupe_key=), GET /api/alerts, POST /api/alerts/actions
#               (ack: new|quarantined -> triaged, else 409; unknown id 404) and
#               POST /api/box-console-commands. The worker side of the archie
#               routes runs for real in worker/jobs/test/archie-actions.bh-4586.test.js.
#   gh_rest     the REST calls, logged to $T/ghrest.log (issue bodies kept).
# $H/bin stubs log argv + RESCUE_ONLY to $T/calls.log: review-rescue.sh,
# fleet-propagate.sh, main-red-bisect.sh, cost-rollup.sh, disk-clean.sh,
# console-pages-deploy.sh, and the never-to-be-called harness-ctl.sh, pause.sh,
# deploy-request.sh. PATH stubs: gh, curl and wrangler log and fail; git logs
# and then runs the real git (the cron sweep reads a fixture checkout); df and
# crontab answer from $T files.
#
# Cases: W-E2E, W-ONCE, W-MATCH, W-NEG, W-RESCUE, W-INODE, W-CRON, W-PAUSE,
# W-ESC, W-ALLOW, W-OBS, W-CAP, W-OFF, W-KNOB, W-NOALERT, W-LEVERS, W-STALE,
# W-DRY, W-CLASS, X mutations.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-watch.bh-4586-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-watch: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-watch: flock is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "archie-fm-watch: python3 is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${ARCHIE_FMW_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-fm-watch.sh" "$DIR/bin/lib/archie-fm-watch/common.sh" \
         "$DIR/bin/lib/archie-fm-watch/sources.sh" "$DIR/bin/lib/archie-fm-watch/levers.sh" \
         "$DIR/bin/lib/archie-fm-queue/common.sh" "$DIR/worker/jobs/src/routes/archie-actions.js" \
         "$DIR/catalog/lanes.d/archie-fm-watch.json" "$DIR/cron/lanes/727-archie-fm-watch.cron"; do
  if [ -f "$f" ]; then ok "ships ${f#"$DIR"/}"; else bad "missing $f"; fi
done
if [ ! -f "$DIR/bin/archie-fm-watch.sh" ]; then
  echo "archie-fm-watch: $PASS passed, $FAIL failed"; exit 1
fi

NOW=1791184500                       # 2026-10-05T07:15:00Z
export HOME="$T/home"
mkdir -p "$T/home" "$T/tmp" "$T/as"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ═════ the detectors' own keyers (D4) ═════════════════════════════════════════
mkdir -p "$T/ash"
# shellcheck source=/dev/null
HARNESS="$T/ash" . "$DIR/bin/lib/alert-state.sh" 2>/dev/null || true
command -v as_sanitize_id >/dev/null 2>&1 && command -v alert_state_key >/dev/null 2>&1 \
  || { echo "archie-fm-watch: bin/lib/alert-state.sh did not load"; exit 1; }
export ALERT_STATE_DIR="$T/as"
# pipeline-health.sh alert(): aid="ph-$(printf '%s' "$key" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-117)"
phid() { printf 'ph-%s' "$(as_sanitize_id "$1" | cut -c1-117)"; }
ID_STUCK=$(as_sanitize_id stuck-work)                                  # bin/stuck-work.sh --id stuck-work
ID_REAP=$(as_sanitize_id "lane-reaper:fixt:FX-1")                      # bin/lane-reaper.sh
ID_DISK_HUB=$(as_sanitize_id "disk-high-hubbox")                       # bin/disk-guard.sh
ID_DISK_A=$(as_sanitize_id "disk-high-box-a")
ID_DISK_B=$(as_sanitize_id "disk-refuse-box-b")
ID_TMP=$(phid "tmpfull:box-a")
ID_DW=$(phid "deployworkers:example-org/cromford")
ID_CPD=$(phid "consolepagesdrift:hub")
ID_ROLL=$(phid "costrollupstale:hub")
ID_RATE=$(phid "costrate:fixt")
ID_OVER=$(phid "overcap:fixt")
ID_BUDGET=$(as_sanitize_id "budget-stop:fixt:fixt-FX-7-202610050100")
ID_UTD=$(as_sanitize_id "untriaged-digest:fixt:20261005")
ID_UTD_GONE=$(as_sanitize_id "untriaged-digest:ghost:20261005")
L_STUCK="STUCK-WORK acme/fixt#12 review owner=blocked-resolver age=300m sla=120m — https://github.com/acme/fixt/pull/12"
L_REAP="[orchestrator/lane-reaper] we killed the fixt FX-1 build lane in fixt-FX-1-202610050100: no heartbeat for 3h. bin/blocked-resolver.sh relaunches it."
L_IDLE="[fly-idle] 2 pool machines idle but billed: fixt-pool (2h), other-pool (3h)"
L_DISK="[orchestrator/disk-guard] / at 91% on hubbox. bin/disk-clean.sh runs at 04:47Z."
L_FP="[orchestrator/fleet-propagate] propagating abc1234 to the fleet FAILED in part — hub=ok, 7/8 boxes synced, failed: box-b, crontab ok."
ID_FP=$(alert_state_key "$L_FP")
L_CRONGAP="[box-b] CRONTAB GAP: fleet.conf assigns fixt to this box but the LIVE crontab has no triage lane for it — installing it now."
ID_CRONGAP=$(alert_state_key "$L_CRONGAP")
L_DW="[pipeline-health] Deploy workers run 5551234 on main abc1234 ended failure: LIVE WORKERS/CONSOLE MAY BE STALE; https://github.com/example-org/cromford/actions/runs/5551234"
L_DW_NORUN="[pipeline-health] Deploy workers on main abc1234 ended failure: LIVE WORKERS/CONSOLE MAY BE STALE"
L_CPD="[pipeline-health] Mission Control is behind main: Pages serves abc1234, main's console-ui is at def5678 (3 undeployed console-ui merges)"
L_RED="[orchestrator/main-red] acme/fixt main is RED at abc1234 (Harness CI run https://github.com/acme/fixt/actions/runs/77)"
ID_RED=$(alert_state_key "$L_RED")
L_GREEN="[orchestrator/main-red] acme/fixt main is GREEN again at def5678"
L_UTD="[orchestrator/untriaged-digest] [fixt] 3 untriaged tickets, oldest 5h"
L_UTS="[fixt] ticket #41 untriaged >1h (app triage may be silently failing): Fix the thing"
L_UTB="UNTRIAGED >1h: fixt #41 — Fix the thing. App triage may be silently failing; check runtime logs / re-trigger."
L_ROLL="[pipeline-health] cost-rollup last succeeded 1500m ago (cron), past 1440m — state/cost/ is frozen"
L_COSTREC="[orchestrator/cost-reconcile] COST RECONCILE [anthropic] 24h: the meter moved \$40 but our rows account for \$20"
L_QUOTA="[gh-quota] GitHub quota low for app:harness: rest 400/5000 (8%), graphql 4000/5000 (80%), resets at 2026-10-05T08:00:00Z"
L_ROLLFAM="[orchestrator/cost-rollup] python rollup FAILED: KeyError 'x'"
for v in ID_STUCK ID_REAP ID_FP ID_CRONGAP ID_RED ID_UTD; do
  [ -n "${!v}" ] || { echo "archie-fm-watch: the keyer gave no id for $v"; exit 1; }
done
eq "D4 the main-red keyer collapses the RED line onto main-red-acme_fixt" "$ID_RED" "main-red-acme_fixt"
eq "D4 lane-reaper's --id folds to lane-reaper_fixt_FX-1" "$ID_REAP" "lane-reaper_fixt_FX-1"

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; CO="$T/co"
REALGIT=$(command -v git)
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$H/builds" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
printf 'fixt acme/fixt - - box-fixt\nother acme/other - - box-other\n' > "$H/fleet.conf"
STUBS="review-rescue.sh fleet-propagate.sh main-red-bisect.sh cost-rollup.sh disk-clean.sh console-pages-deploy.sh harness-ctl.sh pause.sh deploy-request.sh"
for s in fleet-conf.sh alert-line.sh lane-alert.sh project-of.sh $STUBS; do rm -f "$H/bin/$s"; done
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) echo fixt; echo other ;;
  --*) ;;
  *) case "${2:-}" in repo) echo "acme/$1" ;; box) echo "box-$1" ;; esac ;;
esac
SH
cat > "$H/bin/project-of.sh" <<'SH'
#!/bin/bash
[ "$1" = --prefix ] || exit 1
for p in fixt other; do case "$2" in "$p"-*) echo "$p"; exit 0 ;; esac; done
exit 1
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
for s in $STUBS; do
  cat > "$H/bin/$s" <<SH
#!/bin/bash
printf '%s %s RESCUE_ONLY=%s\n' "$s" "\$*" "\${RESCUE_ONLY:-}" >> "\$FXT/calls.log"
printf '%s %s\n' "$s" "\$*" >> "\$FXT/calls-all.log"
exit "\$(cat "\$FXT/$s.rc" 2>/dev/null || echo 0)"
SH
done
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/project-of.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
for s in $STUBS; do chmod +x "$H/bin/$s"; done
# The model session's two calls (afw_session): agent-call answers from
# $FXT/session.answer, archie-tg-send logs the key it was given.
rm -f "$H/bin/agent-call.sh" "$H/bin/archie-tg-send.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s %s %s %s LANE=%s FP=%s\n' "$1" "$2" "$3" "$4" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_FP:-}" >> "$FXT/session.log"
cp "${6#@}" "$FXT/session.prompt" 2>/dev/null
cat "$FXT/session.answer" > "$5" 2>/dev/null
exit "$(cat "$FXT/agent-call.rc" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FXT/tg.log"
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/archie-tg-send.sh"
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
printf '#!/bin/bash\nprintf "wrangler %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' > "$T/fakebin/wrangler"
printf '#!/bin/bash\nprintf "git %%s\\n" "$*" >> "$FXT/git.log"\nexec %s "$@"\n' "$REALGIT" > "$T/fakebin/git"
cat > "$T/fakebin/crontab" <<'SH'
#!/bin/bash
[ "${1:-}" = -l ] || { echo "crontab stub: only -l" >&2; exit 2; }
[ -f "$FXT/crontab.down" ] && exit 1
cat "$FXT/crontab" 2>/dev/null
SH
cat > "$T/fakebin/df" <<'SH'
#!/bin/bash
if [ -f "$FXT/df.out" ]; then cat "$FXT/df.out"; exit 0; fi
printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/root 1000 100 900 10%% /\ntmpfs 1000 50 950 5%% /tmp\n'
SH
chmod +x "$T/fakebin/"*

# The hub's checkout (bin/fleet-propagate.sh's HARNESS_CHECKOUT): one wired hub
# lane added two hours before NOW, one added ten minutes before, one unwired,
# one on another box, and one added two hours before that runs via a wrapper
# (a cadence, no cron/lanes fragment of its own) like batch-resolve or fly-pool.
mkdir -p "$CO/catalog/lanes.d" "$CO/cron/lanes"
frag() { printf '# @hub-lanes\n# %s: a comment naming bin/%s.sh is not a line\n*/10 * * * * /root/harness/bin/%s.sh >/dev/null 2>&1\n' "$2" "$2" "$2" > "$CO/cron/lanes/$1-$2.cron"; }
frag 801 old-lane; frag 802 off-lane; frag 803 box-lane; frag 804 new-lane; frag 805 fresh-lane
"$REALGIT" -C "$CO" init -q
lane_json() { jq -n --arg id "$1" --arg s "$2" --argjson w "$3" --arg b "$4" \
  '{id: $id, scope: "hub", script: $s, cadence: "*/10 * * * *", boxes: [$b], wired: $w}'; }
co_commit() { # co_commit <epoch> <msg>
  "$REALGIT" -C "$CO" add -A
  GIT_AUTHOR_DATE="@$1" GIT_COMMITTER_DATE="@$1" "$REALGIT" -C "$CO" -c user.email=t@t -c user.name=t \
    -c commit.gpgsign=false commit -qm "$2"
}
lane_json old-lane bin/old-lane.sh true hub > "$CO/catalog/lanes.d/old-lane.json"
lane_json off-lane bin/off-lane.sh false hub > "$CO/catalog/lanes.d/off-lane.json"
lane_json box-lane bin/box-lane.sh true box-a > "$CO/catalog/lanes.d/box-lane.json"
co_commit $((NOW - 86400)) "old lanes"
lane_json new-lane bin/new-lane.sh true hub > "$CO/catalog/lanes.d/new-lane.json"
lane_json via-lane bin/via-lane.sh true hub | jq '.cadence = "*/5 * * * * (via bin/old-lane.sh)"' > "$CO/catalog/lanes.d/via-lane.json"
printf '# @hub-lanes\n# via-lane runs inside bin/via-lane.sh, from old-lane; no line of its own\n' > "$CO/cron/lanes/806-via-lane.cron"
co_commit $((NOW - 7200)) "new lane"
lane_json fresh-lane bin/fresh-lane.sh true hub > "$CO/catalog/lanes.d/fresh-lane.json"
co_commit $((NOW - 600)) "fresh lane"
NEWSHA=$("$REALGIT" -C "$CO" log --diff-filter=A --format=%H -1 -- catalog/lanes.d/new-lane.json)

cat > "$T/fx.sh" <<'SH'
fx_clock() { date -u -d "@$ARCHIE_FMW_NOW" +%Y-%m-%dT%H:%M:%SZ; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/flags*|/api/lanes*|/api/verdicts*|/api/job*|/api/pr-*|/api/build-queue*|/api/pauses*) JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2 ;; esac
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  t=$(fx_clock)
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
      [ -f "$FXT/settings.down" ] && { JOBS_HTTP=503; return 1; }
      key=${p#/api/settings/}
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"no such setting"}'; return 2; } ;;
    "POST /api/archie/actions")
      [ -f "$FXT/archie.absent" ] && { JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2; }
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
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"archie action not found"}'; return 2; }
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
      [ -f "$FXT/archie.absent" ] && { JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2; }
      [ -f "$FXT/count.down" ] && { JOBS_HTTP=503; return 1; }
      local d pb k; d=$(qp day); pb=$(qp playbook); k=$(qp dedupe_key)
      if [ -n "$k" ]; then
        k=$(printf '%b' "${k//%/\\x}")
        out=$(jq -c --arg k "$k" '.actions[] | select(.dedupe_key == $k) | {action: .}' "$db")
        [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"archie action not found"}'; return 2; }
      else
        out=$(jq -c --arg d "$d" --arg pb "$pb" '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] as $r
          | {ok: true, day: $d, actions: $r,
             counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][$x.outcome] += 1)), truncated: false}' "$db")
      fi ;;
    "GET /api/initiatives")
      [ -f "$FXT/initiatives.down" ] && { JOBS_HTTP=503; return 1; }
      out=$(jq -c '{initiatives: (.initiatives // []), truncated: false, as_of: "x"}' "$db") ;;
    "GET /api/alerts")
      [ -f "$FXT/alerts.down" ] && { JOBS_HTTP=503; return 1; }
      local st lim; st=$(qp state); lim=$(qp limit)
      out=$(jq -c --arg s "$st" --argjson l "${lim:-200}" '[.alerts[] | select(.state == $s)] as $r
        | {alerts: $r[0:$l], truncated: (($r | length) > $l), as_of: "x"}' "$db") ;;
    "POST /api/alerts/actions")
      printf '%s\n' "$b" >> "$FXT/acks.log"
      key=$(jq -r .id <<<"$b")
      out=$(jq -c --arg k "$key" '.alerts[] | select(.id == $k)' "$db")
      if [ -z "$out" ] || [ -f "$FXT/ack.gone" ]; then JOBS_HTTP=404; printf '{"error":"no such alert"}'; return 2; fi
      if ! jq -e '.state == "new" or .state == "quarantined"' <<<"$out" >/dev/null; then
        JOBS_HTTP=409; printf '{"error":"disallowed edge","from":"%s"}' "$(jq -r .state <<<"$out")"; return 9
      fi
      jq --arg k "$key" '.alerts |= map(if .id == $k then .state = "triaged" else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --arg k "$key" '{alert: (.alerts[] | select(.id == $k)), action: {outcome: "ok"}}' "$db") ;;
    "POST /api/box-console-commands")
      printf '%s\n' "$b" >> "$FXT/bcc.log"
      [ -f "$FXT/bcc.down" ] && { JOBS_HTTP=503; return 1; }
      out='{"ok":true,"created":true}'; code=201 ;;
    *) JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest() {
  local m="$1" p="$2" a n
  shift 2
  printf '%s %s %s\n' "$m" "$p" "$*" >> "$FXT/ghrest.log"
  printf '%s %s %s\n' "$m" "$p" "$*" >> "$FXT/ghrest-all.log"
  for a in "$@"; do case "$a" in body=@*) n=$(ls "$FXT"/issue-body.* 2>/dev/null | wc -l); cp "${a#body=@}" "$FXT/issue-body.$n" ;; esac; done
  case "$m $p" in
    "GET repos/example-org/cromford/actions/workflows/deploy-workers.yml/runs?branch=main&per_page=1")
      [ -f "$FXT/runs.down" ] && { GH_REST_STATUS=502; return 75; }
      GH_REST_STATUS=200
      jq -nc --argjson i "$(cat "$FXT/runs.newest" 2>/dev/null || echo 5551234)" --arg s "$(cat "$FXT/runs.sha" 2>/dev/null || echo "$MAINSHA")" \
        '{workflow_runs: [{id: $i, head_sha: $s, status: "completed", conclusion: "failure"}]}'; return 0 ;;
    "GET repos/example-org/cromford/commits/main")
      GH_REST_STATUS=200; jq -nc --arg s "$MAINSHA" '{sha: $s}'; return 0 ;;
    POST\ repos/*/actions/runs/*/rerun-failed-jobs)
      GH_REST_STATUS=$(cat "$FXT/rerun.status" 2>/dev/null || echo 201)
      case "$GH_REST_STATUS" in 2*) return 0 ;; *) return 75 ;; esac ;;
    GET\ repos/example-org/cromford/issues\?*)
      [ -f "$FXT/issues.down" ] && { GH_REST_STATUS=502; return 75; }
      n=$(printf '%s' "$p" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
      GH_REST_STATUS=200; cat "$FXT/issues.page.$n" 2>/dev/null || echo '[]'; return 0 ;;
    "POST repos/example-org/cromford/issues")
      GH_REST_STATUS=$(cat "$FXT/issue.status" 2>/dev/null || echo 201)
      case "$GH_REST_STATUS" in 2*) echo '{"number": 9001, "html_url": "https://github.com/example-org/cromford/issues/9001"}'; return 0 ;; *) return 75 ;; esac ;;
  esac
  GH_REST_STATUS=404; return 44
}
[ -f "$FXT/fx-extra.sh" ] && . "$FXT/fx-extra.sh"
:
SH

# The REAL hub crontab this checkout renders, for the W-CRON registry case.
# Rendered before the PATH stubs go in.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/render-cron.sh" hub > "$T/hubcron.real" 2>/dev/null || : > "$T/hubcron.real"
export MAINSHA=abc1234def5678abc1234def5678abc1234def56
export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
       MC_REHYDRATE=0 TMPDIR="$T/tmp" HARNESS_CHECKOUT="$CO" ARCHIE_FMW_STATE_MD="$T/STATE.md"
unset HARNESS_ENV_DIR ARCHIE_FMW_ENABLED ARCHIE_FMW_RETRY_S ARCHIE_FMW_NOW ARCHIE_FMW_FIXTURE ARCHIE_FMW_TIMED ARCHIE_FMW_HOST \
  ARCHIE_FMW_TICK_CEILING_S RESCUE_ONLY 2>/dev/null || true

# world — a fresh db, logs, builds, pauses and stubs; nothing fires.
world() {
  local p
  for p in db.json reqlog ghrest.log alerts.log calls.log acks.log bcc.log crontab crontab.down df.out \
           issues.down issue.status rerun.status runs.down runs.newest runs.sha ack.gone bcc.down settings.down count.down alerts.down archie.absent \
           fx-extra.sh out rc STATE.md initiatives.down session.log session.prompt session.answer agent-call.rc tg.log; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/issue-body.* "$T"/issues.page.* "$T"/*.sh.rc
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/flags" || exit 1
  scratch_rm "$H/builds" || exit 1; scratch_rm "$H/env/cloudflare.env" || exit 1
  scratch_rm "$H/catalog/prompts" || exit 1
  scratch_rm "$H/logs/archie-fm-watch.log" || exit 1; scratch_rm "$H/logs/READY-QUEUE.log" || exit 1
  mkdir -p "$H/state/merge-conductor" "$H/flags" "$H/locks" "$H/builds"
  : > "$H/state/merge-conductor/pr-state.tsv"; : > "$H/state/merge-conductor/attempts.txt"
  for p in $STUBS; do chmod +x "$H/bin/$p"; done
  printf '*/10 * * * * /root/harness/bin/old-lane.sh\n*/10 * * * * /root/harness/bin/new-lane.sh\n' > "$T/crontab"
  # interval_min 10: every tick acts, so the cases below need no clock math
  # (W-CADENCE drops the row to test the default).
  jq -n '{settings: {"archie.manage": "on", "archie.watch.interval_min": "10"}, actions: [], alerts: []}' > "$T/db.json"
  : > "$T/reqlog"; : > "$T/ghrest.log"; : > "$T/calls.log"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
alert() { # alert <id> <line> [state] [age-s] [box]
  jq --arg id "$1" --arg l "$2" --arg s "${3:-new}" --arg fs "$(iso $((NOW - ${4:-3600})))" --arg b "${5:-hubbox}" \
    '.alerts += [{id: $id, family: "0123456789ab", box: $b, project: "", state: $s, count: 1, first_seen: $fs,
                  last_seen: $fs, claimed_by: null, claimed_at: null, notified_at: null, severity: "warn", line: $l}]' \
    "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
build() { # build <dir> <RESULT first line> <age-s> [marker...]
  local d="$H/builds/$1" m
  mkdir -p "$d"; printf '%s\n' "$2" > "$d/RESULT"
  touch -d "@$((NOW - $3))" "$d/RESULT"
  shift 3
  for m in "$@"; do : > "$d/$m"; done
  touch -d "@$((NOW - 60))" "$d"
}
pausefix() { # pausefix <scope> <what> <age-s>
  jq -n --arg s "$1" --arg w "$2" --arg c "$(iso $((NOW - $3)))" --arg e "$(iso $((NOW + 86400)))" \
    '{pauses: [{id: 77, scope: $s, what: $w, reason: "hold", actor: "operator", created_at: $c, expires_at: $e, ended_at: null}]}' \
    > "$H/state/pauses.json"
}
tick() { # tick [VAR=value ...] [-- args] — one tick of the shipped lane
  local args=() envs=()
  while [ $# -gt 0 ]; do case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac; done
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FMW_NOW="$NOW" ARCHIE_FMW_FIXTURE="$T/fx.sh" ARCHIE_FMW_HOST=hubbox LANE_GATE_DISABLE=1 \
    ${envs[@]+"${envs[@]}"} bash "$H/bin/archie-fm-watch.sh" ${args[@]+"${args[@]}"} > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rows()   { jq '.actions | length' "$T/db.json"; }
rowsof() { jq --arg p "$1" '[.actions[] | select(.playbook == $p)] | length' "$T/db.json"; }
rowf()   { jq -r --arg p "$1" --arg f "$2" '[.actions[] | select(.playbook == $p)][0] | getpath($f | split(".")) // "null" | tostring' "$T/db.json"; }
nlines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
ncalls() { grep -c "^$1 " "$T/calls.log" 2>/dev/null; }
wlog()   { cat "$H/logs/archie-fm-watch.log" 2>/dev/null; }
# settle — detached kicks write calls.log a moment later: wait until it has
#   <n> lines (5 s at most), then a beat more so a stray extra call shows.
settle() {
  local i=0
  while [ "$(nlines "$T/calls.log")" -lt "${1:-0}" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  sleep 0.3
}
posts() { grep -c "^POST $1" "$T/ghrest.log" 2>/dev/null; }

# ── the all-classes world: one incident per class ────────────────────────────
e2e_world() {
  world
  alert "$ID_STUCK" "$L_STUCK"
  build fixt-FX-1-202610050100 "REVIEW_BLOCKED reviewer timed out" 7200 REAPED
  alert "$ID_REAP" "$L_REAP" new 7200
  alert "$(alert_state_key "$L_IDLE")" "$L_IDLE"
  alert "$ID_DISK_HUB" "$L_DISK"
  alert "$ID_DW" "$L_DW"
  alert "$ID_RED" "$L_RED"
  printf '*/10 * * * * /root/harness/bin/old-lane.sh\n' > "$T/crontab"
  pausefix fixt builds 10800
  printf 'FX-9 fix the widget project=fixt\n' > "$H/logs/READY-QUEUE.log"
  alert "$ID_UTD" "$L_UTD"
  alert "$ID_ROLL" "$L_ROLL"
}
E2E_PB="watch-build-stuck:ack_alert watch-review-unrescued:kick_lane watch-pool-idle:file_ticket watch-disk:run_cleanup
watch-cron-install:kick_lane watch-deploy-drift:rerun_deploy watch-main-red:kick_lane watch-pause-waiting:file_ticket
watch-triage-skip:kick_lane watch-cost-anomaly:kick_lane"
e2e_ok() { # every class: exactly one row with its lever, and one matching call
  local pa pb a out=0
  [ "$(rows)" = 10 ] || { echo "rows=$(rows)"; out=1; }
  for pa in $E2E_PB; do
    pb=${pa%%:*}; a=${pa#*:}
    [ "$(rowsof "$pb")" = 1 ] && [ "$(rowf "$pb" action)" = "$a" ] || { echo "$pb: $(rowsof "$pb") rows, action $(rowf "$pb" action)"; out=1; }
  done
  [ "$(nlines "$T/acks.log")" = 1 ] || { echo "acks=$(nlines "$T/acks.log")"; out=1; }
  [ "$(ncalls review-rescue.sh)" = 1 ] && grep -q '^review-rescue.sh  RESCUE_ONLY=fixt$' "$T/calls.log" || { echo "review-rescue calls"; out=1; }
  [ "$(ncalls disk-clean.sh)" = 1 ] || { echo "disk-clean calls=$(ncalls disk-clean.sh)"; out=1; }
  [ "$(ncalls fleet-propagate.sh)" = 1 ] || { echo "fleet-propagate calls"; out=1; }
  [ "$(ncalls main-red-bisect.sh)" = 1 ] || { echo "main-red-bisect calls"; out=1; }
  [ "$(ncalls cost-rollup.sh)" = 1 ] || { echo "cost-rollup calls"; out=1; }
  [ "$(posts "repos/example-org/cromford/actions/runs/5551234/rerun-failed-jobs")" = 1 ] || { echo "rerun posts"; out=1; }
  [ "$(posts "repos/example-org/cromford/issues ")" = 2 ] || { echo "issue posts=$(posts "repos/example-org/cromford/issues ")"; out=1; }
  [ "$(nlines "$T/bcc.log")" = 1 ] || { echo "box commands=$(nlines "$T/bcc.log")"; out=1; }
  return "$out"
}
q_e2e() { e2e_world; tick; settle 5; e2e_ok; }
if q_e2e >/dev/null; then ok "W-E2E ten classes through the shipped lane: ten rows, each its table lever, each one call"
else bad "W-E2E ten classes through the shipped lane ($(e2e_ok 2>&1 | tr '\n' ' ')$(wlog | tail -3 | tr '\n' ' '))"; fi
check "W-E2E the lever rows close done or requested, never started" \
  '[ "$(jq "[.actions[] | select(.outcome == \"started\" or .outcome == \"failed\")] | length" "$T/db.json")" = 0 ]'
check "W-E2E the review-unrescued alert and the RESULT sweep are ONE incident (the build dir)" \
  '[ "$(rowf watch-review-unrescued evidence.incident)" = fixt-FX-1-202610050100 ]'
check "W-E2E detached kicks and a queued rerun are requested, synchronous levers done" \
  '[ "$(rowf watch-main-red outcome)" = requested ] && [ "$(rowf watch-disk outcome)" = done ] && [ "$(rowf watch-deploy-drift outcome)" = requested ] && [ "$(rowf watch-triage-skip outcome)" = requested ]'
check "W-E2E the rows are pr 0 on the watch playbooks, repo from the subject" \
  '[ "$(rowf watch-main-red pr)" = 0 ] && [ "$(rowf watch-main-red repo)" = acme/fixt ] && [ "$(rowf watch-main-red project)" = fixt ] && [ "$(rowf watch-disk repo)" = example-org/cromford ]'
check "W-E2E the triage box command is run_triage for fixt on its owning box" \
  'jq -e ".type == \"run_triage\" and .project == \"fixt\" and .box == \"box-fixt\" and (.command_id | startswith(\"afw-\"))" "$T/bcc.log" >/dev/null'
check "W-E2E one summary line with the counts" \
  'wlog | grep -q "findings=10 pulled=8 tickets=2 would=0 capped=0 skipped=0 failed=0 incomplete=0"'
check "W-NOALERT a full tick with every class firing writes no ALERTS line and no alert note" \
  '[ "$(nlines "$T/alerts.log")" = 0 ] && ! grep -q "/api/alerts/note" "$T/reqlog"'

# ── W-ONCE: the same state twice -> nothing new ──────────────────────────────
R1=$(rows); C1=$(nlines "$T/calls.log"); G1=$(nlines "$T/ghrest.log"); A1=$(nlines "$T/acks.log"); B1=$(nlines "$T/bcc.log")
tick; settle 0
check "W-ONCE a second tick on the same state adds no row and pulls no lever" \
  '[ "$(rows)" = "$R1" ] && [ "$(nlines "$T/calls.log")" = "$C1" ] && [ "$(grep -c "^POST" "$T/ghrest.log")" = "$(head -n "$G1" "$T/ghrest.log" | grep -c "^POST")" ] && [ "$(nlines "$T/acks.log")" = "$A1" ] && [ "$(nlines "$T/bcc.log")" = "$B1" ]'
check "W-ONCE ...and logs them as skipped" 'wlog | tail -1 | grep -q "skipped=10"'

# ── W-MATCH / W-NEG: the matcher, on lines the detectors write ───────────────
m() { bash -c '. "$1"; afw_match "$2" "$3"' _ "$DIR/bin/lib/archie-fm-watch/sources.sh" "$1" "$2"; }
for row in "build-stuck|$ID_STUCK|$L_STUCK" "review-unrescued|$ID_REAP|$L_REAP" "pool-idle|auto-x|$L_IDLE" \
           "disk|$ID_DISK_A|$L_DISK" "disk|$ID_DISK_B|x" "disk|$ID_TMP|x" "cron-install|$ID_FP|$L_FP" \
           "cron-install|$ID_CRONGAP|$L_CRONGAP" "deploy-drift|$ID_DW|$L_DW" "deploy-drift|$ID_CPD|$L_CPD" \
           "main-red|$ID_RED|$L_RED" "triage-skip|$ID_UTD|$L_UTD" "triage-skip|$(alert_state_key "$L_UTS")|$L_UTS" \
           "triage-skip|$(alert_state_key "$L_UTB")|$L_UTB" "cost-anomaly|$ID_ROLL|$L_ROLL" "cost-anomaly|$ID_RATE|x" \
           "cost-anomaly|$ID_OVER|x" "cost-anomaly|$ID_BUDGET|x" "cost-anomaly|$(alert_state_key "$L_COSTREC")|$L_COSTREC" \
           "cost-anomaly|$(alert_state_key "$L_QUOTA")|$L_QUOTA"; do
  IFS='|' read -r want id line <<<"$row"
  eq "W-MATCH $id" "$(m "$id" "$line")" "$want"
done
for row in "stuck-work-ledger|STUCK-WORK ledger unreachable — 3 items past SLA unpaged" \
           "stuck-work-no-token|[orchestrator/stuck-work] no GitHub token" \
           "$(alert_state_key "[disk-clean] / still above 90% after cleaning")|[disk-clean] / still above 90% after cleaning" \
           "$ID_RED|$L_GREEN" \
           "$(alert_state_key "[orchestrator/lane-reaper] note: [fly-idle] 2 idle")|[orchestrator/lane-reaper] note: [fly-idle] 2 idle" \
           "$(alert_state_key "$L_ROLLFAM")|$L_ROLLFAM" \
           "$(alert_state_key "[pipeline-health] RESOLVED costrollupstale:hub — cost-rollup succeeded 3m ago")|[pipeline-health] RESOLVED costrollupstale:hub — cost-rollup succeeded 3m ago"; do
  id=${row%%|*}; line=${row#*|}
  eq "W-NEG no class for $id :: ${line:0:50}" "$(m "$id" "$line")" ""
done

neg_world() { world; alert "$1" "$2" "${3:-new}" "${4:-3600}"; tick; settle 0; }
neg_world "$ID_RED" "$L_RED" resolved
check "W-NEG a resolved main-red alert: no row, no kick" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/calls.log")" = 0 ]'
neg_world "$ID_STUCK" "$L_STUCK" new 300
check "W-NEG an alert younger than alert_min_age_s: no row" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/acks.log")" = 0 ]'
neg_world "$ID_UTD_GONE" "[orchestrator/untriaged-digest] [ghost] 3 untriaged tickets"
check "W-NEG an untriaged-digest for a project not in fleet.conf: no row, no box command" \
  '[ "$(rows)" = 0 ] && [ "$(nlines "$T/bcc.log")" = 0 ] && wlog | grep -q "not a fleet.conf project"'
neg_world "$(alert_state_key "[orchestrator/lane-reaper] note: [fly-idle] 2 idle")" "[orchestrator/lane-reaper] note: [fly-idle] 2 idle"
check "W-NEG a [fly-idle] quoted inside another lane's alert: no ticket" '[ "$(rows)" = 0 ] && [ "$(posts "repos/example-org/cromford/issues ")" = 0 ]'
neg_world "$ID_DW" "$L_DW_NORUN"
check "W-NEG a deployworkers line with no run id: a failed row, no rerun" \
  '[ "$(rowf watch-deploy-drift outcome)" = failed ] && [ "$(grep -c rerun-failed-jobs "$T/ghrest.log")" = 0 ] && rowf watch-deploy-drift why | grep -q "names no run id"'
world; alert "$ID_DW" "$L_DW"; echo 5559999 > "$T/runs.newest"; tick
check "W-NEG a deployworkers run a newer main run superseded: a failed row naming the newer run, no rerun" \
  '[ "$(rowf watch-deploy-drift outcome)" = failed ] && [ "$(grep -c rerun-failed-jobs "$T/ghrest.log")" = 0 ] && rowf watch-deploy-drift why | grep -q "superseded by run 5559999" && [ "$(rowf watch-deploy-drift evidence.lever.superseded_by)" = 5559999 ]'
world; alert "$ID_DW" "$L_DW"; echo 0123456789012345678901234567890123456789 > "$T/runs.sha"; tick
check "W-NEG a deployworkers run that is newest but not on main's head: failed, no rerun" \
  '[ "$(rowf watch-deploy-drift outcome)" = failed ] && [ "$(grep -c rerun-failed-jobs "$T/ghrest.log")" = 0 ] && rowf watch-deploy-drift why | grep -q "but main is at"'
world; alert "$ID_DW" "$L_DW"; : > "$T/runs.down"; tick
check "W-NEG the newest-run read fails: failed, never a blind rerun" \
  '[ "$(rowf watch-deploy-drift outcome)" = failed ] && [ "$(grep -c rerun-failed-jobs "$T/ghrest.log")" = 0 ] && rowf watch-deploy-drift why | grep -q "could not confirm"'
neg_world "$(alert_state_key "$L_ROLLFAM")" "$L_ROLLFAM"
check "W-NEG a cost-rollup lane alert is not the stale-rollup class: no row, no kick" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/calls.log")" = 0 ]'

# ── the sweeps, each positive and negative ───────────────────────────────────
world; build fixt-FX-2-202610050200 "REVIEW_BLOCKED reviewer timed out" 7200; tick; settle 1
check "W-RESCUE an unrescued REVIEW_BLOCKED build: one kick, RESCUE_ONLY=fixt" \
  '[ "$(rowsof watch-review-unrescued)" = 1 ] && [ "$(ncalls review-rescue.sh)" = 1 ] && grep -q "RESCUE_ONLY=fixt" "$T/calls.log"'
world; build fixt-FX-3-202610050200 "ABANDONED_TIMEOUT no heartbeat" 7200 REAPED; tick; settle 1
check "W-RESCUE a reaped ABANDONED_TIMEOUT build is a finding" '[ "$(rowsof watch-review-unrescued)" = 1 ]'
world; build fixt-FX-2-202610050200 "REVIEW_BLOCKED reviewer timed out" 7200 .review-rescued
build fixt-FX-4-202610050200 "ABANDONED_TIMEOUT no heartbeat" 7200
build fixt-FX-5-202610050200 "REVIEW_BLOCKED reviewer timed out" 600
build fixt-FX-6-202610050200 "REVIEW_BLOCKED reviewer timed out" 7200 .blocked-resolver-superseded
tick; settle 0
check "W-RESCUE negatives: rescued, not reaped, inside the grace, superseded: no row" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/calls.log")" = 0 ]'

world; printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/root 1000 910 90 91%% /\ntmpfs 1000 50 950 5%% /tmp\n' > "$T/df.out"; tick
check "W-INODE / at 91% inodes: one disk row, disk-clean once" \
  '[ "$(rowsof watch-disk)" = 1 ] && [ "$(rowf watch-disk action)" = run_cleanup ] && [ "$(ncalls disk-clean.sh)" = 1 ] && [ "$(rowf watch-disk evidence.incident)" = "hubbox:/:2026-10-05" ]'
world; printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/root 1000 890 110 89%% /\ntmpfs 1000 50 950 5%% /tmp\n' > "$T/df.out"; tick
check "W-INODE 89% is under the 90 row: nothing" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/calls.log")" = 0 ]'
world; printf 'garbage\n' > "$T/df.out"; tick
check "W-INODE an unparseable df is logged and incomplete, never a finding" \
  '[ "$(rows)" = 0 ] && wlog | grep -q "df -iP gave no reading" && wlog | grep -q "incomplete=1"'

world; printf '*/10 * * * * /root/harness/bin/old-lane.sh\n' > "$T/crontab"; tick; settle 1
check "W-CRON a hub lane merged 2h ago and not in crontab: one kick of fleet-propagate, keyed on its add commit" \
  '[ "$(rowsof watch-cron-install)" = 1 ] && [ "$(ncalls fleet-propagate.sh)" = 1 ] && [ "$(rowf watch-cron-install evidence.incident)" = "new-lane@$NEWSHA" ]'
world; tick
check "W-CRON negatives: in crontab, too fresh, unwired, not on the hub, run via a wrapper with no fragment line: nothing" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/calls.log")" = 0 ]'
world; tick -- --dry-list
check "W-CRON --dry-list on the installed fixture crontab names no cron-install (via-lane has a cadence and no line)" \
  '[ "$(cat "$T/rc")" = 0 ] && ! grep -q "^cron-install" "$T/out"'
# The registry as it really is: every catalog/lanes.d entry and cron/lanes
# fragment of THIS checkout, against a crontab that is exactly the rendered hub
# cron. A perfectly installed hub has no cron-install finding (BH-4586 review:
# batch-resolve, box-chat, fly-pool, greenfield and prebuild-repro carry a
# cadence string and, by design, no cron line).
world; cp "$T/hubcron.real" "$T/crontab"
if [ -s "$T/crontab" ] && "$REALGIT" -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  tick HARNESS_CHECKOUT="$DIR" -- --class cron-install --dry-list
  check "W-CRON the real registry against the rendered hub crontab: zero cron-install findings" \
    '[ "$(cat "$T/rc")" = 0 ] && ! grep -q "^cron-install" "$T/out" && ! wlog | grep -q "cron sweep: .* skipped"'
else
  bad "W-CRON the real registry case could not render the hub crontab or find a git checkout at $DIR"
fi
world; : > "$T/crontab.down"; tick
check "W-CRON an unreadable crontab is skipped and incomplete, never 'every lane missing'" \
  '[ "$(rows)" = 0 ] && wlog | grep -q "crontab -l failed" && wlog | grep -q "incomplete=1"'

world; pausefix fixt builds 10800; printf 'FX-9 fix the widget project=fixt\n' > "$H/logs/READY-QUEUE.log"; tick
check "W-PAUSE fixt paused 3h with a ready line: one ticket, no unpause" \
  '[ "$(rowsof watch-pause-waiting)" = 1 ] && [ "$(rowf watch-pause-waiting action)" = file_ticket ] && [ "$(ncalls pause.sh)" = 0 ] && [ "$(rowf watch-pause-waiting evidence.incident)" = pause-77 ]'
world; pausefix fixt builds 10800; tick
check "W-PAUSE a pause with an empty ready queue: nothing" '[ "$(rows)" = 0 ]'
world; pausefix fixt builds 1800; printf 'FX-9 fix the widget project=fixt\n' > "$H/logs/READY-QUEUE.log"; tick
check "W-PAUSE a pause younger than pause_waiting_s: nothing" '[ "$(rows)" = 0 ]'
world; pausefix fixt merges 10800
printf 'acme/fixt#50\tREADY\t%s\t%s\t%s\t-\tready\thttps://github.com/acme/fixt/pull/50\n' "$((NOW - 600))" "$(printf '%040x' 50)" "$(printf '%040x' 50)" \
  >> "$H/state/merge-conductor/pr-state.tsv"; tick
check "W-PAUSE merges paused with a READY conductor row: one ticket" '[ "$(rowsof watch-pause-waiting)" = 1 ]'

# ── W-ESC: still open past escalate_s -> ONE ticket, then nothing ────────────
esc_world() { world; alert "$ID_STUCK" "$L_STUCK"; tick; }
q_esc() {
  esc_world
  [ "$(rowf watch-build-stuck outcome)" = done ] || return 1
  tick ARCHIE_FMW_NOW=$((NOW + 7300))
  [ "$(rowsof watch-ticket)" = 1 ] && [ "$(posts "repos/example-org/cromford/issues ")" = 1 ]
}
check "W-ESC the lever row aged past escalate_s with the alert open: exactly one ticket" q_esc
MARK="<!-- archie-fm-watch:build-stuck:$(printf '%s' "$ID_STUCK@$((NOW - 3600))" | sha1sum | cut -c1-12) -->"
check "W-ESC the issue carries the marker, a plain title and NO label" \
  'grep -qF -- "$MARK" "$T/issue-body.0" && grep -q "title=Archie: a build stuck past its stage SLA on stuck-work still open after ack_alert" "$T/ghrest.log" && ! grep -q "labels" "$T/ghrest.log"'
check "W-ESC the ticket row is done with the issue URL" \
  '[ "$(rowf watch-ticket outcome)" = done ] && [ "$(rowf watch-ticket evidence.lever.issue)" = "https://github.com/example-org/cromford/issues/9001" ]'
tick ARCHIE_FMW_NOW=$((NOW + 7400))
check "W-ESC a third tick: nothing new" '[ "$(rowsof watch-ticket)" = 1 ] && [ "$(posts "repos/example-org/cromford/issues ")" = 1 ]'
esc_world
jq -n --arg m "$MARK" '[{number: 8000, html_url: "https://github.com/example-org/cromford/issues/8000", body: ("x\n" + $m)}]' > "$T/issues.page.1"
tick ARCHIE_FMW_NOW=$((NOW + 7300))
check "W-ESC an open issue already carrying the marker: no POST, the row is done with that URL" \
  '[ "$(posts "repos/example-org/cromford/issues ")" = 0 ] && [ "$(rowf watch-ticket outcome)" = done ] && [ "$(rowf watch-ticket evidence.lever.issue)" = "https://github.com/example-org/cromford/issues/8000" ]'
esc_world; : > "$T/issues.down"; tick ARCHIE_FMW_NOW=$((NOW + 7300))
check "W-ESC the issue list unreadable: no POST, the ticket row failed (fail closed)" \
  '[ "$(posts "repos/example-org/cromford/issues ")" = 0 ] && [ "$(rowf watch-ticket outcome)" = failed ]'
esc_world; tick ARCHIE_FMW_NOW=$((NOW + 3600))
check "W-ESC inside escalate_s: no ticket" '[ "$(rowsof watch-ticket)" = 0 ]'

# ── W-ALLOW: a lever outside the allowlist is refused before any write ──────
world; alert "$ID_STUCK" "$L_STUCK"
printf 'afw_lever() { printf "harness_ctl_off\\t-"; }\n' > "$T/fx-extra.sh"; tick; settle 0
check "W-ALLOW a tampered map naming harness_ctl_off: refused, the row failed, nothing called" \
  '[ "$(rowf watch-build-stuck outcome)" = failed ] && wlog | grep -q "refused lever .harness_ctl_off." && [ "$(nlines "$T/calls.log")" = 0 ] && [ "$(nlines "$T/acks.log")" = 0 ]'
world; alert "$ID_RED" "$L_RED"
printf 'afw_lever() { printf "kick_lane\\tdeploy"; }\n' > "$T/fx-extra.sh"; tick; settle 0
check "W-ALLOW kick_lane deploy: refused, the row failed, nothing called" \
  '[ "$(rowf watch-main-red outcome)" = failed ] && wlog | grep -q "refused kick_lane .deploy." && [ "$(nlines "$T/calls.log")" = 0 ]'

# ── W-OBS / W-OFF / W-CAP / W-KNOB ───────────────────────────────────────────
e2e_world; setting archie.manage observe; tick; settle 0
check "W-OBS observe: ten would_* rows and zero lever calls" \
  '[ "$(rows)" = 10 ] && [ "$(jq "[.actions[] | select(.outcome == \"would\" and (.action | startswith(\"would_\")))] | length" "$T/db.json")" = 10 ] && [ "$(nlines "$T/calls.log")" = 0 ] && [ "$(grep -c "^POST" "$T/ghrest.log")" = 0 ] && [ "$(nlines "$T/acks.log")" = 0 ] && [ "$(nlines "$T/bcc.log")" = 0 ]'
e2e_world; setting archie.manage off; tick; settle 0
check "W-OFF archie.manage=off: zero rows, zero calls" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/calls.log")" = 0 ] && [ "$(grep -c "^POST" "$T/ghrest.log")" = 0 ]'
e2e_world; tick ARCHIE_FMW_ENABLED=0; settle 0
check "W-OFF ARCHIE_FMW_ENABLED=0: zero rows, zero reads" '[ "$(rows)" = 0 ] && [ ! -s "$T/reqlog" ]'
e2e_world; setting archie.manage.hub off; tick; settle 0
check "W-OFF archie.manage.hub=off skips the fleet-scope classes, fixt's still act" \
  '[ "$(rowsof watch-disk)" = 0 ] && [ "$(rowsof watch-cron-install)" = 0 ] && [ "$(rowsof watch-main-red)" = 1 ] && [ "$(rowsof watch-triage-skip)" = 1 ]'
q_cap_one() {
  world; setting archie.cap.watch-disk 1
  alert "$ID_DISK_A" "[orchestrator/disk-guard] / at 91% on box-a." new 3600 box-a
  alert "$ID_DISK_B" "[orchestrator/disk-guard] / at 96% on box-b: builds refused." new 3600 box-b
  tick
  [ "$(rowsof watch-disk)" = 1 ] && [ "$(nlines "$T/acks.log")" = 1 ] && wlog | grep -q "capped=1"
}
check "W-CAP cap 1, two disk incidents on other boxes: one acked, one capped" q_cap_one
check "W-CAP the ack routes the alert to that box's own disk-clean" \
  'jq -e ".action == \"ack\" and .actor == \"archie-fm-watch\" and (.note | test(\"disk-clean\"))" "$T/acks.log" >/dev/null'
world; alert "$ID_STUCK" "$L_STUCK" new 3100; tick
check "W-KNOB absent threshold rows: the defaults act (an alert 3100 s old is past the 3000 default)" '[ "$(rowsof watch-build-stuck)" = 1 ]'
world; alert "$ID_STUCK" "$L_STUCK" new 2900; tick
check "W-KNOB an alert 2900 s old is inside alerts-medic's window (1200 s + one 30-min pass): no ack yet" \
  '[ "$(rows)" = 0 ] && [ "$(nlines "$T/acks.log")" = 0 ]'
world; alert "$ID_STUCK" "$L_STUCK"; setting archie.watch.alert_min_age_s abc; tick
check "W-KNOB a junk alert_min_age_s: no alert-fed action, one log line" \
  '[ "$(rows)" = 0 ] && [ "$(wlog | grep -c "archie.watch.alert_min_age_s=.abc. is not a whole number")" = 1 ]'
world; alert "$ID_STUCK" "$L_STUCK"; setting archie.cap.watch-build-stuck zz; tick
check "W-KNOB a junk cap: no action" '[ "$(rows)" = 0 ] && [ "$(nlines "$T/acks.log")" = 0 ]'

# ── W-CADENCE: archie.watch.interval_min (the operator, 2026-10-06) ──────────────────
unsetting() { jq --arg k "$1" 'del(.settings[$k])' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
world; unsetting archie.watch.interval_min; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-CADENCE no row: the default 20 skips the 07:15 tick (minute 15 of its window), zero rows, zero levers" \
  '[ "$(rows)" = 0 ] && [ "$(nlines "$T/acks.log")" = 0 ] && ! grep -q "/api/alerts" "$T/reqlog"'
world; unsetting archie.watch.interval_min; alert "$ID_STUCK" "$L_STUCK" new 3720; NOW0=$NOW; NOW=$((NOW + 720)); tick; NOW=$NOW0
check "W-CADENCE no row: the 07:27 tick (minute 7 of its window) acts" '[ "$(rowsof watch-build-stuck)" = 1 ]'
world; setting archie.watch.interval_min 30; alert "$ID_STUCK" "$L_STUCK" new 3720; NOW0=$NOW; NOW=$((NOW + 720)); tick; NOW=$NOW0
check "W-CADENCE interval_min 30 skips 07:27 (minute 27 of its window)" '[ "$(rows)" = 0 ]'
world; setting archie.watch.interval_min 5; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-CADENCE interval_min 5 is out of range: one warn line and the default 20 (07:15 skipped)" \
  '[ "$(rows)" = 0 ] && [ "$(wlog | grep -c "archie.watch.interval_min=5 is outside 10..1440")" = 1 ]'
world; unsetting archie.watch.interval_min; alert "$ID_STUCK" "$L_STUCK"; tick -- --dry-list
check "W-CADENCE --dry-list is not gated" 'grep -q "^build-stuck" "$T/out"'

# ── W-SESSION: the model-session gate (the operator, 2026-10-06) ─────────────────────
session_world() {
  world; mkdir -p "$H/catalog/prompts"; echo "watch checklist" > "$H/catalog/prompts/archie-watch.md"
  echo 'lane_role_model() { echo test-model; }' > "$T/fx-extra.sh"
  printf '%s\n' "FINDING: I1's metric is unreadable since 07:00Z." "CAUSE: unknown" "LEVER: probe the I1 metric source" "SAY: report" > "$T/session.answer"
}
sessrows() { jq '[.actions[] | select(.playbook == "watch-session")]' "$T/db.json"; }
session_world; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION a new finding: ONE session row (new key), one agent-call stage archie, one send on that key" \
  '[ "$(rowsof watch-session)" = 1 ] && [ "$(rowf watch-session dedupe_key)" = watch:session:new:20261005T0715:on ] && [ "$(rowf watch-session outcome)" = done ] && [ "$(nlines "$T/session.log")" = 1 ] && grep -q "^archie fleet test-model 300 LANE=archie FP=watch:session:new:20261005T0715:on$" "$T/session.log" && [ "$(cat "$T/tg.log")" = watch:session:new:20261005T0715:on ]'
check "W-SESSION the prompt is archie-watch.md plus this tick's findings" \
  'grep -q "watch checklist" "$T/session.prompt" && grep -q "^build-stuck" "$T/session.prompt"'
NOW0=$NOW; NOW=$((NOW + 600)); tick; NOW=$((NOW0 + 1100)); tick; NOW=$NOW0   # 1100: before fresh-lane passes cron_install_s
check "W-SESSION nothing new: one owed walk for the 06:00Z block, then nothing until the next block" \
  '[ "$(rowsof watch-session)" = 2 ] && [ "$(sessrows | jq -r ".[1].dedupe_key")" = watch:session:owed:20261005T06:on ] && [ "$(nlines "$T/session.log")" = 2 ]'
session_world; rm -f "$H/catalog/prompts/archie-watch.md"; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION no archie-watch.md (BH-4760): no session row, no call, one log line" \
  '[ "$(rowsof watch-session)" = 0 ] && [ ! -s "$T/session.log" ] && wlog | grep -q "archie-watch.md is absent"'
session_world; setting archie.cap.watch-session 0; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION archie.cap.watch-session=0: no session" '[ "$(rowsof watch-session)" = 0 ] && [ ! -s "$T/session.log" ]'
session_world; setting archie.cap.watch-session 1
jq --arg d 2026-10-05 '.actions += [{id: 99, dedupe_key: "watch:session:owed:20261005T03:on", playbook: "watch-session", mode: "on", outcome: "done", day: $d, project: "hub", repo: "example-org/cromford", pr: 0}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION the day cap counts sessions: cap 1 with one done today, no session" \
  '[ "$(rowsof watch-session)" = 1 ] && [ ! -s "$T/session.log" ]'
session_world; setting archie.manage observe; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION observe: one would_session row, no call" \
  '[ "$(rowf watch-session action)" = would_session ] && [ "$(rowf watch-session outcome)" = would ] && [ ! -s "$T/session.log" ]'
session_world; : > "$T/session.answer"; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION a blank answer is silence: row done, nothing sent" \
  '[ "$(rowf watch-session outcome)" = done ] && [ "$(nlines "$T/session.log")" = 1 ] && [ ! -s "$T/tg.log" ]'
session_world; echo NONE > "$T/session.answer"; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION a NONE answer (BH-4767): row done, one call, nothing sent" \
  '[ "$(rowf watch-session outcome)" = done ] && [ "$(nlines "$T/session.log")" = 1 ] && [ ! -s "$T/tg.log" ] && wlog | grep -q "no SAY: beat or report line"'
session_world
printf '%s\n' "FINDING: a stale WAIT_CI build was kicked and is green." "CAUSE: lane build-stuck" "LEVER: none, fixed" "SAY: none" \
  "The rule says SAY: beat only for stop-the-line." "SAY: beatnik" > "$T/session.answer"
alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION only SAY: none (and SAY: beat mid-line, SAY: beatnik) (BH-4767): row done, nothing sent" \
  '[ "$(rowf watch-session outcome)" = done ] && [ "$(nlines "$T/session.log")" = 1 ] && [ ! -s "$T/tg.log" ]'
session_world; printf '%s\n' "FINDING: main is red on cromford for 40 min." "CAUSE: lane main-red" "LEVER: probe the bisect" "SAY: beat " > "$T/session.answer"
alert "$ID_STUCK" "$L_STUCK"; tick
check "W-SESSION a SAY: beat line (trailing space) is sent once (BH-4767)" \
  '[ "$(rowf watch-session outcome)" = done ] && [ "$(cat "$T/tg.log")" = watch:session:new:20261005T0715:on ]'
session_world; alert "$ID_STUCK" "$L_STUCK"; tick -- --class build-stuck
check "W-SESSION a --class tick starts no session" '[ "$(rowsof watch-session)" = 0 ] && [ ! -s "$T/session.log" ]'

# ── W-OWED / W-METRIC: the two BH-4759 inputs, each recorded once ───────────
world
cat > "$T/STATE.md" <<'MD'
# STATE
## OWED TO OPERATOR
- BH-4093 restack report, expected-by 2026-10-05T06:00Z
- BH-4100 console fix, expected-by 2026-10-06T00:00Z
- BH-4101 no date on this one
## Notes
- unrelated item, expected-by 2026-10-01T00:00Z
OWED TO OPERATOR: the I1 metric query, expected by 2026-10-04
MD
tick
check "W-OWED two overdue OWED TO OPERATOR lines: two note rows, done; the future, undated and unrelated lines are not findings" \
  '[ "$(rowsof watch-owed-overdue)" = 2 ] && [ "$(jq "[.actions[] | select(.playbook == \"watch-owed-overdue\" and .action == \"note\" and .outcome == \"done\")] | length" "$T/db.json")" = 2 ] && jq -e "[.actions[] | select(.playbook == \"watch-owed-overdue\") | .evidence.line] | sort == [\"BH-4093 restack report, expected-by 2026-10-05T06:00Z\", \"OWED TO OPERATOR: the I1 metric query, expected by 2026-10-04\"]" "$T/db.json" >/dev/null'
NOW0=$NOW; NOW=$((NOW + 9000)); tick; NOW=$NOW0
check "W-OWED a later tick past escalate_s: still two rows, no ticket (a note is not escalated)" \
  '[ "$(rowsof watch-owed-overdue)" = 2 ] && [ "$(rowsof watch-ticket)" = 0 ]'
world
jq --arg a "$(iso $((NOW - 900)))" '.initiatives = [{id: 1, goal: "ship rate", status: "active", last_check_status: "unreadable", last_check_at: $a},
  {id: 2, goal: "cost", status: "active", last_check_status: "silent", last_check_at: $a}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick; tick
check "W-METRIC an unreadable initiative metric: ONE note row on I1 across two ticks, none for the readable one" \
  '[ "$(rowsof watch-metric-unreadable)" = 1 ] && [ "$(rowf watch-metric-unreadable evidence.incident)" = I1 ] && [ "$(rowf watch-metric-unreadable action)" = note ]'
world; touch "$T/initiatives.down"; tick
check "W-METRIC /api/initiatives down: no row, incomplete=1" '[ "$(rows)" = 0 ] && wlog | grep -q "metric sweep: GET /api/initiatives failed" && wlog | grep -q "incomplete=1"'

# ── W-LEVERS: each lever's exact call and its failure arm ────────────────────
world; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-LEVERS ack_alert: POST /api/alerts/actions {id, ack, archie-fm-watch, routing note} -> done" \
  'jq -e --arg i "$ID_STUCK" ".id == \$i and .action == \"ack\" and .actor == \"archie-fm-watch\" and (.note | test(\"blocked-resolver\"))" "$T/acks.log" >/dev/null && [ "$(rowf watch-build-stuck outcome)" = done ]'
world; alert "$ID_STUCK" "$L_STUCK" triaged; tick
check "W-LEVERS ack_alert on an already-triaged alert (409): done, the refusal kept" \
  '[ "$(rowf watch-build-stuck outcome)" = done ] && [ "$(rowf watch-build-stuck evidence.lever.refused)" = "disallowed edge" ]'
world; alert "$ID_STUCK" "$L_STUCK"; : > "$T/ack.gone"; tick
check "W-LEVERS ack_alert on an alert gone (404): failed 'alert gone', never done" \
  '[ "$(rowf watch-build-stuck outcome)" = failed ] && rowf watch-build-stuck why | grep -q "alert gone"'
world; alert "$ID_DW" "$L_DW"; echo 500 > "$T/rerun.status"; tick
check "W-LEVERS rerun_deploy: HTTP 500 -> failed with the status, never done" \
  '[ "$(rowf watch-deploy-drift outcome)" = failed ] && rowf watch-deploy-drift why | grep -q "HTTP 500" && [ "$(posts "repos/example-org/cromford/actions/runs/5551234/rerun-failed-jobs")" = 1 ]'
world; alert "$ID_DISK_HUB" "$L_DISK"; echo 3 > "$T/disk-clean.sh.rc"; tick
check "W-LEVERS run_cleanup: argv is bin/disk-clean.sh alone; rc 3 -> failed" \
  '[ "$(cat "$T/calls.log")" = "disk-clean.sh  RESCUE_ONLY=" ] && [ "$(rowf watch-disk outcome)" = failed ] && rowf watch-disk why | grep -q "exited 3"'
world; alert "$ID_RED" "$L_RED"; chmod -x "$H/bin/main-red-bisect.sh"; tick; settle 0
check "W-LEVERS kick_lane with the lane script missing: failed, nothing started" \
  '[ "$(rowf watch-main-red outcome)" = failed ] && [ "$(nlines "$T/calls.log")" = 0 ]'
world; alert "$ID_UTD" "$L_UTD"; : > "$T/bcc.down"; tick
check "W-LEVERS run_triage not queued (worker down): failed" '[ "$(rowf watch-triage-skip outcome)" = failed ]'
world; alert "$(alert_state_key "$L_IDLE")" "$L_IDLE"; echo 500 > "$T/issue.status"; tick
check "W-LEVERS file_ticket: HTTP 500 -> failed, never done" '[ "$(rowf watch-pool-idle outcome)" = failed ] && [ "$(posts "repos/example-org/cromford/issues ")" = 1 ]'
rm -f "$T/issue.status"; tick ARCHIE_FMW_NOW=$((NOW + 7300))
check "W-ESC a direct ticket that FAILED is retried once under watch-ticket after escalate_s" \
  '[ "$(rowf watch-ticket outcome)" = done ] && [ "$(posts "repos/example-org/cromford/issues ")" = 2 ]'
world; alert "$(alert_state_key "$L_IDLE")" "$L_IDLE"; tick; tick ARCHIE_FMW_NOW=$((NOW + 7300))
check "W-ESC a direct ticket that was filed is never escalated into a second one" \
  '[ "$(rowsof watch-ticket)" = 0 ] && [ "$(posts "repos/example-org/cromford/issues ")" = 1 ]'
world; alert "$ID_CPD" "$L_CPD"; tick
check "W-LEVERS consolepagesdrift with no cloudflare.env: a ticket, no deploy" \
  '[ "$(rowf watch-deploy-drift action)" = file_ticket ] && [ "$(ncalls console-pages-deploy.sh)" = 0 ]'
world; alert "$ID_CPD" "$L_CPD"; : > "$H/env/cloudflare.env"; tick; settle 1
check "W-LEVERS consolepagesdrift with cloudflare.env: bin/console-pages-deploy.sh started, requested" \
  '[ "$(rowf watch-deploy-drift action)" = rerun_deploy ] && [ "$(rowf watch-deploy-drift outcome)" = requested ] && [ "$(ncalls console-pages-deploy.sh)" = 1 ]'
world; alert "$ID_DISK_A" "[orchestrator/disk-guard] / at 91% on box-a." new 3600 box-a; tick
check "W-LEVERS disk on another box: ack, never disk-clean here" \
  '[ "$(rowf watch-disk action)" = ack_alert ] && [ "$(ncalls disk-clean.sh)" = 0 ]'

# ── W-STALE: a started row a killed tick left is closed failed, one alert ───
world; alert "$ID_STUCK" "$L_STUCK"
KEY="watch:build-stuck:$ID_STUCK@$((NOW - 3600)):ack_alert:on"
jq --arg k "$KEY" --arg t "$(iso $((NOW - 4000)))" '.actions += [{id: 1, dedupe_key: $k, day: "2026-10-05", project: "hub",
  repo: "example-org/cromford", pr: 0, playbook: "watch-build-stuck", mode: "on", action: "ack_alert", outcome: "started",
  why: "x", evidence: {}, attempts: 1, actor: "archie-fm-watch", created_at: $t, updated_at: $t}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
check "W-STALE a dead tick's started row: closed failed, ONE alert naming archie-fm-watch, the lever not re-pulled" \
  '[ "$(rowf watch-build-stuck outcome)" = failed ] && [ "$(nlines "$T/alerts.log")" = 1 ] && grep -q "^archie-fm-watch: " "$T/alerts.log" && grep -q "logs/archie-fm-watch.log" "$T/alerts.log" && ! grep -q "/pull/0" "$T/alerts.log" && [ "$(nlines "$T/acks.log")" = 0 ]'
world; : > "$T/archie.absent"; alert "$ID_STUCK" "$L_STUCK"; tick
check "W-STALE the ledger route absent: nothing done, one log line" \
  '[ "$(nlines "$T/acks.log")" = 0 ] && wlog | grep -q "archie_actions route absent"'
world; alert "$ID_STUCK" "$L_STUCK"; : > "$T/alerts.down"; tick
check "W-STALE the alerts read failing is incomplete, not 'no alerts'" \
  '[ "$(rows)" = 0 ] && wlog | grep -q "could not be read" && wlog | grep -q "incomplete=1"'

# ── W-DRY / W-CLASS: the documented flags, verbatim from the header ─────────
e2e_world; tick -- --dry-list; settle 0
check "W-DRY --dry-list prints the ten findings and writes nothing" \
  '[ "$(cat "$T/rc")" = 0 ] && [ "$(grep -c . "$T/out")" = 10 ] && [ "$(rows)" = 0 ] && [ "$(nlines "$T/calls.log")" = 0 ]'
e2e_world; tick -- --class disk
check "W-CLASS --class disk acts on disk only" '[ "$(rows)" = 1 ] && [ "$(rowsof watch-disk)" = 1 ]'
e2e_world; tick -- --class bogus
check "W-CLASS an unknown class is a usage error, nothing read" '[ "$(cat "$T/rc")" = 2 ] && [ ! -s "$T/reqlog" ]'

# ── across every case: the never-levers were never pulled ───────────────────
check "W-ALLOW across ALL cases: harness-ctl.sh, pause.sh, deploy-request.sh never called" \
  '! grep -qE "^(harness-ctl|pause|deploy-request)\.sh " "$T/calls-all.log"'
check "W-ALLOW across ALL cases: every GitHub write is an issue on example-org/cromford or the alert's own rerun" \
  '[ "$(grep -h "^POST\|^PATCH\|^PUT\|^DELETE" "$T"/ghrest-all.log | grep -vcE "^POST repos/example-org/cromford/(issues|actions/runs/5551234/rerun-failed-jobs) ")" = 0 ]'

# ── the cron line, the registry, scope ───────────────────────────────────────
check "cron: one hub-lease-gated 7-57/10 line for bin/archie-fm-watch.sh" \
  '[ "$(grep -c "^7-57/10 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/archie-fm-watch.sh >/dev/null 2>&1$" "$DIR/cron/lanes/727-archie-fm-watch.cron")" = 1 ]'
check "registry: hub lane, flag switch, seams not settable" \
  'jq -e ".scope == \"hub\" and .script == \"bin/archie-fm-watch.sh\" and .switch.name == \"lane-off-archie-fm-watch\" and ([.knobs[] | select(.env | test(\"^ARCHIE_FMW_(FIXTURE|NOW|HOST|TIMED|TICK_CEILING_S)$\")) | .settable] | all(. == false) and length == 5)" "$DIR/catalog/lanes.d/archie-fm-watch.json" >/dev/null'
check "W-STATIC no new file merges, pushes, unpauses or calls a model outside afw_session" \
  '[ "$(grep -nE "gh pr merge|git push|hold_push|bin/pause\.sh|harness-ctl|agent-call|claude " "$DIR/bin/archie-fm-watch.sh" "$DIR"/bin/lib/archie-fm-watch/*.sh | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#" | grep -vcE "/bin/lib/archie-fm-watch/common\.sh:[0-9]+:    \"\\\$r/bin/agent-call\.sh\" archie fleet ")" = 0 ]'
check "W-STATIC the ONE model call is afw_session's agent-call, stage archie" \
  '[ "$(sed -n "/^afw_session() {/,/^}/p" "$DIR/bin/lib/archie-fm-watch/common.sh" | grep -c "/bin/agent-call.sh\" archie fleet ")" = 1 ] && [ "$(grep -c "agent-call.sh\" " "$DIR"/bin/lib/archie-fm-watch/*.sh "$DIR/bin/archie-fm-watch.sh" | awk -F: "{n+=\$2} END {print n}")" = 1 ]'
check "W-STATIC no /root/harness default in the libs (D43)" '! grep -n "/root/harness" "$DIR"/bin/lib/archie-fm-watch/*.sh'

# ═════ X: mutations, each must turn its case red ═════════════════════════════
mutate() { # mutate <path> <python-expr over s>
  local rel="$1" lib="$H/$1"
  rm -f "$lib"
  python3 -c "import sys; s=open(sys.argv[1]).read(); $2; open(sys.argv[2],'w').write(s)" "$DIR/$rel" "$lib"
  chmod +x "$lib"
  cmp -s "$lib" "$DIR/$rel" && { echo "mutation did not change $rel"; return 1; }
  return 0
}
restore() { rm -f "$H/$1"; ln -s "$DIR/$1" "$H/$1"; }
C=bin/lib/archie-fm-watch/common.sh
if mutate "$C" 's=s.replace("    kick_lane)    afw_kick_lane \"$arg\" \"$p\" \"$c\" \"$inc\" ;;\n", "")'; then
  if q_e2e >/dev/null; then bad "X1 deleting the kick_lane arm must break W-E2E"; else ok "X1 RED: without the kick_lane arm W-E2E breaks"; fi
else bad "X1 mutation not applied"; fi
restore "$C"
if mutate "$C" 's=s.replace("    if [ \"$age\" -lt \"$esc\" ]; then AFW_N_SKIPPED=$((AFW_N_SKIPPED + 1)); return 0; fi\n", "")'; then
  esc_world; tick
  if [ "$(rowsof watch-ticket)" = 0 ]; then bad "X2 dropping the stale check must file a ticket on the next tick"; else ok "X2 RED: without the escalation stale check a ticket is filed at once"; fi
else bad "X2 mutation not applied"; fi
restore "$C"
if mutate "$C" 's=s.replace("if [ \"$used\" -ge \"$((10#$cap))\" ]; then", "if false; then")'; then
  if q_cap_one; then bad "X3 bypassing the cap must break W-CAP"; else ok "X3 RED: bypassing the cap breaks W-CAP"; fi
else bad "X3 mutation not applied"; fi
restore "$C"
B=bin/archie-fm-watch.sh
if mutate "$B" 's=s.replace("  rc=0; afw_handle \"$LINE\" \"$MODE\" || rc=$?\n", "  rc=0\n")'; then
  if q_e2e >/dev/null; then bad "X4 deleting the afw_handle call site must break W-E2E"; else ok "X4 RED: deleting the afw_handle call site breaks W-E2E"; fi
else bad "X4 mutation not applied"; fi
restore "$B"
S=bin/lib/archie-fm-watch/sources.sh
if mutate "$S" 's=s.replace("    stuck-work) printf build-stuck", "    stuck-work*) printf build-stuck")'; then
  world; alert "stuck-work-ledger" "STUCK-WORK ledger unreachable — 3 items past SLA unpaged"; tick
  if [ "$(rows)" = 0 ]; then bad "X5 a prefix match must make stuck-work-ledger a finding"; else ok "X5 RED: a prefix match on stuck-work acts on stuck-work-ledger"; fi
else bad "X5 mutation not applied"; fi
restore "$S"
L=bin/lib/archie-fm-watch/levers.sh
if mutate "$L" 's=s.replace("if [ \"$rc\" = 0 ] && [ \"$st\" = 201 ]; then AFW_OUT=requested; AFW_WHY=\"queued", "if true; then AFW_OUT=requested; AFW_WHY=\"queued")'; then
  world; alert "$ID_DW" "$L_DW"; echo 500 > "$T/rerun.status"; tick
  if [ "$(rowf watch-deploy-drift outcome)" = failed ]; then bad "X6 ignoring the HTTP code must record a 500 as requested"; else ok "X6 RED: without the 201 check a failed rerun is recorded requested"; fi
else bad "X6 mutation not applied"; fi
restore "$L"
if mutate "$L" 's=s.replace("      if [ \"$newest\" != \"$run\" ]; then", "      if false; then")'; then
  world; alert "$ID_DW" "$L_DW"; echo 5559999 > "$T/runs.newest"; echo "$MAINSHA" > "$T/runs.sha"; tick
  if [ "$(grep -c rerun-failed-jobs "$T/ghrest.log")" = 0 ]; then bad "X8 dropping the newest-run guard must re-run a superseded run"; else ok "X8 RED: without the newest-run guard a superseded run is re-run"; fi
else bad "X8 mutation not applied"; fi
restore "$L"
if mutate "$S" 's=s.replace("  [ \"$age\" -ge \"$need\" ] || return 0\n", "")'; then
  neg_world "$ID_STUCK" "$L_STUCK" new 300
  if [ "$(rows)" = 0 ]; then bad "X7 dropping the min-age gate must act on a young alert"; else ok "X7 RED: without the min-age gate a 5-minute-old alert is acted on"; fi
else bad "X7 mutation not applied"; fi
restore "$S"
check "X the restored files are the shipped ones" \
  '[ "$(readlink "$H/$C")" = "$DIR/$C" ] && [ "$(readlink "$H/$B")" = "$DIR/$B" ] && [ "$(readlink "$H/$S")" = "$DIR/$S" ] && [ "$(readlink "$H/$L")" = "$DIR/$L" ]'

# Nothing in any case reached the network, pushed, or deployed.
# (A curl GET of /api/settings is the jobs client's own source-time settings
# read, made before the fixture is loaded; it reaches nothing.)
check "W-ALLOW across ALL cases: no gh or wrangler call, no curl write, no git push" \
  '! grep -qE "^(gh|wrangler) " "$T/net.log" && ! grep -qE "^curl .*-X (POST|PUT|PATCH|DELETE)" "$T/net.log" && ! grep -q "^git push" "$T/git.log"'

echo "archie-fm-watch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
