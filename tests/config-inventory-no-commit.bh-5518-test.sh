#!/bin/bash
# tests/config-inventory-no-commit.bh-5518-test.sh — BH-5518 slice C0. The
# config-inventory renders are GENERATED, and they are not committed.
#
# WHAT WAS WRONG. bin/config-inventory.sh wrote inventory.json, index.html and
# deployment.{json,md} into docs/config-inventory/, and all four were tracked
# (registry-drift.tsv, the hand-run --drift snapshot, too). Every PR that
# re-rendered touched the same files, so two such PRs always conflicted (at
# least on `generated_at_commit`), and a merge batch of two PRs that each
# rendered alone committed a deployment.md that was neither side's render:
# no-hardcoded-deployment R1 went red on batches #5426 and #5427.
#
# The fix is the catalog/lanes.json pattern: the five paths are git-ignored and
# out of the tree, every reader renders first, and the freshness proof is
# `bin/config-inventory.sh --check` (two renders of the sources are identical,
# nothing under docs/config-inventory is tracked, zero un-allowlisted literals).
#
# Every case drives the REAL bin/config-inventory.sh, bin/deployment-lint.sh and
# REAL git in scratch repositories. CN-4/CN-5 copy this branch's committed tree
# with `git archive HEAD`, so they grade exactly what the branch ships:
#   CN-1 this checkout tracks nothing under docs/config-inventory.
#   CN-2 a render into docs/config-inventory leaves `git status` clean; all five
#        paths are ignored.
#   CN-3 a force-added render makes --check rc 1 and names the path.
#   CN-4 (AT 1) a lane-knob PR and a deployment-reader PR, each rendered and
#        committed with `git add -A`, merge in either order with no conflict,
#        and the render on each merge equals a render of a fresh clone of it.
#   CN-5 (AT 2) on that merge, deployment-lint and --check are green and
#        nothing under docs/config-inventory is tracked.
#   CN-6 (AT 3) --check reads the sources, not the tree's render: a hand-edited
#        render and a source change stay green; a nondeterministic generator
#        is red with `not deterministic`.
#   CN-7 a local that one bin/lib/rb stage module assigns and another reads is
#        PLUMBING, not TEST_HOOK (the fresh render bh-1530 now reads exposed it).
#
# No network, no clock, no gh: scratch repositories under $T and nothing else.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/config-inventory-no-commit.bh-5518-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GEN="$DIR/bin/config-inventory.sh"
LINT="$DIR/bin/deployment-lint.sh"
OUTS="deployment.json deployment.md index.html inventory.json"
PATHS5="$OUTS registry-drift.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v git >/dev/null 2>&1 || { echo "git missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# CN-1, CN-4 and CN-5 read this checkout's git (HEAD, its tracked set). A
# snapshot with no .git skips them by name; CI and every build run in a checkout.
INGIT=0
git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 && INGIT=1

# ── CN-1 this checkout tracks nothing under docs/config-inventory ────────────
if [ "$INGIT" = 1 ]; then
  got=$(git -C "$DIR" ls-files docs/config-inventory 2>&1)
  [ -z "$got" ] && ok || bad "CN-1 docs/config-inventory has tracked files: $(echo "$got" | tr '\n' ' ')"
else
  echo "SKIP: CN-1 ($DIR is not a git checkout)"
fi

# ── a small fixture repo: the generator over a tree with a families catalog ──
# Small on purpose: a render of the real tree takes ~25 s, and CN-2/3/6 need
# six of them. The .gitignore is the one this branch COMMITS (HEAD), not the
# working tree's, so a local edit cannot make CN-2 pass.
FX="$T/fx"
mkdir -p "$FX/bin" "$FX/catalog/lanes.d" "$FX/tests"
git init -q -b main "$FX"
if [ "$INGIT" = 1 ]; then git -C "$DIR" show HEAD:.gitignore > "$FX/.gitignore"
else cp "$DIR/.gitignore" "$FX/.gitignore"; fi
cp "$DIR/catalog/deployment-literals.tsv" "$FX/catalog/deployment-literals.tsv"
printf '# empty fixture allowlist\n' > "$FX/tests/no-hardcoded-deployment-allowlist.txt"
printf '#!/bin/bash\necho "${FX_KNOB:-5}"\n' > "$FX/bin/fx.sh"
git -C "$FX" add -A && git -C "$FX" commit -qm fixture

# ── CN-2 a render into the tree is ignored ───────────────────────────────────
bash "$GEN" --root "$FX" >"$T/cn2.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "CN-2 render rc=$rc: $(cat "$T/cn2.log")"
printf 'name\tregistered\n' > "$FX/docs/config-inventory/registry-drift.tsv"
for f in $PATHS5; do
  [ -f "$FX/docs/config-inventory/$f" ] || bad "CN-2 the render wrote no docs/config-inventory/$f"
  git -C "$FX" check-ignore -q "docs/config-inventory/$f" && ok || bad "CN-2 docs/config-inventory/$f is not git-ignored"
done
got=$(git -C "$FX" status --porcelain 2>&1)
[ -z "$got" ] && ok || bad "CN-2 git status after a render is not clean: $(echo "$got" | tr '\n' ' ')"

# ── CN-3 a tracked render is red, by name ────────────────────────────────────
out=$(bash "$GEN" --check --root "$FX" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "CN-3 --check on a clean fixture must be rc 0, got $rc: $out"
git -C "$FX" add -f docs/config-inventory/deployment.md && git -C "$FX" commit -qm "a hand git add -f"
out=$(bash "$GEN" --check --root "$FX" 2>&1); rc=$?
[ "$rc" = 1 ] && ok || bad "CN-3 --check with a tracked deployment.md must be rc 1, got $rc: $out"
grep -q 'docs/config-inventory/deployment.md is tracked' <<<"$out" && ok \
  || bad "CN-3 --check must name the tracked path: $out"
git -C "$FX" rm -q --cached docs/config-inventory/deployment.md && git -C "$FX" commit -qm untrack

# ── CN-6 --check reads the sources, never the render in the tree ─────────────
echo "hand edit" >> "$FX/docs/config-inventory/deployment.md"
out=$(bash "$GEN" --check --root "$FX" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "CN-6 a hand-edited render in the tree must not turn --check red (rc=$rc): $out"

bash "$GEN" --root "$FX" --out "$T/cn6-before" >/dev/null 2>&1
printf 'echo "${FX_OTHER_KNOB:-9}"\n' >> "$FX/bin/fx.sh"
git -C "$FX" commit -qam "a source change"
bash "$GEN" --root "$FX" --out "$T/cn6-after" >/dev/null 2>&1
if [ "$(jq -c '[.variables[].name]' "$T/cn6-before/inventory.json")" != "$(jq -c '[.variables[].name]' "$T/cn6-after/inventory.json")" ]; then ok
else bad "CN-6 the source change did not change the inventory; the case proves nothing"; fi
out=$(bash "$GEN" --check --root "$FX" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "CN-6 a deterministic source change must keep --check green (rc=$rc): $out"

# --check carries no-hardcoded-deployment R1's invariant: an un-allowlisted
# deployment literal is a finding, even though both renders agree on it.
printf '#!/bin/bash\n# header\nREPO=example-org/widget\n' > "$FX/bin/fx-org.sh"
git -C "$FX" add bin/fx-org.sh && git -C "$FX" commit -qm "a hardcoded org"
out=$(bash "$GEN" --check --root "$FX" 2>&1); rc=$?
[ "$rc" = 1 ] && ok || bad "CN-6 an un-allowlisted deployment literal must make --check rc 1, got $rc: $out"
grep -q 'deployment.md records un-allowlisted literals' <<<"$out" && ok \
  || bad "CN-6 --check must say the report has un-allowlisted literals: $out"
git -C "$FX" rm -q bin/fx-org.sh && git -C "$FX" commit -qm "drop the org"

# A python3 first on PATH that runs the real one, then appends its own pid to
# deployment.md: two renders now differ, which is exactly a nondeterministic
# generator.
REALPY=$(command -v python3)
mkdir -p "$T/stub"
cat > "$T/stub/python3" <<STUB
#!/bin/bash
"$REALPY" "\$@"; rc=\$?
out=""
while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
[ -n "\$out" ] && [ -f "\$out/deployment.md" ] && echo "pid \$\$" >> "\$out/deployment.md"
exit \$rc
STUB
chmod +x "$T/stub/python3"
out=$(PATH="$T/stub:$PATH" bash "$GEN" --check --root "$FX" 2>&1); rc=$?
[ "$rc" = 1 ] && ok || bad "CN-6 a nondeterministic render must make --check rc 1, got $rc: $out"
grep -q 'render not deterministic: deployment.md' <<<"$out" && ok \
  || bad "CN-6 --check must say which file is not deterministic: $out"

# ── CN-7 a stage-module local is PLUMBING, not TEST_HOOK ─────────────────────
# Once nothing is committed, bh-1530 section 7 reads a FRESH render, and that
# render showed REPRO_RC as TEST_HOOK: bin/run-build.sh's stage modules
# (bin/lib/rb/, BH-478) assign it in one module and read it in another, so
# BH-1530's same-file rule missed it. The committed inventory was stale and hid
# it. Fixture: the same shape under rb/ is PLUMBING; two unrelated bin/ files
# with that shape stay TEST_HOOK.
FX7="$T/fx7"
mkdir -p "$FX7/bin/lib/rb" "$FX7/tests"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/rb/a.sh"\n. "$(dirname "$0")/lib/rb/b.sh"\n' > "$FX7/bin/run-build.sh"
printf 'FX_STAGE_RC=$(true; echo $?)\n' > "$FX7/bin/lib/rb/a.sh"
printf 'echo "${FX_STAGE_RC:-}"\n' > "$FX7/bin/lib/rb/b.sh"
printf '#!/bin/bash\nFX_LOOSE_RC=$(true; echo $?)\n' > "$FX7/bin/loose-a.sh"
printf '#!/bin/bash\necho "${FX_LOOSE_RC:-}"\n' > "$FX7/bin/loose-b.sh"
printf '#!/bin/bash\nFX_STAGE_RC=1\nFX_LOOSE_RC=1\n' > "$FX7/tests/fx7-test.sh"
bash "$GEN" --root "$FX7" --out "$T/fx7-out" >"$T/fx7.log" 2>&1
cls() { jq -r --arg n "$1" '.variables[]|select(.name==$n)|"\(.class) \(.rule)"' "$T/fx7-out/inventory.json" 2>/dev/null; }
[ "$(cls FX_STAGE_RC)" = "PLUMBING stage-module-assigned" ] && ok \
  || bad "CN-7 a local one bin/lib/rb module assigns and another reads must be PLUMBING stage-module-assigned, got '$(cls FX_STAGE_RC)' $(cat "$T/fx7.log")"
[ "$(cls FX_LOOSE_RC)" = "TEST_HOOK test-only-assignment" ] && ok \
  || bad "CN-7 the same shape across two unrelated bin/ files must stay TEST_HOOK, got '$(cls FX_LOOSE_RC)'"

# ── CN-4 / CN-5: two PRs over this branch's REAL tree ────────────────────────
if [ "$INGIT" = 0 ]; then
  echo "SKIP: CN-4, CN-5 ($DIR is not a git checkout; they copy its HEAD)"
  echo "config-inventory-no-commit: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
SR="$T/real"
git init -q -b main "$SR"
git -C "$DIR" archive HEAD | tar -x -C "$SR"
git -C "$SR" add -A && git -C "$SR" commit -qm "this branch's committed tree"

git clone -q "$SR" "$T/pa" && git -C "$T/pa" checkout -q -b pr-a
cat > "$T/pa/bin/bh5518-fixture-a.sh" <<'SH'
#!/bin/bash
# a deployment reader: the repo slug comes from the deployment defaults
. "$(dirname "$0")/lib/deployment.sh"
echo "${HARNESS_REPO}"
SH
git clone -q "$SR" "$T/pb" && git -C "$T/pb" checkout -q -b pr-b
cat > "$T/pb/catalog/lanes.d/bh5518-fixture-b.json" <<'JSON'
{
  "id": "bh5518-fixture-b",
  "script": "bin/bh5518-fixture-b.sh",
  "knobs": [
    { "env": "BH5518_FIXTURE_KNOB", "type": "int", "default": 7 }
  ]
}
JSON
printf '#!/bin/bash\necho "${BH5518_FIXTURE_KNOB:-7}"\n' > "$T/pb/bin/bh5518-fixture-b.sh"
# Each PR renders, as a builder does by habit, and commits everything.
bash "$GEN" --root "$T/pa" >"$T/pa.log" 2>&1 & pid_a=$!
bash "$GEN" --root "$T/pb" >"$T/pb.log" 2>&1 & pid_b=$!
wait "$pid_a"; ra=$?; wait "$pid_b"; rb=$?
[ "$ra" = 0 ] && [ "$rb" = 0 ] && ok || bad "CN-4 the PR renders failed (a=$ra b=$rb): $(cat "$T/pa.log" "$T/pb.log")"
git -C "$T/pa" add -A && git -C "$T/pa" commit -qm "PR A: a deployment reader"
git -C "$T/pb" add -A && git -C "$T/pb" commit -qm "PR B: a lane knob"
git -C "$SR" fetch -q "$T/pa" pr-a:pr-a && git -C "$SR" fetch -q "$T/pb" pr-b:pr-b

MERGED_AB=""
for order in "pr-a pr-b" "pr-b pr-a"; do
  set -- $order
  M="$T/merge-$1-$2"
  git clone -q "$SR" "$M" && git -C "$M" checkout -q "$1"
  out=$(git -C "$M" merge --no-edit "origin/$2" 2>&1); rc=$?
  conflicted=$(git -C "$M" diff --name-only --diff-filter=U)
  if [ "$rc" = 0 ] && [ -z "$conflicted" ]; then ok
  else bad "CN-4 merging $2 into $1 must not conflict (rc=$rc, conflicted: $(echo "$conflicted" | tr '\n' ' ')): $(echo "$out" | tail -3)"; continue; fi
  [ "$1" = pr-a ] && MERGED_AB="$M"
  git clone -q "$M" "$M-fresh"
done

# The render on each merge, against a render of a fresh clone of the same commit.
pids=""
for M in "$T"/merge-pr-?-pr-?; do
  [ -d "$M-fresh" ] || continue
  bash "$GEN" --root "$M" >"$M.log" 2>&1 & pids="$pids $!"
  bash "$GEN" --root "$M-fresh" >"$M-fresh.log" 2>&1 & pids="$pids $!"
done
for p in $pids; do wait "$p" || bad "CN-4 a post-merge render failed"; done
for M in "$T"/merge-pr-?-pr-?; do
  [ -d "$M-fresh" ] || continue
  for f in $OUTS; do
    cmp -s "$M/docs/config-inventory/$f" "$M-fresh/docs/config-inventory/$f" && ok \
      || bad "CN-4 $(basename "$M"): $f differs from a fresh clone's render"
  done
  jq -e '[.variables[].name] | index("BH5518_FIXTURE_KNOB") != null' "$M/docs/config-inventory/inventory.json" >/dev/null 2>&1 && ok \
    || bad "CN-4 $(basename "$M"): the merged inventory does not hold PR B's BH5518_FIXTURE_KNOB"
  got=$(git -C "$M" status --porcelain 2>&1)
  [ -z "$got" ] && ok || bad "CN-4 $(basename "$M"): the post-merge render left git status dirty: $(echo "$got" | tr '\n' ' ')"
done

# ── CN-5 the batch of the two passes no-hardcoded-deployment ─────────────────
if [ -n "$MERGED_AB" ]; then
  out=$(bash "$LINT" --root "$MERGED_AB" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok || bad "CN-5 deployment-lint on the A+B merge rc=$rc: $(echo "$out" | tail -5)"
  out=$(bash "$GEN" --check --root "$MERGED_AB" 2>&1); rc=$?
  [ "$rc" = 0 ] && ok || bad "CN-5 --check on the A+B merge rc=$rc: $(echo "$out" | tail -5)"
  got=$(git -C "$MERGED_AB" ls-files docs/config-inventory)
  [ -z "$got" ] && ok || bad "CN-5 the A+B merge tracks: $(echo "$got" | tr '\n' ' ')"
else
  bad "CN-5 there is no A+B merge to check (CN-4 conflicted)"
fi

echo "config-inventory-no-commit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
