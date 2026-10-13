#!/bin/bash
# tests/rule-miner-pr-step-test.sh — the miner's PR step, exercised.
#
# THE INCIDENT. 2026-08-26: bin/rule-miner.sh gathered 58 incidents, drafted
# rule D33, and logged exactly "PR creation FAILED". The rules PR was never
# opened. The cause was findable only from the artifacts left on the hub — the
# body it had assembled was 77,148 characters and GitHub refuses a pull request
# body over 65,536 with a 422 — because every step in that block was joined by
# `&&` with its stderr sent to /dev/null. Nothing said which step failed or what
# git or gh had actually printed.
#
# So this test asserts the two halves of the fix, by RUNNING the real blocks
# (extracted verbatim between their markers) against stubs:
#   1. the body is assembled under GitHub's limit, with what did not fit named
#      and counted rather than silently dropped;
#   2. every step names itself, keeps its stderr, and fails into ONE loud
#      ALERTS.log line — and the happy path still opens the PR.
#
# Self-contained: no network, no gh auth, no $HARNESS.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
M="$DIR/bin/rule-miner.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> pr body/{f=1;next} /^# <<< pr body/{exit} f' "$M" > "$T/body.sh"
awk '/^# >>> pr steps/{f=1;next} /^# <<< pr steps/{exit} f' "$M" > "$T/steps.sh"
[ -s "$T/body.sh" ]  && ok || bad "could not extract the pr-body block — markers missing?"
[ -s "$T/steps.sh" ] && ok || bad "could not extract the pr-steps block — markers missing?"
# pr_fail is defined between the two blocks; the steps block calls it.
sed -n '/^pr_fail() {/,/^}/p' "$M" > "$T/prfail.sh"
[ -s "$T/prfail.sh" ] && ok || bad "could not extract pr_fail()"

# ── the 2026-08-26 shape, reproduced: 58 bundles of ~1.8KB ─────────────────
mk_bundles() { # mk_bundles <count>
  MINDIR="$T/mindir"; scratch_rm "$MINDIR"; mkdir -p "$MINDIR"
  INV="$MINDIR/inventory.tsv"; : > "$INV"
  local i
  for i in $(seq 1 "$1"); do
    head -c 2400 /dev/zero | tr '\0' 'x' > "$MINDIR/$i-findings.md"
    printf '%s\tfindings:fam%s\t%s\treview-finding family fam%s recurred 5x in 30d\n' \
      "$i" "$i" "$MINDIR/$i-findings.md" "$i" >> "$INV"
  done
  DRAFT="$MINDIR/draft.md"
  { echo "## Mined 2026-08-26 (rule-miner)"
    echo "- **D33 Serialize on shared resources, not just shared data.** TK-66 and TK-67."
  } > "$DRAFT"
  BODY="$MINDIR/pr-body.md"
}
build_body() {
  ( set -uo pipefail
    MINDIR="$MINDIR" INV="$INV" DRAFT="$DRAFT" BODY="$BODY" \
    N="$1" NRULES=1 DATE=2026-08-26 PROMOTE_MIN=3 NCHECKS="${2:-0}" CHECK_URLS="${3:-}" \
    BODY_MAX="${RULE_MINER_BODY_MAX:-60000}" OMITTED=0 \
    bash -c '. "$0"; echo "OMITTED=$OMITTED"' "$T/body.sh" )
}

mk_bundles 58
OUT=$(build_body 58)
SIZE=$(wc -c < "$BODY")
[ "$SIZE" -le 65536 ] \
  && ok || bad "the 58-incident body is $SIZE bytes — GitHub refuses anything over 65536 (this is the 2026-08-26 bug)"
grep -qE 'OMITTED=[1-9]' <<<"$OUT" \
  && ok || bad "58 bundles at 2.4KB cannot all fit; some must be recorded as omitted (got: $OUT)"
grep -q 'D33 Serialize on shared resources' "$BODY" \
  && ok || bad "the drafted RULES must always ride in full — they are the point of the PR"
grep -q "incident bundle(s) are omitted here" "$BODY" \
  && ok || bad "omitted evidence must be NAMED in the body, not silently dropped"
grep -q "$MINDIR" "$BODY" \
  && ok || bad "the body must point at the hub path holding the full untruncated bundles"
grep -q 'Generated with \[Claude Code\]' "$BODY" \
  && ok || bad "the attribution footer must survive the truncation"

# A small week is unchanged: every bundle rides, nothing is marked omitted.
mk_bundles 3
OUT=$(build_body 3)
grep -q 'OMITTED=0' <<<"$OUT" \
  && ok || bad "a 3-incident week must omit nothing (got: $OUT)"
[ "$(grep -c '^### \[' "$BODY")" = 3 ] \
  && ok || bad "a 3-incident week must carry all 3 evidence sections"
grep -q 'omitted here' "$BODY" \
  && bad "a body that dropped nothing must not claim it did" || ok
# The mechanizable lane's PR links ride in the body when there are any.
OUT=$(build_body 3 2 "https://x/1
https://x/2")
grep -q 'guardrail check PR(s)' "$BODY" \
  && ok || bad "check-lane PR links must appear in the body when checks were promoted"

# ── the steps, against stubbed git and gh ──────────────────────────────────
mkdir -p "$T/stub"
run_steps() { # run_steps <git-mode> <gh-mode> -> prints stdout; ALERTS/LOG in $T
  local gitmode="$1" ghmode="$2"
  : > "$T/ALERTS.log"; : > "$T/miner.log"; : > "$T/pr-step.log"
  cat > "$T/stub/git" <<EOF
#!/bin/bash
# The real calls carry -c flags before the subcommand (git -c user.name=... commit),
# so the stub finds the verb by scanning argv, never by \$1.
MODE="$gitmode"; VERB=""
for a in "\$@"; do
  case "\$a" in checkout|commit|push|add) VERB="\$a"; break ;; esac
done
echo "\$VERB \$*" >> "$T/git-calls"
case "\$MODE:\$VERB" in
  fail-checkout:checkout) echo "fatal: a branch named 'rules/mined-2026-08-26' already exists" >&2; exit 128 ;;
  fail-commit:commit)     echo "nothing to commit, working tree clean" >&2; exit 1 ;;
  fail-push:push)         echo "remote: Permission to example-org/cromford.git denied" >&2; exit 128 ;;
  reject-push:push)
     if [ -f "$T/pushed-once" ]; then exit 0; fi
     : > "$T/pushed-once"; echo "! [rejected] non-fast-forward" >&2; exit 1 ;;
esac
exit 0
EOF
  cat > "$T/stub/gh" <<EOF
#!/bin/bash
MODE="$ghmode"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  case "\$MODE" in
    already-open|create-fails-pr-exists) echo "https://github.com/example-org/cromford/pull/900" ;;
    *) : ;;
  esac
  exit 0
fi
if [ "\$1" = "pr" ] && [ "\$2" = "create" ]; then
  case "\$MODE" in
    body-too-long) echo "pull request create failed: HTTP 422: Body is too long (maximum is 65536 characters)" >&2; exit 1 ;;
    create-fails-pr-exists) echo "a pull request for branch already exists" >&2; exit 1 ;;
    *) echo "https://github.com/example-org/cromford/pull/901" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$T/stub/git" "$T/stub/gh"; rm -f "$T/pushed-once" "$T/git-calls"
  ( PATH="$T/stub:$PATH" \
    bash -c '
      set -uo pipefail
      STAMP() { echo "2026-08-31 05:30:00Z"; }
      . "$1"          # pr_fail
      . "$2"          # the steps
      echo "PR_URL=$PR_URL"
    ' _ "$T/prfail.sh" "$T/steps.sh" ) 2>&1
}
export WT="$T/wt"; mkdir -p "$WT/prompts"
printf '# build discipline\n- **D32 Something.** prior rule.\n' > "$WT/prompts/build-discipline.md"
export HARNESS_REPO="example-org/cromford" RBRANCH="rules/mined-2026-08-26" \
       PRLOG="$T/pr-step.log" LOG="$T/miner.log" ALERTS="$T/ALERTS.log" \
       DRAFT="$DRAFT" BODY="$BODY" MINDIR="$MINDIR" N=58 NRULES=1 \
       DATE=2026-08-26 OMITTED=0

# happy path — the Monday 2026-08-31 run must open the PR
OUT=$(run_steps ok ok)
grep -q 'PR_URL=https://github.com/example-org/cromford/pull/901' <<<"$OUT" \
  && ok || bad "the happy path must open a PR (got: $OUT)"
[ -s "$T/ALERTS.log" ] && bad "a successful run must write no ALERTS line" || ok

# every failure step: names itself in ONE loud ALERTS line, with the tool's stderr
check_fail() { # check_fail <git-mode> <gh-mode> <step-name> <stderr-fragment>
  local out; out=$(run_steps "$1" "$2")
  grep -q "PR STEP FAILED at '$3" "$T/ALERTS.log" \
    && ok || bad "$3: no ALERTS line naming the step (alerts: $(cat "$T/ALERTS.log"))"
  grep -q "$4" "$T/ALERTS.log" \
    && ok || bad "$3: the ALERTS line must carry what git/gh actually said ('$4')"
  grep -q "PR creation FAILED at step '$3" "$T/miner.log" \
    && ok || bad "$3: the run log must name the failing step too"
  [ "$(grep -c 'PR STEP FAILED' "$T/ALERTS.log")" = 1 ] \
    && ok || bad "$3: exactly ONE alert per failure, not a burst"
  grep -q "steplog=$PRLOG" "$T/ALERTS.log" \
    && ok || bad "$3: the alert must point at the captured stderr log"
}
check_fail fail-checkout ok "git checkout" "already exists"
check_fail fail-commit   ok "git commit"   "nothing to commit"
check_fail fail-push     ok "git push"     "Permission to"
# THE 2026-08-26 FAILURE ITSELF: a 422 on an oversized body is now diagnosable
# from the alert alone, and the alert hands over the exact recovery command.
check_fail ok body-too-long "gh pr create" "Body is too long"
grep -q 'gh pr create -R example-org/cromford -B main -H rules/mined-2026-08-26' "$T/ALERTS.log" \
  && ok || bad "the gh-create alert must hand over the by-hand recovery command"

# idempotent re-run: the alert says "re-run", so a re-run must adopt, not duplicate
OUT=$(run_steps ok already-open)
grep -q 'PR_URL=https://github.com/example-org/cromford/pull/900' <<<"$OUT" \
  && ok || bad "a re-run with the PR already open must adopt it (got: $OUT)"
grep -q 'was already open, adopted' "$T/miner.log" \
  && ok || bad "adopting an already-open PR must be logged as such"
[ -s "$T/ALERTS.log" ] && bad "adopting an open PR is success, not an alert" || ok

# gh pr create can fail BECAUSE the PR exists — success wearing an error's clothes
OUT=$(run_steps ok create-fails-pr-exists)
grep -q 'PR_URL=https://github.com/example-org/cromford/pull/900' <<<"$OUT" \
  && ok || bad "a create that fails on an existing PR must adopt that PR (got: $OUT)"
[ -s "$T/ALERTS.log" ] && bad "adopting after a create race is not a failure" || ok

# a rejected push retries once with --force-with-lease, on the miner-owned branch
OUT=$(run_steps reject-push ok)
grep -q 'PR_URL=https://github.com/example-org/cromford/pull/901' <<<"$OUT" \
  && ok || bad "a non-fast-forward push must retry with --force-with-lease (got: $OUT)"
grep -q 'force-with-lease' "$T/miner.log" \
  && ok || bad "the force-push fallback must be logged, never silent"
grep -q 'push .*--force-with-lease' "$T/git-calls" \
  && ok || bad "the retry must actually pass --force-with-lease to git"

# ── the source itself: no step may discard its stderr again ────────────────
STEPS=$(cat "$T/steps.sh")
grep -q '2>/dev/null' <<<"$STEPS" \
  && bad "a PR step still sends stderr to /dev/null — that is the 2026-08-26 bug" || ok
grep -q 'iconv' "$M" \
  && ok || bad "truncated bundles must be scrubbed of invalid UTF-8 before entering the body"
grep -q 'RULE_MINER_BODY_MAX' "$M" \
  && ok || bad "the body budget must be a named, overridable knob"

echo "rule-miner-pr-step-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
