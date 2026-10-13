#!/bin/bash
# tests/archie-fm-data-lane.bh-4927-test.sh — BH-4927 (BH-4920.4): Archie's
# second playbook, data-lane, driven through the SHIPPED bin/archie-fm.sh tick
# (the ticket's tests/archie-fm-data-lane.bh-4920-test.sh, keyed to the
# building ticket per house rule).
#
# THE WORLD. A scratch harness ($T/h, bin/ symlinked from the repo) with one
# project `fixt` -> acme/fixt (a second, `fixu`, for the per-tick cap). PR 7 is
# an open harness-branch PR on main whose build record
# ($H/builds/fixt-BH-1-202610060000) has RESULT `PR_CREATED <url>`, a review.md
# that BLOCKed only on its unapplied migration and names it on a DATA_LANE
# line, and review-head = the PR head. PR 8 is an ordinary open PR with no
# record (it must cost no file-list read).
#
# WHAT IS STUBBED, and only this. ARCHIE_FM_FIXTURE=$T/fx.sh (sandbox-only):
#   _jobs_req             a jq model of the settings read and the three
#                         /api/archie/actions routes over $T/db.json (the
#                         worker side runs for real in
#                         worker/jobs/test/archie-actions-data-lane.bh-4927.test.js);
#                         every request lands in $T/reqlog;
#   gh_rest_pr_list_var   answers from $T/prs-<repo>.json;
#   gh_rest               GET repos/acme/<repo>/pulls/<n>/files from
#                         $T/files-<repo>-<n>.json (logged to $T/ghrest.log);
#   mc_hold_keeps_pr      held when $T/held exists.
# $H/bin/data-lane-apply.sh is a stub that appends `CALL <argv>` to
# $T/reqlog (so the claim-before-call order reads from one file), prints
# $STUB_WORD (default `applied`) and exits $STUB_RC (default 0).
#
# Cases: DL1 candidate on, DL2 second tick, DL3 observe, DL4 negatives, DL5
# the rc table, DL6 the digest line, DL7 resolver/conductor state untouched,
# DL8 cap, DL9 deadline, DL10 per-tick cap, DL11 no cron line, DW the worker
# suite, X mutations.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-data-lane.bh-4927-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "archie-fm-data-lane: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-data-lane: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${ARCHIE_FM_TEST_VERBOSE:-}" = 1 ] && [ -n "${1:-}" ] && echo "ok: $1"; return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket touches (D41).
for f in "$DIR/bin/archie-fm.sh" "$DIR/bin/lib/archie-fm.sh" "$DIR/bin/lib/data-lane.sh" "$DIR/bin/data-lane-apply.sh" \
         "$DIR/bin/lib/daily-digest-render.sh" "$DIR/worker/jobs/src/routes/archie-actions.js" \
         "$DIR/worker/jobs/test/archie-actions-data-lane.bh-4927.test.js" "$DIR/catalog/lanes.d/data-lane.json" \
         "$DIR/docs/verification-map/entries/BH-4920.4.md"; do
  if [ -f "$f" ]; then ok "ships ${f#"$DIR"/}"; else bad "missing $f"; fi
done

NOW=1791273600                       # 2026-10-06T08:00:00Z, read once
DAY=2026-10-06
HEAD7=7777777777777777777777777777777777777777
OLD7=6666666666666666666666666666666666666666
SQL=scripts/migrations/0042_add_col.sql
export HOME="$T/home"
mkdir -p "$T/home" "$T/tmp"

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/data-lane-apply.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) cat "$FXT/projects" 2>/dev/null || echo fixt ;;
  --*) ;;
  *) [ "${2:-}" = repo ] && echo "acme/$1" ;;
esac
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/data-lane-apply.sh" <<'SH'
#!/bin/bash
printf 'CALL %s\n' "$*" >> "$FXT/reqlog"
printf '%s' "${STUB_WORD-applied}"
[ -n "${STUB_WORD-applied}" ] && echo
exit "${STUB_RC:-0}"
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/data-lane-apply.sh"
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

# The worker, modelled in jq over $T/db.json: the answers of
# worker/jobs/src/routes/archie-actions.js, with skipped a terminal outcome.
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
           | ["started>done","started>requested","started>would","started>deferred","started>failed","started>skipped","deferred>started","deferred>failed"]
           | index($tr) != null' <<<"$out" >/dev/null || ! jq -e --argjson b "$b" '.updated_at == $b.expect_updated_at' <<<"$out" >/dev/null; then
        out=$(jq -c '{error: "stale or illegal", action: .}' <<<"$out"); JOBS_HTTP=409; JOBS_BODY=$out; printf '%s' "$out"; return 9
      fi
      jq --argjson b "$b" --arg t "$t" '.actions |= map(if .id == $b.id then
          (if .outcome == "deferred" and $b.outcome == "started" then .attempts += 1 else . end)
          | .outcome = $b.outcome | .action = ($b.action // .action) | .why = ($b.why // .why)
          | .evidence = ($b.evidence // .evidence) | .updated_at = $t else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db") ;;
    "GET /api/archie/actions")
      local d pb cb; d=$(qp day); pb=$(qp playbook); cb=$(qp count_by)
      out=$(jq -c --arg d "$d" --arg pb "$pb" --arg cb "$cb" '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] as $r
        | {ok: true, day: $d, actions: $r,
           counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][if $cb == "action" then $x.action else $x.outcome end] += 1)),
           truncated: false} + (if $cb == "action" then {count_by: "action"} else {} end)' "$db") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest_pr_list_var() {
  local v="$1" slug="$2" state="$3" head="${4:-}" out
  printf 'list %s %s %s\n' "$slug" "$state" "$head" >> "$FXT/ghrest.log"
  if [ -n "$head" ]; then
    out='[]'
  elif [ -f "$FXT/prs-${slug#*/}.json" ]; then
    out=$(jq -c --arg st "$state" '[.[] | select(.state == $st)]' "$FXT/prs-${slug#*/}.json")
  else
    out='[]'
  fi
  printf -v "$v" '%s' "$out"; GH_REST_STATUS=200; return 0
}
gh_rest() {
  local m="$1" path="$2" f
  printf 'rest %s %s\n' "$m" "$path" >> "$FXT/ghrest.log"
  [ -f "$FXT/files.down" ] && { GH_REST_STATUS=502; return 75; }
  if [ "$m" = GET ] && [[ $path =~ ^repos/acme/([a-z]+)/pulls/([0-9]+)/files ]]; then
    f="$FXT/files-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}.json"
    [ -f "$f" ] && { cat "$f"; GH_REST_STATUS=200; return 0; }
  fi
  GH_REST_STATUS=404; return 1
}
mc_hold_keeps_pr() { [ -f "$FXT/held" ]; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
       MC_REPOS="$T/repos" MC_REHYDRATE=0 TMPDIR="$T/tmp"
unset ARCHIE_FM_ENABLED ARCHIE_FM_RETRY_S ARCHIE_FM_MAX_ATTEMPTS ARCHIE_FM_SUITE_TIMEOUT_S ARCHIE_FM_PROJECTS_PER_TICK \
  ARCHIE_FM_NOW ARCHIE_FM_FIXTURE ARCHIE_FM_TIMED ARCHIE_FM_DEADLINE ARCHIE_FM_TICK_CEILING_S ARCHIE_FM_SUITE_AS \
  STUB_WORD STUB_RC 2>/dev/null || true

# review <file> [extra finding lines…] — the BLOCK review of one unapplied
# migration, its DATA_LANE line naming <file>.
review() {
  local f="$1"; shift
  { echo "# Review"; echo "- **B1.** The column is read but the migration is not applied to prod yet."
    printf '%s\n' "$@"; echo "DATA_LANE: $f"; echo "TIER: 2"; echo "VERDICT: BLOCK"; } > "$REC/review.md"
}
# project <name> — a project's PR list, its files, and its build record.
project() {
  local p="$1" rec="$H/builds/$1-BH-1-202610060000"
  mkdir -p "$rec"
  printf 'PR_CREATED https://github.com/acme/%s/pull/7\n' "$p" > "$rec/RESULT"
  echo "$HEAD7" > "$rec/review-head"
  REC="$rec"; review "$SQL"
  jq -n --arg p "$p" --arg h "$HEAD7" '[
    {number: 7, state: "open", html_url: "https://github.com/acme/\($p)/pull/7",
     head: {ref: "ticket/bh-1", sha: $h, repo: {full_name: "acme/\($p)"}}, base: {ref: "main"}},
    {number: 8, state: "open", html_url: "https://github.com/acme/\($p)/pull/8",
     head: {ref: "ticket/bh-2", sha: "8888888888888888888888888888888888888888", repo: {full_name: "acme/\($p)"}}, base: {ref: "main"}}]' \
    > "$T/prs-$p.json"
  jq -n --arg s "$SQL" '[{filename: "src/a.ts"}, {filename: $s}]' > "$T/files-$p-7.json"
}
# world — a fresh db, PR list, build record and harness state.
world() {
  local x
  for x in db.json reqlog ghrest.log alerts.log net.log projects held files.down out rc prs-fixt.json prs-fixu.json \
           files-fixt-7.json files-fixu-7.json; do
    scratch_rm "$T/$x" || exit 1
  done
  for x in state locks builds flags; do scratch_rm "$H/$x" || exit 1; done
  scratch_rm "$H/logs/archie-fm.log" || exit 1
  mkdir -p "$H/state/merge-conductor" "$H/state/blocked-resolver" "$H/flags"
  project fixt
  REC="$H/builds/fixt-BH-1-202610060000"
  printf 'acme/fixt#7\tBLOCKED_HUMAN\t2026-10-06T07:00:00Z\t%s\t%s\t-\treview-blocked\thttps://github.com/acme/fixt/pull/7\n' "$HEAD7" "$HEAD7" \
    > "$H/state/merge-conductor/pr-state.tsv"
  printf '{"pr":7,"head":"%s","attempts":1}\n' "$HEAD7" > "$H/state/blocked-resolver/acme_fixt-7.json"
  jq -n '{settings: {"archie.manage": "on"}, actions: []}' > "$T/db.json"
  : > "$T/reqlog"; : > "$T/ghrest.log"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
tick() { # tick [VAR=value ...]  — one tick of the shipped lane at NOW
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FM_NOW="$NOW" ARCHIE_FM_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 "$@" \
    bash "$H/bin/archie-fm.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
dlrows() { jq '[.actions[] | select(.playbook == "data-lane")] | length' "$T/db.json"; }
rows()   { jq '.actions | length' "$T/db.json"; }
row()    { jq -r --arg f "$1" '.actions[0] | getpath($f | split(".")) // "null" | tostring' "$T/db.json"; }
calls()  { grep -c '^CALL ' "$T/reqlog"; }
files_reads() { grep -c '^rest GET repos/acme/[a-z]*/pulls/[0-9]*/files' "$T/ghrest.log"; }
lastlog(){ tail -1 "$H/logs/archie-fm.log" 2>/dev/null; }
# nothing <label> — zero rows and zero apply calls.
nothing() {
  if [ "$(rows)" = 0 ] && [ "$(calls)" = 0 ]; then ok "$1"; else bad "$1: rows=$(rows) calls=$(calls) log: $(tail -2 "$H/logs/archie-fm.log" 2>/dev/null | tr '\n' '|')"; fi
}

# ── assertion bundles, reused by the X mutations ────────────────────────────
# dl1_ok: one on-mode tick on the candidate made ONE done row and ONE call,
# the claim POST before the call.
dl1_ok() {
  local claim call
  claim=$(grep -n '^POST /api/archie/actions ' "$T/reqlog" | head -1 | cut -d: -f1)
  call=$(grep -n '^CALL ' "$T/reqlog" | head -1 | cut -d: -f1)
  [ "$(rows)" = 1 ] && [ "$(calls)" = 1 ] && [ -n "$claim" ] && [ -n "$call" ] && [ "$claim" -lt "$call" ] \
    && [ "$(row playbook)/$(row mode)/$(row action)/$(row outcome)" = data-lane/on/apply/done ]
}
# stale_sha_none: a review of an older sha is no candidate.
stale_sha_none() { world; echo "$OLD7" > "$REC/review-head"; tick; [ "$(rows)" = 0 ] && [ "$(calls)" = 0 ]; }

# ── DL1: one candidate, mode on ──────────────────────────────────────────────
world
PRS_BEFORE=$(cat "$H/state/merge-conductor/pr-state.tsv"); BR_BEFORE=$(cat "$H/state/blocked-resolver/acme_fixt-7.json")
tick
check "DL1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "DL1 one row, one call, the claim before the call ($(cut -c1-60 "$T/reqlog" | tr '\n' '|'))" dl1_ok
eq "DL1 the dedupe key" "$(row dedupe_key)" "data-lane:fixt:7:${HEAD7:0:12}"
eq "DL1 the row's repo/pr" "$(row repo)#$(row pr)" "acme/fixt#7"
eq "DL1 the stub's argv" "$(grep '^CALL ' "$T/reqlog")" "CALL fixt 7 $REC"
eq "DL1 evidence file" "$(row evidence.file)" "$SQL"
eq "DL1 evidence build_dir" "$(row evidence.build_dir)" "$REC"
eq "DL1 evidence head" "$(row evidence.head)" "$HEAD7"
eq "DL1 evidence word" "$(row evidence.word)" "applied"
eq "DL1 evidence rc" "$(row evidence.rc)" 0
eq "DL1 the plain PR 8 cost no file-list read" "$(files_reads)" 1
check "DL1 the cap read filters on playbook=data-lane" 'grep -q "^GET /api/archie/actions?day=$DAY&playbook=data-lane&limit=1" "$T/reqlog"'
check "DL1 summary line: $(lastlog)" \
  'lastlog | grep -qE "^[^ ]+ data_lane candidates=1 applied=1 would=0 deferred=0 skipped=0 escalated=0 failed=0$"'
check "DL1 the restack summary line is not written (nothing stuck)" '! grep -q " projects=" "$H/logs/archie-fm.log"'
check "DL1 nothing left the stubs" '[ ! -s "$T/net.log" ] || ! grep -qE "github|/api/archie" "$T/net.log"'
# ── DL7: resolver and conductor state are read, never written ───────────────
eq "DL7 pr-state.tsv byte-identical" "$(cat "$H/state/merge-conductor/pr-state.tsv")" "$PRS_BEFORE"
eq "DL7 blocked-resolver state byte-identical" "$(cat "$H/state/blocked-resolver/acme_fixt-7.json")" "$BR_BEFORE"
eq "DL7 no other resolver state" "$(ls "$H/state/blocked-resolver" | tr '\n' ' ')" "acme_fixt-7.json "

# ── DL2: a second tick on the same head calls nothing ───────────────────────
DBB=$(cat "$T/db.json"); : > "$T/reqlog"
tick
eq "DL2 no new call" "$(calls)" 0
eq "DL2 db unchanged" "$(cat "$T/db.json")" "$DBB"

# ── DL3: observe ─────────────────────────────────────────────────────────────
world; setting archie.manage observe
tick
eq "DL3 one row" "$(rows)" 1
eq "DL3 the row" "$(row mode)/$(row action)/$(row outcome)" "observe/would_apply/would"
eq "DL3 the observe key" "$(row dedupe_key)" "data-lane:fixt:7:${HEAD7:0:12}:observe"
check "DL3 the why says would apply" 'row why | grep -q "^would apply $SQL ahead of merge"'
eq "DL3 no call" "$(calls)" 0
check "DL3 summary line: $(lastlog)" 'lastlog | grep -qE " data_lane candidates=1 applied=0 would=1 "'
# Flipping to on after an observe tick still acts on the same head.
setting archie.manage on; tick
eq "DL3 on after observe: one call" "$(calls)" 1
eq "DL3 on after observe: two rows" "$(dlrows)" 2

# ── DL4: negatives — no claim, no call ──────────────────────────────────────
world; review "$SQL" "- **B2.** an unrelated bug"; tick; nothing "DL4 a second BLOCK finding"
world; review "../../etc/x.sql"; jq -n '[{filename: "../../etc/x.sql"}]' > "$T/files-fixt-7.json"; tick; nothing "DL4 a ../ path"
world; review "scripts/migrations/0099_other.sql"; tick; nothing "DL4 a path not in the PR's files"
world; review "<path>"; tick; nothing "DL4 a placeholder path"
world; { echo "- **B1.** migration not applied"; echo "NEEDS_HUMAN: run scripts/migrate-x.ts against prod"; echo "TIER: 2"; echo "VERDICT: BLOCK"; } > "$REC/review.md"
tick; nothing "DL4 NEEDS_HUMAN only"
eq "DL4 NEEDS_HUMAN only costs no file-list read" "$(files_reads)" 0
stale_sha_none; nothing "DL4 the review read an older sha"
world; scratch_rm "$REC" || exit 1; tick; nothing "DL4 no build record"
world; jq '(.[] | select(.number == 7) | .head.ref) = "agent/x"' "$T/prs-fixt.json" > "$T/p.tmp" && mv "$T/p.tmp" "$T/prs-fixt.json"
tick; nothing "DL4 a non-harness branch"
world; jq '(.[] | select(.number == 7) | .head.repo.full_name) = "fork/fixt"' "$T/prs-fixt.json" > "$T/p.tmp" && mv "$T/p.tmp" "$T/prs-fixt.json"
tick; nothing "DL4 a fork head"
world; : > "$T/held"; tick; nothing "DL4 a PR on HOLD"
# The switch is lane-gate's read (lane_paused), so these two run with the gate on.
world; : > "$H/flags/lane-off-data-lane"; tick LANE_GATE_DISABLE=0; nothing "DL4 flags/lane-off-data-lane"
check "DL4 lane-off-data-lane is logged as the data lane's switch" 'grep -q "acme/fixt#7: data-lane: the data-lane lane is off" "$H/logs/archie-fm.log"'
world; : > "$H/flags/all-off"; tick LANE_GATE_DISABLE=0; nothing "DL4 flags/all-off"
world; tick LANE_GATE_DISABLE=0; eq "DL4 with the gate on and no switch set, the candidate is still acted on" "$(calls)" 1
world; sed -i 's/\tBLOCKED_HUMAN\t/\tMERGED\t/' "$H/state/merge-conductor/pr-state.tsv"; tick; nothing "DL4 a conductor row MERGED"
world; : > "$T/files.down"; tick; nothing "DL4 the file list unreadable"
check "DL4 the unreadable file list is logged" 'grep -q "acme/fixt#7: data-lane: the PR file list could not be read" "$H/logs/archie-fm.log"'
world; jq -n '[range(100) | {filename: "src/f\(.).ts"}]' > "$T/files-fixt-7.json"; tick; nothing "DL4 a full page without the path"

# ── DL5: the apply's rc and word close the row ──────────────────────────────
dl5() { # dl5 <rc> <word> <want outcome/action> <want summary word>
  local w="$4"
  world; tick STUB_RC="$1" STUB_WORD="$2"
  eq "DL5 rc $1 word '$2' -> $3" "$(row outcome)/$(row action)" "$3"
  eq "DL5 rc $1 word '$2' one call" "$(calls)" 1
  check "DL5 rc $1 word '$2' counted $w: $(lastlog)" 'lastlog | grep -qE " $w=1( |\$)"'
}
dl5 0 applied done/apply applied
dl5 0 already-applied done/apply applied
dl5 0 "" deferred/apply deferred
dl5 1 failed failed/apply failed
dl5 2 flagged failed/apply failed
check "DL5 rc 2 says flagged" 'row why | grep -q "flagged"'
dl5 75 busy deferred/apply deferred
dl5 124 "" deferred/apply deferred
dl5 3 not-candidate skipped/not_candidate skipped
dl5 5 no-path skipped/no_path escalated
dl5 9 "" failed/apply failed
check "DL5 unknown rc names the rc" 'row why | grep -q "exited 9"'
eq "DL5 no alert from Archie on a failed apply (the script alerted)" "$(cat "$T/alerts.log" 2>/dev/null)" ""
# The deferred ladder: a deferred row at the attempt cap closes failed with ONE data-lane alert.
world; tick STUB_RC=75 STUB_WORD=busy
jq '.actions[0].attempts = 3 | .actions[0].updated_at = "2026-10-06T06:00:00Z"' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
: > "$T/reqlog"; tick
eq "DL5 ladder: the row closes failed" "$(row outcome)" failed
eq "DL5 ladder: no call" "$(calls)" 0
check "DL5 ladder: ONE data-lane alert ($(cat "$T/alerts.log" 2>/dev/null))" \
  '[ "$(grep -c . "$T/alerts.log")" = 1 ] && grep -q "acme/fixt#7 data-lane apply of $SQL deferred 3 times; check logs/fixt.log for data-lane lines" "$T/alerts.log"'
check "DL5 ladder: the alert is not the restack text" '! grep -q "rebase --onto" "$T/alerts.log"'

# ── DL6: the digest line ─────────────────────────────────────────────────────
render() { bash -c ". \"$DIR/bin/lib/daily-digest-render.sh\"; dd_render \"$1\" https://console.test - 0 5 -"; }
jq -n --arg d "$DAY" '{day: $d, factory_manager: {ok: true, day: $d, total: 4, restacked: 1, fix_rounds: 0, would: 0, deferred: 0, failed: 1,
  data_lane: {total: 3, applied: 2, escalated: 1, would: 0}}}' > "$T/dg.json"
DD=$(render "$T/dg.json")
check "DL6 the data-lane line ($(grep '^Factory manager' <<<"$DD" | tr '\n' '|'))" \
  'grep -qxF "Factory manager, data lane: applied 2 migrations ahead of merge, 1 escalated https://console.test/" <<<"$DD"'
eq "DL6 the data-lane line follows the Factory manager line" "$(grep -A1 '^Factory manager: ' <<<"$DD" | sed -n 2p | cut -d, -f1)" "Factory manager"
jq 'del(.factory_manager.data_lane)' "$T/dg.json" > "$T/dg0.json"
check "DL6 no data_lane key: no line" '! render "$T/dg0.json" | grep -q "data lane"'
jq '.factory_manager.data_lane = {total: 0, applied: 0, escalated: 0, would: 0}' "$T/dg.json" > "$T/dg1.json"
check "DL6 total 0: no line" '! render "$T/dg1.json" | grep -q "data lane"'
jq '.factory_manager.ok = false | .factory_manager.error = "x"' "$T/dg.json" > "$T/dg2.json"
check "DL6 ok:false: no data-lane line" '! render "$T/dg2.json" | grep -q "data lane"'

# ── DL8: the day cap ─────────────────────────────────────────────────────────
world; setting archie.cap.data-lane 1
jq --arg d "$DAY" '.actions += [{id: 1, dedupe_key: "data-lane:fixt:9:999999999999", day: $d, project: "fixt", repo: "acme/fixt",
  pr: 9, playbook: "data-lane", mode: "on", action: "apply", outcome: "done", attempts: 1, evidence: {},
  created_at: "2026-10-06T01:00:00Z", updated_at: "2026-10-06T01:00:00Z"}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
eq "DL8 cap reached: no new row" "$(rows)" 1
eq "DL8 cap reached: no call" "$(calls)" 0
check "DL8 logged" 'grep -q "cap reached (1 of 1 data-lane actions today)" "$H/logs/archie-fm.log"'
# A restack-playbook row does not spend the data-lane cap.
world; setting archie.cap.data-lane 1
jq --arg d "$DAY" '.actions += [{id: 1, dedupe_key: "x", day: $d, project: "fixt", repo: "acme/fixt", pr: 9,
  playbook: "stacked-parent-merged", mode: "on", action: "restack", outcome: "done", attempts: 1, evidence: {},
  created_at: "2026-10-06T01:00:00Z", updated_at: "2026-10-06T01:00:00Z"}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
eq "DL8 a restack row is not a data-lane unit" "$(calls)" 1

# ── DL8b: a full cap is per playbook (lead review of 4ac3e235) ──────────────
# afm_cap_ok remembers a reached cap for the rest of the tick. The memo must be
# the playbook's own: a full data-lane cap leaves restack and rebase-repair
# alone, and a full restack cap leaves the data lane alone. Driven on the real
# lib with setting_get / _jobs_req stubs: data-lane is at 1 of 1 today, the
# other playbooks have room.
capseq() { # capseq <playbook>... -> one `<playbook>=<rc>` per call, in one shell (one tick)
  ( set +u
    _jobs_req() { case "$2" in
        *playbook=data-lane*) printf '{"count_by":"action","counts":{"data-lane":{"on":{"apply":%s}}}}' "${DL_USED:-1}" ;;
        *playbook=stacked-parent-merged*) printf '{"count_by":"action","counts":{"stacked-parent-merged":{"on":{"restack":%s}}}}' "${SPM_USED:-0}" ;;
        *) printf '{"count_by":"action","counts":{}}' ;;
      esac; echo "REQ $2" >> "$T/capreq"; }
    setting_get() { case "$1" in archie.cap.data-lane|archie.cap.stacked-parent-merged) printf 1 ;; *) return 2 ;; esac; }
    . "$DIR/bin/lib/archie-fm.sh" >/dev/null 2>&1
    afm_log() { :; }
    DAY=2026-10-06
    for pb in "$@"; do AFM_PLAYBOOK=$pb; afm_cap_ok fixt; printf '%s=%s ' "$pb" "$?"; done )
}
: > "$T/capreq"
eq "DL8b a full data-lane cap leaves restack and rebase-repair room" \
  "$(capseq data-lane stacked-parent-merged rebase-repair data-lane)" \
  "data-lane=1 stacked-parent-merged=0 rebase-repair=0 data-lane=1 "
eq "DL8b the data-lane memo holds: its count is read once in the tick" "$(grep -c 'playbook=data-lane' "$T/capreq")" 1
: > "$T/capreq"
eq "DL8b a full restack cap leaves the data lane room" \
  "$(SPM_USED=1 DL_USED=0 capseq stacked-parent-merged data-lane stacked-parent-merged)" \
  "stacked-parent-merged=1 data-lane=0 stacked-parent-merged=1 "
eq "DL8b the restack memo holds: its count is read once in the tick" "$(grep -c 'playbook=stacked-parent-merged' "$T/capreq")" 1

# ── DL9: no time left ────────────────────────────────────────────────────────
world; tick ARCHIE_FM_DEADLINE="$(date +%s)"
nothing "DL9 no time left: no claim, no call"
check "DL9 logged" 'grep -q "acme/fixt#7: data-lane: .*s left in this tick" "$H/logs/archie-fm.log"'

# ── DL10: ARCHIE_FM_PROJECTS_PER_TICK ───────────────────────────────────────
world; printf 'fixt\nfixu\n' > "$T/projects"; project fixu
tick ARCHIE_FM_PROJECTS_PER_TICK=1
eq "DL10 one project per tick: exactly one call" "$(calls)" 1
world; printf 'fixt\nfixu\n' > "$T/projects"; project fixu
tick
eq "DL10 no cap: one call per project" "$(calls)" 2

# ── DL11: no new cron line, no archie-fm registry change ────────────────────
# Repo state only (BH-5684): the data lane runs inside archie-fm's tick, so no
# cron line and no archie-fm registry row names it. A diff against origin/main
# would hold only while this PR is open, and it failed merge batch #5834 when
# a stacked sibling (#5087) added an unrelated cron/lanes file.
check "DL11 no cron line names the data lane" '! grep -rqE "data-lane|data_lane" "$DIR/cron"'
check "DL11 the archie-fm registry names no data-lane lane or knob" '[ -r "$DIR/catalog/lanes.d/archie-fm.json" ] && ! grep -qiE "data-lane|data_lane|AFM_DL" "$DIR/catalog/lanes.d/archie-fm.json"'

# ── DW: the worker side of the same contract ────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  echo "note: DW not run (no node on PATH); CI's worker job runs it"
elif [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "note: DW not run (catalog/lanes.json is not generated here; CI runs bin/lanes-build.sh --write first)"
else
  if NOUT=$(cd "$DIR/worker/jobs" && node --test test/archie-actions-data-lane.bh-4927.test.js 2>&1); then ok "DW worker suite"
  else bad "DW worker suite: $(tail -20 <<<"$NOUT")"; fi
fi

# ── X: mutations — each must turn a case above red ──────────────────────────
LIB="$H/bin/lib/archie-fm.sh"; WRAP="$H/bin/archie-fm.sh"
mutate() { # mutate <target> <python-expr over s>
  local tgt="$1" src
  src=$(readlink "$tgt") || src=""
  [ -n "$src" ] || { echo "mutate: $tgt is not the symlink to the shipped file"; return 1; }
  rm -f "$tgt"
  python3 -c "import sys; s=open(sys.argv[1]).read(); $2; open(sys.argv[2],'w').write(s)" "$src" "$tgt"
  cmp -s "$tgt" "$src" && { echo "mutation did not change $tgt"; return 1; }
  return 0
}
restore() { rm -f "$LIB" "$WRAP"; ln -s "$DIR/bin/lib/archie-fm.sh" "$LIB"; ln -s "$DIR/bin/archie-fm.sh" "$WRAP"; }
if command -v python3 >/dev/null 2>&1; then
  # X1: the claim removed (the call made with no row).
  if mutate "$LIB" 's=s.replace("afm_claim \"$key\" \"$p\" \"$slug\" \"$n\" on apply", "true \"$key\"")'; then
    world; tick
    if dl1_ok; then bad "X1 dropping the claim must break DL1"; else ok "X1 RED: dropping the claim breaks DL1"; fi
  else bad "X1 mutation not applied"; fi
  restore
  # X2: the apply called before the claim.
  if mutate "$LIB" 's=s.replace("  # >>> dl claim\n", "  # >>> dl claim\n  \"${AFM_H:-}/bin/data-lane-apply.sh\" \"$p\" \"$n\" \"$dir\" >/dev/null 2>&1\n")'; then
    world; tick
    if dl1_ok; then bad "X2 calling before the claim must break DL1"; else ok "X2 RED: calling before the claim breaks DL1"; fi
  else bad "X2 mutation not applied"; fi
  restore
  # X3: the reviewed-sha gate dropped.
  if mutate "$LIB" 's=s.replace("[ \"$(dl_reviewed_sha \"$dir\")\" = \"$head\" ] || return 1", "true")'; then
    if stale_sha_none; then bad "X3 dropping the reviewed-sha gate must break the stale-sha negative"; else ok "X3 RED: dropping the reviewed-sha gate breaks the stale-sha negative"; fi
  else bad "X3 mutation not applied"; fi
  restore
  # X4: the production call site removed from the tick (D2).
  if mutate "$WRAP" 's=s.replace("dl_one_pr \"$p\" \"$slug\" \"$mode\" \"$pr\" && return 0", "false && return 0")'; then
    world; tick
    if dl1_ok; then bad "X4 removing the tick's call site must break DL1"; else ok "X4 RED: removing the tick's call site breaks DL1"; fi
  else bad "X4 mutation not applied"; fi
  restore
  # X5: rc 0 with no word read as applied (D9).
  if mutate "$LIB" 's=s.replace("0:applied|0:already-applied)", "0:*)")'; then
    world; tick STUB_RC=0 STUB_WORD=""
    if [ "$(row outcome)" = deferred ]; then bad "X5 rc 0 without a word must not stay deferred under the mutation"; else ok "X5 RED: rc 0 without a word is no longer deferred"; fi
  else bad "X5 mutation not applied"; fi
  restore
  check "X the restored files are the shipped ones" \
    '[ "$(readlink "$LIB")" = "$DIR/bin/lib/archie-fm.sh" ] && [ "$(readlink "$WRAP")" = "$DIR/bin/archie-fm.sh" ]'
else
  bad "X python3 is required for the mutations"
fi

echo "archie-fm-data-lane: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
