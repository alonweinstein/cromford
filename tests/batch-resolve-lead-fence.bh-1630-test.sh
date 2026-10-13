#!/bin/bash
# tests/batch-resolve-lead-fence.bh-1630-test.sh — BH-1630: bin/batch-resolve.sh
# was a FOURTH landing path with no lead fence and no ticket-HOLD fence.
#
# THE HOLE. The candidate loop read a head-bound APPROVE, a tier and the block
# gate, and nothing else. The union train PR it opens is App-authored, so every
# merge lane's lead fence passes the TRAIN, and the members then land on main by
# ancestry. A lead PR with a box record and a box APPROVE (the #1547 shape), or
# a pool PR whose ticket the lead had put on HOLD, reached main that way with no
# lead verdict and through the HOLD.
#
# Driven against the SHIPPED lane, a REAL bare origin and a stub gh + a stub
# jobs worker (the batch-resolve-test.sh fixture, trimmed to what this needs):
#   F1 a lead PR with a box APPROVE and no lead row is NOT admitted to a train
#      (a pool sibling still rides, so the pass is not simply empty)
#   F2 the same lead PR IS admitted with a lead MERGE row on its exact head
#   F3 a lead MERGE row on an OLDER head does not admit it (the pin)
#   F4 a pool PR whose ticket is on HOLD is excluded; an unreadable hold is too
#   F5 an unreadable lead_pr_authors row excludes every candidate (whose PR is
#      the lead's cannot be told) and raises ONE lane-wide alert
#   T1 the App token's life is read (`gh-token.sh --expires-at`) before the
#      union is pushed: an expired token pushes nothing and defers the members,
#      never marks them red; an expiry that cannot be read is refused the same
#      way; the preflight asks it too, so no union is built on such a box
#   T2 BATCH_TOKEN_MIN_LIFE is the knob, and a token with the life it
#      asks for opens the train
#
# Run from anywhere: tests/batch-resolve-lead-fence.bh-1630-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
if [ -n "${BATCH_TEST_KEEP:-}" ]; then echo "fixture kept at $T"; else trap 'rm -rf "$T"' EXIT; fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
unset GH_TOKEN GH_ADMIN_TOKEN TO_LEAD_AUTHORS TO_LEAD_RC

SLUG=example-org/demo-os
PROJ=demo-os
LEAD=operator

# --- a real repository, and a real remote that never leaves this box ---------
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
S="$T/seed"
mkdir -p "$S/src" "$S/scripts" "$S/tests"
printf 'tests/static-guards.txt merge=union\n' > "$S/.gitattributes"
printf 'guard-base\n' > "$S/tests/static-guards.txt"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
printf 'export const base = 1\n' > "$S/src/base.ts"
cat > "$S/scripts/regen.sh" <<'REGEN'
#!/bin/sh
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/worker-import-set.json
REGEN
chmod +x "$S/scripts/regen.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/ci-stub.sh"; chmod +x "$S/ci-stub.sh"
cat > "$S/AGENT_ARCHITECTURE.md" <<'ARCH'
# Architecture

## Generated files

| File | Regenerate with |
|---|---|
| `scripts/worker-import-set.json` | `bash scripts/regen.sh` |
ARCH
cat > "$S/CLAUDE.md" <<'CLAUDEMD'
# demo-os

## Verification Contract

```bash
bash ci-stub.sh
```
CLAUDEMD
git -C "$S" add -A && git -C "$S" commit -qm base && git -C "$S" push -q origin main
BASE=$(git -C "$S" rev-parse HEAD)
# mkbranch <name> <marker> — one approved sibling (a source file of its own, a
# union-file line, a registry rewrite): clean against main, and only a
# registry/union conflict against each other — exactly what a train is for.
mkbranch() {
  git -C "$S" checkout -q -b "$1" "$BASE"
  printf 'export const %s = 1\n' "$2" > "$S/src/feature-$2.ts"
  printf 'guard-base\nguard-%s\n' "$2" > "$S/tests/static-guards.txt"
  printf '{"imports":["src/base.ts","src/feature-%s.ts"]}\n' "$2" > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$2" && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mkbranch ticket/tk-11 a)   # #101 a pool PR
HEAD_L=$(mkbranch ticket/tk-12 l)   # #102 the LEAD's PR, with a box record + box APPROVE (#1547)
HEAD_H=$(mkbranch ticket/tk-13 h)   # #103 a pool PR whose ticket is on HOLD
git -C "$S" checkout -q main
OLDHEAD=0000000011111111111111111111111111111111   # an earlier head of the lead PR

# --- the harness tree --------------------------------------------------------
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$H/tmp" \
         "$T/fakebin" "$T/repos" "$T/vd"
export FLEET_CONF="$H/fleet.conf"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-rest-list.sh" "$DIR/bin/lib/gh-app-auth.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# THE FENCES UNDER TEST, and the block gate whose streak carries their outage
# alert: the real libraries, never a paraphrase.
cp "$DIR/bin/lib/ticket-ownership.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/verdicts.sh" \
   "$DIR/bin/lib/block-gate.sh" "$H/bin/lib/"
cp "$DIR/bin/batch-resolve.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
: > "$H/env/github-app.env"
# gh-token.sh: an installation token for a mint; `--expires-at` answers
# $T/tok-exp (one line per call, the LAST line repeating), or fails when
# $T/tok-noexp exists (nothing cached for this repo). Every call is logged.
cat > "$H/bin/gh-token.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/tok-calls"
if [ "\${1:-}" = --expires-at ]; then
  [ -f "$T/tok-noexp" ] && exit 1
  n=\$(grep -c -- '--expires-at' "$T/tok-calls")
  l=\$(sed -n "\${n}p" "$T/tok-exp"); [ -n "\$l" ] || l=\$(tail -1 "$T/tok-exp")
  printf '%s\n' "\$l"; exit 0
fi
echo ghs_fixture_installation_token
EOF
chmod +x "$H/bin/gh-token.sh"
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "'"$T"'/alerts.txt"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# THE JOBS WORKER: the ledger is a file; lead_pr_authors is $T/lead ($T/lead-down
# = the read fails); a standing verdict on <sha> is $T/vd/<sha>.
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\t%s\n' "\$1" "\$2" "\${4:-}" >> "$T/mqueue.tsv"; echo queued; }
setting_get() {
  [ "\${1:-}" = lead_pr_authors ] || return 1
  [ -f "$T/lead-down" ] && return 2
  cat "$T/lead" 2>/dev/null
}
_jobs_req() {
  case "\${2:-}" in /api/verdicts\?*) ;; *) return 1 ;; esac
  local h="\${2##*head=}"; h="\${h%%&*}"
  if [ -f "$T/vd/\$h" ]; then cat "$T/vd/\$h"; else printf '{"standing":null,"rows":[]}\n'; fi
}
EOF
# vd_put <head> <verdict> <source> — one standing row on that head
vd_put() {
  jq -nc --arg v "$2" --arg s "$3" --arg h "$1" \
    '{standing:{id:7,pr:102,head_sha:$h,verdict:$v,source:$s,
      created_at:"2026-09-23T10:00:00Z",report_url:null,reviewer:"mac-lead"},head:$h,rows:[]}' > "$T/vd/$1"
}
git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
export MC_REPOS="$T/repos"

# --- the fake gh -------------------------------------------------------------
# The PR list is $T/prs.json; the PR objects themselves (pulls/<n>) are answered
# by tests/lib/gh-list-bridge.sh from that list, author and all. The ticket
# threads (the HOLD read) are $T/issue-<n>.comments; $T/issue-down-<n> fails it.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  # the block gate's thread reads (-q): an empty thread
  *" -q "*) exit 0 ;;
  # the HOLD read (bin/lib/hold.sh): the issue, then its comments
  "api repos/$SLUG/issues/"*"/comments"*|"api --paginate repos/$SLUG/issues/"*"/comments"*)
    [ -f "$T/issue-down-\$num" ] && { echo "HTTP 502: fixture" >&2; exit 1; }
    cat "$T/issue-\$num.comments" 2>/dev/null || echo '[]'; exit 0 ;;
  "api repos/$SLUG/issues/"*)
    [ -f "$T/issue-down-\$num" ] && { echo "HTTP 502: fixture" >&2; exit 1; }
    jq -nc --argjson n "\$num" '{number:\$n,state:"open",title:"a ticket",body:"do the thing",labels:[{name:"ai-build"}]}'; exit 0 ;;
  # the PR's OWN thread (BH-1668: to_merge_hold reads it over REST via gh_rest,
  # under the -i framing): the same per-number file, so a PR thread is clear
  # unless a case writes $T/issue-<pr>.comments
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*)
    [ -f "$T/issue-down-\$num" ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{"message":"fixture"}\n'; exit 0; }
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$T/issue-\$num.comments" 2>/dev/null || echo '[]'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/issues/"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open"}\n'; exit 0 ;;
  *"contents/.mergify.yml"*) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 0 ;;
  *"rulesets"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;
  *"api -i -X GET "*"/pulls/"*"/files"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;
  *"--json headRefOid"*)
    jq -r --arg n "\$num" '.[]|select(.number==(\$n|tonumber))|.headRefOid' "$T/prs.json"; exit 0 ;;
  *"pr list -R $SLUG --state open --author"*) cat "$T/prs.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"pr create"*)
    prev=""; for a in "\$@"; do
      [ "\$prev" = "--body-file" ] && cp "\$a" "$T/train-body.txt"
      prev="\$a"
    done
    echo "https://github.com/$SLUG/pull/900"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
command -v flock >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

# mkpr <num> <branch> <head> <author> <created>
mkpr() {
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg a "$4" --arg c "$5" --arg slug "$SLUG" '
    {number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", state:"OPEN", createdAt:$c,
     author:{login:$a}, title:("TK: "+$br), body:"", labels:[]}'
}
{ mkpr 101 ticket/tk-11 "$HEAD_A" app/cromford 2026-09-16T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_L" "$LEAD"           2026-09-16T02:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_H" app/cromford 2026-09-16T03:00:00Z; } | jq -sc '.' > "$T/prs.json"
# the build records: each PR's own head-bound box APPROVE, tier 2 — the lead
# PR's included, which is the #1547 shape the fence exists for.
mkrec() { # mkrec <issue> <pr-num> <head>
  local d="$H/builds/$PROJ-TK-$1-2026091600$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkrec 11 101 "$HEAD_A"
mkrec 12 102 "$HEAD_L"
mkrec 13 103 "$HEAD_H"

LOG="$H/logs/batch-resolve.log"
run() { BLOCK_GATE_STREAK_K=1 bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
reset() {
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"; cat "$T/run.out"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$T/ledger.tsv"; : > "$T/mqueue.tsv"; : > "$LOG"; : > "$T/run.out"
  : > "$T/alerts.txt"; : > "$T/tok-calls"
  printf '%s\n' "$LEAD" > "$T/lead"
  printf '2099-01-01T00:00:00Z\n' > "$T/tok-exp"
  rm -f "$T/train-body.txt" "$T/lead-down" "$T/tok-noexp" "$T"/issue-* "$T"/vd/*
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$H/state/merge-conductor"; scratch_rm "$H/state/merge-queue"
  scratch_rm "$H/state/ticket-ownership"; scratch_rm "$H/state/block-gate"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$T/origin.git" update-ref -d "$r"; done
}
nbatch() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/batch/' | grep -c . ; }
member() { grep -q "#$1 " "$T/train-body.txt" 2>/dev/null; }
tree_has() { # tree_has <marker> — the pushed union carries that member's file
  local refs br; refs=$(git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/batch/')
  br=$(head -1 <<<"$refs")
  [ -n "$br" ] && git -C "$T/origin.git" cat-file -e "$br:src/feature-$1.ts" 2>/dev/null
}
red_marked() { grep -q "^$1 " "$H/state/batch-resolve/$PROJ/red.txt" 2>/dev/null; }

# ============================================================================
# F1. A LEAD PR WITH A BOX APPROVE AND NO LEAD ROW IS NOT A TRAIN MEMBER
# ============================================================================
reset
run
[ "$(nbatch)" = 1 ] && ok || bad "F1: the pool siblings still ride one train (got $(nbatch) batch branch(es); log: $(tail -5 "$LOG"))"
member 101 && ok || bad "F1: the pool PR #101 is a member ($(cat "$T/train-body.txt" 2>/dev/null))"
member 102 && bad "F1: THE DEFECT — lead PR #102 (box APPROVE, no lead row) was admitted to the train ($(cat "$T/train-body.txt"))" || ok
tree_has l && bad "F1: THE DEFECT — the lead PR's commits are in the pushed union" || ok
grep -q '#102 MERGE_HELD lead-pr' "$LOG" && ok || bad "F1: the lead fence says why #102 stays out, in this lane's log ($(grep -F '#102' "$LOG" | head -3))"
grep -q 'lead-row-unreadable\|lead-authored' "$T/alerts.txt" && bad "F1: a lead PR WAITING on its lead is not an outage — no alert ($(cat "$T/alerts.txt"))" || ok

# ============================================================================
# F2. …AND IT IS A MEMBER WITH A LEAD MERGE ROW ON ITS EXACT HEAD
# ============================================================================
reset
vd_put "$HEAD_L" MERGE lead
run
member 102 && ok || bad "F2: a lead MERGE row on #102's exact head admits it ($(cat "$T/train-body.txt" 2>/dev/null); log: $(grep -F '#102' "$LOG" | head -3))"
tree_has l && ok || bad "F2: and the union carries exactly that head's commits"
member 101 && ok || bad "F2: the pool sibling rides beside it"
reset
vd_put "$HEAD_L" MERGE-WITH-NOTES lead
run
member 102 && ok || bad "F2: MERGE-WITH-NOTES clears it the same way"
# a lead BLOCK row (or any non-MERGE lead verdict) on the head keeps it out
reset
vd_put "$HEAD_L" REQUEST_CHANGES lead
run
member 102 && bad "F2: a standing lead REQUEST_CHANGES must not admit #102" || ok

# ============================================================================
# F3. A MERGE ROW ON AN OLDER HEAD IS NOT A CLEARANCE FOR THIS ONE (the pin)
# ============================================================================
reset
vd_put "$OLDHEAD" MERGE lead
run
member 102 && bad "F3: THE DEFECT — a lead MERGE row on an older head admitted #102 at ${HEAD_L:0:12}" || ok

# ============================================================================
# F4. A HELD TICKET'S PR IS NOT A TRAIN MEMBER; NOR IS ONE WHOSE HOLD IS UNREADABLE
#     (the lead PR is cleared by a lead row in every F4 pass, so two clear
#     siblings are left to conflict in the registry: a lone PR has no batch)
# ============================================================================
reset
vd_put "$HEAD_L" MERGE lead
printf '[{"id":1,"user":{"login":"%s"},"created_at":"2026-09-23T10:00:00Z","body":"HOLD\\n\\nThe lead is building this."}]\n' "$LEAD" > "$T/issue-13.comments"
run
member 103 && bad "F4: THE DEFECT — #103's ticket #13 is on HOLD and it rode a train ($(cat "$T/train-body.txt"))" || ok
tree_has h && bad "F4: THE DEFECT — the held PR's commits are in the pushed union" || ok
member 101 && ok || bad "F4: a sibling whose ticket is clear still rides ($(cat "$T/train-body.txt" 2>/dev/null); log: $(tail -4 "$LOG"))"
grep -q '#103 MERGE_HELD' "$LOG" && ok || bad "F4: the held member is named in the log ($(grep -F '#103' "$LOG" | head -3))"
red_marked 103 && bad "F4: a held member is NOT marked red — the hold ends by itself when RESUME is posted" || ok
# RESUME lifts it
reset
vd_put "$HEAD_L" MERGE lead
printf '[{"id":1,"user":{"login":"%s"},"created_at":"2026-09-23T10:00:00Z","body":"HOLD"},{"id":2,"user":{"login":"%s"},"created_at":"2026-09-23T11:00:00Z","body":"RESUME"}]\n' "$LEAD" "$LEAD" > "$T/issue-13.comments"
run
member 103 && ok || bad "F4: RESUME on the ticket lifts the hold and #103 rides again ($(grep -F '#103' "$LOG" | head -3))"
# the hold read fails: fail closed
reset
vd_put "$HEAD_L" MERGE lead
touch "$T/issue-down-13"
run
member 103 && bad "F4: THE DEFECT — #103's hold could not be read and it rode anyway (fail OPEN)" || ok
member 101 && ok || bad "F4: an unreadable hold on one ticket does not stop its siblings"

# ============================================================================
# F5. AN UNREADABLE lead_pr_authors ROW EXCLUDES EVERY CANDIDATE + ONE ALERT
# ============================================================================
reset
touch "$T/lead-down"
run
[ "$(nbatch)" = 0 ] && ok || bad "F5: THE DEFECT — with lead_pr_authors unreadable no PR can be told apart from a lead PR, so nothing is batched (got $(nbatch) branch(es): $(cat "$T/train-body.txt" 2>/dev/null))"
[ ! -f "$T/train-body.txt" ] && ok || bad "F5: and no train PR is opened"
LA=$(grep -c 'lead-row-unreadable' "$T/alerts.txt" 2>/dev/null || true)
[ "$LA" = 1 ] && ok || bad "F5: THREE members in one lead-row outage raise ONE lane-wide alert (got $LA: $(cat "$T/alerts.txt"))"
grep -q 'lead-row-unreadable:[^ ]*:batch-resolve' "$T/alerts.txt" && ok \
  || bad "F5: the alert id is this lane's (lead-row-unreadable:<box>:batch-resolve): $(cat "$T/alerts.txt")"
red_marked 101 && bad "F5: an outage does not mark a member red" || ok
# a second pass inside the same outage is still the one alert
run
LA=$(grep -c 'lead-row-unreadable' "$T/alerts.txt" 2>/dev/null || true)
[ "$LA" = 1 ] && ok || bad "F5: a second pass in the same outage adds no alert (got $LA)"

# ============================================================================
# T1. THE APP TOKEN'S LIFE IS READ BEFORE THE UNION IS PUSHED
# ============================================================================
# the preflight's read is fine, the pre-push read finds the token expired: the
# #1624 round-4 shape (a push, then a `gh pr create` that fails).
reset
printf '2099-01-01T00:00:00Z\n2020-01-01T00:00:00Z\n' > "$T/tok-exp"
run
[ "$(grep -c -- '--expires-at' "$T/tok-calls")" -ge 2 ] && ok \
  || bad "T1: the token's expiry is read at the preflight AND before the push ($(cat "$T/tok-calls"))"
[ "$(nbatch)" = 0 ] && ok || bad "T1: THE DEFECT — an expired App token must stop the PUSH, not only the create (got $(nbatch) batch branch(es))"
grep -q 'pr create' "$T/gh-calls.txt" && bad "T1: no train PR is opened on an expired token" || ok
red_marked 101 && bad "T1: an infrastructure refusal is a deferral, never a red mark" || ok
grep -q 'batch-train-no-app-token' "$T/alerts.txt" && ok || bad "T1: the refusal raises the no-App-token alert ($(cat "$T/alerts.txt"))"
grep -qi 'expire' "$LOG" && ok || bad "T1: the log says the token was expiring, not that none could be minted ($(tail -3 "$LOG"))"
# nothing cached for this repo (a token that is not this repo's): refused the same way, at the preflight
reset
touch "$T/tok-noexp"
run
[ "$(nbatch)" = 0 ] && ok || bad "T1: an unreadable expiry is refused (fail closed), got $(nbatch) branch(es)"
grep -q 'building a train' "$LOG" && bad "T1: the preflight refuses before any union is built ($(grep 'building a train' "$LOG" | head -1))" || ok
grep -q 'batch-train-no-app-token' "$T/alerts.txt" && ok || bad "T1: and raises the same alert"

# ============================================================================
# T2. BATCH_TOKEN_MIN_LIFE IS THE KNOB
# ============================================================================
reset
run
[ "$(nbatch)" = 1 ] && ok || bad "T2: a token with its life ahead of it opens the train (got $(nbatch); log $(tail -3 "$LOG"))"
grep -q -- '--min-life' "$T/tok-calls" && ok || bad "T2: the mint asks gh-token.sh for the knob's life, so a short cached token is re-minted rather than refused ($(cat "$T/tok-calls"))"
grep -q -- '--min-life 600 ' "$T/tok-calls" && ok || bad "T2: the default min life is 600s ($(grep -- '--min-life' "$T/tok-calls" | head -1))"
reset
printf 'BATCH_TOKEN_MIN_LIFE=900\n' > "$H/env/$PROJ.env"
run
grep -q -- '--min-life 900 ' "$T/tok-calls" && ok || bad "T2: BATCH_TOKEN_MIN_LIFE sets it ($(grep -- '--min-life' "$T/tok-calls" | head -1))"
rm -f "$H/env/$PROJ.env"

echo "batch-resolve-lead-fence.bh-1630: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
