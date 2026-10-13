#!/bin/bash
# tests/archie-fm-stack.bh-4784-test.sh — BH-4784: Archie's factory manager on
# a stack of THREE PRs, driven through the SHIPPED bin/archie-fm.sh, with the
# fixture shape of tests/archie-fm-tracer.bh-4583-test.sh (a real bare origin,
# a real hub clone, a jq model of the jobs worker, stubbed GitHub reads).
#
# THE WORLD (stack3): main <- ticket/bh-9001 (A, PR #1: "parent 1", "parent 2")
# <- ticket/bh-9002 (B, PR #2: "mid own") <- ticket/bh-9003 (C, PR #3: "grand
# own"). A is squash-merged into main, so B carries A's pre-squash commits and
# C carries A's and B's. archie.manage=on.
#
# The worker model ($T/fx.sh) answers what worker/jobs/src/routes/archie-actions.js
# answers (the real route is pinned by worker/jobs/test/archie-actions.bh-4784.test.js):
# GET by day and project, by repo+pr across days, count_by=action with its echo,
# and summary's no_local_suites. Markers: ledger.down (the repo/pr read is a
# 503), countby.absent (an older worker that ignores count_by).
#
# Cases: S1 three-PR stack (grandchild replayed from the ledger's fork point),
# S2 no recorded fork point (failed + ONE alert), S3 ledger unreadable
# (deferred), S4 the day cap counts by action, S4b an older worker, S5 the cap
# memo, S6 a push with no local suites (+ the digest line), S7 killed-tick
# recovery, S7b its refused push, X mutations.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-stack.bh-4784-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-stack: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-stack: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${ARCHIE_FM_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket changes (D41).
for f in "$DIR/bin/archie-fm.sh" "$DIR/bin/lib/archie-fm.sh" "$DIR/worker/jobs/src/routes/archie-actions.js" \
         "$DIR/bin/lib/daily-digest-render.sh"; do
  if [ -f "$f" ]; then ok "ships ${f#"$DIR"/}"; else bad "missing $f"; fi
done

NOW=1791184500                       # 2026-10-05T07:15:00Z
DAY=2026-10-05
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
       GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$T/home" "$T/tmp"

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
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
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/gh.log"
if [ "${1:-} ${2:-} ${3:-}" = "api -X PATCH" ] && [ "${5:-}" = -f ]; then
  [ -f "$FXT/patch.refuse" ] && exit 1
  n=${4##*/}; b=${6#base=}
  jq --argjson n "$n" --arg b "$b" 'map(if .number == $n then .base.ref = $b else . end)' "$FXT/prs.json" > "$FXT/prs.tmp" \
    && mv "$FXT/prs.tmp" "$FXT/prs.json"
  echo patch >> "$FXT/order.log"
  exit 0
fi
exit 1
SH
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

# The worker, modelled in jq over $T/db.json.
cat > "$T/fx.sh" <<'SH'
fx_clock() { date -u -d "@$ARCHIE_FM_NOW" +%Y-%m-%dT%H:%M:%SZ; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/flags*|/api/lanes*) JOBS_HTTP=404; return 2 ;; esac
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  t=$(fx_clock)
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
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
          (if .outcome == "deferred" and $b.outcome == "started" then .attempts += 1 else . end)
          | .outcome = $b.outcome | .action = ($b.action // .action) | .why = ($b.why // .why)
          | .evidence = ($b.evidence // .evidence) | .updated_at = $t else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db") ;;
    "GET /api/archie/actions")
      local d pb s cb pj rp pn; d=$(qp day); pb=$(qp playbook); s=$(qp summary); cb=$(qp count_by)
      pj=$(qp project); rp=$(qp repo); pn=$(qp pr)
      if [ -n "$rp$pn" ] && [ -f "$FXT/ledger.down" ]; then JOBS_HTTP=503; return 1; fi
      if [ -z "$d" ] && { [ -z "$rp" ] || [ -z "$pn" ]; }; then JOBS_HTTP=400; printf '{"error":"day"}'; return 1; fi
      [ -f "$FXT/countby.absent" ] && cb=""
      out=$(jq -c --arg d "$d" --arg pb "$pb" --arg s "$s" --arg cb "$cb" --arg pj "$pj" --arg rp "$rp" --arg pn "$pn" '
        [.actions[] | select(($d == "" or .day == $d) and ($pb == "" or .playbook == $pb) and ($pj == "" or .project == $pj)
           and ($rp == "" or .repo == $rp) and ($pn == "" or (.pr | tostring) == $pn))] | sort_by(.id) | reverse as $r
        | if $s == "1" then {ok: true, day: $d, total: ($r | length),
             restacked: ([$r[] | select(.mode == "on" and .action == "restack" and .outcome == "done")] | length),
             fix_rounds: ([$r[] | select(.outcome == "requested")] | length),
             would: ([$r[] | select(.outcome == "would")] | length),
             deferred: ([$r[] | select(.outcome == "deferred")] | length),
             failed: ([$r[] | select(.outcome == "failed")] | length),
             no_local_suites: ([$r[] | select(.mode == "on" and .action == "restack" and .outcome == "done" and .evidence.local_suites == false)] | length)}
          else {ok: true, day: $d, actions: $r,
             counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][if $cb == "action" then $x.action else $x.outcome end] += 1)),
             truncated: false} + (if $cb == "action" then {count_by: "action"} else {} end) end' "$db") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest_pr_list_var() {
  local v="$1" slug="$2" state="$3" head="${4:-}" out
  printf 'list %s %s %s\n' "$slug" "$state" "$head" >> "$FXT/ghrest.log"
  if [ -n "$head" ]; then
    out=$(jq -c --arg h "${head#*:}" --arg st "$state" '[.[] | select(.head.ref == $h and ($st == "all" or .state == $st))]' "$FXT/prs.json")
  else
    out=$(jq -c --arg st "$state" '[.[] | select(.state == $st)]' "$FXT/prs.json")
  fi
  printf -v "$v" '%s' "$out"; GH_REST_STATUS=200; return 0
}
mc_git_auth() { MC_REMOTE="file://$FXT/origin.git"; export MC_GIT_TOKEN=fixture-token GIT_ASKPASS=/nonexistent/askpass; return 0; }
mc_hold_keeps_pr() { return 1; }
. "$HARNESS/bin/lib/hold-push.sh"
hold_push_verdict() { printf 'clear\tfixture\n'; return 0; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
       MC_REPOS="$T/repos" MC_REHYDRATE=0 TMPDIR="$T/tmp"
unset ARCHIE_FM_ENABLED ARCHIE_FM_RETRY_S ARCHIE_FM_MAX_ATTEMPTS ARCHIE_FM_SUITE_TIMEOUT_S ARCHIE_FM_PROJECTS_PER_TICK \
  ARCHIE_FM_NOW ARCHIE_FM_FIXTURE ARCHIE_FM_TIMED ARCHIE_FM_DEADLINE ARCHIE_FM_TICK_CEILING_S ARCHIE_FM_SUITE_AS 2>/dev/null || true

G() { git -C "$T/work" "$@" >/dev/null 2>&1; }
# world [gate|nogate] — a fresh stack of three, db, PR list and harness state.
world() {
  local v="${1:-gate}" p
  for p in origin.git repos work mergework db.json reqlog gh.log ghrest.log order.log suites.log suite.rc alerts.log net.log \
           ledger.down countby.absent move.child patch.refuse out rc; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  scratch_rm "$H/logs/archie-fm.log" || exit 1; scratch_rm "$H/logs/merge-conductor.log" || exit 1
  mkdir -p "$T/work/src" "$T/work/bin" "$T/repos"
  git init -q -b main "$T/work"
  printf 'line one\nline two\n' > "$T/work/src/a.txt"
  if [ "$v" = gate ]; then
    { printf '#!/bin/bash\nFXT=%q\n' "$T"; cat <<'SH'; } > "$T/work/bin/test-impact-gate.sh"
echo "run $*" >> "$FXT/suites.log"
if [ -f "$FXT/move.child" ]; then
  d=$(mktemp -d)
  git clone -q "$FXT/origin.git" "$d" && git -C "$d" checkout -q ticket/bh-9002 \
    && echo moved > "$d/src/x.txt" && git -C "$d" add -A \
    && git -C "$d" -c user.name=someone -c user.email=someone@example.invalid commit -qm "someone else" \
    && git -C "$d" push -q origin ticket/bh-9002
  rm -rf "$d"
fi
exit "$(cat "$FXT/suite.rc" 2>/dev/null || echo 0)"
SH
    chmod +x "$T/work/bin/test-impact-gate.sh"
  else
    echo readme > "$T/work/README"
  fi
  G add -A; G commit -qm "base"
  G checkout -q -b ticket/bh-9001
  echo 1 > "$T/work/src/p.txt"; G add -A; G commit -qm "parent 1"
  echo 2 > "$T/work/src/p.txt"; G add -A; G commit -qm "parent 2"
  AHEAD=$(git -C "$T/work" rev-parse HEAD)
  G checkout -q -b ticket/bh-9002
  echo mid > "$T/work/src/m.txt"; G add -A; G commit -qm "mid own"
  BOLD=$(git -C "$T/work" rev-parse HEAD)
  G checkout -q -b ticket/bh-9003
  echo grand > "$T/work/src/g.txt"; G add -A; G commit -qm "grand own"
  COLD=$(git -C "$T/work" rev-parse HEAD)
  G checkout -q main
  G merge --squash ticket/bh-9001; G commit -qm "BH-9001 squash"
  git init -q --bare -b main "$T/origin.git"
  G push -q "$T/origin.git" main ticket/bh-9001 ticket/bh-9002 ticket/bh-9003
  printf '#!/bin/sh\necho push >> "%s/order.log"\n' "$T" > "$T/origin.git/hooks/post-receive"
  chmod +x "$T/origin.git/hooks/post-receive"
  git clone -q "$T/origin.git" "$T/repos/fixt"
  jq -n --arg a "$AHEAD" --arg b "$BOLD" --arg c "$COLD" '[
    {number: 2, state: "open", html_url: "https://github.com/acme/fixt/pull/2", merged_at: null,
     head: {ref: "ticket/bh-9002", sha: $b, repo: {full_name: "acme/fixt"}}, base: {ref: "ticket/bh-9001"}},
    {number: 3, state: "open", html_url: "https://github.com/acme/fixt/pull/3", merged_at: null,
     head: {ref: "ticket/bh-9003", sha: $c, repo: {full_name: "acme/fixt"}}, base: {ref: "ticket/bh-9002"}},
    {number: 1, state: "closed", html_url: "https://github.com/acme/fixt/pull/1", merged_at: "2026-10-05T06:00:00Z",
     head: {ref: "ticket/bh-9001", sha: $a, repo: {full_name: "acme/fixt"}}, base: {ref: "main"}}]' > "$T/prs.json"
  jq -n '{settings: {"archie.manage": "on", "archie.cap.stacked-parent-merged": "20"}, actions: []}' > "$T/db.json"
  : > "$T/reqlog"; : > "$T/gh.log"; : > "$T/order.log"; : > "$T/suites.log"
}
# merge_b: B's current origin head is squash-merged into main; PR #2 is merged.
merge_b() {
  git clone -q "$T/origin.git" "$T/mergework" \
    && git -C "$T/mergework" merge -q --squash origin/ticket/bh-9002 >/dev/null 2>&1 \
    && git -C "$T/mergework" commit -qm "BH-9002 squash" \
    && git -C "$T/mergework" push -q origin main
  scratch_rm "$T/mergework" || exit 1
  BNEW=$(oref ticket/bh-9002)
  jq --arg h "$BNEW" 'map(if .number == 2 then .state = "closed" | .merged_at = "2026-10-05T07:20:00Z" | .head.sha = $h else . end)' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  : > "$T/order.log"; : > "$T/gh.log"
}
# by_other: someone else (not Archie) replays B onto main by hand and pushes it.
by_other() {
  git clone -q "$T/origin.git" "$T/mergework" \
    && git -C "$T/mergework" checkout -q -B ticket/bh-9002 origin/main \
    && echo mid > "$T/mergework/src/m.txt" && git -C "$T/mergework" add -A \
    && git -C "$T/mergework" commit -qm "mid own (by hand)" \
    && git -C "$T/mergework" push -q -f origin ticket/bh-9002
  scratch_rm "$T/mergework" || exit 1
  jq 'map(if .number == 2 then .base.ref = "main" else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
seed() { # seed <pr> <mode> <action> <outcome> [evidence-json] [repo] [updated_at] [key]
  local ts="${7:-2026-10-05T01:00:00Z}" e="${5:-}"
  [ -n "$e" ] || e='{}'
  jq --arg d "$DAY" --argjson n "$1" --arg m "$2" --arg a "$3" --arg o "$4" --argjson e "$e" --arg r "${6:-acme/other}" \
     --arg ts "$ts" --arg k "${8:-}" \
    '.actions += [{id: ((.actions | length) + 1), dedupe_key: (if $k == "" then "seed:\($r)#\($n):\($m):\($a):\($o)" else $k end),
       day: $d, project: (if $r == "acme/fixt" then "fixt" else "other" end), repo: $r, pr: $n, playbook: "stacked-parent-merged",
       mode: $m, action: $a, outcome: $o, why: "seeded", evidence: $e, attempts: 1, actor: "archie-fm",
       created_at: $ts, updated_at: $ts}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
tick() { # tick [VAR=value ...]  — one tick of the shipped lane
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" ARCHIE_FM_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 ARCHIE_FM_SUITE_AS=self "$@" \
    bash "$H/bin/archie-fm.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rows()   { jq '.actions | length' "$T/db.json"; }
prow()   { jq -r --argjson n "$1" --arg f "$2" '[.actions[] | select(.pr == $n and .repo == "acme/fixt")] | last
             | if . == null then "null" else (getpath($f | split(".")) | if type == "string" then . else tojson end) end' "$T/db.json"; }
oref()   { git -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
pid_of() { git -C "$T/origin.git" show "$1" 2>/dev/null | git patch-id --stable | cut -d' ' -f1; }
basein() { jq -r --argjson n "$1" '.[] | select(.number == $n) | .base.ref' "$T/prs.json"; }
posts()  { grep -c '^POST /api/archie/actions ' "$T/reqlog"; }
closes() { grep -c '^POST /api/archie/actions/outcome ' "$T/reqlog"; }
alerts() { if [ -f "$T/alerts.log" ]; then wc -l < "$T/alerts.log" | tr -d ' '; else echo 0; fi; }
afmlog() { cat "$H/logs/archie-fm.log" 2>/dev/null; }

# ── bundles reused by the X mutations ────────────────────────────────────────
# s1_run: tick 1 restacks B, B squash-merges, tick 2 restacks C.
s1_run() {
  world gate; tick
  S1_B_ROW="$(prow 2 action)/$(prow 2 outcome)"; S1_CHILDREN=$(prow 2 evidence.children); S1_C_AFTER1=$(oref ticket/bh-9003)
  S1_C_BASE1=$(basein 3); S1_B_LOCAL=$(prow 2 evidence.local_suites)
  merge_b
  tick ARCHIE_FM_NOW=$((NOW + 600))
}
s1_replayed() {
  [ "$(prow 3 action)/$(prow 3 outcome)" = restack/done ] \
    && [ "$(git -C "$T/origin.git" rev-list --count main..ticket/bh-9003)" = 1 ] \
    && [ "$(pid_of ticket/bh-9003)" = "$(pid_of "$COLD")" ]
}
# s4_world <cap>: today's ledger holds 2 noops, 1 failed restack, 1 fix round.
s4_world() {
  world gate; setting archie.cap.stacked-parent-merged "$1"
  seed 7 on noop done; seed 8 on noop done; seed 9 on restack failed; seed 10 on fix_round requested
}
s4_capped() { [ "$(rows)" = 4 ] && [ "$(posts)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$BOLD" ] && afmlog | grep -q "cap reached (2 of 2 "; }
# s5_run: cap 1, already used, and THREE stuck children in one tick.
s5_run() {
  world gate; setting archie.cap.stacked-parent-merged 1; seed 7 on restack done
  jq '. + [range(4; 6) as $n | {number: $n, state: "open", html_url: "https://github.com/acme/fixt/pull/\($n)", merged_at: null,
       head: {ref: "ticket/bh-900\($n)", sha: ("\($n)" * 40), repo: {full_name: "acme/fixt"}}, base: {ref: "ticket/bh-9001"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  tick
}
s5_memo() { [ "$(grep -c 'count_by=action' "$T/reqlog")" = 1 ] && [ "$(afmlog | grep -c 'cap reached')" = 1 ]; }
# s7_world <outcome>: a tick retargeted #2 to main and was killed before its push.
s7_world() {
  world gate
  jq 'map(if .number == 2 then .base.ref = "main" else . end)' "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  seed 2 on restack "$1" "$(jq -nc --arg b "$BOLD" --arg a "$AHEAD" '{onto: "main", parent_head: $a, old_head: $b, parent_pr: 1,
      parent_url: "https://github.com/acme/fixt/pull/1", retarget: "main", conductor_state: "-", child_base: "ticket/bh-9001"}')" \
    acme/fixt "$(date -u -d "@$((NOW - 1860))" +%FT%TZ)" "stacked-parent-merged:acme/fixt#2:$BOLD:$AHEAD:on"
}
s7_run() {
  s7_world started
  tick
  S7_T1="$(prow 2 outcome)"
  tick ARCHIE_FM_NOW=$((NOW + 1800))
}
s7_recovered() {
  [ "$S7_T1" = deferred ] && [ "$(prow 2 outcome)" = done ] \
    && [ "$(git -C "$T/origin.git" rev-list --count main..ticket/bh-9002)" = 1 ] \
    && [ "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9002)" = "mid own" ]
}

# ── S1: a stack of three ─────────────────────────────────────────────────────
s1_run
eq "S1 tick 1: B is restacked" "$S1_B_ROW" restack/done
eq "S1 tick 1: B's row records its child and that child's head" "$S1_CHILDREN" "[{\"pr\":3,\"head\":\"$COLD\"}]"
check "S1 tick 1: the children are logged" 'afmlog | grep -qF "acme/fixt#3 is stacked on ticket/bh-9002; it replays from ${BOLD:0:12} when #2 merges"'
eq "S1 tick 1: C is untouched on origin" "$S1_C_AFTER1" "$COLD"
eq "S1 tick 1: C's base is still B's branch" "$S1_C_BASE1" ticket/bh-9002
check "S1 tick 2 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "S1 tick 2: C's row is restack/done, never noop ($(prow 3 why))" "$(prow 3 action)/$(prow 3 outcome)" restack/done
eq "S1 tick 2: the fork point is B's old head" "$(prow 3 evidence.fork_point)" "$BOLD"
eq "S1 tick 2: ...read from the ledger" "$(prow 3 evidence.fork_from)" ledger
eq "S1 tick 2: C on origin is main + exactly one commit" "$(git -C "$T/origin.git" rev-list --count main..ticket/bh-9003)" 1
eq "S1 tick 2: ...and it is grand own" "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9003)" "grand own"
eq "S1 tick 2: ...patch-id identical to C's own commit" "$(pid_of ticket/bh-9003)" "$(pid_of "$COLD")"
eq "S1 tick 2: C's base PATCHed to main before the push" "$(tr '\n' ' ' < "$T/order.log")" "patch push "
eq "S1 tick 2: the PATCH was pulls/3" "$(grep -c '^api -X PATCH repos/acme/fixt/pulls/3 -f base=main$' "$T/gh.log")" 1
eq "S1 tick 2: C's base is main" "$(basein 3)" main
eq "S1 no alerts" "$(alerts)" 0
eq "S1 a parent-head restack records fork_from parent_head" "$(jq -r '[.actions[] | select(.pr == 2)] | last | .evidence.fork_from' "$T/db.json")" parent_head

# ── S2: B restacked by someone else, no recorded fork point ─────────────────
world gate; by_other; merge_b
tick
eq "S2 C's row is restack/failed" "$(prow 3 action)/$(prow 3 outcome)" restack/failed
check "S2 ...why starts 'parent head not in child history' ($(prow 3 why))" '[[ "$(prow 3 why)" == "parent head not in child history"* ]]'
eq "S2 exactly ONE alert" "$(alerts)" 1
check "S2 the alert names the PR and the hand rebase ($(cat "$T/alerts.log" 2>/dev/null))" \
  'grep -qF "acme/fixt/pull/3" "$T/alerts.log" 2>/dev/null && grep -qF "git rebase --onto origin/main" "$T/alerts.log"'
check "S2 no push, no PATCH" '[ "$(oref ticket/bh-9003)" = "$COLD" ] && [ ! -s "$T/order.log" ] && ! grep -q PATCH "$T/gh.log"'
check "S2 the tick counts it failed ($(afmlog | tail -1))" 'afmlog | tail -1 | grep -q " failed=1 repaired=0$"'
: > "$T/reqlog"
tick ARCHIE_FM_NOW=$((NOW + 600))
check "S2 a second tick: no new alert, no new close" '[ "$(alerts)" = 1 ] && [ "$(closes)" = 0 ] && [ "$(prow 3 outcome)" = failed ]'

# ── S3: the ledger cannot be read ───────────────────────────────────────────
world gate; by_other; merge_b; : > "$T/ledger.down"
tick
eq "S3 C's row is deferred, not failed" "$(prow 3 outcome)" deferred
check "S3 ...the why names the ledger ($(prow 3 why))" '[[ "$(prow 3 why)" == *"ledger for #2 could not be read"* ]]'
eq "S3 no alert" "$(alerts)" 0
check "S3 no push, no PATCH" '[ "$(oref ticket/bh-9003)" = "$COLD" ] && [ ! -s "$T/order.log" ]'

# ── S4: the day cap counts by action ────────────────────────────────────────
s4_world 2
tick
check "S4 cap 2 with a failed restack and a fix round today: no claim, no write, 'cap reached (2 of 2' ($(afmlog | grep cap))" 's4_capped'
s4_world 3
tick
eq "S4 cap 3 with the same seed (the two noops uncounted): B is restacked" "$(prow 2 action)/$(prow 2 outcome)" restack/done
check "S4 the cap read asks for count_by=action" 'grep -q "^GET /api/archie/actions?day=$DAY&playbook=stacked-parent-merged&limit=1&count_by=action " "$T/reqlog"'

# ── S4b: an older worker that does not count by action ──────────────────────
world gate; : > "$T/countby.absent"
tick
check "S4b no row claimed, nothing pushed" '[ "$(rows)" = 0 ] && [ "$(posts)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$BOLD" ]'
check "S4b the log names it ($(afmlog | head -1))" 'afmlog | grep -q "does not count by action"'

# ── S5: the cap is memoized per tick ────────────────────────────────────────
s5_run
check "S5 three stuck children past the cap: ONE cap read ($(grep -c 'count_by=action' "$T/reqlog")) and ONE 'cap reached' line ($(afmlog | grep -c 'cap reached'))" 's5_memo'
check "S5 nothing claimed" '[ "$(posts)" = 0 ] && [ "$(rows)" = 1 ]'
check "S5 the end line counts them skipped ($(afmlog | tail -1))" 'afmlog | tail -1 | grep -q "stuck=3 .* skipped=3 failed=0 repaired=0$"'

# ── S6: a push with no local suites is on the row ───────────────────────────
world nogate
tick
eq "S6 restacked with no gate" "$(prow 2 action)/$(prow 2 outcome)" restack/done
eq "S6 evidence.local_suites is false" "$(prow 2 evidence.local_suites)" false
check "S6 evidence.suites says none ($(prow 2 evidence.suites))" '[[ "$(prow 2 evidence.suites)" == none* ]]'
check "S6 the log says CI is the gate" 'afmlog | grep -q "; no local suites ran, CI is the gate"'
eq "S6 with the gate present local_suites is true (S1 tick 1)" "$S1_B_LOCAL" true
SUMJ=$(ARCHIE_FM_NOW=$NOW FXT=$T bash -c ". '$T/fx.sh'; _jobs_req GET '/api/archie/actions?day=$DAY&summary=1'")
eq "S6 the summary counts it" "$(jq -r .no_local_suites <<<"$SUMJ")" 1
render() { bash -c ". '$DIR/bin/lib/daily-digest-render.sh'; dd_render '$1' https://console.test - 0 5 -" | grep '^Factory manager'; }
jq -n --arg d "$DAY" --argjson f "$SUMJ" '{day: $d, factory_manager: $f}' > "$T/dg1.json"
eq "S6 the digest line says it" "$(render "$T/dg1.json")" \
  "Factory manager: 1 actions (1 restacked, 0 repaired, 0 fix rounds asked, 0 would-do in observe, 0 deferred, 0 failed, 1 pushed with no local suites) https://console.test/"
TODAY_LINE="Factory manager: 1 actions (1 restacked, 0 repaired, 0 fix rounds asked, 0 would-do in observe, 0 deferred, 0 failed) https://console.test/"
jq -n --arg d "$DAY" --argjson f "$SUMJ" '{day: $d, factory_manager: ($f | .no_local_suites = 0)}' > "$T/dg0.json"
eq "S6 at 0 the line is today's, byte for byte" "$(render "$T/dg0.json")" "$TODAY_LINE"
jq -n --arg d "$DAY" --argjson f "$SUMJ" '{day: $d, factory_manager: ($f | del(.no_local_suites))}' > "$T/dgx.json"
eq "S6 without the field (an older worker) the line is today's" "$(render "$T/dgx.json")" "$TODAY_LINE"

# ── S7: a tick killed between the retarget and the push ─────────────────────
s7_run
eq "S7 tick 1: the stale started row is closed deferred" "$S7_T1" deferred
check "S7 tick 1: the log names the recovery" 'afmlog | grep -qF "acme/fixt#2: retargeted to main by a tick that died before its push; replaying it"'
check "S7 the previous UTC day is read too" 'grep -q "^GET /api/archie/actions?day=2026-10-04&project=fixt&playbook=stacked-parent-merged&limit=500 " "$T/reqlog"'
check "S7 tick 2: done, origin B is main + its own commit only ($(prow 2 outcome): $(prow 2 why))" 's7_recovered'
eq "S7 ...one row, reclaimed once" "$(rows)/$(prow 2 attempts)" 1/2
eq "S7 ...B's base is main" "$(basein 2)" main
eq "S7 no alerts" "$(alerts)" 0
s7_world requested
tick
tick ARCHIE_FM_NOW=$((NOW + 1800))
check "S7 control: a requested row is not recovered (no new POST, no push)" \
  '[ "$(prow 2 outcome)" = requested ] && [ "$(posts)" = 0 ] && [ "$(oref ticket/bh-9002)" = "$BOLD" ] && ! afmlog | grep -q "replaying it"'

# ── S7b: the recovery's push is refused ─────────────────────────────────────
s7_world started
tick
: > "$T/move.child"
tick ARCHIE_FM_NOW=$((NOW + 1800))
eq "S7b the row is deferred" "$(prow 2 outcome)" deferred
eq "S7b the base is put back on child_base" "$(basein 2)" ticket/bh-9001
check "S7b the other writer's commit stands" '[ "$(git -C "$T/origin.git" log -1 --format=%s ticket/bh-9002)" = "someone else" ]'

# ═════ X: mutations, each must turn its case red ═════════════════════════════
mutate() { # mutate <relative-path> <python-expr over s>
  rm -f "$H/$1"
  python3 -c "import sys; s=open(sys.argv[1]).read(); $2; open(sys.argv[2],'w').write(s)" "$DIR/$1" "$H/$1"
  cmp -s "$H/$1" "$DIR/$1" && { echo "mutation did not change $1"; return 1; }
  return 0
}
restore() { rm -f "$H/$1"; ln -s "$DIR/$1" "$H/$1"; }
L=bin/lib/archie-fm.sh
if command -v python3 >/dev/null 2>&1; then
  # X1: no fork-point read; a parent head outside the history is the old noop.
  if mutate "$L" 's=s.replace("afm_fork_point \"$slug\" \"$pn\" \"$wt\"; frc=$?", "frc=1")'; then
    s1_run
    if s1_replayed; then bad "X1 without the ledger fork point S1 must go red"; else ok "X1 RED: without the fork point the grandchild is not replayed"; fi
  else bad "X1 mutation not applied"; fi
  restore "$L"
  # X2: the cap back to outcomes done + requested.
  if mutate "$L" 's=s.replace("(.counts[$pb].on.restack // 0) + (.counts[$pb].on.repair // 0) + (.counts[$pb].on.fix_round // 0)", "(.counts[$pb].on.done // 0) + (.counts[$pb].on.requested // 0)")'; then
    s4_world 2; tick
    if s4_capped; then bad "X2 a cap by outcome must break S4"; else ok "X2 RED: a cap by outcome breaks S4"; fi
  else bad "X2 mutation not applied"; fi
  restore "$L"
  # X3: no memo.
  # TEST-CHANGE (BH-4927): the memo is per playbook now; the mutation removes
  # the same assignment in its new spelling.
  if mutate "$L" 's=s.replace("AFM_CAP_FULL=\"${AFM_CAP_FULL:+$AFM_CAP_FULL }$AFM_PLAYBOOK\"; return 1", "return 1")'; then
    s5_run
    if s5_memo; then bad "X3 without the memo S5 must go red"; else ok "X3 RED: without the memo the cap is read per PR"; fi
  else bad "X3 mutation not applied"; fi
  restore "$L"
  # X4: the driver no longer tries the recovery on an unclassified PR.
  if mutate bin/archie-fm.sh 's=s.replace("[ \"$rc\" = 1 ] && afm_recover_classify \"$pr\"", "false")'; then
    s7_run
    if s7_recovered; then bad "X4 without the recovery classify S7 must go red"; else ok "X4 RED: without the recovery the killed tick's PR is stranded"; fi
  else bad "X4 mutation not applied"; fi
  restore bin/archie-fm.sh
  check "X the restored files are the shipped ones" '[ "$(readlink "$H/$L")" = "$DIR/$L" ] && [ "$(readlink "$H/bin/archie-fm.sh")" = "$DIR/bin/archie-fm.sh" ]'
else
  bad "X python3 is required for the mutations"
fi

echo "archie-fm-stack: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
