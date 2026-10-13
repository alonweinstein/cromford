#!/bin/bash
# tests/scope-gate-test.sh — SDLC item 4: did this build change files the plan
# never named, and does anything downstream know?
#
# The hole this closes: prompts/plan-contract.md has always said "needing a file
# outside scope = stop and report, never improvise", and nothing checked it. A
# builder could reach into .github/workflows, a lockfile or prisma/ on a ticket
# that named none of them and the diff arrived at a paid reviewer as one more
# file among twenty. TK-70 was exactly that shape.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q scope-gate bin/run-build.sh` passes on a
# classifier that calls everything foreign, on a demoter wired to the wrong
# default, and on a gate that reports "in-scope" for a plan that named no files
# at all. What is under test is the classification, the protected set, the
# warn-first switch, and that the verdict reaches the reviewer, the tier note
# and the ledger row in the shape their readers expect.
#
# The run-build blocks are extracted VERBATIM by their markers, so a regression
# in the shipped lines fails here rather than in a paraphrase. No network, no
# model call, no secrets: git fixtures on disk, curl and the ledger stubbed.
# Run from anywhere: tests/scope-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/logs" "$T/stub" "$T/bin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "git missing — skipping"; exit 0; }

GATE="$DIR/bin/scope-gate.sh"
[ -x "$GATE" ] && ok || bad "bin/scope-gate.sh is missing or not executable"

# ============================================================================
# 1. bin/scope-gate.sh — the classifier, against a real git diff
# ============================================================================
# One repo, rebuilt per case: the gate reads a diff, so a fixture that fakes the
# diff would test a different program than the pipeline runs.
# The build dir lives OUTSIDE the repo: planned-files.txt inside the worktree
# would show up in the diff it is being used to score.
mkrepo() { # mkrepo <name> ; echoes "<repo> <base-sha>"
  local r="$T/$1/repo"; rm -rf "$T/$1"; mkdir -p "$r/src/lib" "$T/$1/b"
  ( cd "$r" || exit 1
    git init -q .
    git config user.email t@example.com; git config user.name t
    echo one > src/lib/one.ts
    git add -A >/dev/null; git commit -qm base ) >/dev/null 2>&1
  printf '%s %s' "$r" "$(cd "$r" && git rev-parse HEAD)"
}
add() { # add <repo> <path> — a changed file in the working tree
  mkdir -p "$1/$(dirname "$2")" 2>/dev/null
  echo change >> "$1/$2"
}
commit() { ( cd "$1" && git add -A >/dev/null && git commit -qm work ) >/dev/null 2>&1; }
bdir() { printf '%s' "${1%/repo}/b"; }   # the build dir beside a fixture repo
plan() { # plan <repo> <entries...>
  printf '%s\n' "${@:2}" > "$(bdir "$1")/planned-files.txt"
}
# Sets G (the report) and GRC (the exit code). Deliberately NOT `G=$(gate ...)`:
# the rc would be assigned in the subshell and never come back.
gate() { # gate <repo> <base> [env...]
  local r="$1" base="$2"; shift 2
  G=$(env "$@" "$GATE" "$(bdir "$r")" "$base" "$r" 2>&1); GRC=$?
}
counts() { sed -n 's/^SCOPE_COUNTS:[[:space:]]*//p' <<<"$1"; }
field()  { grep -oE "(^| )$2=[0-9]+" <<<"$(counts "$1")" | tr -d ' ' | cut -d= -f2; }

# 1a. every changed file was planned -> in-scope, rc 0.
read -r R B <<<"$(mkrepo clean)"
plan "$R" src/lib/one.ts
add "$R" src/lib/one.ts; commit "$R"
gate "$R" "$B"
[ "$GRC" = 0 ] && ok || bad "a diff inside the plan must be rc 0 (got $GRC: $G)"
grep -q 'SCOPE_VERDICT: in-scope' <<<"$G" && ok || bad "a planned diff must read in-scope (got: $G)"
[ "$(field "$G" unplanned)" = 0 ] && ok || bad "a planned diff counted unplanned files: $(counts "$G")"

# 1b. a planned DIRECTORY scope covers the files under it. planned-files.sh
#     emits both shapes, so a gate that only matched exact paths would call a
#     whole planned directory foreign.
read -r R B <<<"$(mkrepo dirscope)"
plan "$R" src/lib/feature
add "$R" src/lib/feature/a.ts; add "$R" src/lib/feature/deep/b.ts; commit "$R"
gate "$R" "$B"
[ "$GRC" = 0 ] && ok || bad "a planned directory scope must cover its files (got $GRC: $G)"

# 1c. the four classes, one diff. Each exists because most unplanned files are
#     not creep, and a gate that counted them all the same would demote the
#     fleet for writing tests and docs.
read -r R B <<<"$(mkrepo classes)"
plan "$R" src/lib/one.ts
add "$R" src/lib/one.ts
add "$R" src/lib/neighbour.ts          # adjacent — the plan named this directory
add "$R" tests/feature.test.ts         # test
add "$R" docs/how-it-works.md          # spec
add "$R" src/elsewhere/far.ts          # foreign
commit "$R"
gate "$R" "$B"
[ "$GRC" = 2 ] && ok || bad "unplanned-but-unprotected must be rc 2 (got $GRC: $G)"
grep -q 'SCOPE_VERDICT: unplanned' <<<"$G" && ok || bad "rc 2 must read 'unplanned' (got: $G)"
[ "$(field "$G" adjacent)" = 1 ] && ok || bad "a sibling in a planned dir is adjacent: $(counts "$G")"
[ "$(field "$G" test)" = 1 ]     && ok || bad "a test file must classify as test: $(counts "$G")"
[ "$(field "$G" spec)" = 1 ]     && ok || bad "a markdown file must classify as spec: $(counts "$G")"
[ "$(field "$G" foreign)" = 1 ]  && ok || bad "an unrelated file must classify as foreign: $(counts "$G")"
[ "$(field "$G" unplanned)" = 4 ] && ok || bad "the unplanned total must be the four: $(counts "$G")"
[ "$(field "$G" protected)" = 0 ] && ok || bad "nothing here is protected: $(counts "$G")"
grep -q '\[foreign\] src/elsewhere/far.ts' <<<"$G" && ok || bad "the listing must name the foreign file (got: $G)"
grep -q 'SCOPE_PROTECTED:' <<<"$G" && bad "no protected file, so no SCOPE_PROTECTED line (got: $G)" || ok

# 1d. the protected set — the only class that can move a tier.
for P in .github/workflows/ci.yml package.json pnpm-lock.yaml prisma/schema.prisma .env.production src/.env; do
  read -r R B <<<"$(mkrepo "prot-$(basename "$P")")"
  plan "$R" src/lib/one.ts
  add "$R" src/lib/one.ts; add "$R" "$P"; commit "$R"
  gate "$R" "$B"
  [ "$GRC" = 1 ] || bad "$P must reach the protected verdict (got $GRC: $G)"
  grep -q 'SCOPE_VERDICT: protected' <<<"$G" || bad "$P did not read protected (got: $G)"
  grep -q "SCOPE_PROTECTED: .*$P" <<<"$G" || bad "$P must be named on the SCOPE_PROTECTED line (got: $G)"
  # protected is a SUBSET of foreign, never a fifth bucket the counts hide.
  [ "$(field "$G" foreign)" -ge 1 ] || bad "$P must also count as foreign: $(counts "$G")"
done
ok

# 1d-ii. THE OTHER HALF OF "unplanned AND protected": a manifest, workflow or env
#     file the plan NAMED is not a surprise, and must not read as one.
#     bin/planned-files.sh keeps only paths under src|prisma|scripts|… so it
#     drops package.json, .github/workflows/*.yml and .env* no matter what the
#     plan says — which is why the gate re-scrapes plan.md for those families.
#     Driven through the REAL scraper, not a hand-written planned-files.txt: the
#     hand-written fixture is exactly what hid this.
read -r R B <<<"$(mkrepo prot-planned)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
Bump the dependency in package.json (and pnpm-lock.yaml), add the CI step in
.github/workflows/ci.yml, set the flag in .env.production, and wire it up in
src/lib/one.ts.
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
grep -q 'package.json' "$(bdir "$R")/planned-files.txt" \
  && bad "planned-files.sh started keeping manifests — the gate's re-scrape needs revisiting" || ok
# …and a `./`-prefixed path is the same file: bin/planned-files.sh strips the
# prefix, so a plan that writes `./package.json` must not read as a protected
# surprise here just because the token kept two extra characters.
read -r RD BD <<<"$(mkrepo prot-dotslash)"
# (`./src/...` is dropped by bin/planned-files.sh own anchored grep, which runs
# before its `./` strip — pre-existing there, and not this gate to fix, so the
# fixture names the src path plainly and tests the manifest half.)
printf 'Bump ./package.json and edit src/lib/one.ts.\n' > "$(bdir "$RD")/plan.md"
"$DIR/bin/planned-files.sh" "$(bdir "$RD")"
add "$RD" package.json; commit "$RD"
gate "$RD" "$BD"
[ "$GRC" = 0 ] && ok || bad "a ./-prefixed plan path must plan the same file (got $GRC: $G)"

add "$R" src/lib/one.ts; add "$R" package.json; add "$R" pnpm-lock.yaml
add "$R" .github/workflows/ci.yml; add "$R" .env.production; commit "$R"
gate "$R" "$B"
[ "$GRC" = 0 ] && ok || bad "protected files the plan NAMED must not read as unplanned (got $GRC: $G)"
[ "$(field "$G" protected)" = 0 ] && ok || bad "the plan named all of them: $(counts "$G")"
grep -q 'SCOPE_PROTECTED:' <<<"$G" && bad "nothing was unplanned, so no SCOPE_PROTECTED line (got: $G)" || ok
# …and the scrape is a plan reader, not a blanket exemption: an UNnamed manifest
# in the same build is still protected.
add "$R" yarn.lock; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "a manifest the plan never named is still protected (got $GRC: $G)"
grep -q 'SCOPE_PROTECTED: yarn.lock' <<<"$G" && ok || bad "only the unnamed manifest is protected (got: $G)"

# 1d-iii. prose must not be over-read: "mypackage.json" is not package.json.
read -r R B <<<"$(mkrepo prot-prose)"
printf 'Rename mypackage.json in src/lib/one.ts. Nothing else.\n' > "$(bdir "$R")/plan.md"
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" package.json; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "a lookalike word in prose must not exempt the real manifest (got $GRC: $G)"

# 1d-iv. THE NON-GOAL SENTENCE. prompts/plan-contract.md:19 REQUIRES every
#     sub-ticket to carry non-goals, so "do not modify package.json or the CI
#     workflows" is the SHAPE THE CONTRACT ASKS FOR — and a context-free scrape
#     read it as the plan naming those files, exempting exactly the class that
#     moves a tier. Two causes, one case each.
read -r R B <<<"$(mkrepo prot-negated)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
Edit src/lib/one.ts.

Non-goals: do not modify package.json, and never touch .github/workflows/ci.yml.
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" package.json; add "$R" .github/workflows/ci.yml; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "a 'do not touch' line must not exempt the file it forbids (got $GRC: $G)"
grep -q 'SCOPE_PROTECTED: .*package.json' <<<"$G" \
  && ok || bad "the forbidden manifest must be named protected (got: $G)"
grep -q 'SCOPE_PROTECTED: .*\.github/workflows/ci\.yml' <<<"$G" \
  && ok || bad "the forbidden workflow must be named protected (got: $G)"
[ "$(field "$G" protected)" = 2 ] && ok || bad "both must be protected: $(counts "$G")"

# …and a BARE directory mention is not a scope. "we will not go near
# .github/workflows" (or even a positive "see .github/workflows") names no file,
# and letting it plan the whole directory exempts every workflow at once.
read -r R B <<<"$(mkrepo prot-baredir)"
printf 'Wire it up in src/lib/one.ts; see .github/workflows for context.\n' > "$(bdir "$R")/plan.md"
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" .github/workflows/deploy.yml; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "a bare workflows DIRECTORY must not plan every workflow file (got $GRC: $G)"
grep -q 'SCOPE_PROTECTED: .*deploy\.yml' <<<"$G" && ok || bad "the workflow must still be protected (got: $G)"

# 1d-v. the env pattern is anchored: `.env` and `.env.production` are secrets
#     files, `.envrc` and `.environment.ts` are code. Demoting a build for a
#     TypeScript module whose name starts with the same four letters would burn
#     the gate's credibility on its first false positive.
read -r R B <<<"$(mkrepo env-lookalike)"
plan "$R" src/lib/one.ts
add "$R" src/lib/.environment.ts; add "$R" src/lib/.envrc; commit "$R"
gate "$R" "$B"
[ "$GRC" = 2 ] && ok || bad ".envrc/.environment.ts must not be protected (got $GRC: $G)"
[ "$(field "$G" protected)" = 0 ] && ok || bad "no secrets file was touched: $(counts "$G")"
add "$R" src/.env; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "the real env file is still protected (got $GRC: $G)"
grep -q 'SCOPE_PROTECTED: src/.env' <<<"$G" && ok || bad "only the real env file is protected (got: $G)"

# 1d-vi. THE NON-GOAL SENTENCE, THE OTHER TWO FAMILIES. bin/planned-files.sh
#     scrapes every prisma/*.prisma and scripts/migrations/* token no matter
#     which sentence it sits in, so "Do not touch prisma/schema.prisma" landed
#     in planned-files.txt and the gate read a schema change as PLANNED —
#     in-scope, the worst possible answer, on real plan text from this box.
read -r R B <<<"$(mkrepo prot-negated-prisma)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
Edit src/lib/one.ts. Do not touch prisma/schema.prisma or scripts/migrations.
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
grep -q 'prisma/schema.prisma' "$(bdir "$R")/planned-files.txt" \
  && ok || bad "the scraper stopped keeping the forbidden prisma path — this case no longer tests anything"
add "$R" prisma/schema.prisma; add "$R" scripts/migrations/2026-09-06-x.sql; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "a 'do not touch prisma' line must not plan the schema (got $GRC: $G)"
[ "$(field "$G" protected)" = 2 ] && ok || bad "both forbidden files must be protected: $(counts "$G")"
grep -q 'SCOPE_PROTECTED: .*prisma/schema.prisma' <<<"$G" \
  && ok || bad "the forbidden schema must be named protected (got: $G)"
# …and the same sentence must not un-protect the migrations directory either:
# a "leave scripts/migrations/2026-07-17-x.sql alone" plan names no migration.
read -r R B <<<"$(mkrepo mig-negated)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
Edit src/lib/one.ts; leave scripts/migrations/2026-07-17-x.sql alone.
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" scripts/migrations/2026-09-06-new.sql; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "an excluded migration must not make the directory planned territory (got $GRC: $G)"

# 1d-vii. AND THE FALSE POSITIVE THE OTHER WAY. prompts/plan-contract.md makes
#     planners write the caveat NEXT TO the file they are planning: "append the
#     runner to package.json. Never delete or reorder any entry" is ONE line
#     that plans the manifest — and a line-level exclusion filter dropped it,
#     so the build was flagged (and, armed, demoted) for doing what it was
#     asked. Word-anchored, sentence-level filtering is what keeps this
#     in-scope.
read -r R B <<<"$(mkrepo prot-caveat)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
2. **package.json** — append the new runner to the test:notify line, and wire it up in src/lib/one.ts. Never delete, reorder, or weaken any entry.
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" src/lib/one.ts; add "$R" package.json; commit "$R"
gate "$R" "$B"
[ "$GRC" = 0 ] && ok || bad "a planned manifest with a mandated caveat must stay in-scope (got $GRC: $G)"
[ "$(field "$G" protected)" = 0 ] && ok || bad "the plan named the manifest: $(counts "$G")"
# …and the words are matched as WORDS: "whenever" is not "never", "donate" is
# not "don't". A plan sentence that happens to contain one must not lose the
# file it names.
read -r R B <<<"$(mkrepo prot-wordish)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
Whenever the donate flow changes, bump package.json and edit src/lib/one.ts.
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" src/lib/one.ts; add "$R" package.json; commit "$R"
gate "$R" "$B"
[ "$GRC" = 0 ] && ok || bad "'whenever'/'donate' must not read as exclusion words (got $GRC: $G)"

# 1d-viii. THE WRAPPED NON-GOAL. plan.md is hard-wrapped markdown, so the real
#     shape of the sentence 1d-vi tests spans three lines and left its exclusion
#     word on the first one — the continuation lines then read as the plan
#     NAMING the files it forbids. Modelled on a plan from this box
#     (builds/fly-project-2-TK-86-20260803033004/plan.md:214): the schema
#     read `planned`/in-scope and the excluded migration set MIG_PLANNED, so an
#     unplanned migration read `adjacent` — the worst answer, from the sentence
#     that forbade it, with no SCOPE_PROTECTED line for the reviewer.
read -r R B <<<"$(mkrepo prot-wrapped)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
Edit src/lib/one.ts.

NOT touched (explicit non-goals per the ticket): the live-coach lane, its migration
`scripts/migrations/2026-07-20-live-coach.sql`, or `prisma/schema.prisma` (TK-82
owns the alias), the rubric weights, or the portal bell.
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" src/lib/one.ts; add "$R" prisma/schema.prisma
add "$R" scripts/migrations/2026-09-06-new.sql; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "a WRAPPED non-goal sentence must not plan the files it forbids (got $GRC: $G)"
[ "$(field "$G" protected)" = 2 ] && ok || bad "both the schema and the unplanned migration are protected: $(counts "$G")"
grep -q 'SCOPE_PROTECTED: .*prisma/schema.prisma' <<<"$G" \
  && ok || bad "the forbidden schema must be named protected (got: $G)"
grep -q 'SCOPE_PROTECTED: .*scripts/migrations/2026-09-06-new.sql' <<<"$G" \
  && ok || bad "the excluded migration must not make the directory planned territory (got: $G)"
# …and the unwrapping is CONTINUATION-level, not paragraph-level: one bullet's
# non-goal must not swallow the sibling bullet that plans a file. Folding a
# whole paragraph together would re-open 1d-vii in list form, where every plan
# on this box writes its files.
read -r R B <<<"$(mkrepo prot-bullets)"
cat > "$(bdir "$R")/plan.md" <<'PLANEOF'
Files:
- `package.json` — append the runner to the test:notify line, and wire up
  src/lib/one.ts
- Non-goals: do not touch `prisma/schema.prisma`
PLANEOF
"$DIR/bin/planned-files.sh" "$(bdir "$R")"
add "$R" src/lib/one.ts; add "$R" package.json; commit "$R"
gate "$R" "$B"
[ "$GRC" = 0 ] && ok || bad "a sibling bullet's non-goal must not un-plan this bullet's manifest (got $GRC: $G)"
[ "$(field "$G" protected)" = 0 ] && ok || bad "the bullet named the manifest: $(counts "$G")"
add "$R" prisma/schema.prisma; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "the non-goal bullet still forbids the schema (got $GRC: $G)"

# 1d-ix. A MANIFEST INSIDE A TEST DIRECTORY IS A FIXTURE. The manifest rule runs
#     before the test rule, so tests/fixtures/package.json read `protected` and,
#     once armed, would demote a build for adding a test fixture — the gate
#     firing on the discipline it exists to reward.
read -r R B <<<"$(mkrepo fixture-manifest)"
plan "$R" src/lib/one.ts
add "$R" src/lib/one.ts; add "$R" tests/fixtures/package.json
add "$R" e2e/fixtures/pnpm-lock.yaml; commit "$R"
gate "$R" "$B"
[ "$GRC" = 2 ] && ok || bad "a manifest under a test dir is a fixture, not a protected surprise (got $GRC: $G)"
[ "$(field "$G" protected)" = 0 ] && ok || bad "no real manifest was touched: $(counts "$G")"
[ "$(field "$G" test)" = 2 ] && ok || bad "both fixtures must classify as test: $(counts "$G")"
# …and the excuse is the manifest family ONLY: a workflow, a prisma/ path or an
# env file is dangerous wherever it sits, test directory included.
add "$R" tests/fixtures/.env; add "$R" .github/workflows/fixture.yml; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "an env file under a test dir is still protected (got $GRC: $G)"
grep -q 'SCOPE_PROTECTED: .*tests/fixtures/\.env' <<<"$G" \
  && ok || bad "the fixture env file must be named protected (got: $G)"

# 1e. scripts/migrations is protected ONLY when the plan named no migration —
#     a planned migration wave obviously writes there, and demoting it would
#     make the gate fire on exactly the work it was told about.
read -r R B <<<"$(mkrepo mig-unplanned)"
plan "$R" src/lib/one.ts
add "$R" scripts/migrations/2026-09-06-x.sql; commit "$R"
gate "$R" "$B"
[ "$GRC" = 1 ] && ok || bad "an unplanned migration must be protected (got $GRC: $G)"
read -r R B <<<"$(mkrepo mig-planned)"
plan "$R" src/lib/one.ts scripts/migrations/2026-09-06-x.sql
add "$R" scripts/migrations/2026-09-06-x.sql; add "$R" scripts/migrations/2026-09-06-y.sql; commit "$R"
gate "$R" "$B"
[ "$GRC" = 2 ] && ok || bad "a planned migration wave must not trip the protected set (got $GRC: $G)"
[ "$(field "$G" protected)" = 0 ] && ok || bad "the sibling migration must not be protected: $(counts "$G")"

# 1f. the pipeline's own spec commit is not the builder reaching outside its
#     plan — the same exclusion bin/evidence-summary.sh makes.
read -r R B <<<"$(mkrepo spec-artifact)"
plan "$R" src/lib/one.ts
add "$R" src/lib/one.ts; add "$R" .harness/specs/WD-9.md; commit "$R"
gate "$R" "$B"
[ "$GRC" = 0 ] && ok || bad "the harness spec artifact must not count as unplanned (got $GRC: $G)"
# …and a diff of NOTHING BUT the spec artifact is the empty-diff answer, not a
# pass: the builder changed nothing this gate can judge, so `changed=0` must
# never render as "the diff stayed in scope".
read -r R B <<<"$(mkrepo spec-only)"
plan "$R" src/lib/one.ts
add "$R" .harness/specs/WD-9.md; commit "$R"
gate "$R" "$B"
[ "$GRC" = 3 ] && ok || bad "a spec-only diff must be rc 3 (got $GRC: $G)"
grep -q 'in-scope' <<<"$G" && bad "a spec-only diff must never read in-scope (got: $G)" || ok
grep -q 'SCOPE_VERDICT: unavailable' <<<"$G" && ok || bad "a spec-only diff must read unavailable (got: $G)"

# 1g. NO PLAN, NO VERDICT. Every changed file would score unplanned, so a gate
#     that scored it would demote builds for the PLANNER's silence.
read -r R B <<<"$(mkrepo noplan)"
: > "$(bdir "$R")/planned-files.txt"
add "$R" src/lib/one.ts; commit "$R"
gate "$R" "$B"
[ "$GRC" = 3 ] && ok || bad "an empty plan file list must be rc 3 (got $GRC: $G)"
grep -q 'SCOPE_VERDICT: unavailable' <<<"$G" && ok || bad "rc 3 must read unavailable (got: $G)"
grep -q 'in-scope' <<<"$G" && bad "an unrunnable gate must never read as in-scope (got: $G)" || ok
rm -f "$(bdir "$R")/planned-files.txt"
gate "$R" "$B"
[ "$GRC" = 3 ] && ok || bad "an ABSENT plan file list must be rc 3 (got $GRC: $G)"

# 1h. an unresolvable base, a missing build dir and no diff are all rc 3 — the
#     gate says it could not run rather than inventing a verdict.
read -r R B <<<"$(mkrepo nobase)"
plan "$R" src/lib/one.ts
add "$R" src/lib/one.ts; commit "$R"
gate "$R" deadbeefdeadbeef
[ "$GRC" = 3 ] && ok || bad "an unresolvable base must be rc 3 (got $GRC: $G)"
G=$(env "$GATE" "$T/nope" "$B" "$R" 2>&1); GRC=$?
[ "$GRC" = 3 ] && ok || bad "a missing build dir must be rc 3 (got $GRC: $G)"
read -r R B <<<"$(mkrepo nodiff)"
plan "$R" src/lib/one.ts
gate "$R" "$B"
[ "$GRC" = 3 ] && ok || bad "an empty diff must be rc 3, not a claim of in-scope (got $GRC: $G)"

# 1i. the listing is bounded, the counts never are. A 400-file rebase must not
#     flood the review prompt, and must not lie about how big it was either.
read -r R B <<<"$(mkrepo bounded)"
plan "$R" src/lib/one.ts
for i in 1 2 3 4 5 6; do add "$R" "src/elsewhere/f$i.ts"; done
commit "$R"
gate "$R" "$B" SCOPE_GATE_MAX_LIST=2
[ "$(field "$G" unplanned)" = 6 ] && ok || bad "the count was truncated with the listing: $(counts "$G")"
[ "$(grep -c '^  \[' <<<"$G")" = 2 ] && ok || bad "SCOPE_GATE_MAX_LIST=2 did not bound the listing (got: $G)"
grep -q 'and 4 more' <<<"$G" && ok || bad "the truncated listing must say how many it dropped (got: $G)"
gate "$R" "$B" SCOPE_GATE_MAX_LIST=banana
[ "$(grep -c '^  \[' <<<"$G")" = 6 ] && ok || bad "a junk list cap must fall back to the documented 12 (got: $G)"

# 1j. NEVER BUILD A COMMAND STRING FROM A FILENAME. The paths come from a diff
#     written by a builder steered by client-authored ticket text, and this runs
#     as root.
read -r R B <<<"$(mkrepo injection)"
plan "$R" src/lib/one.ts
add "$R" 'src/x;touch $T/pwned.ts'
add "$R" 'src/$(touch pwned2).ts'
commit "$R"
gate "$R" "$B"
[ "$GRC" = 2 ] && ok || bad "a hostile filename must still be classified (got $GRC: $G)"
{ [ ! -e "$T/pwned.ts" ] && [ ! -e "$R/pwned2" ] && [ ! -e "pwned2" ]; } \
  && ok || bad "a filename from the diff was executed"

# ============================================================================
# 2. bin/run-build.sh — the gate block reports, and never blocks
# ============================================================================
awk '/^# >>> mechanical gates/{f=1;next} /^# <<< mechanical gates/{exit} f' \
  "$RB_ALL" > "$T/gates.sh"
[ -s "$T/gates.sh" ] && ok || bad "could not extract the mechanical-gates block — markers missing?"
grep -q 'scope-gate.sh' "$T/gates.sh" && ok || bad "the scope gate is not wired into the gates block"

mkstub() { printf '#!/bin/bash\necho "%s"\nexit %s\n' "$2" "$1" > "$T/bin/$3"; chmod +x "$T/bin/$3"; }
mkstub 0 "TAMPER_COUNT: 0
BLOCKING_COUNT: 0" test-tamper-scan.sh
mkstub 0 "REPRO_REPORT_0" repro-gate.sh
mkstub 0 "INTENT_VERDICT: agree" intent-gate.sh

run_gates() { # run_gates <scope-rc> <scope-report> -> "<exit> <RESULT-or-none>"
  mkstub "$1" "$2" scope-gate.sh
  rm -rf "$T/build"; mkdir -p "$T/build"; rm -f "$T/NOTE.txt"
  ( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=K BASE=main \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$0"
             printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt' "$T/gates.sh" >/dev/null 2>&1 )
  echo "$? $(cat "$T/build/RESULT" 2>/dev/null || echo none)"
}
note() { cat "$T/NOTE.txt" 2>/dev/null; }

# 2a. every verdict continues the build. The scope gate is evidence for the
#     reviewer and a tier input; it is not a terminal, and a mechanical block on
#     a heuristic file list would stall the fleet on planner imprecision.
for RC in 0 1 2 3; do
  OUT=$(run_gates "$RC" "SCOPE_COUNTS: changed=3 planned=1 unplanned=2 adjacent=0 test=0 spec=0 foreign=2 protected=1
SCOPE_PROTECTED: prisma/schema.prisma
SCOPE_VERDICT: v$RC")
  grep -q '^0 none' <<<"$OUT" || bad "scope rc=$RC must not block the build (got: $OUT)"
  note | grep -q 'SCOPE GATE' || bad "scope rc=$RC must still reach the reviewer"
done
ok

# 2b. each verdict says something DIFFERENT, and the gate's own report rides
#     along — a summary the reviewer cannot check is not evidence.
run_gates 0 "SCOPE_REPORT_0
SCOPE_VERDICT: in-scope" >/dev/null
note | grep -q 'every changed file was in the plan' && ok || bad "rc 0 must say the diff stayed in scope"
note | grep -q 'SCOPE_REPORT_0' && ok || bad "the gate's own report must reach the reviewer"
run_gates 2 "SCOPE_REPORT_2
SCOPE_VERDICT: unplanned" >/dev/null
note | grep -q 'scope-creep' && ok || bad "rc 2 must name the fraud class the reviewer is hunting"
note | grep -qi 'not a block' && ok || bad "rc 2 must tell the reviewer it is a judgement call"
run_gates 1 "SCOPE_REPORT_1
SCOPE_VERDICT: protected" >/dev/null
note | grep -q 'PROTECTED set' && ok || bad "rc 1 must name the protected set"
note | grep -q 'unauthorized-action' && ok || bad "rc 1 must name the fraud class"
# 2c. a gate that could not run must never read as one that passed — the same
#     degradation contract the other three gates carry.
run_gates 3 "GATE_UNAVAILABLE the plan named no files
SCOPE_VERDICT: unavailable" >/dev/null
note | grep -q 'Do not read this as in-scope' && ok || bad "rc 3 must forbid reading it as in-scope"
run_gates 127 "" >/dev/null
note | grep -q 'could not run (rc=127)' && ok || bad "an undefined rc must be reported honestly as not-run"
grep -qi 'out of scope\|scope-creep' <<<"$(note)" && bad "a missing gate must not accuse the diff of anything" || ok
# THE ROLLOUT CASE: harness-sync lands bin/ on its own schedule, so a box can
# carry this run-build.sh with no scope-gate.sh for a window.
rm -f "$T/bin/scope-gate.sh"
rm -rf "$T/build"; mkdir -p "$T/build"; rm -f "$T/NOTE.txt"
( HARNESS="$T" BUILD="$T/build" ALERTS="$T/logs/ALERTS.log" PROJECT=p KEY=K BASE=main \
  bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$0"
           printf "%s" "$GATES_NOTE" > '"$T"'/NOTE.txt' "$T/gates.sh" >/dev/null 2>&1 )
MRC=$?
{ [ "$MRC" = 0 ] && [ ! -s "$T/build/RESULT" ]; } \
  && ok || bad "a MISSING scope gate must not block the build (rc=$MRC)"
grep -q 'scope=' "$T/build/pipeline.log" 2>/dev/null \
  && ok || bad "the GATES pipeline.log line must record the scope rc"

# ============================================================================
# 3. bin/run-build.sh — the demoter, and its warn-first default
# ============================================================================
awk '/^# >>> scope gate/{f=1;next} /^# <<< scope gate/{exit} f' \
  "$RB_ALL" > "$T/scope.sh"
[ -s "$T/scope.sh" ] && ok || bad "could not extract the scope-gate demoter — markers missing?"

mkreport() { # mkreport <verdict> [protected-line]
  local b="$T/db"; scratch_rm "$b"; mkdir -p "$b"
  { echo "SCOPE_COUNTS: changed=4 planned=2 unplanned=2 adjacent=0 test=0 spec=0 foreign=2 protected=1"
    [ -n "${2:-}" ] && echo "SCOPE_PROTECTED: $2"
    echo "SCOPE_VERDICT: $1"; } > "$b/scope-gate.txt"
  printf '%s' "$b"
}
demote() { # demote <build-dir> <tier-in> [env...]
  local b="$1" tier="$2"; shift 2
  ( env HARNESS="$DIR" BUILD="$b" PROJECT=p KEY=K TIER="$tier" QA_NOTE="" \
        ALERTS="$T/logs/ALERTS.log" "$@" \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
             printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/scope.sh" 2>/dev/null )
}

# 3a. warn-first is the SHIPPED default: the tier stands, and the reason is
#     still written where RESULT, the PR body and the verdict row pick it up.
B=$(mkreport protected prisma/schema.prisma)
OUT=$(demote "$B" 1)
grep -q '^TIER=1' <<<"$OUT" && ok || bad "the shipped default must not demote (got: $OUT)"
grep -q 'SCOPE_GATE_ENFORCE=0, warn only' <<<"$OUT" && ok || bad "a warn-only run must say so (got: $OUT)"
grep -q 'prisma/schema.prisma' <<<"$OUT" && ok || bad "the note must name the protected file (got: $OUT)"
grep -q 'SCOPE: 1 unplanned file' <<<"$OUT" && ok || bad "the note must carry the protected COUNT (got: $OUT)"

# 3a2. the note is bounded. It rides in QA_NOTE, which bin/evidence-summary.sh
#      truncates at 400 chars for the whole string — a long protected list would
#      push the other demoters' reasons out of the PR body.
LONG=$(mkreport protected "$(for i in $(seq 1 20); do printf 'prisma/very/long/path/number-%s.sql ' "$i"; done)")
OUT=$(demote "$LONG" 1)
[ "${#OUT}" -lt 300 ] && ok || bad "a long protected list was not bounded in the note (${#OUT} chars)"
grep -q 'SCOPE: 1 unplanned file' <<<"$OUT" && ok || bad "the bounded note lost its count (got: $OUT)"

# 3b. armed, the same build demotes and says why.
for ON in 1 true YES on; do
  OUT=$(demote "$B" 1 SCOPE_GATE_ENFORCE="$ON")
  grep -q '^TIER=2' <<<"$OUT" || bad "SCOPE_GATE_ENFORCE=$ON must arm the demotion (got: $OUT)"
  # TEST-CHANGE(BH-4581): wording only, tier logic unchanged
  grep -q 'recorded tier-2 (risk signal)' <<<"$OUT" || bad "the demotion must say it demoted (got: $OUT)"
done
ok

# 3c. ONLY the protected verdict demotes. A foreign file can be exactly right
#     for a ticket, and demoting on a count would teach planners to over-list.
for V in in-scope unplanned unavailable; do
  B=$(mkreport "$V")
  OUT=$(demote "$B" 1 SCOPE_GATE_ENFORCE=1)
  grep -q '^TIER=1|NOTE=$' <<<"$OUT" || bad "verdict '$V' must not demote or annotate (got: $OUT)"
done
ok

# 3d. a build with no scope report is NOT an in-scope build: nothing is demoted,
#     nothing is claimed. (Every record from before this shipped, and any box
#     mid-sync.)
B="$T/db-empty"; scratch_rm "$B"; mkdir -p "$B"
OUT=$(demote "$B" 1 SCOPE_GATE_ENFORCE=1)
grep -q '^TIER=1|NOTE=$' <<<"$OUT" && ok || bad "a missing scope report must change nothing (got: $OUT)"

# 3e. an unrecognised switch value is OFF and SAYS SO. A `true` that silently
#     means off is the never-fires shape, and a typo must not disable the gate
#     quietly.
: > "$T/logs/ALERTS.log"
B=$(mkreport protected prisma/schema.prisma)
OUT=$(demote "$B" 1 SCOPE_GATE_ENFORCE=maybe)
grep -q '^TIER=1' <<<"$OUT" && ok || bad "a junk switch value must be treated as OFF (got: $OUT)"
grep -q "SCOPE_GATE_ENFORCE='maybe' is not a recognized" "$T/logs/ALERTS.log" \
  && ok || bad "a junk switch value must raise an ALERTS line"

# 3f. a build ALREADY at tier 2 is not demoted twice, but it still has to name
#     the protected files. The tier is the thing the guard protects; the list is
#     what the PR body and the verdict row carry to the merge sweep, and burying
#     it in the review prompt alone loses it for every later reader.
B=$(mkreport protected prisma/schema.prisma)
OUT=$(env HARNESS="$DIR" BUILD="$B" PROJECT=p KEY=K TIER=2 ALERTS="$T/logs/ALERTS.log" \
      QA_NOTE=" | QA: SKIPPED — demoted to tier-2" SCOPE_GATE_ENFORCE=1 \
      bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
               printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/scope.sh" 2>/dev/null)
grep -q '^TIER=2|' <<<"$OUT" && ok || bad "a tier-2 build must not be demoted again (got: $OUT)"
grep -q 'QA: SKIPPED' <<<"$OUT" && ok || bad "the earlier demoter's reason must survive (got: $OUT)"
grep -q 'SCOPE: 1 unplanned file(s) in the protected set (prisma/schema.prisma)' <<<"$OUT" \
  && ok || bad "a tier-2 build must still name the protected files (got: $OUT)"
grep -q 'demoted' <<<"$(sed -n 's/.*| SCOPE: //p' <<<"$OUT")" \
  && bad "the scope note must not claim a demotion it did not cause (got: $OUT)" || ok

# 3g. THE VERDICT DESCRIBES THE HEAD THAT MERGES. The gate runs before the
#     review; the review, security, refutation and QA fix rounds all commit
#     after it. A fix round that adds package.json was invisible to the demoter,
#     and the ledger's scope field then rode to the merge sweep describing a
#     diff that no longer existed. Driven end-to-end: score a clean head, commit
#     a protected file on top, run the demoter, expect the RE-SCORE.
read -r R B <<<"$(mkrepo settle-rescore)"
plan "$R" src/lib/one.ts
add "$R" src/lib/one.ts; commit "$R"
BD=$(bdir "$R")
( cd "$R" && "$GATE" "$BD" "$B" . > "$BD/scope-gate.txt" 2>&1 )
grep -q 'SCOPE_VERDICT: in-scope' "$BD/scope-gate.txt" \
  && ok || bad "the pre-review score should be in-scope (got: $(cat "$BD/scope-gate.txt"))"
grep -q '^SCOPE_HEAD: [0-9a-f]\{40\}$' "$BD/scope-gate.txt" \
  && ok || bad "the gate must record WHICH head it scored"
add "$R" package.json; commit "$R"        # the fix round nobody re-scored
OUT=$( cd "$R" && env HARNESS="$DIR" BUILD="$BD" BASE="$B" PROJECT=p KEY=K TIER=1 \
        QA_NOTE="" ALERTS="$T/logs/ALERTS.log" SCOPE_GATE_ENFORCE=1 \
        bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
                 printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/scope.sh" 2>/dev/null )
grep -q '^TIER=2' <<<"$OUT" && ok || bad "a fix round that adds a manifest must be caught at settle (got: $OUT)"
grep -q 'package.json' <<<"$OUT" && ok || bad "the re-score must name the new protected file (got: $OUT)"
grep -q 'SCOPE_VERDICT: protected' "$BD/scope-gate.txt" \
  && ok || bad "the rewritten report must describe the settled head"
grep -q 'head moved' "$BD/pipeline.log" 2>/dev/null \
  && ok || bad "the re-score must be logged, not silent"

# 3g-ii. an UNMOVED head is not re-scored — the gate must not run twice per
#     build for nothing, and a resumed build reads back the same verdict.
: > "$BD/pipeline.log"
OUT=$( cd "$R" && env HARNESS="$DIR" BUILD="$BD" BASE="$B" PROJECT=p KEY=K TIER=1 \
        QA_NOTE="" ALERTS="$T/logs/ALERTS.log" SCOPE_GATE_ENFORCE=1 \
        bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
                 printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/scope.sh" 2>/dev/null )
grep -q 'head moved' "$BD/pipeline.log" 2>/dev/null \
  && bad "the head did not move — the gate must not re-run (got: $(cat "$BD/pipeline.log"))" || ok
grep -q '^TIER=2' <<<"$OUT" && ok || bad "the settled verdict must still stand (got: $OUT)"

# 3g-iii. a report with NO SCOPE_HEAD line (every record from before this
#     shipped, and any gate that could not resolve a base) is read as-is and
#     never re-scored against a repo it may not describe.
B2=$(mkreport protected prisma/schema.prisma)
OUT=$(demote "$B2" 1 SCOPE_GATE_ENFORCE=1)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "a headless report is still read (got: $OUT)"
grep -q 'prisma/schema.prisma' "$B2/scope-gate.txt" \
  && ok || bad "a headless report must not be overwritten by a re-score"

# 3g-iv. THE BASE THE RE-SCORE DIFFS AGAINST. $BASE is a branch NAME, and
#     bin/run-build.sh fast-forwards the LOCAL branch once at build start and
#     then rebases onto origin/$BASE before the PR — by construction only when
#     main moved. Diffing the settled head against the stale local branch takes
#     the merge-base with a main from an hour ago, so every file the OTHER PRs
#     merged in the meantime scores as this build's unplanned/protected files:
#     a sibling PR's package.json demotes THIS build. The suite missed it once
#     because every other case passes a SHA as the base.
UPS="$T/rescore-up"; scratch_rm "$UPS"; rm -rf "$T/rescore"; mkdir -p "$UPS/src/lib" "$T/rescore/b"
( cd "$UPS" || exit 1
  git -c init.defaultBranch=main init -q .
  git config user.email t@example.com; git config user.name t
  echo one > src/lib/one.ts
  git add -A && git commit -qm base ) >/dev/null 2>&1
CL="$T/rescore/repo"; BD="$T/rescore/b"
git clone -q "$UPS" "$CL" >/dev/null 2>&1
( cd "$CL" && git config user.email t@example.com && git config user.name t ) >/dev/null 2>&1
M0=$(cd "$CL" && git rev-parse HEAD)
printf 'src/lib/one.ts\n' > "$BD/planned-files.txt"
( cd "$CL" && git checkout -q -b feat && echo work >> src/lib/one.ts && git commit -qam work ) >/dev/null 2>&1
( cd "$CL" && "$GATE" "$BD" "$M0" . > "$BD/scope-gate.txt" 2>&1 )
grep -q 'SCOPE_VERDICT: in-scope' "$BD/scope-gate.txt" \
  && ok || bad "the pre-rebase score should be in-scope (got: $(cat "$BD/scope-gate.txt"))"
# main moves under us: a sibling PR lands a manifest and a schema.
( cd "$UPS" && mkdir -p prisma && echo dep > package.json && echo model > prisma/schema.prisma \
  && git add -A && git commit -qm sibling ) >/dev/null 2>&1
( cd "$CL" && git fetch -q origin main && git rebase -q origin/main ) >/dev/null 2>&1
# The bug, reproduced: scored against the stale LOCAL branch, the sibling's two
# files read as this build's protected surprise.
mkdir -p "$T/rescore/b-stale"; cp "$BD/planned-files.txt" "$T/rescore/b-stale/"
STALE=$( cd "$CL" && "$GATE" "$T/rescore/b-stale" main . 2>&1 ); SRC=$?
{ [ "$SRC" = 1 ] && grep -q 'package.json' <<<"$STALE"; } \
  && ok || bad "fixture no longer reproduces the stale-base read (rc=$SRC: $STALE)"
# The shipped demoter resolves origin/$BASE, so the re-score sees only this
# build's own commit.
OUT=$( cd "$CL" && env HARNESS="$DIR" BUILD="$BD" BASE=main PROJECT=p KEY=K TIER=1 \
        QA_NOTE="" ALERTS="$T/logs/ALERTS.log" SCOPE_GATE_ENFORCE=1 \
        bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
                 printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/scope.sh" 2>/dev/null )
grep -q 'head moved' "$BD/pipeline.log" 2>/dev/null \
  && ok || bad "the rebase moved HEAD — the settle re-score must run"
grep -q '^TIER=1|NOTE=$' <<<"$OUT" \
  && ok || bad "a rebase onto a moved main must not demote for the SIBLING PR's files (got: $OUT)"
grep -q 'SCOPE_VERDICT: in-scope' "$BD/scope-gate.txt" \
  && ok || bad "the re-scored report must describe THIS build's diff (got: $(cat "$BD/scope-gate.txt"))"
# …and the gates block resolves the same way, so the pre-review score and the
# settle re-score can never disagree about which base they used.
grep -q 'git rev-parse -q --verify "origin/\$BASE"' "$T/gates.sh" \
  && ok || bad "the mechanical-gates block does not resolve the base against origin/\$BASE"

# ============================================================================
# 4. the verdict row carries the scope verdict — including "not-recorded"
# ============================================================================
awk '/^# >>> verdict artifact/{f=1;next} /^# <<< verdict artifact/{exit} f' \
  "$RB_ALL" > "$T/verdict.sh"
[ -s "$T/verdict.sh" ] && ok || bad "could not extract the verdict-artifact block"
verdict_detail() { # verdict_detail [env...]
  local b="$T/vb"; scratch_rm "$b"; mkdir -p "$b"
  printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$b/review.md"
  ( env BUILD="$b" PR_URL=https://github.com/x/y/pull/1 JOB_ID=job-1 TIER=1 QA_NOTE="" \
        HEADBOUND_SHA=abc123 REPAIRS=0 REPAIR_ROUNDS=- SINK="$T/artifact.json" "$@" \
    bash -c 'set -uo pipefail
             job_artifact_put() { printf "%s" "$3" > "$SINK"; }
             . "$0"' "$T/verdict.sh" 2>/dev/null )
  cat "$T/artifact.json" 2>/dev/null
}
D=$(verdict_detail SCOPE_VERDICT=protected SCOPE_COUNTS="changed=4 planned=2 unplanned=2 adjacent=0 test=0 spec=0 foreign=2 protected=1")
[ "$(jq -r '.scope' <<<"$D")" = protected ] && ok || bad "the verdict row lost the scope verdict (detail: $D)"
[ "$(jq -r '.scope_counts' <<<"$D")" = "changed=4 planned=2 unplanned=2 adjacent=0 test=0 spec=0 foreign=2 protected=1" ] \
  && ok || bad "the verdict row lost the scope counts (detail: $D)"
# Absent is NOT in-scope: a build whose gate could not run says so on the row.
D=$(verdict_detail)
[ "$(jq -r '.scope' <<<"$D")" = not-recorded ] && ok \
  || bad "an unmeasured build must record 'not-recorded', never in-scope (detail: $D)"
# ...and the fields items 1 and 3 put there still ride along untouched.
[ "$(jq -r '.reviewed_sha' <<<"$D")" = abc123 ] && ok || bad "the reviewed sha was dropped (detail: $D)"
[ "$(jq -r '.repairs' <<<"$D")" = 0 ] && ok || bad "the repair count was dropped (detail: $D)"

# ============================================================================
# 5. bin/jobs-client.sh — the read, through the real client
# ============================================================================
cat > "$T/stub/curl" <<'CURL'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/verdict*) printf '%s\n200\n' "$(cat "$FIX_VERDICT")" ;;
  *) printf '{"ok":1}\n200\n' ;;
esac
CURL
chmod +x "$T/stub/curl"
export PATH="$T/stub:$PATH" FIX_VERDICT="$T/verdict.json"
export HARNESS_SECRET=x JOBS_URL=https://jobs.test
# shellcheck source=/dev/null
. "$DIR/bin/jobs-client.sh"
cat > "$FIX_VERDICT" <<'JSON'
{"pr":"https://github.com/Acme/widget-os/pull/11","job_id":"b-11","verdict":"APPROVE","tier":1,
 "merge_sha":"aaaa1111","repairs":3,"scope":"protected",
 "job":{"id":"b-11","project":"widget-os","ticket_id":"WD-11"}}
JSON
IFS=$'\t' read -r F1 F2 F3 F4 F5 F6 F7 F8 <<<"$(job_pr_facts https://github.com/Acme/widget-os/pull/11)"
[ "$F1 $F2 $F3 $F4 $F5 $F6 $F7" = "b-11 widget-os WD-11 APPROVE aaaa1111 1 3" ] && ok \
  || bad "job_pr_facts changed the first seven fields: $F1 $F2 $F3 $F4 $F5 $F6 $F7"
[ "$F8" = protected ] && ok || bad "job_pr_facts did not carry the scope verdict (got '$F8')"
# A row from before the gate existed reports "-", never in-scope.
jq 'del(.scope)' "$FIX_VERDICT" > "$T/v2.json" && mv "$T/v2.json" "$FIX_VERDICT"
IFS=$'\t' read -r _ _ _ _ _ _ _ F8 <<<"$(job_pr_facts https://github.com/Acme/widget-os/pull/11)"
[ "$F8" = "-" ] && ok || bad "an unmeasured build must read '-' rather than a verdict (got '$F8')"

# 5b. THE APPEND HAS A CONSUMER. The last variable in a `read` collects every
#     remaining field, so appending to job_pr_facts without updating
#     bin/outcome-metrics.sh turns its repair count into "3<TAB>protected",
#     which its own digit check then discards as unmeasured. Caught live.
grep -q 'read -r _JID PROJECT TICKET _VERDICT MERGE_SHA _TIER PR_REPAIRS _SCOPE' \
  "$DIR/bin/outcome-metrics.sh" \
  && ok || bad "bin/outcome-metrics.sh does not read the appended scope field — its repair count will collect it"

# ============================================================================
# 6. the worker surfaces it, and absence stays absent
# ============================================================================
# BH-1195 moved /api/verdict into worker/jobs/src/routes/verdict.js — grep the
# worker source TREE so the question survives the next move too.
IDX="$DIR/worker/jobs/src"
grep -rq 'scope: d.scope !== undefined ? d.scope : null' "$IDX" && ok \
  || bad "/api/verdict does not surface the scope verdict"
grep -rq 'scope_counts: d.scope_counts !== undefined ? d.scope_counts : null' "$IDX" && ok \
  || bad "/api/verdict does not surface the scope counts"

echo "scope-gate-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
