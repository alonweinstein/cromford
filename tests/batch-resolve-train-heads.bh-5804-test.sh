#!/bin/bash
# tests/batch-resolve-train-heads.bh-5804-test.sh — BH-5804: a merge train
# checks every member's head against its approved head just before it builds,
# drops a member whose head moved (logged, released, back to review), and its
# PR body names the approved sha and the included sha of each member.
#
# THE INCIDENT. Train #5674 carried six members. #5535 moved after approval.
# The re-form dropped it from the union and from the record, but never rewrote
# the PR body, so the body and its Harness-Train trailer still named #5535. The
# lead review read that body and BLOCKed the train. The first build had the
# same gap: nothing re-read a member's head between the candidate loop and
# build_union.
#
# THE MOVE SEAM IS THE gh STUB, not a product hook. The candidate loop reads
# each member's own CI (`commits/<sha>/check-runs`) in PR-age order. When the
# stub answers that read for the LAST candidate (#103) and $T/move-102 exists,
# it pushes one commit to ticket/tk-12 on the bare origin. So #102 passes the
# candidate loop at its approved head and has moved before `attempt` runs.
#
#   H1 a moved member is excluded; the train builds with the others
#   H2 the drop is logged with both shas, and nothing marks it red or held
#   H3 the body lists approved and included sha per member, and the drop
#   H4 no move: no drop, no Dropped section
#   H5 the re-form drops a member that moved after the train formed
#   H6 the re-form rewrites the PR body (one REST PATCH)
#   H7 every member moved: no train, nothing red
#   H8 a refused body PATCH is recorded and retried on the next pass
#
# Run from anywhere: tests/batch-resolve-train-heads.bh-5804-test.sh  (exit 0 = pass)
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

SLUG=example-org/demo-os
PROJ=demo-os

# ── a real repository, and a real remote that never leaves this box ──────────
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
mkdir -p "$S/src" "$S/scripts"
printf 'export const base = 1\n' > "$S/src/base.ts"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
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
git -C "$S" add -A && git -C "$S" commit -qm base >/dev/null && git -C "$S" push -q origin main
BASE=$(git -C "$S" rev-parse HEAD)

# mksib <branch> <file> — a sibling that adds its own file AND rewrites the
# declared registry, so it conflicts with an advanced base only there.
mksib() {
  git -C "$S" checkout -q -b "$1" "$BASE"
  printf 'export const x = 1\n' > "$S/$2"
  printf '%s\n' src/base.ts "$2" | jq -R . | jq -sc '{imports:.}' > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$1" >/dev/null && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mksib ticket/tk-11 src/feature-a.ts)
HEAD_B=$(mksib ticket/tk-12 src/feature-b.ts)
HEAD_C=$(mksib ticket/tk-13 src/feature-c.ts)
git -C "$S" checkout -q main

# move_branch <branch> — one more commit on a member branch, pushed. This is
# the "head moved after approval" event. Prints the new tip.
cat > "$T/move.sh" <<EOF
#!/bin/bash
br="\$1"
git -C "$S" fetch -q origin "\$br" && git -C "$S" checkout -q -B "\$br" FETCH_HEAD
printf 'moved\n' >> "$S/src/moved-\${br##*/}.txt"
git -C "$S" add -A && git -C "$S" commit -qm "move \$br" >/dev/null
git -C "$S" push -q origin "\$br"
git -C "$S" rev-parse HEAD
git -C "$S" checkout -q main
EOF
chmod +x "$T/move.sh"
move_branch() { bash "$T/move.sh" "$1" | head -1; }

# restore_branches — every member branch back at the head its APPROVE names.
restore_branches() {
  git -C "$T/origin.git" update-ref refs/heads/ticket/tk-11 "$HEAD_A"
  git -C "$T/origin.git" update-ref refs/heads/ticket/tk-12 "$HEAD_B"
  git -C "$T/origin.git" update-ref refs/heads/ticket/tk-13 "$HEAD_C"
}

# The base moves on, so every sibling conflicts with it in the registry.
advance_main() {
  git -C "$S" checkout -q main && git -C "$S" reset -q --hard "$BASE"
  printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
  printf '{"imports":["src/base.ts","src/main-advance.ts"]}\n' > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null
  git -C "$S" push -qf origin main
  rm -rf "$T/repos/$PROJ"; git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
}
# advance_more — a sibling landed on main after a train formed: the train is
# now BEHIND the tip, which is what makes the settle pass re-form it.
advance_more() {
  git -C "$S" checkout -q main && git -C "$S" fetch -q origin main && git -C "$S" reset -q --hard origin/main
  printf 'export const more = 1\n' > "$S/src/main-more.ts"
  git -C "$S" add -A && git -C "$S" commit -qm more >/dev/null
  git -C "$S" push -q origin main
}

# ── the harness tree ─────────────────────────────────────────────────────────
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" \
         "$H/tmp" "$H/plans" "$T/fakebin" "$T/repos"
export FLEET_CONF="$H/fleet.conf"
# The bin/batch-resolve.sh copy under test is the real one, with its whole
# source closure (D46), except the ticket-ownership fence, which other suites
# (bh-1630, bh-1934) pin. Without it br_member_fenced admits as before.
mkdir -p "$H/bin/lib"; : > "$H/bin/lib/ticket-ownership.sh"
scratch_install_closure bin/batch-resolve.sh "$H" >/dev/null || { echo "FAIL: the lane's closure could not be installed"; exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$H/bin/"
: > "$H/env/github-app.env"
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
mkdir -p "$H/catalog"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$H/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: catalog/lanes.json could not be composed from catalog/lanes.d"; exit 1; }
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
# ONE GROUP: all three siblings ride one train, so a drop is visible in it.
# PR_SNAPSHOT=0: the open list is read live from the stub (bin/lib/pr-snapshot.sh).
printf 'TRAIN_PARALLEL=1\nPR_SNAPSHOT=0\n' > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\n' "\$1" "\$2" >> "$T/mqueue.tsv"; echo queued; }
merge_train_put() {
  local p="\$1" b="\$2" o="\$3"; shift 3
  printf '%s\t%s\t%s\t%s\n' "\$p" "\$b" "\$o" "\$*" >> "$T/trains.tsv"
  echo "\$o"
}
flag_active() { [ -f "$T/h/flags/\$1" ]; }
EOF

advance_main
export MC_REPOS="$T/repos"

# ── the fake gh ──────────────────────────────────────────────────────────────
#   move-102   the own-CI read of #103's head moves ticket/tk-12 (once)
#   move-all   the own-CI read of #103's head moves all three branches (once)
#   patch-fail the body PATCH answers HTTP 502
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"--json headRefOid"*)
    jq -r --arg n "\$num" '.[]|select(.number==(\$n|tonumber))|.headRefOid' "$T/prs.json"; exit 0 ;;
  *"contents/.mergify.yml"*) exit 1 ;;
  *"-i -X GET repos/$SLUG/commits/"*)
    case "\$*" in
      *"commits/$HEAD_C/"*)
        if [ -f "$T/move-102" ]; then rm -f "$T/move-102"; bash "$T/move.sh" ticket/tk-12 >/dev/null 2>/dev/null; fi
        if [ -f "$T/move-all" ]; then
          rm -f "$T/move-all"
          for b in ticket/tk-11 ticket/tk-12 ticket/tk-13; do bash "$T/move.sh" "\$b" >/dev/null 2>/dev/null; done
        fi ;;
    esac
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"check_runs":[{"name":"Harness CI","status":"completed","conclusion":"success"}]}\n'
    exit 0 ;;
  *"-i -X POST repos/$SLUG/actions/runs/"*"/cancel"*)
    printf 'HTTP/2.0 202 Accepted\nx-stub: 1\n\n{}\n'; exit 0 ;;
  *"-i -X GET repos/$SLUG/actions/runs"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"workflow_runs":[{"id":4242,"name":"Harness CI","status":"completed","conclusion":"success","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}\n'
    exit 0 ;;
  *"-i -X GET repos/$SLUG/pulls -f state=closed"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n[]\n'; exit 0 ;;
  *"api -i -X PATCH repos/$SLUG/pulls/"*)
    printf '%s\n' "\$*" >> "$T/patch-calls.txt"
    for a in "\$@"; do
      case "\$a" in body=@*) cp "\${a#body=@}" "$T/patch-body-\$num.txt" ;; esac
    done
    if [ -f "$T/patch-fail" ]; then
      printf 'HTTP/2.0 502 Bad Gateway\nx-stub: 1\n\n{"message":"fixture refuses"}\n'; exit 1
    fi
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open"}\n'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n'; exit 0 ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n'; exit 0 ;;
  *"-X PATCH repos/$SLUG/pulls/"*)
    printf '%s\n' "\$num" >> "$T/train-closed.txt"; echo '{"state":"closed"}'; exit 0 ;;
  *"pr list -R $SLUG --state open --author"*) cat "$T/prs.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"pr create"*)
    n=\$(( \$(cat "$T/prnum.txt" 2>/dev/null || echo 899) + 1 ))
    printf '%s\n' "\$n" > "$T/prnum.txt"
    prev=""; for a in "\$@"; do
      [ "\$prev" = "--body-file" ] && cp "\$a" "$T/train-body-\$n.txt"
      prev="\$a"
    done
    printf '%s\n' "\$n" >> "$T/train-created.txt"
    echo "https://github.com/$SLUG/pull/\$n"
    exit 0 ;;
  *"pr view https://github.com/$SLUG/pull/"*)
    echo '{"state":"OPEN","mergeCommit":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
    exit 0 ;;
  *"issue view"*) echo OPEN; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
command -v flock >/dev/null 2>&1 || {
  printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

mkpr() { # mkpr <num> <branch> <head> <created>
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg c "$4" --arg slug "$SLUG" '
    {number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", state:"OPEN", createdAt:$c, labels:[]}'
}
mkrec() { # mkrec <ticket-number> <pr-num> <head>
  local d="$H/builds/$PROJ-TK-$1-2026092100$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkplan() { # mkplan <ticket-number> <path...>
  local k="$1"; shift
  mkdir -p "$H/plans/$PROJ-TK-$k"
  printf '%s\n' "$@" > "$H/plans/$PROJ-TK-$k/planned-files.txt"
}
mkrec 11 101 "$HEAD_A"; mkplan 11 src/feature-a.ts
mkrec 12 102 "$HEAD_B"; mkplan 12 src/feature-b.ts
mkrec 13 103 "$HEAD_C"; mkplan 13 src/feature-c.ts
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C" 2026-09-21T03:00:00Z; } | jq -sc '.' > "$T/prs.json"

run() { bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
LOG="$H/logs/batch-resolve.log"
STATE="$H/state/batch-resolve/$PROJ"
HOLDS="$H/state/merge-conductor/batch-hold"
reset() {
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/run.out"; : > "$T/trains.tsv"
  : > "$T/train-closed.txt"; : > "$T/train-created.txt"; : > "$T/patch-calls.txt"; : > "$T/alerts.txt"
  rm -f "$T"/train-body-*.txt "$T"/patch-body-*.txt "$T/move-102" "$T/move-all" "$T/patch-fail" \
        "$H/state/settings-cache.json" "$H/flags/"* 2>/dev/null
  printf '899\n' > "$T/prnum.txt"
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$HOLDS"
  rm -f "$H/state/merge-conductor/attempts.txt"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$T/origin.git" update-ref -d "$r"; done
  restore_branches
  advance_main
}
batch_branches() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/batch/' | sort; }
nbatch() { batch_branches | grep -c . ; }
tip_of() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }
in_union() { git -C "$T/origin.git" merge-base --is-ancestor "$1" "refs/heads/$2" >/dev/null 2>&1; }
rec_members() { jq -r '[.members[].num] | join(" ")' "$1" 2>/dev/null; }
the_rec() { ls "$STATE"/train-*.json 2>/dev/null | head -1; }
held() { [ -s "$HOLDS/$(printf '%s' "$SLUG" | tr -c 'A-Za-z0-9._-' '_')_$1" ] || ls "$HOLDS" 2>/dev/null | grep -q "_$1\$"; }
marked() { # marked <num> -> rc 0 when any exclusion file names the PR
  grep -qs "^$1 " "$STATE/red.txt" "$STATE/abandoned.txt" "$STATE/landed.txt"
}
member_line() { # member_line <num> <branch> <approved> <included>
  printf -- '- #%s (`%s`): approved at `%s`, included at `%s`' "$1" "$2" "${3:0:12}" "${4:0:12}"
}

# ============================================================================
# H1 / H2 / H3. #102 MOVES BETWEEN THE CANDIDATE LOOP AND THE BUILD
# ============================================================================
reset
touch "$T/move-102"
run
NEW_B=$(tip_of ticket/tk-12)
BR=$(batch_branches | head -1)
[ "$NEW_B" != "$HEAD_B" ] && ok || bad "H1 setup: the seam must move ticket/tk-12 (it is still at ${HEAD_B:0:12})"
[ "$(grep -c . "$T/train-created.txt")" = 1 ] && ok \
  || bad "H1 exactly one train PR must open with the two clear members (created: '$(tr '\n' ' ' < "$T/train-created.txt")'; log: $(tail -3 "$LOG" | tr '\n' '|'))"
if [ -n "$BR" ]; then
  { in_union "$HEAD_A" "$BR" && in_union "$HEAD_C" "$BR"; } && ok \
    || bad "H1 the train must carry #101 and #103 at their approved heads"
  in_union "$HEAD_B" "$BR" && bad "H1 the train must NOT carry #102's approved head ${HEAD_B:0:12}: its head moved before the build" || ok
  in_union "$NEW_B" "$BR" && bad "H1 the train must NOT carry #102's new head either: nothing reviewed it" || ok
else
  bad "H1 no train branch was pushed"
fi
REC=$(the_rec)
[ "$(rec_members "$REC")" = "101 103" ] && ok \
  || bad "H1 the train record must list #101 and #103 only (got '$(rec_members "$REC")')"
[ "$(jq -r '[.members[].approved] | join(" ")' "$REC" 2>/dev/null)" = "$HEAD_A $HEAD_C" ] && ok \
  || bad "H1 each member in the record must carry the sha it was approved at"

# H2 — the drop is said, with both shas, and nothing marks #102 red or held.
[ "$(grep '#102' "$LOG" | grep "${HEAD_B:0:12}" | grep "${NEW_B:0:12}" | grep -c 'head moved after approval')" = 1 ] && ok \
  || bad "H2 the log must name #102, its approved head, its new head and 'head moved after approval' on one line: $(grep '#102' "$LOG" | tr '\n' '|')"
marked 102 && bad "H2 a moved member must not be marked red, abandoned or landed: $(grep -hs '^102 ' "$STATE"/*.txt)" || ok
held 102 && bad "H2 a moved member must be released, not held by the train" || ok
grep -q 'review' <<<"$(grep 'head moved after approval' "$LOG")" && ok \
  || bad "H2 the log line must say the member goes back to review"

# H3 — the body.
BODY="$T/train-body-900.txt"
grep -qxF -- "$(member_line 101 ticket/tk-11 "$HEAD_A" "$HEAD_A")" "$BODY" 2>/dev/null && ok \
  || bad "H3 the body must list #101 with its approved and included sha: $(grep '#101' "$BODY" 2>/dev/null)"
grep -qxF -- "$(member_line 103 ticket/tk-13 "$HEAD_C" "$HEAD_C")" "$BODY" 2>/dev/null && ok \
  || bad "H3 the body must list #103 with its approved and included sha: $(grep '#103' "$BODY" 2>/dev/null)"
grep -q 'Dropped from this train' "$BODY" 2>/dev/null && ok || bad "H3 the body must have a 'Dropped from this train' section"
DROPL=$(grep '^- #102 ' "$BODY" 2>/dev/null)
{ grep -q "approved at \`${HEAD_B:0:12}\`" <<<"$DROPL" && grep -q "head now \`${NEW_B:0:12}\`" <<<"$DROPL" \
  && grep -q 'not included' <<<"$DROPL"; } && ok \
  || bad "H3 the Dropped section must list #102 with its approved sha and its head now: '$DROPL'"
TRL=$(grep '^Harness-Train:' "$BODY" 2>/dev/null)
{ grep -q '#101' <<<"$TRL" && grep -q '#103' <<<"$TRL" && ! grep -q '#102' <<<"$TRL"; } && ok \
  || bad "H3 the Harness-Train trailer must name #101 and #103 and not #102: '$TRL'"
grep -q 'reviewed on its own' "$BODY" 2>/dev/null && ok || bad "H3 the body keeps its policy sentence"

# ============================================================================
# H4. NO MOVE, NO DROP
# ============================================================================
reset
run
REC=$(the_rec)
[ "$(rec_members "$REC")" = "101 102 103" ] && ok \
  || bad "H4 a train whose members did not move must carry all three (got '$(rec_members "$REC")'; log: $(tail -3 "$LOG" | tr '\n' '|'))"
grep -q 'Dropped' "$T/train-body-900.txt" 2>/dev/null && bad "H4 no member was dropped, so the body has no Dropped section" || ok
grep -q 'head moved after approval' "$LOG" && bad "H4 nothing moved, so no drop may be logged" || ok
grep -qxF -- "$(member_line 102 ticket/tk-12 "$HEAD_B" "$HEAD_B")" "$T/train-body-900.txt" 2>/dev/null && ok \
  || bad "H4 the body must list #102 with its approved and included sha"

# ============================================================================
# H5 / H6. THE RE-FORM DROPS A MOVED MEMBER AND REWRITES THE BODY
#     H4 left a train of three. #102 moves, and a sibling lands on main, so the
#     train is BEHIND and the settle pass re-forms it.
# ============================================================================
TBR=$(batch_branches | head -1)
U_BEFORE=$(tip_of "$TBR" 2>/dev/null)
NEW_B=$(move_branch ticket/tk-12)
advance_more
: > "$LOG"; : > "$T/patch-calls.txt"; : > "$T/train-created.txt"
run
[ "$(tip_of "$TBR" 2>/dev/null)" != "$U_BEFORE" ] && ok \
  || bad "H5 setup: the behind train must be re-formed on the same branch (log: $(tail -3 "$LOG" | tr '\n' '|'))"
[ "$(rec_members "$REC")" = "101 103" ] && ok \
  || bad "H5 the re-formed record must list #101 and #103 only (got '$(rec_members "$REC")')"
[ "$(grep '#102' "$LOG" | grep "${HEAD_B:0:12}" | grep "${NEW_B:0:12}" | grep -c 'head moved after approval')" = 1 ] && ok \
  || bad "H5 the re-form must log #102's drop with both shas: $(grep '#102' "$LOG" | tr '\n' '|')"
in_union "$HEAD_B" "$TBR" && bad "H5 the re-formed union must not carry #102" || ok
[ -s "$T/train-created.txt" ] && bad "H5 a re-form opens no new PR" || ok

[ "$(grep -c "api -i -X PATCH repos/$SLUG/pulls/900 " "$T/patch-calls.txt")" = 1 ] && ok \
  || bad "H6 the re-form must PATCH the train PR body exactly once (calls: $(tr '\n' '|' < "$T/patch-calls.txt"))"
grep -q 'body=@' "$T/patch-calls.txt" && ok || bad "H6 the body must go by file, never argv"
PB="$T/patch-body-900.txt"
U_AFTER=$(tip_of "$TBR" 2>/dev/null)
{ grep -qxF -- "$(member_line 101 ticket/tk-11 "$HEAD_A" "$HEAD_A")" "$PB" \
  && grep -qxF -- "$(member_line 103 ticket/tk-13 "$HEAD_C" "$HEAD_C")" "$PB"; } 2>/dev/null && ok \
  || bad "H6 the rewritten body must list #101 and #103 with approved and included sha: $(grep '^- #' "$PB" 2>/dev/null | tr '\n' '|')"
{ grep -q 'Dropped from this train' "$PB" && grep -q "^- #102 .*head now \`${NEW_B:0:12}\`" "$PB"; } 2>/dev/null && ok \
  || bad "H6 the rewritten body must list #102 under Dropped with its head now"
TRL=$(grep '^Harness-Train:' "$PB" 2>/dev/null)
{ [ -n "$TRL" ] && ! grep -q '#102' <<<"$TRL"; } && ok || bad "H6 the rewritten Harness-Train must not name #102: '$TRL'"
[ "$(jq -r '.body_stale // false' "$REC")" = false ] && ok || bad "H6 a written body leaves body_stale unset or false"

# ============================================================================
# H7. EVERY MEMBER MOVED: NO TRAIN, NOTHING RED
# ============================================================================
reset
touch "$T/move-all"
run
[ -s "$T/train-created.txt" ] && bad "H7 no train PR may open when every member moved: $(cat "$T/train-created.txt")" || ok
[ "$(nbatch)" = 0 ] && ok || bad "H7 no batch branch may be pushed (got $(batch_branches | tr '\n' ' '))"
[ "$(grep -c 'head moved after approval' "$LOG")" = 3 ] && ok \
  || bad "H7 each of the three moved members must be logged (got $(grep -c 'head moved after approval' "$LOG"))"
{ marked 101 || marked 102 || marked 103; } && bad "H7 no moved member may be marked red: $(cat "$STATE"/red.txt 2>/dev/null)" || ok
{ held 101 || held 102 || held 103; } && bad "H7 every moved member must be released" || ok

# ============================================================================
# H8. A REFUSED BODY PATCH IS RECORDED AND RETRIED
# ============================================================================
reset
run
REC=$(the_rec)
NEW_B=$(move_branch ticket/tk-12)
advance_more
: > "$LOG"; : > "$T/patch-calls.txt"
touch "$T/patch-fail"
run
[ "$(rec_members "$REC")" = "101 103" ] && ok || bad "H8 setup: the re-form must still drop #102 (got '$(rec_members "$REC")')"
[ "$(jq -r '.body_stale // false' "$REC")" = true ] && ok \
  || bad "H8 a refused body PATCH must set body_stale=true in the record (got $(jq -r '.body_stale // "absent"' "$REC"))"
[ "$(grep -c 'body could not be written' "$LOG")" = 1 ] && ok \
  || bad "H8 the refused PATCH must be one log line: $(grep -i 'body' "$LOG" | tr '\n' '|')"
rm -f "$T/patch-fail"; : > "$T/patch-calls.txt"; : > "$LOG"
run
[ "$(grep -c "api -i -X PATCH repos/$SLUG/pulls/900 " "$T/patch-calls.txt")" = 1 ] && ok \
  || bad "H8 the next pass must retry the body PATCH once (calls: $(tr '\n' '|' < "$T/patch-calls.txt"))"
[ "$(jq -r '.body_stale // false' "$REC")" = false ] && ok \
  || bad "H8 a retried PATCH that succeeds must clear body_stale (got $(jq -r '.body_stale' "$REC"))"
grep -q '^- #102 .*not included' "$T/patch-body-900.txt" 2>/dev/null && ok \
  || bad "H8 the retried body must still list #102 as dropped"

echo "$PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
