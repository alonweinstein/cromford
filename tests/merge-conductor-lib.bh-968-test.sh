#!/bin/bash
# tests/merge-conductor-lib.bh-968-test.sh — BH-968 contract: mc_regen_table
# emits generated-files table rows, and the resolver default BR_REGEN_RUNG is 1.
#
# Drives the real merge-conductor-lib.sh through its production entry point
# (the helper is defined there) and a real git repo, never a copy of the logic.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"

R="$T/repo"
mkdir -p "$R/docs/verification-map"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false

cat > "$R/AGENT_ARCHITECTURE.md" <<'AGENT'
# Agent architecture

## Generated files

| where | command |
| --- | --- |
| `src/generated.ts` | `npm run generate` |
| `docs/schema.md` | `npm run docs` |
| `**/*.lock` | `bash bin/locks.sh` |
| no slash here | `bash bin/bad.sh` |
|  |  |
AGENT

cat > "$R/docs/verification-map/README.md" <<'VMAP'
# Verification map

## Generated files

| path | regenerate with |
| --- | --- |
| `docs/verification-map/README.md` | `bin/verification-map-build.sh` |
| `env-templates/*.example` | `bash bin/env-template-sync.sh` |
VMAP

git -C "$R" add -A
git -C "$R" commit -qm "tables"
REF=$(git -C "$R" rev-parse HEAD)

OUT=$(mc_regen_table "$R" "$REF")
WANT=$(printf '%s\n%s\n%s\n%s\n%s' \
  'src/generated.ts	npm run generate' \
  'docs/schema.md	npm run docs' \
  '**/*.lock	bash bin/locks.sh' \
  'docs/verification-map/README.md	bin/verification-map-build.sh' \
  'env-templates/*.example	bash bin/env-template-sync.sh')
[ "$OUT" = "$WANT" ] && ok || bad "mc_regen_table returns all valid rows, preserves globs and skips separators/malformed rows (want:\n$WANT\ngot:\n$OUT)"

# Only the generated-files heading under AGENT_ARCHITECTURE.md starts the
# table; a later heading in README.md terminates parsing of that file, so
# a stray `## Generated files` elsewhere is ignored.
grep -qF 'src/generated.ts' <<<"$OUT" && ok || bad "AGENT_ARCHITECTURE.md rows are emitted"
grep -qF 'docs/verification-map/README.md' <<<"$OUT" && ok || bad "README.md rows are emitted"
[ "$(grep -cF 'no slash here' <<<"$OUT")" -eq 0 ] && ok || bad "rows whose path has no / or . are skipped"
[ "$(grep -c 'bad.sh' <<<"$OUT")" -eq 0 ] && ok || bad "malformed/skipped rows do not leak their command"

mkdir -p "$T/emptyrepo"
git init -q -b main "$T/emptyrepo"
git -C "$T/emptyrepo" config user.email t@example.com
git -C "$T/emptyrepo" config user.name t
git -C "$T/emptyrepo" config commit.gpgsign false
git -C "$T/emptyrepo" add -A
git -C "$T/emptyrepo" commit -qm "empty" 2>/dev/null
EMPTY=$(mc_regen_table "$T/emptyrepo" HEAD)
[ -z "$EMPTY" ] && ok || bad "mc_regen_table returns empty when neither AGENT_ARCHITECTURE.md nor docs/verification-map/README.md exists (got: $EMPTY)"

# Missing ref returns empty without failing the caller.
MISS=$(mc_regen_table "$R" no-such-ref-abc123 2>&1)
[ -z "$MISS" ] && ok || bad "mc_regen_table returns empty for an invalid ref (got: $MISS)"

# BR_REGEN_RUNG default: sourcing only the constant header of blocked-resolver.sh
# gives 1. We avoid the full source path because it needs sibling libs and HARNESS.
BR_DEF=$(grep -m1 'BR_REGEN_RUNG="\${BR_REGEN_RUNG:-1}"' "$DIR/bin/blocked-resolver.sh" | sed 's/.*:-\([0-9]*\)}".*/\1/')
[ "$BR_DEF" = "1" ] && ok || bad "BR_REGEN_RUNG default is 1 (got: $BR_DEF)"

echo "merge-conductor-lib.bh-968: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
