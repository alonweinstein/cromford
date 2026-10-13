#!/bin/bash
# tests/model-route-seed-lint.bh-1928-test.sh — bin/model-route-seed-lint.sh
# (BH-1928, item 1 of the #1917 review follow-ups).
#
# A model_routes seed change for a role that already exists is inert on live
# (every seed skips a role with hub audit history, BH-1572), so the lint fails
# it unless the same diff ships the audited PUT or the `seed-only: fresh-db`
# waiver. Driven through the real script's seams against
# tests/fixtures/model-route-seed-lint/, and its parser against the REAL
# worker/jobs/schema.sql.
#   L1 the parser reads the real schema.sql: every seed shape, >= 40 roles.
#   L2 a changed existing role with nothing else -> rc 1, the role named
#      (8-field value change, a rung added to a 4-field role, the bare SELECT
#      rung, a role dropped).
#   L3 the audited PUT in bin/ or scripts/ -> rc 0; L3n a bin/ file without
#      the API, one that only reads it and MENTIONS a PUT (the real resolver
#      among them), a script naming only a longer role, or the PUT under
#      tests/ -> rc 1.
#   L4 the waiver in PR_BODY or on an added line -> rc 0, the roles printed.
#   L5 negatives that must pass: a new role, stamps only, a comment only, the
#      same tuple syntax in another table, schema.sql not in the diff.
#   L6 CI runs it: one step in the lint job, PR_BODY through env.
#   L7 git mode (base..HEAD in a scratch repository), the way CI calls it.
#
# Run from anywhere: tests/model-route-seed-lint.bh-1928-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/model-route-seed-lint.sh"
F="$DIR/tests/fixtures/model-route-seed-lint"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SCH=worker/jobs/schema.sql

# A root the lint reads changed files from, with the fixture scripts at the
# paths a real PR would put them.
R="$T/root"; mkdir -p "$R/bin" "$R/scripts" "$R/tests"
cp "$F/bin-put-ok.sh" "$R/bin/mr-put-build-qa.sh"
cp "$F/bin-no-api.sh" "$R/bin/mr-no-api.sh"
cp "$F/bin-prefix-role.sh" "$R/bin/mr-prefix.sh"
cp "$F/bin-put-ok.sh" "$R/scripts/mr-put-build-qa.sh"
cp "$F/bin-put-ok.sh" "$R/tests/mr-put-build-qa.sh"
cp "$F/bin-put-curl.sh" "$R/bin/mr-put-curl.sh"
cp "$F/bin-prose-only.sh" "$R/bin/mr-prose-only.sh"
cp "$F/bin-put-other-api.sh" "$R/bin/mr-put-other-api.sh"
mkdir -p "$R/bin/lib"; cp "$DIR/bin/lib/model-route.sh" "$R/bin/lib/model-route.sh"

lint() { # lint <head.sql> <files (newline-separated)> [ENV=VAL...] -> $OUT, $RC
  local head="$1" files="$2"; shift 2
  OUT=$(env -u PR_BODY MRSL_ROOT="$R" MRSL_BASE_SQL="$F/base.sql" MRSL_HEAD_SQL="$head" \
    MRSL_FILES="$files" MRSL_ADDED="" "$@" bash "$LINT" 2>&1); RC=$?
}

# --- L1. the real schema.sql -------------------------------------------------
P=$(MRSL_ROOT="$DIR" MRSL_FILES="$SCH" MRSL_PARSE_ONLY=1 bash "$LINT"); RC=$?
ROLES=$(printf '%s\n' "$P" | cut -f1 | sort -u)
NR=$(printf '%s\n' "$ROLES" | grep -c .)
[ "$RC" = 0 ] && [ "$NR" -ge 40 ] && ok || bad "L1 the real schema.sql must parse to >= 40 roles: rc=$RC n=$NR"
for r in build.plan stage.plan housekeeping.floor bootstrap.smoke fireworks.floor claude.ladder; do
  grep -qxF "$r" <<<"$ROLES" && ok || bad "L1 the real seed must include $r"
done
# housekeeping.floor carries both its 8-field rung 0 and its bare-SELECT rung 1.
[ "$(printf '%s\n' "$P" | awk -F'\t' '$1=="housekeeping.floor"{print $2}' | paste -sd,)" = "0,1" ] \
  && ok || bad "L1 housekeeping.floor must parse both rungs: $(printf '%s\n' "$P" | grep housekeeping.floor)"
# Every row has four non-empty fields and a numeric position.
printf '%s\n' "$P" | awk -F'\t' 'NF!=4 || $1=="" || $2!~/^[0-9]+$/ || $3=="" || $4=="" {bad=1} END{exit bad}' \
  && ok || bad "L1 malformed parsed row"
# The 50-ish tuples in the file, not fewer: every rung of every seed shape.
NT=$(printf '%s\n' "$P" | grep -c .)
[ "$NT" -ge 60 ] && ok || bad "L1 only $NT rungs parsed from the real seed"

# --- L2. a changed existing role, nothing else -> rc 1 -----------------------
lint "$F/head-changed.sql" "$SCH"
[ "$RC" = 1 ] && grep -q 'FAIL.*build\.qa' <<<"$OUT" \
  && ok || bad "L2 a changed build.qa seed must fail: rc=$RC $OUT"
grep -q 'build\.plan' <<<"$OUT" && bad "L2 an unchanged role must not be named: $OUT" || ok
lint "$F/head-rung-added.sql" "$SCH"
[ "$RC" = 1 ] && grep -q 'FAIL.*claude\.ladder' <<<"$OUT" && ok || bad "L2 a rung added to claude.ladder must fail: rc=$RC $OUT"
lint "$F/head-select-changed.sql" "$SCH"
[ "$RC" = 1 ] && grep -q 'FAIL.*housekeeping\.floor' <<<"$OUT" && ok || bad "L2 the bare SELECT rung must count: rc=$RC $OUT"
grep -v "'build.plan'" "$F/base.sql" > "$T/head-dropped.sql"
lint "$T/head-dropped.sql" "$SCH"
[ "$RC" = 1 ] && grep -q 'FAIL.*build\.plan' <<<"$OUT" && ok || bad "L2 a role dropped from the seed must fail: rc=$RC $OUT"

# --- L3. the audited PUT ------------------------------------------------------
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/mr-put-build-qa.sh"
[ "$RC" = 0 ] && grep -q 'build\.qa.*bin/mr-put-build-qa\.sh' <<<"$OUT" \
  && ok || bad "L3 a bin/ one-shot that PUTs build.qa must satisfy the lint: rc=$RC $OUT"
lint "$F/head-changed.sql" "$SCH"$'\n'"scripts/mr-put-build-qa.sh"
[ "$RC" = 0 ] && ok || bad "L3 a scripts/ migration that PUTs build.qa must satisfy the lint: rc=$RC $OUT"
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/mr-put-curl.sh"
[ "$RC" = 0 ] && ok || bad "L3 a curl -X PUT one-shot must satisfy the lint: rc=$RC $OUT"
# A file that reads the API and only SAYS "PUT /api/model-routes" is not the
# PUT — the fixture has the shape of the resolver, and the real resolver too
# (it names every build role and GETs /api/model-routes).
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/mr-prose-only.sh"
[ "$RC" = 1 ] && ok || bad "L3n a GET plus a 'PUT /api/model-routes' message must not count: rc=$RC $OUT"
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/mr-put-other-api.sh"
[ "$RC" = 1 ] && ok || bad "L3n a PUT to another API that names the role must not count: rc=$RC $OUT"
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/lib/model-route.sh"
[ "$RC" = 1 ] && ok || bad "L3n the real bin/lib/model-route.sh is not an audited PUT for build.qa: rc=$RC $OUT"
# L3n. presence of the role alone, a prefix-sharing role, a tests/ file, or a
# file that is not in the diff are not the PUT.
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/mr-no-api.sh"
[ "$RC" = 1 ] && ok || bad "L3n a bin/ file that names the role but never calls /api/model-routes must not count: rc=$RC"
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/mr-prefix.sh"
[ "$RC" = 1 ] && ok || bad "L3n a script naming build.qa.x must not satisfy build.qa: rc=$RC"
# ...and the bound holds on the left too: a role that only ENDS in build.qa.
sed 's/"build\.qa\.x"/"pre.build.qa"/' "$F/bin-prefix-role.sh" > "$R/bin/mr-suffix.sh"
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/mr-suffix.sh"
[ "$RC" = 1 ] && ok || bad "L3n a script naming pre.build.qa must not satisfy build.qa: rc=$RC"
lint "$F/head-changed.sql" "$SCH"$'\n'"tests/mr-put-build-qa.sh"
[ "$RC" = 1 ] && ok || bad "L3n a tests/ file is not the audited PUT: rc=$RC"
lint "$F/head-changed.sql" "$SCH"$'\n'"bin/gone.sh"
[ "$RC" = 1 ] && ok || bad "L3n a changed file that no longer exists at HEAD must not count: rc=$RC"
# One role covered does not cover another.
cp "$F/head-changed.sql" "$T/head-two.sql"
sed -i "s/'fireworks.floor', 0, 'model-f'/'fireworks.floor', 0, 'model-g'/" "$T/head-two.sql"
lint "$T/head-two.sql" "$SCH"$'\n'"bin/mr-put-build-qa.sh"
[ "$RC" = 1 ] && grep -q 'FAIL.*fireworks\.floor' <<<"$OUT" && ! grep -q 'FAIL.*build\.qa' <<<"$OUT" \
  && ok || bad "L3 each changed role needs its own PUT: rc=$RC $OUT"

# --- L4. the waiver -----------------------------------------------------------
lint "$F/head-changed.sql" "$SCH" PR_BODY=$'## What\nseed tweak\n\nseed-only: fresh-db\n'
[ "$RC" = 0 ] && grep -q 'WAIVED.*build\.qa' <<<"$OUT" \
  && ok || bad "L4 the waiver in the PR body must pass and name the waived roles: rc=$RC $OUT"
lint "$F/head-changed.sql" "$SCH" MRSL_ADDED="+  -- seed-only: fresh-db"
[ "$RC" = 0 ] && grep -q 'WAIVED.*build\.qa' <<<"$OUT" \
  && ok || bad "L4 the waiver on an added schema.sql line must pass: rc=$RC $OUT"
lint "$F/head-changed.sql" "$SCH" PR_BODY="seed only, fresh db"
[ "$RC" = 1 ] && ok || bad "L4 only the exact waiver text counts: rc=$RC"

# --- L5. negatives that must pass --------------------------------------------
lint "$F/head-new-role.sql" "$SCH"
[ "$RC" = 0 ] && ok || bad "L5 a brand-new role has no audit history and must pass: rc=$RC $OUT"
lint "$F/head-stamp-only.sql" "$SCH"
[ "$RC" = 0 ] && ok || bad "L5 updated_by/updated_at alone is not a change: rc=$RC $OUT"
lint "$F/head-comment-only.sql" "$SCH"
[ "$RC" = 0 ] && ok || bad "L5 a comment inside a model_routes statement is not a change: rc=$RC $OUT"
lint "$F/head-settings-only.sql" "$SCH"
[ "$RC" = 0 ] && ok || bad "L5 the same tuple syntax in another table is not a model_routes seed: rc=$RC $OUT"
lint "$F/head-changed.sql" "docs/MODEL-ROUTES.md"$'\n'"worker/jobs/src/lib/core.js"
[ "$RC" = 0 ] && ok || bad "L5 schema.sql not in the diff -> nothing to check: rc=$RC $OUT"
lint "$F/base.sql" "$SCH"
[ "$RC" = 0 ] && ok || bad "L5 an identical seed must pass: rc=$RC $OUT"

# --- L5b. git mode: an unresolvable base is could-not-run, never a pass ------
OUT=$(cd "$T" && env -u MRSL_FILES -u MRSL_BASE_SQL -u MRSL_ADDED MRSL_ROOT="$T" bash "$LINT" no-such-ref 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "L5b an unresolvable base must answer rc 2: rc=$RC $OUT"

# --- L7. git mode, as CI runs it: base..HEAD in a real repository ----------
G="$T/git"; mkdir -p "$G/worker/jobs" "$G/bin"
cp "$F/base.sql" "$G/$SCH"
git -C "$G" init -q -b main 2>/dev/null || git -C "$G" init -q
git -C "$G" -c user.email=t@t -c user.name=t add -A
git -C "$G" -c user.email=t@t -c user.name=t commit -qm base
git -C "$G" branch -f base-ref HEAD
git -C "$G" checkout -q -b pr
cp "$F/head-changed.sql" "$G/$SCH"
cp "$DIR/bin/lib/model-route.sh" "$G/bin/model-route-like.sh"   # a changed bin/ file that is not the PUT
git -C "$G" -c user.email=t@t -c user.name=t add -A
git -C "$G" -c user.email=t@t -c user.name=t commit -qm change
OUT=$(cd "$G" && env -u PR_BODY bash "$LINT" base-ref 2>&1); RC=$?
[ "$RC" = 1 ] && grep -q 'FAIL.*build\.qa' <<<"$OUT" && ok || bad "L7 git mode: a changed seed with no PUT must fail: rc=$RC $OUT"
OUT=$(cd "$G" && PR_BODY="seed-only: fresh-db" bash "$LINT" base-ref 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q 'WAIVED.*build\.qa' <<<"$OUT" && ok || bad "L7 git mode: the PR-body waiver must pass: rc=$RC $OUT"
printf '%s\n' '  -- seed-only: fresh-db' >> "$G/$SCH"
git -C "$G" -c user.email=t@t -c user.name=t commit -qam waiver
OUT=$(cd "$G" && env -u PR_BODY bash "$LINT" base-ref 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "L7 git mode: the waiver on an added schema.sql line must pass: rc=$RC $OUT"
git -C "$G" -c user.email=t@t -c user.name=t checkout -q -b pr2 base-ref
mkdir -p "$G/bin"; cp "$F/head-changed.sql" "$G/$SCH"; cp "$F/bin-put-ok.sh" "$G/bin/mr-put-build-qa.sh"
git -C "$G" -c user.email=t@t -c user.name=t add -A
git -C "$G" -c user.email=t@t -c user.name=t commit -qm put
OUT=$(cd "$G" && env -u PR_BODY bash "$LINT" base-ref 2>&1); RC=$?
[ "$RC" = 0 ] && grep -q 'bin/mr-put-build-qa\.sh' <<<"$OUT" && ok || bad "L7 git mode: the PUT in the same diff must pass: rc=$RC $OUT"

# --- L6. CI runs it -----------------------------------------------------------
WF="$DIR/.github/workflows/harness-ci.yml"
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$WF" <<'PY' && ok || bad "L6 harness-ci.yml must run the lint once in the lint job, PR_BODY via env"
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
s = [x for x in w['jobs']['lint']['steps'] if 'model-route-seed-lint.sh' in (x.get('run') or '')]
assert len(s) == 1, s
st = s[0]
assert 'bin/model-route-seed-lint.sh "origin/${{ github.base_ref }}"' in st['run'], st['run']
assert 'PR_BODY' in (st.get('env') or {}), st
assert '${{' not in st['run'].replace('${{ github.base_ref }}', ''), 'no other expression interpolated into run:'
assert st.get('if') == "github.event_name == 'pull_request'", st.get('if')
PY
else
  [ "$(grep -c 'bin/model-route-seed-lint.sh "origin/${{ github.base_ref }}"' "$WF")" = 1 ] \
    && grep -q 'PR_BODY: \${{ github.event.pull_request.body }}' "$WF" \
    && ok || bad "L6 harness-ci.yml must run the lint once with PR_BODY via env"
fi

echo "model-route-seed-lint.bh-1928: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
