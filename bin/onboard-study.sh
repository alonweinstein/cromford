#!/bin/bash
# onboard-study.sh <repo-dir> [--json]
#
# The study pass of project onboarding (BH-4074, slice C0). Reads a checkout
# and reports what this harness would need to build it: the commands, any
# deploy config, a DRAFT Verification Contract, a readiness grade and whether
# CodeGraph indexed it. Deterministic, and it calls no model. Only the ROOT of
# the checkout is read: a monorepo whose package.json lives in a subdir is
# reported like a checkout with no package.json.
#
#   install   from the lockfile only, first match wins:
#             package-lock.json -> npm ci, pnpm-lock.yaml -> pnpm install
#             --frozen-lockfile, yarn.lock -> yarn --frozen-lockfile.
#             No lockfile -> null (`npm install` is not a reproducible command).
#   test, start, build, lint, e2e
#             the package.json scripts `test`, `start`, `build`, `lint` and
#             `test:e2e`, run through the lockfile's package manager (npm when
#             there is no lockfile): `<pm> test`, `<pm> start`, `<pm> run <name>`.
#             A script that is absent or not a string -> null. An unparseable
#             package.json -> every package command null + package_json_error.
#   deploy    vercel.json, fly.toml, wrangler.toml, scripts/deploy.sh (that
#             order) -> {"detected":[...],"used":false}; none -> null. A deploy
#             is never run and never put in the contract.
#   framework "nextjs" when `next` is in dependencies/devDependencies or a
#             next.config.* exists; otherwise null.
#   contract_draft
#             a "## Verification Contract" section. Its first ```bash block's
#             first line is install && lint && test && build (the non-null ones,
#             in that order): the line bin/batch-resolve.sh verify_cmd reads.
#             e2e, when present, is a second block. With no test command the
#             first block is EMPTY and the prose says so; no contract is invented.
#   readiness bin/readiness-report.sh <dir> --json --no-run (READINESS_GH
#             passed through, default 1) under `timeout 300` -> {level,
#             max_level}. A grade that fails, times out or does not parse is
#             null plus readiness_error, never 0.
#   codegraph `codegraph init -i` in the checkout under `timeout 90` when the
#             binary ($CODEGRAPH_BIN, default `codegraph` on PATH) exists:
#             "indexed" on rc 0, otherwise "failed". No binary: "skipped". It
#             never changes the exit code. THE ONE WRITE: codegraph creates
#             .codegraph/ inside the checkout; nothing else is written there.
#
# Output (--json): {schema:1, framework, commands:{install,test,build,start,
# lint,e2e,deploy}, contract_draft, readiness, codegraph[, readiness_error]
# [, package_json_error]}. Without --json, a human summary whose LAST line is
# "READINESS LEVEL: <n>/<max>" or "READINESS LEVEL: unknown".
#
# Exit codes: 0 a report was produced (whatever it says). 2 usage: no dir, not
# a directory, an unknown flag, two dirs, or jq missing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,48p' "$0" >&2; }

REPO="" MODE=human
while [ $# -gt 0 ]; do
  case "$1" in
    --json)    MODE=json ;;
    -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
    -*)        echo "onboard-study.sh: unknown flag $1" >&2; usage; exit 2 ;;
    *)         [ -z "$REPO" ] || { echo "onboard-study.sh: one repo dir, not two ($REPO, $1)" >&2; exit 2; }
               REPO="$1" ;;
  esac
  shift
done
[ -n "$REPO" ] || { echo "onboard-study.sh: a repo dir is required" >&2; usage; exit 2; }
[ -d "$REPO" ] || { echo "onboard-study.sh: not a directory: $REPO" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "onboard-study.sh: jq is required" >&2; exit 2; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# ── package manager + commands ──────────────────────────────────────────────
PKG="$REPO/package.json"
PM=npm INSTALL="" PKG_ERR=""
if [ -f "$REPO/package-lock.json" ]; then PM=npm;  INSTALL="npm ci"
elif [ -f "$REPO/pnpm-lock.yaml" ]; then PM=pnpm; INSTALL="pnpm install --frozen-lockfile"
elif [ -f "$REPO/yarn.lock" ];      then PM=yarn; INSTALL="yarn --frozen-lockfile"
fi

has_script() { jq -e --arg s "$1" '(.scripts // {}) | (.[$s] | type) == "string"' "$PKG" >/dev/null 2>&1; }
run_cmd() {
  case "$1" in
    test|start) echo "$PM $1" ;;
    *)          echo "$PM run $1" ;;
  esac
}

TEST="" BUILD="" START="" LINT="" E2E=""
if [ ! -f "$PKG" ]; then
  INSTALL=""   # a lockfile with no package.json declares nothing to install
elif ! jq -e 'type == "object" and ((.scripts // {}) | type == "object")' "$PKG" >/dev/null 2>&1; then
  PKG_ERR="package.json is not a JSON object with an object .scripts; no command was read from it"
  INSTALL=""
else
  has_script test     && TEST=$(run_cmd test)
  has_script build    && BUILD=$(run_cmd build)
  has_script start    && START=$(run_cmd start)
  has_script lint     && LINT=$(run_cmd lint)
  has_script test:e2e && E2E=$(run_cmd test:e2e)
fi

# ── framework ───────────────────────────────────────────────────────────────
FRAMEWORK=""
if [ -f "$PKG" ] && [ -z "$PKG_ERR" ] \
   && jq -e '((.dependencies // {}) + (.devDependencies // {})) | has("next")' "$PKG" >/dev/null 2>&1; then
  FRAMEWORK=nextjs
elif compgen -G "$REPO/next.config.*" >/dev/null; then
  FRAMEWORK=nextjs
fi

# ── deploy: detected, never used ────────────────────────────────────────────
DEPLOY_FOUND=()
for f in vercel.json fly.toml wrangler.toml scripts/deploy.sh; do
  [ -f "$REPO/$f" ] && DEPLOY_FOUND+=("$f")
done
DEPLOY_JSON=null
[ ${#DEPLOY_FOUND[@]} -gt 0 ] && DEPLOY_JSON=$(jq -cn '{detected: $ARGS.positional, used: false}' --args "${DEPLOY_FOUND[@]}")

# ── readiness ───────────────────────────────────────────────────────────────
READINESS_JSON=null READINESS_ERR=""
READINESS_GH="${READINESS_GH:-1}" timeout 300 bash "$HERE/readiness-report.sh" "$REPO" --json --no-run \
  >"$TMPD/ready.json" 2>"$TMPD/ready.err"
rrc=$?
if [ "$rrc" -eq 124 ]; then
  READINESS_ERR="readiness-report.sh timed out after 300s"
elif [ "$rrc" -ne 0 ]; then
  READINESS_ERR="readiness-report.sh exited $rrc: $(tail -n 1 "$TMPD/ready.err" 2>/dev/null)"
elif R=$(jq -ce 'select((.level | type) == "number" and (.max_level | type) == "number") | {level, max_level}' \
           "$TMPD/ready.json" 2>/dev/null) && [ -n "$R" ]; then
  READINESS_JSON=$R
else
  READINESS_ERR="readiness-report.sh produced no numeric level/max_level"
fi

# ── codegraph (best effort) ─────────────────────────────────────────────────
CG="${CODEGRAPH_BIN:-codegraph}"
if command -v "$CG" >/dev/null 2>&1; then
  if (cd "$REPO" && timeout 90 "$CG" init -i) >"$TMPD/cg.out" 2>&1; then CODEGRAPH=indexed
  else CODEGRAPH=failed; fi
else
  CODEGRAPH=skipped
fi

# ── contract draft ──────────────────────────────────────────────────────────
if [ -n "$TEST" ]; then
  CHAIN=""
  for c in "$INSTALL" "$LINT" "$TEST" "$BUILD"; do
    [ -n "$c" ] && CHAIN="${CHAIN:+$CHAIN && }$c"
  done
  CONTRACT=$(printf '## Verification Contract\n\nDRAFT from bin/onboard-study.sh, read from package.json and the lockfile. The owner confirms it before it is adopted: the first line of the first block is what a verification run executes.\n\n```bash\n%s\n```\n' "$CHAIN")
else
  CONTRACT=$(printf '## Verification Contract\n\nDRAFT from bin/onboard-study.sh: no test command was detected, so the first block is empty. The owner writes the verify command before this repo is enrolled.\n\n```bash\n```\n')
fi
[ -n "$E2E" ] && CONTRACT=$(printf '%s\n\nEnd-to-end, run separately:\n\n```bash\n%s\n```\n' "$CONTRACT" "$E2E")

# ── output ──────────────────────────────────────────────────────────────────
OUT=$(jq -n \
  --arg framework "$FRAMEWORK" \
  --arg install "$INSTALL" --arg test "$TEST" --arg build "$BUILD" \
  --arg start "$START" --arg lint "$LINT" --arg e2e "$E2E" \
  --argjson deploy "$DEPLOY_JSON" --arg contract "$CONTRACT" \
  --argjson readiness "$READINESS_JSON" --arg rerr "$READINESS_ERR" \
  --arg codegraph "$CODEGRAPH" --arg perr "$PKG_ERR" '
  def n: if . == "" then null else . end;
  {schema: 1, framework: ($framework | n),
   commands: {install: ($install | n), test: ($test | n), build: ($build | n),
              start: ($start | n), lint: ($lint | n), e2e: ($e2e | n),
              deploy: $deploy},
   contract_draft: $contract, readiness: $readiness, codegraph: $codegraph}
  + (if $rerr != "" then {readiness_error: $rerr} else {} end)
  + (if $perr != "" then {package_json_error: $perr} else {} end)')

if [ "$MODE" = json ]; then
  printf '%s\n' "$OUT"
  exit 0
fi

show() { printf '  %-8s %s\n' "$1" "${2:-(none)}"; }
echo "onboard study: $REPO"
echo "framework: ${FRAMEWORK:-(none detected)}"
echo "commands:"
show install "$INSTALL"; show test "$TEST"; show build "$BUILD"; show start "$START"
show lint "$LINT"; show e2e "$E2E"
if [ ${#DEPLOY_FOUND[@]} -gt 0 ]; then show deploy "detected, not used: ${DEPLOY_FOUND[*]}"; else show deploy ""; fi
[ -n "$PKG_ERR" ] && echo "package.json: $PKG_ERR"
echo "codegraph: $CODEGRAPH"
echo
printf '%s\n\n' "$CONTRACT"
if [ "$READINESS_JSON" != null ]; then
  jq -r '"READINESS LEVEL: \(.level)/\(.max_level)"' <<<"$READINESS_JSON"
else
  echo "readiness: not graded ($READINESS_ERR)"
  echo "READINESS LEVEL: unknown"
fi
exit 0
