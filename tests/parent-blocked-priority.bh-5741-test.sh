#!/bin/bash
# tests/parent-blocked-priority.bh-5741-test.sh — BH-5741: a BLOCKed parent PR
# with approved stacked children gets the next fix round, and pages once when
# no fix round starts for 2 h.
#
# WHAT IS CLAIMED. On 2026-10-09, 16 approved PRs waited on 9 unmerged parents,
# and 4 of those parents had a lead BLOCK that no fix round picked up. The lane
# now ranks a candidate with a standing BLOCK (review-changes-requested or
# head-not-reapproved) and open approved children (open PRs whose base is its
# head branch) above ordinary candidates and below main-red. It logs the reason
# (`PRIORITY parent`), and after BR_PARENT_WAIT_ALERT_MIN with no fix round it
# writes ONE lane-alert line per episode.
#
# The REAL bin/blocked-resolver.sh runs a tick over a scratch $HARNESS with a
# fake `gh` that answers the REST envelope from files. The assertions are on the
# lane's own ` -> ` dispatch lines, its log, the recorded lane-alert calls and
# $ST/.parent-wait.tsv — never on the source text.
#
# Run from anywhere: tests/parent-blocked-priority.bh-5741-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos" "$T/f" "$T/tmp"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
# Only the module under test is installed: the other optional rungs have their
# own suites, and a carry or a CI park here would hide the order under test.
OPTD="$H/bin/lib/br/opt"; mkdir -p "$OPTD"; rm -f "$OPTD"/*.sh
PMOD="$DIR/bin/lib/br/opt/parentprio.sh"
[ -r "$PMOD" ] && cp "$PMOD" "$OPTD/parentprio.sh"
chmod +x "$H/bin/"*.sh
export HARNESS_OPERATOR_LOGIN=operator
export MC_MAIN_RED_LABEL=main-red
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh beat.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# lane-alert is RECORDED: "one line, and none on the next tick" is a count.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# The jobs client. job_verdict answers APPROVE, bound to the child's current
# head, for each URL in $T/f/approved, and nothing (rc 2) for every other URL.
# _jobs_req answers the fix-round queue read from $T/f/frq: absent = an empty
# list (fix_round_get rc 2), `outage` = rc 1, anything else = the body as is.
# The REAL bin/lib/fix-round-queue.sh runs on top of it.
export HARNESS_SECRET="fixture-secret-not-real"
cat > "$H/bin/jobs-client.sh" <<EOF
jobs_configured() { return 0; }
_jobs_log() { :; }
_jobs_req() {
  case "\$2" in
    /api/fix-rounds\?*)
      [ -f "$T/f/frq" ] || { printf '{"fix_round_jobs":[]}'; return 0; }
      [ "\$(cat "$T/f/frq")" = outage ] && return 1
      cat "$T/f/frq"; return 0 ;;
  esac
  return 2
}
job_verdict() {
  grep -qxF "\$1" "$T/f/approved" 2>/dev/null || return 2
  local n=\${1##*/}
  printf 'APPROVE\t2\tclaude\t-\tj1\t%s\n' "\$(jq -r '.head.sha' "$T/f/pr-\$n.json")"
}
job_verdict_headbound() { :; }
# No builds-of-record rows: the merged-ticket check reads "nothing merged".
job_artifact_feed() { return 0; }
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF

# ---------------------------------------------------------------------------
# Fixtures. pr-<n>.json is the REST PR object; the open list is all of them.
# PRADD <n> <base-ref> [draft]   head sha = 40 x <n mod 10>, branch ticket/ts-<n>
PRADD() {
  local h; h=$(printf "%040d" 0 | tr 0 "$(( $1 % 10 ))")
  jq -nc --argjson n "$1" --arg h "$h" --arg b "ticket/ts-$1" --arg base "$2" \
        --argjson d "${3:-false}" --arg u "$(ISO 300)" \
    '{number:$n, html_url:("https://github.com/o/tproj/pull/"+($n|tostring)), state:"open",
      title:("TK-"+($n|tostring)+": the work"), body:"body", draft:$d, updated_at:$u, created_at:$u,
      user:{login:"operator", type:"User"}, head:{sha:$h, ref:$b, repo:{full_name:"o/tproj", fork:false}},
      base:{ref:$base}, merged_at:null, closed_at:null, labels:[], mergeable_state:"clean"}' \
    > "$T/f/pr-$1.json"
  jq -s 'sort_by(.number)' "$T"/f/pr-*.json > "$T/f/list.json"
}
HEAD_OF() { jq -r '.head.sha' "$T/f/pr-$1.json"; }
# LEAD <n> — a lead's CHANGES_REQUESTED standing on the PR's current head.
LEAD() {
  jq -nc --arg c "$(HEAD_OF "$1")" \
    '[{id:1, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"operator", type:"User"},
       author_association:"MEMBER", body:"Please fix the null check."}]' > "$T/f/reviews-$1.json"
}
APPROVE() { local n; for n in "$@"; do echo "https://github.com/o/tproj/pull/$n" >> "$T/f/approved"; done; }
# CROW <n> <reason> — a conductor hand-off row; REC <n> <labels-json> its build record.
CROW() {
  printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#$1" "$NOW" "$(HEAD_OF "$1")" "$(HEAD_OF "$1")" \
    "$2" "https://github.com/o/tproj/pull/$1" >> "$H/state/merge-conductor/pr-state.tsv"
}
REC() {
  local d="$H/builds/tproj-TK-$1-20261009000001"
  mkdir -p "$d"
  printf 'PR_CREATED https://github.com/o/tproj/pull/%s\n' "$1" > "$d/RESULT"
  printf '{"labels":%s}\n' "$2" > "$d/ticket-meta.json"
}
LEDGER="$H/state/blocked-resolver/.parent-wait.tsv"
CK=tproj-TK-51
URL51=https://github.com/o/tproj/pull/51
SEED() { # SEED <first_seen> <fix0> <alerted> [ck] [url]
  mkdir -p "$H/state/blocked-resolver"
  printf 'tproj\t%s\t%s\t%s\t%s\t%s\n' "${4:-$CK}" "${5:-$URL51}" "$1" "$2" "$3" >> "$LEDGER"
}
RESET() {
  rm -rf "$T/f"/* "$H/state/blocked-resolver" "$H/state/merge-conductor/"* "$H/builds"/* \
         "$H/logs/blocked-resolver.log" "$T/tmp"/* 2>/dev/null
  mkdir -p "$T/f"; echo '[]' > "$T/f/list.json"; : > "$T/f/approved"
  : > "$T/lane-alert.txt"; : > "$T/run.log"; : > "$T/gh.txt"
  printf '%s\n' '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}' > "$T/f/ratelimit.json"
}
export GH_BUDGET_TTL_S=0

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
F="$T/f"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
case "\$1 \$2" in
  "api rate_limit") cat "\$F/ratelimit.json"; exit 0 ;;
esac
if [ "\$1" = api ] && [ "\$2" = -i ] && [ "\$3" = -X ]; then
  M="\$4"; P="\$5"
  case "\$M \$P" in
    "GET repos/o/tproj/pulls"|"GET repos/o/tproj/pulls?"*) send 200 "\$(cat "\$F/list.json")" ;;
    "GET repos/o/tproj/pulls/"*"/reviews"*)
      N=\${P#repos/o/tproj/pulls/}; N=\${N%%/*}
      send 200 "\$(cat "\$F/reviews-\$N.json" 2>/dev/null || echo '[]')" ;;
    "GET repos/o/tproj/pulls/"*)
      N=\${P##*/}
      [ -f "\$F/pr-\$N.json" ] || { send 404 '{"message":"Not Found"}'; exit 0; }
      send 200 "\$(cat "\$F/pr-\$N.json")" ;;
    "GET repos/o/tproj/issues/"*) send 200 '{"labels":[],"state":"open"}' ;;
    *) send 200 '[]' ;;
  esac
  exit 0
fi
echo ""
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
# OBSERVE: the ` -> ` line is written before the dispatch either way, so the
# order is observable without a rung running.
: > "$H/flags/blocked-resolver-observe"

BRENV=()
# HUB_BUILD_OK=1: this box builds here, so br_one never reads the fix-round
# queue itself and the ` -> ` line is the same on the hub and off it.
TICK() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" TMPDIR="$T/tmp" \
           HUB_BUILD_OK=1 BR_PER_TICK=9 env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>&1 ) || true; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
# The PR numbers in dispatch order, one line.
ORDER() { LOG | grep -F ' -> ' | sed -nE 's#.* tproj/o-tproj-([0-9]+) .*#\1#p' | tr '\n' ' '; }
FIRST() { LOG | grep -F ' -> ' | head -1 | sed -nE 's#.* tproj/o-tproj-([0-9]+) .*#\1#p'; }
NPRIO() { LOG | grep -c 'PRIORITY parent'; }
NALERT() { grep -c -- "--id parent-blocked-children-tproj-$CK " "$T/lane-alert.txt"; }
ROW51() { awk -F'\t' -v k="$CK" '$2 == k' "$LEDGER" 2>/dev/null; }

# P1 fixture: #50 BLOCKed, discovered first, no children. #51 BLOCKed with
# three open, non-draft, approved children #52 #53 #54 based on ticket/TK-51.
P1FIX() {
  PRADD 50 main; PRADD 51 main
  PRADD 52 ticket/TK-51; PRADD 53 ticket/TK-51; PRADD 54 ticket/TK-51
  LEAD 50; LEAD 51; APPROVE 52 53 54
}

# ===========================================================================
# P1 — the parent with approved children goes first (red on main).
# ===========================================================================
RESET; P1FIX; TICK
[ "$(FIRST)" = 51 ] && ok || bad "P1: the parent #51 must be dispatched first, got '$(FIRST)' (order: $(ORDER)) $(tail -3 "$T/run.log")"
[ "$(NPRIO)" = 1 ] && ok || bad "P1: exactly one PRIORITY parent line, got $(NPRIO): $(LOG | grep PRIORITY)"
LOG | grep 'PRIORITY parent' | grep -q 'o-tproj-51 .*3 approved child PR(s).*#52 #53 #54' && ok \
  || bad "P1: the PRIORITY line must name #51, 3 approved child PR(s) and the children: $(LOG | grep PRIORITY)"
LOG | grep -q 'tick: candidates=2 ' && ok || bad "P1: both BLOCKed PRs stay in the stream: $(LOG | grep 'tick:')"
[ "$(ORDER)" = "51 50 " ] && ok || bad "P1: #50 is still dispatched, after #51, got '$(ORDER)'"

# P1b — below main-red: #49 is a conductor head-not-reapproved row whose build
# record carries the main-red label.
RESET; P1FIX; PRADD 49 main; CROW 49 'head-not-reapproved: BLOCK on the head'; REC 49 '[{"name":"main-red"}]'
TICK
[ "$(ORDER)" = "49 51 50 " ] && ok || bad "P1b: main-red #49, then parent #51, then #50 — got '$(ORDER)'"

# P1c — hotfix still first.
RESET; P1FIX; PRADD 48 main; CROW 48 'head-not-reapproved: BLOCK on the head'; REC 48 '[{"name":"hotfix"}]'
TICK
[ "$(ORDER)" = "48 51 50 " ] && ok || bad "P1c: hotfix #48, then parent #51, then #50 — got '$(ORDER)'"

# ===========================================================================
# P2 — one ALERTS line after 2 h with no fix round, none on the next tick.
# ===========================================================================
RESET; P1FIX; SEED $((NOW - 7260)) 0 0
TICK
[ "$(NALERT)" = 1 ] && ok || bad "P2: exactly one lane-alert call for $CK, got $(NALERT): $(cat "$T/lane-alert.txt")"
grep -- "--id parent-blocked-children-tproj-$CK " "$T/lane-alert.txt" | grep -F "$URL51" | grep -q '3 approved child PR(s)' && ok \
  || bad "P2: the alert must name $URL51 and 3 approved child PR(s): $(cat "$T/lane-alert.txt")"
[ "$(ROW51 | cut -f6)" != 0 ] && [ -n "$(ROW51 | cut -f6)" ] && ok || bad "P2: the ledger row must carry an alerted stamp: '$(ROW51)'"
# P2b — the next tick adds nothing.
TICK
[ "$(NALERT)" = 1 ] && ok || bad "P2b: the second tick must not alert again, got $(NALERT)"
compgen -G "$T/tmp/br-parent.*" >/dev/null && bad "P2: the tick must leave no br-parent temp file: $(ls -A "$T/tmp")" || ok

# P2c — under the threshold: no alert, the row is kept.
RESET; P1FIX; SEED $((NOW - 3600)) 0 0
TICK
[ "$(NALERT)" = 0 ] && ok || bad "P2c: 60 min is under the threshold, got $(NALERT) alert(s)"
[ "$(ROW51 | cut -f4)" = $((NOW - 3600)) ] && ok || bad "P2c: the row must be kept unchanged: '$(ROW51)'"

# P2d — a fix round started (the record's fixrounds rose) resets the clock.
RESET; P1FIX; SEED $((NOW - 7260)) 0 0
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg k "$CK" '{project:"tproj",rkey:$k,fixrounds:1,rebuilds:0,outcome:"",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/$CK.json"
TICK
[ "$(NALERT)" = 0 ] && ok || bad "P2d: a started fix round must not page, got $(NALERT)"
FS=$(ROW51 | cut -f4); [ "${FS:-0}" -ge "$NOW" ] 2>/dev/null && ok || bad "P2d: the episode must restart (first_seen >= NOW), row '$(ROW51)'"
[ "$(ROW51 | cut -f5)" = 1 ] && ok || bad "P2d: fix0 must be the new count 1, row '$(ROW51)'"

# P2e — a round in flight on the queue: no alert. A queue outage still pages.
RESET; P1FIX; SEED $((NOW - 7260)) 0 0
printf '{"fix_round_jobs":[{"cap_key":"%s","status":"claimed","box":"box-tproj"}]}' "$CK" > "$T/f/frq"
TICK
[ "$(NALERT)" = 0 ] && ok || bad "P2e: a claimed fix round must not page, got $(NALERT)"
echo outage > "$T/f/frq"
TICK
[ "$(NALERT)" = 1 ] && ok || bad "P2e: a queue outage must still page once, got $(NALERT)"
grep -- "--id parent-blocked-children-tproj-$CK " "$T/lane-alert.txt" | grep -qi 'queue was unreadable' && ok \
  || bad "P2e: the outage alert must say the queue was unreadable: $(cat "$T/lane-alert.txt")"

# P2f — knob 0 is off; a non-number is the 120-minute default, said once.
RESET; P1FIX; SEED $((NOW - 7260)) 0 0
BRENV=(BR_PARENT_WAIT_ALERT_MIN=0); TICK; BRENV=()
[ "$(NALERT)" = 0 ] && ok || bad "P2f: BR_PARENT_WAIT_ALERT_MIN=0 must never page, got $(NALERT)"
BRENV=(BR_PARENT_WAIT_ALERT_MIN=abc); TICK; BRENV=()
[ "$(NALERT)" = 1 ] && ok || bad "P2f: BR_PARENT_WAIT_ALERT_MIN=abc must fall back to 120 and page, got $(NALERT)"
LOG | grep -q 'BR_PARENT_WAIT_ALERT_MIN' && ok || bad "P2f: a bad knob value must be named in the log"

# P2g — prune: a row for a parent not in the stream goes, #51 stays.
RESET; P1FIX; SEED $((NOW - 3600)) 0 0; SEED $((NOW - 3600)) 0 0 tproj-TK-77 https://github.com/o/tproj/pull/77
TICK
grep -q . <<<"$(awk -F'\t' '$2 == "tproj-TK-77"' "$LEDGER")" && bad "P2g: the #77 row must be pruned: $(cat "$LEDGER")" || ok
[ -n "$(ROW51)" ] && ok || bad "P2g: the #51 row must stay: $(cat "$LEDGER" 2>/dev/null)"

# ===========================================================================
# P3 — today's order wherever the rule does not apply.
# ===========================================================================
# P3: no children.
RESET; PRADD 50 main; PRADD 51 main; LEAD 50; LEAD 51; TICK
[ "$(FIRST)" = 50 ] && ok || bad "P3: with no children #50 runs first, got '$(FIRST)'"
[ "$(NPRIO)" = 0 ] && ok || bad "P3: no PRIORITY parent line without children"

# P3b: a draft child and an unapproved child do not count.
RESET; PRADD 50 main; PRADD 51 main; PRADD 52 ticket/TK-51 true; PRADD 53 ticket/TK-51
LEAD 50; LEAD 51; APPROVE 52; TICK
[ "$(FIRST)" = 50 ] && ok || bad "P3b: draft/unapproved children must not promote #51, got '$(FIRST)'"
[ "$(NPRIO)" = 0 ] && ok || bad "P3b: no PRIORITY parent line, got $(LOG | grep PRIORITY)"

# P3c: a non-BLOCK reason (merge-failed-twice) is not promoted — the same
# order as the module switched off.
RESET; P1FIX; rm -f "$T/f/reviews-51.json"; CROW 51 'merge-failed-twice: gh pr merge refused'
BRENV=(BR_OPT_OFF=parentprio); TICK; BRENV=(); BASE_ORDER=$(ORDER)
rm -f "$H/logs/blocked-resolver.log"; scratch_rm "$H/state/blocked-resolver" || exit 1; TICK
[ "$(ORDER)" = "$BASE_ORDER" ] && ok || bad "P3c: a non-BLOCK parent keeps today's order '$BASE_ORDER', got '$(ORDER)'"
[ "$(NPRIO)" = 0 ] && ok || bad "P3c: no PRIORITY parent line for a merge-failed-twice row"
[ "$(FIRST)" = 50 ] && ok || bad "P3c: the BLOCKed #50 (fix round, cheaper) runs first, got '$(FIRST)'"

# P3d: the kill switch.
RESET; P1FIX; BRENV=(BR_OPT_OFF=parentprio); TICK; BRENV=()
[ "$(FIRST)" = 50 ] && ok || bad "P3d: BR_OPT_OFF=parentprio must restore discovery order, got '$(FIRST)'"
[ "$(NPRIO)" = 0 ] && ok || bad "P3d: no PRIORITY parent line with the module off"

echo "parent-blocked-priority: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
