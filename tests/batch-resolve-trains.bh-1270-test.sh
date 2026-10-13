#!/bin/bash
# tests/batch-resolve-trains.bh-1270-test.sh — BH-1270: N merge trains in flight
# at once, on DISJOINT planned-file sets, bounded by TRAIN_PARALLEL.
#
# Eight behaviours, each driven against a REAL bare origin and the SHIPPED lane
# — no paraphrase of its logic anywhere in this file:
#
#   T1  two candidates whose planned-file sets do not intersect form TWO trains
#       in ONE tick, and their D1 rows carry the group they rode in
#   T2  two candidates whose planned-file sets DO intersect ride the SAME train
#       — they never share a tick across two groups
#   T3  two candidates in the same MODULE directory ride the same train, even
#       though the files they name are different
#   T4  when the first group's train lands under the second one's, the second is
#       RE-FORMED on the new tip: same PR, same members at the same heads, a new
#       union sha — and nothing is re-reviewed
#   T5  a RED union in one group does not hold the other: the green group still
#       pushes its train in the same pass
#   T6  TRAIN_PARALLEL=1 reproduces BH-1269 — one train, every candidate in it,
#       in the order the pass found them — at the lane AND at the planner
#   T7  the CI pool bounds the parallelism: a declared pool that fits one run
#       caps the lane at one train however high TRAIN_PARALLEL is, and a
#       candidate whose files meet a train ALREADY in flight is not batched
#   T8  a candidate nobody can judge conflicts with EVERYTHING — it collapses
#       the partition to one train and may not ride beside a live one
#
# WHY REAL GIT. Every claim here is about what a union cut from a moving base
# actually does — whether the second group's branch still merges after the first
# one lands, and whether rebuilding it on the new tip produces a tree that
# verifies. A stubbed git would only prove the shell around it is spelled right,
# which was never the part in doubt. `gh` IS stubbed, always: nothing here may
# touch GitHub.
#
# Run from anywhere: tests/batch-resolve-trains.bh-1270-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
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
mkdir -p "$S/src" "$S/scripts" "$S/bin/lib/mc"

printf 'export const base = 1\n' > "$S/src/base.ts"
printf '#!/bin/sh\nexit 0\n' > "$S/bin/lib/mc/keep.sh"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"

# The stub regenerate command: it rewrites the declared registry deterministically
# from the tree, so every member of every train conflicts with the base in it.
# That conflict is the whole reason a train exists — and it is exactly why the
# partition must NOT count declared generated files as an overlap.
cat > "$S/scripts/regen.sh" <<'REGEN'
#!/bin/sh
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/worker-import-set.json
REGEN
chmod +x "$S/scripts/regen.sh"

# The verification contract. Green unless $T/red-when-present.txt names a path
# the union tree carries — which is how T5 makes ONE group's union red and
# leaves the other one alone.
cat > "$S/ci-stub.sh" <<CI
#!/bin/sh
p=\$(cat "$T/red-when-present.txt" 2>/dev/null)
[ -n "\$p" ] && [ -e "\$p" ] && exit 1
exit 0
CI
chmod +x "$S/ci-stub.sh"

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

# mksib <branch> <new-file> — a sibling that adds ONE file of its own AND
# rewrites the declared registry, so it conflicts with an advanced base in a
# file the repo marks generated (allowed) and nowhere else.
mksib() {
  git -C "$S" checkout -q -b "$1" "$BASE"
  mkdir -p "$(dirname "$S/$2")"
  printf 'export const x = 1\n' > "$S/$2"
  printf '{"imports":["src/base.ts","%s"]}\n' "$2" > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$1" >/dev/null && git -C "$S" push -q origin "$1"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mksib ticket/tk-11 src/feature-a.ts)
HEAD_B=$(mksib ticket/tk-12 src/feature-b.ts)
HEAD_C=$(mksib ticket/tk-13 src/feature-c.ts)
# ...and tk-13 ALSO carries src/feature-a.ts, the file tk-11 carries. T2 and T7
# below are about two candidates that claim the SAME file, and until BH-1306
# that claim was made by tk-13's pre-plan alone while its patch touched only
# feature-c. mrt_planned_files now reads the DIFF first — the plan is a
# prediction, the diff is the patch the review was of — so a fixture whose
# overlap exists only in the prediction stopped expressing what those two cases
# assert. The overlap is in the patch now, and the plan below still names it.
git -C "$S" checkout -q ticket/tk-13
printf 'export const x = 1\n' > "$S/src/feature-a.ts"
printf '{"imports":["src/base.ts","src/feature-a.ts","src/feature-c.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm tk-13-claims-feature-a >/dev/null
git -C "$S" push -q origin ticket/tk-13
HEAD_C=$(git -C "$S" rev-parse HEAD)
HEAD_D=$(mksib ticket/tk-14 bin/lib/mc/x.sh)
HEAD_E=$(mksib ticket/tk-15 bin/lib/mc/y.sh)
# A sibling that touches ONLY the declared generated file. It has no pre-plan,
# no build-record list, and a diff that is empty once the generated file is
# subtracted — so nothing on this box can say what it would touch. It is the
# UNJUDGED shape, and it must never be treated as disjoint from anything.
git -C "$S" checkout -q -b ticket/tk-16 "$BASE"
printf '{"imports":["src/base.ts","src/nothing.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm tk-16 >/dev/null && git -C "$S" push -q origin ticket/tk-16
HEAD_F=$(git -C "$S" rev-parse HEAD)

# The base moves on, so every sibling conflicts with it in the registry.
git -C "$S" checkout -q main
printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
printf '{"imports":["src/base.ts","src/main-advance.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null && git -C "$S" push -q origin main

# ── the harness tree ─────────────────────────────────────────────────────────
export HARNESS="$T/h"
H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/builds" "$H/env" \
         "$H/tmp" "$H/plans" "$T/fakebin" "$T/repos"
export FLEET_CONF="$H/fleet.conf"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/main-red-gate.sh" \
   "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/batch-resolve.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
# BH-1606: a train opens only as the App (never the lead PAT), so this box can mint one.
cp "$DIR/bin/lib/gh-app-auth.sh" "$H/bin/lib/"; : > "$H/env/github-app.env"
# TEST-CHANGE (BH-1630): the lane now reads the token's expiry (`gh-token.sh
# --expires-at`) before it pushes a union, so the stub answers one, far ahead.
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
# THE REGISTRY IS RENDERED, NEVER COPIED (BH-1247/#1275). catalog/lanes.json is
# git-ignored — it is composed from catalog/lanes.d/ on demand — so a fixture
# that COPIES it reads an artifact that exists on a developer's box and not in
# CI, and the lane then finds no registry, lane_env_apply returns early, and T9
# fails for a reason that has nothing to do with what it tests. Composing it
# from the committed sources with the shipped builder is both correct in CI and
# closer to what a box does: bin/lib/lanes-registry.sh renders exactly this way.
mkdir -p "$H/catalog"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$H/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: batch-resolve-trains.bh-1270-test: catalog/lanes.json could not be composed from catalog/lanes.d — T9 reads the registry and every case below would run against a lane with no knobs"; exit 1; }
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$H/fleet.conf"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"

cat > "$H/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$T/ledger.tsv"; }
merge_queue_put() { printf '%s\t%s\n' "\$1" "\$2" >> "$T/mqueue.tsv"; echo queued; }
merge_train_put() {
  local p="\$1" b="\$2" o="\$3"; shift 3
  printf '%s\t%s\t%s\t%s\n' "\$p" "\$b" "\$o" "\$*" >> "$T/trains.tsv"
  echo "\$o"
}
flag_active() { [ -f "$T/h/flags/\$1" ]; }
flag_set() {
  case "\$2" in off|0|false) rm -f "$T/h/flags/\$1" ;; *) touch "$T/h/flags/\$1" ;; esac
}
EOF

git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
export MC_REPOS="$T/repos"

# ── the fake gh ──────────────────────────────────────────────────────────────
# `pr create` hands out a DIFFERENT number every time: with two trains in one
# tick, a stub that answers 900 to both would make the two records collide and
# hide the very thing this suite is about.
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
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"check_runs":[{"name":"Harness CI","status":"completed","conclusion":"success"}]}\n'
    exit 0 ;;
  *"-i -X POST repos/$SLUG/actions/runs/"*"/cancel"*)
    printf '%s\n' "\$*" | grep -oE 'runs/[0-9]+' | sed 's#runs/##' >> "$T/cancelled.txt"
    printf 'HTTP/2.0 202 Accepted\nx-stub: 1\n\n{}\n'; exit 0 ;;
  *"-i -X GET repos/$SLUG/actions/runs"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$(cat "$T/runs.json" 2>/dev/null || echo '{"workflow_runs":[{"id":4242,"name":"Harness CI","status":"completed","conclusion":"success","created_at":"2026-09-21T10:00:00Z","run_started_at":"2026-09-21T10:00:00Z"}]}')"
    exit 0 ;;
  *"-i -X GET repos/$SLUG/pulls -f state=closed"*)
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n%s\n' "\$(cat "$T/closedprs.json" 2>/dev/null || echo '[]')"
    exit 0 ;;
  *"api -i -X PATCH repos/$SLUG/pulls/"*)
    printf 'closed\n' > "$T/pr-state-\$num.txt"
    printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    case "\$(cat "$T/pr-state-\$num.txt" 2>/dev/null)" in
      closed) printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed","merged_at":null}\n' ;;
      *)      printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"open","merged_at":null}\n' ;;
    esac
    exit 0 ;;
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
    cat "$T/train-state-\$num.json" 2>/dev/null && exit 0
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
# mkplan <ticket-number> <path...> — the pre-plan list bin/overlap-guard.sh and
# bin/overlap-schedule.sh already read, in the home they read it from.
mkplan() {
  local k="$1"; shift
  mkdir -p "$H/plans/$PROJ-TK-$k"
  printf '%s\n' "$@" > "$H/plans/$PROJ-TK-$k/planned-files.txt"
}
mkrec 11 101 "$HEAD_A"; mkplan 11 src/feature-a.ts
mkrec 12 102 "$HEAD_B"; mkplan 12 src/feature-b.ts
mkrec 13 103 "$HEAD_C"; mkplan 13 src/feature-a.ts    # OVERLAPS TK-11 on purpose
mkrec 14 104 "$HEAD_D"; mkplan 14 bin/lib/mc/x.sh
mkrec 15 105 "$HEAD_E"; mkplan 15 bin/lib/mc/y.sh     # same MODULE as TK-14
mkrec 16 106 "$HEAD_F"                                # deliberately NO plan

run() { bash "$H/bin/batch-resolve.sh" "$PROJ" >>"$T/run.out" 2>&1; }
LOG="$H/logs/batch-resolve.log"
STATE="$H/state/batch-resolve/$PROJ"
reset() {
  [ -n "${BATCH_TEST_KEEP:-}" ] && { echo "=== scenario boundary ==="; cat "$LOG"; } >> "$T/log-history.txt" 2>/dev/null
  : > "$T/gh-calls.txt"; : > "$LOG"; : > "$T/run.out"; : > "$T/trains.tsv"
  : > "$T/train-closed.txt"; : > "$T/ledger.tsv"; : > "$T/cancelled.txt"; : > "$T/train-created.txt"
  rm -f "$T"/train-body-*.txt "$T"/train-state-*.json "$T"/pr-state-*.txt \
        "$T/red-when-present.txt" "$T/runs.json" "$T/closedprs.json" \
        "$H/state/settings-cache.json" "$H/flags/"* 2>/dev/null
  printf '899\n' > "$T/prnum.txt"
  scratch_rm "$H/state/batch-resolve"; scratch_rm "$H/state/merge-conductor/batch-hold"
  rm -f "$H/state/merge-conductor/attempts.txt"
  git -C "$T/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$T/origin.git" update-ref -d "$r"; done
}
batch_branches() { git -C "$T/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/batch/' | sort; }
nbatch() { batch_branches | grep -c . ; }
remote_head() { git -C "$T/origin.git" rev-parse "refs/heads/$1"; }
bodies() { cat "$T"/train-body-*.txt 2>/dev/null; }
# the train record for a given batch branch
recof() { echo "$STATE/train-${1##*/}.json"; }
# every member number named by the body of the train whose PR is $1
bodymem() { grep -oE '#1[0-9]+' "$T/train-body-$1.txt" 2>/dev/null | sort -u | tr -d '#' | tr '\n' ' '; }

# ============================================================================
# T1. TWO DISJOINT SETS FORM TWO TRAINS IN ONE TICK
#     #101 claims src/feature-a.ts and #102 claims src/feature-b.ts. They both
#     conflict with main in the declared registry — which is what makes them
#     train material at all — and that conflict must NOT count as an overlap,
#     or every candidate would meet every other one and the partition would
#     collapse to the one train BH-1269 already built.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 2 ] && ok || bad "T1 two disjoint candidates must form TWO trains in one tick (branches: $(nbatch); $(grep -i 'partitioned' "$LOG" | head -1))"
M900=$(bodymem 900); M901=$(bodymem 901)
[ "$M900" = "101 " ] && ok || bad "T1 the first train must carry #101 alone (got '$M900')"
[ "$M901" = "102 " ] && ok || bad "T1 the second train must carry #102 alone (got '$M901')"
grep -qi 'partitioned 2 approved siblings into 2 train' "$LOG" && ok \
  || bad "T1 the partition must be said out loud: $(grep -i partition "$LOG" | head -1)"

# ...and the D1 rows show BOTH groups (T7's half of the ticket).
G0=$(awk -F'\t' '$3=="open"' "$T/trains.tsv" | grep -c 'train_group=0')
G1=$(awk -F'\t' '$3=="open"' "$T/trains.tsv" | grep -c 'train_group=1')
{ [ "$G0" -ge 1 ] && [ "$G1" -ge 1 ]; } && ok \
  || bad "T1 the merge_trains rows must carry both group ids (g0=$G0 g1=$G1): $(cat "$T/trains.tsv")"
# and the file record agrees with the row
R0=$(recof "$(batch_branches | head -1)"); R1=$(recof "$(batch_branches | tail -1)")
[ "$(jq -r '.train_group' "$R0")" = 0 ] && [ "$(jq -r '.train_group' "$R1")" = 1 ] && ok \
  || bad "T1 each train record must remember its group ($(jq -r '.train_group' "$R0")/$(jq -r '.train_group' "$R1"))"

# ============================================================================
# T2. OVERLAPPING CANDIDATES NEVER SHARE A TICK ACROSS GROUPS
#     #101 and #103 both claim src/feature-a.ts. Two unions cut from the same
#     base that both touch it WOULD meet, so they must ride one train.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C" 2026-09-21T03:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok || bad "T2 two candidates claiming the same file must ride ONE train (branches: $(nbatch))"
[ "$(bodymem 900)" = "101 103 " ] && ok \
  || bad "T2 and that one train must carry both of them (got '$(bodymem 900)')"

# ============================================================================
# T3. SAME-MODULE CANDIDATES NEVER RUN IN PARALLEL
#     #104 names bin/lib/mc/x.sh and #105 names bin/lib/mc/y.sh — different
#     files, one module. A textual non-conflict is not a semantic one, and the
#     module's own suite is the thing that would catch it.
# ============================================================================
reset
{ mkpr 104 ticket/tk-14 "$HEAD_D" 2026-09-21T04:00:00Z
  mkpr 105 ticket/tk-15 "$HEAD_E" 2026-09-21T05:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok || bad "T3 two PRs in one module directory must ride ONE train (branches: $(nbatch))"
[ "$(bodymem 900)" = "104 105 " ] && ok || bad "T3 and both must be in it (got '$(bodymem 900)')"

# the contrast: one of them beside a candidate in no module at all DOES split
reset
{ mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z
  mkpr 104 ticket/tk-14 "$HEAD_D" 2026-09-21T04:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 2 ] && ok \
  || bad "T3 a module PR and a src PR that share no file must still form two trains (branches: $(nbatch))"

# ============================================================================
# T4. THE SECOND GROUP RE-FORMS — IT IS NOT RE-REVIEWED
#     Two trains go out. The first one MERGES, so main moves under the second,
#     whose union no longer merges. Its members have not moved, so nothing any
#     verdict is bound to has moved: the union is rebuilt on the new tip and
#     force-pushed to the SAME branch, same PR, no re-review.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 2 ] && ok || bad "T4 setup: two trains must go out (got $(nbatch))"
BR0=$(batch_branches | head -1); BR1=$(batch_branches | tail -1)
REC1=$(recof "$BR1")
U1_BEFORE=$(jq -r '.union_sha' "$REC1")
SHA11_BEFORE=$(cat "$H/builds/$PROJ-TK-12-2026092100"*/reviewed-sha)

# the first train really lands: its branch is merged into main on the origin
git -C "$S" fetch -q origin "+refs/heads/*:refs/remotes/origin/*"
git -C "$S" checkout -q main && git -C "$S" reset -q --hard origin/main
git -C "$S" merge -q --no-edit "origin/$BR0" >/dev/null 2>&1
git -C "$S" push -q origin main
MERGESHA=$(git -C "$S" rev-parse HEAD)
printf '{"state":"MERGED","mergeCommit":{"oid":"%s"},"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}\n' \
  "$MERGESHA" > "$T/train-state-900.json"
# ...and GitHub now calls the second train's PR conflicting
printf '{"state":"OPEN","mergeCommit":null,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}\n' \
  > "$T/train-state-901.json"
: > "$LOG"; : > "$T/train-created.txt"; : > "$T/gh-calls.txt"
U1_REMOTE_BEFORE=$(remote_head "$BR1")
run
U1_AFTER=$(jq -r '.union_sha' "$REC1")
[ "$(remote_head "$BR1")" != "$U1_REMOTE_BEFORE" ] && ok \
  || bad "T4 the second train's branch must be rebuilt on the new tip"
[ "$U1_AFTER" != "$U1_BEFORE" ] && ok || bad "T4 its record must carry the NEW union sha"
[ "$(jq -r '.reform_n' "$REC1")" = 1 ] && ok \
  || bad "T4 the re-form must be counted (reform_n=$(jq -r '.reform_n' "$REC1"))"
[ "$(jq -r '.train_url' "$REC1")" = "https://github.com/$SLUG/pull/901" ] && ok \
  || bad "T4 the SAME PR must carry the new union — a re-form is not a new train"
[ -s "$T/train-created.txt" ] && bad "T4 no second train PR may be opened for a re-form: $(cat "$T/train-created.txt")" || ok
grep -qi 'RE-FORMED' "$LOG" && ok || bad "T4 the re-form must be said out loud"
[ "$(cat "$H/builds/$PROJ-TK-12-2026092100"*/reviewed-sha)" = "$SHA11_BEFORE" ] && ok \
  || bad "T4 NOTHING may be re-reviewed or re-bound: the member's head has not moved"
# the member is still held by the same train and is not a candidate for another
grep -qi 'already held by the train' "$LOG" && ok \
  || bad "T4 a member of a live train must not be offered to a second one: $(grep -i held "$LOG" | head -1)"
# and the first train settled its own member
grep -qi 'LANDED' "$LOG" && ok || bad "T4 the landed train must settle in the same pass"

# past the budget it is NOT re-formed again
: > "$LOG"
jq -c '.reform_n = 9' "$REC1" > "$REC1.tmp" && mv -f "$REC1.tmp" "$REC1"
U2_BEFORE=$(remote_head "$BR1")
run
[ "$(remote_head "$BR1")" = "$U2_BEFORE" ] && ok || bad "T4 BATCH_REFORM_MAX must bound the re-forms"
grep -qi 'already been re-formed' "$LOG" && ok \
  || bad "T4 and the refusal must name the budget: $(grep -i reform "$LOG" | head -1)"

# put the base back for the scenarios below
git -C "$S" checkout -q main && git -C "$S" reset -q --hard "$BASE"
printf 'export const advanced = 1\n' > "$S/src/main-advance.ts"
printf '{"imports":["src/base.ts","src/main-advance.ts"]}\n' > "$S/scripts/worker-import-set.json"
git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null
git -C "$S" push -qf origin main
rm -rf "$T/repos/$PROJ"; git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null

# ============================================================================
# T5. A RED UNION IN ONE GROUP DOES NOT HOLD THE OTHER
#     The groups share nothing, so a red one says nothing about the other. If
#     one red stood the whole pass down, parallel trains would be strictly
#     worse than serial ones.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
printf 'src/feature-a.ts\n' > "$T/red-when-present.txt"
run
[ "$(nbatch)" = 1 ] && ok || bad "T5 the green group must still push while the other is red (branches: $(nbatch))"
[ "$(bodymem 900)" = "102 " ] && ok || bad "T5 and it must be the green one (got '$(bodymem 900)')"
grep -qxF "101 $HEAD_A" "$STATE/red.txt" 2>/dev/null && ok \
  || bad "T5 the red group's member goes back to the one-at-a-time path at its head"
# AND NO SPLIT IS PAID. Before the partition these two rode one train, that
# train went red, and a binary split bought a second CI run per half to
# rediscover which member it was. Knowing they were disjoint in the first place
# is what makes that run unnecessary.
grep -qi 'binary split of the red union' "$LOG" \
  && bad "T5 disjoint candidates must never buy a binary split to find out they were disjoint" || ok
rm -f "$T/red-when-present.txt"

# ============================================================================
# T6. TRAIN_PARALLEL=1 IS BH-1269, BYTE FOR BYTE
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
TRAIN_PARALLEL=1 run
[ "$(nbatch)" = 1 ] && ok || bad "T6 TRAIN_PARALLEL=1 must build exactly one train (branches: $(nbatch))"
[ "$(bodymem 900)" = "101 102 " ] && ok \
  || bad "T6 with every candidate in it, in the order the pass found them (got '$(bodymem 900)')"

# ...and at the planner, where the property actually lives: one group, the
# caller's order, whatever the sets say.
mkdir -p "$T/planner"
( set -u
  . "$H/bin/lib/mc/train.sh"
  d="$T/planner"
  printf 'src/a.ts\n' > "$d/1.files"; printf 'src/b.ts\n' > "$d/2.files"; printf 'src/c.ts\n' > "$d/3.files"
  for k in 1 2 3; do mrt_modules_of "$d/$k.files" "$d/$k.mods"; done
  got=$(mrt_group_plan 1 8 "$d" 1 2 3 | tr '\t' ':' | tr '\n' ' ')
  [ "$got" = "0:1 0:2 0:3 " ] || { echo "planner: $got"; exit 1; }
) && ok || bad "T6 mrt_group_plan with one group must return the candidates unchanged, in order"
scratch_rm "$T/planner"

# ============================================================================
# T7. THE CI POOL BOUNDS IT, AND A LIVE TRAIN'S FILES ARE OFF LIMITS
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
BATCH_CI_RUNNERS=8 BATCH_CI_SHARDS=8 TRAIN_PARALLEL=4 run
[ "$(nbatch)" = 1 ] && ok \
  || bad "T7 a pool that fits ONE run must cap the lane at one train (branches: $(nbatch))"
grep -qi 'cap 1' "$LOG" && ok || bad "T7 and the cap must be in the line: $(grep -i partition "$LOG" | head -1)"

# a candidate whose files meet a train ALREADY in flight is not batched; a
# disjoint one still is.
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z; } | jq -sc '.' > "$T/prs.json"
TRAIN_PARALLEL=1 run
[ "$(nbatch)" = 1 ] && ok || bad "T7 setup: one train must go out (got $(nbatch))"
: > "$LOG"
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C" 2026-09-21T03:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok \
  || bad "T7 #103 claims the file the live train holds — no second train may be built beside it (got $(nbatch))"
grep -qi 'meet a train that is already in flight' "$LOG" && ok \
  || bad "T7 and the refusal must say why: $(tail -3 "$LOG")"
: > "$LOG"
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-21T02:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 2 ] && ok \
  || bad "T7 a candidate that shares nothing with the live train DOES ride beside it (got $(nbatch))"

# ============================================================================
# T8. AN UNJUDGED CANDIDATE CONFLICTS WITH EVERYTHING
#     #106 has no pre-plan, no build-record list, and a diff that is empty once
#     the repo's declared generated files are subtracted. Nothing here can say
#     what it would touch — and a candidate nobody can judge must never be
#     silently treated as disjoint, because being wrong about that is two
#     unions meeting on main.
# ============================================================================
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 106 ticket/tk-16 "$HEAD_F" 2026-09-21T06:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok \
  || bad "T8 an unjudged candidate must collapse the partition to one train (branches: $(nbatch))"
[ "$(bodymem 900)" = "101 106 " ] && ok \
  || bad "T8 and everything rides with it (got '$(bodymem 900)')"
grep -qi 'UNJUDGED' "$LOG" && ok || bad "T8 the lane must say which candidate it could not judge"

# ...and it may not ride beside a train that is ALREADY in flight either
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z; } | jq -sc '.' > "$T/prs.json"
TRAIN_PARALLEL=1 run
[ "$(nbatch)" = 1 ] && ok || bad "T8 setup: one train must go out (got $(nbatch))"
: > "$LOG"
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z
  mkpr 106 ticket/tk-16 "$HEAD_F" 2026-09-21T06:00:00Z; } | jq -sc '.' > "$T/prs.json"
run
[ "$(nbatch)" = 1 ] && ok \
  || bad "T8 an unjudged candidate cannot be shown disjoint from a live train, so no second train (got $(nbatch))"
grep -qi 'cannot be shown to be disjoint' "$LOG" && ok \
  || bad "T8 and the refusal must say so: $(tail -3 "$LOG")"

# ============================================================================
# T9 (#1287). A `lane.batch-resolve.*` SETTINGS ROW REACHES THE TRAIN MODULE
#     bin/lib/mc/train.sh fixes MC_TRAIN_CI_REQUIRED / _WORKFLOW / _IGNORE at
#     SOURCE time from ${BATCH_CI_*:-default}. Sourced ABOVE lane_env_apply —
#     where it was — those three read the box's environment and could never see
#     a D1 row: the registry called them settable, the console wrote the row,
#     the row was exported one line too late, and the lane went on logging the
#     default back at the operator who had just changed it. Nothing errored,
#     because the env-file path worked throughout.
#
#     The row this drives is BATCH_CI_RUN_REQUIRED, whose two arms are visible
#     from outside: a merged fix whose head has ZERO runs of the named workflow
#     lifts the main-red freeze at 0 and lifts nothing at 1.
# ============================================================================
setrow() { # setrow <key> <value>  — one settings row, fresh enough to be used
  mkdir -p "$H/state"
  jq -nc --arg k "$1" --arg v "$2" --argjson t "$(date -u +%s)" \
    '{fetched_at:$t, values:{($k):$v}}' > "$H/state/settings-cache.json"
}
armfix() { # a merged fix-main-red PR at the base tip, and NO workflow run for it
  touch "$H/flags/main-red-example-org-demo-os"
  printf '{"workflow_runs":[]}\n' > "$T/runs.json"
  jq -nc --arg h "$(remote_head main)" \
    --arg m "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" \
    '[{number:200, merged_at:$m, labels:[{name:"fix-main-red"}], head:{sha:$h}}]' > "$T/closedprs.json"
}
reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z; } | jq -sc '.' > "$T/prs.json"
armfix
run
[ -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T9 at the default a head with no run of the named workflow must lift NOTHING"

reset
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-21T01:00:00Z; } | jq -sc '.' > "$T/prs.json"
armfix
setrow lane.batch-resolve.batch_ci_run_required 0
run
[ ! -f "$H/flags/main-red-example-org-demo-os" ] && ok \
  || bad "T9 a settings ROW at 0 must reach the module and lift the freeze — the row is exported by lane_env_apply, so the module has to be sourced BELOW it (#1287): $(grep -i 'STANDS' "$LOG" | head -1)"

echo "$PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
