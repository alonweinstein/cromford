#!/bin/bash
# Build the pool launcher's actual archive and price a synthetic session from
# the extracted runtime. A missing catalog must not turn recorded usage into $0.
set -euo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

python3 - "$DIR" "$T" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

repo, tmp = map(Path, sys.argv[1:])
fixture = tmp / "checkout"
runtime = tmp / "runtime"
for name in ("bin", "prompts", "rules", "catalog", "fly"):
    (fixture / name).mkdir(parents=True)
(fixture / "fleet.conf").write_text("# fixture\n")
shutil.copy2(repo / "bin/transcript-cost.sh", fixture / "bin/transcript-cost.sh")
model = "pool-pricing-fixture"
(fixture / "catalog/model-prices.json").write_text(json.dumps({
    "per_token": {model: {
        "prompt": 0.000001, "completion": 0.000002,
        "cache_read": 0.0000001, "cache_write": 0.00000125,
    }}
}))

# Execute only the archive command from spawn_one; never launch a machine.
spawn = (repo / "bin/fly-pool.sh").read_text().split("spawn_one() {", 1)[1]
line = next(line.strip() for line in spawn.splitlines()
            if line.strip().startswith('harness_tarball "$TB"'))
args = shlex.split(line.split("2>/dev/null", 1)[0])
archive = tmp / "pool.tgz"
args[args.index("$TB")] = str(archive)
args[2] = str(fixture)
subprocess.run(["bash", "-c", '. "$0" && "$@"; [ $? != 1 ]',
                str(repo / "bin/lib/harness-tarball.sh"), *args], check=True)
runtime.mkdir()
subprocess.run(["tar", "xzf", str(archive), "-C", str(runtime)], check=True)
if not (runtime / "catalog/model-prices.json").is_file():
    sys.exit("FAIL: the pool runtime archive omits catalog/model-prices.json")

session = tmp / "synthetic.jsonl"
session.write_text(json.dumps({"message": {
    "id": "fixture-response", "model": model,
    "usage": {"input_tokens": 10, "output_tokens": 20,
              "cache_read_input_tokens": 100,
              "cache_creation_input_tokens": 0},
}}) + "\n")
env = dict(os.environ, HARNESS=str(runtime), MODEL_PRICES="")
result = subprocess.run([
    "bash", str(runtime / "bin/transcript-cost.sh"), str(session),
    "--no-subagents", "--format", "json",
], env=env, check=True, capture_output=True, text=True)
cost = json.loads(result.stdout)
if cost["usd"] != 0.00006 or cost["unpriced"]:
    sys.exit("FAIL: the extracted pool runtime did not price recorded usage")
if Path(cost["prices"]).resolve() != runtime / "catalog/model-prices.json":
    sys.exit("FAIL: pool pricing depended on a catalog outside its runtime")
print("pool-pricing-catalog-test: archive built; extracted runtime prices usage")
PY
