#!/bin/bash
# tests/resolver-hotfix-order-test.sh — bin/blocked-resolver.sh picks the HOTFIX
# park first, and the per-tick cap can never cut it off.
#
# WHY THIS IS THE TEST THAT MATTERS (#643 fix 1, BH-646). The resolver takes
# BR_PER_TICK parks per */10 tick in DISCOVERY order — whatever order the
# conductor rows, the queue and the build records happened to come back in. A
# ticket carrying the `hotfix` label is the one park in the fleet that cannot
# wait ten more minutes, and with four parks ahead of it in a file it waited as
# long as the queue felt like. So `br_candidates` now carries a rank column from
# the build record's own ticket-meta.json (no API call) and sorts on it.
#
# Two ways that goes wrong and both are silent: the rank is read from something
# that is not the label (a title that says "hotfix", a `hotfix-candidate` label
# somebody used to ASK whether this is urgent) and ordinary work jumps the
# queue; or the sort drops the rest of the rows and a plain park becomes
# invisible. Both are asserted here against the tick's OWN LOG — never against
# the script's source — with the kill flag driven as its own case, because
# `flags/hotfix-lane-off` has to put this lane back to byte-for-byte what it was.
# Run from anywhere: tests/resolver-hotfix-order-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/scheduler-conf.sh" "$H/bin/lib/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/" 2>/dev/null || true
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), owned by a remote box.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# lane-alert is RECORDED, never stubbed silent: a lane that went quiet instead of
# paging is the failure this fixture family exists to catch.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  # bin/blocked-resolver.sh decides over REST now (#783). The fields are named
  # off the NUMBER in the path so the shared envelope stub finds them.
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)            printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json state"*)        echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-9" ;;
  *"--json headRefName"*)  echo "ticket/TK-9" ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN.
export GH_TOKEN=""
# OBSERVE mode: the tick classifies and logs every rung it WOULD take and writes
# nothing else. The `->` line — the thing under test — is written before the
# dispatch either way, so the order is observable without a rung running.
: > "$H/flags/blocked-resolver-observe"

# ---------------------------------------------------------------------------
# Fixtures. One conductor row + one build record per PR; the record's
# ticket-meta.json is what priority_rank_meta reads, exactly as run-build.sh
# leaves it on a real box.
# ---------------------------------------------------------------------------
ROWS="$H/state/merge-conductor/pr-state.tsv"
addrow() { # addrow <pr-number>
  printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' \
    "o/tproj#$1" "$NOW" "merge-failed-twice: gh pr merge refused" \
    "https://github.com/o/tproj/pull/$1" >> "$ROWS"
}
addrec() { # addrec <pr-number> <meta: none|empty|badjson|<json>>
  local n="$1" kind="$2" d="$H/builds/tproj-TK-$1-20260917000001"
  mkdir -p "$d"
  printf 'PR_CREATED https://github.com/o/tproj/pull/%s\n' "$n" > "$d/RESULT"
  case "$kind" in
    none)    rm -f "$d/ticket-meta.json" ;;
    empty)   : > "$d/ticket-meta.json" ;;
    badjson) printf 'this is not json {{{\n' > "$d/ticket-meta.json" ;;
    *)       printf '%s\n' "$kind" > "$d/ticket-meta.json" ;;
  esac
}
reset() { # reset — a clean tick: no rows, no records, no log
  : > "$ROWS"; : > "$H/logs/blocked-resolver.log"
  scratch_rm "$H/builds"; mkdir -p "$H/builds"
  scratch_rm "$H/state/blocked-resolver"
}
BRENV=()
TICK() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_PER_TICK=1 \
            env ${BRENV[*]:+"${BRENV[@]}"} bash "$H/bin/blocked-resolver.sh" \
            >>"$T/run.log" 2>&1 ) || true; }
# The one observable: the dispatch line the lane writes for every park it picked
# up this tick ("tproj/o-tproj-42 [conductor/merge-failed-twice] -> rebuild-fresh").
arrows() { grep -F ' -> ' "$H/logs/blocked-resolver.log" 2>/dev/null; }
picked() { arrows | sed -nE 's#^[^ ]+ [^ ]+ tproj/(o-tproj-[0-9]+) .*#\1#p'; }

HOTFIX_META='{"labels":[{"name":"hotfix"}]}'
CAND_META='{"labels":[{"name":"hotfix-candidate"}]}'

# ============================================================================
# A. THE HOTFIX PARK IS PICKED FIRST, and BR_PER_TICK=1 cannot cut it off.
#    Discovery order is 40, 41, 42; only 42 carries the label.
# ============================================================================
reset
for n in 40 41 42; do addrow "$n"; done
addrec 40 '{"labels":[]}'; addrec 41 "$CAND_META"; addrec 42 "$HOTFIX_META"
TICK
[ "$(arrows | wc -l)" = 1 ] && ok || bad "A: BR_PER_TICK=1 must dispatch exactly one park, got: $(arrows)"
[ "$(picked)" = o-tproj-42 ] && ok || bad "A: the hotfix park (PR 42) must be picked first, got '$(picked)'"
grep -qE 'o-tproj-(40|41)' <<<"$(arrows)" && bad "A: no plain park may be dispatched ahead of the hotfix: $(arrows)" || ok

# A2. The rest of the rows are still THERE, behind it — a sort key, never a
#     separate queue. Same fixture, the whole tick this time.
reset
for n in 40 41 42; do addrow "$n"; done
addrec 40 '{"labels":[]}'; addrec 41 "$CAND_META"; addrec 42 "$HOTFIX_META"
BRENV=(BR_PER_TICK=9); TICK; BRENV=()
[ "$(arrows | wc -l)" = 3 ] && ok || bad "A2: every park must still be offered, got: $(arrows)"
[ "$(picked | tr '\n' ' ')" = "o-tproj-42 o-tproj-40 o-tproj-41 " ] && ok \
  || bad "A2: hotfix first, then discovery order behind it, got '$(picked | tr '\n' ' ')'"

# A3. THE MUTATION, ASSERTED RATHER THAN NARRATED. With the rank forced to a
#     constant (HOTFIX_LANE=0 makes every rank 2) the same fixture picks the
#     first-discovered row — which is exactly what deleting the sort produces.
reset
for n in 40 41 42; do addrow "$n"; done
addrec 40 '{"labels":[]}'; addrec 41 "$CAND_META"; addrec 42 "$HOTFIX_META"
BRENV=(HOTFIX_LANE=0); TICK; BRENV=()
[ "$(picked)" = o-tproj-40 ] && ok || bad "A3: with the lane off the first-discovered park runs, got '$(picked)'"

# ============================================================================
# B. THE KILL FLAG. flags/hotfix-lane-off puts this lane back to what it was:
#    no reordering, the first-discovered park runs, and a genuine `hotfix`
#    label is just a label.
# ============================================================================
reset
: > "$H/flags/hotfix-lane-off"
for n in 40 41 42; do addrow "$n"; done
addrec 40 '{"labels":[]}'; addrec 41 "$CAND_META"; addrec 42 "$HOTFIX_META"
TICK
[ "$(picked)" = o-tproj-40 ] && ok || bad "B: with flags/hotfix-lane-off the first-discovered park runs, got '$(picked)'"
rm -f "$H/flags/hotfix-lane-off"

# ============================================================================
# C. THE NEGATIVES. Everything that is NOT the label must rank plain, because
#    rank 0 reorders the whole tick. Each case is discovered SECOND and must
#    not overtake the plain row in front of it.
# ============================================================================
for spec in "none" "empty" "badjson" \
            '{"labels":[],"title":"hotfix: the checkout is down","body":"hotfix please"}' \
            "$CAND_META" '{"labels":[{"name":"not-hotfix"}]}' '{"labels":[{"name":"hotfixes"}]}'; do
  reset
  addrow 40; addrow 41
  addrec 40 '{"labels":[]}'; addrec 41 "$spec"
  TICK
  [ "$(picked)" = o-tproj-40 ] && ok || bad "C: '$spec' must not rank as a hotfix, got '$(picked)'"
done

# C2. A park with NO build record at all (the queue-sourced shape: rec '-')
#     ranks plain and asks GitHub nothing.
reset
addrow 40; addrow 41
addrec 40 '{"labels":[]}'   # 41 has no record: mc_record_for answers nothing
TICK
[ "$(picked)" = o-tproj-40 ] && ok || bad "C2: a recordless park must rank plain, got '$(picked)'"
grep -q 'issue view' "$T/gh.txt" && bad "C2: ranking must cost no GitHub issue read: $(grep 'issue view' "$T/gh.txt")" || ok

# C3. A genuine hotfix still wins when it is discovered LAST behind negatives —
#     the case that proves C is about the label and not about position.
reset
for n in 40 41 42; do addrow "$n"; done
addrec 40 "$CAND_META"; addrec 41 none; addrec 42 "$HOTFIX_META"
TICK
[ "$(picked)" = o-tproj-42 ] && ok || bad "C3: the labelled park must still win from last place, got '$(picked)'"

echo "resolver-hotfix-order: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
