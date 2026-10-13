#!/bin/bash
# tests/config-literal-lint.sh [--strict] [root]
#
# BH-1511.1 — the lint half of "anything in the harness that can be a DB value
# should be a DB value" (the operator, 2026-09-22). A `${VAR:-literal}` whose VAR is a
# REGISTERED knob (catalog/lanes.d, lanes and libs) carries a second copy of the
# default: the registry says one number, the file says another the day either
# moves, and the file's copy is the one a worker outage runs on. The settings
# contract (bin/lib/lane-gate.sh, `required: true`) is what lets a conversion
# slice delete that copy; this lint lists what is left to delete.
#
# WHAT COUNTS. `${NAME:-x}` or `${NAME:=x}` where NAME is a registered knob's
# env name and the default is a LITERAL — non-empty and not itself an
# expansion. `${NAME:-}` is an emptiness test, not a default; `${A:-$B}` /
# `${A:-${B:-5}}` compute theirs, and the inner `${B:-5}` is counted on its own
# when B is registered. Comment lines are skipped.
#
# WHERE: bin/, fly/, cron/ — tracked files only (`git ls-files`), the issue's
# own scope. tests/ and every fixture are exempt, as in tests/model-literal-lint.sh.
#
# WARN MODE (the default): prints every finding as file:line:NAME:literal and a
# count, and exits 0. It is NOT a ratchet: tests/lanes-registry-test.sh section
# 7 demands that every new `${X:-default}` a lane reads be registered, so every
# new knob adds exactly one of these — a ceiling here would fail unrelated PRs
# on a shared count, the shape BH-1247 took out of this repo. Conversion slices
# (#1511.2…) drive it down; the final slice runs --strict in CI at 0.
#
#   CONFIG_LITERAL_LINT_BASELINE=414 findings (2026-09-22), the same on
#     origin/main d202defb and with this slice: the slice REGISTERS
#     WAKE_BACKSTOP_S (so its read would count) and DELETES its literal (so it
#     does not). Every read site of a registered name counts, wherever it is —
#     JOBS_BOX read by bin/harness-ctl.sh is a finding because a lane registers
#     JOBS_BOX — which is why this is larger than the issue's 308 "registered
#     reads in the lane's own script".
#
#   --strict   exit 1 if anything is found (the final slice)
#   --drift    instead of the lint, print the REGISTRY-VS-READ drift as TSV
#              (kind, scope:id, ENV, file, detail) — the knobs a conversion
#              slice cannot simply mark `required`: READ_DIFFERS (the read's
#              default is computed or is not the registry default), READ_OP (a
#              `${X-…}`/`${X+…}`/`${X:+…}` read, where set-vs-unset matters) and
#              NOT_IN_OWN_FILE (no read in the lane's script / read_in / lib
#              file: it is read somewhere else, possibly a child process).
#              docs/config-inventory/registry-drift.tsv is where a hand run
#              may save this output; it is git-ignored and not committed
#              (BH-5518), because every knob-registering PR moved it and a
#              committed copy is the shared-generated-file conflict BH-1247
#              removed. `--drift` on the current tree is the live list
#              (review round 2 of #1565, N3). One knob read twice in one
#              file prints twice, so count distinct (scope, ENV), not lines.
#
# The registry is rendered from <root>/catalog/lanes.d by bin/lanes-build.sh,
# or taken from $LANE_REGISTRY when a fixture sets it.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
ROOT_DEFAULT="$(cd "$(dirname "$0")/.." && pwd)"
STRICT=0; ROOT=""; DRIFT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --drift)  DRIFT=1 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*) echo "config-literal-lint: unknown flag $1" >&2; exit 2 ;;
    *) ROOT="$1" ;;
  esac
  shift
done
ROOT="${ROOT:-$ROOT_DEFAULT}"; ROOT="${ROOT%/}"

REG="${LANE_REGISTRY:-}"
if [ -z "$REG" ]; then
  REG="$T/lanes.json"
  "$ROOT/bin/lanes-build.sh" --root "$ROOT" --to "$REG" >/dev/null 2>&1 \
    || { echo "config-literal-lint: could not compose the registry from $ROOT/catalog/lanes.d — a lint with no vocabulary must not report green" >&2; exit 2; }
fi
[ -r "$REG" ] || { echo "config-literal-lint: registry $REG is not readable" >&2; exit 2; }

if [ "$DRIFT" = 1 ]; then
  python3 - "$ROOT" "$REG" <<'PY'
import json, os, re, sys
root, reg = sys.argv[1], json.load(open(sys.argv[2]))
def reads(rel, env):
    try:
        text = open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    out = []
    for line in text.split('\n'):
        if line.lstrip().startswith('#'):
            continue
        for m in re.finditer(r'\$\{' + re.escape(env) + r'(:?[-=+?])', line):
            i, depth = m.end(), 1
            while i < len(line) and depth:
                depth += {'{': 1, '}': -1}.get(line[i], 0)
                i += 1
            out.append((m.group(1), line[m.end():i - 1]))
    return out
def num(x):
    try: return float(x)
    except ValueError: return None
print("kind\tscope:id\tenv\tfile\tdetail")
for scope, key in (("lane", "lanes"), ("lib", "libs")):
    for l in reg.get(key, []):
        for k in l.get("knobs", []):
            env, d = k.get("env"), k.get("default")
            if not env or d is None or str(d) == "":
                continue
            ds = str(d)
            files = [l["file"]] if scope == "lib" else [l.get("script", "")] + ([k["read_in"]] if k.get("read_in") else [])
            files = [f for f in files if f and not f.startswith('/')]
            rs = [(f,) + r for f in files for r in reads(f, env)]
            if not rs:
                print(f"NOT_IN_OWN_FILE\t{scope}:{l['id']}\t{env}\t{' '.join(files)}\tregistry={ds}")
                continue
            for f, op, lit in rs:
                if op not in (':-', ':='):
                    print(f"READ_OP\t{scope}:{l['id']}\t{env}\t{f}\t${{{env}{op}{lit}}} registry={ds}")
                elif lit and not (lit == ds or (num(lit) is not None and num(lit) == num(ds))):
                    print(f"READ_DIFFERS\t{scope}:{l['id']}\t{env}\t{f}\tread={lit} registry={ds}")
                elif not lit:
                    print(f"READ_DIFFERS\t{scope}:{l['id']}\t{env}\t{f}\tread=(empty) registry={ds}")
PY
  exit $?
fi
jq -r '[.lanes[]?.knobs[]?, .libs[]?.knobs[]? | .env // empty] | unique[]' "$REG" > "$T/knobs.txt" 2>/dev/null \
  || { echo "config-literal-lint: $REG is not a registry" >&2; exit 2; }
[ -s "$T/knobs.txt" ] || { echo "config-literal-lint: the registry names zero knobs — refusing to scan for nothing" >&2; exit 2; }

: > "$T/files.txt"
for d in bin fly cron; do
  [ -d "$ROOT/$d" ] || continue
  (cd "$ROOT" && git ls-files -- "$d" 2>/dev/null) >> "$T/files.txt"
done
[ -s "$T/files.txt" ] || { echo "config-literal-lint: no tracked files under bin/ fly/ cron/ — nothing to scan" >&2; exit 2; }

HITS=$(python3 - "$ROOT" "$T/knobs.txt" "$T/files.txt" <<'PY'
import re, sys
root, knobs_f, files_f = sys.argv[1:4]
knobs = set(open(knobs_f).read().split())
pat = re.compile(r'\$\{([A-Z_][A-Z0-9_]*):[-=]')
for rel in open(files_f).read().split('\n'):
    if not rel:
        continue
    try:
        text = open(f"{root}/{rel}", encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for n, line in enumerate(text.split('\n'), 1):
        if line.lstrip().startswith('#'):
            continue
        for m in pat.finditer(line):
            name = m.group(1)
            if name not in knobs:
                continue
            # the default runs to the brace that closes THIS expansion
            i, depth = m.end(), 1
            while i < len(line) and depth:
                depth += {'{': 1, '}': -1}.get(line[i], 0)
                i += 1
            default = line[m.end():i - 1] if depth == 0 else line[m.end():]
            if not default or default.startswith('$'):
                continue
            print(f"{rel}:{n}:{name}:{default}")
PY
) || { echo "config-literal-lint: the scan itself failed" >&2; exit 2; }

N=$(printf '%s\n' "$HITS" | grep -c . || true)
[ -n "$HITS" ] && printf '%s\n' "$HITS"
echo "config-literal-lint: $N redundant literal default(s) for registered knobs under bin/ fly/ cron/ ($(wc -l < "$T/knobs.txt" | tr -d ' ') registered knob names)"
if [ "$STRICT" = 1 ] && [ "$N" -gt 0 ]; then
  echo "config-literal-lint: --strict and $N literal(s) remain — mark the knob required: true in catalog/lanes.d and read it as \$NAME (BH-1511)" >&2
  exit 1
fi
exit 0
