#!/bin/bash
# tests/e2e-paths-lib-test.sh — bin/lib/e2e-paths.sh is the fleet's one
# definition of "E2E path" and "E2E-class check" (docs/E2E-POLICY.md). Every
# consumer (review-prs debounce, review-autopilot prompt) trusts these two
# regexes, so each side of each boundary is pinned here: a path the app repos
# gate their browser jobs on MUST hit, a server/docs/migration path MUST NOT,
# and the fast deterministic check names must never read as E2E.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# shellcheck source=../bin/lib/e2e-paths.sh
. "$DIR/bin/lib/e2e-paths.sh"

hit()  { printf '%s\n' "$1" | e2e_path_hit && ok || bad "should be an E2E path: $1"; }
miss() { printf '%s\n' "$1" | e2e_path_hit && bad "should NOT be an E2E path: $1" || ok; }
for p in app/page.tsx src/app/api/clients/route.ts pages/index.tsx src/components/Nav.tsx ui/button.tsx \
         middleware.ts src/proxy.ts src/middleware.js lib/auth.ts src/auth/session.ts \
         tests/e2e/login.spec.ts e2e/smoke.ts playwright.config.ts playwright/fixtures.ts \
         package.json package-lock.json pnpm-lock.yaml next.config.mjs next.config.js tailwind.config.ts postcss.config.js \
         src/app/globals.css styles/global.css .github/workflows/e2e.yml .github/workflows/e2e-prod.yml; do hit "$p"; done
for p in lib/pricing.ts src/server/jobs.ts scripts/migrations/0042.sql prisma/schema.prisma README.md docs/E2E.md \
         tests/unit/pricing.test.ts src/lib/utils.ts .github/workflows/ci.yml .github/workflows/typecheck.yml \
         supabase/functions/x/index.ts bin/deploy.sh; do miss "$p"; done
# a multi-line list hits when ANY line hits, and an empty list never hits
printf 'lib/a.ts\nsrc/app/x/page.tsx\n' | e2e_path_hit && ok || bad "a UI file among server files must hit"
printf 'lib/a.ts\nlib/b.ts\n' | e2e_path_hit && bad "two server files must not hit" || ok
printf '' | e2e_path_hit && bad "an empty list must not hit" || ok

e2e()  { e2e_check_name "$1" && ok || bad "should be an E2E-class check: $1"; }
fast() { e2e_check_name "$1" && bad "should NOT be an E2E-class check: $1" || ok; }
for n in "E2E Tests" "e2e" "E2E (chromium)" "Production QA" "production-qa" "Prod QA" "Preview QA" "Playwright" "playwright-smoke" "Post-deploy browser"; do e2e "$n"; done
# real fleet names that must stay substantive: project-5's smoke test is unit-class,
# its Railway deploy is a push-time job, project-1/project-2 run Guardrails on PRs
for n in "Typecheck" "Lint" "Unit tests" "unit" "Guard" "Guardrails" "test-tamper" "Static guards vs current main" "Harness CI" "CI" "build" \
         "Migrate prod DB" "Bridge npm smoke test" "Deploy Worker to Railway" "Weekly Full-Scan Smoke" "Migration SQL gate"; do fast "$n"; done

echo "e2e-paths-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
