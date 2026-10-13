#!/bin/bash
# tests/gate-selfwrite-test.sh — comment-author extraction must cover every
# detail-response shape used by the in-app boards.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

python3 - "$DIR/bin/gate-selfwrite.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("gate_selfwrite", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

older = {
    "createdAt": "2026-09-02T17:18:00Z",
    "author": {"name": "Build Harness"},
}
newer = {
    "createdAt": "2026-09-02T17:27:00Z",
    "author": {"name": "Dev Team"},
}

cases = {
    "flat ticket": {"comments": [older, newer]},
    "nested ticket": {"ticket": {"comments": [older, newer]}},
    "sibling comments (project-9)": {
        "ticket": {"id": "00000000-0000-0000-0000-000000000000"},
        "comments": [older, newer],
    },
}

for label, payload in cases.items():
    actual = module.newest_comment_author(payload)
    if actual != "Dev Team":
        raise AssertionError(f"{label}: got {actual!r}, want 'Dev Team'")

if module.newest_comment_author({"ticket": {}, "comments": []}) is not None:
    raise AssertionError("empty thread must not produce an author")

print(f"gate-selfwrite-test: {len(cases) + 1} pass, 0 fail")
PY
