#!/bin/bash
# tests/ci-test-tiers-workflow.bh-5653-test.sh — the CI wiring that hands the
# test-tier set (bin/ci-test-tiers.sh fetch, BH-5653 slice C1) to every
# bin/ci-plan.sh call, read from the parsed YAML of both workflows.
#
#   TW1 harness-ci plan job: the fetch step comes BEFORE the ci-plan step, has
#       no `if:`, writes $RUNNER_TEMP/ci-durations/test-tiers.tsv, and gets
#       JOBS_URL from vars and CI_DURATIONS_TOKEN only on a trusted run (the
#       same guard expression as the durations fetch)
#   TW2 every harness-ci step that runs bin/ci-plan.sh sets CI_PLAN_TIER_FILE
#       to that file; the plan job's upload of `ci-durations` carries the
#       directory, and comes after the fetch
#   TW3 tests-shard: the `ci-durations` download and its guard come BEFORE the
#       shard's ci-plan step, and the guard requires test-tiers.tsv
#   TW4 the nightly plan job fetches before its ci-plan step and uploads
#       `nightly-tiers`; the shard downloads it before its ci-plan step, fails
#       without it, and both ci-plan steps set CI_PLAN_TIER_FILE
#   TW5 no workflow runs `bin/ci-test-tiers.sh put` (CI has no write path)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/harness-ci.yml"
NW="$DIR/.github/workflows/harness-nightly.yml"
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: python3 with PyYAML missing"; exit 0; }

python3 - "$WF" "$NW" "$DIR/.github/workflows" <<'PY'
import glob, sys, yaml
ci = yaml.safe_load(open(sys.argv[1])).get("jobs") or {}
nwf = yaml.safe_load(open(sys.argv[2]))
nj = nwf.get("jobs") or {}
P = F = 0
def ok(m):
    global P; P += 1; print("  ok   " + m)
def bad(m):
    global F; F += 1; print("  FAIL " + m)
def check(c, m): ok(m) if c else bad(m)

TRUSTED = "${{ (github.event_name != 'pull_request' || startsWith(github.head_ref, 'mergify/merge-queue/')) && secrets.CI_DURATIONS_TOKEN || '' }}"
CI_FILE = "${{ runner.temp }}/ci-durations/test-tiers.tsv"
N_FILE = "${{ runner.temp }}/tiers/test-tiers.tsv"

def steps(jobs, job): return (jobs.get(job) or {}).get("steps") or []
def idx(jobs, job, pred):
    return [i for i, s in enumerate(steps(jobs, job)) if pred(s)]
def runs(needle): return lambda s: needle in str(s.get("run", ""))
def uses_art(kind, name):
    return lambda s: str(s.get("uses", "")).startswith(f"actions/{kind}-artifact@") and (s.get("with") or {}).get("name") == name
def one(lst, m):
    check(len(lst) == 1, f"{m} (found {len(lst)})")
    return lst[0] if lst else None
def env(jobs, job, i): return (steps(jobs, job)[i].get("env") or {}) if i is not None else {}

print("TW1: the harness-ci plan job fetches the tiers before it plans")
f = one(idx(ci, "plan", runs("bin/ci-test-tiers.sh fetch")), "TW1 one tier fetch step in plan")
p = one(idx(ci, "plan", runs("bin/ci-plan.sh")), "TW1 one ci-plan step in plan")
check(f is not None and p is not None and f < p, f"TW1 the fetch (step {f}) comes before ci-plan (step {p})")
fs = steps(ci, "plan")[f] if f is not None else {}
check("if" not in fs, f"TW1 the fetch has no if: {fs.get('if')!r}")
check('--out "$RUNNER_TEMP/ci-durations/test-tiers.tsv"' in str(fs.get("run", "")), f"TW1 the fetch writes the artifact dir: {fs.get('run')!r}")
e = env(ci, "plan", f)
check(e.get("JOBS_URL") == "${{ vars.JOBS_URL }}", f"TW1 JOBS_URL from vars: {e.get('JOBS_URL')!r}")
check(e.get("CI_DURATIONS_TOKEN") == TRUSTED, f"TW1 the token only on a trusted run: {e.get('CI_DURATIONS_TOKEN')!r}")
d = idx(ci, "plan", runs("bin/ci-durations.sh fetch"))
check(len(d) == 1 and env(ci, "plan", d[0]).get("CI_DURATIONS_TOKEN") == e.get("CI_DURATIONS_TOKEN"),
      "TW1 the same token guard as the durations fetch")
check(str(e.get("CI_TEST_TIERS_CACHE", "")).startswith("${{ runner.temp }}/"), f"TW1 the cache lives in runner.temp: {e.get('CI_TEST_TIERS_CACHE')!r}")
check("HARNESS_SECRET" not in e, "TW1 the fetch gets no HARNESS_SECRET")

print("TW2: every ci-plan call reads the fetched file")
calls = [(j, i) for j in ci for i in idx(ci, j, runs("bin/ci-plan.sh"))]
check(sorted(j for j, _ in calls) == ["plan", "tests-shard"], f"TW2 ci-plan runs in plan and tests-shard: {calls!r}")
for j, i in calls:
    check(env(ci, j, i).get("CI_PLAN_TIER_FILE") == CI_FILE, f"TW2 {j} sets CI_PLAN_TIER_FILE: {env(ci, j, i).get('CI_PLAN_TIER_FILE')!r}")
u = one(idx(ci, "plan", uses_art("upload", "ci-durations")), "TW2 one ci-durations upload in plan")
us = steps(ci, "plan")[u] if u is not None else {}
check((us.get("with") or {}).get("path") == "${{ runner.temp }}/ci-durations/", f"TW2 the upload carries the directory: {(us.get('with') or {}).get('path')!r}")
check(u is not None and f is not None and u > f, "TW2 the upload comes after the tier fetch")
# A shard only runs when the plan says corpus 1, which is the upload's own condition.
check(str((ci.get("tests-shard") or {}).get("if", "")) == "needs.plan.outputs.corpus == '1'"
      and str(us.get("if", "")) == "steps.plan.outputs.corpus == '1'",
      "TW2 the upload and tests-shard share the corpus condition")

print("TW3: tests-shard has the file before it re-plans")
dl = one(idx(ci, "tests-shard", uses_art("download", "ci-durations")), "TW3 one ci-durations download")
g = one(idx(ci, "tests-shard", runs("no ci-durations from the plan job")), "TW3 one guard step")
sp = one(idx(ci, "tests-shard", runs("bin/ci-plan.sh")), "TW3 one ci-plan step")
check(None not in (dl, g, sp) and dl < g < sp, f"TW3 download ({dl}) < guard ({g}) < ci-plan ({sp})")
gr = str(steps(ci, "tests-shard")[g].get("run", "")) if g is not None else ""
check('"$RUNNER_TEMP/ci-durations/test-tiers.tsv"' in gr and '"$RUNNER_TEMP/ci-durations/ci-durations.tsv"' in gr and "exit 1" in gr,
      f"TW3 the guard requires both files: {gr!r}")
ds = steps(ci, "tests-shard")[dl] if dl is not None else {}
check("continue-on-error" not in ds and (ds.get("with") or {}).get("path") == "${{ runner.temp }}/ci-durations",
      "TW3 the download is not continue-on-error and lands in runner.temp/ci-durations")
check("--expect-n" in str(steps(ci, "tests-shard")[sp].get("run", "")) if sp is not None else False, "TW3 the shard still re-plans with --expect-n")

print("TW4: the nightly plan and shards read one tier file")
on = nwf.get("on", nwf.get(True)) or {}
check(set(on) <= {"schedule", "workflow_dispatch"}, f"TW4 the nightly runs on schedule/dispatch only: {sorted(on)!r}")
nf = one(idx(nj, "plan", runs("bin/ci-test-tiers.sh fetch")), "TW4 one tier fetch in the nightly plan")
npl = one(idx(nj, "plan", runs("bin/ci-plan.sh")), "TW4 one ci-plan in the nightly plan")
nu = one(idx(nj, "plan", uses_art("upload", "nightly-tiers")), "TW4 one nightly-tiers upload")
check(None not in (nf, npl, nu) and nf < npl and nf < nu, f"TW4 fetch ({nf}) before ci-plan ({npl}) and the upload ({nu})")
ne = env(nj, "plan", nf)
check('--out "$RUNNER_TEMP/tiers/test-tiers.tsv"' in str(steps(nj, "plan")[nf].get("run", "")) if nf is not None else False, "TW4 the fetch writes runner.temp/tiers")
check(ne.get("JOBS_URL") == "${{ vars.JOBS_URL }}" and ne.get("CI_DURATIONS_TOKEN") == "${{ secrets.CI_DURATIONS_TOKEN }}",
      f"TW4 the nightly fetch env: {sorted(ne)!r}")
nus = (steps(nj, "plan")[nu].get("with") or {}) if nu is not None else {}
check(nus.get("path") == N_FILE and int(nus.get("retention-days", 0)) == 3, f"TW4 the upload: {nus!r}")
nd = one(idx(nj, "shard", uses_art("download", "nightly-tiers")), "TW4 one nightly-tiers download in the shard")
ng = one(idx(nj, "shard", runs("::error::no test-tiers from the plan job")), "TW4 one guard in the shard")
nsp = one(idx(nj, "shard", runs("bin/ci-plan.sh")), "TW4 one ci-plan in the shard")
check(None not in (nd, ng, nsp) and nd < ng < nsp, f"TW4 download ({nd}) < guard ({ng}) < ci-plan ({nsp})")
check(str(steps(nj, "shard")[nsp].get("run", "")).find("--expect-n") > 0 if nsp is not None else False, "TW4 the shard still re-plans with --expect-n")
ndw = (steps(nj, "shard")[nd].get("with") or {}) if nd is not None else {}
check(ndw.get("path") == "${{ runner.temp }}/tiers", f"TW4 the download lands in runner.temp/tiers: {ndw!r}")
for j, i in ((j, i) for j in nj for i in idx(nj, j, runs("bin/ci-plan.sh"))):
    check(env(nj, j, i).get("CI_PLAN_TIER_FILE") == N_FILE, f"TW4 nightly {j} sets CI_PLAN_TIER_FILE: {env(nj, j, i).get('CI_PLAN_TIER_FILE')!r}")

print("TW5: no workflow writes a tier set")
hits = [p for p in sorted(glob.glob(sys.argv[3] + "/*.yml")) if "ci-test-tiers.sh put" in open(p).read()]
check(hits == [], f"TW5 no workflow runs bin/ci-test-tiers.sh put: {hits!r}")

print(f"PASS={P} FAIL={F}")
sys.exit(1 if F else 0)
PY
