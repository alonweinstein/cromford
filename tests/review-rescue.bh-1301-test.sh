#!/bin/bash
# tests/review-rescue.bh-1301-test.sh — a rescued APPROVE keeps the build's
# provenance (BH-1301).
#
# WHY. bin/review-rescue.sh wrote the upgraded RESULT wholesale: three echo lines
# into `> "$CAND/RESULT"`, which is `PR_CREATED <url>`, the tier and the
# `RESCUED:` note and nothing else. Every line the builder or the staging loop
# had put there — `TICKET_ID:`, `SOURCE:`, `JOB_ID:`, `BUILT_AS:`, `BUILD_DIR:` —
# was gone. The candidate walk is `find $H/builds -maxdepth 2 -name RESULT
# -mmin +90`, so relayed and ledger-staged dirs on a hub-local project are
# candidates too, and a rescue stripped their markers as a matter of course.
#
# Downstream that is not cosmetic. bin/lib/rt/staging.sh identifies a build by
# those lines: `BUILT_AS:` is the cross-path identity the two relay paths match
# on, and `BUILD_DIR:` / `JOB_ID:` are how each path recognises its own staging.
# A marker-less dir made the dedup blind and a later result for the same ticket
# was consumed and lost (tests/staging-identity.bh-1301-test.sh is that half).
#
# So the rewrite is additive: a new header, then every line of the old RESULT
# except the one the header replaces. The fixture is the same shape
# tests/review-rescue-test.sh uses — a real bare origin and clone, a fake gh and
# a stub review agent — because the rewrite only happens at the end of a real
# rescue.
#
# Run from anywhere: tests/review-rescue.bh-1301-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

PRURL="https://github.com/example-org/project-5/pull/777"

# ── the fixture harness tree ─────────────────────────────────────────────────
export HARNESS="$T/h"; H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$T/fakebin" "$T/repos"
cp "$DIR/bin/review-rescue.sh" "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/fleet-projects-or-alert.sh" "$DIR/bin/test-tamper-scan.sh" "$H/bin/"
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"   # TEST-CHANGE BH-1651: the state read is REST
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
export REPOS_ROOT="$T/repos"
# BH-1510.1: this lane's model is a model_routes row (rescue.review); this
# worker-less box carries the resolver beside the lane and its cache of #1507's table.
mkdir -p "$H/bin/lib"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" project-5

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -k) shift 2 ;;
    -*) shift ;;
    [0-9]*) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF
chmod +x "$T/fakebin/flock" "$T/fakebin/timeout"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr create"*)
    printf '%s\n' "\$*" >> "$T/pr-creates.txt"
    echo "$PRURL"; exit 0 ;;
  *"pr list"*"--head"*) cat "$T/prhead.out" 2>/dev/null ;;
  *"-i -X GET"*"/issues/"*)   # TEST-CHANGE BH-1651: gh_rest_issue_state, same fixture
    printf 'HTTP/2 200\r\n\r\n{"state":"%s"}' "\$(tr A-Z a-z < "$T/issue-state.out" 2>/dev/null || echo open)" ;;
  *"pr list"*)          cat "$T/prlist.out" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# The fake reviewer: writes the review.md the prompt names, always TIER: 1 /
# APPROVE, so every case below lands in the branch that rewrites RESULT.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1 \$2 \$5" >> "$T/review-calls.txt"
RM=\$(printf '%s' "\${6:-}" | grep -oE '/[^ ]*/review\.md' | head -1)
[ -n "\$RM" ] && printf 'rescued findings\nTIER: 1\nVERDICT: APPROVE\n' > "\$RM"
[ -n "\${5:-}" ] && : > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"

# ── a real bare origin + clone: the worktree add and merge-base are not faked ─
ORIGIN="$T/origin.git"
git init -q --bare "$ORIGIN"
W="$T/work"; mkdir -p "$W/tests"
(
  cd "$W" || exit 1
  git -c init.defaultBranch=main init -q .
  git config user.email t@t; git config user.name t
  cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds', () => { expect(add(1,2)).toBe(3) })
})
EOF
  echo "src" > app.js
  git add -A; git commit -qm "init"
  git branch -M main
  git remote add origin "$ORIGIN"; git push -q -u origin main
  # The false-block shape: a feature plus an ADDED test, so the re-scan of the
  # tamper block comes back clean and the rescue runs to the APPROVE branch.
  git checkout -q -b ticket/TK-551
  echo "feature" >> app.js
  cat >> tests/thing.test.js <<'EOF'
it('multiplies', () => { expect(mul(2,3)).toBe(6) })
EOF
  git add -A; git commit -qm "TK-551: add multiply and its test"
  git push -q -u origin ticket/TK-551
  # main moves on AFTER the branch is cut — a rescued branch is always behind by
  # the time anyone looks at it — but in a file the branch never touched, so the
  # merge the lane makes is clean and the rescue reaches its RESULT rewrite.
  git checkout -q main
  echo "later" > mainfile.txt
  git add -A; git commit -qm "main: moves on"
  git push -q origin main
) >/dev/null 2>&1
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$T/repos/project-5"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

# ── helpers ──────────────────────────────────────────────────────────────────
ago() { date -d "-$1 minutes" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"$1"M +%Y%m%d%H%M.%S; }
reset_h() { scratch_rm "$H/builds"; scratch_rm "$H/logs"; scratch_rm "$H/flags"
            mkdir -p "$H/builds" "$H/logs" "$H/flags"
            : > "$T/pr-creates.txt"; : > "$T/review-calls.txt"
            : > "$T/prlist.out"; : > "$T/prhead.out"; echo OPEN > "$T/issue-state.out"; }

# mkbuild <dir-name> — RESULT body on stdin, aged past the 90-minute floor.
mkbuild() {
  local D="$H/builds/$1"
  mkdir -p "$D"
  cat > "$D/RESULT"
  printf '# %s — the ticket title from the plan\n\n## Tasks\n' "$1" > "$D/plan.md"
  touch -t "$(ago 200)" "$D/RESULT"
  echo "$D"
}
run() { bash "$H/bin/review-rescue.sh" >>"$T/run.log" 2>&1; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

TAMPER="REVIEW_BLOCKED test-tamper: TAMPER_COUNT: 1 (deleted_files=0 deleted_cases=1 added_skips=0) — no TEST-CHANGE justification; see /root/harness/builds/x/test-tamper.txt"

# ══ 1. a ledger-staged dir keeps every provenance line ══════════════════════
# The exact shape bin/lib/rt/staging.sh's ledger loop writes, rescued.
reset_h
D=$(mkbuild project-5-TK-551-remote20260917220820 <<EOF
$TAMPER
TICKET_ID: 551
SOURCE: remote (ledger, built on pool-x)
JOB_ID: build-project-5-TK-551-1
BUILT_AS: project-5-TK-551-2609172200
EOF
)
run
eq "1: line 1 becomes the rescued PR" "$(head -1 "$D/RESULT")" "PR_CREATED $PRURL"
eq "1: exactly one TIER line"    "$(cnt '^TIER: ' "$D/RESULT")" "1"
eq "1: exactly one RESCUED line" "$(cnt '^RESCUED: ' "$D/RESULT")" "1"
for L in 'TICKET_ID: 551' 'SOURCE: remote (ledger, built on pool-x)' \
         'JOB_ID: build-project-5-TK-551-1' 'BUILT_AS: project-5-TK-551-2609172200'; do
  grep -qxF "$L" "$D/RESULT" && ok \
    || bad "1: the rescue dropped '$L' — the staging dedup reads that line ($(cat "$D/RESULT"))"
done
[ -f "$D/.review-rescued" ] && ok || bad "1: the rescued build must still be marked done"
grep -q "REVIEW_BLOCKED" "$D/RESULT" && bad "1: the superseded first line must not survive" || ok

# ══ 2. the relay-staged (pool) shape, with a TIER line of its own ═══════════
# The old TIER: 2 is the one line the header genuinely replaces: two TIER lines
# in one RESULT is a record the merge lanes cannot read.
reset_h
D=$(mkbuild pool-project-5-TK-551-202609172208 <<EOF
$TAMPER
TICKET_ID: 551
SOURCE: remote (fly)
BUILD_DIR: pool-project-5-TK-551-202609172208
WARM: reused machine pool-TK-3
ARTIFACT: https://artifacts.invalid/TK-551.tgz
TIER: 2
EOF
)
run
eq "2: exactly one TIER line survives" "$(cnt '^TIER: ' "$D/RESULT")" "1"
eq "2: and it is the rescue's own"     "$(grep '^TIER: ' "$D/RESULT")" "TIER: 1"
for L in 'BUILD_DIR: pool-project-5-TK-551-202609172208' 'ARTIFACT: https://artifacts.invalid/TK-551.tgz' \
         'WARM: reused machine pool-TK-3' 'SOURCE: remote (fly)'; do
  grep -qxF "$L" "$D/RESULT" && ok || bad "2: the rescue dropped '$L' ($(cat "$D/RESULT"))"
done

# ══ 3. a second rescue does not stack RESCUED lines ═════════════════════════
reset_h
D=$(mkbuild project-5-TK-551-remote20260917220821 <<EOF
$TAMPER
RESCUED: review re-run 2026-09-17T22:10:00Z after died-mid-review orphan
BUILT_AS: project-5-TK-551-2609172200
EOF
)
run
eq "3: exactly one RESCUED line after a second rescue" "$(cnt '^RESCUED: ' "$D/RESULT")" "1"
grep -qxF 'BUILT_AS: project-5-TK-551-2609172200' "$D/RESULT" && ok \
  || bad "3: provenance must survive a second rescue too ($(cat "$D/RESULT"))"

# ══ 4. a build dir with NOTHING but a first line still rescues ══════════════
# The degraded case: nothing to keep, so the file is exactly what it was before
# this change — no blank lines, no stray keys.
reset_h
D=$(mkbuild project-5-TK-551-remote20260917220822 <<EOF
$TAMPER
EOF
)
run
eq "4: a one-line RESULT rescues to three lines" "$(wc -l < "$D/RESULT" | tr -d ' ')" "3"
eq "4: line 1 is the PR"  "$(head -1 "$D/RESULT")" "PR_CREATED $PRURL"
eq "4: no empty line is written" "$(grep -c '^$' "$D/RESULT" || true)" "0"

echo "review-rescue.bh-1301: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
