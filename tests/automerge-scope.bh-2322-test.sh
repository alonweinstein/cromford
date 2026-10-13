#!/bin/bash
# tests/automerge-scope.bh-2322-test.sh — #2322: the Project page's AUTOMERGE
# toggle is per project, so it must not stop the whole fleet.
#
# The console sends automerge_off / automerge_on with commands.project set to
# the project the toggle sits on ('all' for the dashboard KILL button and chat
# /kill). bin/poll-commands.sh ignored the project and wrote the fleet-wide
# flags/automerge-disabled either way, so one click on one board stopped
# auto-merge on every board, and the flags beat then reported automerge=false
# for all of them.
#
#   H  the automerge handler, EXTRACTED VERBATIM from bin/poll-commands.sh:
#      a project writes flags/automerge-disabled-<project> and nothing else;
#      'all' (or no project) is still the fleet kill switch; an unknown project
#      is refused; a fleet.conf that could not be read is retryable, never a
#      refusal; ON for a project says so when the fleet switch is still on
#   B  the flags beat reports automerge per project: A off, B on; and
#      automerge_fleet, the fleet kill switch ALONE, so the console's fleet
#      KILL / RE-ENABLE button keys on the fleet flag, never on one board
#   Q  bin/merge-queue.sh, run for real: a project row for A holds A's queue
#      and B's queue still reaches its first merge call
#   P  review-prs' hold_automerge_disabled, EXTRACTED VERBATIM: A held, B not
#   C  every other merge writer names the per-project flag next to the fleet one
#   L  catalog/lanes.d registers automerge-disabled- as a prefix alias on each
#      lane that aliases the fleet flag, so the Lanes page shows a board's
#      merge lanes held by its toggle
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/automerge-scope.bh-2322-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ---------- H. the handler -------------------------------------------------
mkdir -p "$T/h/bin" "$T/h/flags"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 local
beta-os Org/beta https://b.example /api/board 2 local
EOF
awk '/^    # >>> automerge handlers/{f=1;next} /^    # <<< automerge handlers/{exit} f{print}' \
  "$DIR/bin/poll-commands.sh" | sed -e '1s/^    automerge_off|automerge_on)//' -e '$s/ ;;$//' > "$T/am.body"
if [ ! -s "$T/am.body" ]; then
  bad "H could not extract the automerge handler (markers '# >>> automerge handlers' missing)"
else
  ok
fi
# set_flag as poll-commands defines it, without the jobs client: the file is the flag.
awk '/^set_flag\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/poll-commands.sh" > "$T/setflag.sh"
[ -s "$T/setflag.sh" ] && ok || bad "H could not extract set_flag from bin/poll-commands.sh"

run() { # run <type> <project> -> "OK=<ok>|RESULT=<result>"
  HARNESS="${HH:-$T/h}" FLEET_CONF="$T/h/fleet.conf" TYPE="$1" PROJECT="$2" PAYLOAD='{}' OK=false RESULT="" \
    bash -c 'set -uo pipefail; . "$1"; . "$0"; echo "OK=$OK|RESULT=$RESULT"' "$T/am.body" "$T/setflag.sh"
}
flags() { (cd "$T/h/flags" && ls -1 2>/dev/null | sort | paste -sd, -); }
clear_flags() { rm -f "$T/h/flags/"*; }

clear_flags; OUT=$(run automerge_off alpha-os)
[ "$(flags)" = "automerge-disabled-alpha-os" ] && ok || bad "H1 OFF for alpha-os must write only automerge-disabled-alpha-os (flags: $(flags); $OUT)"
grep -q '^OK=true|' <<<"$OUT" && ok || bad "H1 OFF for alpha-os acks ok ($OUT)"
grep -q 'alpha-os' <<<"$OUT" && ok || bad "H1 the result names the project ($OUT)"
[ ! -e "$T/h/flags/automerge-disabled" ] && ok || bad "H1 OFF for one project must not set the fleet kill switch"

OUT=$(run automerge_off beta-os)
[ "$(flags)" = "automerge-disabled-alpha-os,automerge-disabled-beta-os" ] && ok || bad "H2 OFF for beta-os adds its own flag (flags: $(flags))"
OUT=$(run automerge_on alpha-os)
[ "$(flags)" = "automerge-disabled-beta-os" ] && ok || bad "H2 ON for alpha-os clears only alpha-os (flags: $(flags); $OUT)"
grep -q '^OK=true|' <<<"$OUT" && ok || bad "H2 ON acks ok ($OUT)"

clear_flags; OUT=$(run automerge_off all)
[ "$(flags)" = "automerge-disabled" ] && ok || bad "H3 OFF for 'all' is the fleet kill switch (flags: $(flags); $OUT)"
OUT=$(run automerge_on all)
[ -z "$(flags)" ] && ok || bad "H3 ON for 'all' clears the fleet kill switch (flags: $(flags); $OUT)"
clear_flags; OUT=$(run automerge_off "")
[ "$(flags)" = "automerge-disabled" ] && ok || bad "H3 OFF with no project is the fleet kill switch (flags: $(flags); $OUT)"

clear_flags; OUT=$(run automerge_off nope-os)
[ -z "$(flags)" ] && ok || bad "H4 an unknown project writes no flag (flags: $(flags))"
grep -q '^OK=false|RESULT=refused:' <<<"$OUT" && ok || bad "H4 an unknown project is refused ($OUT)"
OUT=$(run automerge_off 'alpha-os/../x')
[ -z "$(flags)" ] && grep -q 'RESULT=refused:' <<<"$OUT" && ok || bad "H4 a path-shaped project is refused and writes nothing ($OUT; flags: $(flags))"

# A fleet-conf.sh that fails stands for a fleet.conf that could not be read.
mkdir -p "$T/h5/bin"; ln -s "$T/h/flags" "$T/h5/flags"
printf '#!/bin/bash\nexit 3\n' > "$T/h5/bin/fleet-conf.sh"; chmod +x "$T/h5/bin/fleet-conf.sh"
clear_flags; OUT=$(HH="$T/h5" run automerge_off alpha-os)
[ -z "$(flags)" ] && ok || bad "H5 an unreadable fleet.conf writes no flag (flags: $(flags))"
grep -q '^OK=false|' <<<"$OUT" && ! grep -q 'RESULT=refused:' <<<"$OUT" && ok \
  || bad "H5 an unreadable fleet.conf is retryable, never a terminal refusal ($OUT)"

clear_flags; touch "$T/h/flags/automerge-disabled" "$T/h/flags/automerge-disabled-alpha-os"
OUT=$(run automerge_on alpha-os)
[ "$(flags)" = "automerge-disabled" ] && ok || bad "H6 ON for a project never clears the fleet kill switch (flags: $(flags))"
grep -q 'fleet' <<<"$OUT" && ok || bad "H6 ON for a project says the fleet kill switch is still on ($OUT)"

# ---------- B. the flags beat ----------------------------------------------
mkdir -p "$T/b/bin" "$T/b/flags"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> %s/BEATS.jsonl\n' "$T/b" > "$T/b/bin/beat.sh"
printf '#!/bin/bash\necho alpha-os; echo beta-os\n' > "$T/b/bin/fleet-projects-or-alert.sh"
chmod +x "$T/b/bin/beat.sh" "$T/b/bin/fleet-projects-or-alert.sh"
awk '/^# >>> flags beats/{f=1;next} /^# <<< flags beats/{exit} f{print}' "$DIR/bin/poll-commands.sh" > "$T/beat.body"
[ -s "$T/beat.body" ] && ok || bad "B could not extract the flags beats block"
beat_am() { # beat_am <project> [field] -> the value it was beaten with
  jq -r --arg p "$1" --arg f "${2:-automerge}" 'select(.kind=="flags" and .project==$p) | .[$f]' "$T/b/BEATS.jsonl" | tail -1
}
runbeat() { : > "$T/b/BEATS.jsonl"; HARNESS="$T/b" BEAT="$T/b/bin/beat.sh" bash -c '. "$0"' "$T/beat.body" >/dev/null 2>&1; }

touch "$T/b/flags/automerge-disabled-alpha-os"; runbeat
[ "$(beat_am alpha-os)" = false ] && ok || bad "B1 alpha-os beats automerge=false under its own flag (got $(beat_am alpha-os))"
[ "$(beat_am beta-os)" = true ] && ok || bad "B1 beta-os still beats automerge=true (got $(beat_am beta-os))"
[ "$(beat_am alpha-os automerge_fleet)" = true ] && [ "$(beat_am beta-os automerge_fleet)" = true ] && ok \
  || bad "B1 one board's flag leaves automerge_fleet=true on every beat (alpha=$(beat_am alpha-os automerge_fleet) beta=$(beat_am beta-os automerge_fleet))"
rm -f "$T/b/flags/"*; touch "$T/b/flags/automerge-disabled"; runbeat
[ "$(beat_am alpha-os)" = false ] && [ "$(beat_am beta-os)" = false ] && ok \
  || bad "B2 the fleet kill switch still beats automerge=false everywhere (alpha=$(beat_am alpha-os) beta=$(beat_am beta-os))"
[ "$(beat_am alpha-os automerge_fleet)" = false ] && [ "$(beat_am beta-os automerge_fleet)" = false ] && ok \
  || bad "B2 the fleet kill switch beats automerge_fleet=false (alpha=$(beat_am alpha-os automerge_fleet) beta=$(beat_am beta-os automerge_fleet))"
rm -f "$T/b/flags/"*; runbeat
[ "$(beat_am alpha-os)" = true ] && [ "$(beat_am beta-os)" = true ] && ok \
  || bad "B3 no flags: automerge=true everywhere (alpha=$(beat_am alpha-os) beta=$(beat_am beta-os))"
[ "$(beat_am alpha-os automerge_fleet)" = true ] && ok || bad "B3 no flags: automerge_fleet=true (got $(beat_am alpha-os automerge_fleet))"

# ---------- Q. bin/merge-queue.sh, for real --------------------------------
if command -v flock >/dev/null; then
  mkdir -p "$T/fakebin"
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac; done
case "$METHOD $URL" in
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_CALLS"\nexit 1\n' > "$T/fakebin/gh"
  printf '#!/bin/bash\nprintf "git %%s\\n" "$*" >> "$GH_CALLS"\nexit 1\n' > "$T/fakebin/git"
  chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/git"
  Q="$T/q"; mkdir -p "$Q/bin/lib/jobs" "$Q/flags" "$Q/state" "$Q/logs" "$Q/locks" "$Q/env" "$Q/rows"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/merge-queue.sh" "$Q/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$Q/bin/lib/jobs/"
  cp "$DIR/bin/lib/scheduler-conf.sh" "$DIR/bin/lib/gh-pr-list.sh" "$Q/bin/lib/"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$Q/env/global.env"
  printf 'aproj example-org/aproj https://a.example /api/board 0 local -\nbproj example-org/bproj https://b.example /api/board 0 local -\n' > "$Q/fleet.conf"
  cat > "$Q/bin/lib/merge-conductor-lib.sh" <<'EOF'
mc_queue_enabled() { echo "mc_queue_enabled $PROJECT" >> "$GH_CALLS"; return 1; }
mc_pr_view() { echo "mc_pr_view $PROJECT" >> "$GH_CALLS"; return 75; }
mc_rest_status() { printf '?'; }
mc_log() { :; }
mc_rebase() { echo mc_rebase >> "$GH_CALLS"; return 1; }
EOF
  for p in aproj bproj; do mkdir -p "$Q/state/merge-queue/$p"; : > "$Q/state/merge-queue/$p/41"; done
  # The console's toggle for aproj: a ROW only, no file yet (the box reconciles it).
  printf '{"flag":{"name":"automerge-disabled-aproj","active":1,"updated_at":"2026-09-23T01:00:00Z"}}' \
    > "$Q/rows/automerge-disabled-aproj.json"
  mq() { # mq <project> -> rc
    ( export PATH="$T/fakebin:$PATH" HARNESS="$Q" FLEET_CONF="$Q/fleet.conf" HARNESS_SECRET=test-secret \
        JOBS_RETRIES=0 JOBS_URL=https://jobs.invalid ROWS="$Q/rows" GH_CALLS="$Q/calls-$1.txt" PROJECT="$1"
      bash "$Q/bin/merge-queue.sh" "$1" >/dev/null 2>&1 ); echo $?
  }
  mq aproj >/dev/null
  [ ! -s "$Q/calls-aproj.txt" ] && ok || bad "Q1 aproj's row holds aproj's merge queue — calls: $(tr '\n' ';' < "$Q/calls-aproj.txt")"
  # TEST-CHANGE BH-4153: automerge-disabled-* is a harness_flags row read DB-first;
  # no flags/ file is reconciled into place any more. The row's answer lands in
  # the last-good cache instead (as tests/flag-row-kill-switch.bh-1629-test.sh).
  [ ! -e "$Q/flags/automerge-disabled-aproj" ] && ok || bad "Q1 a row-only automerge-disabled-aproj must not write flags/automerge-disabled-aproj (BH-4153)"
  jq -e '.on == true' "$Q/state/flags-cache/fleet/automerge-disabled-aproj" >/dev/null 2>&1 && ok \
    || bad "Q1 the aproj row's answer must be cached in state/flags-cache/fleet/automerge-disabled-aproj"
  [ -f "$Q/state/merge-queue/aproj/41" ] && ok || bad "Q1 aproj's queue entry is kept, not dropped"
  mq bproj >/dev/null
  [ -s "$Q/calls-bproj.txt" ] && ok || bad "Q2 bproj's merge queue is NOT stopped by aproj's toggle (never reached its first merge call)"
  [ ! -e "$Q/flags/automerge-disabled" ] && ok || bad "Q2 no fleet kill switch appeared"
else
  echo "flock missing — skipping Q"
fi

# ---------- P. review-prs hold_automerge_disabled ---------------------------
awk '/^hold_automerge_disabled\(\)/{f=1} f{print} f&&/; \}$/{exit}' "$DIR/bin/review-prs.sh" > "$T/hold.sh"
[ -s "$T/hold.sh" ] && ok || bad "P could not extract hold_automerge_disabled from bin/review-prs.sh"
mkdir -p "$T/p/flags"; touch "$T/p/flags/automerge-disabled-alpha-os"
hold() { HARNESS="$T/p" PROJECT="$1" bash -c '. "$0"; hold_automerge_disabled' "$T/hold.sh"; }
hold alpha-os && ok || bad "P1 review-prs holds alpha-os's tier-1 merge under its own flag"
hold beta-os && bad "P1 review-prs must NOT hold beta-os for alpha-os's flag" || ok
rm -f "$T/p/flags/"*; touch "$T/p/flags/automerge-disabled"
hold beta-os && ok || bad "P2 the fleet kill switch still holds every project"

# ---------- C. every other merge writer honours the project flag ------------
# Each of these merges (or enqueues a merge) for one project at a time and
# already honours the fleet switch; each must name the project flag too.
for f in bin/lib/rb/pr.sh bin/lander.sh bin/lib/autoenqueue.sh bin/merge-sweep.sh \
         bin/merge-conductor.sh bin/batch-resolve.sh; do
  grep -qE 'automerge-disabled-\$(\{)?[A-Za-z_]+' "$DIR/$f" && ok \
    || bad "C $f merges per project but never reads flags/automerge-disabled-<project>"
done

# ---------- L. the Lanes page sees a board's toggle ------------------------
# worker/jobs/src/routes/lanes.js expands a trailing-dash alias with the viewed
# project (the `paused-` shape in fly-pool.json). A lane whose fleet alias is
# `present` gets the board alias `present` too; the conductor keeps running
# for that board with merges off (MERGES=0, never KILL), so it is `partial`.
for pair in merge-queue:present review-prs:present batch-resolve:present merge-conductor:partial; do
  lane=${pair%%:*}; want=${pair#*:}
  got=$(jq -r '[.switch.aliases[]? | select(type=="object" and .name=="automerge-disabled-") | .off_when] | join(",")' \
    "$DIR/catalog/lanes.d/$lane.json" 2>/dev/null)
  [ "$got" = "$want" ] && ok || bad "L $lane: alias automerge-disabled- off_when=$want (got '${got:-none}')"
done
# Every lane that aliases the fleet switch is covered, not only the four above.
for f in "$DIR"/catalog/lanes.d/*.json; do
  jq -e '[.switch.aliases[]? | select(type=="object" and .name=="automerge-disabled")] | length > 0' "$f" >/dev/null 2>&1 || continue
  jq -e '[.switch.aliases[]? | select(type=="object" and .name=="automerge-disabled-")] | length > 0' "$f" >/dev/null 2>&1 \
    && ok || bad "L $(basename "$f" .json) aliases automerge-disabled but not the board form automerge-disabled-"
done

echo "automerge-scope.bh-2322: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
