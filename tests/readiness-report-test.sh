#!/bin/bash
# tests/readiness-report-test.sh — bin/readiness-report.sh grades a checkout.
#
# WHAT THIS SUITE IS PROTECTING. The report is the thing an operator reads
# before deciding whether a repo can be built, reviewed and shipped by machines
# with nobody watching. Two failure shapes make it worse than useless:
#
#   1. a check that answers "pass" because its probe never ran. `gh` unauthed,
#      `npm` missing, the migration linter not beside the script — every one of
#      those is an UNKNOWN, and unknown is a third status, never a quiet yes.
#      So the negatives carry the weight here: the sections that hand the script
#      a broken world and assert it says so.
#   2. a level that moves without anyone deciding it moved. The level table is
#      config (catalog/readiness-levels.json) with a builtin fallback, and the
#      two copies are pinned byte-for-byte by A1 — a fallback that has drifted
#      is a repo graded by a different rulebook depending on which box ran it.
#
# Everything is asserted on the script's OUTPUT — the table's last line and the
# --json object. Nothing here greps the script's source: a regex over source
# text keeps passing while the probe behind it is broken.
#
# No network: every `gh` and every `npm` the sections care about is a stub first
# on PATH, and the sections that must prove a command was NOT run assert on a
# marker file the stub writes.
#
# Run from anywhere: bash tests/readiness-report-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RR="$DIR/bin/readiness-report.sh"
FIX="$DIR/tests/fixtures/readiness"
CAT="$DIR/catalog/readiness-levels.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h" "$T/bin"

# mk <name> [fixture-to-copy ...] — a scratch checkout the sections may mutate.
# Fixtures are copied, never graded in place: several sections add a committed
# .env or rewrite package.json, and a suite that mutated the committed fixtures
# would pass once and poison every later run.
mk() {
  local n="$1"; shift
  rm -rf "$T/$n"; mkdir -p "$T/$n"
  local f
  for f in "$@"; do cp -R "$FIX/$f/." "$T/$n/"; done
  printf '%s' "$T/$n"
}

# report <out-basename> <repo> [flags...] — JSON into $T/<out>.json, rc into $RC.
report() {
  local out="$1"; shift
  HARNESS="$T/h" bash "$RR" "$@" --json >"$T/$out.json" 2>"$T/$out.err"
  RC=$?
  return 0
}
st()  { jq -r --arg i "$2" '.checks[] | select(.id==$i) | .status' "$T/$1.json" 2>/dev/null; }
det() { jq -r --arg i "$2" '.checks[] | select(.id==$i) | .detail' "$T/$1.json" 2>/dev/null; }
lvl() { jq -r '.level' "$T/$1.json" 2>/dev/null; }

# ---------- A0. the fixtures exist, and carry no committed .env --------------
A_OK=1
for p in a-empty/.gitkeep b-ready/package.json b-ready/test.js b-ready/CLAUDE.md \
         b-ready/vercel.json b-ready/.env.example b-ready/.gitignore \
         b-ready/.github/workflows/ci.yml b-ready/.github/labels.yml \
         c-overlay/AGENT_ARCHITECTURE.md c-overlay/docs/verification-map/README.md; do
  [ -e "$FIX/$p" ] || { A_OK=0; echo "  missing fixture: $p"; }
done
[ "$A_OK" = 1 ] && ok || bad "A0: the readiness fixtures are incomplete"
# The (d) case is a committed .env, and a suite that committed one to THIS repo
# to test for committed .env files would be the joke that writes itself. It is
# written into the scratch tree instead, and this asserts the tree stays clean.
NENV=$(git -C "$DIR" ls-files tests/fixtures/readiness | grep -c '/\.env$')
[ "$NENV" = 0 ] && ok || bad "A0: tests/fixtures/readiness must never carry a committed .env (found $NENV)"

# ---------- A1. the builtin level table equals the catalog copy --------------
# A script deployed without its catalog must grade IDENTICALLY, or a repo's
# level depends on which box read it. The copy has its SELF_DIR rewritten so the
# repo's own catalog/ cannot be found, and $HARNESS points at an empty tree.
sed 's|^SELF_DIR=.*|SELF_DIR=/nonexistent|' "$RR" > "$T/rr-nocat.sh"
HARNESS="$T/h" READINESS_LEVELS= bash "$T/rr-nocat.sh" --print-levels > "$T/builtin.json" 2>"$T/builtin.err"
RC=$?
[ "$RC" = 0 ] && ok || bad "A1: --print-levels with no catalog must still answer (rc $RC: $(head -1 "$T/builtin.err"))"
if diff <(jq -S .levels "$CAT" 2>/dev/null) <(jq -S .levels "$T/builtin.json" 2>/dev/null) >"$T/parity.diff" 2>&1; then
  ok
else
  bad "A1: the builtin level table has drifted from catalog/readiness-levels.json"; sed 's/^/    /' "$T/parity.diff"
fi
[ "$(jq -r '.levels_source' "$T/builtin.json" 2>/dev/null)" = "builtin" ] \
  && ok || bad "A1: a report with no catalog must name its source as 'builtin'"
[ "$(jq -r '.max_level' "$T/builtin.json" 2>/dev/null)" = "$(jq -r '.max_level' "$CAT" 2>/dev/null)" ] \
  && ok || bad "A1: builtin max_level must equal the catalog's"

# ---------- A2. $READINESS_LEVELS is used as given, or it is an error --------
cat > "$T/only-vmap.json" <<'JSON'
{"_doc":"fixture","max_level":1,
 "levels":{"1":{"requires":["context.vmap"],"must_not_fail":[],"unlocks":"nothing real"}}}
JSON
A=$(mk a2a a-empty); C=$(mk a2c b-ready c-overlay)
READINESS_LEVELS="$T/only-vmap.json" report a2a "$A" --no-run
[ "$(lvl a2a)" = 0 ] && ok || bad "A2: an override table must grade the empty fixture 0 (got $(lvl a2a))"
READINESS_LEVELS="$T/only-vmap.json" report a2c "$C" --no-run
[ "$(lvl a2c)" = 1 ] && ok || bad "A2: an override requiring only context.vmap must grade fixture c 1 (got $(lvl a2c))"
[ "$(jq -r .levels_source "$T/a2c.json" 2>/dev/null)" = "$T/only-vmap.json" ] \
  && ok || bad "A2: the JSON must name the level table it actually read"
# Used AS GIVEN, never fallen back from: an override that silently reads the
# catalog is how a fixture run ends up asserting production rules.
READINESS_LEVELS="$T/no-such/levels.json" report a2bad "$A" --no-run
[ "$RC" = 2 ] && ok || bad "A2: an unreadable \$READINESS_LEVELS must exit 2, never fall back (rc $RC)"

# ---------- A3. a level table naming a check that does not exist -------------
# A typo in the config must not silently relax a gate.
cat > "$T/typo.json" <<'JSON'
{"_doc":"fixture","max_level":1,
 "levels":{"1":{"requires":["context.agent"],"must_not_fail":[],"unlocks":"x"}}}
JSON
READINESS_LEVELS="$T/typo.json" report a3 "$A" --no-run
[ "$RC" = 2 ] && ok || bad "A3: a level table naming an unknown check id must exit 2 (rc $RC)"
grep -q 'context.agent' "$T/a3.err" && ok || bad "A3: the error must name the unknown check id"

# ---------- B1. the empty repo: level 0, every gap named ---------------------
report b1 "$A" --no-run
[ "$RC" = 0 ] && ok || bad "B1: a report that was produced exits 0 — the level is data, not an exit code (rc $RC)"
[ "$(lvl b1)" = 0 ] && ok || bad "B1: the empty fixture must grade level 0 (got $(lvl b1))"
GAPS=$(jq -r '[.gaps[].check] | sort | unique | join(" ")' "$T/b1.json" 2>/dev/null)
WANT="board.source ci.workflow context.agents context.arch context.vmap preview.config secrets.env_example secrets.gitignore tests.present"
[ "$GAPS" = "$WANT" ] && ok || bad "B1: the empty fixture must name all nine required checks as gaps
    want: $WANT
    got:  $GAPS"
# Ascending by level, so the reader's first gap is the cheapest one to close.
jq -e '[.gaps[].level] == ([.gaps[].level] | sort)' "$T/b1.json" >/dev/null 2>&1 \
  && ok || bad "B1: gaps must be ordered ascending by level"
# An empty tree cannot leak an env file, and a gate that said otherwise would
# refuse every new repo for a file that is not there.
[ "$(st b1 secrets.no_committed_env)" = pass ] \
  && ok || bad "B1: an empty tree has no committed .env (got $(st b1 secrets.no_committed_env))"
LAST=$(HARNESS="$T/h" bash "$RR" "$A" --no-run > "$T/b1.table" 2>&1; tail -1 "$T/b1.table")
[ "$LAST" = "READINESS LEVEL: 0/5" ] && ok || bad "B1: table's last line must be the level (got '$LAST')"

# ---------- B2. the ready repo: level 4 -------------------------------------
B=$(mk b2 b-ready)
report b2 "$B" --no-run
[ "$(lvl b2)" = 4 ] && ok || bad "B2: the ready fixture must grade level 4 (got $(lvl b2))"
[ "$(st b2 tests.green)" = skipped ] && ok || bad "B2: --no-run records tests.green as skipped (got $(st b2 tests.green))"
for c in tests.present ci.workflow preview.config board.source secrets.env_example secrets.gitignore context.agents; do
  [ "$(st b2 "$c")" = pass ] || { bad "B2: $c must pass on the ready fixture (got $(st b2 "$c"))"; continue; }
  ok
done
# Level 5 is the only thing it is missing, and the gap must say which files.
[ "$(jq -r '[.gaps[].check] | sort | join(" ")' "$T/b2.json")" = "context.arch context.vmap" ] \
  && ok || bad "B2: the only gaps at level 4 are the two context files"

# ---------- B3. ready + the context overlay: level 5, no gaps ---------------
report b3 "$C" --no-run
[ "$(lvl b3)" = 5 ] && ok || bad "B3: ready + verification map + architecture must grade 5 (got $(lvl b3))"
[ "$(jq -r '.gaps | length' "$T/b3.json")" = 0 ] && ok || bad "B3: a level-5 repo has no gaps"

# ---------- B4. a committed .env drops it to 0 ------------------------------
D=$(mk b4 b-ready)
printf 'EXAMPLE_KEY=fixture\n' > "$D/.env"
report b4 "$D" --no-run
[ "$(st b4 secrets.no_committed_env)" = fail ] \
  && ok || bad "B4: a committed .env must fail the secrets check (got $(st b4 secrets.no_committed_env))"
case "$(det b4 secrets.no_committed_env)" in *.env*) ok ;; *) bad "B4: the detail must name the file it found" ;; esac
[ "$(lvl b4)" = 0 ] && ok || bad "B4: a committed .env drops the repo to level 0 (got $(lvl b4))"
jq -e '[.gaps[] | select(.check=="secrets.no_committed_env" and .level==1)] | length == 1' "$T/b4.json" >/dev/null 2>&1 \
  && ok || bad "B4: the committed .env must appear as the level-1 gap"

# ---------- B4b. the siblings a three-name list never saw ------------------
# `.env.vercel` is the file that leaked seven live keys on a client repo, and
# `.env.staging` / `.env.test` are the same thing under another name. A check
# that only knew .env/.local/.production/.development answered "no committed
# .env in the tree" about a tree that has two. The declaring siblings are the
# other direction: `.env.example` is REQUIRED by secrets.env_example, so
# flagging it would make every correct repo fail its own prerequisite.
D=$(mk b4b b-ready)
printf 'TOKEN=fixture\n' > "$D/.env.vercel"
mkdir -p "$D/config"
printf 'TOKEN=fixture\n' > "$D/config/.env.staging"
report b4b "$D" --no-run
[ "$(st b4b secrets.no_committed_env)" = fail ] \
  && ok || bad "B4b: .env.vercel is a committed env file (got $(st b4b secrets.no_committed_env))"
case "$(det b4b secrets.no_committed_env)" in
  *.env.vercel*) ok ;; *) bad "B4b: the detail must name .env.vercel (got '$(det b4b secrets.no_committed_env)')" ;;
esac
case "$(det b4b secrets.no_committed_env)" in
  *config/.env.staging*) ok ;; *) bad "B4b: a nested .env.staging must be found too (got '$(det b4b secrets.no_committed_env)')" ;;
esac
[ "$(lvl b4b)" = 0 ] && ok || bad "B4b: a committed .env sibling drops the repo to level 0 (got $(lvl b4b))"
# b-ready ships .env.example and grades 4 in B2; this states outright that the
# declaring file is never read as a leak.
case "$(det b2 secrets.no_committed_env)" in
  *.env.example*) bad "B4b: .env.example must never be reported as a committed env file" ;;
  *) ok ;;
esac
[ "$(st b2 secrets.no_committed_env)" = pass ] \
  && ok || bad "B4b: a repo whose only env file is .env.example has no committed env file"

# ---------- B5. npm's placeholder test script is not a test suite -----------
P=$(mk b5 b-ready)
cat > "$P/package.json" <<'JSON'
{"name":"x","private":true,"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}
JSON
report b5 "$P" --no-run
[ "$(st b5 tests.present)" = fail ] \
  && ok || bad "B5: npm's placeholder test script must not count as a test suite (got $(st b5 tests.present))"
[ "$(lvl b5)" -le 1 ] && ok || bad "B5: without a test suite the repo cannot reach level 2 (got $(lvl b5))"

# ---------- B6. a workflow that never runs on a PR --------------------------
W=$(mk b6 b-ready)
cat > "$W/.github/workflows/ci.yml" <<'YML'
name: CI
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: npm test
YML
report b6 "$W" --no-run
[ "$(st b6 ci.workflow)" = fail ] \
  && ok || bad "B6: a push-only workflow puts no check on a PR (got $(st b6 ci.workflow))"
[ "$(lvl b6)" = 2 ] && ok || bad "B6: no PR workflow caps the repo at level 2 (got $(lvl b6))"

# ---------- B6b. a workflow that mentions tests/ but runs none -------------
# Level 3 says "a PR carries a check the merge lanes can read". A `paths:`
# filter names the directory that TRIGGERS the workflow, not a command — and a
# grep for `tests/` anywhere in the file read it as one. The same hole swallows
# an upload-artifact `path: tests/out` and a checkout path.
W=$(mk b6b b-ready)
cat > "$W/.github/workflows/ci.yml" <<'YML'
name: CI
on:
  pull_request:
    paths:
      - 'tests/**'
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo lint only
      - uses: actions/upload-artifact@v4
        with:
          path: tests/out
YML
report b6b "$W" --no-run
[ "$(st b6b ci.workflow)" = fail ] \
  && ok || bad "B6b: a lint-only workflow triggered on tests/** runs no tests (got $(st b6b ci.workflow))"
[ "$(lvl b6b)" = 2 ] && ok || bad "B6b: a workflow that runs no tests caps the repo at level 2 (got $(lvl b6b))"
# And the ordinary multi-line shape still passes: the command sits on a LATER
# line than `run:`, so a check anchored to the `run:` line itself would fail
# almost every real workflow.
cat > "$W/.github/workflows/ci.yml" <<'YML'
name: CI
on:
  pull_request:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: suite
        run: |
          npm ci
          npm test
YML
report b6c "$W" --no-run
[ "$(st b6c ci.workflow)" = pass ] \
  && ok || bad "B6b: a 'run: |' block that calls npm test runs the tests (got $(st b6c ci.workflow))"
# The shell-loop shape this repo's own CI uses.
cat > "$W/.github/workflows/ci.yml" <<'YML'
name: CI
on:
  pull_request:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: |
          for t in tests/*.sh; do bash "$t" || exit 1; done
YML
report b6d "$W" --no-run
[ "$(st b6d ci.workflow)" = pass ] \
  && ok || bad "B6b: a loop that runs tests/*.sh runs the tests (got $(st b6d ci.workflow))"

# ---------- B7. .gitignore: what covers .env and what only looks like it ----
# secrets.gitignore is a LEVEL-2 requirement, so both directions are load-
# bearing: a false fail refuses a repo that is fine, a false pass tells the
# operator the next env file is safe when it is not.
G=$(mk b7 b-ready)
printf '.envrc\nnode_modules/\n' > "$G/.gitignore"
report b7 "$G" --no-run
[ "$(st b7 secrets.gitignore)" = fail ] \
  && ok || bad "B7: an ignore of .envrc does not cover .env (got $(st b7 secrets.gitignore))"
# .env.local ignores one sibling; .env itself is still committable.
printf '.env.local\nnode_modules/\n' > "$G/.gitignore"
report b7b "$G" --no-run
[ "$(st b7b secrets.gitignore)" = fail ] \
  && ok || bad "B7: an ignore of .env.local does not cover .env (got $(st b7b secrets.gitignore))"
# The anchored forms cover exactly the same file as the bare one. `/.env` is one
# of the commonest ways a repo writes this, and grading it `fail` would cap a
# fine repo at level 1 with a message ("the next env file lands in a commit")
# that is simply untrue.
for IGN in '.env' '/.env' '**/.env' '.env*' '/.env*' '*.env'; do
  printf '%s\nnode_modules/\n' "$IGN" > "$G/.gitignore"
  report b7x "$G" --no-run
  [ "$(st b7x secrets.gitignore)" = pass ] \
    && ok || bad "B7: '$IGN' in .gitignore covers .env (got $(st b7x secrets.gitignore))"
done
# CORRECTED ASSERTION (this loop used to include '.env.*' in the pass set).
# git reads the dot after `env` literally: under `.env.*` the bare `.env` is not
# ignored at all — `git -c core.excludesFile=/dev/null check-ignore -v .env`
# lists nothing, while `.env.local` matches. It is `.env.local`'s shape, not
# `.env*`'s, and B7's own second case already grades that fail.
for IGN in '.env.*' '/.env.*' '**/.env.*'; do
  printf '%s\nnode_modules/\n' "$IGN" > "$G/.gitignore"
  report b7y "$G" --no-run
  [ "$(st b7y secrets.gitignore)" = fail ] \
    && ok || bad "B7: '$IGN' does NOT ignore a bare .env (got $(st b7y secrets.gitignore))"
done

# ---------- B8. a documented preview URL instead of vercel.json -------------
V=$(mk b8 b-ready)
rm -f "$V/vercel.json"
report b8v "$V" --no-run
[ "$(st b8v preview.config)" = fail ] \
  && ok || bad "B8: with no preview config at all the check must fail (got $(st b8v preview.config))"
printf '# Fixture\n\nPreview: https://example-git-branch.vercel.app\n' > "$V/README.md"
report b8 "$V" --no-run
[ "$(st b8 preview.config)" = pass ] \
  && ok || bad "B8: a documented preview URL is a preview config (got $(st b8 preview.config))"
# The phrasings a real README actually uses. "Preview deployments:" is the
# ordinary one and it carries an "n" between the word and the URL — the case a
# `[^\n]` bracket expression silently drops, which is why it is asserted here
# and not left to the one wording that happens to dodge it.
for LINE in 'Preview deployments: https://example.vercel.app' \
            'preview environment: https://example.vercel.app' \
            'Preview URL: https://example.vercel.app' \
            '- **Preview:** every branch gets https://example.vercel.app'; do
  printf '# Fixture\n\n%s\n' "$LINE" > "$V/README.md"
  report b8x "$V" --no-run
  [ "$(st b8x preview.config)" = pass ] \
    && ok || bad "B8: '$LINE' is a documented preview URL (got $(st b8x preview.config))"
done
# And a README that mentions neither is still a fail: the widened pattern must
# not turn every repo into a preview repo.
printf '# Fixture\n\nDeploys land on https://example.com after merge.\n' > "$V/README.md"
report b8n "$V" --no-run
[ "$(st b8n preview.config)" = fail ] \
  && ok || bad "B8: a README with no preview line is not a preview config (got $(st b8n preview.config))"

# ---------- B9. a board route instead of label metadata ---------------------
R=$(mk b9 b-ready)
rm -f "$R/.github/labels.yml"
report b9n "$R" --no-run
[ "$(st b9n board.source)" = fail ] \
  && ok || bad "B9: no route and no label metadata is not a board source (got $(st b9n board.source))"
mkdir -p "$R/src/app/api/board"
printf 'export async function GET() {}\n' > "$R/src/app/api/board/route.ts"
report b9 "$R" --no-run
[ "$(st b9 board.source)" = pass ] \
  && ok || bad "B9: an /api/board route is a board source (got $(st b9 board.source))"

# ---------- B10. migrations: na, pass, fail --------------------------------
[ "$(st b2 migrations.appliable)" = na ] \
  && ok || bad "B10: a repo with no migrations dir is 'na', never a failure (got $(st b2 migrations.appliable))"
M=$(mk b10 b-ready); mkdir -p "$M/scripts/migrations"
printf 'CREATE TABLE fixture_rows (id int);\n' > "$M/scripts/migrations/001_add.sql"
report b10 "$M" --no-run
[ "$(st b10 migrations.appliable)" = pass ] \
  && ok || bad "B10: an additive migration is appliable (got $(st b10 migrations.appliable): $(det b10 migrations.appliable))"
printf 'DROP TABLE fixture_rows;\n' > "$M/scripts/migrations/002_drop.sql"
report b10d "$M" --no-run
[ "$(st b10d migrations.appliable)" = fail ] \
  && ok || bad "B10: a DROP the apply endpoint refuses must fail (got $(st b10d migrations.appliable))"
[ "$(lvl b10d)" -le 3 ] && ok || bad "B10: an unappliable migration blocks level 4 (got $(lvl b10d))"
# A prisma/ or supabase/ migrations dir holds SQL the linter cannot read. `pass`
# there was a quiet yes — it satisfied level 4's must_not_fail by silence over a
# directory whose contents were never opened. `unknown` is the honest status,
# and it still does not block (unknown is not fail), so the level is unchanged.
for MD in prisma/migrations supabase/migrations; do
  U=$(mk b10u b-ready); mkdir -p "$U/$MD/20260101000000_init"
  printf 'DROP TABLE users;\n' > "$U/$MD/20260101000000_init/migration.sql"
  report b10u "$U" --no-run
  [ "$(st b10u migrations.appliable)" = unknown ] \
    && ok || bad "B10: $MD is not a shape the linter reads — that is 'unknown', never 'pass' (got $(st b10u migrations.appliable))"
  case "$(det b10u migrations.appliable)" in
    *"NOT graded"*) ok ;; *) bad "B10: the detail must say the SQL was not graded (got '$(det b10u migrations.appliable)')" ;;
  esac
  [ "$(lvl b10u)" = 4 ] && ok || bad "B10: 'unknown' does not block level 4 the way 'fail' does (got $(lvl b10u))"
done

# ---------- B11. the info-only context rows are reported, never required ----
I=$(mk b11 b-ready); mkdir -p "$I/.codegraph" "$I/.factory"
report b11 "$I" --no-run
[ "$(st b11 context.codegraph)" = pass ] && ok || bad "B11: a .codegraph/ index must be reported"
[ "$(st b11 context.conventions)" = pass ] && ok || bad "B11: .factory/ conventions must be reported"
[ "$(st b2 context.codegraph)" = fail ] && ok || bad "B11: no index is a fail row, so the report stays honest"
jq -e '[.gaps[] | select(.check=="context.codegraph" or .check=="context.conventions")] | length == 0' \
  "$T/b2.json" >/dev/null 2>&1 \
  && ok || bad "B11: an info-only row must never appear as a gap — no level requires it"

# ---------- B12. stack detection -------------------------------------------
[ "$(jq -r '.stack.framework' "$T/b2.json")" = unknown ] \
  && ok || bad "B12: a repo with no framework marker is 'unknown' (got $(jq -r .stack.framework "$T/b2.json"))"
[ "$(jq -r '.stack.adapters' "$T/b2.json")" = not-yet ] \
  && ok || bad "B12: the stack adapters say 'not-yet' for a stack nothing was written against"
N=$(mk b12 b-ready); printf 'module.exports = {};\n' > "$N/next.config.js"
report b12 "$N" --no-run
[ "$(jq -r '.stack.framework' "$T/b12.json")" = next ] \
  && ok || bad "B12: next.config.js is a Next.js repo (got $(jq -r .stack.framework "$T/b12.json"))"
[ "$(jq -r '.stack.adapters' "$T/b12.json")" = supported ] \
  && ok || bad "B12: Next.js is the stack the deploy-verify and preview QA lanes were written against"
[ "$(jq -r '.stack.files' "$T/b12.json")" -ge 1 ] && ok || bad "B12: the file count must be a real count"
[ -n "$(jq -r '.stack.language' "$T/b12.json")" ] && ok || bad "B12: the primary language must be reported"

# ---------- B13. deterministic: no model is called -------------------------
# "no LLM" is the ticket's word and this is what makes it true rather than
# intended: a stub `claude` and a stub `agent-call.sh` that would leave a marker
# behind if anything reached for them.
mkdir -p "$T/llmbin"
for f in claude agent-call.sh codex; do
  printf '#!/bin/bash\ntouch "%s/llm-called"\nexit 0\n' "$T" > "$T/llmbin/$f"
  chmod +x "$T/llmbin/$f"
done
rm -f "$T/llm-called"
PATH="$T/llmbin:$PATH" HARNESS="$T/h" bash "$RR" "$C" --no-run >/dev/null 2>&1
[ -f "$T/llm-called" ] && bad "B13: the report called a model — it must be deterministic" || ok

# ---------- C. the bounded test run -----------------------------------------
# The stub npm is the production entry point for "did it actually run the repo's
# suite": C1 proves --no-run never reaches it, C2 proves the default DOES.
cat > "$T/bin/npm" <<STUB
#!/bin/bash
touch "$T/npm-called"
echo "stub npm: \$*"
echo "3 failing"
exit 1
STUB
chmod +x "$T/bin/npm"

rm -f "$T/npm-called"
PATH="$T/bin:$PATH" report c1 "$B" --no-run
[ -f "$T/npm-called" ] && bad "C1: --no-run must never execute the repo's test script" || ok
[ "$(st c1 tests.green)" = skipped ] && ok || bad "C1: --no-run records skipped (got $(st c1 tests.green))"
[ "$(jq -r '.ran_tests' "$T/c1.json")" = false ] && ok || bad "C1: ran_tests must be false under --no-run"

rm -f "$T/npm-called"
PATH="$T/bin:$PATH" report c2 "$B"
[ -f "$T/npm-called" ] && ok || bad "C2: without --no-run the repo's own test script must actually run"
[ "$(st c2 tests.green)" = fail ] && ok || bad "C2: a runner that exits non-zero is a fail (got $(st c2 tests.green))"
case "$(det c2 tests.green)" in *failing*) ok ;; *) bad "C2: the detail must carry the runner's own last lines (got '$(det c2 tests.green)')" ;; esac
[ "$(jq -r '.ran_tests' "$T/c2.json")" = true ] && ok || bad "C2: ran_tests must be true when the runner ran"
[ "$(lvl c2)" = 3 ] && ok || bad "C2: a red suite blocks level 4 and nothing below it (got $(lvl c2))"

cat > "$T/bin/npm" <<STUB
#!/bin/bash
touch "$T/npm-called"
sleep 30  # determinism: ok — not a wait: this stub must never finish. The report
          # runs it under \`timeout \$READINESS_TEST_TIMEOUT\` (1s below), and the
          # assertion is on the KILL. It was 1.5s, which raced the 1s budget on a
          # loaded box; 30 puts the outcome beyond any scheduling delay.
exit 0
STUB
chmod +x "$T/bin/npm"
PATH="$T/bin:$PATH" READINESS_TEST_TIMEOUT=1 report c3 "$B"
[ "$(st c3 tests.green)" = fail ] \
  && ok || bad "C3: a suite that outruns the budget is a fail, never an unknown (got $(st c3 tests.green))"
case "$(det c3 tests.green)" in *"timed out after 1s"*) ok ;; *) bad "C3: the detail must say it timed out (got '$(det c3 tests.green)')" ;; esac
rm -f "$T/bin/npm"

# ---------- D. the gh-backed probes fail OPEN -------------------------------
cat > "$T/bin/gh" <<STUB
#!/bin/bash
echo "gh \$*" >> "$T/gh-log"
exit 1
STUB
chmod +x "$T/bin/gh"
GHR=$(mk d1 b-ready)
git -C "$GHR" init -q
git -C "$GHR" remote add origin https://github.com/acme/x.git

rm -f "$T/gh-log"
PATH="$T/bin:$PATH" READINESS_GH=0 report d1 "$GHR" --no-run
[ "$(st d1 ci.branch_protection)" = skipped ] \
  && ok || bad "D1: READINESS_GH=0 must skip the API probe (got $(st d1 ci.branch_protection))"
[ -f "$T/gh-log" ] && bad "D1: READINESS_GH=0 must not call gh at all" || ok

rm -f "$T/gh-log"
PATH="$T/bin:$PATH" report d2 "$GHR" --no-run
[ "$(st d2 ci.branch_protection)" = unknown ] \
  && ok || bad "D2: a gh that cannot answer is unknown, never a fail (got $(st d2 ci.branch_protection))"
[ -s "$T/gh-log" ] && ok || bad "D2: with a remote and gh on PATH the probe must be attempted"
[ "$(lvl d2)" = 4 ] && ok || bad "D2: an unknown must not cost the repo a level (got $(lvl d2))"

cat > "$T/bin/gh" <<STUB
#!/bin/bash
echo "gh \$*" >> "$T/gh-log"
case "\$*" in
  *protection*) echo "gh: Branch not protected (HTTP 404)" >&2; exit 1 ;;
  *label*)      echo "ai-build" ;;
  *)            echo "main" ;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"
rm -f "$T/gh-log"
PATH="$T/bin:$PATH" report d3 "$GHR" --no-run
[ "$(st d3 ci.branch_protection)" = fail ] \
  && ok || bad "D3: a 404 from the protection API means the branch is not protected (got $(st d3 ci.branch_protection))"
[ "$(lvl d3)" = 3 ] && ok || bad "D3: an unprotected default branch blocks level 4 (got $(lvl d3))"

# ---------- D4. a bare 404 is NOT an answer about protection ----------------
# GitHub answers 404 "Not Found" when the token cannot SEE the repo, not only
# when the branch is unprotected. Reading that as `fail` would cost a repo a
# level for the state of the machine running the report — the same fail-open
# rule D2 asserts for a gh that cannot answer at all. Only the phrase GitHub
# uses for the real answer, "Branch not protected", is a fail.
cat > "$T/bin/gh" <<STUB
#!/bin/bash
echo "gh \$*" >> "$T/gh-log"
case "\$*" in
  *protection*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *label*)      echo "ai-build" ;;
  *)            echo "main" ;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"
rm -f "$T/gh-log"
PATH="$T/bin:$PATH" report d4 "$GHR" --no-run
[ "$(st d4 ci.branch_protection)" = unknown ] \
  && ok || bad "D4: a bare 404 says nothing about protection — unknown, never fail (got $(st d4 ci.branch_protection))"
[ "$(lvl d4)" = 4 ] && ok || bad "D4: an unknown must not cost the repo a level (got $(lvl d4))"
rm -f "$T/bin/gh"

# ---------- E1. the documented JSON shape ----------------------------------
python3 - "$T/b2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
need = {"schema","repo","slug","level","max_level","levels_source","ran_tests","checks","gaps","stack"}
missing = need - set(d)
assert not missing, f"missing keys: {sorted(missing)}"
assert d["schema"] == 1, d["schema"]
assert isinstance(d["ran_tests"], bool), d["ran_tests"]
assert 0 <= d["level"] <= d["max_level"], (d["level"], d["max_level"])
ids = set()
for c in d["checks"]:
    assert set(c) == {"id","group","status","detail"}, sorted(c)
    assert c["status"] in {"pass","fail","unknown","skipped","na"}, c
    assert isinstance(c["detail"], str), c
    ids.add(c["id"])
levels = [g["level"] for g in d["gaps"]]
assert levels == sorted(levels), levels
for g in d["gaps"]:
    assert set(g) == {"level","check","status","detail"}, sorted(g)
    assert g["check"] in ids, g
    assert g["status"] != "pass", g
    assert 1 <= g["level"] <= d["max_level"], g
assert set(d["stack"]) == {"files","language","framework","adapters"}, sorted(d["stack"])
assert isinstance(d["stack"]["files"], int), d["stack"]
assert isinstance(d["slug"], str), d["slug"]
PY
[ $? = 0 ] && ok || bad "E1: --json must match the shape documented in docs/READINESS.md"

# ---------- E2. the table, and its last line -------------------------------
HARNESS="$T/h" bash "$RR" "$B" --no-run > "$T/e2.table" 2>&1
[ "$(tail -1 "$T/e2.table")" = "READINESS LEVEL: 4/5" ] \
  && ok || bad "E2: the last line of the table is the level (got '$(tail -1 "$T/e2.table")')"
grep -q 'tests.present' "$T/e2.table" && ok || bad "E2: the table must list the checks by id"
grep -q 'READINESS LEVEL' "$T/e2.table" && ok || bad "E2: the table must state the level"

# ---------- E3. usage errors -----------------------------------------------
HARNESS="$T/h" bash "$RR" >"$T/e3.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "E3: no repo dir is a usage error (rc $RC)"
HARNESS="$T/h" bash "$RR" "$T/no-such-checkout" >"$T/e3b.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "E3: an unreadable repo dir is rc 2, never a level 0 report (rc $RC)"
HARNESS="$T/h" bash "$RR" "$B" --nope >"$T/e3c.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "E3: an unknown flag is a usage error (rc $RC)"

echo "readiness-report-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
