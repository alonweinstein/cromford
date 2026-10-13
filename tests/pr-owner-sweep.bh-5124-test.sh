#!/bin/bash
# tests/pr-owner-sweep.bh-5124-test.sh — BH-5124. bin/pr-owner-sweep.sh stops
# trusting a stale local conductor file, and a pool-routed refusal stops reading
# as a failed hand-back.
#
# WHY (2026-10-07). On box-small the sweep read
# state/merge-conductor/pr-state.tsv, a file only the hub's conductor writes and
# which had last moved at 01:38Z. Every harness PR with no ledger row read as
# ORPHAN, and every pool-routed project's refusal was logged `handback-failed`.
#
#   M1-M7  po_mc_read (bin/lib/pr-owner/mc-read.sh): the D1 view when the
#          pr-state-rows flag is up, else the file only on the conductor's box
#          and only while fresh, else refuse with a reason.
#   S1-S5  the real sweep: a conductor read that fails classifies UNREAD, never
#          ORPHAN, acts on nothing, and says so in one line plus the summary.
#   H1-H4  hand-back return codes: pool-routed and no-project are held under
#          their own names and spend no action; only a cm_clear miss is
#          handback-failed.
#   D1     the knob is in the lane catalog.
#
# gh and curl are PATH shims (no network, no secrets).
# Run from anywhere: tests/pr-owner-sweep.bh-5124-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
P=project-5
for s in bin/pr-owner-sweep.sh bin/jobs-client.sh bin/lib/hub-box.sh bin/lib/pr-owner/mc-read.sh; do
  scratch_install_closure "$s" "$H" >/dev/null 2>&1 || true
done
cp "$DIR/bin/alert-line.sh" "$H/bin/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
export HARNESS_SECRET=s3cret JOBS_URL=https://jobs.test JOBS_RETRY_SLEEP=0
export GH_TOKEN=defaulttok GH_BUDGET_TTL_S=0
export HUB_BOX_NAME=box-hub
printf '#!/bin/bash\necho box-project-5-1\n' > "$H/bin/box-for.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts-called.log"\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/box-for.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "api rate_limit")
    now=$(date -u +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$now" "$now"
    exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*)   cat "$HARNESS/fixture/open.json" ;;
  *"pr list"*"--state merged"*) echo '[]' ;;
  *"pr comment"*|*"pr close"*|*"pr edit"*) printf '%s\n' "$*" >> "$HARNESS/gh-writes.log" ;;
  # TEST-CHANGE: BH-3933 — the sweep's writes are REST (bin/lib/gh-rest.sh), the
  # same arms tests/pr-owner-sweep-test.sh carries: every write is logged.
  *"api -i -X POST repos/"*"/comments"*|*"api -i -X PATCH repos/"*"/pulls/"*|*"api -i -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$HARNESS/gh-writes.log"
    case "$*" in *"-X PATCH"*) touch "$HARNESS/closed-$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")" ;; esac
    printf 'HTTP/1.1 200 OK\r\n\r\n{}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    n=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")
    if [ -f "$HARNESS/closed-$n" ]; then printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed","merged_at":null}\n'
    else printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open","merged_at":null}\n'; fi ;;
  *) exit 1 ;;
esac
SH
# curl: jobs/queue from fixtures; /api/pr-state from fixture/prstate.json
# (PRSTATE_DOWN=1 = transport failure, PRSTATE_FULL=1 = a full 1000-row page
# every time); the settings row only when SETTING_MC_AGE is set; every PUT
# /api/ledger body recorded, LEDGER_DOWN=1 fails only that write.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift ;; --data-binary) BODY="$2"; shift ;; esac
  shift
done
case "$METHOD $URL" in
  "PUT "*/api/ledger*)
    printf '%s\n' "$BODY" >> "$HARNESS/ledger-puts.log"
    [ "${LEDGER_DOWN:-0}" = 1 ] && exit 7
    printf '{"ok":true}\n200\n' ;;
  *" "*/api/pr-state*)
    [ "${PRSTATE_DOWN:-0}" = 1 ] && exit 7
    if [ "${PRSTATE_FULL:-0}" = 1 ]; then
      printf '%s\n200\n' "$(jq -nc '{rows:[range(0;1000)|{id:(5000-.),repo:"example-org/project-5",number:(10000+.),state:"QUEUED"}]}')"
    else printf '%s\n200\n' "$(cat "$HARNESS/fixture/prstate.json")"; fi ;;
  *" "*/api/settings/pr_owner.mc_max_age_s)
    if [ -n "${SETTING_MC_AGE:-}" ]; then printf '{"setting":{"value":"%s"}}\n200\n' "$SETTING_MC_AGE"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *" "*/api/jobs*)  printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  *" "*/api/queue*) printf '{"queue":[]}\n200\n' ;;
  *)                printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

NOWISO() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }
D=86400
pr() { # pr <num> <title> <head> <login> <labels-json> <mergeable> <updated-ago-s>
  printf '{"number":%s,"title":"%s","headRefName":"%s","author":{"login":"%s"},"labels":%s,"body":"","mergeable":"%s","updatedAt":"%s","createdAt":"%s","url":"https://github.com/%s/pull/%s","isDraft":false,"headRefOid":"abc%s"}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$(NOWISO "$7")" "$(NOWISO $((40*D)))" "$SLUG" "$1" "$1"
}
fixture() {
  local m909="${1:-MERGEABLE}" with911="${2:-0}"
  {
    printf '['
    pr 901 "TK-901: the conductor is landing it" ticket/TK-901 operator '[]' MERGEABLE $((2*D)); printf ','
    pr 909 "TK-909: the plain orphan" ticket/TK-909 operator '[]' "$m909" $((20*D)); printf ','
    pr 950 "Add the CSV mapper" reviewer-1/csv reviewer-1-partner '[]' MERGEABLE $((20*D)); printf ','
    pr 960 "TK-960: EU residency" ticket/TK-960 operator '[{"name":"parked"}]' MERGEABLE $((20*D))
    [ "$with911" = 1 ] && { printf ','; pr 911 "TK-911: conflicting" ticket/TK-911 operator '[]' CONFLICTING $((20*D)); }
    printf ']\n'
  } > "$H/fixture/open.json"
  echo '{"jobs":[]}' > "$H/fixture/jobs.json"
  echo '{"rows":[]}' > "$H/fixture/prstate.json"
  printf '%s#901\tQUEUED\t1757000000\tdeadbee\tdeadbee\t-\tenqueued\thttps://x\n' "$SLUG" \
    > "$H/state/merge-conductor/pr-state.tsv"
}
reset() {
  scratch_rm "$H/state/pr-owners"; scratch_rm "$H/logs"; scratch_rm "$H/locks"; scratch_rm "$H/flags"
  mkdir -p "$H/state/pr-owners" "$H/logs" "$H/locks" "$H/flags"
  rm -f "$H/gh-writes.log" "$H/ledger-puts.log" "$H/alerts-called.log" "$T/out.tsv" "$H"/closed-*
  echo box-hub > "$H/state/box-name"
  fixture "$@"
}
stale_file() { touch -d "@$(( $(date +%s) - ${1:-1000} ))" "$H/state/merge-conductor/pr-state.tsv"; }
LOGF="$H/logs/pr-owner-sweep.log"
run() { "$H/bin/pr-owner-sweep.sh" --repo "${REPO:-$SLUG}" --explain 2>/dev/null; }
summary() { grep -o "${REPO:-$SLUG}: open=.*" "$LOGF" 2>/dev/null | tail -1; }
STATEF="$H/state/pr-owners/example-org_project-5.json"
sfield() { jq -r --arg n "$1" --arg f "$2" '.prs[$n][$f] // "MISSING"' "$STATEF" 2>/dev/null; }
klass() { awk -F'\t' -v n="$1" '$1==n {print $2}' <<<"$OUT"; }

# po_mc_read driven in its own shell, the way the sweep loads it.
mcr() {
  : > "$T/out.tsv"
  bash -c '
    . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
    [ "${NO_HUBBOX:-0}" = 1 ] || . "$HARNESS/bin/lib/hub-box.sh"
    . "$HARNESS/bin/lib/pr-owner/mc-read.sh" || { echo "rc=9 lib missing"; exit 0; }
    po_mc_read "$1" "$2"; rc=$?
    printf "rc=%s src=%s why=%s\n" "$rc" "${PO_MC_SRC:-}" "${PO_MC_WHY:-}"' _ "$SLUG" "$T/out.tsv" 2>/dev/null
}

# ---------- M1 hub, fresh file, flag down -----------------------------------
reset
R=$(mcr)
grep -q '^rc=0 src=file:[0-9]*s ' <<<"$R" && ok || bad "M1 a fresh file on the conductor's box is read: $R"
grep -q "^$SLUG#901	QUEUED$" "$T/out.tsv" && ok || bad "M1 the #901 row reaches the outfile: $(cat "$T/out.tsv")"

# ---------- M2 hub, file 1000s old, default 900 ------------------------------
reset; stale_file 1000
R=$(mcr)
grep -q '^rc=1 ' <<<"$R" && ok || bad "M2 a stale file is refused: $R"
grep -qE 'pr-state.tsv is 10(0[0-5]|99|98|97|96|95)s old \(limit 900s\)' <<<"$R" && ok || bad "M2 the reason names age and limit: $R"
[ ! -s "$T/out.tsv" ] && ok || bad "M2 nothing from a stale file reaches the outfile: $(cat "$T/out.tsv")"
R=$(PO_MC_MAX_AGE_S=2000 mcr)
grep -q '^rc=0 src=file:' <<<"$R" && ok || bad "M2 a raised limit reads the same file: $R"
R=$(PO_MC_MAX_AGE_S=0 mcr)
grep -q '^rc=1 .*PR_OWNER_MC_MAX_AGE_S=0' <<<"$R" && ok || bad "M2 limit 0 turns the file read off: $R"
reset; touch -d "@$(( $(date +%s) + 600 ))" "$H/state/merge-conductor/pr-state.tsv"
R=$(mcr)
grep -q '^rc=0 src=file:0s ' <<<"$R" && ok || bad "M2 a future mtime is age 0: $R"

# ---------- M3 not the conductor's box --------------------------------------
reset; echo box-small > "$H/state/box-name"
R=$(mcr)
grep -q "^rc=1 .*not the conductor's box (box-small; conductor runs on box-hub)" <<<"$R" && ok \
  || bad "M3 a fresh file on a box the conductor does not run on is refused: $R"
[ ! -s "$T/out.tsv" ] && ok || bad "M3 outfile empty: $(cat "$T/out.tsv")"
reset; rm -f "$H/state/merge-conductor/pr-state.tsv"
R=$(mcr)
grep -q '^rc=1 .*no state/merge-conductor/pr-state.tsv' <<<"$R" && ok || bad "M3 a missing file is refused by name: $R"

# ---------- M5 flag up: the D1 view wins, even off the hub, even with no file --
reset; echo box-small > "$H/state/box-name"; rm -f "$H/state/merge-conductor/pr-state.tsv"
touch "$H/flags/pr-state-rows"
echo '{"rows":[{"id":9,"repo":"example-org/project-5","number":901,"state":"WAIT_CI"}]}' > "$H/fixture/prstate.json"
R=$(mcr)
grep -q '^rc=0 src=rows ' <<<"$R" && ok || bad "M5 the view is read when the flag is up: $R"
[ "$(cat "$T/out.tsv")" = "$SLUG#901	WAIT_CI" ] && ok || bad "M5 the view's row reaches the outfile: $(cat "$T/out.tsv")"
echo '{"rows":[]}' > "$H/fixture/prstate.json"
R=$(mcr)
grep -q '^rc=0 src=rows ' <<<"$R" && [ ! -s "$T/out.tsv" ] && ok || bad "M5 an empty view is a real 'no rows' answer: $R"

# ---------- M6 flag up, view fails or hits the bound: refuse -----------------
R=$(PRSTATE_DOWN=1 mcr)
grep -q '^rc=1 ' <<<"$R" && ok || bad "M6 a failed view read off the hub is refused: $R"
R=$(PRSTATE_FULL=1 mcr)
grep -q '^rc=1 ' <<<"$R" && ok || bad "M6 a read that hits the 5-page bound is not a complete answer: $R"
[ ! -s "$T/out.tsv" ] && ok || bad "M6 a partial view leaves no rows behind: $(wc -l < "$T/out.tsv")"
# …and on the hub the bounded read falls through to the fresh file
reset; touch "$H/flags/pr-state-rows"
R=$(PRSTATE_DOWN=1 mcr)
grep -q '^rc=0 src=file:' <<<"$R" && ok || bad "M6 a failed view read on the hub falls through to the fresh file: $R"

# ---------- M7 hub-box.sh not loaded -----------------------------------------
reset
R=$(NO_HUBBOX=1 mcr)
grep -q "^rc=1 .*cannot tell where the conductor runs" <<<"$R" && ok || bad "M7 no hub-box.sh is fail-closed: $R"

# ---------- S1 stale file through the real sweep -----------------------------
reset; stale_file 1000
OUT=$(run)
S=$(summary)
grep -q 'orphans=0 conductor-unread=2 conductor=unread ' <<<"$S" && ok || bad "S1 summary splits the counts: $S"
[ "$(klass 901)" = UNREAD ] && ok || bad "S1 #901's stale conductor row is not OWNED evidence: $(klass 901)"
[ "$(klass 909)" = UNREAD ] && ok || bad "S1 #909 is UNREAD, not ORPHAN: $(klass 909)"
[ "$(grep -c "$SLUG: conductor rows unusable — pr-state.tsv is" "$LOGF")" = 1 ] && ok \
  || bad "S1 exactly one 'conductor rows unusable' line: $(cat "$LOGF")"
grep -q "conductor rows unusable .*2 PR(s) with no ledger owner counted conductor-unread, no orphan action this run" "$LOGF" && ok \
  || bad "S1 the line says what was withheld: $(grep unusable "$LOGF")"
[ ! -s "$H/gh-writes.log" ] && ok || bad "S1 nothing is written to GitHub: $(cat "$H/gh-writes.log")"
grep -q 'TK-909' "$H/ledger-puts.log" 2>/dev/null && bad "S1 TK-909 must not be handed back: $(cat "$H/ledger-puts.log")" || ok
[ "$(sfield 909 state)" = UNREAD ] && ok || bad "S1 state file records UNREAD: $(sfield 909 state)"
grep -q 'conductor rows unusable: pr-state.tsv is' <<<"$(sfield 909 reason)" && ok || bad "S1 the reason names why: $(sfield 909 reason)"
[ ! -s "$H/alerts-called.log" ] && ok || bad "S1 an all-UNREAD run pages nobody: $(cat "$H/alerts-called.log")"

# ---------- S2 not the conductor's box, fresh file ---------------------------
reset; echo box-small > "$H/state/box-name"
OUT=$(run)
grep -q 'orphans=0 conductor-unread=2 conductor=unread ' <<<"$(summary)" && ok || bad "S2 summary: $(summary)"
grep -q "conductor rows unusable — not the conductor's box (box-small; conductor runs on box-hub)" "$LOGF" && ok \
  || bad "S2 the line names the box: $(grep unusable "$LOGF")"
[ "$(klass 909)" = UNREAD ] && [ ! -s "$H/gh-writes.log" ] && ! grep -q TK-909 "$H/ledger-puts.log" 2>/dev/null && ok \
  || bad "S2 no action off the conductor's box: $(klass 909)"

# ---------- S3 hub, fresh file: unchanged behaviour --------------------------
reset
OUT=$(run)
S=$(summary)
grep -q 'orphans=1 conductor-unread=0 conductor=file:[0-9]*s ' <<<"$S" && ok || bad "S3 summary: $S"
grep -q '^901	OWNED	none	TK-901	conductor:QUEUED' <<<"$OUT" && ok || bad "S3 #901 owned by the conductor: $(klass 901)"
grep -q 'handed-back=#909(TK-909)' <<<"$S" && ok || bad "S3 #909 handed back: $S"
grep -q 'conductor rows unusable' "$LOGF" && bad "S3 no unusable line on a good read: $(grep unusable "$LOGF")" || ok
grep -q 'blocked project-5 TK-909' "$H/ledger-puts.log" 2>/dev/null && ok || bad "S3 the hand-back row is written"

# ---------- S4 stale file, #909 conflicting 20d ------------------------------
reset CONFLICTING; stale_file 1000
OUT=$(run)
[ "$(klass 909)" = UNREAD ] && ok || bad "S4 #909 UNREAD: $(klass 909)"
grep -q 'stale-conflict' "$H/gh-writes.log" 2>/dev/null && bad "S4 no stale-conflict label on an UNREAD PR: $(cat "$H/gh-writes.log")" || ok
[ "$(sfield 909 dirty_since)" != MISSING ] && ok || bad "S4 dirty_since is still remembered for UNREAD"

# ---------- S5 the other classes are untouched -------------------------------
reset; stale_file 1000
OUT=$(run)
[ "$(klass 950)" = EXTERNAL ] && ok || bad "S5 EXTERNAL still EXTERNAL: $(klass 950)"
[ "$(klass 960)" = PARKED ] && ok || bad "S5 PARKED still PARKED: $(klass 960)"
grep -q 'external=1 parked=1 ' <<<"$(summary)" && ok || bad "S5 summary counts: $(summary)"

# ---------- M4 the settings row sets the limit; env next ---------------------
reset; stale_file 1000
OUT=$(SETTING_MC_AGE=2000 run)
grep -q 'conductor=file:' <<<"$(summary)" && ok || bad "M4 pr_owner.mc_max_age_s=2000 admits a 1000s file: $(summary)"
reset; stale_file 300
OUT=$(PR_OWNER_MC_MAX_AGE_S=100 run)
grep -q 'conductor=unread' <<<"$(summary)" && grep -q 'limit 100s' "$LOGF" && ok \
  || bad "M4 env PR_OWNER_MC_MAX_AGE_S=100 with no row refuses a 300s file: $(summary)"
reset; stale_file 300
OUT=$(SETTING_MC_AGE=2000 PR_OWNER_MC_MAX_AGE_S=100 run)
grep -q 'conductor=file:' <<<"$(summary)" && ok || bad "M4 the row wins over the env: $(summary)"

# ---------- H1 pool-routed: its own label, no action spent ------------------
reset MERGEABLE 1
touch "$H/flags/builder-fly-$P" "$H/flags/fly-pool-$P"
OUT=$(PR_OWNER_MAX_ACTIONS=1 run)
S=$(summary)
grep -q 'held=#909:pool-routed' <<<"$S" && ok || bad "H1 pool-routed is held under its own name: $S"
grep -q 'handback-failed' <<<"$S" && bad "H1 a pool-routed refusal is not a failure: $S" || ok
# TEST-CHANGE: BH-3933 — the label write is REST now (the same write, its REST argv).
grep -q "POST repos/$SLUG/issues/911/labels -f labels\[\]=stale-conflict" "$H/gh-writes.log" 2>/dev/null && ok \
  || bad "H1 a refusal spends no action: #911 still gets its write under MAX_ACTIONS=1: $S"
grep -q 'TK-909' "$H/ledger-puts.log" 2>/dev/null && bad "H1 nothing written for a pool-routed key" || ok

# ---------- H2 a real cm_clear failure is handback-failed --------------------
reset
OUT=$(LEDGER_DOWN=1 run)
grep -q 'held=#909:handback-failed' <<<"$(summary)" && ok || bad "H2 a cm_clear miss is handback-failed: $(summary)"
grep -q 'project-5/TK-909: row not written; jobs DB unreachable' "$LOGF" && ok || bad "H2 and says so: $(cat "$LOGF")"

# ---------- H3 a repo with no fleet project ----------------------------------
reset
printf 'example-org/extra-only#901\tQUEUED\t1757000000\tx\tx\t-\tq\thttps://x\n' > "$H/state/merge-conductor/pr-state.tsv"
OUT=$(REPO=example-org/extra-only run)
S=$(REPO=example-org/extra-only summary)
grep -q 'held=#909:no-project' <<<"$S" && ok || bad "H3 no fleet project is held no-project: $S"
grep -q 'handback-failed' <<<"$S" && bad "H3 not handback-failed: $S" || ok

# ---------- H4 the handback() body -------------------------------------------
BODY=$(awk '/^handback\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/pr-owner-sweep.sh")
[ -n "$BODY" ] && ok || bad "H4 handback() not found"
awk '/pool-routed/{p=1} p&&/return/{print; exit}' <<<"$BODY" | grep -q 'return 3' && ok || bad "H4 the pool-routed arm returns 3"
awk '/no fleet project/{p=1} p&&/return/{print; exit}' <<<"$BODY" | grep -q 'return 4' && ok || bad "H4 the no-project arm returns 4"
[ "$(grep -c 'return 1' <<<"$BODY")" = 1 ] && awk '/jobs DB unreachable/{p=1} p&&/return 1/{f=1} END{exit !f}' <<<"$BODY" && ok \
  || bad "H4 return 1 only after the cm_clear miss: $BODY"
grep -qE '(^|[^a-z_])ssh |rm -f' <<<"$BODY" && bad "H4 no ssh and no rm -f in handback()" || ok

# ---------- L1 the lib is side-effect free at source time --------------------
R=$(bash -c '. "$1" && type po_mc_read >/dev/null && echo defined' _ "$DIR/bin/lib/pr-owner/mc-read.sh" 2>&1)
[ "$R" = defined ] && ok || bad "L1 sourcing mc-read.sh prints nothing and defines po_mc_read: $R"

# ---------- D1 the catalog knob ----------------------------------------------
jq -e '.knobs[] | select(.env=="PR_OWNER_MC_MAX_AGE_S" and .default==900 and (.note|test("pr_owner.mc_max_age_s")))' \
  "$DIR/catalog/lanes.d/pr-owner-sweep.json" >/dev/null 2>&1 && ok \
  || bad "D1 catalog/lanes.d/pr-owner-sweep.json declares PR_OWNER_MC_MAX_AGE_S default 900 naming pr_owner.mc_max_age_s"

echo "pr-owner-sweep.bh-5124: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
