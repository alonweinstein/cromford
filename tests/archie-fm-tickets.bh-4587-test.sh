#!/bin/bash
# tests/archie-fm-tickets.bh-4587-test.sh — BH-4587 (BH-4574.5): Archie's
# self-improvement loop, driven through the SHIPPED bin/archie-fm-improve.sh
# (the ticket's archie-fm-tickets-test, keyed to the ticket per house rule).
#
# THE WORLD. A scratch $HARNESS with the lane's closure (scratch_install_closure)
# and the harness repo acme/fixt-harness. Every input row is written by the REAL
# writer, wave 2's afq_claim/afq_close, against the model below (D4/D63), with
# the dedupe keys and evidence shapes waves 1-4 write.
#
# WHAT IS STUBBED, and only this. ARCHIE_FMI_FIXTURE=$T/fx.sh (sandbox-only):
#   _jobs_req   a jq model of /api/settings/<key> and the three
#               /api/archie/actions routes (day, playbook, limit, truncated via
#               $T/trunc.<day>, dedupe_key). The worker side runs for real in
#               worker/jobs/test/archie-actions.bh-4587.test.js.
#   gh_rest     a stateful model of the GitHub REST calls ($T/gh.json): the
#               issue lists, POST issues, comments, PATCH, timeline. Every call
#               is logged to $T/ghrest.log.
# $H/bin stubs: alert-line.sh and archie-tg-send.sh log. PATH stubs git, gh and
# curl log to $T/forbidden.log and fail (E-NOWRITE: the lane never writes a fix).
#
# Cases: F-CAUSE, F-NEG, T-THREE, E-LOG, T-FOURTH, T-DIFF, T-BODY,
# T-DEDUPE-OPEN, T-DEDUPE-OWN / M-NOTPLANNED, T-OBS, T-CAP, T-KNOB, T-READFAIL,
# T-POSTFAIL, T-CRASH, M-TRACK, M-REOPEN, M-GRACE, M-VERIFY, M-AFTERVERIFY,
# M-VERIFYFAIL, M-REOPENCAP, T-LBLCAP, M-NOVERIFY-INCOMPLETE, E-OFF, E-LOCK, E-ROUTE404, E-DRY, D-SECTION, D-EMPTY,
# D-UNREADABLE, D-LEARN, E-NOWRITE.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-tickets.bh-4587-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-tickets: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-tickets: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${ARCHIE_FMI_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-fm-improve.sh" "$DIR/bin/lib/archie-fm-improve/common.sh" \
         "$DIR/bin/lib/archie-fm-improve/tickets.sh" "$DIR/worker/jobs/src/routes/archie-actions.js" \
         "$DIR/worker/jobs/schema.d/0020-bh-4587-archie-improve.sql" "$DIR/bin/archie-learn.sh" \
         "$DIR/catalog/lanes.d/archie-fm-improve.json" "$DIR/cron/lanes/729-archie-fm-improve.cron"; do
  if [ -f "$f" ]; then ok "ships ${f#"$DIR"/}"; else bad "missing $f"; fi
done
if [ ! -f "$DIR/bin/archie-fm-improve.sh" ]; then
  echo "archie-fm-tickets: $PASS passed, $FAIL failed"; exit 1
fi

D=86400
NOW0=1791720000                      # Sun 2026-10-11T12:00:00Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
fp() { printf '%s' "$1" | sha1sum | cut -c1-12; }
CAUSE_DISK="watch|disk|hub|run_cleanup"
FP_DISK=$(fp "$CAUSE_DISK")

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/env" "$T/fakebin" "$T/tmp" "$T/home"
scratch_install_closure bin/archie-fm-improve.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/archie-learn.sh "$H" >/dev/null || exit 1
# The closure scan does not follow `. "$SELF/jobs-client.sh"`; the client and its modules go in by their own closure.
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
: > "$H/env/global.env"
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$2" > "$FXT/tg.txt"
SH
chmod +x "$H/bin/alert-line.sh" "$H/bin/archie-tg-send.sh"
for s in git gh curl; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$FXT/forbidden.log"\nexit 1\n' "$s" > "$T/fakebin/$s"
done
chmod +x "$T/fakebin/"*

cat > "$T/fx.sh" <<'SH'
fx_now() { printf '%s' "${FXNOW:-${ARCHIE_FMI_NOW:-${ARCHIE_NOW:-0}}}"; }
fx_clock() { date -u -d "@$(fx_now)" +%Y-%m-%dT%H:%M:%SZ; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t
  JOBS_HTTP=""; JOBS_BODY=""
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s\n' "$m" "$p" >> "$FXT/reqlog"
  t=$(fx_clock)
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
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
           | ["started>done","started>requested","started>would","started>deferred","started>failed","started>skipped","deferred>started","deferred>failed"]
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
      local d pb k lim; d=$(qp day); pb=$(qp playbook); k=$(qp dedupe_key); lim=$(qp limit)
      if [ -n "$k" ]; then
        k=$(printf '%b' "${k//%/\\x}")
        out=$(jq -c --arg k "$k" '.actions[] | select(.dedupe_key == $k) | {action: .}' "$db")
        [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"archie action not found"}'; return 2; }
      else
        out=$(jq -c --arg d "$d" --arg pb "$pb" --argjson l "${lim:-100}" --argjson tr "$([ -f "$FXT/trunc.$d" ] && echo true || echo false)" \
          '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] | sort_by(.created_at, .id) | reverse as $r
          | {ok: true, day: $d, actions: $r[0:$l],
             counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][$x.outcome] += 1)), truncated: ($tr or ($r | length) > $l)}' "$db")
      fi ;;
    *) JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest() {
  local m="$1" p="$2" a title="" body="" labels="[]" sv="" st n c gh="$FXT/gh.json"
  shift 2
  printf '%s %s %s\n' "$m" "$p" "$*" >> "$FXT/ghrest.log"
  printf '%s %s\n' "$m" "$p" >> "$FXT/ghrest-all.log"
  for a in "$@"; do
    case "$a" in
      title=*) title=${a#title=} ;;
      body=@*) body=$(cat "${a#body=@}") ;;
      labels\[\]=*) labels=$(jq -c --arg l "${a#labels[]=}" '. + [$l]' <<<"$labels") ;;
      state=*) sv=${a#state=} ;;
    esac
  done
  case "$m $p" in
    GET\ repos/acme/fixt-harness/issues\?*)
      [ -f "$FXT/issues.down" ] && { GH_REST_STATUS=500; return 75; }
      case "$p" in *labels=archie-fm-improve*) [ -f "$FXT/lbl.down" ] && { GH_REST_STATUS=500; return 75; } ;; esac
      n=$(printf '%s' "$p" | sed -n 's/.*[?&]page=\([0-9]*\).*/\1/p')
      GH_REST_STATUS=200
      [ "$n" = 1 ] || { echo '[]'; return 0; }
      case "$p" in
        *labels=archie-fm-improve*state=all*) jq -c '[.issues[] | select(any(.labels[]; .name == "archie-fm-improve"))]' "$gh" ;;
        *state=open*) jq -c '[.issues[] | select(.state == "open")]' "$gh" ;;
        *) echo '[]' ;;
      esac
      return 0 ;;
    "POST repos/acme/fixt-harness/issues")
      GH_REST_STATUS=$(cat "$FXT/issue.status" 2>/dev/null || echo 201)
      case "$GH_REST_STATUS" in 2*) ;; *) return 75 ;; esac
      n=$(jq '[.issues[].number] | (max // 9000) + 1' "$gh")
      [ "$n" -gt 9000 ] || n=9001
      jq --argjson n "$n" --arg t "$title" --arg b "$body" --argjson l "$labels" --arg c "$(fx_clock)" \
        '.issues += [{number: $n, title: $t, body: $b, state: "open", state_reason: null, created_at: $c, closed_at: null,
          html_url: ("https://github.com/acme/fixt-harness/issues/" + ($n | tostring)), labels: ($l | map({name: .}))}]' "$gh" > "$gh.tmp" && mv "$gh.tmp" "$gh"
      printf '%s\n' "$body" > "$FXT/issue-body.$n"
      jq -c --argjson n "$n" '.issues[] | select(.number == $n) | {number, html_url}' "$gh"; return 0 ;;
    POST\ repos/acme/fixt-harness/issues/*/comments)
      n=${p#repos/acme/fixt-harness/issues/}; n=${n%/comments}
      GH_REST_STATUS=$(cat "$FXT/comment.status" 2>/dev/null || echo 201)
      case "$GH_REST_STATUS" in 2*) ;; *) return 75 ;; esac
      c=$(( $(cat "$FXT/ncomments" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$FXT/ncomments"
      { printf '#%s\n' "$n"; printf '%s\n' "$body"; } > "$FXT/comment.$c"
      jq -nc --argjson c "$c" --arg n "$n" '{id: (500 + $c), html_url: ("https://github.com/acme/fixt-harness/issues/" + $n + "#issuecomment-" + ($c | tostring))}'
      return 0 ;;
    PATCH\ repos/acme/fixt-harness/issues/*)
      n=${p##*/}
      GH_REST_STATUS=$(cat "$FXT/patch.status" 2>/dev/null || echo 200)
      case "$GH_REST_STATUS" in 2*) ;; *) return 75 ;; esac
      jq --argjson n "$n" --arg s "$sv" '.issues |= map(if .number == $n then .state = $s
          | (if $s == "open" then .state_reason = "reopened" | .closed_at = null else . end) else . end)' "$gh" > "$gh.tmp" && mv "$gh.tmp" "$gh"
      jq -c --argjson n "$n" '.issues[] | select(.number == $n) | {number, state}' "$gh"; return 0 ;;
    GET\ repos/acme/fixt-harness/issues/*/timeline\?*)
      n=${p#repos/acme/fixt-harness/issues/}; n=${n%%/*}
      [ -f "$FXT/timeline.down" ] && { GH_REST_STATUS=502; return 75; }
      GH_REST_STATUS=200; cat "$FXT/timeline.$n" 2>/dev/null || echo '[]'; return 0 ;;
  esac
  GH_REST_STATUS=404; return 44
}
:
SH

# The REAL writer: wave 2's afq_claim (and afq_close), one process per batch.
# A line: epoch \t playbook \t key \t project \t repo \t pr \t mode \t action \t why \t evidence \t final-outcome|-
cat > "$T/writer.sh" <<'SH'
#!/bin/bash
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null
. "$HARNESS/bin/lib/archie-fm.sh" || exit 1
. "$HARNESS/bin/lib/archie-fm-queue/common.sh" || exit 1
. "$FXT/fx.sh"
AFQ_RETRY_S=1800; AFM_LOG=""
while IFS=$'\t' read -r e pb key p repo n mode act why ev fin; do
  FXNOW=$e; NOW=$e
  case "$pb" in watch-*) AFQ_ACTOR=archie-fm-watch ;; queue-*) AFQ_ACTOR=archie-fm-queue ;; improve) AFQ_ACTOR=archie-fm-improve ;; *) AFQ_ACTOR=archie-fm ;; esac
  afq_claim "$pb" "$key" "$p" "$repo" "$n" "$mode" "$act" "$why" "$ev" || { echo "writer: claim of $key failed" >&2; exit 1; }
  if [ "$mode" = on ] && [ "$fin" != - ]; then afq_close "$pb" "$fin" "" "" "" || { echo "writer: close of $key failed" >&2; exit 1; }; fi
done
SH
chmod +x "$T/writer.sh"

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
       TMPDIR="$T/tmp" HOME="$T/home" HARNESS_REPO=acme/fixt-harness JOBS_SETTINGS_CACHE_S=0 LANE_GATE_DISABLE=1
unset HARNESS_ENV_DIR ARCHIE_FMI_ENABLED ARCHIE_FMI_RETRY_S ARCHIE_FMI_NOW ARCHIE_FMI_FIXTURE ARCHIE_FMI_TIMED 2>/dev/null || true

WQ=""   # the writer batch
wq() { local IFS=$'\t'; WQ+="$*"$'\n'; }
wflush() { [ -n "$WQ" ] || return 0; printf '%s' "$WQ" | bash "$T/writer.sh" || bad "the writer failed"; WQ=""; }
# inc <epoch> <class> <incident> <project> [mode] — a watch-<class> row exactly
#   as afw_handle writes it: key watch:<class>:<incident>:<lever>:<mode>.
inc() {
  local e="$1" c="$2" i="$3" p="$4" mode="${5:-on}" lever act out
  case "$c" in disk) lever=run_cleanup ;; pool-idle) lever=file_ticket ;; main-red) lever=kick_lane ;; *) lever=ack_alert ;; esac
  act=$lever; out=done; [ "$mode" = on ] || { act="would_$lever"; out=-; }
  wq "$e" "watch-$c" "watch:$c:$i:$lever:$mode" "$p" acme/fixt-harness 0 "$mode" "$act" "disk, tmpfs or inodes over threshold on $p" \
     "$(jq -nc --arg i "$i" --arg c "$c" '{source: "alert", alert_id: $i, class: $c, incident: $i, subject: $i}')" "$out"
}
disk3() { # disk3 <project> <first-epoch> — three distinct incidents, an hour apart
  local p="$1" e="$2" k
  for k in 0 1 2; do inc $((e + k * 3600)) disk "disk-high-$p@$((e + k * 3600))" "$p"; done
}
world() {
  local p
  for p in db.json gh.json reqlog ghrest.log alerts.log out rc tg.txt ncomments issue.status comment.status patch.status \
           lbl.down issues.down count.down archie.absent timeline.down; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/issue-body.* "$T"/comment.[0-9]* "$T"/trunc.* "$T"/timeline.[0-9]*
  scratch_rm "$H/logs/archie-fm-improve.log" || exit 1
  jq -n '{settings: {"archie.manage": "on"}, actions: []}' > "$T/db.json"
  jq -n '{issues: []}' > "$T/gh.json"
  : > "$T/reqlog"; : > "$T/ghrest.log"; : > "$T/alerts.log"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
tick() { # tick <now> [VAR=value ...] — one tick of the shipped lane
  local now="$1"; shift
  wflush
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FMI_NOW="$now" ARCHIE_FMI_FIXTURE="$T/fx.sh" "$@" \
    bash "$H/bin/archie-fm-improve.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
section() { # section <now> <from-iso> <to-iso>
  wflush
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FMI_NOW="$1" ARCHIE_FMI_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-improve.sh" section "$2" "$3" 2>&1
}
gh_issue() { # gh_issue <n> <state> <reason|null> <body> <labels-json> [created-epoch] [closed-epoch]
  jq --argjson n "$1" --arg s "$2" --arg r "$3" --arg b "$4" --argjson l "$5" --arg c "$(iso "${6:-$((NOW0 - D))}")" \
     --arg cl "$([ -n "${7:-}" ] && iso "$7")" \
    '.issues += [{number: $n, title: "x", body: $b, state: $s, state_reason: (if $r == "null" then null else $r end),
      created_at: $c, closed_at: (if $cl == "" then null else $cl end),
      html_url: ("https://github.com/acme/fixt-harness/issues/" + ($n | tostring)), labels: ($l | map({name: .}))}]' \
    "$T/gh.json" > "$T/gh.tmp" && mv "$T/gh.tmp" "$T/gh.json"
}
gh_close() { # gh_close <n> <reason> <epoch>
  jq --argjson n "$1" --arg r "$2" --arg c "$(iso "$3")" '.issues |= map(if .number == $n
      then .state = "closed" | .state_reason = $r | .closed_at = $c else . end)' "$T/gh.json" > "$T/gh.tmp" && mv "$T/gh.tmp" "$T/gh.json"
}
xref() { # xref <pr> <repo> <merged-epoch|null> — one timeline event
  jq -nc --argjson n "$1" --arg r "$2" --arg m "$([ "$3" = null ] || iso "$3")" \
    '{event: "cross-referenced", source: {type: "issue", issue: {number: $n, html_url: ("https://github.com/" + $r + "/pull/" + ($n | tostring)),
      repository: {full_name: $r}, pull_request: {merged_at: (if $m == "" then null else $m end)}}}}'
}
imp()     { jq -c '[.actions[] | select(.playbook == "improve")]' "$T/db.json"; }
nimp()    { imp | jq length; }
impf()    { imp | jq -r --arg a "$1" --arg f "$2" '[.[] | select(.action == $a)] | last | getpath($f | split(".")) // "null" | tostring'; }
nact()    { imp | jq --arg a "$1" '[.[] | select(.action == $a)] | length'; }
ngh()     { grep -cE "$1" "$T/ghrest.log" 2>/dev/null; }
nissues() { ngh '^POST repos/acme/fixt-harness/issues '; }
ncomm()   { ngh '^POST repos/acme/fixt-harness/issues/[0-9]+/comments '; }
npatch()  { ngh '^PATCH '; }
ilog()    { cat "$H/logs/archie-fm-improve.log" 2>/dev/null; }
lastlog() { tail -1 "$H/logs/archie-fm-improve.log" 2>/dev/null | cut -d' ' -f2-; }
row_by_key() { jq -c --arg k "$1" '.actions[] | select(.dedupe_key == $k)' "$T/db.json"; }
cause_of() { bash -c '. "$1/bin/lib/archie-fm-improve/common.sh"; afi_cause "$2"' _ "$H" "$1"; }
fp_of()    { bash -c '. "$1/bin/lib/archie-fm-improve/common.sh"; afi_fp "$2"' _ "$H" "$1"; }

# ═════ F-CAUSE: one row per playbook, written by the real writer ══════════════
world
E=$((NOW0 - 3600))
inc "$E" disk disk-high-hubbox@1 hub
inc "$E" disk disk-high-hubbox@1 hub observe
wq "$E" stacked-parent-merged "stacked-parent-merged:acme/fixt#12:aaaa111:bbbb222:on" fixt acme/fixt 12 on restack "stacked on #11, which merged" '{"parent":11}' done
wq "$E" rebase-repair "rebase-repair:acme/fixt#41:3f2a9c1d0e:on" fixt acme/fixt 41 on repair "park" \
   '{"park_reason":"Conflict in bin/x.sh at 3f2a9c1d0e after #4512, try 3","park_since":"2026-10-10T00:00:00Z","old_head":"3f2a9c1d0e","onto":"main"}' done
wq "$E" queue-culprit "queue-culprit:acme/other#51:block:cccc333:900:on" other acme/other 51 on block_verdict "reproduces" \
   '{"head":"cccc333","main":"dddd444","suites":["tests/b-test.sh","tests/a-test.sh"],"draft":900,"run":null}' done
wq "$E" queue-enqueue "queue-enqueue:acme/fixt#7:eeee555:on" fixt acme/fixt 7 on enqueue "enqueued" '{}' done
wq "$E" data-lane "data-lane:acme/fixt#8:ffff666:on" fixt acme/fixt 8 on apply "apply" '{}' failed
wq "$E" queue-reconcile "queue-reconcile:acme/fixt#9:settle:abab777:on" fixt acme/fixt 9 on settle_merged "settle" '{}' done
wflush
eq "F-CAUSE watch: class, project and the lever" "$(cause_of "$(row_by_key watch:disk:disk-high-hubbox@1:run_cleanup:on)")" "$CAUSE_DISK"
eq "F-CAUSE watch observe: would_ stripped, the same cause" "$(cause_of "$(row_by_key watch:disk:disk-high-hubbox@1:run_cleanup:observe)")" "$CAUSE_DISK"
eq "F-CAUSE the same row in on and observe has the same fp" \
  "$(fp_of "$(cause_of "$(row_by_key watch:disk:disk-high-hubbox@1:run_cleanup:observe)")")" "$FP_DISK"
eq "F-CAUSE stacked-parent-merged: the repo" "$(cause_of "$(row_by_key "stacked-parent-merged:acme/fixt#12:aaaa111:bbbb222:on")")" "stacked-parent-merged|acme/fixt"
eq "F-CAUSE rebase-repair: the normalised park reason" "$(cause_of "$(row_by_key "rebase-repair:acme/fixt#41:3f2a9c1d0e:on")")" \
  "rebase-repair|acme/fixt|conflict in bin/x.sh at <sha> after #N, try N"
eq "F-CAUSE queue-culprit: the suites, sorted" "$(cause_of "$(row_by_key "queue-culprit:acme/other#51:block:cccc333:900:on")")" \
  "queue-culprit|acme/other|tests/a-test.sh,tests/b-test.sh"
eq "F-CAUSE queue-enqueue: the repo" "$(cause_of "$(row_by_key "queue-enqueue:acme/fixt#7:eeee555:on")")" "queue-enqueue|acme/fixt"
eq "F-CAUSE data-lane: the action" "$(cause_of "$(row_by_key "data-lane:acme/fixt#8:ffff666:on")")" "data-lane|acme/fixt|apply"
eq "F-CAUSE queue-reconcile: the action" "$(cause_of "$(row_by_key "queue-reconcile:acme/fixt#9:settle:abab777:on")")" "queue-reconcile|acme/fixt|settle_merged"
eq "F-CAUSE fp is the first 12 hex of sha1(cause)" "$(fp_of "$CAUSE_DISK")" "$FP_DISK"

# ═════ F-NEG: the adversarial negatives file nothing ══════════════════════════
world
inc $((NOW0 - 3 * D)) disk A hub; inc $((NOW0 - 3 * D + 60)) disk A hub observe       # one incident, on + observe
wq $((NOW0 - D)) watch-ticket "watch:ticket:disk:A:on" hub acme/fixt-harness 0 on file_ticket "still open" '{"class":"disk"}' done
inc $((NOW0 - 2 * D)) disk B hub                                                      # 2 occurrences in all
for k in 1 2 3; do
  wq $((NOW0 - k * 3600)) watch-session "watch:session:new:2026101$k:on" hub acme/fixt-harness 0 on session "model session" '{}' done
  wq $((NOW0 - k * 3600)) queue-solo "queue-solo:acme/fixt#5:h$k:main:fp:on" fixt acme/fixt 5 on solo_run "solo" '{}' done
  wq $((NOW0 - k * 3600)) data-lane "data-lane:acme/fixt#6:h$k:on" fixt acme/fixt 6 on apply "apply" '{}' done
  wq $((NOW0 - k * 3600)) queue-enqueue "queue-enqueue:acme/fixt#7:h$k:on" fixt acme/fixt 7 on enqueue "not ready" '{}' skipped
  inc $((NOW0 - k * 3600)) pool-idle "fly-idle-$k" "p$k"                                # one class, three projects
  wq $((NOW0 - k * 3600)) improve "improve:comment:ffffffffffff:1:2026-10-1$k:on" hub acme/fixt-harness 0 on comment "earlier" '{"fp":"ffffffffffff","issue":1}' done
done
inc $((NOW0 - 8 * D - 3600)) main-red red1 hub; inc $((NOW0 - 2 * D)) main-red red2 hub; inc $((NOW0 - D)) main-red red3 hub
tick "$NOW0"
eq "F-NEG rc" "$(cat "$T/rc")" 0
eq "F-NEG no issue filed" "$(nissues)" 0
eq "F-NEG no improve row beyond the three seeded" "$(nimp)" 3
eq "F-NEG no comment, no PATCH" "$(ncomm)$(npatch)" 00
check "F-NEG the tick read the rows ($(head -c 300 "$T/out"))" 'grep -q "GET /api/archie/actions?day=2026-10-11&limit=500" "$T/reqlog"'

# ═════ T-THREE, E-LOG, T-DEDUPE-OWN round trip, T-FOURTH ═════════════════════
world
disk3 hub $((NOW0 - 3 * D))
tick "$NOW0"
eq "T-THREE rc" "$(cat "$T/rc")" 0
eq "T-THREE exactly one POST issues" "$(nissues)" 1
check "T-THREE labels ai-build and archie-fm-improve" 'grep "^POST repos/acme/fixt-harness/issues " "$T/ghrest.log" | grep -q "labels\[\]=ai-build" && grep "^POST repos/acme/fixt-harness/issues " "$T/ghrest.log" | grep -q "labels\[\]=archie-fm-improve"'
eq "T-THREE one improve row, file_ticket" "$(nimp) $(impf file_ticket outcome)" "1 done"
eq "T-THREE the row carries the html_url" "$(impf file_ticket evidence.issue_url)" "https://github.com/acme/fixt-harness/issues/9001"
eq "T-THREE the row carries the fp" "$(impf file_ticket evidence.fp)" "$FP_DISK"
eq "T-THREE the row is pr 0 on the harness repo" "$(impf file_ticket pr) $(impf file_ticket repo)" "0 acme/fixt-harness"
eq "E-LOG the summary line" "$(lastlog)" "fps=1 recurring=1 filed=1 commented=0 reopened=0 tracked=0 verified=0 would=0 capped=0 skipped=0 failed=0 incomplete=0"
check "T-BODY the issue body carries the marker" 'grep -qF "<!-- archie-fm-improve:fp=$FP_DISK -->" "$T/issue-body.9001"'
tick $((NOW0 + 600))
eq "T-DEDUPE-OWN the filed body read back from the label list: no second POST" "$(nissues)" 1
eq "T-DEDUPE-OWN and no comment (nothing new)" "$(ncomm)" 0
inc $((NOW0 + 1200)) disk "disk-high-hub@4th" hub
tick $((NOW0 + 3600))
eq "T-FOURTH one comment" "$(ncomm)" 1
eq "T-FOURTH no new issue" "$(nissues)" 1
check "T-FOURTH the comment names the 4th incident" 'grep -qF "watch:disk:disk-high-hub@4th:run_cleanup" "$T/comment.1" && head -1 "$T/comment.1" | grep -qx "#9001"'
check "T-FOURTH the comment does not repeat the first three" '! grep -qF "disk-high-hub@$((NOW0 - 3 * D))" "$T/comment.1"'
eq "T-FOURTH the comment row" "$(impf comment outcome) $(impf comment evidence.count)" "done 1"
inc $((NOW0 + 4000)) disk "disk-high-hub@5th" hub
tick $((NOW0 + 7200))
eq "T-FOURTH a 5th the same day: no second comment" "$(ncomm)" 1
tick $((NOW0 + D))
eq "T-FOURTH the next day: one comment" "$(ncomm)" 2
check "T-FOURTH it lists the 5th and not the 4th" 'grep -qF "disk-high-hub@5th" "$T/comment.2" && ! grep -qF "disk-high-hub@4th" "$T/comment.2"'
eq "T-FOURTH still one issue" "$(nissues)" 1

# ═════ T-DIFF, T-BODY ════════════════════════════════════════════════════════
world
for k in 1 2 3; do
  wq $((NOW0 - k * D)) rebase-repair "rebase-repair:acme/fixt#4$k:a1b2c3d$k:on" fixt acme/fixt "4$k" on repair "the park cleared after a rebase" \
     "$(jq -nc --arg r "Conflict in bin/x.sh at a1b2c3d$k after #45$k" '{park_reason: $r, park_since: "2026-10-01T00:00:00Z", old_head: "a1b2c3d", onto: "main"}')" done
  wq $((NOW0 - k * D)) queue-culprit "queue-culprit:acme/other#5$k:block:c0ffee$k:90$k:on" other acme/other "5$k" on block_verdict "reproduces alone" \
     "$(jq -nc --arg o "$([ "$k" = 2 ] && echo '["tests/b-test.sh","tests/a-test.sh"]' || echo '["tests/a-test.sh","tests/b-test.sh"]')" \
        '{head: "c0ffee", main: "d00d", suites: ($o | fromjson), draft: 900, run: null}')" done
done
tick "$NOW0"
CR="rebase-repair|acme/fixt|conflict in bin/x.sh at <sha> after #N"
CQ="queue-culprit|acme/other|tests/a-test.sh,tests/b-test.sh"
eq "T-DIFF two causes, two POSTs" "$(nissues)" 2
check "T-DIFF two different fp markers" 'grep -qF "fp=$(fp "$CR") -->" "$T/issue-body.9001" "$T/issue-body.9002" && grep -qF "fp=$(fp "$CQ") -->" "$T/issue-body.9001" "$T/issue-body.9002"'
RB=$(grep -lF "fp=$(fp "$CR") -->" "$T"/issue-body.900* | head -1)
check "T-BODY the cause line" 'grep -qxF "Cause: \`$CR\`" "$RB"'
check "T-BODY three occurrence lines" '[ "$(grep -c "^- .* rebase-repair \`rebase-repair:acme/fixt#4" "$RB")" = 3 ]'
check "T-BODY a PR link for a pr>0 row" 'grep -qF "https://github.com/acme/fixt/pull/41" "$RB"'
check "T-BODY the hand fix: action, outcome and why" 'grep -qF "The fix Archie applied by hand: repair -> done: the park cleared after a rebase" "$RB"'
check "T-BODY an Acceptance tests heading" 'grep -qx "## Acceptance tests" "$RB"'
check "T-BODY the acceptance test names the fp and the playbook" 'grep -qF "$(fp "$CR")" "$RB" && grep -qF "playbook \`rebase-repair\`" "$RB"'
check "T-BODY no em dash" '! grep -q "—" "$RB"'

# ═════ T-DEDUPE-OPEN ═════════════════════════════════════════════════════════
world
disk3 hub $((NOW0 - 2 * D))
gh_issue 500 open null "Someone else saw this. $(printf '<!-- archie-fm-improve:fp=%s -->' "$FP_DISK")" '[]'
tick "$NOW0"
eq "T-DEDUPE-OPEN an open issue with the marker: no POST" "$(nissues)" 0
eq "T-DEDUPE-OPEN the row is done, already filed" "$(impf file_ticket outcome)|$(impf file_ticket why)" "done|already filed: https://github.com/acme/fixt-harness/issues/500"
tick $((NOW0 + D))
eq "T-DEDUPE-OPEN the next day: the ledger row dedupes, no POST and no new row" "$(nissues) $(nimp)" "0 1"
world
disk3 hub $((NOW0 - 2 * D))
gh_issue 501 open null "We keep seeing watch|disk|hub|run_cleanup on the hub." '["bug"]'
tick "$NOW0"
eq "T-DEDUPE-OPEN a human issue quoting the cause with no marker is not a dedupe hit" "$(nissues)" 1

# T-DEDUPE-OWN with the ledger row aged out: only the label list (state=all)
# remembers the filing, a closed not_planned issue of Archie's from 30 days ago.
world
disk3 hub $((NOW0 - 2 * D))
gh_issue 8800 closed not_planned "$(printf 'Cause: `%s`\n\n<!-- archie-fm-improve:fp=%s -->' "$CAUSE_DISK" "$FP_DISK")" \
  '["ai-build","archie-fm-improve"]' $((NOW0 - 30 * D)) $((NOW0 - 29 * D))
tick "$NOW0"
eq "T-DEDUPE-OWN an old closed not_planned filing in the label list: no POST, no reopen, no row" "$(nissues) $(npatch) $(ncomm) $(nimp)" "0 0 0 0"

# An Archie issue closed completed with no closed_at: unreadable, skipped. Never
# read as today (GNU date -d "" answers today's 00:00Z), so no track and no reopen.
world
disk3 hub $((NOW0 - 2 * D))
gh_issue 8801 closed completed "$(printf '<!-- archie-fm-improve:fp=%s -->' "$FP_DISK")" '["ai-build","archie-fm-improve"]' $((NOW0 - 3 * D))
tick "$NOW0"
eq "M-NOCLOSEDAT closed completed with closed_at null: no row, no reopen" "$(nimp) $(npatch) $(ncomm)" "0 0 0"
check "M-NOCLOSEDAT one log line" 'ilog | grep -q "#8801: closed_at .* is unreadable; skipped"'

# ═════ T-OBS ═════════════════════════════════════════════════════════════════
world
setting archie.manage observe
disk3 hub $((NOW0 - 2 * D))
tick "$NOW0"
eq "T-OBS a would_file_ticket row" "$(impf would_file_ticket outcome) $(impf would_file_ticket mode)" "would observe"
eq "T-OBS no GitHub write" "$(ngh '^(POST|PATCH) ')" 0
check "T-OBS the lists were still read" 'grep -q "^GET repos/acme/fixt-harness/issues?labels=archie-fm-improve" "$T/ghrest.log"'
setting archie.manage.hub on
tick $((NOW0 + 60))
eq "T-OBS archie.manage.hub=on wins over archie.manage=observe" "$(nissues)" 1

# ═════ T-CAP ═════════════════════════════════════════════════════════════════
world
for p in p1 p2 p3 p4 p5 p6; do disk3 "$p" $((NOW0 - 3 * D)); done
tick "$NOW0"
eq "T-CAP six recurring causes, tickets_per_day 3: three POSTs" "$(nissues)" 3
check "T-CAP the summary says capped=3 ($(lastlog))" 'lastlog | grep -q " capped=3 "'
tick $((NOW0 + 3600))
eq "T-CAP a later tick the same day: still three" "$(nissues)" 3
tick $((NOW0 + D))
eq "T-CAP the next day: the other three" "$(nissues)" 6
world
setting archie.cap.improve 0
disk3 hub $((NOW0 - 2 * D))
tick "$NOW0"
eq "T-CAP archie.cap.improve=0: none" "$(nissues) $(nimp)" "0 0"
world
setting archie.cap.improve 2
for p in p1 p2 p3; do disk3 "$p" $((NOW0 - 3 * D)); done
tick "$NOW0"
eq "T-CAP archie.cap.improve=2 caps the writes of the day" "$(nissues)" 2

# ═════ T-KNOB ════════════════════════════════════════════════════════════════
world
setting archie.improve.recur_n 4
disk3 hub $((NOW0 - 2 * D))
tick "$NOW0"
eq "T-KNOB recur_n=4: three occurrences file nothing" "$(nissues) $(nimp)" "0 0"
world
setting archie.improve.recur_n junk
disk3 hub $((NOW0 - 2 * D))
tick "$NOW0"
eq "T-KNOB recur_n=junk: nothing filed, no row" "$(nissues) $(nimp)" "0 0"
eq "T-KNOB recur_n=junk: one log line naming it" "$(ilog | grep -c "archie.improve.recur_n='junk'")" 1
world
setting archie.improve.window_days 2
disk3 hub $((NOW0 - 3 * D))
tick "$NOW0"
eq "T-KNOB window_days=2: the incidents three days ago are outside the window" "$(nissues)" 0

# ═════ T-READFAIL ════════════════════════════════════════════════════════════
world
disk3 hub $((NOW0 - 2 * D))
: > "$T/lbl.down"
tick "$NOW0"
eq "T-READFAIL the label list answers 500: no claim, no POST" "$(nissues) $(nimp)" "0 0"
check "T-READFAIL one log line" 'ilog | grep -q "the lbl issue list of acme/fixt-harness could not be read"'

# ═════ T-POSTFAIL / T-CRASH ══════════════════════════════════════════════════
world
disk3 hub $((NOW0 - 2 * D))
echo 422 > "$T/issue.status"
tick "$NOW0"
eq "T-POSTFAIL POST answers 422: the row is failed" "$(impf file_ticket outcome)" failed
check "T-POSTFAIL the why names the status" 'impf file_ticket why | grep -q "HTTP 422"'
rm -f "$T/issue.status"
tick $((NOW0 + 3600))
eq "T-POSTFAIL the same day: no second POST" "$(nissues)" 1
tick $((NOW0 + D))
eq "T-POSTFAIL the next UTC day: retried and filed" "$(nissues) $(imp | jq -r '[.[] | select(.outcome == "done")] | length')" "2 1"
world
disk3 hub $((NOW0 - 2 * D))
gh_issue 9001 open null "$(printf 'Cause: `%s`\n\n<!-- archie-fm-improve:fp=%s -->' "$CAUSE_DISK" "$FP_DISK")" '["ai-build","archie-fm-improve"]' $((NOW0 - 7200))
wq $((NOW0 - 7200)) improve "improve:ticket:$FP_DISK:2026-10-11:on" hub acme/fixt-harness 0 on file_ticket "x recurred" "{\"fp\":\"$FP_DISK\"}" -
tick "$NOW0"
eq "T-CRASH a started row and the issue already on GitHub: no second POST" "$(nissues)" 0
eq "T-CRASH the stale started row is closed failed" "$(impf file_ticket outcome)" failed
eq "T-CRASH with one alert" "$(grep -c "archie-fm-improve: acme/fixt-harness#0 improve action improve:ticket:$FP_DISK" "$T/alerts.log")" 1

# ═════ M: track, reopen, grace, verify ═══════════════════════════════════════
filed_world() { # three incidents, one issue #9001 filed at NOW0
  world
  disk3 hub $((NOW0 - 3 * D))
  tick "$NOW0"
  [ "$(nissues)" = 1 ] || bad "filed_world: the issue was not filed"
  : > "$T/ghrest.log"
}
C=$((NOW0 + 7200))
filed_world
gh_close 9001 completed "$C"
{ xref 78 acme/fixt-harness null; xref 77 acme/fixt-harness $((C - 600)); xref 79 acme/elsewhere $((C - 60)); } | jq -s . > "$T/timeline.9001"
tick $((C + 1800))
eq "M-TRACK one track_merged row" "$(nact track_merged) $(impf track_merged outcome)" "1 done"
eq "M-TRACK the merged PR of the same repo" "$(impf track_merged evidence.pr) $(impf track_merged evidence.pr_url)" "77 https://github.com/acme/fixt-harness/pull/77"
eq "M-TRACK closed_at and before=3" "$(impf track_merged evidence.closed_at) $(impf track_merged evidence.before) $(impf track_merged evidence.before_complete)" "$(iso "$C") 3 true"
eq "M-TRACK no reopen, no comment" "$(npatch) $(ncomm)" "0 0"
tick $((C + 2400))
eq "M-TRACK a second tick: still one track row, one timeline read" "$(nact track_merged) $(ngh '/timeline')" "1 1"
inc $((C + 7200)) disk "disk-high-hub@after" hub
tick $((C + 7800))
eq "M-REOPEN one comment and one PATCH" "$(ncomm) $(npatch)" "1 1"
check "M-REOPEN the comment comes BEFORE the PATCH" '[ "$(grep -nE "^POST repos/acme/fixt-harness/issues/9001/comments " "$T/ghrest.log" | cut -d: -f1)" -lt "$(grep -n "^PATCH repos/acme/fixt-harness/issues/9001 " "$T/ghrest.log" | cut -d: -f1)" ]'
check "M-REOPEN the PATCH asks for state open" 'grep -q "^PATCH repos/acme/fixt-harness/issues/9001 -f state=open" "$T/ghrest.log"'
check "M-REOPEN the comment lists the new occurrence" 'grep -qF "disk-high-hub@after" "$T/comment.1"'
eq "M-REOPEN the issue is open again" "$(jq -r '.issues[] | select(.number == 9001) | .state' "$T/gh.json")" open
eq "M-REOPEN the reopen row" "$(impf reopen outcome) $(impf reopen evidence.after)" "done 1"
S=$(section $((C + 7900)) 2026-10-05T00:00:00Z 2026-10-11T23:59:59Z)
check "D-SECTION a reopened fix ($S)" 'grep -q "^- watch|disk|hub|run_cleanup: .*after 1; reopened$" <<<"$S"'

filed_world
gh_close 9001 completed "$C"
inc $((C + 1800)) disk "disk-high-hub@lag" hub
tick $((C + 2400))
eq "M-GRACE an occurrence 30 min after the close: no reopen" "$(npatch) $(ncomm)" "0 0"

filed_world
gh_close 9001 completed "$C"
echo '[]' > "$T/timeline.9001"
tick $((C + 1800))
tick $((C + 6 * D))
eq "M-VERIFY day 6: not verified yet" "$(nact verified)" 0
eq "M-VERIFY no merged PR found: track row with pr null" "$(impf track_merged evidence.pr)" null
tick $((C + 8 * D))
eq "M-VERIFY day 8, 0 occurrences, reads complete: one verified row" "$(nact verified) $(impf verified outcome)" "1 done"
eq "M-VERIFY before 3, after 0" "$(impf verified evidence.before) $(impf verified evidence.after)" "3 0"
eq "M-VERIFY one comment, no PATCH" "$(ncomm) $(npatch)" "1 0"
check "M-VERIFY the comment gives both counts" 'grep -qF "happened 3 times in the 7 days before this closed, and 0 times in the 7 days since" "$T/comment.1"'
S=$(section $((C + 8 * D + 60)) 2026-10-05T00:00:00Z 2026-10-11T23:59:59Z)
eq "D-SECTION the header" "$(head -1 <<<"$S")" "Factory fixes shipped: 1"
eq "D-SECTION the line: links, counts, verified" "$(sed -n 2p <<<"$S")" \
  "- watch|disk|hub|run_cleanup: issue https://github.com/acme/fixt-harness/issues/9001, closed, no merged PR found; before 3, after 0; verified"
tick $((C + 8 * D + 600))
eq "M-VERIFY a later tick: still one verified row and one comment" "$(nact verified) $(ncomm)" "1 1"
inc $((C + 8 * D + 3600)) disk "disk-high-hub@v1" hub
tick $((C + 8 * D + 7200))
eq "M-AFTERVERIFY one occurrence after verified: no reopen" "$(npatch)" 0
inc $((C + 8 * D + 7300)) disk "disk-high-hub@v2" hub
inc $((C + 8 * D + 7400)) disk "disk-high-hub@v3" hub
tick $((C + 8 * D + 9000))
eq "M-AFTERVERIFY recur_n after verified: reopen" "$(npatch)" 1

# A verify comment that fails on day 8 is retried on day 9 under a new day key.
posted() { cat "$T/ncomments" 2>/dev/null || echo 0; }
filed_world
gh_close 9001 completed "$C"
echo '[]' > "$T/timeline.9001"
tick $((C + 1800))
echo 500 > "$T/comment.status"
tick $((C + 8 * D))
eq "M-VERIFYFAIL day 8, the comment answers 500: one failed verified row, nothing posted" "$(nact verified) $(impf verified outcome) $(posted)" "1 failed 0"
scratch_rm "$T/comment.status" || exit 1
tick $((C + 8 * D + 600))
eq "M-VERIFYFAIL later the same day: the day key is taken, no new POST" "$(nact verified) $(ncomm)" "1 1"
tick $((C + 9 * D))
eq "M-VERIFYFAIL day 9: one done verified row and one comment posted" \
  "$(imp | jq '[.[] | select(.action == "verified" and .outcome == "done")] | length') $(posted)" "1 1"
tick $((C + 9 * D + 600))
eq "M-VERIFYFAIL a later tick: still one comment posted, no new POST" "$(posted) $(ncomm)" "1 2"

# A reopen is two GitHub writes (comment + PATCH) against archie.cap.improve.
# The day's filing used 1; a cap of 2 leaves room for 1, so no reopen.
filed_world
gh_close 9001 completed "$C"
echo '[]' > "$T/timeline.9001"
setting archie.cap.improve 2
inc $((C + 7200)) disk "disk-high-hub@cap" hub
tick $((C + 7800))
eq "M-REOPENCAP cap 2 with 1 used: no comment, no PATCH" "$(ncomm) $(npatch)" "0 0"
check "M-REOPENCAP the summary says capped=1 ($(lastlog))" 'lastlog | grep -q " capped=1 "'
# A failed PATCH after the evidence comment posted still counts its comment.
setting archie.cap.improve 3
echo 500 > "$T/patch.status"
tick $((C + 8400))
eq "M-REOPENCAP cap 3: the comment posts, the PATCH fails" "$(ncomm) $(npatch) $(impf reopen outcome) $(impf reopen evidence.comment_posted)" "1 1 failed true"
scratch_rm "$T/patch.status" || exit 1
setting archie.cap.improve 2
for k in 0 1 2; do inc $((C + 8500 + k * 60)) pool-idle "fly-idle-cap$k" pc; done
tick $((C + 9000))
eq "M-REOPENCAP 1 filing + 1 posted comment = 2 of cap 2: no new issue" "$(nissues)" 0
setting archie.cap.improve 3
tick $((C + 9600))
eq "M-REOPENCAP cap 3: the new cause is filed" "$(nissues)" 1

# The label list over its page cap: no claim, and ONE ALERTS line a day.
filed_world
printf '. "%s/fx.sh"\nAFI_LBL_PAGES=0\n' "$T" > "$T/fx-lblcap.sh"
for _lc in "$H/state"/archie-fm-improve.list-cap-*; do [ -e "$_lc" ] || continue; scratch_rm "$_lc" || exit 1; done
disk3 hub $((NOW0 + 3600))
tick $((NOW0 + 4 * 3600)) ARCHIE_FMI_FIXTURE="$T/fx-lblcap.sh"
tick $((NOW0 + 5 * 3600)) ARCHIE_FMI_FIXTURE="$T/fx-lblcap.sh"
eq "T-LBLCAP no claim and no GitHub write" "$(nissues) $(ncomm)" "0 0"
eq "T-LBLCAP two ticks, one ALERTS line" "$(grep -c 'archie-fm-improve: the lbl issue list of acme/fixt-harness is longer than 0 pages' "$T/alerts.log")" 1

filed_world
gh_close 9001 completed "$C"
: > "$T/trunc.$(date -u -d "@$((C + 3 * D))" +%F)"
tick $((C + 8 * D))
eq "M-NOVERIFY-INCOMPLETE a truncated day: no verified row" "$(nact verified) $(ncomm)" "0 0"
check "M-NOVERIFY-INCOMPLETE the summary says incomplete=1 ($(lastlog))" 'lastlog | grep -q "incomplete=1$"'

filed_world
gh_close 9001 not_planned "$C"
for k in 1 2 3; do inc $((C + k * 7200)) disk "disk-high-hub@np$k" hub; done
tick $((C + 4 * 7200))
eq "M-NOTPLANNED / T-DEDUPE-OWN closed not_planned + 3 new: no reopen, no POST, no comment" "$(npatch) $(nissues) $(ncomm)" "0 0 0"

# ═════ D-SECTION with a merged PR, D-LEARN ═══════════════════════════════════
world
T1=$((NOW0 - 6 * D))                       # Mon 2026-10-05T12:00:00Z
disk3 hub "$T1"
tick $((T1 + 3 * 3600))
C2=$((NOW0 - 5 * D))
gh_close 9001 completed "$C2"
xref 77 acme/fixt-harness $((C2 - 600)) | jq -s . > "$T/timeline.9001"
tick $((C2 + 1800))
S=$(section $((NOW0 + 60)) 2026-10-05T00:00:00Z 2026-10-11T23:59:59Z)
eq "D-SECTION a merged fix, still in its verify window" "$(sed -n 2p <<<"$S")" \
  "- watch|disk|hub|run_cleanup: issue https://github.com/acme/fixt-harness/issues/9001, fix https://github.com/acme/fixt-harness/pull/77; before 3, after 0; watching"
eq "D-SECTION another week: none" "$(section $((NOW0 + 60)) 2026-09-28T00:00:00Z 2026-10-04T23:59:59Z)" "Factory fixes shipped: none this week"
MON=$((NOW0 + 66900))                      # Mon 2026-10-12T06:35:00Z: the report covers 2026-W41
mkdir -p "$T/orc" "$T/src" "$T/tx"
LEARN() { env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$MON" ARCHIE_FMI_NOW="$MON" ARCHIE_FMI_FIXTURE="$T/fx.sh" ARCHIE_LEARN_FIXTURE="$T/fx.sh" \
  ARCHIE_ORC_DIR="$T/orc" ARCHIE_SKILLS_SRC="$T/src" ARCHIE_TRANSCRIPTS_DIR="$T/tx" bash "$H/bin/archie-learn.sh" report >/dev/null 2>&1; }
LEARN
check "D-LEARN the weekly report carries the section ($(head -c 600 "$T/tg.txt" 2>/dev/null))" \
  'grep -qx "Factory fixes shipped: 1" "$T/tg.txt" && grep -qF "fix https://github.com/acme/fixt-harness/pull/77; before 3, after 0; watching" "$T/tg.txt"'
scratch_rm "$H/state/archie-learn" || exit 1; scratch_rm "$T/tg.txt" || exit 1
mv "$H/bin/archie-fm-improve.sh" "$T/afi.bak"
LEARN
mv "$T/afi.bak" "$H/bin/archie-fm-improve.sh"
check "D-LEARN the lane absent: not measured, never a silent gap" 'grep -qx "Factory fixes shipped: not measured (bin/archie-fm-improve.sh section rc=127)" "$T/tg.txt"'
world
eq "D-EMPTY no rows" "$(section "$NOW0" 2026-10-05T00:00:00Z 2026-10-11T23:59:59Z)" "Factory fixes shipped: none this week"
: > "$T/count.down"
check "D-UNREADABLE not measured" '[ "$(section "$NOW0" 2026-10-05T00:00:00Z 2026-10-11T23:59:59Z)" = "Factory fixes shipped: not measured (the archie_actions rows of 2026-10-05 could not be read)" ]'
check "D-UNREADABLE junk dates" 'section "$NOW0" junk 2026-10-11T23:59:59Z | grep -q "^Factory fixes shipped: not measured"'

# ═════ E: switches, lock, route, dry list ════════════════════════════════════
world
disk3 hub $((NOW0 - 2 * D))
wflush; : > "$T/reqlog"
setting archie.manage off
tick "$NOW0"
eq "E-OFF archie.manage=off: no actions read, no row, no GitHub call" "$(grep -c archie/actions "$T/reqlog") $(nimp) $(grep -c . "$T/ghrest.log")" "0 0 0"
setting archie.manage on
: > "$T/reqlog"
tick "$NOW0" ARCHIE_FMI_ENABLED=0
eq "E-OFF ARCHIE_FMI_ENABLED=0: nothing read at all" "$(grep -c . "$T/reqlog") $(nimp)" "0 0"
exec 8>"$H/locks/archie-fm-improve.lock"; flock -n 8
tick "$NOW0"
flock -u 8; exec 8>&-
eq "E-LOCK the lock is held: rc 0, no actions read, no row" "$(cat "$T/rc") $(grep -c archie/actions "$T/reqlog") $(nimp)" "0 0 0"
env HARNESS_TEST_SANDBOX=1 ARCHIE_FMI_NOW="$NOW0" ARCHIE_FMI_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-improve.sh" --dry-list > "$T/out" 2>&1
eq "E-DRY one line per fp, nothing written" "$(cat "$T/out")|$(nimp)|$(ngh '^(POST|PATCH) ')" "$FP_DISK	3	recurring	$CAUSE_DISK|0|0"
: > "$T/archie.absent"; : > "$T/ghrest.log"
tick "$NOW0"
eq "E-ROUTE404 no row and no GitHub call" "$(nimp) $(grep -c . "$T/ghrest.log")" "0 0"
check "E-ROUTE404 one log line" '[ "$(ilog | grep -c "route absent")" = 1 ]'

# ═════ E-NOWRITE: never git, gh, curl or a pulls write, across the whole suite ═
check "E-NOWRITE no git, gh or curl call ($(head -3 "$T/forbidden.log" 2>/dev/null))" '[ ! -s "$T/forbidden.log" ]'
check "E-NOWRITE no pulls call and no write outside issues, across the whole suite" '! grep -q "pulls" "$T/ghrest-all.log" && ! grep -E "^(POST|PATCH|PUT|DELETE) " "$T/ghrest-all.log" | grep -vqE "^(POST|PATCH) repos/acme/fixt-harness/issues(/[0-9]+(/comments)?)?$"'

echo "archie-fm-tickets: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
