#!/bin/bash
# tests/harness-nightly-workflow-test.sh — .github/workflows/harness-nightly.yml
# carries the shape the nightly tier's promise depends on (2026-09-28).
#
# The nightly and guard tiers (catalog/test-tiers.tsv) left the merge-queue
# batch because this workflow runs them every night and files a red night as a
# ticket. Each claim below is a way that promise breaks while every check stays
# green:
#   W1  it runs on a schedule and on demand, and on NOTHING else (a push or PR
#       trigger would re-test trees the queue already tested)
#   W2  a nightly run is never cancelled by the next one
#   W3  the plan and every shard plan the NIGHTLY tier with the same sizing, and
#       a shard's re-plan must agree (--expect-n)
#   W4  each shard runs the traced gate over exactly the planned list, with the
#       tools required rather than skipped, and keeps its log for the ticket
#   W5  the judge runs even when a shard is red, uses the same fan-in script as
#       the batch for BOTH verdicts, and files the ticket — on main only
#   W6  the tool pins equal harness-ci.yml's (a different gitleaks is a
#       different rule set)
#   W8  the strict ratchet pass runs, and its red turns the night red and
#       reaches the ticket
#   W7  every job reads the runner from vars.CI_RUNNER, like harness-ci.yml
# Run from anywhere: tests/harness-nightly-workflow-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NWF="${NIGHTLY_WORKFLOW:-$DIR/.github/workflows/harness-nightly.yml}"
CIWF="$DIR/.github/workflows/harness-ci.yml"
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "harness-nightly-workflow: PyYAML missing — skipping on this dev machine"; exit 0
fi

python3 - "$NWF" "$CIWF" <<'PY'
import re, sys, yaml
nwf_path, ci_path = sys.argv[1:3]
wf = yaml.safe_load(open(nwf_path))
text = open(nwf_path).read(); ci_text = open(ci_path).read()
jobs = wf.get("jobs") or {}
on = wf.get("on", wf.get(True)) or {}
P = F = 0
def ok():
    global P; P += 1
def bad(m):
    global F; F += 1; print("FAIL: " + m)
def runs(job):
    return "\n".join(str(s.get("run", "")) for s in (jobs.get(job) or {}).get("steps") or [])
def env(job):
    e = {}
    for s in (jobs.get(job) or {}).get("steps") or []:
        e.update(s.get("env") or {})
    return e

# W1
ok() if on.get("schedule") and on["schedule"][0].get("cron") else bad("W1: no schedule — the nightly tier would never run")
ok() if "workflow_dispatch" in on else bad("W1: the nightly run must be dispatchable by hand")
extra = set(on) - {"schedule", "workflow_dispatch"}
ok() if not extra else bad(f"W1: only schedule and workflow_dispatch may trigger it, got {sorted(extra)}")
# W2
c = wf.get("concurrency") or {}
ok() if str(c.get("cancel-in-progress")).lower() == "false" else bad(f"W2: a nightly run must never be cancelled: {c!r}")
# W3
for j in ("plan", "shard"):
    r = runs(j)
    ok() if re.search(r"bin/ci-plan\.sh --tier nightly", r) else bad(f"W3: {j} must plan with bin/ci-plan.sh --tier nightly: {r!r}")
ok() if "--expect-n" in runs("shard") else bad("W3: a shard's re-plan must pass --expect-n")
ok() if str(env("plan").get("CI_SUITES_PER_SHARD")) == str(env("shard").get("CI_SUITES_PER_SHARD")) \
    else bad("W3: plan and shard must size with the same CI_SUITES_PER_SHARD, or --expect-n fails every night")
for k in ("count", "n", "shards", "summary"):
    ok() if k in ((jobs.get("plan") or {}).get("outputs") or {}) else bad(f"W3: the plan must output {k}")
# W4
sh = jobs.get("shard") or {}
ok() if (sh.get("strategy") or {}).get("fail-fast") is False else bad("W4: a red shard must not cancel its siblings")
ok() if "needs.plan.outputs.shards" in str((sh.get("strategy") or {}).get("matrix", {}).get("shard")) else bad("W4: the matrix must be the plan's shards")
r = runs("shard")
for want in ("bin/test-trace-safety.sh --gate", "--verdict", "--shard", "--only-file", "GITLEAKS_REQUIRED=1",
             "CODEGRAPH_REQUIRED=1", "SEMGREP_REQUIRED=1", "shard-$SHARD.log"):
    ok() if want in r else bad(f"W4: the shard run must carry {want!r}")
ok() if "pipefail" in r else bad("W4: the gate is piped into tee, so pipefail must keep its rc")
# W5
v = jobs.get("verdict") or {}
nd = v.get("needs") or []
ok() if {"plan", "shard"} <= set(nd if isinstance(nd, list) else [nd]) else bad(f"W5: the verdict must need plan and shard: {nd!r}")
ok() if "!cancelled()" in str(v.get("if", "")) else bad(f"W5: a red shard must not skip the judge: if: {v.get('if')!r}")
ok() if (v.get("permissions") or {}).get("issues") == "write" else bad("W5: filing a ticket needs issues: write")
r = runs("verdict")
for want in ("bin/ci-verdicts.sh pure", "bin/ci-verdicts.sh trace", "bin/nightly-ticket.sh", "exit \"$RED\""):
    ok() if want in r else bad(f"W5: the verdict step must run {want!r}")
ok() if "refs/heads/main" in str(env("verdict").get("NT_ON_MAIN", "")) else bad("W5: only a red night on main files a ticket")
ok() if "github.token" in str(env("verdict").get("GH_TOKEN", "")) else bad("W5: the ticket is filed with the workflow's own token")
# W6
def pins(t):
    return (sorted(set(re.findall(r"codegraph@([0-9.]+)", t))), sorted(set(re.findall(r"semgrep==([0-9.]+)", t))),
            sorted(set(re.findall(r"^\s*V=([0-9.]+)", t, re.M))), sorted(set(re.findall(r"^\s*SHA=([0-9a-f]{64})", t, re.M))))
np_, cp_ = pins(text), pins(ci_text)
for name, a, b in zip(("codegraph", "semgrep", "gitleaks V", "gitleaks SHA"), np_, cp_):
    ok() if a and a == b else bad(f"W6: the {name} pin must equal harness-ci.yml's: nightly {a} vs ci {b}")
# W7
for j, b in jobs.items():
    ok() if "vars.CI_RUNNER" in str((b or {}).get("runs-on", "")) else bad(f"W7: {j} must read vars.CI_RUNNER")

# W8: the strict ratchet pass runs, and its red reaches the judge and the ticket.
st = jobs.get("strict") or {}
ok() if "bin/nightly-strict-ratchets.sh" in runs("strict") else bad("W8: a strict job must run bin/nightly-strict-ratchets.sh")
ok() if "pipefail" in runs("strict") else bad("W8: the strict pass is piped into tee, so pipefail must keep its rc")
ok() if "strict" in (v.get("needs") or []) else bad("W8: the verdict must need the strict job, or its red is never judged")
ok() if "needs.strict.result" in str(env("verdict").get("STRICT_RESULT", "")) else bad("W8: the verdict must read the strict job's result")
ok() if "STRICT_RESULT" in runs("verdict") and "NT_STRICT_RESULT" in runs("verdict") else bad("W8: a red strict pass must turn the night red and reach the ticket")
ok() if any("nightly-verdict-strict" in str((s.get("with") or {}).get("name", "")) for s in st.get("steps") or []) \
    else bad("W8: the strict summary must ride with the verdicts (artifact nightly-verdict-strict)")
print(f"harness-nightly-workflow: {P} pass, {F} fail")
sys.exit(1 if F else 0)
PY
