#!/bin/bash
# tests/merge-conductor-stack-orphan.bh-3950-test.sh — BH-3950: a stacked child
# whose parent has NO PR is retargeted off the dead base, and a retarget off a
# closed or absent parent owes a head-bound re-review before it can merge.
#
# THE INCIDENT. project-4 #1778 (head ticket/TK-2103, base agent/TK-2102) sat in
# STACKED_WAIT for 4.6 days. Nothing ever opened a PR on agent/TK-2102, so
# mc_stack_parent answered NONE, the conductor's `case` had no NONE arm, and the
# stuck detector paged the same row every tick while nothing acted.
#
# Driven, not grepped: the conductor cases run bin/merge-conductor.sh itself
# with a stubbed gh/curl against a REAL local git origin (mc_orphan_clean's
# answer is about what git says), and assert on the gh argv, the state row and
# logs/merge-conductor.log. Two project fixtures, demo-os and project-4, because
# the logic has no project branch.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-stack-orphan.bh-3950-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export JOBS_URL=https://jobs.invalid
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] && [ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1   # impact: bin/merge-conductor.sh bin/lib/mc/rebase.sh
cp "$DIR/bin/lib/open-pr-precheck.sh" "$T/h/bin/lib/" || exit 1   # impact: bin/lib/open-pr-precheck.sh
mkdir -p "$T/repos" "$T/cfg"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
: > "$T/h/env/global.env"

# --- real git: one origin per project, a parent branch, two children ---------
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
declare -A CLEAN CARRY PARENT NUM HEADREF
PARENT[project-4]=agent/TK-2102; NUM[project-4]=1778; HEADREF[project-4]=ticket/TK-2103
PARENT[demo-os]=agent/TK-41;   NUM[demo-os]=42;   HEADREF[demo-os]=ticket/TK-42
for R in project-4 demo-os; do
  O="$T/$R.git"; S="$T/seed-$R"
  git config --global "url.$O.insteadOf" "https://x-access-token@github.com/example-org/$R.git"
  git config --global "url.$O.insteadOf" "https://github.com/example-org/$R.git" --add
  git init -q --bare "$O"; git clone -q "$O" "$S" 2>/dev/null
  mkdir -p "$S/src"; printf 'A1\n' > "$S/src/a.ts"
  git -C "$S" add -A; git -C "$S" commit -qm base; git -C "$S" push -q origin main
  B=$(git -C "$S" rev-parse HEAD)
  git -C "$S" checkout -q -b "${PARENT[$R]}" "$B"
  printf 'export const p = 1\n' > "$S/src/p.ts"
  git -C "$S" add -A; git -C "$S" commit -qm parent; git -C "$S" push -q origin "${PARENT[$R]}"
  # clean: cut from main, nothing of the parent in it
  git -C "$S" checkout -q -b kid-clean "$B"
  printf 'export const k = 1\n' > "$S/src/k.ts"
  git -C "$S" add -A; git -C "$S" commit -qm kid-clean; git -C "$S" push -q origin kid-clean
  CLEAN[$R]=$(git -C "$S" rev-parse HEAD)
  # carry: really cut from the parent, so the parent's commit rides in it
  git -C "$S" checkout -q -b kid-carry "${PARENT[$R]}"
  printf 'export const k2 = 1\n' > "$S/src/k2.ts"
  git -C "$S" add -A; git -C "$S" commit -qm kid-carry; git -C "$S" push -q origin kid-carry
  CARRY[$R]=$(git -C "$S" rev-parse HEAD)
  git clone -q "$O" "$T/repos/$R" 2>/dev/null
done

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init

# ============================================================================
# U. The helpers, pure (stubbed gh_rest / gh_rest_pr_list_var)
# ============================================================================
echo "== U. mc_branch_exists / mc_stack_parent's answer / mc_stack_parent_key / mc_orphan_clean carry=0 =="
U() { local st="$1" body="${2:-}"
      ( gh_rest() { GH_REST_STATUS="$st"; case "$st" in 200) printf '%s\n' "$body"; return 0 ;; 404) return 44 ;; *) return 75 ;; esac; }
        mc_branch_exists example-org/project-4 agent/TK-2102 ) >/dev/null 2>&1; echo $?; }
[ "$(U 200 '{"name":"agent/TK-2102","commit":{"sha":"abc"}}')" = 0 ] && ok || bad "U1 mc_branch_exists: a 200 naming the branch must be rc 0 (got $(U 200 '{"name":"agent/TK-2102"}'))"
[ "$(U 404)" = 1 ] && ok || bad "U2 mc_branch_exists: a 404 must be rc 1 (got $(U 404))"
[ "$(U 403)" = 2 ] && ok || bad "U3 mc_branch_exists: a 403 must be rc 2, never 'gone' (got $(U 403))"
[ "$(U 502)" = 2 ] && ok || bad "U3 mc_branch_exists: a 502 must be rc 2 (got $(U 502))"
[ "$(U 000)" = 2 ] && ok || bad "U3 mc_branch_exists: a network failure must be rc 2 (got $(U 000))"
[ "$(U 200 'not json')" = 2 ] && ok || bad "U3 mc_branch_exists: a 200 that does not parse must be rc 2 (got $(U 200 'not json'))"
UB=$( (gh_rest() { echo CALLED >> "$T/ub.txt"; return 0; }; mc_branch_exists example-org/project-4 '--upload-pack=x') >/dev/null 2>&1; echo $?)
[ "$UB" = 2 ] && [ ! -s "$T/ub.txt" ] && ok || bad "U3 mc_branch_exists: an unsafe name must be rc 2 before any read (got $UB)"

# mc_stack_parent's answer file: the split the NONE arm acts on. Its stdout is
# NONE in all three of the first cases, which is exactly why the file exists.
L() { local st="$1" body="${2:-}" f="$T/ans.L"
      ( gh_rest_pr_list_var() { GH_REST_STATUS="$st"; [ "$st" = 200 ] || return 75; printf -v "$1" '%s' "$body"; return 0; }
        MC_STACK_PARENT_ANS="$f" mc_stack_parent example-org/project-4 agent/TK-2102 ) >/dev/null 2>&1
      cat "$f" 2>/dev/null; rm -f "$f"; }
[ "$(L 200 '[]')" = none ] && ok || bad "U4 an empty list must record a VERIFIED none (got '$(L 200 '[]')')"
[ -z "$(L 200 '[{"state":"closed","merged_at":null}]')" ] && ok || bad "U5 a list with a PR must not record none (got '$(L 200 '[{"state":"closed"}]')')"
case "$(L 403)" in "HTTP 403"*) ok ;; *) bad "U6 a 403 must record its status, never none (got '$(L 403)')" ;; esac
[ "$(L 200 '{"message":"x"}')" = unparseable ] && ok || bad "U6 a 200 that is not a list must record unparseable, never none (got '$(L 200 '{"message":"x"}')')"
OUTW=$( (gh_rest_pr_list_var() { printf -v "$1" '%s' '[]'; return 0; }; MC_STACK_PARENT_ANS="$T/ans.x" mc_stack_parent example-org/project-4 agent/TK-2102) 2>/dev/null | tr '\t' ' ')
[ "$OUTW" = "NONE -" ] && ok || bad "mc_stack_parent's stdout must stay 'NONE<TAB>-' (mc_retry_pr reads it; got '$OUTW')"

[ "$(mc_stack_parent_key agent/TK-2102 2>/dev/null)" = TK-2102 ] && ok || bad "mc_stack_parent_key agent/TK-2102 must be TK-2102 (got '$(mc_stack_parent_key agent/TK-2102 2>/dev/null)')"
[ "$(mc_stack_parent_key ticket/TK-2102-r3 2>/dev/null)" = TK-2102 ] && ok || bad "mc_stack_parent_key ticket/TK-2102-r3 must be TK-2102 (got '$(mc_stack_parent_key ticket/TK-2102-r3 2>/dev/null)')"
[ -z "$(mc_stack_parent_key feature/x 2>/dev/null)" ] && type mc_stack_parent_key >/dev/null 2>&1 && ok || bad "mc_stack_parent_key must print nothing for a branch that names no ticket"

if mc_git_has_merge_tree; then
  export MC_REPOS="$T/repos"
  # No token on a test box: the auth is stubbed to the URL the insteadOf above
  # maps onto the local bare origin, as tests/generated-files-train.bh-969 does.
  mc_git_auth() { MC_REMOTE="https://github.com/$1.git"; return 0; }
  OUT=$(mc_orphan_clean example-org/project-4 project-4 main agent/never-existed "${CLEAN[project-4]}" 0); RC=$?
  [ "$RC" = 0 ] && ok || bad "U7 mc_orphan_clean carry=0: a gone parent and a clean kid must be rc 0 (rc $RC: $OUT)"
  grep -q 'gone and never had a PR' <<<"$OUT" && ok || bad "U7 the carry=0 answer must say what it judged (got: $OUT)"
  OUT=$(mc_orphan_clean example-org/project-4 project-4 main agent/never-existed "${CLEAN[project-4]}"); RC=$?
  [ "$RC" = 1 ] && ok || bad "U7 without the sixth argument the gone parent must stay a hand-off, rc 1 (rc $RC: $OUT)"
  unset MC_REPOS; unset -f mc_git_auth
fi

# ============================================================================
# The driven conductor. Every per-repo answer is a file under $T/cfg, so each
# case is a handful of writes and one tick.
#   <r>.plist   empty|403|502|open|closed|merged — the parent list read
#   <r>.branch  200|404|403 — GET branches/<parent>
#   <r>.okey    empty|open|403 — the open list on ticket/<parent key>
#   <r>.ci      none|green ; <r>.head <sha> ; <r>.base <list base>
# ============================================================================
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
R=\$(printf '%s' "\$*" | grep -o 'example-org/[a-z-]*' | head -1); R=\${R#example-org/}
C="$T/cfg/\$R"
cf() { cat "\$C.\$1" 2>/dev/null; }
PAR=\$(cf parent); N=\$(cf num); HD=\$(cf head); HREF=\$(cf headref)
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/\$R/pulls/\$N -f base="*)
    printf '%s\n' "\$*" >> "$T/patches.txt"; A="\$*"; printf '%s' "\${A##*base=}" > "\$C.base"; exit 0 ;;
  *"api -X PATCH"*"-f state="*) printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merges.txt"; exit 1 ;;
  *"api -X PATCH"*|*"pr close"*|*"issue close"*|*"api -i -X POST"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -i -X GET repos/example-org/\$R/branches/"*)
    case "\$(cf branch)" in
      200) restpr --raw 200 "{\"name\":\"\$PAR\",\"commit\":{\"sha\":\"abc\"}}" ;;
      404) restpr --raw 404 '{"message":"Branch not found"}' ;;
      *)   restpr --raw 403 '{"message":"Forbidden"}' ;;
    esac ;;
  *"-f state=all -f head=example-org:\$PAR "*)
    case "\$(cf plist)" in
      empty)  restpr --raw 200 '[]' ;;
      403)    restpr --raw 403 '{"message":"API rate limit exceeded"}' ;;
      502)    restpr --raw 502 '{"message":"Bad Gateway"}' ;;
      open)   restpr --raw 200 '[{"number":2102,"state":"open","merged_at":null,"html_url":"https://github.com/example-org/'"\$R"'/pull/2102"}]' ;;
      closed) restpr --raw 200 '[{"number":2102,"state":"closed","merged_at":null,"html_url":"https://github.com/example-org/'"\$R"'/pull/2102"}]' ;;
      merged) restpr --raw 200 '[{"number":2102,"state":"closed","merged_at":"2026-10-01T00:00:00Z","html_url":"https://github.com/example-org/'"\$R"'/pull/2102"}]' ;;
    esac ;;
  *"-f state=open -f head=example-org:ticket/"*)
    A="\$*"; case "\$A" in *"head=example-org:\$(cf okeybr) "*) OK=1 ;; *) OK=0 ;; esac
    if [ "\$(cf okey)" = 403 ] && [ "\$OK" = 1 ]; then restpr --raw 403 '{"message":"Forbidden"}'
    elif [ "\$(cf okey)" = open ] && [ "\$OK" = 1 ]; then
      restpr --raw 200 "[{\"number\":2099,\"state\":\"open\",\"head\":{\"ref\":\"\$(cf okeybr)\"}}]"
    else restpr --raw 200 '[]'; fi ;;
  *"-f state=all -f head=example-org:\$(cf rebuild) "*)
    restpr --raw 200 '[{"number":2110,"state":"open","merged_at":null,"html_url":"https://github.com/example-org/'"\$R"'/pull/2110"}]' ;;
  *"-f head=example-org:"*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/\$R --state open"*)
    printf '[{"number":%s,"url":"https://github.com/example-org/%s/pull/%s","headRefOid":"%s","headRefName":"%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"%s"}]\n' \
      "\$N" "\$R" "\$N" "\$HD" "\$HREF" "\$(cf base)" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) if [ "\$(cf ci)" = green ]; then restpr --runs 'completed|success'; else restpr --runs; fi ;;
  *"api -i -X GET repos/example-org/\$R/pulls/\$N/files"*) restpr --raw 200 '[{"filename":"src/k.ts"}]' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/\$R/pulls/\$N"*) restpr OPEN "\$HD" "\$HREF" "\$(cf base)" "" MERGEABLE CLEAN operator "" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

conf() { # conf <repo> <field> <value>
  printf '%s' "$3" > "$T/cfg/$1.$2"; }
fixture() { # fixture <repo> <clean|carry> — one stacked PR on the parent, default answers
  local r="$1" h
  [ "$2" = carry ] && h="${CARRY[$r]}" || h="${CLEAN[$r]}"
  conf "$r" parent "${PARENT[$r]}"; conf "$r" num "${NUM[$r]}"; conf "$r" headref "${HEADREF[$r]}"
  conf "$r" head "$h"; conf "$r" base "${PARENT[$r]}"
  conf "$r" plist empty; conf "$r" branch 404; conf "$r" okey empty; conf "$r" ci none; conf "$r" rebuild none-such
  local k; k=$(mc_stack_parent_key "${PARENT[$r]}" 2>/dev/null); conf "$r" okeybr "ticket/${k,,}"
  local d="$T/h/builds/pool-$r-${HEADREF[$r]#ticket/}-202610030001"
  rm -rf "$T/h/builds/pool-$r-"*; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/$r/pull/${NUM[$r]}" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$h" > "$d/reviewed-sha"
}
fleet() { : > "$T/h/fleet.conf"
  for r in "$@"; do printf '%s example-org/%s https://%s.example /api/board 2 box-%s\n' "$r" "$r" "$r" "$r" >> "$T/h/fleet.conf"; done; }
reset_case() {
  rm -rf "$T/h/state/merge-conductor" "$T/h/logs" "$T/h/locks"
  mkdir -p "$T/h/logs" "$T/h/locks" "$T/h/state/merge-conductor"
  : > "$T/patches.txt"; : > "$T/kicks.txt"; : > "$T/merges.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-calls.txt"
  touch "$T/h/flags/merge-conductor-actions"; rm -f "$T/h/flags/merge-conductor-merge"
}
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
             MC_MERGE_SETTLE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_REPOS="$T/repos" \
             env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
         || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
LOG="$T/h/logs/merge-conductor.log"
CK=example-org/project-4#1778; DK=example-org/demo-os#42
seed_stacked() { # seed_stacked <key> <age-secs> <head> — a STACKED_WAIT row that old
  printf '%s\tSTACKED_WAIT\t%s\t%s\t%s\t-\tbased on x\t%s\n' "$1" "$(( $(date -u +%s) - $2 ))" "$3" "$3" "https://github.com/${1%#*}/pull/${1##*#}" \
    >> "$T/h/state/merge-conductor/pr-state.tsv"; }
nopatch() { # nopatch <label> <key>
  [ ! -s "$T/patches.txt" ] && ok || bad "$1: must not PATCH the base (got: $(cat "$T/patches.txt"))"
  [ "$(state_of "$2")" = STACKED_WAIT ] && ok || bad "$1: the row must stay STACKED_WAIT (got '$(state_of "$2")' / '$(reason_of "$2")')"; }

# ============================================================================
# (a) THE INCIDENT: no parent PR, base branch 404 — both projects
# ============================================================================
echo "== (a) verified none + base branch gone =="
reset_case; fleet project-4 demo-os; fixture project-4 clean; fixture demo-os clean
# GONE for real: the parent branch is deleted from each origin, so the only
# answer mc_orphan_clean can give is the carry=0 one (put back after the case).
for r in project-4 demo-os; do git -C "$T/seed-$r" push -q origin --delete "${PARENT[$r]}"; done
tick
for r in project-4 demo-os; do git -C "$T/seed-$r" push -q origin "${PARENT[$r]}"; done
[ "$(grep -c 'api -X PATCH repos/example-org/project-4/pulls/1778 -f base=main' "$T/patches.txt")" = 1 ] \
  && ok || bad "(a) project-4 #1778 must get exactly one PATCH base=main (got: $(cat "$T/patches.txt"))"
[ "$(grep -c 'api -X PATCH repos/example-org/demo-os/pulls/42 -f base=main' "$T/patches.txt")" = 1 ] \
  && ok || bad "(a) demo #42 must get exactly one PATCH base=main — same logic, every project (got: $(cat "$T/patches.txt"))"
grep -q 'pulls/1778 -f state=closed' "$T/kicks.txt" && grep -q 'pulls/1778 -f state=open' "$T/kicks.txt" \
  && ok || bad "(a) a head with no runs must be CI-kicked after the retarget (got: $(cat "$T/kicks.txt"))"
grep -q "RETARGETED $CK base agent/TK-2102 -> main (parent: none, branch gone)" "$LOG" \
  && ok || bad "(a) the RETARGETED line must name the key, the old base and why (got: $(grep -o 'RETARGETED.*' "$LOG" 2>/dev/null))"
grep -q "RETARGETED $DK base agent/TK-41 -> main (parent: none, branch gone)" "$LOG" \
  && ok || bad "(a) demo-os must log its own RETARGETED line"
for K in "$CK" "$DK"; do
  [ -n "$(state_of "$K")" ] && [ "$(state_of "$K")" != STACKED_WAIT ] && ok || bad "(a) $K must leave STACKED_WAIT (got '$(state_of "$K")')"
  [ "$(reason_of "$K")" = "retargeted off closed parent - re-review owed" ] \
    && ok || bad "(a) $K's reason must be the owed re-review (got '$(reason_of "$K")')"
done
grep -q "rtreview $CK ${CLEAN[project-4]}" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null \
  && ok || bad "(a) the owed re-review must be recorded on the head"
[ ! -s "$T/merges.txt" ] && ok || bad "(a) nothing may merge (got: $(cat "$T/merges.txt"))"

# ============================================================================
# (a2)/(a3) the branch is still there, no PR, past the STACKED_WAIT TTL
# ============================================================================
echo "== (a2) branch present, no PR, past the TTL, clean kid =="
reset_case; fleet project-4; fixture project-4 clean; conf project-4 branch 200
seed_stacked "$CK" $((21600 + 60)) "${CLEAN[project-4]}"
tick
[ "$(grep -c 'pulls/1778 -f base=main' "$T/patches.txt")" = 1 ] && ok || bad "(a2) past the TTL a clean kid must be retargeted (got: $(cat "$T/patches.txt"); log: $(grep -o '1778.*' "$LOG" | tail -3))"
grep -q "RETARGETED $CK base agent/TK-2102 -> main (parent: none, branch ttl)" "$LOG" \
  && ok || bad "(a2) the RETARGETED line must say branch ttl"

echo "== (a3) branch present, no PR, past the TTL, kid carries the parent =="
reset_case; fleet project-4; fixture project-4 carry; conf project-4 branch 200
seed_stacked "$CK" $((21600 + 60)) "${CARRY[project-4]}"
tick
[ ! -s "$T/patches.txt" ] && ok || bad "(a3) a kid that carries the parent must not be retargeted (got: $(cat "$T/patches.txt"))"
grep -q "$CK BLOCKED_AGENT orphaned-child" "$LOG" && ok || bad "(a3) it must be handed to the resolver"
case "$(reason_of "$CK")" in orphaned-child*) ok ;; *) bad "(a3) the park must be orphaned-child (got '$(reason_of "$CK")')" ;; esac

# ============================================================================
# (b) and the negatives: none of these may PATCH
# ============================================================================
echo "== (b) / N1-N9 =="
reset_case; fleet project-4; fixture project-4 clean; conf project-4 plist 403; tick
nopatch "(b) parent list HTTP 403" "$CK"
grep -q 'UNVERIFIABLE' "$LOG" && ok || bad "(b) the unreadable read must say so"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 plist 502; tick
nopatch "N1 parent list HTTP 502" "$CK"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 plist open; tick
nopatch "N2 parent OPEN" "$CK"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 base main; tick
[ ! -s "$T/patches.txt" ] && ok || bad "N3 a PR already on the project base must not be PATCHed (got: $(cat "$T/patches.txt"))"
reset_case; rm -f "$T/h/flags/merge-conductor-actions"; fleet project-4; fixture project-4 clean; tick
nopatch "N4 observe mode" "$CK"
grep -q "$CK would retarget" "$LOG" && ok || bad "N4 observe mode must say what it would do"
reset_case; fleet project-4; fixture project-4 clean; tick MC_ORPHAN_RETARGET=0
nopatch "N5 MC_ORPHAN_RETARGET=0" "$CK"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 branch 200
seed_stacked "$CK" 600 "${CLEAN[project-4]}"; tick
nopatch "N6 branch present, no PR, inside the TTL" "$CK"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 okey open; tick
nopatch "N7 the parent ticket is open on ticket/TK-2102" "$CK"
grep -q -- '-f state=open -f head=example-org:ticket/TK-2102 ' "$T/gh-calls.txt" && ok || bad "N7 the parent-key guard must ask for ticket/TK-2102"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 okey 403; tick
nopatch "N8 open_pr_for_key unreadable" "$CK"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 branch 403; tick
nopatch "N9 branch GET HTTP 403" "$CK"
reset_case; fleet project-4; fixture project-4 clean; conf project-4 rebuild agent/TK-2102-r3; tick
nopatch "N10 the parent's rebuild is open on agent/TK-2102-r3" "$CK"
grep -q -- '-f state=all -f head=example-org:agent/TK-2102-r3 ' "$T/gh-calls.txt" && ok || bad "N10 the NONE arm must probe the parent's rebuilds (mc_retry_pr)"

# ============================================================================
# B1: a gone parent with MC_RETARGET_REREVIEW=0 — nothing would read the
# parent's commits the child carries, so carry=0 is not taken: full check,
# orphaned-child, no PATCH (the kid really carries the parent here).
# ============================================================================
echo "== B1 verified none + gone branch + MC_RETARGET_REREVIEW=0 =="
reset_case; fleet project-4; fixture project-4 carry
git -C "$T/seed-project-4" push -q origin --delete "${PARENT[project-4]}"
tick MC_RETARGET_REREVIEW=0
git -C "$T/seed-project-4" push -q origin "${PARENT[project-4]}"
[ ! -s "$T/patches.txt" ] && ok || bad "B1 MC_RETARGET_REREVIEW=0 must not retarget a gone parent's child unread (got: $(cat "$T/patches.txt"))"
grep -q "$CK BLOCKED_AGENT orphaned-child" "$LOG" && ok || bad "B1 it must be handed to the resolver as orphaned-child (log: $(grep -o '1778.*' "$LOG" | tail -3))"
case "$(reason_of "$CK")" in orphaned-child*) ok ;; *) bad "B1 the park must be orphaned-child (got '$(reason_of "$CK")')" ;; esac
grep -q "rtreview $CK" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "B1 no retarget, so no marker" || ok

# ============================================================================
# (c) CLOSED parent, no rebuild, clean kid: retarget AND a re-review owed
# ============================================================================
echo "== (c) parent CLOSED, clean kid =="
reset_case; fleet project-4 demo-os; fixture project-4 clean; fixture demo-os clean
conf project-4 plist closed; conf demo-os plist closed; conf project-4 branch 200; conf demo-os branch 200
tick
for r in project-4 demo-os; do
  K="example-org/$r#${NUM[$r]}"
  [ "$(grep -c "pulls/${NUM[$r]} -f base=main" "$T/patches.txt")" = 1 ] && ok || bad "(c) $K must be retargeted (got: $(cat "$T/patches.txt"))"
  grep -q "rtreview $K ${CLEAN[$r]}" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null \
    && ok || bad "(c) $K must owe a re-review on its head"
  grep -q "$K retargeted off closed parent - re-review owed on ${CLEAN[$r]:0:8}" "$LOG" && ok || bad "(c) $K must log the owed re-review"
  [ "$(reason_of "$K")" = "retargeted off closed parent - re-review owed" ] && ok || bad "(c) $K's reason must be the owed re-review (got '$(reason_of "$K")')"
done
# the next tick: on main now, CI green -> the head-bound review is bought
conf project-4 ci green; conf demo-os ci green
tick
RRD="$T/h/state/merge-conductor/rereview"
for r in project-4 demo-os; do
  K="example-org/$r#${NUM[$r]}"
  JF="$RRD/example-org_${r}_${NUM[$r]}_${CLEAN[$r]}.json"
  grep -q "$K REREVIEW_SPAWNED" "$LOG" && ok || bad "(c) $K's owed re-review must be spawned once CI is green (log: $(grep -o "$K .*" "$LOG" | tail -3))"
  [ "$(jq -r '.head_sha // empty' "$JF" 2>/dev/null)" = "${CLEAN[$r]}" ] && ok || bad "(c) $K's re-review job must be on the PR head ($(ls "$RRD" 2>/dev/null))"
done

echo "== R2: the next tick, review still running, merges ON =="
for r in project-4 demo-os; do
  JF="$RRD/example-org_${r}_${NUM[$r]}_${CLEAN[$r]}.json"
  P0=$(jq -r '.pid // 0' "$JF" 2>/dev/null); [ "${P0:-0}" -gt 1 ] 2>/dev/null && kill -9 -- -"$P0" "$P0" 2>/dev/null
  sleep 300 & SP=$!; echo "$SP" >> "$T/sleepers"
  mc_rr_write "$JF" running "$SP" "$(date -u +%s)" 0 - "${CLEAN[$r]}" "${CLEAN[$r]}" "${JF%.json}.out"
done
touch "$T/h/flags/merge-conductor-merge"
tick
[ ! -s "$T/merges.txt" ] && ok || bad "R2 a PR whose owed re-review is still running must not merge (got: $(cat "$T/merges.txt"))"
for r in project-4 demo-os; do
  K="example-org/$r#${NUM[$r]}"
  [ "$(state_of "$K")" = WAIT_REVIEW ] && [ "$(reason_of "$K")" = "retargeted off closed parent - re-review owed" ] \
    && ok || bad "R2 $K must stay WAIT_REVIEW owed (got '$(state_of "$K")' / '$(reason_of "$K")')"
done
while read -r SP; do kill "$SP" 2>/dev/null; done < "$T/sleepers"

# ============================================================================
# R3/R4: what the owed read's ANSWER does. A done APPROVE bought after the
# retarget releases the hold (rtcleared); a done BLOCK parks
# head-not-reapproved for the resolver.
# ============================================================================
rr_done() { # rr_done <repo> <verdict> — the post-retarget job for the clean head finishes
  local r="$1" jf="$RRD/example-org_${1}_${NUM[$1]}_${CLEAN[$1]}.json"
  printf 'findings\nVERDICT: %s\n' "$2" > "${jf%.json}.out"
  mc_rr_write "$jf" done 0 "$(date -u +%s)" "$(date -u +%s)" "$2" "${CLEAN[$r]}" "${CLEAN[$r]}" "${jf%.json}.out"; }
echo "== R3 the owed re-review APPROVES -> hold released =="
rm -f "$T/h/flags/merge-conductor-merge"
rr_done project-4 APPROVE; rr_done demo-os BLOCK
tick
grep -q "rtcleared $CK ${CLEAN[project-4]}" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null \
  && ok || bad "R3 an APPROVE bought after the retarget must record rtcleared (log: $(grep -o "$CK .*" "$LOG" | tail -3))"
grep -q "$CK re-review owed after the retarget APPROVED ${CLEAN[project-4]:0:8}" "$LOG" && ok || bad "R3 the release must be logged"
case "$(reason_of "$CK")" in "retargeted off closed parent - re-review owed"*) bad "R3 $CK must leave the owed hold (got '$(state_of "$CK")' / '$(reason_of "$CK")')" ;; *) ok ;; esac
echo "== R4 the owed re-review BLOCKS -> head-not-reapproved =="
[ "$(state_of "$DK")" = BLOCKED_HUMAN ] && [ "$(reason_of "$DK")" = head-not-reapproved ] \
  && ok || bad "R4 a BLOCK must park head-not-reapproved (got '$(state_of "$DK")' / '$(reason_of "$DK")')"
grep -q "rtcleared $DK" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "R4 a BLOCK must not release the hold" || ok
[ ! -s "$T/merges.txt" ] && ok || bad "R4 nothing may merge with merges off (got: $(cat "$T/merges.txt"))"

# ============================================================================
# B2: a clearance that PREDATES the retarget must not release the hold. The
# retarget leaves the head where it was, so both shapes below judged the diff
# against the dead parent.
# ============================================================================
echo "== B2a a provcleared row on the head from before the retarget =="
reset_case; fleet project-4; fixture project-4 clean; conf project-4 plist closed; conf project-4 branch 200
echo "provcleared $CK ${CLEAN[project-4]}" >> "$T/h/state/merge-conductor/attempts.txt"
tick
conf project-4 ci green; touch "$T/h/flags/merge-conductor-merge"
tick
[ "$(state_of "$CK")" = WAIT_REVIEW ] && [ "$(reason_of "$CK")" = "retargeted off closed parent - re-review owed" ] \
  && ok || bad "B2a a pre-retarget provcleared must not release the owed hold (got '$(state_of "$CK")' / '$(reason_of "$CK")')"
grep -q "$CK REREVIEW_SPAWNED" "$LOG" && ok || bad "B2a the owed read must still be bought (log: $(grep -o "$CK .*" "$LOG" | tail -3))"
[ ! -s "$T/merges.txt" ] && ok || bad "B2a nothing may merge on the pre-retarget clearance (got: $(cat "$T/merges.txt"))"
P0=$(jq -r '.pid // 0' "$RRD/example-org_project-4_1778_${CLEAN[project-4]}.json" 2>/dev/null); [ "${P0:-0}" -gt 1 ] 2>/dev/null && kill -9 -- -"$P0" "$P0" 2>/dev/null

echo "== B2b a head-bound read of the head from before the retarget =="
reset_case; fleet project-4; fixture project-4 clean; conf project-4 plist closed; conf project-4 branch 200
mkdir -p "$RRD"; rr_done project-4 APPROVE
tick
grep -q "rtpreread $CK ${CLEAN[project-4]}" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null \
  && ok || bad "B2b a head already read at the retarget must be marked rtpreread"
conf project-4 ci green; touch "$T/h/flags/merge-conductor-merge"
tick; tick
[ "$(state_of "$CK")" = WAIT_REVIEW ] && case "$(reason_of "$CK")" in "retargeted off closed parent - re-review owed; "*"already read against the dead parent"*) true ;; *) false ;; esac \
  && ok || bad "B2b the pre-retarget APPROVE must not release the hold (got '$(state_of "$CK")' / '$(reason_of "$CK")')"
grep -q "rtcleared $CK" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "B2b no rtcleared on a pre-retarget read" || ok
[ ! -s "$T/merges.txt" ] && ok || bad "B2b nothing may merge on the pre-retarget read (got: $(cat "$T/merges.txt"))"

# ============================================================================
# R1: the kill flag — (c) with MC_RETARGET_REREVIEW=0 keeps the review
# ============================================================================
echo "== R1 MC_RETARGET_REREVIEW=0 =="
reset_case; fleet project-4; fixture project-4 clean; conf project-4 plist closed; conf project-4 branch 200
tick MC_RETARGET_REREVIEW=0
[ "$(grep -c 'pulls/1778 -f base=main' "$T/patches.txt")" = 1 ] && ok || bad "R1 the retarget itself still happens (got: $(cat "$T/patches.txt"))"
grep -q "rtreview $CK" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "R1 MC_RETARGET_REREVIEW=0 must write no marker" || ok
conf project-4 ci green; tick MC_RETARGET_REREVIEW=0
grep -q "$CK REREVIEW_SPAWNED" "$LOG" && bad "R1 MC_RETARGET_REREVIEW=0 must spawn no re-review" || ok

# ============================================================================
# (d) MERGED parent: the retarget keeps its review (unchanged arm)
# ============================================================================
echo "== (d) parent MERGED =="
reset_case; fleet project-4; fixture project-4 clean; conf project-4 plist merged; conf project-4 branch 200
tick
[ "$(grep -c 'pulls/1778 -f base=main' "$T/patches.txt")" = 1 ] && ok || bad "(d) a MERGED parent still retargets (got: $(cat "$T/patches.txt"))"
grep -q "rtreview $CK" "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null && bad "(d) a MERGED parent must not owe a re-review" || ok
conf project-4 ci green; tick
grep -q "$CK REREVIEW_SPAWNED" "$LOG" && bad "(d) a MERGED parent's child must not have a re-review bought" || ok

echo "merge-conductor-stack-orphan.bh-3950: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
