#!/bin/bash
# tests/blocked-resolver-conflict-class.bh-1470-test.sh — BH-1470: the CONFLICT
# rung of bin/lib/br/opt/mechanical.sh and the classifier it turns on.
#
# WHAT IT PINS. `br_conflict_kind` gates an irreversible, client-visible action:
# a force push to a PR's own branch. So section 1 drives it over real trees —
# clean, a conflict in a file the repo DECLARES machine-written, a conflict in
# ordinary source, and a git that cannot answer — plus the adversarial negatives
# that must never read as `derived`. Sections 2-5 drive the REAL
# bin/blocked-resolver.sh against a scratch $HARNESS (D2) and a REAL bare origin,
# and assert on artifacts: the origin's own ref, its reflog depth, the record
# json, the tick line. `gh`, the jobs client and bin/agent-call.sh are stubbed.
#
# D1 MUTATION, run once before the PR and confirmed red: make the `source` arm
# of br_conflict_kind fall through to `derived` — five of section 1's fixtures
# and all five of section 3's cluster assertions go red.
#
# Run from anywhere: tests/blocked-resolver-conflict-class.bh-1470-test.sh (0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

SLUG=o/p1
PROJ=p1

# ── a real repository, and a real remote that never leaves this box ──────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global advice.skippedCherryPicks false
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

git init -q --bare "$T/origin.git"
git -C "$T/origin.git" config core.logAllRefUpdates true
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
S="$T/seed"
mkdir -p "$S/src" "$S/scripts" "$S/catalog/lanes.d" "$S/bin" "$S/deep"

# THE ROOT COMMIT DECLARES NOTHING. A repo with no `## Generated files` table is
# negative 6: an empty allow-list must never mean "allow all".
printf 'export const base = 1\n' > "$S/src/base.ts"
printf 'export const shared = "base"\n' > "$S/src/shared.ts"
printf '{"n":"orig"}\n' > "$S/scripts/regen-out.json"
printf '{"lanes":["orig"]}\n' > "$S/catalog/lanes.json"
printf '{"lanes":["orig"]}\n' > "$S/catalog/lanes.json.bak"
printf '{"id":"orig"}\n'      > "$S/catalog/lanes.d/one.json"
printf '#!/bin/sh\necho orig\n' > "$S/bin/lane.sh"
printf 'note-orig\n' > "$S/deep/union-notes.txt"
git -C "$S" add -A && git -C "$S" commit -qm root >/dev/null
git -C "$T/origin.git" fetch -q "$S" main:main
ROOT=$(git -C "$S" rev-parse HEAD)

# ...and the second commit declares the table and the union attribute. `#` in a
# gitattributes pattern with NO SLASH matches at any depth, which is git's own
# reading and negative 8.
cat > "$S/scripts/regen.sh" <<REGEN
#!/bin/sh
if [ -f "$T/regen-oscillate" ]; then
  echo tick >> "$T/osc-count.txt"
  printf '{"n":%s}\n' "\$(grep -c . "$T/osc-count.txt")" > scripts/regen-out.json
  exit 0
fi
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/regen-out.json
REGEN
chmod +x "$S/scripts/regen.sh"
printf 'union-notes.txt merge=union\n' > "$S/.gitattributes"
cat > "$S/AGENT_ARCHITECTURE.md" <<'ARCH'
# Architecture

## Generated files

| File | Regenerate with |
|---|---|
| `scripts/regen-out.json` | `bash scripts/regen.sh` |
| `catalog/lanes.json` | `bash scripts/regen.sh` |
ARCH
git -C "$S" add -A && git -C "$S" commit -qm declare >/dev/null
git -C "$T/origin.git" fetch -q "$S" main:main
BASE=$(git -C "$S" rev-parse HEAD)

# ── the branches ────────────────────────────────────────────────────────────
# #31 the DERIVED park that rebases: its regenerate commit is one main also
#     made (the commonest shape there is — two PRs regenerate the same index),
#     so the merge conflicts on that file and the pure rebase drops the commit.
git -C "$S" checkout -q -b ticket/TK-31 "$BASE"
printf '{"n":"X"}\n' > "$S/scripts/regen-out.json"
git -C "$S" commit -qam 'TK-31 regen' >/dev/null
printf 'export const f31 = 1\n' > "$S/src/f31.ts"
git -C "$S" add -A && git -C "$S" commit -qm 'TK-31 feature' >/dev/null
git -C "$S" push -q origin ticket/TK-31

# #32 the same conflict, but EVERY one of its commits is already upstream, so
#     the rebase carries a different patch than the one that was approved.
git -C "$S" checkout -q -b ticket/TK-32 "$BASE"
printf '{"n":"X"}\n' > "$S/scripts/regen-out.json"
git -C "$S" commit -qam 'TK-32 regen' >/dev/null
printf 'export const dup = 1\n' > "$S/src/dup.ts"
git -C "$S" add -A && git -C "$S" commit -qm 'TK-32 dup' >/dev/null
git -C "$S" push -q origin ticket/TK-32

# #33 and #34 both conflict on the SAME source file: the cluster.
for N in 33 34; do
  git -C "$S" checkout -q -b "ticket/ts-$N" "$BASE"
  printf 'export const shared = "b%s"\n' "$N" > "$S/src/shared.ts"
  git -C "$S" commit -qam "ts-$N shared" >/dev/null
  git -C "$S" push -q origin "ticket/ts-$N"
done

# #35 a derived-only conflict for the observe run.
git -C "$S" checkout -q -b ticket/TK-35 "$BASE"
printf '{"n":"X"}\n' > "$S/scripts/regen-out.json"
git -C "$S" commit -qam 'TK-35 regen' >/dev/null
printf 'export const f35 = 1\n' > "$S/src/f35.ts"
git -C "$S" add -A && git -C "$S" commit -qm 'TK-35 feature' >/dev/null
git -C "$S" push -q origin ticket/TK-35

# The classifier-only fixtures. Each is a branch off BASE (or off ROOT, for the
# ref that declares no table at all).
git -C "$S" checkout -q -b fx/clean "$BASE"
printf 'export const clean = 1\n' > "$S/src/clean.ts"
git -C "$S" add -A && git -C "$S" commit -qm clean >/dev/null
git -C "$S" checkout -q -b fx/source "$BASE"
printf '#!/bin/sh\necho branch\n' > "$S/bin/lane.sh"
git -C "$S" commit -qam source >/dev/null
git -C "$S" checkout -q -b fx/lanesd "$BASE"
printf '{"id":"branch"}\n' > "$S/catalog/lanes.d/one.json"
git -C "$S" commit -qam lanesd >/dev/null
git -C "$S" checkout -q -b fx/bak "$BASE"
printf '{"lanes":["branch"]}\n' > "$S/catalog/lanes.json.bak"
git -C "$S" commit -qam bak >/dev/null
git -C "$S" checkout -q -b fx/mixed "$BASE"
printf '{"n":"X"}\n' > "$S/scripts/regen-out.json"
printf '#!/bin/sh\necho branch\n' > "$S/bin/lane.sh"
git -C "$S" commit -qam mixed >/dev/null
git -C "$S" checkout -q -b fx/union "$BASE"
printf 'note-orig\nnote-branch\n' > "$S/deep/union-notes.txt"
git -C "$S" commit -qam union >/dev/null
git -C "$S" checkout -q -b fx/notable-a "$ROOT"
printf '{"n":"A"}\n' > "$S/scripts/regen-out.json"
git -C "$S" commit -qam notable-a >/dev/null
git -C "$S" checkout -q -b fx/notable-b "$ROOT"
printf '{"n":"B"}\n' > "$S/scripts/regen-out.json"
git -C "$S" commit -qam notable-b >/dev/null
git -C "$S" push -q origin fx/clean fx/source fx/lanesd fx/bak fx/mixed fx/union \
                           fx/notable-a fx/notable-b

# ── main moves on, after every branch was cut ───────────────────────────────
git -C "$S" checkout -q main
printf '{"n":"X"}\n' > "$S/scripts/regen-out.json"
git -C "$S" commit -qam 'main regen X (the same patch #31 and #32 made)' >/dev/null
printf 'export const dup = 1\n' > "$S/src/dup.ts"
git -C "$S" add -A && git -C "$S" commit -qm 'main dup (the same patch #32 made)' >/dev/null
printf '{"n":"Y"}\n' > "$S/scripts/regen-out.json"
printf 'export const shared = "main"\n' > "$S/src/shared.ts"
printf '#!/bin/sh\necho main\n' > "$S/bin/lane.sh"
printf '{"id":"main"}\n' > "$S/catalog/lanes.d/one.json"
printf '{"lanes":["main"]}\n' > "$S/catalog/lanes.json.bak"
git -C "$S" rm -q deep/union-notes.txt >/dev/null
git -C "$S" add -A && git -C "$S" commit -qm advance >/dev/null
git -C "$T/origin.git" fetch -q "$S" main:main

mkdir -p "$T/repos"
git clone -q "$T/origin.git" "$T/repos/$PROJ" 2>/dev/null
REPO="$T/repos/$PROJ"
git -C "$REPO" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'

HEADOF() { git -C "$REPO" rev-parse "origin/ticket/ts-$1"; }
ORIGREF() { git -C "$T/origin.git" rev-parse "refs/heads/ticket/ts-$1" 2>/dev/null; }
REFLOGN() { git -C "$T/origin.git" reflog show "refs/heads/ticket/ts-$1" 2>/dev/null | grep -c .; }

# ── the harness tree ─────────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/tmp" "$H/state/merge-conductor" "$T/fakebin" "$T/nogit"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
mkdir -p "$H/bin/lib/br/opt"
cp "$DIR/bin/lib/br/opt/mechanical.sh" "$H/bin/lib/br/opt/" 2>/dev/null
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf '%s %s - - 2 box-%s 192.0.2.1\n' "$PROJ" "$SLUG" "$PROJ" > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning, such as it was\nREJECT\n' > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"-i -X "*)
    GHT="$T"
    cat "$T/pr-\$N.branch" 2>/dev/null > "$T/prbranch"
    cat "$T/pr-\$N.head"   2>/dev/null > "$T/prhead"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) printf '%s ticket/ts-%s\n' "\$(cat "$T/pr-\$N.head" 2>/dev/null)" "\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
echo OPEN > "$T/prstate"
for N in 31 32 33 34 35; do
  printf 'ticket/ts-%s' "$N" > "$T/pr-$N.branch"
  HEADOF "$N" | tr -d '\n' > "$T/pr-$N.head"
done

JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
job_verdict_rebind() { printf 'verdict-rebind %s %s\n' "\$1" "\$2" >> "$T/jobs.txt"; return 0; }
EOF
}
JOBS_OK

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
BRENV=()
RC=0
RUN() { RC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" MC_REPOS="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || RC=$?; }
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$SLUG#$1" BLOCKED_HUMAN "$((NOW - 600))" "$2" "$2" \
             "conflict-unresolvable: CONFLICT (content): Merge conflict in scripts/regen-out.json" \
             "https://github.com/$SLUG/pull/$1" >> "$ROWS"; }
STATEJSON() { cat "$ST/$PROJ/$PROJ-TK-$1.json" 2>/dev/null; }
ACTIONS() { STATEJSON "$1" | jq -r '.attempts[]?.action' 2>/dev/null | tr '\n' ' '; }
FIELD() { STATEJSON "$1" | jq -r ".$2 // \"\"" 2>/dev/null; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
ORDER() { grep -oE '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild)' \
            "$H/logs/blocked-resolver.log" 2>/dev/null | sed 's/-> //' | tr '\n' ' '; }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null; }
NLINES() { grep -c "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }

CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/tmp" 2>/dev/null; mkdir -p "$H/tmp"
          : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"; : > "$T/jobs.txt"
          : > "$T/alerts.txt"; : > "$T/agent.txt"
          rm -f "$T/regen-oscillate" "$T/osc-count.txt" "$H/flags/blocked-resolver-observe"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          echo OPEN > "$T/prstate"; JOBS_OK
          : > "$ROWS"; }

# KIND <base-ref> <head-ref> [path-override] — br_conflict_kind, as the lane
# loads it: the conductor lib, bin/lib/mc/train.sh and the module, nothing else.
KIND() {
  ( export HARNESS="$H"; H="$H"; MC_REPOS="$T/repos"; REPOS="$T/repos"
    # shellcheck disable=SC1090
    . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    . "$H/bin/lib/br/opt/mechanical.sh" >/dev/null 2>&1
    [ -n "${3:-}" ] && PATH="$3"
    br_conflict_kind "$REPO" "$1" "$2" )
}

# ============================================================================
# 1. THE CLASSIFIER, over real trees. Every answer is asserted by its exact
#    first word, and every negative is a realistic input that must NOT read as
#    `derived` — this is the gate in front of a force push.
# ============================================================================
[ "$(KIND origin/main origin/fx/clean)" = clean ] && ok \
  || bad "1: two trees that merge are clean (got: $(KIND origin/main origin/fx/clean))"
[ "$(KIND origin/main origin/ticket/TK-31)" = "derived scripts/regen-out.json" ] && ok \
  || bad "1: a conflict only in a DECLARED generated file is derived (got: $(KIND origin/main origin/ticket/TK-31))"
[ "$(KIND origin/main origin/fx/source)" = "source bin/lane.sh" ] && ok \
  || bad "1: a conflict in ordinary source is source (got: $(KIND origin/main origin/fx/source))"
[ "$(KIND origin/main origin/fx/clean "$T/nogit")" = unknown ] && ok \
  || bad "1: no git is unknown, never clean (got: $(KIND origin/main origin/fx/clean "$T/nogit"))"
# (c) the adversarial negatives.
[ "$(KIND origin/main origin/fx/lanesd)" = "source catalog/lanes.d/one.json" ] && ok \
  || bad "1(2): a source json beside a generated one is source (got: $(KIND origin/main origin/fx/lanesd))"
[ "$(KIND origin/main origin/fx/mixed)" = "source bin/lane.sh" ] && ok \
  || bad "1(3): a MIXED conflict names the source path (got: $(KIND origin/main origin/fx/mixed))"
[ "$(KIND origin/main 0123456789abcdef0123456789abcdef01234567)" = unknown ] && ok \
  || bad "1(4): a sha the clone does not have is unknown (got: $(KIND origin/main 0123456789abcdef0123456789abcdef01234567))"
[ "$(KIND origin/fx/notable-a origin/fx/notable-b)" = "source scripts/regen-out.json" ] && ok \
  || bad "1(6): a base ref that declares NO table allows nothing (got: $(KIND origin/fx/notable-a origin/fx/notable-b))"
[ "$(KIND origin/main origin/fx/bak)" = "source catalog/lanes.json.bak" ] && ok \
  || bad "1(7): a path that only LOOKS like a declared one is source (got: $(KIND origin/main origin/fx/bak))"
[ "$(KIND origin/main origin/fx/union)" = "derived deep/union-notes.txt" ] && ok \
  || bad "1(8): a merge=union pattern with no slash matches at any depth (got: $(KIND origin/main origin/fx/union))"

# ============================================================================
# 2. A DERIVED-ONLY CONFLICT IS REBASED, ONCE. The push happens inside
#    mrt_rebase_pure; nothing is enqueued and no model is called.
# ============================================================================
CLEAN
WAS=$(ORIGREF 31); WASN=$(REFLOGN 31)
ROWADD 31 "$(HEADOF 31)"
RUN
[ "$RC" = 0 ] && ok || bad "2: the tick must exit 0 (rc $RC)"
[ "$(ORIGREF 31)" != "$WAS" ] && ok || bad "2: the branch must be pushed (origin ref unchanged)"
[ "$(REFLOGN 31)" = "$((WASN + 1))" ] && ok \
  || bad "2: pushed EXACTLY once (reflog $WASN -> $(REFLOGN 31))"
case " $(ACTIONS 31) " in *" mechanical-regen "*) ok ;; *) bad "2: a mechanical-regen attempt is recorded (record: $(STATEJSON 31))" ;; esac
[ "$(LFIELD mechanical)" = 1 ] && ok || bad "2: mechanical=1 (tick: $(LASTTICK))"
[ "$(LFIELD llm_rungs)" = 0 ] && ok || bad "2: and no llm rung (tick: $(LASTTICK))"
[ "$(NAGENT)" = 0 ] && ok || bad "2: no model is called (agent: $(cat "$T/agent.txt"))"
[ ! -s "$T/queue.txt" ] && ok || bad "2: nothing is enqueued (queue: $(cat "$T/queue.txt"))"
grep -q 'pr merge' "$T/gh.txt" && bad "2: nothing here merges a PR (gh: $(cat "$T/gh.txt"))" || ok

# 2b. THE REBASED PATCH IS NOT THE SAME PATCH (mrt_rebase_pure rc 2): every one
#     of this branch's commits is already upstream, so the head that came out
#     carries less than the one a reviewer read. Nothing is pushed.
CLEAN
WAS=$(ORIGREF 32); WASN=$(REFLOGN 32)
ROWADD 32 "$(HEADOF 32)"
RUN
[ "$(ORIGREF 32)" = "$WAS" ] && ok || bad "2b: nothing may be pushed on rc 2 (origin ref moved)"
[ "$(REFLOGN 32)" = "$WASN" ] && ok || bad "2b: and the reflog must not move ($WASN -> $(REFLOGN 32))"
case " $(ACTIONS 32) " in *" mechanical-regen "*) bad "2b: nothing is recorded (record: $(STATEJSON 32))" ;; *) ok ;; esac
[ "$(LFIELD mechanical)" = 0 ] && ok || bad "2b: mechanical=0 (tick: $(LASTTICK))"
case "$(ORDER)" in *mechanical*|*fix-round*|*rebuild*) ok ;; *) bad "2b: today's ladder runs (order: $(ORDER))" ;; esac

# 2c. THE GENERATORS DO NOT SETTLE (rc 3). A render with no fixed point is a
#     real conflict wearing a clean rebase's clothes. Nothing is pushed.
CLEAN
touch "$T/regen-oscillate"
WAS=$(ORIGREF 35); WASN=$(REFLOGN 35)
ROWADD 35 "$(HEADOF 35)"
RUN
rm -f "$T/regen-oscillate"
[ "$(ORIGREF 35)" = "$WAS" ] && ok || bad "2c: nothing may be pushed on rc 3 (origin ref moved)"
[ "$(REFLOGN 35)" = "$WASN" ] && ok || bad "2c: and the reflog must not move ($WASN -> $(REFLOGN 35))"
[ "$(LOG | grep 'do not settle' | grep -c 'scripts/regen-out.json')" = 1 ] && ok \
  || bad "2c: the unsettled path is named in the log (log: $(LOG | tail -5))"
[ "$(LFIELD mechanical)" = 0 ] && ok || bad "2c: mechanical=0 (tick: $(LASTTICK))"
case "$(ORDER)" in *mechanical*|*fix-round*|*rebuild*) ok ;; *) bad "2c: today's ladder runs (order: $(ORDER))" ;; esac

# ============================================================================
# 3. TWO PARKS ON THE SAME SOURCE FILE ARE ONE CLUSTER. The key is the declared
#    input the cross-ticket round needs; this slice writes it and nothing else —
#    both parks still take their ordinary ladder rung.
# ============================================================================
CLEAN
W33=$(ORIGREF 33); W34=$(ORIGREF 34)  # neither may move
ROWADD 33 "$(HEADOF 33)"
ROWADD 34 "$(HEADOF 34)"
RUN
[ "$(FIELD 33 conflict_cluster)" = "src/shared.ts" ] && ok \
  || bad "3: the cluster is the sorted conflicting paths (got: $(FIELD 33 conflict_cluster))"
[ "$(FIELD 34 conflict_cluster)" = "src/shared.ts" ] && ok \
  || bad "3: on both parks (got: $(FIELD 34 conflict_cluster))"
K33=$(FIELD 33 conflict_cluster_key); K34=$(FIELD 34 conflict_cluster_key)
[ -n "$K33" ] && [ "$K33" = "$K34" ] && ok || bad "3: and both carry the SAME key ($K33 vs $K34)"
[ "${#K33}" = 12 ] && ok || bad "3: the key is 12 hex (got: '$K33')"
[ "$(ORIGREF 33)" = "$W33" ] && [ "$(ORIGREF 34)" = "$W34" ] && ok \
  || bad "3: a clustered park pushes nothing"
[ "$(LFIELD mechanical)" = 0 ] && ok || bad "3: nothing was resolved, so nothing is counted (tick: $(LASTTICK))"
[ "$(LFIELD families)" = 0 ] && ok || bad "3: this slice touches no family counter (tick: $(LASTTICK))"
case "$(ORDER)" in *mechanical*|*fix-round*|*rebuild*) ok ;; *) bad "3: both take their ordinary rung (order: $(ORDER))" ;; esac
[ "$(NLINES 'EVENT conflict-clustered')" = 2 ] && ok \
  || bad "3: one clustered event per park (log: $(LOG | grep -c 'EVENT conflict-clustered'))"

# ============================================================================
# 4. THE KILL SWITCH. BR_OPT_OFF=mechanical is today's path.
# ============================================================================
CLEAN
WAS=$(ORIGREF 33); WASN=$(REFLOGN 33)
ROWADD 33 "$(HEADOF 33)"
BRENV=(BR_OPT_OFF=mechanical)
RUN
BRENV=()
[ "$(ORIGREF 33)" = "$WAS" ] && ok || bad "4: a switched-off module pushes nothing"
[ "$(REFLOGN 33)" = "$WASN" ] && ok || bad "4: ($WASN -> $(REFLOGN 33))"
[ "$(LFIELD mechanical)" = 0 ] && ok || bad "4: mechanical=0 (tick: $(LASTTICK))"
[ "$(FIELD 33 conflict_cluster)" = "" ] && ok || bad "4: and writes no cluster (got: $(FIELD 33 conflict_cluster))"

# ============================================================================
# 5. OBSERVE MODE predicts the rebase and pushes nothing.
# ============================================================================
CLEAN
touch "$H/flags/blocked-resolver-observe"
printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
  "$SLUG#35" BLOCKED_HUMAN "$((NOW - 600))" "$(ORIGREF 35)" "$(ORIGREF 35)" \
  "conflict-unresolvable: CONFLICT (content): Merge conflict in scripts/regen-out.json" \
  "https://github.com/$SLUG/pull/35" >> "$ROWS"
printf '%s' "$(ORIGREF 35)" > "$T/pr-35.head"
W35=$(ORIGREF 35); W35N=$(REFLOGN 35)
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(NLINES 'WOULD regen-rebase')" = 1 ] && ok || bad "5: exactly one WOULD regen-rebase line (log: $(LOG | tail -5))"
[ "$(ORIGREF 35)" = "$W35" ] && ok || bad "5: observe pushes nothing (origin ref moved)"
[ "$(REFLOGN 35)" = "$W35N" ] && ok || bad "5: ($W35N -> $(REFLOGN 35))"
[ -z "$(ACTIONS 35)" ] && ok || bad "5: and writes no record (record: $(STATEJSON 35))"
[ "$(LFIELD mechanical)" = 0 ] && ok || bad "5: and counts nothing (tick: $(LASTTICK))"

echo "blocked-resolver conflict class (BH-1470): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
