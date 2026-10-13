#!/bin/bash
# tests/guardrail-promote-test.sh — the mechanizable lane of the rule miner.
#
# This is the lane that opens PRs on CLIENT repos, so its refusals matter more
# than its successes: a malformed draft, a check with no escape hatch, or a
# target that is the harness itself must never reach `gh`. A fake gh on PATH
# records every invocation and the assertions read that record — the same shape
# harness-ci.yml uses to prove merge-sweep stays silent on a BLOCKED build.
#
# No network, no secrets.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T"
mkdir -p "$T/logs" "$T/bin"
# Every path below is absolute, so this only matters when something goes wrong —
# and when something goes wrong in a test that shells out to git and gh, "wrong"
# means files appearing in the repo. An early version of the fake gh below read
# the clone slug where the clone DIR should be and left a example-org/ tree in the
# working copy. Litter in the repo is a finding, so: never run from the repo.
cd "$T" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── fake gh: clones by git-init'ing an empty repo, records every call ────────
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
PREV=""
case "${1:-}" in
  repo)
    # gh repo clone <slug> <dir> -- -q  — a real local repo with a real origin,
    # so the script's push is genuinely exercised rather than stubbed away.
    D="${4:-}"; mkdir -p "$D"   # gh repo clone <slug> <dir>: $3 slug, $4 dir
    # The bare origin lives somewhere the test can inspect afterwards: what got
    # PUSHED is the only honest place to look for an exfiltrated secret.
    mkdir -p "$ORIGINS"; B="$ORIGINS/$(basename "$D").git"; git init -q --bare "$B"
    git -C "$D" init -q 2>/dev/null
    git -C "$D" config user.email t@t; git -C "$D" config user.name t
    echo "# target" > "$D/README.md"
    git -C "$D" add -A && git -C "$D" commit -qm init
    git -C "$D" branch -M main
    git -C "$D" remote add origin "$B"
    git -C "$D" push -q origin main
    ;;
  pr) # keep every PR body the script submits, so assertions can read them
      for a in "$@"; do [ "$PREV" = "--body-file" ] && cat "$a" >> "$BODIES"; PREV="$a"; done
      echo "https://github.com/fake/pr/1" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export GH_LOG="$T/gh.log" ORIGINS="$T/origins" BODIES="$T/pr-bodies.txt"
: > "$BODIES"
export PATH="$T/fakebin:$PATH"
RUN="$DIR/bin/guardrail-promote.sh"

mkcheck() { # mkcheck <dir> <slug> <target> <ci-step-body>
  local d="$1/$2"; mkdir -p "$d"
  echo "$3" > "$d/TARGET"
  cat > "$d/rule.yml" <<'YML'
rules:
  - id: drafted-check
    languages: [typescript]
    severity: ERROR
    message: drafted by the rule miner from a recurring finding family
    pattern-regex: nothing-in-particular
YML
  echo "# drafted check" > "$d/README.md"
  printf '%s\n' "$4" > "$d/ci-step.yml"
}
# The canonical CI step. NOTE what it deliberately does NOT do: wire
# GUARDRAIL_JUSTIFICATION to the raw ${{ github.event.pull_request.body }}.
# Drafts copy this sample verbatim, and that wiring made any PR body a valid
# justification — 25 spaces included. The hatch reads a dedicated
# `Guardrail-Justification:` marker line instead.
GOOD_STEP='- name: guardrail drafted-check
  if: "!contains(github.event.pull_request.labels.*.name, '"'"'skip-guardrail'"'"')"
  env:
    GUARDRAIL_JUSTIFICATION: ${{ vars.GUARDRAIL_JUSTIFICATION }}
  run: semgrep scan --config .guardrails/drafted-check/rule.yml --error'

# ── 1. happy path: one well-formed check -> exactly one PR on the TARGET ────
D="$T/c1"; mkcheck "$D" drafted-check example-org/project-2 "$GOOD_STEP"
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1 || bad "rc nonzero on happy path"
grep -q 'gh pr create' "$GH_LOG" && ok || bad "no PR opened (log: $(cat "$GH_LOG"))"
grep -q 'gh pr create.*-R example-org/project-2' "$GH_LOG" \
  && ok || bad "PR not targeted at the TARGET repo"
grep -q 'gh pr merge' "$GH_LOG" && bad "the miner MERGED a PR" || ok

# ── 2. never the harness repo, no matter what the draft says ────────────────
D="$T/c2"; mkcheck "$D" sneaky example-org/cromford "$GOOD_STEP"
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1 || bad "rc nonzero on harness-repo target"
grep -q 'gh pr create' "$GH_LOG" && bad "opened a check PR on the harness repo" || ok
grep -q 'harness repo' "$T/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "harness-repo refusal not alerted"

# ── 3. a check with no escape hatch is refused (malformed-draft guard) ──────
D="$T/c3"; mkcheck "$D" nohatch example-org/project-3 '- name: guardrail
  run: semgrep scan --config .guardrails/nohatch/rule.yml --error'
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1 || bad "rc nonzero on hatchless check"
grep -q 'gh pr create' "$GH_LOG" && bad "opened a PR for a check with no escape hatch" || ok

# ── 4. label without a justification is not an escape hatch either ──────────
D="$T/c4"; mkcheck "$D" labelonly example-org/project-3 '- name: guardrail
  if: "!contains(github.event.pull_request.labels.*.name, '"'"'skip-guardrail'"'"')"
  run: semgrep scan --config .guardrails/labelonly/rule.yml --error'
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1
grep -q 'gh pr create' "$GH_LOG" \
  && bad "opened a PR for a hatch with no mandatory justification" || ok

# ── 5. no TARGET file -> refused, and said so ──────────────────────────────
D="$T/c5/notarget"; mkdir -p "$D"; echo "rules: []" > "$D/rule.yml"
: > "$GH_LOG"
"$RUN" "$T/c5" >/dev/null 2>&1 || bad "rc nonzero on missing TARGET"
grep -q 'gh pr create' "$GH_LOG" && bad "opened a PR with no TARGET" || ok

# ── 6. no check file at all -> refused ─────────────────────────────────────
D="$T/c6/empty"; mkdir -p "$D"; echo "example-org/project-3" > "$D/TARGET"
printf '%s\n' "$GOOD_STEP" > "$D/ci-step.yml"
: > "$GH_LOG"
"$RUN" "$T/c6" >/dev/null 2>&1
grep -q 'gh pr create' "$GH_LOG" && bad "opened a PR with no check file" || ok

# ── 7. fail-open: missing dir / no args -> rc 0, no gh, no crash ───────────
: > "$GH_LOG"
"$RUN" "$T/does-not-exist" >/dev/null 2>&1 || bad "rc nonzero on missing dir"
"$RUN" >/dev/null 2>&1 || bad "rc nonzero with no args"
[ ! -s "$GH_LOG" ] && ok || bad "touched gh with nothing to promote"

# ── 8. one good + one malformed: the good one still ships ─────────────────
D="$T/c8"; mkcheck "$D" fine example-org/project-3 "$GOOD_STEP"
mkdir -p "$D/broken"; echo "example-org/project-3" > "$D/broken/TARGET"
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1
[ "$(grep -c 'gh pr create' "$GH_LOG")" = 1 ] && ok \
  || bad "one malformed sibling should not stop the good check (or should not add one)"

# ── 9. the drafted check lands under .guardrails/<slug>/, not repo root ────
grep -q 'gh pr create' "$GH_LOG" && grep -q 'guardrails/fine' "$GH_LOG" \
  && ok || bad "PR branch/title should name the check slug"

# ══ Round 2: findings from the adversarial review of PR #114 ═══════════════
# Every case below was reproduced live against the first version of this script.

# ── 10. SYMLINK DEREFERENCE = SECRET EXFILTRATION ──────────────────────────
# `cp` follows symlinks. A drafted rule.yml symlinked at a secrets file got the
# TARGET'S CONTENTS committed, pushed, and PR'd to a client repo. The draft is
# LLM-written and lands on disk before any human sees it, so "a draft would not
# do that" is not a control. Every draft file must be a regular, non-symlink
# file before it is read, copied, or piped into a PR body.
SECRET='sk-live-DEADBEEF-do-not-exfiltrate'
mkdir -p "$T/vault"; echo "$SECRET" > "$T/vault/secrets.env"

symlink_case() { # symlink_case <n> <filename-to-symlink>
  local d="$T/sym$1/leak"; mkdir -p "$d"
  echo "example-org/project-3" > "$d/TARGET"
  cat > "$d/rule.yml" <<'YML'
rules:
  - id: x
    languages: [typescript]
    severity: ERROR
    message: m
    pattern-regex: z
YML
  echo "# doc" > "$d/README.md"
  printf 'FAMILY: abc123abc123\n' > "$d/WHY.md"
  printf '%s\n' "$GOOD_STEP" > "$d/ci-step.yml"
  rm -f "$d/$2"; ln -s "$T/vault/secrets.env" "$d/$2"
  : > "$GH_LOG"; : > "$BODIES"; scratch_rm "$ORIGINS"
  "$RUN" "$T/sym$1" >/dev/null 2>&1 || bad "rc nonzero on symlinked $2"
  grep -q 'gh pr create' "$GH_LOG" \
    && bad "symlinked $2 reached gh pr create" || ok
  # The decisive assertions: the secret must not reach the remote NOR a PR body.
  # `git grep` over every pushed object is what "did we exfiltrate it" means.
  LEAK=""
  for o in "$ORIGINS"/*.git; do
    [ -d "$o" ] || continue
    # NOT `| grep -q`: under `set -o pipefail`, grep -q closes the pipe early,
    # git takes SIGPIPE, and the pipeline reports failure ON A MATCH — the
    # exact D6 trap ("never trust a piped exit code") in the test that is
    # supposed to catch a secret leak. Count instead; grep -c drains the input.
    N=$(git -C "$o" log -p --all 2>/dev/null | grep -cF "$SECRET" || true)
    [ "${N:-0}" -gt 0 ] && LEAK="pushed"
  done
  grep -qF "$SECRET" "$BODIES" 2>/dev/null && LEAK="${LEAK:+$LEAK+}pr-body"
  [ -z "$LEAK" ] && ok || bad "symlinked $2: secret exfiltrated via $LEAK"
}
symlink_case 1 rule.yml
symlink_case 2 README.md
symlink_case 3 WHY.md
symlink_case 4 ci-step.yml
symlink_case 5 TARGET

# ── 11. VOLUME CAP: 25 drafts must not become 25 PRs on a client repo ───────
mkdir -p "$T/many"
for i in $(seq 1 25); do mkcheck "$T/many" "chk$i" example-org/project-3 "$GOOD_STEP"; done
: > "$GH_LOG"; : > "$T/logs/ALERTS.log"
"$RUN" "$T/many" >/dev/null 2>&1 || bad "rc nonzero on 25 drafts"
N=$(grep -c 'gh pr create' "$GH_LOG")
[ "$N" = 3 ] && ok || bad "MAX_PROMOTE default 3 not enforced (opened $N PRs)"
grep -q 'MAX_PROMOTE' "$T/logs/ALERTS.log" && ok \
  || bad "hitting the cap must alert, not stop silently"

: > "$GH_LOG"
rm -f "$T/many"/*/.promoted 2>/dev/null
MAX_PROMOTE=1 "$RUN" "$T/many" >/dev/null 2>&1
N=$(grep -c 'gh pr create' "$GH_LOG")
[ "$N" = 1 ] && ok || bad "MAX_PROMOTE=1 not honored (opened $N)"

# ── 12. TARGET ALLOWLIST: only repos the fleet actually owns ────────────────
# "owner/repo" shaped is not the same as "ours". An LLM-drafted TARGET could
# name any repo on GitHub, and the script would clone and push a branch to it.
D="$T/c12"; mkcheck "$D" stranger someone-else/not-ours "$GOOD_STEP"
: > "$GH_LOG"; : > "$T/logs/ALERTS.log"
"$RUN" "$D" >/dev/null 2>&1 || bad "rc nonzero on off-fleet TARGET"
grep -q 'gh repo clone' "$GH_LOG" \
  && bad "cloned a repo that is not in fleet.conf" || ok
grep -q 'not in fleet.conf\|not a fleet repo' "$T/logs/ALERTS.log" && ok \
  || bad "off-fleet TARGET refusal not alerted"

D="$T/c12b"; mkcheck "$D" onfleet example-org/project-3 "$GOOD_STEP"
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1
grep -q 'gh pr create' "$GH_LOG" && ok || bad "a real fleet repo must be allowed"

# ── 13. the raw-PR-body justification wiring is refused ────────────────────
# It is what drafts copy, and it makes any body (25 spaces included) a valid
# justification. Refuse the pattern at the gate, not just in the hatch.
D="$T/c13"; mkcheck "$D" bodywired example-org/project-3 '- name: guardrail
  if: "!contains(github.event.pull_request.labels.*.name, '"'"'skip-guardrail'"'"')"
  env:
    GUARDRAIL_JUSTIFICATION: ${{ github.event.pull_request.body }}
  run: semgrep scan --config .guardrails/bodywired/rule.yml --error'
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1
grep -q 'gh pr create' "$GH_LOG" \
  && bad "accepted a hatch wired to the raw PR body" || ok

# ── 14. promoted families are recorded, so the miner marks only what shipped ─
D="$T/c14"; mkcheck "$D" famrec example-org/project-3 "$GOOD_STEP"
printf 'FAMILY: 6f570a9bb4c6\nCOUNT_30D: 4\n' > "$D/famrec/WHY.md"
: > "$GH_LOG"
"$RUN" "$D" >/dev/null 2>&1
grep -qx 'findings:6f570a9bb4c6' "$D/.promoted-families" 2>/dev/null && ok \
  || bad "promoted family not recorded for the miner's seen-marking"

echo "guardrail-promote-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
