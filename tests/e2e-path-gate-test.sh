#!/bin/bash
# tests/e2e-path-gate-test.sh — the preview smoke is PATH-GATED before it pushes.
#
# What this is about. The e2e stage used to decide "is there UI in this diff?"
# with one regex — `\.(tsx|jsx|css)$|(^|/)app/|(^|/)components/|(^|/)pages/` —
# and that regex says yes to a diff that changes nothing a browser can see:
# `src/lib/foo.test.tsx` (a test), `src/lib/Widget.stories.tsx` (a story),
# `apps/web/x.ts` (the substring `app/`). Every one of those pushed a branch,
# waited up to 600 s for Vercel to build a preview of it, and drove a browser to
# learn nothing. The gate now runs through bin/lib/e2e-ui-paths.sh and it runs
# BEFORE the push, so a miss costs nothing at all.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q e2e_ui_path_hit bin/run-build.sh` passes
# on a version that calls the matcher and ignores its answer, on one that gates
# the browser but still pushes the branch, and on one that skips a diff it should
# have driven. What is under test is the OBSERVABLE consequence: whether the
# branch reached the remote, whether bin/wait-preview.sh was called at all, what
# e2e.md says about why, and which exit code the stage handed the pipeline.
# The block is extracted VERBATIM from bin/run-build.sh by its markers and the
# REAL bin/e2e-smoke.sh sits behind it, so the only fakes are the network edges.
#
# Run from anywhere: tests/e2e-path-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin/lib" "$T/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' \
  "$RB_ALL" > "$T/timing.sh"
[ -s "$T/timing.sh" ] && ok || bad "could not extract the stage-timing block — markers missing?"
awk '/^# >>> e2e smoke/{f=1;next} /^# <<< e2e smoke/{exit} f' \
  "$RB_ALL" > "$T/e2e.sh"
[ -s "$T/e2e.sh" ] && ok || bad "could not extract the e2e-smoke block — markers missing?"

# The REAL smoke script and its .mjs neighbour (e2e-smoke.sh SKIPs without the
# .mjs, which would make every case below pass for the wrong reason), and the
# two contract libs the block sources out of $HARNESS/bin/lib.
cp "$DIR/bin/e2e-smoke.sh" "$DIR/bin/e2e-smoke.mjs" "$T/bin/"
cp "$DIR/bin/lib/e2e-ui-paths.sh" "$DIR/bin/lib/e2e-join.sh" "$T/bin/lib/"
chmod +x "$T/bin/e2e-smoke.sh"
printf 'p\tsomeproj\n' > "$T/vercel.conf"
printf '{"_default_routes":["/"]}\n' > "$T/routes.json"

# The network edges, and only those. wait-preview.sh records the sha it was
# asked about — its marker file is the proof that the stage went past the gate.
cat > "$T/bin/wait-preview.sh" <<'STUB'
#!/bin/bash
printf '%s' "$2" > "$WP_CALLED"
[ "${WP_MODE:-}" = fail ] && exit 1
echo "https://preview.example.invalid"
exit 0
STUB
cat > "$T/bin/fakenode" <<'STUB'
#!/bin/bash
# stands in for `node bin/e2e-smoke.mjs <preview> <out> <repo>`
{ echo "loaded / on the preview"
  echo "E2E COVERAGE: routes=1 failed=0"
  echo "E2E: PASS"; } > "$3/e2e.md"
exit 0
STUB
chmod +x "$T/bin/wait-preview.sh" "$T/bin/fakenode"

# A real repo with a real bare remote: "no push" has to be observable, and the
# only honest way to observe it is that the remote has no branch.
REPO="$T/repo"
git init -q --bare "$T/remote"
( mkdir -p "$REPO" && cd "$REPO" || exit 1
  git init -q -b main
  git config user.email t@example.com; git config user.name tester
  echo base > README.md
  git add -A; git -c commit.gpgsign=false commit -qm base
  git remote add origin "$T/remote"
  git push -q origin main ) >/dev/null 2>&1

# prep <path> — a fresh `feat` carrying exactly one changed file, and a remote
# that has never heard of it.
prep() {
  ( cd "$REPO" || exit 1
    git checkout -q main
    git branch -qD feat 2>/dev/null
    git checkout -q -b feat
    mkdir -p "$(dirname "$1")"
    printf 'export const x = 1\n' > "$1"
    git add -A
    git -c commit.gpgsign=false commit -qm "work on $1" ) >/dev/null 2>&1
  git --git-dir="$T/remote" update-ref -d refs/heads/feat >/dev/null 2>&1
  rm -f "$T/wp-called"
}

# run <env assignments...> — the extracted block, inline (GATES_PARALLEL=0), so
# the verdict and the rc are readable straight afterwards.
run() {
  rm -rf "$T/build"; mkdir -p "$T/build"
  : > "$T/alerts.log"
  ( cd "$REPO" || exit 1
    env HARNESS="$T" BUILD="$T/build" ALERTS="$T/alerts.log" \
        PROJECT=p KEY=K BASE=main BRANCH=feat GATES_NOTE="" \
        GATES_PARALLEL=0 OUTDIR="$T" \
        WP_CALLED="$T/wp-called" \
        E2E_ROUTES_FILE="$T/routes.json" \
        WAIT_PREVIEW="$T/bin/wait-preview.sh" \
        E2E_NODE="$T/bin/fakenode" \
        "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      track_pushed() { :; }
      # BH-2504: the pipeline pushes through RB_PUSH (bin/lib/rb/gates.sh ->
      # bin/lib/hold-push.sh). This suite is about the stage timing, so the
      # push is the plain one the block made before the hold read existed.
      RB_PUSH() { git push -q -u origin "$BRANCH"; }
      GH_LIVE() { :; }
      . "$1"
      . "$2"
      printf "%s" "${E2E_VERDICT:-none}" > "$OUTDIR/verdict.txt"
    ' _ "$T/timing.sh" "$T/e2e.sh" ) >/dev/null 2>&1
  printf '%s\n' "$(cat "$T/verdict.txt" 2>/dev/null)" >> "$T/verdicts.log"
}

rc()        { cat "$T/build/e2e-rc" 2>/dev/null; }
md_first()  { head -1 "$T/build/e2e.md" 2>/dev/null; }
md_last()   { tail -1 "$T/build/e2e.md" 2>/dev/null; }
head_sha()  { git -C "$REPO" rev-parse HEAD; }
pushed()    { grep -q feat <<<"$(git ls-remote --heads "$T/remote" feat 2>/dev/null)"; }
: > "$T/verdicts.log"

# A skip case, asserted the same way every time: nothing left the box.
assert_skipped() { # assert_skipped <label>
  [ "$(rc)" = 3 ] && ok || bad "$1: e2e-rc is '$(rc)', want 3"
  [ "$(md_last)" = "E2E: SKIP" ] && ok || bad "$1: e2e.md last line is '$(md_last)', want 'E2E: SKIP'"
  [ ! -f "$T/wp-called" ] && ok || bad "$1: bin/wait-preview.sh was called — the stage went past the gate"
  pushed && bad "$1: the branch reached the remote on a skip" || ok
}
assert_invoked() { # assert_invoked <label>
  [ -f "$T/wp-called" ] && ok || bad "$1: bin/wait-preview.sh was never called — the gate refused a UI diff"
  pushed && ok || bad "$1: the branch never reached the remote, so no preview could exist"
}

# ============================================================================
# A1. AN ENGINE-ONLY DIFF: no push, no preview wait, and a sentence that says
#     which globs decided it. This is the whole point of the slice.
# ============================================================================
prep src/lib/engine/x.ts
run
assert_skipped "A1 engine-only"
grep -q 'E2E skip (no UI paths in diff)' "$T/build/pipeline.log" \
  && ok || bad "A1: pipeline.log carries no 'E2E skip (no UI paths in diff)' line"
case "$(md_first)" in
  "E2E smoke did not run: no UI paths in diff"*) ok ;;
  *) bad "A1: e2e.md line 1 is '$(md_first)'" ;;
esac
grep -q 'src/app/\*\*' "$T/build/e2e.md" \
  && ok || bad "A1: the skip sentence does not name the globs that decided it: '$(md_first)'"

# ============================================================================
# A2. A PAGE DIFF still drives the browser, against the sha that was pushed.
# ============================================================================
prep src/app/foo/page.tsx
run
assert_invoked "A2 page"
[ "$(cat "$T/wp-called" 2>/dev/null)" = "$(head_sha)" ] \
  && ok || bad "A2: wait-preview was asked about '$(cat "$T/wp-called" 2>/dev/null)', want $(head_sha)"
[ "$(rc)" = 0 ] && ok || bad "A2: e2e-rc is '$(rc)', want 0"
[ "$(md_last)" = "E2E: PASS" ] && ok || bad "A2: e2e.md last line is '$(md_last)', want 'E2E: PASS'"
[ "$(cat "$T/build/e2e-sha" 2>/dev/null)" = "$(head_sha)" ] \
  && ok || bad "A2: e2e-sha is '$(cat "$T/build/e2e-sha" 2>/dev/null)', want $(head_sha)"

# ============================================================================
# A3. E2E_PATHS REPLACES the list, it does not extend it — and a blank value is
#     the default, never "match nothing".
# ============================================================================
prep src/lib/engine/x.ts
run 'E2E_PATHS=src/lib/engine/**'
assert_invoked "A3 override opts a server path in"
prep components/Nav.tsx
run 'E2E_PATHS=src/app/**'
assert_skipped "A3 override opts components out"
prep src/app/foo/page.tsx
run 'E2E_PATHS=  '
assert_invoked "A3 whitespace-only E2E_PATHS falls back to the default"
prep src/lib/engine/x.ts
run 'E2E_PATHS=src/lib/**,components/**'
assert_invoked "A3 comma-separated list"

# ============================================================================
# A4. THE FALSE POSITIVES TODAY'S REGEX PAYS FOR, and the route file it must
#     still drive.
# ============================================================================
prep src/lib/foo.test.tsx
run
assert_skipped "A4 a .test.tsx is not a rendered surface"
prep src/app/api/x/route.ts
run
assert_invoked "A4 an app-router route file is"

# ============================================================================
# A4b. A BIG UI DIFF STILL HITS. The block runs under `pipefail` and the matcher
#      answers at the FIRST hit, so feeding it `git diff --name-only | ...` makes
#      git die of SIGPIPE on any diff whose name list outgrows the pipe buffer
#      (~64 KB): the pipeline reports 141, the gate reads a MISS, and a 2000-file
#      UI change silently skips the smoke. That is the failure this whole slice
#      exists to prevent, so it is a case and not a comment.
# ============================================================================
prep_many() { # prep_many <count> — one branch, <count> component files
  ( cd "$REPO" || exit 1
    git checkout -q main
    git branch -qD feat 2>/dev/null
    git checkout -q -b feat
    mkdir -p src/app/generated
    i=0
    while [ "$i" -lt "$1" ]; do
      printf 'export const x = 1\n' > "src/app/generated/Widget-$i-with-a-long-enough-name.tsx"
      i=$((i+1))
    done
    git add -A
    git -c commit.gpgsign=false commit -qm "work on $1 files" ) >/dev/null 2>&1
  git --git-dir="$T/remote" update-ref -d refs/heads/feat >/dev/null 2>&1
  rm -f "$T/wp-called"
}
prep_many 2000
[ "$(git -C "$REPO" diff --name-only main...HEAD | wc -c)" -gt 65536 ] \
  && ok || bad "A4b: the fixture diff is smaller than a pipe buffer, so it proves nothing"
run
assert_invoked "A4b 2000 UI files"

# ============================================================================
# A5. RUNG ORDER. A copy ticket answers first, in its own words, and the path
#     sentence never appears — a reader must not have to guess which rung spoke.
# ============================================================================
prep src/app/foo/page.tsx
run KIND_SKIP_E2E=1
assert_skipped "A5 KIND: copy"
grep -q 'KIND: copy' "$T/build/e2e.md" \
  && ok || bad "A5: e2e.md does not name the copy routing: '$(md_first)'"
grep -q 'no UI paths in diff' "$T/build/e2e.md" \
  && bad "A5: a copy skip was reported as a path-gate skip" || ok

# ============================================================================
# A6. vercel.conf WITHOUT THE PROJECT gets its OWN sentence. Today both states
#     share one "no UI-touching files, or no Vercel project" line, which is
#     false in whichever state did not cause it (build-discipline D13).
# ============================================================================
printf 'other\tsomeproj\n' > "$T/vercel.conf"
prep src/app/foo/page.tsx
run
assert_skipped "A6 no Vercel project"
grep -q 'vercel.conf' "$T/build/e2e.md" \
  && ok || bad "A6: e2e.md does not name vercel.conf: '$(md_first)'"
grep -q 'no UI paths in diff' "$T/build/e2e.md" \
  && bad "A6: a missing Vercel project was reported as a path-gate skip" || ok
printf 'p\tsomeproj\n' > "$T/vercel.conf"

# ============================================================================
# 7. FAIL-OPEN. A box whose render lost the lib must SPEND a smoke and say so
#    out loud — never silently skip every build from then on.
# ============================================================================
rm -f "$T/bin/lib/e2e-ui-paths.sh"
prep src/app/foo/page.tsx
run
assert_invoked "lib missing: fail-open"
grep -q 'e2e-ui-paths.sh' "$T/alerts.log" \
  && ok || bad "lib missing: nothing in ALERTS names the lib that did not source"
cp "$DIR/bin/lib/e2e-ui-paths.sh" "$T/bin/lib/"

# ============================================================================
# 8. THE VOCABULARY. Every path above settled on one of pass/fail/skip — a new
#    word here silently breaks gates.json, evidence-summary.sh and the demoter.
# ============================================================================
BADV=$(grep -cvE '^(pass|fail|skip)$' "$T/verdicts.log")
[ "$BADV" -eq 0 ] \
  && ok || bad "$BADV run(s) settled on a verdict outside pass/fail/skip: $(sort -u "$T/verdicts.log" | paste -sd, -)"

echo "e2e-path-gate-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
