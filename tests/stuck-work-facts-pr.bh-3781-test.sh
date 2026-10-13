#!/bin/bash
# tests/stuck-work-facts-pr.bh-3781-test.sh — BH-3791 (BH-3781.2): swf_pr_facts,
# the open-PR fact reader. The seam is the TRANSPORT only: gh_rest and
# _jobs_req are stubbed, and the real verb bodies (gh_rest_pr_list_all,
# vd_standing, mc_mergify_check_live, pr_state_page, mc_resolver_claim_get,
# dqw_actions_list, sw_first_seen, job_ledger_row/put) run on top of them.
#
#   P1  a READY PR -> the exact 22-field line, rc 0      P1b verdict on an old head -> -
#   P2  mergify queued / checking / idle / failed        P3  check-runs 403 -> mergify ?
#   P4  list read 429 -> rc 3, nothing, no per-PR call   P5  no graphql, no bare gh
#   P6  nothing wired -> rc 1, 0 bytes                   P7  cap -> rc 3, oldest first
#   P8  verdicts 503 -> ? in 8-10                        P9  draft=1, P9b [] -> rc 0
#   P10 a bad cap falls back to 300                      P11 conductor row / - / ?
#   P12 first_seen anchor written once, never on ?       P13 status 403 -> ? ?
#   P13b/P14c a time that does not parse -> ?           P14 resolver claim on this head / another head
#   P15 dequeue actions gated
#   P16 every line is 22 tab-separated fields
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-facts-pr.bh-3781-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/stuck-work/facts-pr.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "stuck-work-facts-pr: 0 passed, 1 failed"; exit 1; }

NOW=1700009999
T0=1700000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { printf 'a%039d' "$1"; }

mkdir -p "$T/shim" "$T/h/logs"
printf '#!/bin/bash\necho "gh $*" >> "%s/gh-shim.calls"\nexit 1\n' "$T" > "$T/shim/gh"
chmod +x "$T/shim/gh"

# The prelude every case sources: the real libs, then the two transport stubs.
cat > "$T/prelude.sh" <<EOF
. "$DIR/bin/lib/gh-rest.sh"
. "$DIR/bin/lib/gh-rest-list.sh"
. "$DIR/bin/lib/verdicts.sh"
. "$DIR/bin/lib/jobs/jobs.sh"
. "$DIR/bin/lib/jobs/dequeue-watch.sh"
. "$DIR/bin/lib/stuck-work/seen.sh"
eval "\$(sed -n '/^vs_context()/p' "$DIR/bin/lib/verdict-status.sh")"
eval "\$(sed -n '/^mc_mergify_check() {/,/^}/p;/^mc_mergify_check_live() {/,/^}/p' "$DIR/bin/lib/mc/queue.sh")"
eval "\$(sed -n '/^mc_handoff_id()/p;/^mc_resolver_claim_file()/p;/^mc_resolver_claim_get() {/,/^}/p' "$DIR/bin/lib/mc/classify.sh")"
. "$LIB"
EOF
cat >> "$T/prelude.sh" <<'EOF'
# gh_rest <method> <path> [args] — answers $T/gh/<path with / as _>, rc from .rc,
# status from .st; a commit's status / check-runs default to an empty answer.
gh_rest() {
  local m="$1" p="$2" f; shift 2
  echo "$m $p $*" >> "$T/gh.calls"
  f="$T/gh/${p//\//_}"
  GH_REST_STATUS=200; GH_REST_REASON=
  [ -f "$f.st" ] && GH_REST_STATUS=$(cat "$f.st")
  if [ -f "$f.rc" ] && [ "$(cat "$f.rc")" != 0 ]; then return "$(cat "$f.rc")"; fi
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  case "$p" in
    */status) echo '{"state":"pending","statuses":[]}' ;;
    */check-runs) echo '{"total_count":0,"check_runs":[]}' ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
}
# _jobs_req <method> <path> [body] — the worker, by route.
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" f k
  echo "$m $p $b" >> "$T/w.calls"
  JOBS_HTTP=200; JOBS_BODY=
  case "$p" in
    /api/verdicts\?*)
      k=$(sed -n 's/.*[?&]pr=\([0-9]*\).*/\1/p' <<<"$p"); f="$T/w/verdicts_$k"
      [ -f "$f.rc" ] && { JOBS_HTTP=503; return "$(cat "$f.rc")"; }
      if [ -f "$f" ]; then cat "$f"; else echo '{"standing":null}'; fi ;;
    /api/pr-state\?*)
      k=$(sed -n 's/.*[?&]before=\([0-9]*\).*/\1/p' <<<"$p"); f="$T/w/prstate${k:+.before_$k}"
      [ -f "$T/w/prstate.rc" ] && { JOBS_HTTP=503; return "$(cat "$T/w/prstate.rc")"; }
      if [ -f "$f" ]; then cat "$f"; else JOBS_HTTP=404; return 2; fi ;;
    /api/dequeue-watch/actions*)
      k=$(sed -n 's/.*[?&]pr=\([0-9]*\).*/\1/p' <<<"$p"); f="$T/w/dqw_$k"
      [ -f "$f.rc" ] && { JOBS_HTTP=503; return "$(cat "$f.rc")"; }
      if [ -f "$f" ]; then cat "$f"; else echo '{"rows":[],"truncated":false}'; fi ;;
    /api/ledger\?*)
      k=$(sed -n 's/.*[?&]key=\([^&]*\).*/\1/p' <<<"$p")
      if [ -f "$T/ledger/$k" ]; then cat "$T/ledger/$k"; else JOBS_HTTP=404; return 2; fi ;;
    /api/ledger)
      [ "$m" = PUT ] || return 1
      echo "$b" >> "$T/puts"
      k=$(jq -r '.key|@uri' <<<"$b")
      mkdir -p "$T/ledger"
      jq -c '{ledger:{status, detail}}' <<<"$b" > "$T/ledger/$k" ;;
    *) return 1 ;;
  esac
}
EOF

# reset — a clean fixture tree for the next case.
reset() { rm -rf "$T/gh" "$T/w" "$T/ledger" "$T/claims" "$T/puts" "$T/gh.calls" "$T/w.calls"; mkdir -p "$T/gh" "$T/w" "$T/claims"; : > "$T/gh.calls"; : > "$T/w.calls"; }
nputs() { if [ -f "$T/puts" ]; then wc -l < "$T/puts"; else echo 0; fi; }
# pr <num> <created-epoch> <labels-csv> [draft] — one list entry.
pr() {
  jq -nc --argjson n "$1" --arg c "$(iso "$2")" --arg l "$3" --arg h "$(sha "$1")" --argjson d "${4:-false}" \
    '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)), draft:$d, created_at:$c,
      head:{sha:$h}, labels:($l | if . == "" then [] else split(",") | map({name:.}) end)}'
}
# prs <entry>... — the open-PR list fixture.
prs() { printf '%s\n' "$@" | jq -sc . > "$T/gh/repos_o_r_pulls"; }
lead_ok() { # lead_ok <num> <epoch> — a lead-verdict success status on the head
  jq -nc --arg t "$(iso "$2")" '{state:"failure",statuses:[{context:"ci",state:"failure",updated_at:"2020-01-01T00:00:00Z"},{context:"lead-verdict",state:"success",updated_at:$t}]}' \
    > "$T/gh/repos_o_r_commits_$(sha "$1")_status"
}
merge_v() { # merge_v <num> <epoch> — a standing MERGE on the head
  jq -nc --arg t "$(iso "$2")" '{standing:{verdict:"MERGE",source:"lead",id:7,created_at:$t,report_url:null,reviewer:null}}' > "$T/w/verdicts_$1"
}
checks() { # checks <num> <status> <conclusion> <title>
  jq -nc --arg s "$2" --arg c "$3" --arg t "$4" \
    '{total_count:1,check_runs:[{name:"Mergify Merge Queue",status:$s,conclusion:(if $c == "" then null else $c end),output:{title:$t}}]}' \
    > "$T/gh/repos_o_r_commits_$(sha "$1")_check-runs"
}

# run [VAR=val...] — swf_pr_facts o/r in a clean env; stdout in $T/out, rc in RC.
# TEST-CHANGE BH-4656: PR_SNAPSHOT=0, or the lazily loaded snapshot keeps one case's list for the next.
run() {
  env -i PATH="$T/shim:$PATH" HOME="$T" T="$T" HARNESS="$T/h" JOBS_BOX=test HARNESS_TEST_SANDBOX=1 \
    STUCK_WORK_NOW="$NOW" MC_RESOLVER_CLAIM_DIR="$T/claims" PR_SNAPSHOT=0 "$@" \
    bash -c '. "$T/prelude.sh"; swf_pr_facts o/r' > "$T/out" 2> "$T/err"
  RC=$?
  cat "$T/out" >> "$T/all.out"
  cat "$T/gh.calls" "$T/w.calls" >> "$T/all.calls" 2>/dev/null
  return 0
}
# fld <num> <field#> — field N of the line for PR #num.
fld() { awk -F'\t' -v i="o/r#$1" -v n="$2" '$2 == i {print $n}' "$T/out"; }
fields() { awk -F'\t' -v i="o/r#$1" '$2 == i {print $6"|"$7"|"$8"|"$9"|"$10}' "$T/out"; }

# P1 — a READY PR: the whole line, byte for byte.
reset
prs "$(pr 12 "$T0" ai-build)"
lead_ok 12 "$T0"; merge_v 12 $((T0+60))
run
H=$(sha 12)
want=$(printf 'pr\to/r#12\thttps://github.com/o/r/pull/12\t0\tai-build\tsuccess\t%s\tMERGE\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s' \
  "$T0" "$H" "$((T0+60))" "$H" "$NOW")
[ "$RC" = 0 ] && ok || bad "P1 rc=$RC, wanted 0 ($(cat "$T/err"))"
[ "$(cat "$T/out")" = "$want" ] && ok || bad "P1 line was
  '$(cat "$T/out")'
wanted
  '$want'"
grep -q '^GET repos/o/r/pulls ' "$T/gh.calls" && ok || bad "P1 the list was not read from REST pulls: $(cat "$T/gh.calls")"
[ "$(grep -c '/api/pr-state?' "$T/w.calls")" = 1 ] && ok || bad "P1 wanted one pr_state read, got $(grep -c '/api/pr-state?' "$T/w.calls")"

# P1b — the verdict stands on an OLD head: nothing stands on this one.
rm -f "$T/w/verdicts_12"
run
[ "$(fields 12)" = "success|$T0|-|-|-" ] && ok || bad "P1b fields 6-10 were '$(fields 12)', wanted 'success|$T0|-|-|-'"

# P2 — the Mergify phase.
reset
prs "$(pr 21 $T0 ai-build)" "$(pr 22 $((T0+1)) ai-build)" "$(pr 23 $((T0+2)) ai-build)" "$(pr 24 $((T0+3)) ai-build)"
checks 21 queued "" "Queued"
checks 22 in_progress "" "Checking batch"
checks 23 completed neutral "Merge queue is ready"
checks 24 completed failure "Dequeued: checks failed"
run
[ "$RC" = 0 ] && ok || bad "P2 rc=$RC"
[ "$(fld 21 12)" = queued ] && ok || bad "P2 #21 mergify '$(fld 21 12)', wanted queued"
[ "$(fld 22 12)" = checking ] && ok || bad "P2 #22 mergify '$(fld 22 12)', wanted checking"
[ "$(fld 23 12)" = - ] && ok || bad "P2 #23 (idle check) mergify '$(fld 23 12)', wanted -"
[ "$(fld 24 12)" = failed ] && ok || bad "P2 #24 mergify '$(fld 24 12)', wanted failed"

# P3 — check-runs refused: mergify ?, the rest of the line still reads.
reset
prs "$(pr 12 "$T0" ai-build)"
lead_ok 12 "$T0"; merge_v 12 $((T0+60))
echo 75 > "$T/gh/repos_o_r_commits_$(sha 12)_check-runs.rc"; echo 403 > "$T/gh/repos_o_r_commits_$(sha 12)_check-runs.st"
run
[ "$RC" = 0 ] && ok || bad "P3 rc=$RC, wanted 0"
[ "$(fld 12 12)" = '?' ] && ok || bad "P3 mergify '$(fld 12 12)', wanted ?"
[ "$(fields 12)" = "success|$T0|MERGE|$(sha 12)|$((T0+60))" ] && ok || bad "P3 fields 6-10 '$(fields 12)' did not stay readable"
[ "$(fld 12 22)" = '?' ] && ok || bad "P3 first_seen '$(fld 12 22)', wanted ? (no anchor on an unreadable phase)"

# P4 — the list read is rate limited: rc 3, nothing printed, no per-PR call.
reset
prs "$(pr 12 "$T0" ai-build)"
echo 75 > "$T/gh/repos_o_r_pulls.rc"; echo 429 > "$T/gh/repos_o_r_pulls.st"
run
[ "$RC" = 3 ] && ok || bad "P4 rc=$RC, wanted 3"
[ -s "$T/out" ] && bad "P4 printed '$(cat "$T/out")'" || ok
grep -q 'commits/' "$T/gh.calls" && bad "P4 a per-PR call was made: $(cat "$T/gh.calls")" || ok
[ -s "$T/w.calls" ] && bad "P4 the worker was called: $(cat "$T/w.calls")" || ok

# P6 — nothing wired but the lib: rc 1 and 0 bytes. A bad repo arg is rc 1 too.
env -i PATH="$T/shim:$PATH" HOME="$T" L="$LIB" bash -c '. "$L"; swf_pr_facts o/r' > "$T/p6.out" 2>&1
rc=$?
[ "$rc" = 1 ] && ok || bad "P6 unwired rc=$rc, wanted 1"
[ -s "$T/p6.out" ] && bad "P6 unwired printed '$(cat "$T/p6.out")'" || ok
reset
env -i PATH="$T/shim:$PATH" HOME="$T" T="$T" HARNESS="$T/h" bash -c '. "$T/prelude.sh"; swf_pr_facts nope' > "$T/p6.out" 2>&1
rc=$?
[ "$rc" = 1 ] && [ ! -s "$T/p6.out" ] && ok || bad "P6 bad repo arg rc=$rc out='$(cat "$T/p6.out")', wanted rc 1 and nothing"
[ -s "$T/gh.calls" ] && bad "P6 a bad repo arg still called GitHub" || ok

# P7 — the cap: the OLDEST two, then rc 3.
reset
prs "$(pr 31 $((T0+3)) x)" "$(pr 32 $((T0+1)) x)" "$(pr 33 $((T0+2)) x)"
run STUCK_WORK_MAX_ITEMS=2
[ "$RC" = 3 ] && ok || bad "P7 rc=$RC, wanted 3"
[ "$(cut -f2 "$T/out" | tr '\n' ' ')" = "o/r#32 o/r#33 " ] && ok || bad "P7 lines were '$(cut -f2 "$T/out" | tr '\n' ' ')', wanted o/r#32 o/r#33"

# P10 — a cap that is not a positive number falls back to 300.
for cap in abc 0; do
  run STUCK_WORK_MAX_ITEMS=$cap
  [ "$RC" = 0 ] && [ "$(wc -l < "$T/out")" = 3 ] && ok || bad "P10 cap '$cap': rc=$RC lines=$(wc -l < "$T/out"), wanted rc 0 and 3"
done
[ "$(cut -f2 "$T/out" | tr '\n' ' ')" = "o/r#32 o/r#33 o/r#31 " ] && ok || bad "P10 order '$(cut -f2 "$T/out" | tr '\n' ' ')'"

# P8 — the verdicts worker answers 503.
reset
prs "$(pr 12 "$T0" ai-build)"
lead_ok 12 "$T0"; echo 1 > "$T/w/verdicts_12.rc"
run
[ "$(fields 12)" = "success|$T0|?|?|?" ] && ok || bad "P8 fields 6-10 '$(fields 12)', wanted 'success|$T0|?|?|?'"

# P9 — a draft is emitted with draft=1; P9b no open PRs is a real empty set.
reset
prs "$(pr 12 "$T0" ai-build true)" "$(pr 13 "$T0" "")"
run
[ "$(fld 12 4)" = 1 ] && ok || bad "P9 draft '$(fld 12 4)', wanted 1"
[ "$(fld 13 4)" = 0 ] && ok || bad "P9 non-draft '$(fld 13 4)', wanted 0"
[ "$(fld 13 5)" = - ] && ok || bad "P9 no labels '$(fld 13 5)', wanted -"
reset; echo '[]' > "$T/gh/repos_o_r_pulls"
run
[ "$RC" = 0 ] && [ ! -s "$T/out" ] && ok || bad "P9b [] gave rc=$RC out='$(cat "$T/out")', wanted rc 0 and nothing"

# P11 — the conductor row.
reset
prs "$(pr 41 "$T0" x)" "$(pr 42 "$T0" x)"
jq -nc --arg s "$(iso $((T0+5)))" '{rows:[{id:50,repo:"o/r",number:41,state:"QUEUED",since:$s}]}' > "$T/w/prstate"
run
[ "$(fld 41 13)|$(fld 41 14)" = "QUEUED|$((T0+5))" ] && ok || bad "P11 #41 '$(fld 41 13)|$(fld 41 14)', wanted QUEUED|$((T0+5))"
[ "$(fld 42 13)|$(fld 42 14)" = "-|-" ] && ok || bad "P11 #42 (no row) '$(fld 42 13)|$(fld 42 14)', wanted -|-"
echo 1 > "$T/w/prstate.rc"
run
[ "$(fld 41 13)|$(fld 41 14)" = "?|?" ] && ok || bad "P11 failed read '$(fld 41 13)|$(fld 41 14)', wanted ?|?"
# Five full pages and #42 still not seen: unreadable, not absent.
rm -f "$T/w/prstate.rc"
# Page 1 has ids 5000..4001 (#41 first), then before=4001, 3001, 2001, 1001.
page() { # page <top-id> <file>
  jq -nc --argjson hi "$1" '{rows:[range(0;1000) | ($hi - .) as $id
    | {id:$id, repo:"o/r", number:(if $id == 5000 then 41 else 100000 + $id end), state:"QUEUED", since:"2023-01-01T00:00:00Z"}]}' > "$2"
}
page 5000 "$T/w/prstate"
for hi in 4000 3000 2000 1000; do page "$hi" "$T/w/prstate.before_$((hi+1))"; done
# A sixth page would exist; reading it is past the bound.
page 0 "$T/w/prstate.before_1"
: > "$T/w.calls"
run
[ "$(grep -c '/api/pr-state?' "$T/w.calls")" = 5 ] && ok || bad "P11 wanted 5 pr_state pages, got $(grep -c '/api/pr-state?' "$T/w.calls")"
[ "$(fld 41 13)" = QUEUED ] && ok || bad "P11 #41 on page 1 '$(fld 41 13)', wanted QUEUED"
[ "$(fld 42 13)|$(fld 42 14)" = "?|?" ] && ok || bad "P11 #42 past 5 pages '$(fld 42 13)|$(fld 42 14)', wanted ?|?"

# P12 — the first_seen anchor.
reset
prs "$(pr 12 "$T0" ai-build)"
checks 12 queued "" "Queued"
run
[ "$(nputs)" = 1 ] && ok || bad "P12 wanted one PUT, got $(cat "$T/puts" 2>/dev/null)"
[ "$(jq -r .key "$T/puts" 2>/dev/null)" = "o/r#12|$(sha 12 | cut -c1-12)|queued" ] && ok || bad "P12 PUT key '$(jq -r .key "$T/puts" 2>/dev/null)'"
[ "$(fld 12 22)" = "$NOW" ] && ok || bad "P12 first run first_seen '$(fld 12 22)', wanted $NOW"
NOW0=$NOW; NOW=$((NOW+500))
run
NOW=$NOW0
[ "$(nputs)" = 1 ] && ok || bad "P12 the second run wrote another PUT: $(cat "$T/puts" 2>/dev/null)"
[ "$(fld 12 22)" = "$NOW0" ] && ok || bad "P12 second run first_seen '$(fld 12 22)', wanted the stored $NOW0"
reset
prs "$(pr 12 "$T0" ai-build)"
echo 75 > "$T/gh/repos_o_r_commits_$(sha 12)_check-runs.rc"
run
[ -s "$T/puts" ] && bad "P12 an unreadable phase wrote an anchor: $(cat "$T/puts")" || ok
[ "$(fld 12 22)" = '?' ] && ok || bad "P12 unreadable phase first_seen '$(fld 12 22)', wanted ?"

# P13 — the status endpoint refused.
reset
prs "$(pr 12 "$T0" ai-build)"
merge_v 12 $((T0+60))
echo 75 > "$T/gh/repos_o_r_commits_$(sha 12)_status.rc"; echo 403 > "$T/gh/repos_o_r_commits_$(sha 12)_status.st"
run
[ "$(fld 12 6)|$(fld 12 7)" = "?|?" ] && ok || bad "P13 lead_status '$(fld 12 6)|$(fld 12 7)', wanted ?|?"
[ "$(fld 12 8)" = MERGE ] && ok || bad "P13 the verdict did not stay readable: '$(fld 12 8)'"
# P13b — a status whose time does not parse is unreadable, never absent or 0.
rm -f "$T/gh/repos_o_r_commits_$(sha 12)_status.rc" "$T/gh/repos_o_r_commits_$(sha 12)_status.st"
echo '{"statuses":[{"context":"lead-verdict","state":"success","updated_at":"yesterday"}]}' > "$T/gh/repos_o_r_commits_$(sha 12)_status"
run
[ "$(fld 12 6)|$(fld 12 7)" = "success|?" ] && ok || bad "P13b unparseable updated_at '$(fld 12 6)|$(fld 12 7)', wanted success|?"

# P14 — the resolver claim.
reset
prs "$(pr 12 "$T0" ai-build)"
printf '%s\tprovenance-ci-red\t%s\t%s\t-\t-\n' "$(sha 12)" $((T0+100)) $((T0+500)) > "$T/claims/o_r_12"
run
[ "$(fld 12 15)" = $((T0+500)) ] && ok || bad "P14 resolver_at '$(fld 12 15)', wanted $((T0+500))"
printf '%s\tprovenance-ci-red\t%s\t%s\t-\t-\n' "$(sha 99)" $((T0+100)) $((T0+500)) > "$T/claims/o_r_12"
run
[ "$(fld 12 15)" = - ] && ok || bad "P14 claim on another head '$(fld 12 15)', wanted -"
printf '%s\tprovenance-ci-red\t%s\tsoon\t-\t-\n' "$(sha 12)" $((T0+100)) > "$T/claims/o_r_12"
run
[ "$(fld 12 15)" = '?' ] && ok || bad "P14c a non-epoch active_at '$(fld 12 15)', wanted ?"

# P15 — dequeue owner actions, read only on a dequeue signal.
reset
prs "$(pr 51 "$T0" ai-build,dequeued)" "$(pr 52 "$T0" dequeued)" "$(pr 53 "$T0" ai-build)"
jq -nc --arg a "$(iso $((T0+10)))" --arg b "$(iso $((T0+20)))" \
  '{rows:[{id:1,updated_at:$a},{id:2,updated_at:$b}],truncated:false}' > "$T/w/dqw_51"
echo 1 > "$T/w/dqw_52.rc"
run
[ "$(fld 51 16)" = $((T0+20)) ] && ok || bad "P15 #51 dqw_action_at '$(fld 51 16)', wanted $((T0+20))"
[ "$(fld 52 16)" = '?' ] && ok || bad "P15 #52 dqw rc 1 '$(fld 52 16)', wanted ?"
[ "$(fld 53 16)" = - ] && ok || bad "P15 #53 no signal '$(fld 53 16)', wanted -"
grep -q 'dequeue-watch.*pr=53' "$T/w.calls" && bad "P15 #53 had no dequeue signal but was read" || ok
[ "$(grep -c '/api/dequeue-watch' "$T/w.calls")" = 2 ] && ok || bad "P15 wanted 2 dequeue-watch reads, got $(grep -c '/api/dequeue-watch' "$T/w.calls")"

# P16 — a label with a tab in it still gives 22 fields.
reset
prs "$(pr 12 "$T0" "$(printf 'a\tb'),c")"
run
[ "$(fld 12 5)" = "ab,c" ] && ok || bad "P16 labels '$(fld 12 5)', wanted ab,c"
bad16=$(awk -F'\t' 'NF != 22' "$T/all.out")
[ -s "$T/all.out" ] && [ -z "$bad16" ] && ok || bad "P16 lines not 22 fields: $bad16"
grep -qP '\t\t|\t$|^\t' "$T/all.out" && bad "P16 a blank field was printed: $(grep -P '\t\t|\t$' "$T/all.out" | head -1)" || ok

# P5 — every call in every case went through gh_rest / _jobs_req, none GraphQL,
# and the bare gh CLI was never run.
[ -s "$T/all.calls" ] && ok || bad "P5 no calls were logged at all"
grep -qi graphql "$T/all.calls" && bad "P5 a graphql call: $(grep -i graphql "$T/all.calls" | head -1)" || ok
[ -s "$T/gh-shim.calls" ] && bad "P5 the gh CLI was run directly: $(cat "$T/gh-shim.calls")" || ok

echo "stuck-work-facts-pr: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
