#!/bin/bash
# tests/orphan-reconcile-rollout-master.bh-985-test.sh — a rollout master, listed
# or parked, is OWNED by its waves, and the wave that is ready to build is the
# only thing the reconciler launches.
#
# WHY IT EXISTS (BH-985, child .4 of #816). When the rollout lane files a
# master's waves it PARKS the master: the issues lane removes the `ai-build`
# label. bin/orphan-reconcile.sh's whole job is to find open work nobody owns
# and launch it, so the question this fixture answers is the one that decides
# whether the lane is safe to ship: does the reconciler read a parked master as
# a dropped ticket and re-launch it (which would plan a ticket whose waves are
# already filed, and could file them twice), or does it read the waves naming it
# as its owners?
#
# It reads them as owners — class (c), the same rule the de-labelled decompose
# parent already goes through, because a rollout child carries `Part of #<n>` in
# exactly the shape bin/lib/file-children.sh's decompose arm writes it. That is
# why this ticket changes NO code in bin/orphan-reconcile.sh: the fixture IS the
# deliverable, and it is what would go red if someone narrowed class (c) to
# decompose children only.
#
# WHAT IT PINS:
#   1. The master (#970), still on the `ai-build` list the shim returns, reads
#      OWNED, named by both open waves.
#   2. Wave 2 (#972) reads OWNED — its `Blocked-by: #971 (hard)` is still open.
#   3. Wave 1 (#971) is the ORPHAN, and the only key launched.
#   4. The parked master (truly de-labelled, off the list, run 3) is simply not
#      a candidate, and nothing else moves.
#
# HOW IT DRIVES: the real bin/orphan-reconcile.sh, on its own scratch tree, with
# gh and curl as PATH shims answering from fixtures and run-build.sh as a shim
# that records its argv. No network, no secrets, no model.
# Run from anywhere: bash tests/orphan-reconcile-rollout-master.bh-985-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
cp "$DIR/bin/orphan-reconcile.sh" "$H/bin/"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-budget.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/"
# The REST contract itself (BH-1163, landed on main after this ticket was
# built). Copied, never stubbed: gh_rest_issue_list moved out of gh-rest.sh
# into gh-rest-list.sh, and bin/orphan-reconcile.sh now reads the board through
# it instead of the `gh issue/pr list` CLI this fixture used to shim.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts-called.log"\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# gh shim — a REST endpoint, not the CLI (BH-1163, landed after this ticket was
# built). bin/lib/gh-rest.sh calls `gh api -i -X GET <path> …`, so this answers
# with a status LINE, a blank line and a body — the same shim
# tests/orphan-reconcile-test.sh already proved against the real gh-rest.sh /
# gh-rest-list.sh contract; the fixtures below stay authored in the readable
# shape (comments a list, updatedAt/closedAt) and this shim's jq translates it
# to the wire shape, so the script under test only ever sees REST.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$ARGS" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c --argjson n "$n" '[ .[] | select(.number==$n) | (.comments // [])[] ]' \
                 "$HARNESS/fixture/open.json")" ;;
  *"/pulls"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, title, body, head:{ref:.headRefName}} ]' \
                 "$HARNESS/fixture/prs.json")" ;;
  *"/issues/"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(jq -c '{number, state:(.state|ascii_downcase), closed_at:.closedAt}' \
                 "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*"state=all"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, state:(.state|ascii_downcase), closed_at:.closedAt} ]' \
                 "$HARNESS/fixture/states.json")" ;;
  *"/issues"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, title, body, comments:((.comments // [])|length),
                               updated_at:.updatedAt} + (if .pull_request then {pull_request:.pull_request} else {} end) ]' \
                 "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  */api/queue*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/queuerows.json")" ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

NOWISO() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# ── the fixture board: one filed rollout, exactly as the lane leaves it ──────
# #970 is the master; the shim still lists it under `ai-build` (run 1 — the
# moment before the lane parks it), and run 3 is the parked case (off the list).
# Its body is the author's own rollout section. #971 and #972 are the waves, carrying the
# footer lines bin/lib/file-children.sh's rollout arm writes.
MASTER_BODY='project-4 needs its MCP server in waves.

## Rollout
### Wave: schema
### Wave: routes
after: schema'
WAVE1_BODY='Part of #970
Order: 1 of 2
Rollout wave 1 of 2: planned by its author; the PLAN stage fleshes it out. Never split into a rollout again.'
WAVE2_BODY='Part of #970
Order: 2 of 2
Blocked-by: #971 (hard)
Rollout wave 2 of 2: planned by its author; the PLAN stage fleshes it out. Never split into a rollout again.'

open_board() { # open_board [with-master|without-master]
  local upd; upd=$(NOWISO 7200)
  jq -n --arg mb "$MASTER_BODY" --arg w1 "$WAVE1_BODY" --arg w2 "$WAVE2_BODY" \
        --arg u "$upd" --arg mode "${1:-with-master}" '
    [ {number:970,title:"TK-970 project-4 mcp rollout",body:$mb,comments:[],updatedAt:$u},
      {number:971,title:"TK-970.1: schema",body:$w1,comments:[],updatedAt:$u},
      {number:972,title:"TK-970.2: routes",body:$w2,comments:[],updatedAt:$u} ]
    | if $mode == "without-master" then map(select(.number != 970)) else . end' \
    > "$H/fixture/open.json"
  cat > "$H/fixture/states.json" <<JSON
[
 {"number":970,"state":"OPEN","closedAt":null},
 {"number":971,"state":"OPEN","closedAt":null},
 {"number":972,"state":"OPEN","closedAt":null}
]
JSON
  echo '[]' > "$H/fixture/prs.json"
  echo '{"jobs":[]}' > "$H/fixture/jobs.json"
  echo '{"queue":[]}' > "$H/fixture/queuerows.json"
}

reset() { # reset [with-master|without-master]
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/alerts-called.log" "$H/gh-calls.log" "$H/fixture"/issue-*.json
  open_board "${1:-with-master}"
}
run()      { "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null; }
launched() { sort -u "$H/launches.log" 2>/dev/null; }
nlaunch()  { grep -c . "$H/launches.log" 2>/dev/null || true; }
verdict()  { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT"; }

# ── 1. the filed rollout, one run ───────────────────────────────────────────
reset with-master
OUT=$(run)
[ -n "$OUT" ] && ok || bad "the reconciler classified nothing — the fixture never ran"
grep -q '^TK-970	970	OWNED	children:#971,#972 open (decompose parent)' <<<"$OUT" && ok \
  || bad "a listed rollout master must be OWNED by its open waves: $(verdict TK-970)"
grep -q '^TK-972	972	OWNED	blocker:#971 still open' <<<"$OUT" && ok \
  || bad "wave 2 must be held by its hard blocker, wave 1: $(verdict TK-972)"
grep -q '^TK-971	971	ORPHAN	no owner' <<<"$OUT" && ok \
  || bad "wave 1 is released work nobody is building — it must read ORPHAN: $(verdict TK-971)"
grep -qx "project-5 971 TK-971" <<<"$(launched)" && ok \
  || bad "wave 1 must be the launch: $(launched)"
[ "$(nlaunch)" = 1 ] && ok || bad "exactly one wave may launch, got $(nlaunch): $(launched)"
grep -q 'reconcile: open=3 owned=2 orphans=1 enqueued=TK-971' "$H/logs/$P.log" && ok \
  || bad "the one-line summary must carry the counts: $(grep -o 'reconcile: .*' "$H/logs/$P.log" | tail -1)"

# ── 2. the master is never a launch, however it is read ─────────────────────
grep -q 'project-5 970 TK-970' <<<"$(launched)" \
  && bad "the master must never be launched — its waves are already filed: $(launched)" || ok
grep -q 'project-5 972 TK-972' <<<"$(launched)" \
  && bad "a wave under an open blocker must never be launched: $(launched)" || ok

# ── 3. a master that left the list is simply not a candidate ────────────────
# The de-labelled master the shim no longer returns. Nothing about the waves
# changes: wave 1 is still the one launchable thing.
reset without-master
OUT=$(run)
[ -z "$(verdict TK-970)" ] && ok || bad "a master that is not on the list must get no verdict row: $(verdict TK-970)"
grep -q '^TK-971	971	ORPHAN	no owner' <<<"$OUT" && ok \
  || bad "wave 1 must still read ORPHAN with the master off the list: $(verdict TK-971)"
grep -q '^TK-972	972	OWNED	blocker:#971 still open' <<<"$OUT" && ok \
  || bad "wave 2 must still be held by wave 1 with the master off the list: $(verdict TK-972)"
[ "$(launched)" = "project-5 971 TK-971" ] && ok \
  || bad "wave 1 must be the only launch: $(launched)"

echo "orphan-reconcile-rollout-master.bh-985: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
