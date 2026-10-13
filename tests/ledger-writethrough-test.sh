#!/bin/bash
# tests/ledger-writethrough-test.sh — bin/pr-owner-sweep.sh mirrors its state
# file to the D1 `pr_owners` ledger, and reads it back before classifying.
#
# WHY THIS EXISTS (BH-435). state/pr-owners/<owner>_<repo>.json is the ledger of
# record for "who owns this open PR", and it lives on ONE box. Rebuild that box,
# move the project to another one, or lose the disk, and every PR's `since`
# resets to "now" — which is the one field the whole lane is built on ("this has
# been ORPHAN for eleven days"). #433/#434 put the table and the two client
# verbs in place; this is the caller that uses them.
#
# THE RULE UNDER TEST, in both directions:
#   write  the FILE first, the row second. A failed PUT must leave a written
#          file behind, never the other way round.
#   read   a D1 row overlays the file ONLY when the worker stamped it at or
#          after the file's own `generated_at`. A file written after a failed
#          PUT is never reverted by the stale row that PUT did not replace.
#   outage the sweep's verdicts and its file are byte-identical to a run with no
#          D1 at all, and the only page is bin/jobs-client.sh's existing
#          once-a-day `harness-jobs unreachable` line. No new alert code.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about an artifact: a request
# body in the curl sink, a `since` field in the state file, a line in
# gh-writes.log. The overlay changes `since`/`dirty_since`, and those two decide
# whether this sweep COMMENTS ON AND CLOSES somebody's pull request — a grep
# over the source would pass just as happily on an overlay that runs after the
# classification instead of before it.
# Run from anywhere: tests/ledger-writethrough-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

# The clock is read ONCE, here, and every fixture stamp is derived from it
# (bin/test-determinism-lint.sh's pin). The three stamps this suite COMPARES are
# absolute and never derived: a row from the future, a row from the past, and a
# `since` the file must carry forward.
NOW=$(date -u +%s)
FUTURE=2099-01-01T00:00:00Z     # a row the worker stamped after the file
PAST=2020-01-01T00:00:00Z       # a row the worker stamped long before it
PINNED=2026-09-01T00:00:00Z     # the `since` a rehydrated row must carry back

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
P=project-5
# TEST-CHANGE: BH-3933 r3 — the sweep's libs (gh-rest.sh for its REST writes
# included) arrive with its closure, not a hand list (D46).
scratch_install_closure bin/pr-owner-sweep.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1; mkdir -p "$H/state"; echo box-hub > "$H/state/box-name"; export HUB_BOX_NAME=box-hub  # TEST-CHANGE: BH-5124 — the conductor file is read only on the conductor's box
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf 'GH_ADMIN_TOKEN=admintok\n' > "$H/env/github-admin.env"
export GH_TOKEN=defaulttok
export GH_BUDGET_TTL_S=0
# Every request the sweep's jobs client makes lands here, method + URL + body.
export REQ_SINK="$H/req.log"
# What GET /api/pr-owners answers. Absent/empty = the route's empty-set answer.
export PO_OWNERS_JSON="$H/d1-owners.json"

printf '#!/bin/bash\nprintf "%%s\\n" "${FAKE_BOX:-box-project-5-1}"\n' > "$H/bin/box-for.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts-called.log"\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/box-for.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"

# gh shim — the pr-owner-sweep suite's, trimmed to what this file drives. Every
# WRITE is recorded verbatim, because "the overlay changed which PRs get written
# to" is the regression this suite's `cmp` is looking for.
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
  # TEST-CHANGE: BH-3933 — the REST write shapes, recorded the same way; the
  # close's re-read of the PR answers closed.
  *"api -i -X POST repos/"*|*"api -i -X PATCH repos/"*)
    printf '%s\n' "$*" | sed 's#body=@[^ ]*#body=@<file>#' >> "$HARNESS/gh-writes.log"
    printf 'HTTP/1.1 200 OK\r\n\r\n{}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed","merged_at":null}\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

# curl shim for bin/jobs-client.sh. /api/jobs and /api/queue come from fixtures
# so the sweep's own fail-closed ledger gate is never what trips; only
# /api/pr-owners is under test.
#   PO_MODE=down    exit 7 for /api/pr-owners ONLY (the worker outage)
#   PO_PUT_FAIL=1   the PUT answers 500 (a row that did not land)
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/pr-owners*)
    [ "${PO_MODE:-ok}" = down ] && exit 7
    if [ "$M" = PUT ]; then
      if [ "${PO_PUT_FAIL:-0}" = 1 ]; then printf '{"error":"write failed"}\n500\n'
      else printf '{"pr_owners":12,"tombstoned":0,"as_of":"2026-09-17T00:00:00Z"}\n200\n'; fi
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

# ssh drains stdin, like the real thing (the per-repo loop is a here-string).
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

# --- the fixture repo: one open PR per class, twelve in all -------------------
fixture() {
  cat > "$H/fixture/open.json" <<JSON
[
 {"number":900,"title":"TK-900: pool build in flight","headRefName":"ticket/TK-900","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(ISO $((2*D)))","createdAt":"$(ISO $((3*D)))","url":"https://github.com/$SLUG/pull/900","isDraft":false},
 {"number":901,"title":"TK-901: the conductor is landing it","headRefName":"ticket/TK-901","author":{"login":"app/cromford"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(ISO $((2*D)))","createdAt":"$(ISO $((3*D)))","url":"https://github.com/$SLUG/pull/901","isDraft":false},
 {"number":902,"title":"Add the CSV mapper","headRefName":"reviewer-1/csv-mapper","author":{"login":"reviewer-1-partner"},
  "labels":[],"body":"","mergeable":"CONFLICTING","updatedAt":"$(ISO $((90*D)))","createdAt":"$(ISO $((95*D)))","url":"https://github.com/$SLUG/pull/902","isDraft":false},
 {"number":903,"title":"TK-903: org chart After view","headRefName":"ticket/TK-903","author":{"login":"operator"},
  "labels":[],"body":"Parked: waiting on the client's org data until 2099-01-01","mergeable":"MERGEABLE","updatedAt":"$(ISO $((30*D)))","createdAt":"$(ISO $((40*D)))","url":"https://github.com/$SLUG/pull/903","isDraft":false},
 {"number":904,"title":"TK-904: EU residency","headRefName":"ticket/TK-904","author":{"login":"operator"},
  "labels":[{"name":"parked"}],"body":"","mergeable":"MERGEABLE","updatedAt":"$(ISO $((30*D)))","createdAt":"$(ISO $((40*D)))","url":"https://github.com/$SLUG/pull/904","isDraft":false},
 {"number":905,"title":"TK-905: retention sweeper","headRefName":"ticket/TK-905","author":{"login":"operator"},
  "labels":[],"body":"Parked: pending the retention policy until 2020-01-01","mergeable":"MERGEABLE","updatedAt":"$(ISO $((30*D)))","createdAt":"$(ISO $((40*D)))","url":"https://github.com/$SLUG/pull/905","isDraft":false},
 {"number":906,"title":"TK-906: carry-forward","headRefName":"ticket/TK-906","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(ISO $((30*D)))","createdAt":"$(ISO $((40*D)))","url":"https://github.com/$SLUG/pull/906","isDraft":false},
 {"number":907,"title":"TK-907: invoice export","headRefName":"ticket/TK-907","author":{"login":"cromford[bot]"},
  "labels":[],"body":"","mergeable":"CONFLICTING","updatedAt":"$(ISO $((40*D)))","createdAt":"$(ISO $((45*D)))","url":"https://github.com/$SLUG/pull/907","isDraft":false},
 {"number":908,"title":"TK-908: already labelled","headRefName":"ticket/TK-908","author":{"login":"operator"},
  "labels":[{"name":"stale-conflict"}],"body":"","mergeable":"CONFLICTING","updatedAt":"$(ISO $((40*D)))","createdAt":"$(ISO $((45*D)))","url":"https://github.com/$SLUG/pull/908","isDraft":false},
 {"number":909,"title":"TK-909: the plain orphan","headRefName":"ticket/TK-909","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(ISO $((30*D)))","createdAt":"$(ISO $((40*D)))","url":"https://github.com/$SLUG/pull/909","isDraft":false},
 {"number":910,"title":"TK-910: the conductor is DONE with it","headRefName":"ticket/TK-910","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(ISO $((30*D)))","createdAt":"$(ISO $((40*D)))","url":"https://github.com/$SLUG/pull/910","isDraft":false},
 {"number":911,"title":"TK-911: opened four minutes ago","headRefName":"ticket/TK-911","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(ISO 240)","createdAt":"$(ISO 240)","url":"https://github.com/$SLUG/pull/911","isDraft":false}
]
JSON
  echo '[{"number":1200,"title":"TK-906: carry-forward","headRefName":"ticket/TK-906","url":"https://github.com/'"$SLUG"'/pull/1200","mergedAt":"'"$(ISO $((5*D)))"'"}]' > "$H/fixture/merged.json"
  cat > "$H/fixture/jobs.json" <<JSON
{"jobs":[
 {"id":"build-project-5-TK-900-1","ticket_id":"TK-900","kind":"build","status":"running","updated_at":"$(ISO 600)","meta":"{\"key\":\"TK-900\"}"},
 {"id":"build-project-5-TK-909-0","ticket_id":"TK-909","kind":"build","status":"failed","updated_at":"$(ISO 90000)","meta":"{\"key\":\"TK-909\"}"}
]}
JSON
  echo '{"queue":[]}' > "$H/fixture/queuerows.json"
  {
    printf '%s#901\tQUEUED\t1757000000\tdeadbee\tdeadbee\t-\tenqueued\thttps://x\n' "$SLUG"
    printf '%s#910\tMERGED\t1757000000\tdeadbee\tdeadbee\t-\tlanded\thttps://x\n' "$SLUG"
  } > "$H/state/merge-conductor/pr-state.tsv"
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
put_body() { grep '^PUT [^ ]*/api/pr-owners ' "$REQ_SINK" 2>/dev/null | tail -1 | cut -d' ' -f3-; }
n_put()  { grep -c '^PUT [^ ]*/api/pr-owners ' "$REQ_SINK" 2>/dev/null || true; }
n_get()  { grep -c '^GET [^ ]*/api/pr-owners' "$REQ_SINK" 2>/dev/null || true; }
swlog()  { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
# The D1 answer, built from a PUT body the sweep itself produced — a fixture the
# production pipeline can actually generate (D4), never a hand-written row.
serve() { # serve <updated_at> <since-for-902> <<< <put-body>
  jq -c --arg u "$1" --arg s "$2" \
    '{repo: .repo, as_of: $u,
      pr_owners: (.rows | map(. + {updated_at: $u})
                        | map(if .number == 902 then . + {since: $s} else . end))}' \
    > "$PO_OWNERS_JSON"
}

# ---------- A1. the file is written through to D1 ---------------------------
reset
run >/dev/null
B1=$(put_body)
[ "$(n_put)" = 1 ] && ok || bad "exactly one PUT /api/pr-owners per repo per run, got $(n_put): $(cut -c1-120 "$REQ_SINK" 2>/dev/null | head -5)"
[ "$(jq -r '.repo' <<<"$B1" 2>/dev/null)" = "$SLUG" ] && ok || bad "the PUT body must name the repo: $(cut -c1-200 <<<"$B1")"
[ "$(jq -r '.project' <<<"$B1" 2>/dev/null)" = "$P" ] && ok || bad "…and the project: $(cut -c1-200 <<<"$B1")"
[ "$(jq -r '.complete' <<<"$B1" 2>/dev/null)" = true ] && ok || bad "…and complete:true, which is how D1 learns the FULL set this box owns"
[ "$(jq -r '.rows | length' <<<"$B1" 2>/dev/null)" = 12 ] && ok \
  || bad "one row per open PR (12): $(jq -r '.rows | length' <<<"$B1" 2>/dev/null)"
[ "$(jq -r '[.rows[] | has("updated_at")] | any' <<<"$B1" 2>/dev/null)" = false ] && ok \
  || bad "this box must never stamp updated_at — the worker owns that clock"
[ "$(jq -r '[.rows[].number] | sort | .[0]' <<<"$B1" 2>/dev/null)" = 900 ] && ok \
  || bad "the rows are the state file's own prs map, keyed by number"
# rc 2 (the route answered an empty array) is SILENT — not a degraded line.
grep -q 'pr-owners ledger unreachable' <<<"$(swlog)" && bad "an empty D1 is not an outage: $(swlog)" || ok
grep -q 'could not be merged' <<<"$(swlog)" && bad "an empty D1 must not log a merge failure: $(swlog)" || ok

# A1-fail. The FILE is written first, so a PUT that 500s leaves it behind.
reset
PO_PUT_FAIL=1 run >/dev/null
[ -s "$STATEF" ] && jq -e . "$STATEF" >/dev/null 2>&1 && ok \
  || bad "a failed row write must still leave the state FILE — file first, row second"
[ "$(n_put)" = 1 ] && ok || bad "the PUT is attempted even when it fails: $(n_put)"

# A1-dry. The read and the mirror are free; gh writes are what dry-run withholds.
reset
PR_OWNER_DRY_RUN=1 run >/dev/null
[ "$(n_put)" = 1 ] && ok || bad "PR_OWNER_DRY_RUN=1 must still mirror the file it wrote: $(n_put)"
[ "$(n_get)" -ge 1 ] && ok || bad "…and still read the rows back: $(n_get)"
[ ! -s "$H/gh-writes.log" ] && ok || bad "PR_OWNER_DRY_RUN=1 must not touch GitHub: $(cat "$H/gh-writes.log")"

# ---------- A2. a rebuilt box back-fills its file from D1 -------------------
# No state file at all (the fresh-hub shape). Every row overlays, because an
# absent generated_at is "" and every stamp is >= "".
reset
run >/dev/null
BODY=$(put_body)
serve "$FUTURE" "$PINNED" <<<"$BODY"
rm -f "$STATEF" "$H/gh-writes.log"
run >/dev/null
[ "$(sfield 902 since)" = "$PINNED" ] && ok \
  || bad "a rebuilt box must carry 'since' back from D1, not reset it to now: $(sfield 902 since)"
[ "$(sfield 909 state)" = ORPHAN ] && ok || bad "…and the rest of the map is back-filled: $(sfield 909 state)"
cp -f "$H/gh-writes.log" "$T/writes-overlay.log" 2>/dev/null || : > "$T/writes-overlay.log"
# The control arm: same second run, file present, D1 empty. The overlay must not
# add, drop or reorder a single GitHub write.
reset
run >/dev/null
rm -f "$H/gh-writes.log"
run >/dev/null
cmp -s "$H/gh-writes.log" "$T/writes-overlay.log" && ok \
  || bad "the back-fill changed which PRs get written to:
 overlay: $(cat "$T/writes-overlay.log")
 control: $(cat "$H/gh-writes.log")"

# ---------- A2-file-present. a NEWER row overlays an existing file ----------
reset
run >/dev/null
serve "$FUTURE" "$PINNED" <<<"$(put_body)"
run >/dev/null
[ "$(sfield 902 since)" = "$PINNED" ] && ok \
  || bad "a row stamped after the file's generated_at must win: $(sfield 902 since)"

# ---------- N1 (negative). an OLDER row must never overlay ------------------
# This is the failed-PUT shape: the file was rewritten, the row was not, and the
# stale row must not revert what this box just decided.
reset
run >/dev/null
S1=$(sfield 902 since)
serve "$PAST" "$PAST" <<<"$(put_body)"
run >/dev/null
[ "$(sfield 902 since)" = "$S1" ] && ok \
  || bad "a row older than the file overlaid it anyway: $S1 -> $(sfield 902 since)"
[ "$(sfield 902 since)" != "$PAST" ] && ok || bad "the stale row reverted the file"

# ---------- A3. worker down: identical verdicts, one page for the day -------
reset
PO_MODE=down run >/dev/null
DOWN2=$(PO_MODE=down run)
[ -s "$STATEF" ] && ok || bad "an unreachable pr-owners ledger must not stop the sweep recording"
[ "$(grep -c 'pr-owners ledger unreachable' "$H/logs/pr-owner-sweep.log" 2>/dev/null)" = 2 ] && ok \
  || bad "each degraded run says so once in its own log: $(swlog)"
[ "$(grep -c 'harness-jobs unreachable' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "the outage page is jobs-client's existing once-a-day line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(grep -c . "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "no new alert code: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
reset
run >/dev/null
CTRL2=$(run)
[ "$DOWN2" = "$CTRL2" ] && ok \
  || bad "a D1 outage changed the verdicts:
 down: $DOWN2
 ctrl: $CTRL2"

# ---------- A5. a PR_OWNER_EXTRA_REPOS repo (project '-') reads and writes ---
reset
"$H/bin/pr-owner-sweep.sh" --repo example-org/not-in-fleet --explain >/dev/null 2>&1
XB=$(put_body)
[ "$(n_get)" -ge 1 ] && ok || bad "a repo with no fleet project must still read its rows: $(cat "$REQ_SINK" 2>/dev/null | cut -c1-100)"
[ "$(jq -r '.project' <<<"$XB" 2>/dev/null)" = "-" ] && ok \
  || bad "…and write them with project '-': $(cut -c1-200 <<<"$XB")"
[ "$(jq -r '.repo' <<<"$XB" 2>/dev/null)" = example-org/not-in-fleet ] && ok \
  || bad "…for its own repo: $(cut -c1-200 <<<"$XB")"

echo "ledger-writethrough: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
