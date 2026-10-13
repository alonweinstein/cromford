#!/bin/bash
# tests/wake-loop-claims.bh-2637-test.sh — bin/wake-loop.sh on EVERY box
# (BH-2525.2): each box claims its own wake rows, keeps its watermark in the
# wake_cursors row, takes launch cooldowns from wake_cooldowns, and never ssh's.
#
# Drives the REAL bin/wake-loop.sh, the REAL jobs-client (bin/lib/jobs/queue.sh's
# wakes_claim / wake_cursor_* / wake_cooldown_take), the REAL wake-class libs,
# bin/box-name.sh, bin/box-for.sh and bin/lib/hub-box.sh. The worker is
# tests/lib/wake-claim-stub.sh (the routes of worker/jobs/src/routes/wakes.js
# over files); every lane the loop can launch is a recorder.
#
# The stubbed fleet: project-3 -> box-project-3-1 (example-org/project-3),
# cromford -> box-small (example-org/cromford), project-1 ->
# local (example-org/project-1). The hub is box-hub.
#
# M1-M4 at the end are the D1 self-check: each mutates a copy of the loop and
# asserts the case that pins that behaviour goes RED.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-loop-claims.bh-2637-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
export HARNESS="$H" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
LOOP_SRC="$DIR/bin/wake-loop.sh"
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train migration-autopilot
  apply-migrations flaky-detect prompt-eval fleet-propagate review-autopilot reconcile-prs
  check-migration-prs alerts-groom tickets-snapshot-push alerts-resolve-closed-prs"

# A checkout whose one commit touches prompts/, so wake-class-push's
# prompts_touched answers YES for $PSHA (N7 needs prompt-eval to be WANTED).
CK="$T/checkout"
mkdir -p "$CK/prompts"
git -C "$CK" init -q 2>/dev/null
echo x > "$CK/prompts/p.md"
git -C "$CK" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "$CK" -c user.email=t@t -c user.name=t commit -qm p >/dev/null 2>&1
PSHA=$(git -C "$CK" rev-parse HEAD)
export HARNESS_CHECKOUT="$CK"

# fresh [probe-class-body] — a new harness tree, a new stub worker, no calls.
fresh() {
  scratch_rm "$H"
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags" "$H/calls"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
  cp "$LOOP_SRC" "$H/bin/wake-loop.sh"
  cp "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/wake-lanes.sh" "$DIR"/bin/lib/wake-class-*.sh "$H/bin/lib/"
  wcs_install "$H/bin"
  wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\ncromford\nproject-1\n'; exit 0; }
case "$1/$2" in
  project-3/repo)       echo example-org/project-3 ;;
  cromford/repo) echo example-org/cromford ;;
  project-1/repo)   echo example-org/project-1 ;;
  project-3/box)        echo box-project-3-1 ;;
  cromford/box)  echo box-small ;;
  project-1/box)    echo local ;;
  */board_prefix)     echo /api/board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
  done
  printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
  printf '#!/bin/bash\necho "[]"\n' > "$H/bin/gh"
  printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
  chmod +x "$H/bin/"*.sh "$H/bin/gh" "$H/bin/setsid"
  for c in push pr-ci deploy pr-closed flaky split-chain; do touch "$H/flags/wake-lanes-$c"; done
  if [ -n "${1:-}" ]; then
    printf '%s\n' "$1" > "$H/bin/lib/wake-class-zz-probe.sh"
    touch "$H/flags/wake-lanes-zz-probe"
  fi
  : > "$T/wakes.json"
}
export WCS_WAKES="$T/wakes.json"
export PATH="$H/bin:$PATH"

wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <repo> <kind> <key> [event]
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-27T03:00:00Z"}' \
    "$1" "$2" "$3" "$4" "${5:-ev}"
}
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    cur=$(cat "$H/calls/"* "$H/ssh.log" 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
}
run_as() { BOX_NAME="$1" "$H/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
calls() { if [ -f "$H/calls/$1" ]; then wc -l < "$H/calls/$1" | tr -d " "; else echo 0; fi; }
LOG() { cat "$H/logs/wake-loop.log" 2>/dev/null; }
REQ() { wcs_log; }
line_of() { REQ | grep -n -m1 -- "$1" | cut -d: -f1; }
# claim_body — the JSON body of the first claim request.
claim_body() { REQ | awk '$1=="POST" && $2=="/api/wakes/claim" { $1=""; $2=""; sub(/^  /, ""); print; exit }'; }
none_of() { local s; for s in "$@"; do [ "$(calls "$s")" = 0 ] || { echo "$s recorded: $(cat "$H/calls/$s")"; return 1; }; done; }

project-3=example-org/project-3 BH=example-org/cromford MOM=example-org/project-1

# ── the cases, as functions: rc 0 = the case holds; each prints why it does not.
case_A() { # the owning box launches its own lanes; the conductor never runs off-hub
  fresh; wakes "$(W 1 $project-3 push abc1234)" "$(W 2 $project-3 issue 12)" "$(W 3 $project-3 pr 7 pull_request.opened)"
  run_as box-project-3-1
  [ "$(calls deploy-train)" = 1 ] || { echo "A deploy-train=$(calls deploy-train)"; return 1; }
  grep -qx project-3 "$H/calls/run-triage" 2>/dev/null || { echo "A run-triage not recorded: $(LOG | tail -5)"; return 1; }
  grep -qx project-3 "$H/calls/review-prs" 2>/dev/null || { echo "A review-prs not recorded: $(LOG | tail -5)"; return 1; }
  none_of merge-conductor || return 1
}
case_B() { # the hub: conductor for another box's pr row, nothing else for it
  fresh; wakes "$(W 5 $project-3 pr 44 pull_request.opened)"
  run_as box-hub
  [ "$(calls merge-conductor)" = 1 ] || { echo "B merge-conductor=$(calls merge-conductor): $(LOG)"; return 1; }
  none_of review-prs deploy-train run-triage || return 1
  ! grep -q '"project":"project-3"' <<<"$(grep '/api/wakes/cooldown/take' <<<"$(REQ)")" \
    || { echo "B took an project-3 cooldown on the hub: $(REQ | grep cooldown)"; return 1; }
}
case_C() { # the claim body carries exactly this box's repos, lowercased
  local b
  fresh; wakes; run_as box-project-3-1; b=$(claim_body)
  [ "$(jq -c .repos <<<"$b")" = '["example-org/project-3"]' ] && [ "$(jq -c .kinds_all_repos <<<"$b")" = '[]' ] \
    && [ "$(jq -c .limit <<<"$b")" = 200 ] && [ "$(jq -r .box <<<"$b")" = box-project-3-1 ] \
    || { echo "C project-3 claim body: $b"; return 1; }
  fresh; wakes; run_as box-hub; b=$(claim_body)
  # TEST-CHANGE (BH-4057): the hub also claims every repo's lead-land rows, because only the hub lands.
  [ "$(jq -c .repos <<<"$b")" = '["example-org/project-1"]' ] && [ "$(jq -c .kinds_all_repos <<<"$b")" = '["pr","checks","lead-land"]' ] \
    || { echo "C hub claim body: $b"; return 1; }
  fresh; wakes; WAKE_CLAIM_LIMIT=7 run_as box-project-3-1; b=$(claim_body)
  [ "$(jq -c .limit <<<"$b")" = 7 ] || { echo "C WAKE_CLAIM_LIMIT=7 body: $b"; return 1; }
  fresh; wakes; WAKE_CLAIM_LIMIT=900 run_as box-project-3-1; b=$(claim_body)
  [ "$(jq -c .limit <<<"$b")" = 200 ] && LOG | grep -q "WAKE_CLAIM_LIMIT='900'" \
    || { echo "C WAKE_CLAIM_LIMIT=900 must fall back to 200 with a line: $b / $(LOG)"; return 1; }
}
case_D() { # cursor PUT carries scanned_top, BEFORE the ack; no file, no settings mirror
  local put ack
  fresh; wakes "$(W 7 $project-3 push s1)" "$(W 9 $project-3 deploy d1)" "$(W 11 $BH push s2)"
  run_as box-project-3-1
  put=$(line_of 'PUT /api/wakes/cursor {"box":"box-project-3-1","cursor":9}')
  ack=$(line_of 'POST /api/wakes/ack')
  [ -n "$put" ] && [ -n "$ack" ] && [ "$put" -lt "$ack" ] || { echo "D put=$put ack=$ack: $(REQ)"; return 1; }
  [ ! -e "$H/state/wake-cursor" ] || { echo "D state/wake-cursor exists"; return 1; }
  ! grep -q 'wake-cursor\.' <<<"$(REQ)" || { echo "D a settings wake-cursor request was made"; return 1; }
}
case_E() { # a failed PUT still acks; a re-claim of the same rows launches nothing
  fresh; wakes "$(W 3 $project-3 push s1)"
  echo 500 > "$H/state/wcs/CURSOR_PUT_MODE"
  run_as box-project-3-1
  REQ | grep -q '^POST /api/wakes/ack' || { echo "E no ack after a failed put: $(REQ)"; return 1; }
  [ "$(LOG | grep -c 'cursor put failed at 3')" = 1 ] || { echo "E log: $(LOG)"; return 1; }
  scratch_rm "$H/calls"; mkdir -p "$H/calls"; : > "$H/state/wcs/curl.log"
  run_as box-project-3-1
  none_of deploy-train rebase-train || return 1
  ! grep -q '^POST /api/wakes/ack' <<<"$(REQ)" || { echo "E acked an empty claim"; return 1; }
}
case_F() { # taken:false -> no launch
  fresh; echo false > "$H/state/wcs/COOL_MODE"
  wakes "$(W 1 $project-3 push s1)" "$(W 2 $project-3 deploy d1)" "$(W 3 $project-3 issue 12)"
  run_as box-project-3-1
  none_of deploy-train postmerge-qa run-triage || return 1
}
case_G() { # cooldown 500 -> no launch, exactly one line per (kind, project)
  fresh; echo 500 > "$H/state/wcs/COOL_MODE"
  wakes "$(W 1 $project-3 push s1)" "$(W 2 $project-3 push s2)"
  WAKE_LOOP_CYCLES=1 run_as box-project-3-1
  none_of deploy-train rebase-train || return 1
  [ "$(LOG | grep -c 'cooldown row unreachable — cron covers push\[project-3\]')" = 1 ] \
    || { echo "G log: $(LOG)"; return 1; }
}
case_H() { # no local cooldown directory, ever
  case_A >/dev/null || true
  [ ! -e "$H/state/wake-cooldown" ] || { echo "H state/wake-cooldown exists"; return 1; }
}
# The probe class calls the two placement functions the class libs call, for a
# project the HUB does not own — the way wake-class-pr-ci / -deploy / -push do.
PROBE_I='wc_zz_probe_row() { :; }
wc_zz_probe_dispatch() {
  launch_triage project-3 "probe wake" 12
  remote_launch "probe[project-3]" project-3 postmerge-qa.sh project-3
}'
case_I() { # no ssh, ever: the other-box arms log and return
  fresh "$PROBE_I"; echo 1 > "$H/state/wcs/CLAIM_ALL"
  wakes "$(W 1 $project-3 issue 12)" "$(W 2 $project-3 deploy d1)" "$(W 3 $project-3 pr 9 pull_request.opened)"
  run_as box-hub
  [ ! -s "$H/ssh.log" ] || { echo "I ssh was called: $(cat "$H/ssh.log")"; return 1; }
  none_of run-triage postmerge-qa review-prs || return 1
  LOG | grep -q 'triage\[project-3\]: owned by box-project-3-1 — its own loop claims this wake' \
    && LOG | grep -q 'probe\[project-3\]: owned by box-project-3-1 — its own loop claims this wake' \
    || { echo "I log: $(LOG)"; return 1; }
  ! grep -nE '\bssh\b +-' "$H/bin/wake-loop.sh" || { echo "I the loop still carries an ssh call"; return 1; }
}
case_N1() { # a non-hub box handed a pr row of a repo it does not own launches nothing
  fresh; echo 1 > "$H/state/wcs/CLAIM_ALL"
  wakes "$(W 1 $BH pr 3 pull_request.opened)" "$(W 2 $BH push s9)" "$(W 3 $BH issue 4)"
  run_as box-project-3-1
  none_of $LANES || return 1
  ! grep -q '"project":"cromford"' <<<"$(grep '/api/wakes/cooldown/take' <<<"$(REQ)")" \
    || { echo "N1 took a cromford cooldown: $(REQ | grep cooldown)"; return 1; }
  [ ! -e "$H/state/wake-cromford" ] || { echo "N1 un-braked another box's triage"; return 1; }
  local b; b=$(claim_body)
  [ "$(jq -c .repos <<<"$b")" = '["example-org/project-3"]' ] || { echo "N1 claim body: $b"; return 1; }
}
case_N2() { # an unregistered repo is dropped
  fresh; echo 1 > "$H/state/wcs/CLAIM_ALL"
  wakes "$(W 1 example-org/not-in-fleet push s1)" "$(W 2 example-org/not-in-fleet pr 1 pull_request.opened)"
  run_as box-hub
  none_of $LANES || return 1
  LOG | grep -q 'not a fleet repo' || { echo "N2 log: $(LOG)"; return 1; }
}
case_N3() { # the lookalike repo is neither claimed nor launched
  local b
  fresh; wakes "$(W 1 example-org/cromford-x push s1)"
  run_as box-small; b=$(claim_body)
  [ "$(jq -c .repos <<<"$b")" = '["example-org/cromford"]' ] || { echo "N3 claim body: $b"; return 1; }
  echo 1 > "$H/state/wcs/CLAIM_ALL"; rm -f "$H/state/wcs/claimed."*
  run_as box-small
  none_of $LANES || return 1
}
case_N4() { # a non-hub box's own pr row never buys a conductor
  fresh; wakes "$(W 1 $project-3 pr 5 pull_request.opened)" "$(W 2 $project-3 checks c1 check_suite.completed)"
  run_as box-project-3-1
  none_of merge-conductor || return 1
  ! grep -q '"kind":"pr","project":"fleet"' <<<"$(REQ)" || { echo "N4 asked for the conductor's cooldown off-hub"; return 1; }
}
case_N5() { # a box owning nothing asks nothing
  fresh; wakes "$(W 1 $project-3 push s1)"
  run_as box-idle
  ! grep -q '/api/wakes/claim' <<<"$(REQ)" || { echo "N5 claimed: $(REQ)"; return 1; }
  [ "$(LOG | grep -c 'owns no fleet repo — nothing to claim')" = 1 ] || { echo "N5 log: $(LOG)"; return 1; }
}
case_N6() { # off-hub, fleet-wide lanes are the hub's: no request for them
  fresh; wakes "$(W 1 $project-3 pr 5 pull_request.closed)" "$(W 2 $project-3 pr 6 pull_request.opened)"
  run_as box-project-3-1
  ! grep -q '"project":"fleet"' <<<"$(grep '/api/wakes/cooldown/take' <<<"$(REQ)")" \
    || { echo "N6 fleet take off-hub: $(REQ | grep cooldown)"; return 1; }
  none_of reconcile-prs check-migration-prs alerts-groom review-autopilot tickets-snapshot-push || return 1
}
case_N7() { # hub-scoped lanes never fire on a box, even for its own project
  fresh; wakes "$(W 1 $BH push "$PSHA")"
  run_as box-small
  none_of prompt-eval fleet-propagate || return 1
  [ "$(calls deploy-train)" = 1 ] || { echo "N7 deploy-train=$(calls deploy-train): $(LOG)"; return 1; }
}
PROBE_N7B='wc_zz_probe_row() { :; }
wc_zz_probe_dispatch() { launch "probe[cromford]" "$SELF/flaky-detect.sh" cromford; }'
case_N7b() { # launch() itself refuses a hub lane off-hub
  fresh "$PROBE_N7B"; wakes "$(W 1 $BH push s1)"
  run_as box-small
  none_of flaky-detect || return 1
  LOG | grep -q 'probe\[cromford\]: flaky-detect.sh is a hub lane — not launched on box-small' \
    || { echo "N7b log: $(LOG)"; return 1; }
}
case_S1() { # no own cursor row: adopt the hub's once, before the first claim
  local put claim
  fresh; echo 41 > "$H/state/wcs/cursor.box-hub"
  wakes "$(W 30 $project-3 deploy old)" "$(W 50 $project-3 push new)"
  run_as box-project-3-1
  put=$(line_of 'PUT /api/wakes/cursor {"box":"box-project-3-1","cursor":41}')
  claim=$(line_of 'POST /api/wakes/claim')
  [ -n "$put" ] && [ -n "$claim" ] && [ "$put" -lt "$claim" ] || { echo "S1 put=$put claim=$claim: $(REQ)"; return 1; }
  [ "$(calls deploy-train)" = 1 ] && LOG | grep -q "cursor seeded from the hub's: 41" \
    || { echo "S1 deploy-train=$(calls deploy-train) log: $(LOG)"; return 1; }
  none_of postmerge-qa || { echo "S1 row 30 sits below the adopted cursor and must not launch"; return 1; }
}
case_S2() { # zero claimed rows still move the cursor, once
  fresh; echo 0 > "$H/state/wcs/cursor.box-project-3-1"
  printf '80\n85\n90\n' > "$H/state/wcs/claimed.box-project-3-1"
  wakes "$(W 80 $project-3 push a)" "$(W 85 $project-3 push b)" "$(W 90 $project-3 deploy c)"
  WAKE_LOOP_CYCLES=3 run_as box-project-3-1
  [ "$(REQ | grep -c '^PUT /api/wakes/cursor')" = 1 ] \
    && REQ | grep -q '^PUT /api/wakes/cursor {"box":"box-project-3-1","cursor":90}' \
    || { echo "S2 puts: $(REQ | grep cursor)"; return 1; }
  none_of deploy-train postmerge-qa || return 1
  ! grep -q '^POST /api/wakes/ack' <<<"$(REQ)" || { echo "S2 acked nothing-claimed"; return 1; }
}

check() { local out; if out=$("$1" 2>&1); then ok; else bad "$1 — $out"; fi; }
for c in A B C D E F G H I N1 N2 N3 N4 N5 N6 N7 N7b S1 S2; do check "case_$c"; done

# ── D1: mutate the loop, and the case that pins the behaviour must go red ───
MUT="$T/mutant.sh"
mutant() { # mutant <name> <case> <sed-expr>
  sed -e "$3" "$DIR/bin/wake-loop.sh" > "$MUT"
  if cmp -s "$MUT" "$DIR/bin/wake-loop.sh"; then bad "$1: the sed did not change the loop (the mutation point moved)"; return; fi
  LOOP_SRC="$MUT"
  if "$2" >/dev/null 2>&1; then bad "$1: $2 stayed GREEN on the mutant"; else ok; fi
  LOOP_SRC="$DIR/bin/wake-loop.sh"
}
# M1: every fleet repo counts as owned -> the claim asks for all of them.
mutant M1 case_C  's/^owned_here() {/owned_here() { return 0;/'
mutant M1 case_N1 's/^owned_here() {/owned_here() { return 0;/'
# M2: every cooldown is taken, whatever the row says.
mutant M2 case_F  's/^cooled() {/cooled() { return 0;/'
mutant M2 case_G  's/^cooled() {/cooled() { return 0;/'
# M3: one ssh launch restored in launch_triage's other-box arm.
mutant M3 case_I  '/triage\[\$p\]: owned by \$box/s/say /ssh -n "root@$box" true; say /'
# M4: the hub-lane guard in launch() removed.
mutant M4 case_N7b 's/^hub_lane_script() {/hub_lane_script() { return 1;/'

echo "wake-loop-claims (BH-2637): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
