#!/bin/bash
# tests/e2e-ui-paths-lib-test.sh — bin/lib/e2e-ui-paths.sh answers ONE question,
# "can this diff change a rendered route?", and the preview smoke gate will act
# on its rc. Both sides of every boundary are pinned here: a file the browser
# actually renders MUST hit, and the server/test/story/lockfile paths that made
# the old .tsx regex fire on every build MUST NOT. The override semantics
# (E2E_PATHS replaces the default, blank means default) are pinned too, because
# a box that sets the knob wrong silently gets the wrong gate.
#
# No scratch tree: this suite creates nothing, removes nothing and never changes
# its own cwd, so there is nothing for tests/lib/scratch.sh to own. The "scratch
# cwd" the pathname-expansion case needs is the checked-in fixture directory
# tests/fixtures/e2e-ui-paths/, entered inside a one-line subshell.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
CTX=repo
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL[$CTX]: $1" >&2; }
# shellcheck source=../bin/lib/e2e-ui-paths.sh
. "$DIR/bin/lib/e2e-ui-paths.sh" || exit 1

hit()  { printf '%s\n' "$1" | e2e_ui_path_hit && ok || bad "should hit: $1"; }
miss() { printf '%s\n' "$1" | e2e_ui_path_hit && bad "should NOT hit: $1" || ok; }
# E2E_PATHS scoped to one assertion; `local` is visible to the callee, so the
# matcher reads it without the test ever exporting a knob into the environment.
with_paths() { local E2E_PATHS="$1"; shift; "$@"; }

run_matrix() {
  local p
  unset E2E_PATHS

  # Server code, tests, stories, specs, docs, deps, schema, migrations, CI: the
  # browser renders none of them. apps/web, appointments, webapp, pages.ts,
  # components.ts, public.ts and middleware-utils.ts are the near-misses — a
  # glob with a `/` needs a real path SEGMENT, one without a `/` needs the whole
  # basename.
  for p in src/lib/engine/x.ts worker/src/index.ts src/lib/foo.test.tsx src/lib/Widget.stories.tsx \
           tests/e2e/login.spec.ts README.md docs/verification-map/x.md package.json package-lock.json \
           prisma/schema.prisma scripts/migrations/0001.sql .github/workflows/ci.yml \
           apps/web/x.ts src/lib/appointments/x.ts webapp/x.ts \
           src/lib/pages.ts src/components.ts src/lib/public.ts middleware-utils.ts; do miss "$p"; done

  # Rendered routes, their components, their assets and the two configs that
  # change every page. src/app/api/x/route.ts hits because `src/app/**` is
  # literal: an API handler under the app dir is inside the route tree, and this
  # line is here so that assumption is visible rather than inferred.
  for p in app/page.tsx src/app/x/page.tsx src/app/api/x/route.ts pages/index.tsx src/pages/x.tsx \
           components/Nav.tsx src/components/Nav.tsx public/logo.svg src/app/globals.css styles/x.css \
           middleware.ts src/middleware.ts next.config.mjs; do hit "$p"; done

  # List shape: any line hits, all-server misses, empty input never hits.
  printf 'src/lib/a.ts\nworker/b.ts\n'        | e2e_ui_path_hit && bad "two server files must not hit" || ok
  printf 'src/lib/a.ts\nsrc/app/x/page.tsx\n' | e2e_ui_path_hit && ok || bad "a page beside a server file must hit"
  printf ''                                   | e2e_ui_path_hit && bad "an empty list must not hit" || ok

  # E2E_PATHS REPLACES the default (it does not extend it); blank means default;
  # commas are separators; unset prints the default list verbatim.
  with_paths 'src/lib/engine/**'     hit  'src/lib/engine/x.ts'
  with_paths 'src/lib/engine/**'     miss 'components/Nav.tsx'
  with_paths '  '                    hit  'components/Nav.tsx'
  with_paths 'src/lib/**,components/**' hit 'src/lib/engine/x.ts'
  [ "$(e2e_ui_globs)" = "$E2E_UI_GLOBS_DEFAULT" ] && ok || bad "unset E2E_PATHS must print the default list, got: $(e2e_ui_globs)"
}

run_matrix
REPO_PASS=$PASS

# The pathname-expansion trap: from a cwd that CONTAINS a.css and middleware.ts,
# an unquoted glob list would expand against those files and rewrite itself.
# Every answer must be identical. The cd lives inside the subshell only.
SUB=$( CTX=fixture-cwd; PASS=0; FAIL=0; cd "$DIR/tests/fixtures/e2e-ui-paths" || exit 99; run_matrix >&2; printf '%s %s\n' "$PASS" "$FAIL" )
SUB_PASS=${SUB%% *}; SUB_FAIL=${SUB##* }
[ -n "$SUB" ] && [ "$SUB_PASS" = "$REPO_PASS" ] && ok || bad "matrix from the fixture cwd passed '$SUB_PASS', repo cwd passed '$REPO_PASS'"
[ "$SUB_FAIL" = 0 ] && ok || bad "matrix from the fixture cwd reported '$SUB_FAIL' failures"

echo "e2e-ui-paths-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
