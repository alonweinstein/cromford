#!/bin/bash
# tests/pr-owner-clock-db.bh-5003-test.sh — the D1 `pr_owners` rows decide
# which PRs bin/pr-owner-sweep.sh treats as owned; state/pr-owners/<repo>.json
# is their local mirror and write-behind queue (BH-5003, scope D).
#
# WHY THIS EXISTS. Before BH-5003 the overlay was `file + fresh rows`: a file
# entry with no open D1 row survived into the sweep's `prev` map and handed its
# old `since` to a PR that is open again (a reopened PR, or a stale file that
# bin/restore-merge.sh put back from R2). That is the file acting as the record.
#
# THE RULE UNDER TEST (PR_OWNERS_ROWS_RECORD=1, the default):
#   drop    when pr_owners_list answered rc 0 with fewer than 500 rows and the
#           last push landed (no `push_pending`), a file entry survives only if
#           D1 holds an open row for that PR. One log line counts the drops.
#   merge   exactly today's overlay when: the GET failed (rc 1), the answer hit
#           the route's 500-row cap, `push_pending` is true, or the knob is 0.
#   pending `push_pending:true` is written when the PUT fails and removed when
#           a later PUT lands.
#   clock   deleting the file keeps the `since` clock when D1 answers (O1; this
#           is green on main too and is pinned, not fixed, here).
#
# Cases O1..O7 and M1 are the plan's acceptance list for this suite. Driven
# through the production entry point (the sweep itself), never grepped.
# Run from anywhere: tests/pr-owner-clock-db.bh-5003-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

# The clock is read ONCE, here, and every fixture PR stamp is derived from it.
# Every stamp this suite COMPARES is an absolute literal.
NOW=$(date -u +%s)
W_MINUS=2026-09-16T23:59:00Z    # a row the worker stamped BEFORE our push (never overlays)
PAST=2020-01-01T00:00:00Z       # the `since` a dropped file entry must NOT carry back

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
SWEEP_SRC="$DIR/bin/pr-owner-sweep.sh"
scratch_install_closure bin/pr-owner-sweep.sh "$H" >/dev/null \
  || { echo "FAIL: cannot install the sweep's closure"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
  || { echo "FAIL: cannot install the jobs client's closure"; exit 1; }
# The conductor file is read only on the conductor's box (BH-5124, bin/lib/pr-owner/mc-read.sh):
# name this scratch box the hub so the fixture's fresh pr-state.tsv is trusted.
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null \
  || { echo "FAIL: cannot install bin/lib/hub-box.sh"; exit 1; }
echo box-hub > "$H/state/box-name"; export HUB_BOX_NAME=box-hub
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf 'GH_ADMIN_TOKEN=admintok\n' > "$H/env/github-admin.env"
export GH_TOKEN=defaulttok
export GH_BUDGET_TTL_S=0
export JOBS_RETRY_SLEEP=0
export REQ_SINK="$H/req.log"
export PO_OWNERS_JSON="$H/d1-owners.json"

printf '#!/bin/bash\nprintf "%%s\\n" "${FAKE_BOX:-box-project-5-1}"\n' > "$H/bin/box-for.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts-called.log"\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/box-for.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"

# gh shim — tests/pr-owner-sweep-server-clock.bh-1042-test.sh's, unchanged.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
case "$1 $2" in
  "api rate_limit")
    core_rem="${GH_BUDGET_CORE:-4000}"
    now=$(date -u +%s)
    printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":%s},"graphql":{"remaining":%s,"limit":5000,"reset":%s}}}\n' \
      "$core_rem" "$now" "$core_rem" "$now"
    exit 0 ;;
  "api repos/") echo 1234; exit 0 ;;
  "api repos"*) echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*)   cat "$HARNESS/fixture/open.json" ;;
  *"pr list"*"--state merged"*) cat "$HARNESS/fixture/merged.json" ;;
  *"pr comment"*|*"pr close"*|*"pr edit"*)
    printf '%s\n' "$*" >> "$HARNESS/gh-writes.log" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

# curl shim for bin/jobs-client.sh. The pr_owners rows live in $PO_OWNERS_JSON
# (the route's own answer shape, as_of included); the PUT is stamped with the
# fixed worker clock 2026-09-17T00:00:00Z.
#   PO_GET_FAIL=1   the GET answers 503 (an outage that still reaches HTTP)
#   PO_PUT_FAIL=1   the PUT answers 500 (a row write that did not land)
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/pr-owners*)
    if [ "$M" = PUT ]; then
      if [ "${PO_PUT_FAIL:-0}" = 1 ]; then printf '{"error":"write failed"}\n500\n'
      else printf '{"pr_owners":12,"tombstoned":0,"as_of":"2026-09-17T00:00:00Z"}\n200\n'; fi
    elif [ "${PO_GET_FAIL:-0}" = 1 ]; then
      printf '{"error":"d1 unavailable"}\n503\n'
    elif [ -s "${PO_OWNERS_JSON:-/nonexistent}" ]; then
      cat "$PO_OWNERS_JSON"; printf '\n200\n'
    else
      printf '{"repo":"example-org/project-5","pr_owners":[],"as_of":"2026-09-17T00:00:00Z"}\n200\n'
    fi ;;
  */api/jobs*)  printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  */api/queue*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/queuerows.json")" ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"

cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/ssh-calls.log"
cat > /dev/null
exit 0
SH
chmod +x "$T/fakebin/ssh"
export PATH="$T/fakebin:$PATH"

ISO() { date -u -d "@$(( NOW - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }
D=86400

# --- the fixture repo ---------------------------------------------------------
# #902 is EXTERNAL (the O1 clock). #905 is OWNED by a live conductor row: the
# PR whose file entry D1 holds no row for in O2..O7.
pr() { # pr <number> <title> <author> <mergeable> <updated-age-s> <body>
  printf ' {"number":%s,"title":"%s","headRefName":"ticket/ts-%s","author":{"login":"%s"},"labels":[],"body":"%s","mergeable":"%s","updatedAt":"%s","createdAt":"%s","url":"https://github.com/%s/pull/%s","isDraft":false}' \
    "$1" "$2" "$1" "$3" "$6" "$4" "$(ISO "$5")" "$(ISO $(( $5 + D )))" "$SLUG" "$1"
}
fixture() {
  {
    echo '['
    pr 900 "TK-900: pool build in flight" operator MERGEABLE $((2*D)) ""; echo ','
    pr 902 "Add the CSV mapper" reviewer-1-partner CONFLICTING $((90*D)) ""; echo ','
    pr 905 "TK-905: retention sweeper" operator MERGEABLE $((30*D)) ""; echo ','
    pr 909 "TK-909: the plain orphan" operator MERGEABLE $((30*D)) ""
    echo ']'
  } > "$H/fixture/open.json"
  echo '[]' > "$H/fixture/merged.json"
  cat > "$H/fixture/jobs.json" <<JSON
{"jobs":[
 {"id":"build-project-5-TK-900-1","ticket_id":"TK-900","kind":"build","status":"running","updated_at":"$(ISO 600)","meta":"{\"key\":\"TK-900\"}"}
]}
JSON
  echo '{"queue":[]}' > "$H/fixture/queuerows.json"
  printf '%s#905\tQUEUED\t1757000000\tdeadbee\tdeadbee\t-\tenqueued\thttps://x\n' "$SLUG" \
    > "$H/state/merge-conductor/pr-state.tsv"
}

reset() {
  scratch_rm "$H/state/pr-owners"; scratch_rm "$H/state/gh-budget"
  scratch_rm "$H/logs"; scratch_rm "$H/locks"; scratch_rm "$H/flags"
  mkdir -p "$H/state/pr-owners" "$H/state/gh-budget" "$H/logs" "$H/locks" "$H/flags"
  rm -f "$H/gh-calls.log" "$H/gh-writes.log" "$H/ssh-calls.log" "$H/alerts-called.log" \
        "$REQ_SINK" "$PO_OWNERS_JSON"
  fixture
}
run()   { "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" --explain 2>/dev/null; }
STATEF="$H/state/pr-owners/example-org_project-5.json"
sfield() { jq -r --arg n "$1" --arg f "$2" '.prs[$n][$f] // "MISSING"' "$STATEF" 2>/dev/null; }
ffield() { jq -r --arg f "$1" '.[$f] // "MISSING"' "$STATEF" 2>/dev/null; }
put_body() { grep '^PUT [^ ]*/api/pr-owners ' "$REQ_SINK" 2>/dev/null | tail -1 | cut -d' ' -f3-; }
swlog()  { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
nlog()   { grep -c -- "$1" "$H/logs/pr-owner-sweep.log" 2>/dev/null || true; }
# The D1 answer, built from a PUT body the sweep itself produced (a fixture the
# production pipeline can generate), every row stamped <updated_at>, minus the
# PR numbers given after it.
serve() { # serve <updated_at> [exclude-number...] <<< <put-body>
  local u="$1"; shift
  jq -c --arg u "$u" --argjson ex "[${*// /,}]" \
    '{repo: .repo, as_of: $u,
      pr_owners: (.rows | map(select(.number as $n | $ex | index($n) | not))
                        | map(. + {updated_at: $u}))}' > "$PO_OWNERS_JSON"
}
# file_set <jq-expr> — edit the state file in place (the previous tick's mirror).
file_set() { jq "$1" "$STATEF" > "$T/f.json" && mv -f "$T/f.json" "$STATEF"; }

# The O2 shape: the seeding run recorded #905; D1 holds stale rows for every
# other PR and none for #905; the file says #905 has been OWNED since 2020.
o2_setup() {
  reset
  run >/dev/null
  [ "$(sfield 905 state)" = OWNED ] \
    || bad "fixture: #905 must classify OWNED (conductor QUEUED), got $(sfield 905 state)"
  serve "$W_MINUS" 905 <<<"$(put_body)"
  file_set ".prs[\"905\"].since = \"$PAST\" | del(.push_pending)"
  S902=$(sfield 902 since)
  : > "$H/logs/pr-owner-sweep.log"
}

# ---------- O1. deleting the file keeps the `since` clock (pinned) ------------
reset
run >/dev/null
S=$(sfield 902 since)
[ "$(sfield 902 state)" = EXTERNAL ] && ok || bad "O1: #902 must be EXTERNAL, got $(sfield 902 state)"
serve 2026-09-17T00:00:00Z <<<"$(put_body)"
rm -f "$STATEF"; rm -f "$REQ_SINK"
run >/dev/null
[ "$(sfield 902 since)" = "$S" ] && ok \
  || bad "O1: since must survive deleting the file: want $S got $(sfield 902 since)"
[ -s "$STATEF" ] && ok || bad "O1: the file mirror must be written again"
[ "$(put_body | jq -r '.rows[] | select(.number == 902) | .since' 2>/dev/null)" = "$S" ] && ok \
  || bad "O1: the PUT body must carry since $S: $(put_body | head -c 300)"

# ---------- O2. a file-only PR is dropped: the rows are the record ------------
o2_setup
run >/dev/null
[ "$(sfield 905 since)" != "$PAST" ] && ok \
  || bad "O2: #905 has no open D1 row, yet the file handed back its old since=$PAST"
[ "$(nlog 'file-only PR(s) dropped')" = 1 ] && ok \
  || bad "O2: want one 'file-only PR(s) dropped' line: $(swlog)"
grep -q '1 file-only PR(s) dropped — D1 holds no open row for them (rows are the record)' <<<"$(swlog)" && ok \
  || bad "O2: the drop line names the count and the reason: $(swlog)"
[ "$(sfield 902 since)" = "$S902" ] && ok \
  || bad "O2: #902 has a (stale) D1 row, so its file entry stays: want $S902 got $(sfield 902 since)"
[ -s "$STATEF" ] && ok || bad "O2: the file mirror is still written"

# ---------- O3. push_pending keeps merge mode (write-behind guard) ------------
o2_setup
file_set '.push_pending = true'
run >/dev/null
[ "$(sfield 905 since)" = "$PAST" ] && ok \
  || bad "O3: with push_pending the file entry must be kept: got $(sfield 905 since)"
[ "$(nlog 'file-only PR(s) dropped')" = 0 ] && ok || bad "O3: no drop line under push_pending: $(swlog)"
[ "$(nlog 'push_pending')" -ge 1 ] && ok || bad "O3: a line names the write-behind (push_pending): $(swlog)"

# ---------- O4. GET 503: the file alone, one degraded line --------------------
o2_setup
PO_GET_FAIL=1 run >/dev/null
[ "$(sfield 905 since)" = "$PAST" ] && ok \
  || bad "O4: an outage must not drop anything: got $(sfield 905 since)"
[ "$(nlog 'using state/pr-owners file alone (degraded)')" = 1 ] && ok \
  || bad "O4: want exactly one degraded line: $(swlog)"
[ "$(nlog 'file-only PR(s) dropped')" = 0 ] && ok || bad "O4: no drop line on an outage: $(swlog)"

# ---------- O5. a failing PUT leaves push_pending; the next good PUT clears it -
reset
PO_PUT_FAIL=1 run >/dev/null
[ "$(ffield push_pending)" = true ] && ok \
  || bad "O5: a failed PUT must leave push_pending:true, got $(ffield push_pending)"
[ -s "$STATEF" ] && ok || bad "O5: the file mirror is still written on a failed PUT"
run >/dev/null
[ "$(ffield push_pending)" = MISSING ] && ok \
  || bad "O5: a good PUT must remove push_pending, got $(ffield push_pending)"

# ---------- O6. a 500-row answer keeps merge mode and says so -----------------
o2_setup
jq -c '.pr_owners as $r
       | .pr_owners = ($r + [range(0; 500 - ($r | length)) as $i
                             | ($r[0] + {number: (3000 + $i)})])' \
  "$PO_OWNERS_JSON" > "$T/cap.json" && mv -f "$T/cap.json" "$PO_OWNERS_JSON"
[ "$(jq '.pr_owners | length' "$PO_OWNERS_JSON")" = 500 ] && ok || bad "O6: fixture must hold 500 rows"
run >/dev/null
[ "$(sfield 905 since)" = "$PAST" ] && ok \
  || bad "O6: at the 500-row cap the file entry must be kept: got $(sfield 905 since)"
[ "$(nlog 'file-only PR(s) dropped')" = 0 ] && ok || bad "O6: no drop line at the cap: $(swlog)"
grep -q 'pr-owners.*500' <<<"$(swlog)" && ok || bad "O6: a line names the 500-row cap: $(swlog)"

# ---------- O7. PR_OWNERS_ROWS_RECORD=0 is main's behaviour -------------------
o2_setup
PR_OWNERS_ROWS_RECORD=0 run >/dev/null
[ "$(sfield 905 since)" = "$PAST" ] && ok \
  || bad "O7: knob 0 must carry the file's since as main does: got $(sfield 905 since)"
[ "$(nlog 'file-only PR(s) dropped')" = 0 ] && ok || bad "O7: no drop line with knob 0: $(swlog)"

# O7b. a knob value that is neither 0 nor 1 is the default 1, said once.
o2_setup
PR_OWNERS_ROWS_RECORD=yes run >/dev/null
[ "$(sfield 905 since)" != "$PAST" ] && ok \
  || bad "O7b: an invalid knob value must fall back to 1 (drop): got $(sfield 905 since)"
[ "$(nlog 'PR_OWNERS_ROWS_RECORD')" = 1 ] && ok \
  || bad "O7b: an invalid knob value is logged once, never silent: $(swlog)"

# ---------- M1. a sweep without the drop filter fails O2 ----------------------
cp -p "$SWEEP_SRC" "$T/sweep.orig"
sed 's/with_entries(select(\.key as \$k | \$rows | has(\$k)))/./' "$SWEEP_SRC" > "$T/sweep.mut"
if cmp -s "$T/sweep.orig" "$T/sweep.mut"; then
  bad "M1: the mutation did not change the sweep — the drop filter moved, update the sed"
else
  ok
  cp "$T/sweep.mut" "$H/bin/pr-owner-sweep.sh"; chmod +x "$H/bin/pr-owner-sweep.sh"
  o2_setup
  run >/dev/null
  [ "$(sfield 905 since)" = "$PAST" ] && ok \
    || bad "M1: the mutant (no drop filter) must fail O2 by carrying since=$PAST, got $(sfield 905 since)"
  cp -p "$T/sweep.orig" "$H/bin/pr-owner-sweep.sh"
fi

echo "pr-owner-clock-db.bh-5003: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
