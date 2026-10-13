#!/bin/bash
# tests/batch-resolve-trains.bh-1287-test.sh — BH-1287: the THREE train CI knobs
# are settable from a D1 settings ROW, not only from the environment.
#
# bin/lib/mc/train.sh fixes MC_TRAIN_CI_REQUIRED / MC_TRAIN_CI_WORKFLOW /
# MC_TRAIN_CI_IGNORE at SOURCE time from `${BATCH_CI_*:-default}`. Sourced ABOVE
# `lane_env_apply` — where it was until #1297 — those three read the box's
# environment and could never see a `lane.batch-resolve.*` row: the registry
# called them settable, the console wrote the row, the row was exported one line
# too late, and the lane went on logging the default back at the operator who
# had just changed it. Nothing errored, because the env-file path worked
# throughout, which is why this went unnoticed for as long as it did.
#
# The product fix (source the module BELOW lane_env_apply) shipped in #1297.
# tests/batch-resolve-trains.bh-1270-test.sh T9 pins ONE of the three knobs,
# BATCH_CI_RUN_REQUIRED. This file pins the other two, so a re-ordering that
# happened to keep RUN_REQUIRED working — reading one knob at call time and
# leaving the other two at source time, which is the ticket's "option A" done
# halfway — cannot pass CI:
#
#   W  a `lane.batch-resolve.batch_ci_workflow` ROW changes the NAME of the
#      workflow run mrt_head_green asks for, and the row's own value comes back
#      in the refusal line
#   I  a `lane.batch-resolve.batch_ci_ignore` ROW widens the check-run ignore
#      list, so a pending check of a name the row names stops holding the freeze
#
# Both cases drive the SHIPPED bin/batch-resolve.sh (D2) through its main-red
# freeze-lift branch (bin/batch-resolve.sh:253-302), which runs before any
# candidate work — so no PRs are needed and nothing here builds a train. Both
# arms of each case are visible from OUTSIDE the module: the flag file the lane
# removes, and the line it writes to logs/batch-resolve.log (D3). `gh` is
# stubbed, always: nothing here may touch GitHub.
#
# Run from anywhere: tests/batch-resolve-trains.bh-1287-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
if [ -n "${BATCH_TEST_KEEP:-}" ]; then echo "fixture kept at $T"; else trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

SLUG=example-org/demo-os
PROJ=demo-os

# ── a real repository, and a real remote that never leaves this box ──────────
# The lane resolves `remote_head main` to arm the merged fix PR, so the origin
# has to be a real ref and not a literal sha somebody typed here.
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
S="$T/seed"
mkdir -p "$S/src"
printf 'export const base = 1\n' > "$S/src/base.ts"
printf '#!/bin/sh\nexit 0\n' > "$S/ci-stub.sh"
chmod +x "$S/ci-stub.sh"
cat > "$S/CLAUDE.md" <<'CLAUDEMD'
# demo-os

## Verification Contract

```bash
bash ci-stub.sh
```
CLAUDEMD
git -C "$S" add -A && git -C "$S" commit -qm base >/dev/null && git -C "$S" push -q origin main

# ── the harness tree ─────────────────────────────────────────────────────────
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" \
         "$H/tmp" "$H/plans" "$T/fakebin" "$T/repos"
export FLEET_CONF="$H/fleet.conf"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/main-red-gate.sh" \
   "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/batch-resolve.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
# THE REGISTRY IS RENDERED, NEVER COPIED (BH-1247/#1275). catalog/lanes.json is
# git-ignored — it is composed from catalog/lanes.d/ on demand — so a fixture
# that COPIES it reads an artifact that exists on a developer's box and not in
# CI, and the lane then finds no registry, lane_env_apply returns early, and
# every case here passes for a reason that has nothing to do with what it tests.
mkdir -p "$H/catalog"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$H/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "could not compose the lane registry — skipping"; exit 0; }
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"

cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\n' "\$1" "\$2" >> "$T/mqueue.tsv"; echo queued; }
merge_train_put() {
  local p="\$1" b="\$2" o="\$3"; shift 3
  printf '%s\t%s\t%s\t%s\n' "\$p" "\$b" "\$o" "\$*" >> "$T/trains.tsv"
  echo "\$o"
}
flag_active() { [ -f "$T/h/flags/\$1" ]; }
flag_set() {
  case "\$2" in off|0|false) rm -f "$T/h/flags/\$1" ;; *) touch "$T/h/flags/\$1" ;; esac
}
EOF

git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
export MC_REPOS="$T/repos"

# ── the fake gh ──────────────────────────────────────────────────────────────
# Two arms matter here and both are FILE-BACKED, because case I needs a check
# run of a custom name and case W needs a workflow run of one:
#   commits/<sha>/check-runs → $T/checks.json when it exists, else one completed
#     `Harness CI` success (the shape a green head has)
#   actions/runs             → $T/runs.json when it exists, else one completed
#     `Harness CI` success run
# Both bodies are the GitHub REST shapes mrt_head_green really reads (D4).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"contents/.mergify.yml"*) exit 1 ;;
  *"-i -X GET repos/$SLUG/commits/"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$(cat "$T/checks.json" 2>/dev/null || echo '{"check_runs":[{"name":"Harness CI","status":"completed","conclusion":"success"}]}')"
    exit 0 ;;
  *"-i -X GET repos/$SLUG/actions/runs"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$(cat "$T/runs.json" 2>/dev/null || echo '{"workflow_runs":[{"id":4242,"name":"Harness CI","status":"completed","conclusion":"success","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}')"
    exit 0 ;;
  *"-i -X GET repos/$SLUG/pulls -f state=closed"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$(cat "$T/closedprs.json" 2>/dev/null || echo '[]')"
    exit 0 ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n'; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"issue view"*) echo OPEN; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
command -v flock >/dev/null 2>&1 || {
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

run() { bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
LOG="$H/logs/batch-resolve.log"
remote_head() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }
reset() {
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/run.out"
  rm -f "$T/runs.json" "$T/checks.json" "$T/closedprs.json" \
        "$H/state/settings-cache.json" "$H/flags/"* 2>/dev/null
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$H/state/merge-conductor/batch-hold"
  rm -f "$H/state/merge-conductor/attempts.txt"
}
FLAG="$H/flags/main-red-example-org-demo-os"

setrow() { # setrow <key> <value>  — one settings row, fresh enough to be used
  mkdir -p "$H/state"
  jq -nc --arg k "$1" --arg v "$2" --argjson t "$(date -u +%s)" \
    '{fetched_at:$t, values:{($k):$v}}' > "$H/state/settings-cache.json"
}
# The freeze, and a merged fix-main-red PR at the base tip. Whether the freeze
# LIFTS is then entirely a question of how mrt_head_green judges that head —
# which is the thing the two rows below move.
armfix() {
  touch "$FLAG"
  jq -nc --arg h "$(remote_head main)" \
    --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
    '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
}

# ============================================================================
# W. A `batch_ci_workflow` ROW REACHES THE MODULE
#    The fix PR's head carries a completed `Harness CI` success and green check
#    runs, so at the default it is green and the freeze lifts. A row that
#    renames the workflow to one this head has NO run of must make the same
#    head un-green — and the refusal must echo the ROW'S OWN VALUE back, which
#    is what distinguishes "the module saw the row" from "it refused for some
#    other reason" (MRT_GREEN_WHY, bin/lib/mc/train.sh:167).
# ============================================================================
reset
armfix
run
[ ! -f "$FLAG" ] && ok \
  || bad "W-1 with no row a head with a concluded 'Harness CI' success must lift the freeze: $(grep -i 'STANDS' "$LOG" | head -1)"
grep -q 'CLEARED' "$LOG" && ok \
  || bad "W-1 and the lift must say so in the lane log: $(tail -3 "$LOG")"

reset
armfix
setrow lane.batch-resolve.batch_ci_workflow "Fleet CI"
run
[ -f "$FLAG" ] && ok \
  || bad "W-2 a settings ROW naming a workflow this head has no run of must hold the freeze — the row is exported by lane_env_apply, so bin/lib/mc/train.sh has to be sourced BELOW it (#1287)"
grep -qE "STANDS — .*no Fleet CI run for" "$LOG" && ok \
  || bad "W-2 the refusal must name the workflow THE ROW asked for, not the default: $(grep -i 'STANDS' "$LOG" | head -1)"

# ============================================================================
# I. A `batch_ci_ignore` ROW REACHES THE MODULE
#    A check run of a name outside the default ignore list, still in_progress,
#    makes the head read 'pending' and holds the freeze. A row that widens the
#    ERE to cover that name must let the same head through.
# ============================================================================
CHECKS='{"check_runs":[{"name":"Harness CI","status":"completed","conclusion":"success"},{"name":"Leak Guard","status":"in_progress","conclusion":null}]}'

reset
armfix
printf '%s\n' "$CHECKS" > "$T/checks.json"
run
[ -f "$FLAG" ] && ok \
  || bad "I-1 with no row a check run outside the default ignore list and still in flight must hold the freeze"
grep -qE "read 'pending', not green" "$LOG" && ok \
  || bad "I-1 and the refusal must say the check runs are pending: $(grep -i 'STANDS' "$LOG" | head -1)"

reset
armfix
printf '%s\n' "$CHECKS" > "$T/checks.json"
setrow lane.batch-resolve.batch_ci_ignore '^(Mergify|Publish share mirror|Leak Guard)'
run
[ ! -f "$FLAG" ] && ok \
  || bad "I-2 a settings ROW that widens the ignore ERE must reach the module and lift the freeze (#1287): $(grep -i 'STANDS' "$LOG" | head -1)"
grep -q 'CLEARED' "$LOG" && ok \
  || bad "I-2 and the lift must say so in the lane log: $(tail -3 "$LOG")"

echo "$PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
