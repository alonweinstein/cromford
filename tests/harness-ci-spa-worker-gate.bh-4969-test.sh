#!/bin/bash
# tests/harness-ci-spa-worker-gate.bh-4969-test.sh — the workflow half of
# BH-4969: the plan job can read the members' labels and publishes spa/worker,
# the shards take its escalation, and the console-ui and worker-jobs jobs run
# only their "not affected by this batch" step when it says 0 while still
# concluding success under the names .mergify.yml requires.
#
#   W1  plan: pull-requests: read, CI_PR_BODY/CI_REPO/GH_TOKEN in env, spa and
#       worker outputs
#   W2  tests-shard's re-plan takes CI_PLAN_ESCALATION from the plan, no body
#   W3  both jobs keep the job-level corpus gate
#   W4  each job's first step is the skip step, on == '0'
#   W5  every other step runs on != '0' (and there are real steps to gate)
#   W6  .mergify.yml still matches the mergify template (the required check
#       names did not move). The old "untouched against the merge base" half
#       was scoped to BH-4969's own PR and blocked every later Mergify change
#       (#5527, batch size); it is removed, the template match is the invariant.
# Parsed YAML, not a grep (the cost-shape idiom).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${SPA_WORKER_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "harness-ci-spa-worker-gate: PyYAML missing — skipping on this dev machine"; exit 0
fi

python3 - "$WF" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1])).get("jobs") or {}
P = F = 0
def ok():
    global P; P += 1
def bad(m):
    global F; F += 1; print("FAIL: " + m)

# ── W1
plan = jobs.get("plan")
if not isinstance(plan, dict):
    bad("W1: no plan job")
else:
    perms = plan.get("permissions") or {}
    ok() if perms.get("pull-requests") == "read" else bad(f"W1: plan permissions need pull-requests: read, got {perms!r}")
    step = next((s for s in plan.get("steps", []) if s.get("id") == "plan"), None)
    env = (step or {}).get("env") or {}
    for k, v in (("CI_PR_BODY", "${{ github.event.pull_request.body }}"), ("CI_REPO", "${{ github.repository }}"),
                 ("GH_TOKEN", "${{ github.token }}")):
        ok() if env.get(k) == v else bad(f"W1: the plan step's {k} must be {v!r}, got {env.get(k)!r}")
    ok() if "pull_request.body" not in str((step or {}).get("run", "")) else bad("W1: the body must never be interpolated into run:")
    outs = plan.get("outputs") or {}
    for k in ("spa", "worker"):
        ok() if outs.get(k) == "${{ steps.plan.outputs.%s }}" % k else bad(f"W1: plan must export {k}, got {outs.get(k)!r}")

# ── W2
shard = jobs.get("tests-shard") or {}
rp = [s for s in shard.get("steps", []) if "bin/ci-plan.sh" in str(s.get("run", ""))]
if len(rp) != 1:
    bad(f"W2: tests-shard must have exactly one re-plan step, found {len(rp)}")
else:
    env = rp[0].get("env") or {}
    ok() if env.get("CI_PLAN_ESCALATION") == "${{ needs.plan.outputs.escalation }}" else bad(f"W2: CI_PLAN_ESCALATION is {env.get('CI_PLAN_ESCALATION')!r}")
    ok() if "CI_PR_BODY" not in env and "GH_TOKEN" not in env else bad("W2: the shard re-plan must not get CI_PR_BODY or GH_TOKEN")
    ok() if "--expect-n" in str(rp[0].get("run", "")) else bad("W2: the shard re-plan lost --expect-n")

# ── W3-W5
for j, k, least in (("console-ui", "spa", 5), ("worker-jobs", "worker", 6)):
    job = jobs.get(j)
    if not isinstance(job, dict):
        bad(f"W3: no {j} job"); continue
    ok() if str(job.get("if", "")).strip() == "needs.plan.outputs.corpus == '1'" else bad(f"W3: {j} job if: is {job.get('if')!r}")
    ok() if "plan" in (job.get("needs") or []) else bad(f"W3: {j} must need plan")
    steps = job.get("steps") or []
    if not steps:
        bad(f"W4: {j} has no steps"); continue
    first = steps[0]
    ok() if str(first.get("if", "")).strip() == f"needs.plan.outputs.{k} == '0'" else bad(f"W4: {j}'s first step if: is {first.get('if')!r}")
    ok() if str(first.get("run", "")).strip() == 'echo "skipped: not affected by this batch"' else bad(f"W4: {j}'s first step run: is {first.get('run')!r}")
    ok() if first.get("name") == "not affected by this batch" else bad(f"W4: {j}'s first step name is {first.get('name')!r}")
    ok() if "uses" not in first else bad(f"W4: {j}'s skip step must only echo")
    rest = steps[1:]
    ok() if len(rest) >= least else bad(f"W5: {j} must keep at least {least} real steps, has {len(rest)}")
    for i, s in enumerate(rest, 1):
        cond = str(s.get("if", ""))
        ok() if f"needs.plan.outputs.{k} != '0'" in cond else bad(f"W5: {j} step {i} ({s.get('name') or s.get('uses')}) is not gated on {k} != '0': {cond!r}")

print(f"harness-ci-spa-worker-gate (yaml): {P} passed, {F} failed")
sys.exit(1 if F else 0)
PY
RC_Y=$?

# ── W6. The required check names did not move: .mergify.yml matches the template.
PASS=0; FAIL=0
(cd "$DIR" && bin/mergify-template.sh --check) >/dev/null 2>&1 && PASS=$((PASS+1)) \
  || { FAIL=$((FAIL+1)); echo "FAIL: W6: bin/mergify-template.sh --check is red"; }
echo "harness-ci-spa-worker-gate (mergify): $PASS passed, $FAIL failed"
[ "$RC_Y" = 0 ] && [ "$FAIL" = 0 ] || exit 1
