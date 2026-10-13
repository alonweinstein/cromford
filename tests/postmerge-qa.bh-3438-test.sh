#!/bin/bash
# tests/postmerge-qa.bh-3438-test.sh — BH-3438: project-5 is on the post-merge
# QA lane, and `postmerge-qa.sh <project> --dry-run` resolves the account and
# the routes without driving, calling or writing anything.
#
#   A  catalog/lanes.d/postmerge-qa.json lists project-5, the fragment has a
#      `# @box project-5` variant running `postmerge-qa.sh project-5`, and the
#      rendered project-5 crontab carries exactly one such line
#   B  dry run, env set + a build plan: rc 0, user/key/prod/routes printed, the
#      key VALUE never printed, zero gh/curl/node calls, no done row, no ALERTS
#   C  dry run, empty env: rc 1, user=UNSET, names the owed env vars
#   D  dry run, no build dirs: build=none routes=/
#   E  explicit build-dir + --dry-run uses that build's routes; and a non-dry
#      `postmerge-qa.sh project-5 <builddir>` still reads arg 2 as the build
#
# Every dry-run assertion is on what the REAL script printed and wrote in a
# scratch harness (fake gh, curl and node that record each call).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa.bh-3438-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "postmerge-qa.bh-3438: jq is required"; exit 1; }
command -v flock >/dev/null || { echo "postmerge-qa.bh-3438: flock is required"; exit 1; }
BASE="$T"

# --- A. the lane config and the rendered crontab ----------------------------------
jq -e '.boxes | index("project-5")' "$DIR/catalog/lanes.d/postmerge-qa.json" >/dev/null \
  && ok || bad "A: catalog/lanes.d/postmerge-qa.json .boxes does not list project-5"
FRAG="$DIR/cron/lanes/600-postmerge-qa.cron"
awk '/^# @box /{s=$3; next} s=="project-5"' "$FRAG" | grep -q '/bin/postmerge-qa.sh project-5 ' \
  && ok || bad "A: $FRAG has no '# @box project-5' variant running postmerge-qa.sh project-5"
# The render reads the generated registry; build it into a scratch copy of the
# inputs so the check never writes into the checkout.
R="$BASE/render"; mkdir -p "$R"
cp -r "$DIR/bin" "$DIR/catalog" "$DIR/cron" "$R/" 2>/dev/null
cp "$DIR/fleet.conf" "$R/" 2>/dev/null
if (cd "$R" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --write >/dev/null 2>&1) && [ -s "$R/catalog/lanes.json" ]; then
  OUT=$(cd "$R" && bin/render-cron.sh --root "$R" project-5 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "A: render-cron.sh project-5 rc=$RC: $(head -c 400 <<<"$OUT")"
  N=$(grep -c 'postmerge-qa\.sh project-5 ' <<<"$OUT")
  [ "$N" = 1 ] && ok || bad "A: the project-5 crontab must carry exactly one postmerge-qa.sh project-5 line (got $N)"
  grep -q 'postmerge-qa\.sh project-4' <<<"$OUT" \
    && bad "A: project-5 rendered project-4's default postmerge line" || ok
else
  bad "A: could not build a scratch catalog/lanes.json to render from"
fi

# --- the scratch harness for the script ---------------------------------------------
new_harness() {
  local T; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env" "$T/builds"
  local F
  for F in postmerge-qa.sh fleet-conf.sh prod-url.sh; do
    cp "$DIR/bin/$F" "$T/bin/$F"; chmod +x "$T/bin/$F"
  done
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
  printf 'project-5     example-org/project-5        https://project-5.example                 -                               9  box-project-5-1 10.0.0.5\n' > "$T/fleet.conf"
  : > "$T/env/global.env"
  printf 'QA_TEST_USER_ID=user_TS\nQA_CLERK_SECRET_KEY=sk_test_fake\n' > "$T/env/project-5.env"
  local C
  for C in gh curl node; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/stub-calls.txt"\nexit 0\n' "$C" "$T" > "$T/fakebin/$C"
    chmod +x "$T/fakebin/$C"
  done
  # qa-unbanned.sh and agent-call.sh would be network in production: record them.
  for C in qa-unbanned.sh agent-call.sh beat.sh; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/stub-calls.txt"\nexit 0\n' "$C" "$T" > "$T/bin/$C"
    chmod +x "$T/bin/$C"
  done
  printf '%s' "$T"
}
seed_build() { # seed_build <harness> <name> <route...>
  local d="$1/builds/$2"; shift 2; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-5/pull/7" > "$d/RESULT"
  { printf '# plan\n\n## QA screens\n\n'; printf -- '- `%s`\n' "$@"; printf '\n## Size\n'; } > "$d/plan.md"
  printf '%s' "$d"
}
run() { # run <harness> <args...>   — stdout+stderr to $T/out.txt, rc echoed
  local T="$1"; shift
  env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" HARNESS="$T" FLEET_CONF="$T/fleet.conf" \
      HARNESS_ENV_DIR="$T/env" QA_REPO_DIR="$T/repo" LANE_GATE_DISABLE=1 \
      "$T/bin/postmerge-qa.sh" "$@" > "$T/out.txt" 2>&1
  echo $?
}
calls() { [ -f "$1/stub-calls.txt" ] || { echo 0; return 0; }; grep -c '' "$1/stub-calls.txt"; }

# --- B. env set, one build with a plan ----------------------------------------------
T=$(new_harness); seed_build "$T" project-5-TK-1-202609290000 /scan/new /reports >/dev/null
RC=$(run "$T" project-5 --dry-run); OUT=$(cat "$T/out.txt")
[ "$RC" = 0 ] && ok || bad "B: a fully configured dry run must exit 0 (rc=$RC): $OUT"
grep -q '^DRY RUN postmerge-qa project-5: ' <<<"$OUT" && ok || bad "B: no 'DRY RUN postmerge-qa project-5:' line: $OUT"
grep -q 'user=user_TS' <<<"$OUT" && ok || bad "B: user=user_TS not printed: $OUT"
grep -q 'clerk_key=set' <<<"$OUT" && ok || bad "B: clerk_key=set not printed: $OUT"
grep -q 'prod=https://project-5.example' <<<"$OUT" && ok || bad "B: prod URL not printed: $OUT"
grep -q 'build=project-5-TK-1-202609290000' <<<"$OUT" && ok || bad "B: the build the routes came from is not named: $OUT"
grep -q 'routes=.*/scan/new' <<<"$OUT" && ok || bad "B: /scan/new not among the routes: $OUT"
grep -q 'routes=.*/reports' <<<"$OUT" && ok || bad "B: /reports not among the routes: $OUT"
grep -q 'sk_test_fake' <<<"$OUT" && bad "B: the Clerk key VALUE was printed" || ok
[ "$(calls "$T")" = 0 ] && ok || bad "B: the dry run called out: $(cat "$T/stub-calls.txt")"
[ ! -e "$T/state/postmerge-qa-done.txt" ] && ok || bad "B: the dry run wrote a done row"
[ ! -e "$T/logs/ALERTS.log" ] && ok || bad "B: the dry run wrote ALERTS.log"
[ ! -s "$T/logs/postmerge-qa.log" ] && ok || bad "B: the dry run wrote to the lane log: $(cat "$T/logs/postmerge-qa.log")"

# --- C. empty env -----------------------------------------------------------------------
T=$(new_harness); : > "$T/env/project-5.env"; seed_build "$T" project-5-TK-2-202609290000 /reports >/dev/null
RC=$(run "$T" project-5 --dry-run); OUT=$(cat "$T/out.txt")
[ "$RC" = 1 ] && ok || bad "C: an unconfigured account must exit 1 (rc=$RC): $OUT"
grep -q 'user=UNSET' <<<"$OUT" && ok || bad "C: user=UNSET not printed: $OUT"
grep -q 'clerk_key=UNSET' <<<"$OUT" && ok || bad "C: clerk_key=UNSET not printed: $OUT"
grep -q 'QA_TEST_USER_ID' <<<"$OUT" && ok || bad "C: the owed env var is not named: $OUT"
[ "$(calls "$T")" = 0 ] && ok || bad "C: the dry run called out: $(cat "$T/stub-calls.txt")"
[ ! -e "$T/state/postmerge-qa-done.txt" ] && ok || bad "C: an unconfigured dry run wrote a done row"

# --- D. no build dirs -------------------------------------------------------------------
T=$(new_harness)
RC=$(run "$T" project-5 --dry-run); OUT=$(cat "$T/out.txt")
[ "$RC" = 0 ] && ok || bad "D: rc=$RC: $OUT"
grep -q 'build=none routes=/$' <<<"$OUT" && ok || bad "D: no builds must print 'build=none routes=/': $OUT"

# --- E. explicit build dir + --dry-run, and the positional without it -----------------
T=$(new_harness)
seed_build "$T" project-5-TK-3-202609290000 /team >/dev/null
B=$(seed_build "$T" project-5-TK-4-202609280000 /connections)
touch -d '2026-09-28' "$B"
RC=$(run "$T" project-5 "$B" --dry-run); OUT=$(cat "$T/out.txt")
[ "$RC" = 0 ] && ok || bad "E: rc=$RC: $OUT"
grep -q 'build=project-5-TK-4-202609280000 routes=/connections$' <<<"$OUT" \
  && ok || bad "E: an explicit build-dir must supply the routes: $OUT"
RC=$(run "$T" project-5 --dry-run "$B"); OUT=$(cat "$T/out.txt")
grep -q 'build=project-5-TK-4-202609280000' <<<"$OUT" && ok || bad "E: --dry-run before the build-dir must still take it: $OUT"
# Non-dry, positional build: the script must take arg 2 as THE build (the gh stub
# answers nothing, so the build is skipped at the merge read — but gh was asked
# about exactly this build's PR, which only happens when arg 2 was the build).
export POSTMERGE_QA_MODEL=stub-model
T=$(new_harness); B=$(seed_build "$T" project-5-TK-5-202609290000 /reports)
env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" HARNESS="$T" FLEET_CONF="$T/fleet.conf" \
    HARNESS_ENV_DIR="$T/env" QA_REPO_DIR="$T/repo" LANE_GATE_DISABLE=1 POSTMERGE_QA_MODEL=stub-model \
    "$T/bin/postmerge-qa.sh" project-5 "$B" >/dev/null 2>&1
grep -q '^gh pr view https://github.com/example-org/project-5/pull/7' "$T/stub-calls.txt" 2>/dev/null \
  && ok || bad "E: a non-dry run with a build-dir arg must read that build's PR (calls: $(cat "$T/stub-calls.txt" 2>/dev/null))"
grep -q '^DRY RUN' "$T/out.txt" 2>/dev/null && bad "E: a non-dry run printed a dry-run line" || ok

echo "postmerge-qa.bh-3438: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
