#!/bin/bash
# tests/ci-durations-workflow.bh-5653-test.sh — the CI wiring that feeds the jobs
# worker's ci_suite_durations (BH-5653), read from the parsed YAML of
# .github/workflows/harness-ci.yml, values not prose.
#
#   WF1 the plan job's fetch step (bin/ci-durations.sh fetch) gets JOBS_URL
#       from vars and CI_DURATIONS_TOKEN only on a trusted run: a push, a
#       dispatch, or a Mergify batch draft (head ref mergify/merge-queue/)
#   WF2 the lint job's fetch (every ordinary PR) gets neither
#   WF3 job ci-timings: needs plan and tests-shard; runs only on a Mergify
#       batch whose shards all succeeded; continue-on-error; at most 5 minutes;
#       downloads suite-timings-*; runs bin/ci-durations.sh post --run-id
#       ${{ github.run_id }} over them with the token
#   WF4 secrets.CI_DURATIONS_TOKEN appears in those two places, plus the plan
#       job's test-tier fetch (BH-5653 C1, the same guard), and nowhere else
#   WF5 .mergify.yml names no check after ci-timings (it can never hold a batch)
#   WF6 no workflow step reads secrets.HARNESS_SECRET
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/harness-ci.yml"
MERGIFY="$DIR/.mergify.yml"
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: python3 with PyYAML missing"; exit 0; }

python3 - "$WF" "$MERGIFY" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
mergify_text = open(sys.argv[2]).read()
jobs = wf.get("jobs") or {}
P = F = 0
def ok(m):
    global P; P += 1; print("  ok   " + m)
def bad(m):
    global F; F += 1; print("  FAIL " + m)
def check(c, m): ok(m) if c else bad(m)

TRUSTED = "github.event_name != 'pull_request' || startsWith(github.head_ref, 'mergify/merge-queue/')"
BATCH = "github.event_name == 'pull_request' && startsWith(github.head_ref, 'mergify/merge-queue/')"

def steps(job): return (jobs.get(job) or {}).get("steps") or []
def step_running(job, needle):
    return [s for s in steps(job) if needle in str(s.get("run", ""))]

print("WF1: the plan job's fetch")
st = step_running("plan", "bin/ci-durations.sh fetch")
check(len(st) == 1, "WF1 one fetch step in plan")
env = (st[0].get("env") or {}) if st else {}
check(env.get("JOBS_URL") == "${{ vars.JOBS_URL }}", f"WF1 JOBS_URL from vars: {env.get('JOBS_URL')!r}")
tok = str(env.get("CI_DURATIONS_TOKEN", ""))
check(tok == "${{ (" + TRUSTED + ") && secrets.CI_DURATIONS_TOKEN || '' }}", f"WF1 the token only on a trusted run: {tok!r}")
check(env.get("CI_DURATIONS_CACHE") == "${{ runner.temp }}/ci-durations-cache/api.tsv", f"WF1 the cache lives in runner.temp: {env.get('CI_DURATIONS_CACHE')!r}")

print("WF2: the lint job's fetch")
st = step_running("lint", "bin/ci-durations.sh fetch")
check(len(st) == 1, "WF2 one fetch step in lint")
env = (st[0].get("env") or {}) if st else {}
check("CI_DURATIONS_TOKEN" not in env and "JOBS_URL" not in env, f"WF2 an ordinary PR gets no worker credential: {sorted(env)}")

print("WF3: the ci-timings job")
j = jobs.get("ci-timings") or {}
check(bool(j), "WF3 job ci-timings exists")
needs = j.get("needs") or []
check(set(needs) == {"plan", "tests-shard"}, f"WF3 needs plan and tests-shard: {needs!r}")
cond = str(j.get("if", ""))
check(cond == BATCH + " && needs.tests-shard.result == 'success'", f"WF3 runs only on a green Mergify batch: {cond!r}")
check(j.get("continue-on-error") is True, "WF3 continue-on-error: true")
check(isinstance(j.get("timeout-minutes"), int) and j["timeout-minutes"] <= 5, f"WF3 timeout <= 5: {j.get('timeout-minutes')!r}")
check(str(j.get("runs-on", "")).startswith("${{ fromJSON(vars.CI_RUNNER"), "WF3 runs-on reads vars.CI_RUNNER")
dl = [s for s in steps("ci-timings") if str(s.get("uses", "")).startswith("actions/download-artifact@")]
check(len(dl) == 1 and (dl[0].get("with") or {}).get("pattern") == "suite-timings-*", "WF3 downloads suite-timings-*")
path = (dl[0].get("with") or {}).get("path") if dl else None
post = step_running("ci-timings", "bin/ci-durations.sh post")
check(len(post) == 1, "WF3 one post step")
run = str(post[0].get("run", "")) if post else ""
check('--run-id "${{ github.run_id }}"' in run and '--timings-dir "$RUNNER_TEMP/timings"' in run and path == "${{ runner.temp }}/timings",
      f"WF3 post names this run and the downloaded timings: {run!r} {path!r}")
penv = (post[0].get("env") or {}) if post else {}
check(penv.get("JOBS_URL") == "${{ vars.JOBS_URL }}" and penv.get("CI_DURATIONS_TOKEN") == "${{ secrets.CI_DURATIONS_TOKEN }}",
      f"WF3 post env: {sorted(penv)}")

print("WF4: where the token goes")
hits = []
for name, job in jobs.items():
    if "CI_DURATIONS_TOKEN" in yaml.safe_dump({k: v for k, v in job.items() if k != "steps"}):
        hits.append((name, "<job>"))
    for s in job.get("steps") or []:
        if "secrets.CI_DURATIONS_TOKEN" in yaml.safe_dump(s):
            hits.append((name, s.get("name") or s.get("run", "")[:40]))
# TEST-CHANGE (BH-5653 C1): the plan job gains a second reader, the test-tier
# fetch (bin/ci-test-tiers.sh fetch, read-only); tests/ci-test-tiers-workflow.bh-5653-test.sh
# pins its guard. The list stays exact: one more reader anywhere is still red.
check(sorted((h[0], h[1]) for h in hits) == [("ci-timings", "post them to the jobs worker"),
      ("plan", "the shard weights (ci-durations)"), ("plan", "the test tiers (ci-test-tiers)")],
      f"WF4 the token is read by the plan job's two fetches and ci-timings only: {hits!r}")

print("WF5: ci-timings is not a required check")
name = j.get("name", "ci-timings")
check(name not in mergify_text and "ci-timings" not in mergify_text, f"WF5 .mergify.yml does not name {name!r}")

print("WF6: no step reads HARNESS_SECRET")
check("secrets.HARNESS_SECRET" not in open(sys.argv[1]).read(), "WF6 no secrets.HARNESS_SECRET in the workflow")

print(f"PASS={P} FAIL={F}")
sys.exit(1 if F else 0)
PY
