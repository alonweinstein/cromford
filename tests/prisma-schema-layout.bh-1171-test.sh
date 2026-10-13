#!/bin/bash
# tests/prisma-schema-layout.bh-1171-test.sh — the prisma/schema/ folder layout.
#
# Prisma 7.5's multi-file schema moves the models from prisma/schema.prisma into
# a prisma/schema/ folder (project-5 #2744). Two harness guards decided whether
# to run `prisma generate` on `[ -f prisma/schema.prisma ]` alone, so on a
# folder-layout repo they silently skipped the generate and the typecheck after
# them read a stale (or absent) generated client:
#   H1-H4  bin/edit-feedback-hook.sh, driven through its real entry point (the
#          PostToolUse JSON on stdin) with a stub npx recording every call.
#   T1-T3  bin/rebase-train.sh's pre-verify regenerate, the shipped line taken
#          from between its '# >>> prisma regenerate' markers.
#   P1     the two generic plan/proposal prompts name both layouts.
#
# The scripts under test default to this checkout's and can be pointed at
# another copy (HOOK=..., TRAIN_SRC=...) for the red-before-green check.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
HOOK="${HOOK:-$DIR/bin/edit-feedback-hook.sh}"
TRAIN_SRC="${TRAIN_SRC:-$DIR/bin/rebase-train.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

# A stub npx first on PATH: records its argv, prints nothing, exits 0.
mkdir -p "$T/bin"
cat > "$T/bin/npx" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$NPX_CALLS"
exit 0
EOF
chmod +x "$T/bin/npx"
export PATH="$T/bin:$PATH"

# The hook keeps its state in /tmp/edit-feedback-<md5(cwd)>, outside $T. Each
# case pre-plants that path as a symlink into $T, so everything the hook writes
# lands in scratch (removed by the scratch trap) and only the link itself, a
# plain non-recursive rm, is left to clean up on exit.
FBLINKS=()
cleanup_fb() { local l; for l in "${FBLINKS[@]}"; do [ -L "$l" ] && rm -f "$l"; done; }
trap 'cleanup_fb; __scratch_exit_trap' EXIT

# fixture <dir> <folder|file|none>
fixture() {
  mkdir -p "$1"
  echo '{}' > "$1/tsconfig.json"
  echo 'export const a = 1;' > "$1/a.ts"
  case "$2" in
    folder) mkdir -p "$1/prisma/schema"; echo 'generator client { provider = "prisma-client" }' > "$1/prisma/schema/base.prisma" ;;
    file)   mkdir -p "$1/prisma"; echo 'generator client { provider = "prisma-client" }' > "$1/prisma/schema.prisma" ;;
    none)   : ;;
  esac
}

# ── hook: the real entry point ───────────────────────────────────────────────
# run_hook <case> <layout> — leaves the recorded calls in $T/<case>.calls and
# the hook's rc/stderr in $T/<case>.rc / $T/<case>.err.
run_hook() {
  local c="$1" cwd="$T/hook-$1" key fbd i
  fixture "$cwd" "$2"
  key=$(printf '%s' "$cwd" | md5sum | cut -c1-8)
  fbd="/tmp/edit-feedback-$key"
  if [ -e "$fbd" ] || [ -L "$fbd" ]; then
    bad "$c: $fbd already exists; refusing to reuse a real hook state dir"
    return
  fi
  mkdir -p "$T/fb-$c"; ln -s "$T/fb-$c" "$fbd"; FBLINKS+=("$fbd")
  : > "$T/$c.calls"
  printf '{"tool_input":{"file_path":"%s/a.ts"},"cwd":"%s"}' "$cwd" "$cwd" \
    | NPX_CALLS="$T/$c.calls" bash "$HOOK" 2> "$T/$c.err"
  echo $? > "$T/$c.rc"
  # The typecheck runs detached; wait for it to clear its running marker.
  for i in $(seq 1 150); do
    [ -d "$fbd/running" ] || break
    sleep 0.1
  done
  [ -d "$fbd/running" ] && bad "$c: the background check never finished (15s)"
}

run_hook H1 folder
run_hook H2 file
run_hook H3 none

# H1: folder layout → a bare `prisma generate`, before the tsc.
GEN=$(grep -nx 'prisma generate' "$T/H1.calls" | head -1 | cut -d: -f1)
TSC=$(grep -n '^tsc --noEmit' "$T/H1.calls" | head -1 | cut -d: -f1)
[ -n "$GEN" ] && ok || bad "H1: folder layout (prisma/schema/) must run a bare 'prisma generate'. npx calls: $(cat "$T/H1.calls")"
[ -n "$GEN" ] && [ -n "$TSC" ] && [ "$GEN" -lt "$TSC" ] \
  && ok || bad "H1: 'prisma generate' must come before the tsc. npx calls: $(cat "$T/H1.calls")"

# H2: single-file layout keeps generating.
grep -qx 'prisma generate' "$T/H2.calls" \
  && ok || bad "H2: prisma/schema.prisma must still run 'prisma generate'. npx calls: $(cat "$T/H2.calls")"

# H3: no schema at all → no prisma call, but the background check did run.
grep -q '^tsc --noEmit' "$T/H3.calls" \
  && ok || bad "H3: the background tsc never ran, so 'no prisma call' would be vacuous. npx calls: $(cat "$T/H3.calls")"
grep -q '^prisma' "$T/H3.calls" \
  && bad "H3: a repo with no Prisma schema must not run prisma. npx calls: $(cat "$T/H3.calls")" || ok

# H4: first edit, no diags yet → silent exit 0 every time.
for c in H1 H2 H3; do
  [ "$(cat "$T/$c.rc")" = 0 ] && [ ! -s "$T/$c.err" ] \
    && ok || bad "H4: $c hook must exit 0 with empty stderr, got rc $(cat "$T/$c.rc"), stderr: $(cat "$T/$c.err")"
done

# ── train: the shipped regenerate line ───────────────────────────────────────
REGEN="$T/regen.sh"
marked '# >>> prisma regenerate' '# <<< prisma regenerate' "$TRAIN_SRC" > "$REGEN"
if grep -q 'prisma generate' "$REGEN"; then
  ok
  for spec in T1:folder:yes T2:file:yes T3:none:no; do
    c=${spec%%:*}; rest=${spec#*:}; layout=${rest%%:*}; want=${rest#*:}
    cwd="$T/train-$c"; fixture "$cwd" "$layout"; : > "$T/$c.calls"
    ( cd "$cwd" && NPX_CALLS="$T/$c.calls" bash "$REGEN" ) >/dev/null 2>&1
    if [ "$want" = yes ]; then
      grep -qx 'prisma generate' "$T/$c.calls" \
        && ok || bad "$c: $layout layout must regenerate before the train's tsc. npx calls: $(cat "$T/$c.calls")"
    else
      grep -q '^prisma' "$T/$c.calls" \
        && bad "$c: no schema, the train must not run prisma. npx calls: $(cat "$T/$c.calls")" || ok
    fi
  done
else
  bad "T: bin/rebase-train.sh carries no '# >>> prisma regenerate' block with a prisma generate in it"
fi

# ── prompts: both layouts named where a model is told what to read ───────────
grep 'nav/app-map' "$DIR/bin/draft-proposal.sh" | grep -q 'prisma/schema/' \
  && ok || bad "P1: bin/draft-proposal.sh's PRD prompt must name the prisma/schema/ folder"
sed -n 6p "$DIR/prompts/product-stages/map.md" | grep -q 'prisma/schema/' \
  && ok || bad "P1: prompts/product-stages/map.md line 6 must name the prisma/schema/ folder"

echo "prisma-schema-layout.bh-1171: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
