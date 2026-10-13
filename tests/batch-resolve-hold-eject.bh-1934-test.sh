#!/bin/bash
# tests/batch-resolve-hold-eject.bh-1934-test.sh — BH-1934: a HOLD, or a
# withdrawn lead MERGE row, that lands AFTER a train has opened pulls that
# member out of the train.
#
# THE HOLE. bin/batch-resolve.sh asked to_lane_hold and to_lane_lead_fence
# (br_member_fenced, BH-1630) only in the candidate loop. Once a train was open,
# the settle pass read pre-emption, the dirty/behind re-form and the age budget,
# and nothing else — so a train opened with #101 and #102 kept #101 after its
# ticket was put on HOLD, bin/merge-queue.sh landed the train, and #101 reached
# main by ancestry through the HOLD.
#
# Driven against the SHIPPED lane, a REAL bare origin, the REAL ownership / hold
# / verdicts libraries, and a stub gh + jobs worker (the BH-1630 fixture, plus
# the BH-1306 train-state `gh pr view` stub):
#   E1 train {101,102}, HOLD on #101's ticket: the next settle re-forms the SAME
#      PR without #101 (members [102], reform_n 1, #101's commit gone from the
#      union), never closes it, and marks #101 neither red nor abandoned
#   E2 the same train is also BEHIND main: one re-form puts it on the tip AND
#      leaves the held member out
#   E3 a lead PR admitted on a lead MERGE row whose row is then withdrawn is
#      ejected the same way
#   E4 every member held (nothing left to re-form), and BATCH_REFORM_MAX=0:
#      the train is CLOSED, its branch deleted, its record abandoned with an
#      `ejected:` detail, and no member is excluded
#   E5 a gated pass (flags/batch-resolve-off) closes the train and builds or
#      pushes no union
#   E6 negatives: HOLD then RESUME; a ticket title carrying (HOLD) that a RESUME
#      comment lifted; a lead PR whose MERGE row still stands; a clear train —
#      none of them ejects, re-forms or closes anything
#   E7 a refused close releases nothing and changes no status
#
# Run from anywhere: tests/batch-resolve-hold-eject.bh-1934-test.sh  (exit 0 = pass)
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
unset GH_TOKEN GH_ADMIN_TOKEN TO_LEAD_AUTHORS TO_LEAD_RC BATCH_REFORM_MAX BATCH_TRAIN_MIN

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
# mkbranch <name> <marker> — one approved sibling: a source file of its own, a
# union-file line and a registry rewrite, so siblings conflict only in files a
# train is allowed to resolve.
mkbranch() {
  git -C "$S" checkout -q -b "$1" "$BASE"
  printf 'export const %s = 1\n' "$2" > "$S/src/feature-$2.ts"
  printf 'guard-base\nguard-%s\n' "$2" > "$S/tests/static-guards.txt"
  printf '{"imports":["src/base.ts","src/feature-%s.ts"]}\n' "$2" > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$2" && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mkbranch ticket/tk-11 a)   # #101 a pool PR (ticket #11)
HEAD_B=$(mkbranch ticket/tk-12 b)   # #102 a pool PR (ticket #12)
HEAD_L=$(mkbranch ticket/tk-13 l)   # #103 the LEAD's PR
git -C "$S" checkout -q main

# main_reset / main_advance — main back at BASE, or one commit past it (a
# sibling landed), on the origin AND in the hub clone.
main_to() {
  git -C "$S" checkout -q main && git -C "$S" reset -q --hard "$BASE"
  if [ "$1" = advance ]; then
    printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
    printf '{"imports":["src/base.ts","src/main-advance.ts"]}\n' > "$S/scripts/worker-import-set.json"
    git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null
  fi
  git -C "$S" push -qf origin main
  rm -rf "$T/repos/$PROJ"; git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
}

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
# THE FENCES UNDER TEST: the real libraries, never a paraphrase.
cp "$DIR/bin/lib/ticket-ownership.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/verdicts.sh" \
   "$DIR/bin/lib/block-gate.sh" "$H/bin/lib/"
# BR_UNDER_TEST lets the red proof run this suite against another copy of the
# lane (the merge base's) with the fixture unchanged.
cp "${BR_UNDER_TEST:-$DIR/bin/batch-resolve.sh}" "$H/bin/batch-resolve.sh"
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
: > "$H/env/github-app.env"
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$H/bin/gh-token.sh"
chmod +x "$H/bin/gh-token.sh"
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "'"$T"'/alerts.txt"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# THE JOBS WORKER: lead_pr_authors is $T/lead; a standing verdict on <sha> is
# $T/vd/<sha>; every merge_trains row is recorded (the ejected: detail rides it).
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\t%s\n' "\$1" "\$2" "\${4:-}" >> "$T/mqueue.tsv"; echo queued; }
merge_train_put() {
  local p="\$1" b="\$2" o="\$3"; shift 3
  printf '%s\t%s\t%s\t%s\n' "\$p" "\$b" "\$o" "\$*" >> "$T/trains.tsv"
  echo "\$o"
}
setting_get() {
  [ "\${1:-}" = lead_pr_authors ] || return 1
  cat "$T/lead" 2>/dev/null
}
_jobs_req() {
  case "\${2:-}" in /api/verdicts\?*) ;; *) return 1 ;; esac
  local h="\${2##*head=}"; h="\${h%%&*}"
  if [ -f "$T/vd/\$h" ]; then cat "$T/vd/\$h"; else printf '{"standing":null,"rows":[]}\n'; fi
}
EOF
vd_put() { # vd_put <head> <verdict> <source>
  jq -nc --arg v "$2" --arg s "$3" --arg h "$1" \
    '{standing:{id:7,pr:103,head_sha:$h,verdict:$v,source:$s,
      created_at:"2026-09-23T10:00:00Z",report_url:null,reviewer:"mac-lead"},head:$h,rows:[]}' > "$T/vd/$1"
}
git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
export MC_REPOS="$T/repos"

# --- the fake gh -------------------------------------------------------------
# PR list $T/prs.json; ticket threads $T/issue-<n>.comments (title override
# $T/issue-<n>.title); a train PR's state $T/train-state-<n>.json (default OPEN,
# MERGEABLE, CLEAN); a train close is recorded in $T/train-closed.txt, and
# $T/patch-refuse makes GitHub refuse it.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  "api -X PATCH repos/$SLUG/pulls/"*)
    [ -f "$T/patch-refuse" ] && { echo "HTTP 403: fixture refuses the close" >&2; exit 1; }
    printf '%s\n' "\$num" >> "$T/train-closed.txt"; echo '{"state":"closed"}'; exit 0 ;;
  *"pr view https://github.com/$SLUG/pull/"*)
    cat "$T/train-state-\$num.json" 2>/dev/null && exit 0
    echo '{"state":"OPEN","mergeCommit":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
    exit 0 ;;
  *" -q "*) exit 0 ;;
  "api repos/$SLUG/issues/"*"/comments"*|"api --paginate repos/$SLUG/issues/"*"/comments"*)
    cat "$T/issue-\$num.comments" 2>/dev/null || echo '[]'; exit 0 ;;
  "api repos/$SLUG/issues/"*)
    ttl=\$(cat "$T/issue-\$num.title" 2>/dev/null || echo "a ticket")
    jq -nc --argjson n "\$num" --arg t "\$ttl" '{number:\$n,state:"open",title:\$t,body:"do the thing",labels:[{name:"ai-build"}]}'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*)
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
    n=\$(( \$(cat "$T/prnum.txt" 2>/dev/null || echo 899) + 1 ))
    printf '%s\n' "\$n" > "$T/prnum.txt"
    printf '%s\n' "\$n" >> "$T/train-created.txt"
    echo "https://github.com/$SLUG/pull/\$n"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
command -v flock >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

mkpr() { # mkpr <num> <branch> <head> <author> <created>
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg a "$4" --arg c "$5" --arg slug "$SLUG" '
    {number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", state:"OPEN", createdAt:$c,
     author:{login:$a}, title:("TK: "+$br), body:"", labels:[]}'
}
PR_A=$(mkpr 101 ticket/tk-11 "$HEAD_A" app/cromford 2026-09-16T01:00:00Z)
PR_B=$(mkpr 102 ticket/tk-12 "$HEAD_B" app/cromford 2026-09-16T02:00:00Z)
PR_L=$(mkpr 103 ticket/tk-13 "$HEAD_L" "$LEAD"           2026-09-16T03:00:00Z)
mkrec() { # mkrec <issue> <pr-num> <head>
  local d="$H/builds/$PROJ-TK-$1-2026091600$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkrec 11 101 "$HEAD_A"
mkrec 12 102 "$HEAD_B"
mkrec 13 103 "$HEAD_L"

LOG="$H/logs/batch-resolve.log"
STATE="$H/state/batch-resolve/$PROJ"
HOLDDIR="$H/state/merge-conductor/batch-hold"
run() { bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
hold_on()   { printf '[{"id":1,"user":{"login":"%s"},"created_at":"2026-09-28T10:00:00Z","body":"HOLD\\n\\nThe lead wants a look first."}]\n' "$LEAD" > "$T/issue-$1.comments"; }
resume_on() { printf '[{"id":1,"user":{"login":"%s"},"created_at":"2026-09-28T10:00:00Z","body":"HOLD"},{"id":2,"user":{"login":"%s"},"created_at":"2026-09-28T11:00:00Z","body":"RESUME"}]\n' "$LEAD" "$LEAD" > "$T/issue-$1.comments"; }
reset() {
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"; cat "$T/run.out"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$T/ledger.tsv"; : > "$T/mqueue.tsv"; : > "$LOG"; : > "$T/run.out"
  : > "$T/alerts.txt"; : > "$T/trains.tsv"; : > "$T/train-closed.txt"; : > "$T/train-created.txt"
  printf '%s\n' "$LEAD" > "$T/lead"
  printf '899\n' > "$T/prnum.txt"
  rm -f "$T"/issue-* "$T"/vd/* "$T"/train-state-*.json "$T/patch-refuse" "$H/flags/"* 2>/dev/null
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$H/state/merge-conductor"; scratch_rm "$H/state/merge-queue"
  scratch_rm "$H/state/ticket-ownership"; scratch_rm "$H/state/block-gate"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$T/origin.git" update-ref -d "$r"; done
  main_to base
}
# open_train <pr-json>... — pass 1 opens ONE train of exactly these PRs; every
# artifact is then truncated, so a case asserts what the NEXT pass did.
#   Sets TBR (branch) REC (record) U0 (its union sha on the origin).
open_train() {
  printf '%s\n' "$@" | jq -sc '.' > "$T/prs.json"
  run
  TBR=$(git -C "$T/origin.git" for-each-ref --count=1 --format='%(refname:short)' 'refs/heads/batch/')
  REC="$STATE/train-${TBR##*/}.json"
  [ -n "$TBR" ] && [ -f "$REC" ] && [ "$(jq -r '.status' "$REC")" = open ] \
    || { echo "open_train: no open train ($(tail -5 "$LOG"))"; return 1; }
  U0=$(git -C "$T/origin.git" rev-parse "refs/heads/$TBR")
  : > "$LOG"; : > "$T/train-closed.txt"; : > "$T/train-created.txt"; : > "$T/trains.tsv"; : > "$T/alerts.txt"
  return 0
}
members()  { jq -r '[.members[].num] | join(",")' "$REC" 2>/dev/null; }
reforms()  { jq -r '.reform_n // 0' "$REC" 2>/dev/null; }
status()   { jq -r '.status' "$REC" 2>/dev/null; }
has_ref()  { git -C "$T/origin.git" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }
union_has() { # union_has <marker> — the train branch on the origin carries that member's file
  git -C "$T/origin.git" cat-file -e "refs/heads/$TBR:src/feature-$1.ts" 2>/dev/null; }
excluded() { grep -q "^$1 " "$STATE/red.txt" "$STATE/abandoned.txt" 2>/dev/null; }
batch_held() { ls "$HOLDDIR" 2>/dev/null | grep -q "_$1\$"; }
closed900() { grep -qxF 900 "$T/train-closed.txt" 2>/dev/null; }

# ============================================================================
# E1. THE TICKET'S ACCEPTANCE: HOLD ON A, THE NEXT SETTLE RE-FORMS WITHOUT A
# ============================================================================
reset
if open_train "$PR_A" "$PR_B"; then
  [ "$(members)" = "101,102" ] && union_has a && ok || bad "E1 setup: the train carries #101 and #102 ($(members))"
  hold_on 11
  run
  [ "$(members)" = 102 ] && ok \
    || bad "E1: THE DEFECT — #101's ticket went on HOLD after the train opened and it is still a member (members=$(members); log: $(tail -4 "$LOG"))"
  union_has a && bad "E1: THE DEFECT — the union on the origin still carries #101's commit, so the queue would land it through the HOLD" || ok
  git -C "$T/origin.git" merge-base --is-ancestor "$HEAD_A" "refs/heads/$TBR" 2>/dev/null \
    && bad "E1: #101's head is still an ancestor of the train branch" || ok
  union_has b && ok || bad "E1: the re-formed union still carries #102"
  [ "$(git -C "$T/origin.git" rev-parse "refs/heads/$TBR" 2>/dev/null)" != "$U0" ] && ok || bad "E1: the train branch must be force-pushed"
  [ "$(jq -r '.train_url' "$REC")" = "https://github.com/$SLUG/pull/900" ] && ok || bad "E1: the SAME PR carries the re-formed union"
  [ "$(reforms)" = 1 ] && ok || bad "E1: the ejection spends one re-form (reform_n=$(reforms))"
  [ "$(status)" = open ] && ok || bad "E1: the train stays open (status=$(status))"
  closed900 && bad "E1: a re-formable train is not closed" || ok
  [ -s "$T/train-created.txt" ] && bad "E1: no second train PR is opened ($(cat "$T/train-created.txt"))" || ok
  grep -q '#101 MERGE_HELD' "$LOG" && ok || bad "E1: the hold is named in the lane's log ($(grep -F '#101' "$LOG" | head -3))"
  grep -q 'ejected' "$LOG" && ok || bad "E1: the ejection is said out loud ($(tail -3 "$LOG"))"
  excluded 101 && bad "E1: a held member is NOT marked red or abandoned — RESUME must be enough to bring it back" || ok
  batch_held 101 && bad "E1: the ejected member is released to the conductor" || ok
  batch_held 102 && ok || bad "E1: the surviving member is still held by the train"
  [ -s "$T/alerts.txt" ] && bad "E1: a HOLD is an operator action, not a fault — no alert ($(cat "$T/alerts.txt"))" || ok
  # RESUME: A rides again. Its ticket is clear and it is no train's member.
  resume_on 11
  : > "$LOG"
  run
  grep -q '#101 MERGE_HELD' "$LOG" && bad "E1: after RESUME #101 is no longer fenced ($(grep -F '#101' "$LOG" | head -2))" || ok
  excluded 101 && bad "E1: after RESUME #101 is still not excluded" || ok
else
  bad "E1 fixture could not be armed"
fi

# ============================================================================
# E2. THE RE-FORM PATH: A BEHIND TRAIN WITH A HELD MEMBER
# ============================================================================
reset
if open_train "$PR_A" "$PR_B"; then
  main_to advance
  TIP=$(git -C "$T/origin.git" rev-parse refs/heads/main)
  hold_on 11
  run
  git -C "$T/origin.git" merge-base --is-ancestor "$TIP" "refs/heads/$TBR" 2>/dev/null && ok \
    || bad "E2: the re-formed union contains the new main tip ($(tail -3 "$LOG"))"
  union_has a && bad "E2: THE DEFECT — the behind re-form rebuilt the union WITH the held member" || ok
  union_has b && ok || bad "E2: the clear member is in the re-formed union"
  [ "$(members)" = 102 ] && ok || bad "E2: the record's members drop #101 (members=$(members))"
  [ "$(reforms)" = 1 ] && ok || bad "E2: ONE re-form covers both the tip and the ejection (reform_n=$(reforms))"
  excluded 101 && bad "E2: the held member is not in red.txt or abandoned.txt" || ok
  closed900 && bad "E2: nothing is closed" || ok
else
  bad "E2 fixture could not be armed"
fi

# ============================================================================
# E3. THE LEAD FENCE: A LEAD MERGE ROW WITHDRAWN AFTER THE TRAIN OPENED
# ============================================================================
reset
vd_put "$HEAD_L" MERGE lead
if open_train "$PR_A" "$PR_L"; then
  [ "$(members)" = "101,103" ] && ok || bad "E3 setup: the lead PR rode on its MERGE row ($(members))"
  rm -f "$T/vd/$HEAD_L"
  run
  [ "$(members)" = 101 ] && ok || bad "E3: THE DEFECT — the lead's MERGE row is gone and #103 is still a member (members=$(members))"
  union_has l && bad "E3: the lead PR's commit is gone from the union" || ok
  grep -q '#103 MERGE_HELD lead-pr' "$LOG" && ok || bad "E3: the lead fence says why ($(grep -F '#103' "$LOG" | head -3))"
  excluded 103 && bad "E3: an ejected lead PR is not excluded" || ok
else
  bad "E3 fixture could not be armed"
fi

# ============================================================================
# E4. NOTHING LEFT TO RE-FORM, AND A ZERO BUDGET: CLOSE, RELEASE, EXCLUDE NOBODY
# ============================================================================
reset
if open_train "$PR_A" "$PR_B"; then
  hold_on 11; hold_on 12
  run
  closed900 && ok || bad "E4a: every member held, so the train PR is CLOSED ($(tail -4 "$LOG"))"
  has_ref "$TBR" && bad "E4a: the dead train's branch is deleted" || ok
  [ "$(status)" = abandoned ] && ok || bad "E4a: the record reads abandoned (got $(status))"
  grep -q 'ejected: #101' "$T/trains.tsv" && ok || bad "E4a: the D1 row carries an ejected: detail ($(cat "$T/trains.tsv"))"
  { excluded 101 || excluded 102; } && bad "E4a: THE DEFECT — an ejection excluded a held member ($(cat "$STATE/abandoned.txt" 2>/dev/null))" || ok
  { batch_held 101 || batch_held 102; } && bad "E4a: both members are released" || ok
  [ -s "$T/alerts.txt" ] && bad "E4a: no alert for a hold ($(cat "$T/alerts.txt"))" || ok
else
  bad "E4a fixture could not be armed"
fi
reset
if open_train "$PR_A" "$PR_B"; then
  hold_on 11
  BATCH_REFORM_MAX=0 run
  closed900 && ok || bad "E4b: BATCH_REFORM_MAX=0 cannot re-form, so the train with a held member is CLOSED ($(tail -4 "$LOG"))"
  [ "$(status)" = abandoned ] && ok || bad "E4b: the record reads abandoned (got $(status))"
  has_ref "$TBR" && bad "E4b: the branch is deleted" || ok
  { excluded 101 || excluded 102; } && bad "E4b: neither the held member nor its clear sibling is excluded ($(cat "$STATE/abandoned.txt" 2>/dev/null))" || ok
  # the clear sibling is not excluded, so it is a candidate again; a lone PR
  # never forms a train, so it is simply left to the ordinary path
  batch_held 102 && bad "E4b: #102 is released" || ok
else
  bad "E4b fixture could not be armed"
fi

# ============================================================================
# E5. A GATED PASS CLOSES THE TRAIN AND BUYS NO UNION
# ============================================================================
reset
if open_train "$PR_A" "$PR_B"; then
  hold_on 11
  touch "$H/flags/batch-resolve-off"
  run
  closed900 && ok || bad "E5: under the gate a landable train with a held member is still CLOSED ($(tail -4 "$LOG"))"
  grep -q 'RE-FORMED\|building a train' "$LOG" && bad "E5: a gated pass builds no union ($(grep 'RE-FORMED\|building' "$LOG" | head -2))" || ok
  grep -q 'on a gated pass' "$LOG" && ok || bad "E5: the log says why no re-form was tried ($(tail -2 "$LOG"))"
  has_ref "$TBR" && bad "E5: the branch is deleted" || ok
  [ "$(status)" = abandoned ] && ok || bad "E5: the record reads abandoned (got $(status))"
  excluded 101 && bad "E5: the held member is not excluded" || ok
else
  bad "E5 fixture could not be armed"
fi

# ============================================================================
# E6. NEGATIVES — nothing is ejected, re-formed or closed
# ============================================================================
reset
if open_train "$PR_A" "$PR_B"; then
  resume_on 11
  run
  { [ "$(members)" = "101,102" ] && [ "$(reforms)" = 0 ] && ! closed900; } && ok \
    || bad "E6a: HOLD followed by RESUME is clear (members=$(members) reform_n=$(reforms) closed=$(cat "$T/train-closed.txt"))"
  [ "$(git -C "$T/origin.git" rev-parse "refs/heads/$TBR")" = "$U0" ] && ok || bad "E6a: the branch is untouched"
else
  bad "E6a fixture could not be armed"
fi
reset
if open_train "$PR_A" "$PR_B"; then
  # the title idiom IS a hold (bin/lib/hold.sh), and the newest comment lifting
  # it is what makes it clear — the #1934 thread's own shape
  printf 'TK-11 re-check (HOLD) and the lead fence\n' > "$T/issue-11.title"
  printf '[{"id":1,"user":{"login":"%s"},"created_at":"2026-09-28T13:20:00Z","body":"RESUME. This ticket is not on hold."}]\n' "$LEAD" > "$T/issue-11.comments"
  run
  { [ "$(members)" = "101,102" ] && [ "$(reforms)" = 0 ] && ! closed900; } && ok \
    || bad "E6b: a (HOLD) title lifted by a RESUME comment is clear (members=$(members) reform_n=$(reforms); $(grep -F '#101' "$LOG" | head -2))"
else
  bad "E6b fixture could not be armed"
fi
reset
vd_put "$HEAD_L" MERGE lead
if open_train "$PR_A" "$PR_L"; then
  run
  { [ "$(members)" = "101,103" ] && [ "$(reforms)" = 0 ] && ! closed900; } && ok \
    || bad "E6c: a lead PR whose MERGE row still stands on its head stays (members=$(members) reform_n=$(reforms))"
  grep -q 'ejected' "$LOG" && bad "E6c: nothing is ejected ($(grep ejected "$LOG" | head -1))" || ok
  grep -q 'PATCH' "$T/gh-calls.txt" && bad "E6c: no PATCH is sent for a clear train" || ok
else
  bad "E6c fixture could not be armed"
fi

# ============================================================================
# E7. A REFUSED CLOSE RELEASES NOTHING AND CHANGES NO STATUS
# ============================================================================
reset
if open_train "$PR_A" "$PR_B"; then
  hold_on 11
  touch "$T/patch-refuse"
  BATCH_REFORM_MAX=0 run
  [ "$(status)" = open ] && ok || bad "E7: a refused close leaves the record open (got $(status))"
  has_ref "$TBR" && ok || bad "E7: and its branch in place"
  { batch_held 101 && batch_held 102; } && ok || bad "E7: and both members still held by it — nothing released ($(ls "$HOLDDIR" 2>/dev/null | tr '\n' ' '))"
  grep -qi 'close was REFUSED\|could not be closed' "$LOG" && ok || bad "E7: the log says the close was refused ($(tail -3 "$LOG"))"
  excluded 101 && bad "E7: nothing is excluded" || ok
else
  bad "E7 fixture could not be armed"
fi

echo "batch-resolve-hold-eject.bh-1934: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
