#!/bin/bash
# tests/prequeue-invariant-overrides.bh-5440-test.sh — BH-5440 (#5429 child 2):
# a `conf.prequeue-invariants.<id>[.<box>]` settings row turns one pre-queue
# invariant off or changes its budget, and the hub carries the row to the
# workflow as `-f invariants=<list>`. Plus `--jobs N` on --run.
#
#   C2   an `off` row drops the id from --list; --overrides prints it
#   C3   a whole number rebudgets; `tests/x.sh 5`, `rm -rf`, `0`, `-1` are
#        refused through conf_row_refused and the catalog answers
#   C3b  a row for an id not in the catalog adds nothing and changes no argv
#   C4   no settings cache: --overrides prints nothing, rc 0; no --harness: the
#        catalog as committed
#   C9   every row off is rc 2 on --run and --list, never green
#   J1   --jobs 2 runs two rows at once; --jobs 1 does not; output in catalog
#        order either way; --jobs 0 is rc 2
#   D6   a malformed workflow input `invariants` is could-not-run
#        why=bad-invariants; a good one drops that row and runs the rest
#   K6   the real conductor dispatch carries `-f invariants=lanes-registry=off`;
#        no script in MC_H keeps the argv byte-identical; garbage never reaches it
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-invariant-overrides.bh-5440-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

SCRIPT="$DIR/bin/prequeue-invariants.sh"
CATALOG="$DIR/catalog/prequeue-invariants.tsv"
WF="$DIR/.github/workflows/prequeue-gate.yml"
HOOK="$DIR/bin/lib/mc-prequeue.d/invariants.sh"
NL=$'\n'
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
has() { [[ "$1" == *"$2"* ]]; }
crows() { grep -v '^#' "$CATALOG" | grep -v '^$'; }
[ -f "$HOOK" ] && ok || bad "setup: bin/lib/mc-prequeue.d/invariants.sh is missing"

# The scratch harness: the REAL runner and conf-row.sh, the real catalog, a
# settings cache written straight to disk and no bin/jobs-client.sh, so the
# cache is read as it stands (conf-row.sh's fixture-tree rule).
H="$T/h"; mkdir -p "$H/catalog" "$H/state" "$H/logs"
scratch_install_closure bin/prequeue-invariants.sh "$H" >/dev/null || bad "setup: install bin/prequeue-invariants.sh"
scratch_install_closure bin/lib/conf-row.sh "$H" >/dev/null || bad "setup: install bin/lib/conf-row.sh"
cp "$CATALOG" "$H/catalog/"
# cache_in k=v... — $H/state/settings-cache.json holding exactly those rows.
cache_in() {
  local out='{}' kv
  for kv in "$@"; do out=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"$out"); done
  jq -c '{fetched_at: 1758300000, values: ., seeded: {}}' <<<"$out" > "$H/state/settings-cache.json"
}
reset() { scratch_rm "$H/state/lane-gate"; rm -f "$H/state/settings-cache.json" "$H/logs/lane-gate.log"; }
# pq <case> [args...] — the real runner in $H; $T/<case>.{out,err,rc}
pq() {
  local c="$1"; shift
  ( cd "$T" && env JOBS_BOX=hub-1 bash "$H/bin/prequeue-invariants.sh" "$@" ) > "$T/$c.out" 2> "$T/$c.err"
  echo $? > "$T/$c.rc"
}
rc() { cat "$T/$1.rc" 2>/dev/null; }
out() { cat "$T/$1.out" 2>/dev/null; }
col() { cut -f"$2" "$T/$1.out" 2>/dev/null; }
budget_of() { awk -F'\t' -v i="$2" '$1 == i { print $4 }' "$T/$1.out"; }
CAT4=$(crows | cut -f1-4)
# TEST-CHANGE (BH-5684): the row counts below come from the catalog instead of
# the literals 11 and 10. The catalog grows by one row per new invariant
# (BH-5684 added pr-scoped-tests, the 12th), and every count check still pins
# "all rows" (NCAT) or "all but the off row" (NCAT - 1) exactly.
NCAT=$(crows | grep -c .)

# ============================================================================
# C4. No cache, and no --harness.
# ============================================================================
reset
pq c4o --overrides --harness "$H"
[ "$(rc c4o)" = 0 ] && [ -z "$(out c4o)" ] && ok || bad "C4: no cache, --overrides prints nothing rc 0 (rc $(rc c4o), out '$(out c4o)', err $(cat "$T/c4o.err"))"
pq c4l --list
[ "$(rc c4l)" = 0 ] && [ "$(out c4l)" = "$CAT4" ] && ok || bad "C4: --list with no --harness is the $NCAT catalog rows (rc $(rc c4l); err $(cat "$T/c4l.err"))"
pq c4c --list --catalog "$CATALOG"
[ "$(rc c4c)" = 0 ] && [ "$(out c4c)" = "$CAT4" ] && ok || bad "C4: --list --catalog F reads F (rc $(rc c4c))"
cache_in conf.prequeue-invariants.lanes-registry=off
pq c4n --list
[ "$(out c4n)" = "$CAT4" ] && ok || bad "C4: a row with no --harness changes nothing"
# Print mode with no catalog in the tree: nothing, rc 0.
mv "$H/catalog/prequeue-invariants.tsv" "$T/cat.bak"
pq c4x --overrides --harness "$H"
[ "$(rc c4x)" = 0 ] && [ -z "$(out c4x)" ] && ok || bad "C4: no catalog, --overrides prints nothing rc 0 (rc $(rc c4x), out '$(out c4x)')"
pq c4y --list
[ "$(rc c4y)" = 2 ] && ok || bad "C4: no catalog, --list is rc 2 (rc $(rc c4y))"
mv "$T/cat.bak" "$H/catalog/prequeue-invariants.tsv"

# ============================================================================
# C2. An off row.
# ============================================================================
reset; cache_in conf.prequeue-invariants.lanes-registry=off
pq c2l --list --harness "$H"
[ "$(rc c2l)" = 0 ] && [ "$(out c2l | wc -l)" = "$((NCAT - 1))" ] && ! grep -q '^lanes-registry	' "$T/c2l.out" && ok \
  || bad "C2: --list has $((NCAT - 1)) rows and no lanes-registry (rc $(rc c2l); $(col c2l 1 | tr '\n' ' '); err $(cat "$T/c2l.err"))"
[ "$(out c2l)" = "$(grep -v '^lanes-registry	' <<<"$CAT4")" ] && ok || bad "C2: the other $((NCAT - 1)) rows are the catalog's, in order"
pq c2o --overrides --harness "$H"
[ "$(rc c2o)" = 0 ] && [ "$(out c2o)" = lanes-registry=off ] && ok || bad "C2: --overrides prints lanes-registry=off (rc $(rc c2o), out '$(out c2o)', err $(cat "$T/c2o.err"))"
# C2b. This box's row answers; another box's row is a key with one segment too many.
reset; cache_in conf.prequeue-invariants.lanes-registry.hub-1=off conf.prequeue-invariants.determinism.otherbox=off
pq c2b --overrides --harness "$H"
[ "$(out c2b)" = lanes-registry=off ] && ok || bad "C2b: box row answers, another box's row does not (got '$(out c2b)')"
pq c2c --list --harness "$H"
[ "$(out c2c | wc -l)" = "$((NCAT - 1))" ] && grep -q '^determinism	' "$T/c2c.out" && ok || bad "C2b: --list keeps determinism, drops lanes-registry"
[ ! -s "$H/logs/lane-gate.log" ] || ! grep -q 'determinism.otherbox' "$H/logs/lane-gate.log" && ok || bad "C2b: another box's row logs nothing"
# LANE_GATE_DISABLE=1 is conf-row's escape hatch: no rows.
reset; cache_in conf.prequeue-invariants.lanes-registry=off
( cd "$T" && env JOBS_BOX=hub-1 LANE_GATE_DISABLE=1 bash "$H/bin/prequeue-invariants.sh" --overrides --harness "$H" ) > "$T/c2d.out" 2>/dev/null
[ -z "$(out c2d)" ] && ok || bad "C2: LANE_GATE_DISABLE=1 reads no row (got '$(out c2d)')"

# ============================================================================
# C3. A rebudget, and refused values.
# ============================================================================
reset; cache_in conf.prequeue-invariants.share-mirror-clean=90 'conf.prequeue-invariants.config-inventory=tests/x.sh 5' \
  'conf.prequeue-invariants.determinism=rm -rf' conf.prequeue-invariants.hold-push-ratchet=0 conf.prequeue-invariants.pr-trailers-sites=-1
pq c3l --list --harness "$H"
[ "$(rc c3l)" = 0 ] && [ "$(out c3l | wc -l)" = "$NCAT" ] && ok || bad "C3: --list has $NCAT rows (rc $(rc c3l); err $(cat "$T/c3l.err"))"
[ "$(budget_of c3l share-mirror-clean)" = 90 ] && ok || bad "C3: share-mirror-clean=90 rebudgets (got '$(budget_of c3l share-mirror-clean)')"
[ "$(budget_of c3l config-inventory) $(budget_of c3l determinism) $(budget_of c3l hold-push-ratchet) $(budget_of c3l pr-trailers-sites)" = "51 27 3 25" ] && ok \
  || bad "C3: refused rows keep the catalog budgets (got $(budget_of c3l config-inventory) $(budget_of c3l determinism) $(budget_of c3l hold-push-ratchet) $(budget_of c3l pr-trailers-sites))"
[ "$(col c3l 3)" = "$(crows | cut -f3)" ] && ok || bad "C3: no row changes argv"
GL=$(cat "$H/logs/lane-gate.log" 2>/dev/null)
for k in config-inventory determinism hold-push-ratchet pr-trailers-sites; do
  has "$GL" "row conf.prequeue-invariants.$k=" && has "$GL" refused && ok || bad "C3: lane-gate.log names $k as refused (log: $GL)"
done
has "$GL" "share-mirror-clean" && bad "C3: the accepted row is not logged as refused" || ok
pq c3o --overrides --harness "$H"
[ "$(rc c3o)" = 0 ] && [ "$(out c3o)" = share-mirror-clean=90 ] && ok || bad "C3: --overrides prints only share-mirror-clean=90 (got '$(out c3o)')"
has "$(cat "$T"/c3*.out "$T"/c2*.out)" "tests/x.sh" && bad "C3: no output carries a refused value" || ok
has "$(cat "$T"/c3o.out "$T"/c2o.out "$T"/c2b.out)" "tests/" && bad "C3: --overrides never prints a suite path" || ok
# C3b. A row for an id not in the catalog.
reset; cache_in conf.prequeue-invariants.nope=off
pq c3b --list --harness "$H"
[ "$(rc c3b)" = 0 ] && [ "$(out c3b)" = "$CAT4" ] && ok || bad "C3b: an unknown id changes nothing (rc $(rc c3b))"
pq c3c --overrides --harness "$H"
[ -z "$(out c3c)" ] && ok || bad "C3b: --overrides prints nothing for an unknown id (got '$(out c3c)')"
[ ! -s "$H/logs/lane-gate.log" ] && ok || bad "C3b: an unknown id logs nothing ($(cat "$H/logs/lane-gate.log"))"

# ============================================================================
# C9. Every row off: rc 2, never green.
# ============================================================================
R="$T/r"; mkdir -p "$R/tests"
scratch_install_closure bin/prequeue-invariants.sh "$R" >/dev/null || bad "setup: install the runner in R"
scratch_install_closure bin/test-suite-run.sh "$R" >/dev/null || bad "setup: install test-suite-run"
scratch_install_closure bin/ci-tool-present.sh "$R" >/dev/null || bad "setup: install ci-tool-present"
printf '#!/bin/bash\necho fine\n' > "$R/tests/green.sh"
# inv <case> <catalog body> [args...] — the real runner in $R on a stub catalog.
inv() {
  local c="$1"; printf '%s' "$2" > "$T/$c.tsv"; shift 2
  ( cd "$T" && env -u PQ_MAIN ${INV_ENV:-} bash "$R/bin/prequeue-invariants.sh" --run --catalog "$T/$c.tsv" --out "$T/$c.d" "$@" ) > "$T/$c.out" 2> "$T/$c.err"
  echo $? > "$T/$c.rc"
}
inv c9 "$(row green suite tests/green.sh 5 g)${NL}$(row green2 suite tests/green.sh 5 g)${NL}" --overrides green=off,green2=off
[ "$(rc c9)" = 2 ] && has "$(cat "$T/c9.err")" "no invariant left" && [ ! -e "$T/c9.d/timings.tsv" ] && ok \
  || bad "C9: every row off on --run is rc 2 (rc $(rc c9), err $(cat "$T/c9.err"))"
ALLOFF=(); for id in $(crows | cut -f1); do ALLOFF+=("conf.prequeue-invariants.$id=off"); done
reset; cache_in "${ALLOFF[@]}"
pq c9l --list --harness "$H"
[ "$(rc c9l)" = 2 ] && [ -z "$(out c9l)" ] && ok || bad "C9: every row off on --list is rc 2 (rc $(rc c9l))"
pq c9r --run --catalog "$H/catalog/prequeue-invariants.tsv" --out "$T/c9r.d" --harness "$H"
[ "$(rc c9r)" = 2 ] && [ ! -e "$T/c9r.d/timings.tsv" ] && ok || bad "C9: every row off through settings rows on --run is rc 2 (rc $(rc c9r))"
pq c9o --overrides --harness "$H"
[ "$(rc c9o)" = 0 ] && [ "$(out c9o)" = "$(crows | cut -f1 | sed 's/$/=off/' | paste -sd, -)" ] && ok \
  || bad "C9: --overrides prints the $NCAT off items in catalog order (got '$(out c9o)')"

# ============================================================================
# J1. --jobs N.
# ============================================================================
# meet <mine> <theirs> [extra] — touch my mark, wait up to 3 s for theirs, then
# spin <extra> more seconds; red if theirs never came.
cat > "$R/tests/meet.sh" <<'SH'
#!/bin/bash
touch "$J1_DIR/$1"; end=$((SECONDS + 3))
while [ ! -e "$J1_DIR/$2" ] && [ "$SECONDS" -lt "$end" ]; do :; done
[ -e "$J1_DIR/$2" ] || { echo "FAIL: $1 never met $2"; exit 1; }
end=$((SECONDS + ${3:-0})); while [ "$SECONDS" -lt "$end" ]; do :; done
echo "met"
SH
printf '#!/bin/bash\nexec bash tests/meet.sh a b 1\n' > "$R/tests/meet-a.sh"
printf '#!/bin/bash\nexec bash tests/meet.sh b a\n' > "$R/tests/meet-b.sh"
JCAT="$(row aa suite tests/meet-a.sh 30 "waits for bb")${NL}$(row bb suite tests/meet-b.sh 30 "waits for aa")${NL}"
mkdir -p "$T/j2" "$T/j1"
INV_ENV="J1_DIR=$T/j2" inv j2 "$JCAT" --jobs 2
[ "$(rc j2)" = 0 ] && ok || bad "J1: --jobs 2 runs both rows at once (rc $(rc j2); $(cat "$T/j2.out"); $(cat "$T/j2.d/fail/"* 2>/dev/null))"
[ "$(grep '^prequeue-invariant: ' "$T/j2.out" | cut -d' ' -f2 | tr '\n' ' ')" = "aa bb " ] && ok || bad "J1: --jobs 2 lines in catalog order (got $(cat "$T/j2.out"))"
[ "$(cut -f1 "$T/j2.d/timings.tsv" 2>/dev/null | tr '\n' ' ')" = "aa bb " ] && [ "$(tr '\n' ' ' < "$T/j2.d/suites.txt" 2>/dev/null)" = "tests/meet-a.sh tests/meet-b.sh " ] && ok \
  || bad "J1: timings.tsv and suites.txt in catalog order (got $(cat "$T/j2.d/timings.tsv" "$T/j2.d/suites.txt" 2>/dev/null | tr '\n' ' '))"
TOT=$(tail -n1 "$T/j2.out"); SUM=$(awk -F'\t' '{ s += $3 } END { print s + 0 }' "$T/j2.d/timings.tsv" 2>/dev/null)
[[ $TOT =~ ^prequeue-invariants:\ total\ ${SUM}s\ wall\ [0-9]+s\ \(2\ run,\ 0\ red\)$ ]] && ok || bad "J1: the total line sums timings.tsv ($SUM; got '$TOT')"
[ -z "$(find "$T/j2.d" -name '.only*' 2>/dev/null)" ] && ok || bad "J1: no list file is left behind"
INV_ENV="J1_DIR=$T/j1" inv j1 "$JCAT" --jobs 1
[ "$(rc j1)" = 1 ] && [ "$(cat "$T/j1.d/failed.txt" 2>/dev/null)" = aa ] && ok || bad "J1: --jobs 1 is serial, aa never meets bb (rc $(rc j1); failed '$(cat "$T/j1.d/failed.txt" 2>/dev/null)')"
[ "$(grep '^prequeue-invariant: ' "$T/j1.out" | cut -d' ' -f2,3 | tr '\n' ' ')" = "aa rc=1 bb rc=0 " ] && ok || bad "J1: --jobs 1 lines (got $(cat "$T/j1.out"))"
inv j0 "$JCAT" --jobs 0
[ "$(rc j0)" = 2 ] && [ ! -d "$T/j0.d" ] && ok || bad "J1: --jobs 0 is rc 2 (rc $(rc j0))"
inv jx "$JCAT" --jobs two
[ "$(rc jx)" = 2 ] && ok || bad "J1: --jobs two is rc 2 (rc $(rc jx))"

# ============================================================================
# D6. The workflow's real verdict step, dry run.
# ============================================================================
python3 - "$WF" "$T/w" <<'PY' || bad "D6: the workflow must parse and carry its verdict step"
import sys, yaml, os
wf = yaml.safe_load(open(sys.argv[1]))
os.makedirs(sys.argv[2], exist_ok=True)
step = [s for s in wf["jobs"]["gate"]["steps"] if s.get("id") == "verdict"][0]
open(sys.argv[2] + "/run.sh", "w").write(step["run"])
open(sys.argv[2] + "/env", "w").write(step["env"].get("PQ_INVARIANTS_IN", "") + "\n")
i = wf[True]["workflow_dispatch"]["inputs"].get("invariants") or {}
open(sys.argv[2] + "/input", "w").write("required=%s default='%s' type=%s\n" % (i.get("required"), i.get("default"), i.get("type")))
PY
[ "$(cat "$T/w/env" 2>/dev/null)" = '${{ inputs.invariants }}' ] && ok || bad "D6: PQ_INVARIANTS_IN is the invariants input (got '$(cat "$T/w/env" 2>/dev/null)')"
[ "$(cat "$T/w/input" 2>/dev/null)" = "required=False default='' type=string" ] && ok || bad "D6: invariants is an optional string input defaulting to '' (got $(cat "$T/w/input" 2>/dev/null))"
O="$T/origin.git"; S="$T/seed"
git init -q --bare "$O"; git init -q "$S"
sg() { git -C "$S" -c user.email=t@example.com -c user.name=t "$@"; }
mkdir -p "$S/bin" "$S/tests" "$S/catalog"
scratch_install_closure bin/prequeue-invariants.sh "$S" >/dev/null || bad "D6 setup: install the runner"
scratch_install_closure bin/test-suite-run.sh "$S" >/dev/null || bad "D6 setup: install test-suite-run"
scratch_install_closure bin/ci-tool-present.sh "$S" >/dev/null || bad "D6 setup: install ci-tool-present"
printf '#!/bin/bash\nexit "${STUB_RC:-0}"\n' > "$S/bin/test-impact-gate.sh"
# one and two meet each other: both green only when the workflow runs them at once.
cp "$R/tests/meet.sh" "$S/tests/meet.sh"
printf '#!/bin/bash\nexec bash tests/meet.sh one two\n' > "$S/tests/one.sh"
printf '#!/bin/bash\nexec bash tests/meet.sh two one\n' > "$S/tests/two.sh"
printf '%s' "$(row one suite tests/one.sh 30 "meets two")${NL}$(row two suite tests/two.sh 30 "meets one")${NL}" > "$S/catalog/prequeue-invariants.tsv"
echo base > "$S/x.txt"; sg add -A; sg commit -qm main; DM=$(git -C "$S" rev-parse HEAD)
echo head > "$S/y.txt"; sg add -A; sg commit -qm head; DH=$(git -C "$S" rev-parse HEAD)
# A second main whose one and two are plain green stubs, for D6b.
sg checkout -q "$DM"; printf '#!/bin/bash\necho fine\n' > "$S/tests/g1.sh"; cp "$S/tests/g1.sh" "$S/tests/g2.sh"
printf '%s' "$(row one suite tests/g1.sh 30 g)${NL}$(row two suite tests/g2.sh 30 g)${NL}" > "$S/catalog/prequeue-invariants.tsv"
sg add -A; sg commit -qm main2; DM2=$(git -C "$S" rev-parse HEAD)
echo head2 > "$S/y.txt"; sg add -A; sg commit -qm head2; DH2=$(git -C "$S" rev-parse HEAD)
sg push -q "$O" "$DH:refs/pull/51/head" "$DH2:refs/pull/52/head" "$DM:refs/heads/main" "$DM2:refs/heads/m2"
# dry <case> [VAR=value ...] — the verdict step in a fresh checkout of main
# (PQ_PR=52 DM=$DM2 DH=$DH2 for the second main).
dry() {
  local c="$1" pr=51 m="$DM" h="$DH"; shift
  [ "${1:-}" = m2 ] && { pr=52; m="$DM2"; h="$DH2"; shift; }
  git clone -q "$O" "$T/wd-$c" 2>/dev/null; git -C "$T/wd-$c" checkout -q "$m"
  mkdir -p "$T/rt-$c" "$T/mk-$c"
  ( cd "$T/wd-$c" && env PQ_PR="$pr" PQ_HEAD="$h" PQ_MAIN="$m" PQ_SUITES_IN="" PQ_INVARIANTS_IN="" RUNNER_TEMP="$T/rt-$c" \
      J1_DIR="$T/mk-$c" "$@" bash "$T/w/run.sh" ) > "$T/out-$c" 2>&1
  echo "rc=$?" >> "$T/out-$c"
}
outside() {
  awk '/^::stop-commands::/ { tok = substr($0, 18); off = 1; next }
       off && $0 == "::" tok "::" { off = 0; next }
       !off { print }' "$T/out-$1"
}
verdict() { outside "$1" | sed -n 's/^::notice title=prequeue-verdict:://p'; }
dry d6a PQ_INVARIANTS_IN='tests/x.sh=off'
dry d6b PQ_INVARIANTS_IN='a=off;rm'
dry d6c PQ_INVARIANTS_IN=$'a=off\nb=1'
dry d6d PQ_INVARIANTS_IN='one=off,'
for c in d6a d6b d6c d6d; do
  [ "$(verdict "$c" | grep -c .)" = 1 ] && [ "$(verdict "$c")" = "could-not-run main=$DM head=$DH suites= why=bad-invariants" ] && ok \
    || bad "D6 $c: a malformed input is could-not-run why=bad-invariants (got: $(tr '\n' '|' < "$T/out-$c"))"
  grep -qx 'rc=0' "$T/out-$c" && ok || bad "D6 $c: the step exits 0"
  [ ! -d "$T/rt-$c/inv" ] && ok || bad "D6 $c: nothing ran"
done
# D6b. A good input drops that row and runs the other.
dry d6g m2 PQ_INVARIANTS_IN=one=off
[ "$(verdict d6g | grep -c .)" = 1 ] && [ "$(verdict d6g)" = "green main=$DM2 head=$DH2 suites=" ] && ok || bad "D6b: one=off is one green verdict (got: $(tr '\n' '|' < "$T/out-d6g"))"
[ ! -e "$T/rt-d6g/inv/log/one.log" ] && [ -e "$T/rt-d6g/inv/log/two.log" ] && ok \
  || bad "D6b: one did not run, two did (logs: $(ls "$T/rt-d6g/inv/log" 2>/dev/null | tr '\n' ' '))"
# On the meeting main, two never meets a dropped one: the override reached the runner.
dry d6h PQ_INVARIANTS_IN=one=off
[ "$(verdict d6h)" = "red main=$DM head=$DH suites=tests/two.sh why=invariant:two" ] && [ ! -e "$T/rt-d6h/inv/log/one.log" ] && ok \
  || bad "D6b: one=off on the meeting main leaves two alone (got '$(verdict d6h)')"
dry d6r m2 PQ_INVARIANTS_IN=two=40
grep -q '^prequeue-invariant: two rc=0 [0-9]*s budget 40s$' "$T/out-d6r" && ok || bad "D6b: two=40 rebudgets (got $(grep '^prequeue-invariant' "$T/out-d6r"))"
# No input: both rows, at once (--jobs 4), green.
dry d6n
[ "$(verdict d6n)" = "green main=$DM head=$DH suites=" ] && [ -s "$T/rt-d6n/inv/timings.tsv" ] && [ ! -s "$T/rt-d6n/inv/failed.txt" ] && ok \
  || bad "D6: no input runs both rows in parallel and is green (got '$(verdict d6n)'; failed '$(cat "$T/rt-d6n/inv/failed.txt" 2>/dev/null)')"

# ============================================================================
# K6. The real conductor dispatch.
# ============================================================================
KS=example-org/demo-os; KH=$(printf 'a%.0s' $(seq 40)); KM=$(printf 'c%.0s' $(seq 40))
# k6 <name> <MC_H> — source the real tracer and its hooks, dispatch once.
k6() {
  ( export MC_STATE_DIR="$T/k6-$1/state" MC_H="$2" GH_ARGV="$T/k6-$1/gh.argv" JOBS_BOX=hub-1
    mkdir -p "$MC_STATE_DIR" "$MC_H/locks" "$T/k6-$1/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$GH_ARGV"\n' > "$T/k6-$1/bin/gh"; chmod +x "$T/k6-$1/bin/gh"
    PATH="$T/k6-$1/bin:$PATH"
    mc_log() { :; }; mc_use_token() { :; }; mc_safe_name() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
    . "$DIR/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 9
    pq_dispatch "$KS" 7 "$KH" "$KM"; echo "rc=$?" ) > "$T/k6-$1.out" 2>&1
}
argv() { cat "$T/k6-$1/gh.argv" 2>/dev/null; }
BASE_ARGV="workflow run prequeue-gate.yml -R $KS --ref main -f pr=7 -f head=$KH -f main=$KM"
reset; cache_in conf.prequeue-invariants.lanes-registry=off
k6 row "$H"
[ "$(argv row)" = "$BASE_ARGV -f invariants=lanes-registry=off" ] && ok || bad "K6: the argv carries -f invariants=lanes-registry=off (got '$(argv row)'; $(cat "$T/k6-row.out"))"
reset
k6 norow "$H"
[ "$(argv norow)" = "$BASE_ARGV" ] && ok || bad "K6: no row, the argv is unchanged (got '$(argv norow)')"
# K6b. No script in MC_H.
mkdir -p "$T/bare"
k6 bare "$T/bare"
[ "$(argv bare)" = "$BASE_ARGV" ] && ok || bad "K6b: no bin/prequeue-invariants.sh in MC_H, the argv is byte-identical (got '$(argv bare)')"
# K6c. A script that prints garbage never puts a word into the argv.
for g in 'a=off /etc/passwd' 'a=off -f suites=tests/x.sh' 'tests/x.sh=off'; do
  G="$T/garb-${#g}"; mkdir -p "$G/bin"
  printf '#!/bin/bash\nprintf "%%s\\n" %q\n' "$g" > "$G/bin/prequeue-invariants.sh"
  k6 "garb-${#g}" "$G"
  [ "$(argv "garb-${#g}")" = "$BASE_ARGV" ] && ok || bad "K6c: '$g' never reaches the argv (got '$(argv "garb-${#g}")')"
done

echo "prequeue-invariant-overrides: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
