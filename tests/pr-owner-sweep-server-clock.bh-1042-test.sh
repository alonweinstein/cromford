#!/bin/bash
# tests/pr-owner-sweep-server-clock.bh-1042-test.sh — the D1 overlay in
# bin/pr-owner-sweep.sh compares the worker's clock against the WORKER's clock,
# never against this box's.
#
# WHY THIS EXISTS (BH-1042, bullet 1). state/pr-owners/<owner>_<repo>.json is
# stamped `generated_at` from the LOCAL clock, and the overlay then keeps a D1
# row only when `row.updated_at >= file.generated_at`. Those are two different
# clocks. On a box running ahead of the worker — which is every box some of the
# time, and the Orgo fleet's normal state after a resume — the worker stamps our
# own push with ITS time, that stamp is behind our `generated_at`, and the
# overlay throws away the row we just wrote. The visible damage is the one thing
# the ledger exists for: another box closes a PR, D1 knows it, and this box goes
# on calling it OWNED because the row that says otherwise never survives the
# filter. BH-435's own comment says the two stamps must both be the worker's;
# the code then compares one of them to `date -u +%s`.
#
# THE RULE UNDER TEST:
#   sync   a successful run records `synced_as_of` — the `as_of` the WORKER
#          answered our PUT with. When the PUT did not land, the fallback is the
#          `as_of` of this tick's GET (pr_owners_list surfaces it as the
#          `generated_at` of $TD/d1-owners.json). When neither is available —
#          the worker is down — no `synced_as_of` is written at all.
#   read   the overlay compares a row against `(synced_as_of // generated_at)`,
#          so a row the worker stamped at or after our push wins even when this
#          box's clock is days ahead of the worker's.
#   keep   `generated_at` still means what it always meant: the moment THIS box
#          wrote the file. It is the fallback, not the comparison.
#   guard  a row the worker stamped BEFORE our push still never overlays. That
#          is the failed-PUT protection from BH-435 and this change must not
#          spend it to buy the skew fix.
#   outage a down worker still leaves a written file, no `synced_as_of`, and
#          exactly the one `harness-jobs unreachable` line bin/jobs-client.sh
#          already pages once a day. No new alert code.
#
# WHY DRIVEN AND NOT GREPPED. The defect is a comparison between two values that
# are equal on a healthy box and differ only under skew, so the source reads
# correct — `>=` against a stamp, exactly as the comment describes. Only the
# artifacts tell the two apart: the `since` field the overlay did or did not
# carry back, the `synced_as_of` on the state file, the ALERTS line. A grep for
# `synced_as_of` would pass on a fix that writes the field and still compares
# the local one.
# Run from anywhere: tests/pr-owner-sweep-server-clock.bh-1042-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

# The clock is read ONCE, here, and every fixture PR stamp is derived from it
# (bin/test-determinism-lint.sh's pin). Every stamp this suite COMPARES is an
# absolute literal, because the whole point is a worker clock that does not
# agree with this box's: W is what the curl shim's PUT answers, and it is days
# behind the real date on purpose — that IS the skewed-box shape under test.
NOW=$(date -u +%s)
W=2026-09-17T00:00:00Z          # the as_of the worker stamps our PUT with
W_PLUS=2026-09-17T00:01:00Z     # a row the worker stamped 60s AFTER our push
W_MINUS=2026-09-16T23:59:00Z    # a row the worker stamped 60s BEFORE our push
PINNED=2026-09-01T00:00:00Z     # the `since` a surviving row must carry back
PAST=2020-01-01T00:00:00Z       # the `since` a filtered row must NOT carry back
GETAS=2026-09-18T12:00:00Z      # a GET as_of distinct from every PUT as_of

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
cp "$DIR/bin/pr-owner-sweep.sh" "$H/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp -R "$DIR/bin/lib/pr-owner" "$H/bin/lib/"; cp "$DIR/bin/lib/pr-health.sh" "$H/bin/lib/"  # TEST-CHANGE: BH-3932 — the sweep sources its hook libs with || exit 1
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1; mkdir -p "$H/state"; echo box-hub > "$H/state/box-name"; export HUB_BOX_NAME=box-hub  # TEST-CHANGE: BH-5124 — the conductor file is read only on the conductor's box
cp "$DIR/bin/jobs-client.sh"    "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-repo-token.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-budget.sh" "$H/bin/lib/"
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

# gh shim — tests/ledger-writethrough-test.sh's, unchanged.
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

# curl shim for bin/jobs-client.sh — tests/ledger-writethrough-test.sh's, plus
# ONE knob this suite needs. The PUT's as_of stays the fixed worker stamp W;
# PO_GET_AS_OF makes the GET's as_of settable INDEPENDENTLY of it, because "the
# PUT answered X and the GET answered Y" is the whole fallback ladder here and a
# shim that welds the two together cannot tell which one a fix read.
#   PO_MODE=down    exit 7 for /api/pr-owners ONLY (the worker outage)
#   PO_PUT_FAIL=1   the PUT answers 500 (a row that did not land)
#   PO_GET_AS_OF=   override the as_of the GET answers with (default W)
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
      if [ -n "${PO_GET_AS_OF:-}" ]; then
        jq -c --arg a "$PO_GET_AS_OF" '.as_of = $a' "$PO_OWNERS_JSON"
      else
        cat "$PO_OWNERS_JSON"
      fi
      printf '\n200\n'
    else
      printf '{"repo":"example-org/project-5","pr_owners":[],"as_of":"%s"}\n200\n' \
        "${PO_GET_AS_OF:-2026-09-17T00:00:00Z}"
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
ffield() { jq -r --arg f "$1" '.[$f] // "MISSING"' "$STATEF" 2>/dev/null; }
put_body() { grep '^PUT [^ ]*/api/pr-owners ' "$REQ_SINK" 2>/dev/null | tail -1 | cut -d' ' -f3-; }
n_put()  { grep -c '^PUT [^ ]*/api/pr-owners ' "$REQ_SINK" 2>/dev/null || true; }
n_get()  { grep -c '^GET [^ ]*/api/pr-owners' "$REQ_SINK" 2>/dev/null || true; }
swlog()  { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
# The D1 answer, built from a PUT body the sweep itself produced — a fixture the
# production pipeline can actually generate, never a hand-written row.
serve() { # serve <updated_at> <since-for-902> <<< <put-body>
  jq -c --arg u "$1" --arg s "$2" \
    '{repo: .repo, as_of: $u,
      pr_owners: (.rows | map(. + {updated_at: $u})
                        | map(if .number == 902 then . + {since: $s} else . end))}' \
    > "$PO_OWNERS_JSON"
}

# ---------- A. a row the worker stamped AFTER our push survives the skew -----
# The box's clock is the real date; the worker's is W, days behind it. The row
# below is stamped W+60s — later than the worker's own record of our push, and
# still far BEHIND `generated_at`. Today the local stamp is the yardstick, so
# the row is thrown away and `since` stays whatever this run invented. That is
# the defect: a row another box wrote after us loses to our wall clock.
reset
run >/dev/null
[ "$(n_put)" = 1 ] && ok || bad "the seeding run must PUT exactly once, got $(n_put)"
serve "$W_PLUS" "$PINNED" <<<"$(put_body)"
run >/dev/null
[ "$(n_get)" -ge 1 ] && ok || bad "the second run must read the rows back: $(n_get)"
[ "$(sfield 902 since)" = "$PINNED" ] && ok \
  || bad "a row the WORKER stamped after our push ($W_PLUS, vs the PUT's as_of $W) was
 filtered out by this box's own clock — the overlay is comparing two clocks:
 want since=$PINNED  got since=$(sfield 902 since)  generated_at=$(ffield generated_at)  synced_as_of=$(ffield synced_as_of)"

# ---------- B (negative). a row stamped BEFORE our push still never wins -----
# The failed-PUT protection from BH-435. The file was rewritten, the row was
# not, and the stale row must not revert what this box just decided. Green
# before the fix and green after it — that is the point of the case.
reset
run >/dev/null
S1=$(sfield 902 since)
serve "$W_MINUS" "$PAST" <<<"$(put_body)"
run >/dev/null
[ "$(sfield 902 since)" = "$S1" ] && ok \
  || bad "a row stamped before our push ($W_MINUS < $W) overlaid the file anyway: $S1 -> $(sfield 902 since)"
[ "$(sfield 902 since)" != "$PAST" ] && ok \
  || bad "the stale row reverted the file to its own since=$PAST"
[ "$(sfield 909 state)" = ORPHAN ] && ok \
  || bad "…and the rest of the map is this run's own verdicts: $(sfield 909 state)"

# ---------- C. the file records the WORKER's stamp, and keeps its own --------
reset
run >/dev/null
[ "$(ffield synced_as_of)" = "$W" ] && ok \
  || bad "a successful PUT records the as_of the worker answered with ($W): $(ffield synced_as_of)"
G=$(ffield generated_at)
date -u -d "$G" >/dev/null 2>&1 && ok \
  || bad "generated_at must still be a date this box wrote: $G"
[ "$G" != MISSING ] && ok || bad "generated_at must survive the change — it is the fallback, not the yardstick"

# ---------- D1. no PUT answer: the fallback is this tick's GET as_of ---------
# The PUT 500s, so there is no worker stamp for OUR write. The GET still
# answered, and its as_of is a worker stamp for the rows we just read — the
# closest honest thing to "where the worker's clock is". It is a literal
# distinct from every PUT as_of so a fix that quietly reused W would be red.
reset
run >/dev/null
serve "$W_PLUS" "$PINNED" <<<"$(put_body)"
PO_PUT_FAIL=1 PO_GET_AS_OF="$GETAS" run >/dev/null
[ -s "$STATEF" ] && ok || bad "a failed row write must still leave the state FILE behind"
[ "$(ffield synced_as_of)" = "$GETAS" ] && ok \
  || bad "with no PUT answer the fallback is the GET's own as_of ($GETAS): $(ffield synced_as_of)"

# ---------- D2. worker down: a written file, no stamp, one page for the day --
reset
PO_MODE=down run >/dev/null
[ -s "$STATEF" ] && jq -e . "$STATEF" >/dev/null 2>&1 && ok \
  || bad "an unreachable pr-owners ledger must not stop the sweep recording"
[ "$(ffield synced_as_of)" = MISSING ] && ok \
  || bad "with neither a PUT nor a GET answer there is no worker stamp to record,
 and inventing one would re-create the bug: $(ffield synced_as_of)"
date -u -d "$(ffield generated_at)" >/dev/null 2>&1 && ok \
  || bad "the local write time is still recorded during an outage: $(ffield generated_at)"
[ "$(grep -c 'harness-jobs unreachable' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "the outage page is jobs-client's existing once-a-day line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
[ "$(grep -c . "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "no new alert code: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q 'pr-owners ledger unreachable' <<<"$(swlog)" && ok \
  || bad "the degraded run still says so in its own log: $(swlog)"

echo "pr-owner-sweep-server-clock.bh-1042: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
