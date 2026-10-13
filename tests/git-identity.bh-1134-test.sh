#!/bin/bash
# tests/git-identity.bh-1134-test.sh — bin/lib/git-identity.sh and the lanes it
# pins (BH-1134): one definition of "the configured commit author", exported to
# every agent session, and checked before the lander pushes.
#
#   1. gi_resolve reads the GLOBAL config, falls back to the fleet default, and
#      ignores a repo-local user.email an agent could have written
#   2. gi_check rc 0 on matching commits (case/space variants, a merge commit),
#      rc 1 naming the sha on an author-only and a committer-only mismatch
#   3. gi_check rc 3 on a ref that will not resolve — never clean
#   4. bin/agent-call.sh exports the four GIT_* vars to the runner it launches,
#      over whatever the caller's env carried (fake claude on PATH)
#   5. the REAL bin/lander.sh refuses to push a --author Fable resolution and
#      still pushes a clean one
#   6. gi_ensure_global sets only what is unset
#
# No network, no model call. Every git config write goes to a scratch
# GIT_CONFIG_GLOBAL. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 tests/git-identity.bh-1134-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# shellcheck source=bin/lib/git-identity.sh
. "$DIR/bin/lib/git-identity.sh" || exit 1
export GIT_CONFIG_GLOBAL="$T/gitconfig"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
setglobal() { : > "$GIT_CONFIG_GLOBAL"; [ -n "$1" ] && git config --global user.name "$1"; [ -n "$2" ] && git config --global user.email "$2"; return 0; }

echo "== 1. gi_resolve =="
setglobal "Box Owner" owner@box.test
R="$T/r1"; git init -q "$R"; git -C "$R" config user.email noreply@anthropic.com; git -C "$R" config user.name "Claude Fable 5.1"
( cd "$R" && GI_NAME=; GI_EMAIL=; gi_resolve; printf '%s|%s' "$GI_NAME" "$GI_EMAIL" ) > "$T/res"
[ "$(cat "$T/res")" = "Box Owner|owner@box.test" ] && ok \
  || bad "1: resolve inside a repo with a poisoned LOCAL config must read the global one (got $(cat "$T/res"))"
setglobal "" ""
( GI_NAME=; GI_EMAIL=; gi_resolve; printf '%s|%s' "$GI_NAME" "$GI_EMAIL" ) > "$T/res"
[ "$(cat "$T/res")" = "operator|operator@example.com" ] && ok || bad "1: an empty global must fall back to operator|operator@example.com (got $(cat "$T/res"))"
setglobal "" half@box.test
( GI_NAME=; GI_EMAIL=; gi_resolve; printf '%s|%s' "$GI_NAME" "$GI_EMAIL" ) > "$T/res"
[ "$(cat "$T/res")" = "operator|half@box.test" ] && ok || bad "1: each half falls back on its own (got $(cat "$T/res"))"

echo "== 2/3. gi_check =="
setglobal "Box Owner" owner@box.test
GI_NAME=; GI_EMAIL=; gi_resolve
G="$T/g"; git init -q -b main "$G"
mk() { # mk <name> <ae> <ce> <file> — one commit with the given author/committer
  printf '%s\n' "$4" > "$G/$4"; git -C "$G" add -A
  GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$3" \
    git -C "$G" commit -qm "$4"
}
mk o owner@box.test owner@box.test base; BASE=$(git -C "$G" rev-parse HEAD)
mk o 'Owner@BOX.test ' ' owner@box.test' variant
git -C "$G" checkout -qb side "$BASE"; mk o owner@box.test owner@box.test sidefile
git -C "$G" checkout -q main
GIT_AUTHOR_NAME=o GIT_AUTHOR_EMAIL=OWNER@box.test GIT_COMMITTER_NAME=o GIT_COMMITTER_EMAIL=owner@box.test \
  git -C "$G" merge -q --no-edit side
[ "$(git -C "$G" rev-list --merges --count HEAD)" = 1 ] && ok || bad "2: fixture must hold a merge commit"
OUT=$(gi_check "$G" "$BASE"); RC=$?
[ "$RC" = 0 ] && ok || bad "2: case/space variants and a matching merge must be clean (rc $RC: $OUT)"
TOP=$(git -C "$G" rev-parse HEAD)
mk "Claude Fable 5.1" noreply@anthropic.com owner@box.test authoronly; A1=$(git -C "$G" rev-parse HEAD)
OUT=$(gi_check "$G" "$TOP"); RC=$?
[ "$RC" = 1 ] && ok || bad "2: an author-only mismatch must be rc 1 (rc $RC)"
grep -q "^${A1:0:8} author=noreply@anthropic.com committer=owner@box.test" <<<"$OUT" && ok \
  || bad "2: the mismatch must name the sha and both emails (got: $OUT)"
git -C "$G" reset -q --hard "$TOP"
mk o owner@box.test noreply@anthropic.com committeronly
OUT=$(gi_check "$G" "$TOP"); RC=$?
[ "$RC" = 1 ] && ok || bad "2: a committer-only mismatch must be rc 1 (rc $RC: $OUT)"
# A foreign MERGE is a commit the push carries.
git -C "$G" reset -q --hard "$TOP"
git -C "$G" checkout -qb side2 "$BASE"; mk o owner@box.test owner@box.test side2file; git -C "$G" checkout -q main
GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=noreply@anthropic.com GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=noreply@anthropic.com \
  git -C "$G" merge -q --no-edit side2
OUT=$(gi_check "$G" "$TOP" side2); RC=$?
[ "$RC" = 1 ] && ok || bad "2: a foreign-authored merge commit must be counted (rc $RC)"
git -C "$G" reset -q --hard "$TOP"
OUT=$(gi_check "$G" "$TOP" origin/no-such-branch); RC=$?
[ "$RC" = 3 ] && ok || bad "3: an unresolvable exclude must be rc 3, never clean (rc $RC)"
OUT=$(gi_check "$T/not-a-repo" "$TOP"); RC=$?
[ "$RC" = 3 ] && ok || bad "3: a non-repo must be rc 3 (rc $RC)"

echo "== 4. bin/agent-call.sh pins the identity for the runner =="
A="$T/ac"; mkdir -p "$A/logs" "$A/locks" "$A/flags" "$A/state" "$A/fakebin"
cat > "$A/fakebin/claude" <<'EOF'
#!/bin/bash
env | grep '^GIT_\(AUTHOR\|COMMITTER\)_' | sort > "$ENV_SINK"
printf '{"result":"ok","usage":{"input_tokens":1,"output_tokens":1},"total_cost_usd":0}\n'
EOF
cat > "$A/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*|-k) shift ;; esac
case "${1:-}" in [0-9]*) ;; *) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$A/fakebin/billing-mode.sh"
chmod +x "$A/fakebin/"*
setglobal "Box Owner" owner@box.test
WANTENV=$(printf 'GIT_AUTHOR_EMAIL=owner@box.test\nGIT_AUTHOR_NAME=Box Owner\nGIT_COMMITTER_EMAIL=owner@box.test\nGIT_COMMITTER_NAME=Box Owner')
for pre in clean poisoned; do
  rm -f "$T/env.txt"
  if [ "$pre" = poisoned ]; then set -- GIT_AUTHOR_EMAIL=noreply@anthropic.com GIT_COMMITTER_NAME="Claude Fable 5.1"; else set --; fi
  ( export ENV_SINK="$T/env.txt" PATH="$A/fakebin:$PATH" HARNESS="$A" HOME="$A" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
    env "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5 60 "$T/ac-out.txt" "hello" >/dev/null 2>&1 )
  [ -s "$T/env.txt" ] && ok || bad "4/$pre: the runner saw no GIT_* var at all (or was never launched)"
  [ "$(cat "$T/env.txt" 2>/dev/null)" = "$WANTENV" ] && ok \
    || bad "4/$pre: the runner must see all four GIT_* vars = the global identity (got: $(tr '\n' ';' < "$T/env.txt" 2>/dev/null))"
done

echo "== 5. the real bin/lander.sh refuses a foreign author =="
setglobal operator lander@box.test
L="$T/L"; LH="$L/h"; ORIGIN="$L/origin.git"; SEED="$L/seed"
mkdir -p "$LH/bin/lib" "$LH/env" "$LH/flags" "$LH/logs" "$LH/state" "$LH/repos" "$L/fakebin"
sed -e 's|^HARNESS=/root/harness$|HARNESS="${HARNESS:-/root/harness}"|' \
    -e 's|^REPO_DIR="/root/repos/\$PROJECT"$|REPO_DIR="$HARNESS/repos/$PROJECT"|' \
    "$DIR/bin/lander.sh" > "$LH/bin/lander.sh"
grep -qF 'HARNESS="${HARNESS:-/root/harness}"' "$LH/bin/lander.sh" && grep -qF 'REPO_DIR="$HARNESS/repos/$PROJECT"' "$LH/bin/lander.sh" \
  && ok || bad "5: the scratch-root rewrites did not match — this case would drive /root/harness"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/git-identity.sh" "$DIR/bin/lib/deployment.sh" "$LH/bin/lib/"
# BH-4080: the lander reads the repo slug from fleet.conf (no literal table).
cp "$DIR/bin/fleet-conf.sh" "$LH/bin/" && printf 'project-3 example-org/project-3\n' > "$LH/fleet.conf"
# BH-2504: the lander pushes only through bin/lib/hold-push.sh (+ hold.sh).
. "$DIR/tests/lib/hold-fixture.sh" && hold_fixture_libs "$DIR" "$LH" || exit 1
printf 'lane_model() { echo claude-test; }\n' > "$LH/bin/lib/lane-model.sh"
: > "$LH/env/global.env"; : > "$LH/env/project-3.env"
printf '#!/bin/bash\nexit 0\n' > "$LH/bin/beat.sh"
cat > "$LH/bin/agent-call.sh" <<EOF
#!/bin/bash
cd "\$(sed -n 's/^You are resolving merge conflicts in the git worktree at \\([^ ]*\\) .*/\\1/p' <<<"\$6")" || exit 1
printf 'both sides, resolved\n' > a.txt; git add -A
case "\$(cat "$L/mode")" in
  author) git commit -q --author="Claude Fable 5.1 <noreply@anthropic.com>" -m "Lander: merge main" ;;
  *)      git commit -q -m "Lander: merge main" ;;
esac
EOF
cat > "$L/fakebin/gh" <<EOF
#!/bin/bash
echo "ticket/TK-7 \$(git -C "$ORIGIN" rev-parse ticket/TK-7)"
EOF
chmod +x "$LH/bin/"*.sh "$L/fakebin/gh"
git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q -b main "$SEED"; git -C "$SEED" remote add origin "$ORIGIN"
printf 'base\n' > "$SEED/a.txt"; git -C "$SEED" add -A; git -C "$SEED" -c user.email=t@t -c user.name=t commit -qm base
git -C "$SEED" push -q origin main
mkbr() { # mkbr <branch> — a branch that conflicts with main on a.txt
  git -C "$SEED" checkout -q -B "$1" "$(git -C "$SEED" rev-list --max-parents=0 main)"
  printf 'branch line\n' > "$SEED/a.txt"; git -C "$SEED" -c user.email=t@t -c user.name=t commit -qam "work $1"
  git -C "$SEED" push -q -f origin "$1"
}
mkbr ticket/TK-7
git -C "$SEED" checkout -q main; printf 'main line\n' > "$SEED/a.txt"
git -C "$SEED" -c user.email=t@t -c user.name=t commit -qam "main work"; git -C "$SEED" push -q origin main
git clone -q "$ORIGIN" "$LH/repos/project-3"
run_lander() {
  rm -f "$LH/state/lander/project-3-7"; : > "$LH/logs/lander.log"
  env -i PATH="$L/fakebin:/usr/bin:/bin" HOME="$L" HARNESS="$LH" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
    bash "$LH/bin/lander.sh" project-3 7 >"$L/out.txt" 2>&1
}
B7=$(git -C "$ORIGIN" rev-parse ticket/TK-7)
echo author > "$L/mode"; run_lander; RC=$?
[ "$RC" = 1 ] && ok || bad "5: a --author Fable resolution must exit 1 (rc $RC; log: $(cat "$LH/logs/lander.log"))"
grep -q '#7 lander: commit author is not lander@box.test .*— not pushed' "$LH/logs/lander.log" && ok \
  || bad "5: the lander log must name the expected email and refuse (got: $(cat "$LH/logs/lander.log"))"
[ "$(git -C "$ORIGIN" rev-parse ticket/TK-7)" = "$B7" ] && ok || bad "5: the foreign-authored resolution reached origin"
echo plain > "$L/mode"; run_lander; RC=$?
[ "$RC" = 0 ] && ok || bad "5: a clean resolution must still push (rc $RC; log: $(cat "$LH/logs/lander.log"); out: $(tail -3 "$L/out.txt"))"
[ "$(git -C "$ORIGIN" rev-parse ticket/TK-7)" != "$B7" ] && ok || bad "5: the clean resolution was not pushed"
IDS=$(git -C "$ORIGIN" log --format='%ae %ce' ticket/TK-7 --not "$B7" main | sort -u)
[ "$IDS" = "lander@box.test lander@box.test" ] && ok || bad "5: the pushed commits must be the configured identity (got: $(tr '\n' ';' <<<"$IDS"))"
mv "$LH/bin/lib/git-identity.sh" "$L/away"
mkbr ticket/TK-7; B7=$(git -C "$ORIGIN" rev-parse ticket/TK-7)
echo plain > "$L/mode"; run_lander; RC=$?
[ "$RC" = 1 ] && [ "$(git -C "$ORIGIN" rev-parse ticket/TK-7)" = "$B7" ] && ok \
  || bad "5: with no identity lib the lander must not push (rc $RC; log: $(cat "$LH/logs/lander.log"))"
grep -q 'check could not run' "$LH/logs/lander.log" && ok || bad "5: the refusal must say the check could not run"
mv "$L/away" "$LH/bin/lib/git-identity.sh"

echo "== 6. gi_ensure_global =="
setglobal "" ""
gi_ensure_global
[ "$(git config --global user.email)|$(git config --global user.name)" = "operator@example.com|operator" ] && ok \
  || bad "6: an unset global must be set to the fleet default (got $(git config --global user.email)|$(git config --global user.name))"
setglobal "Someone Else" else@box.test
gi_ensure_global
[ "$(git config --global user.email)|$(git config --global user.name)" = "else@box.test|Someone Else" ] && ok \
  || bad "6: a configured identity must never be overwritten"
bash -n "$DIR/bin/bootstrap-machine.sh" && ok || bad "6: bin/bootstrap-machine.sh does not parse"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
