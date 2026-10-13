#!/bin/bash
# bin/test-impact-gate.sh — THE BUILDER'S GATE: run the suites this diff can
# reach, before the push, bounded, and say which ones were left to CI (BH-1524).
#
#   bin/test-impact-gate.sh [--base <ref>] [--head <ref>] [--cap N]
#                           [--budget SECONDS] [--project <slug>]
#                           [--runner auto|isolated|local|remote|plan]
#                           [--list <file>] [--table <file>]
#                           [--skip-suites <file>] [--failed <file>]
#
# WHY THIS EXISTS. BH-1524 counted four lead PRs that each needed an extra
# review round because a pinned-contract suite went red in CI — T1.32 in
# launch-fastpath, mc-split-layout's expected-map, br-contested's caller pin,
# priority-rank's A10 and gh-rest-lib's line ceiling. bin/test-impact.sh had
# selected every one of them; CI ran them and they went red, which is CI doing
# its job one round too late. What had not run them was the BUILDER: a Mac
# build's gate table was a hand-picked list, and a pool build of this repo ran
# nothing at all — cromford has no package.json, so HARNESS_SUITE_RUN
# recorded `no-test-script` and pushed. This script is the gate both use now:
# bin/run-build.sh's HARNESS_SUITE_RUN calls it for a checkout that carries it,
# and prompts/build-discipline.md D38 tells a Mac builder to run it.
#
# WHAT IT RUNS. `bin/test-impact.sh select <base>..<head> --map-only --why`:
# the map's picks with a reason per suite. --map-only because an infra change
# (tests/lib/, catalog/, a workflow) sends CI to the whole corpus, and a gate
# that answered that with 700 serial suites would never finish; the gate runs
# what the map can see and the reason line says CI keeps the corpus.
#
# THE CAP, THE BUDGET, AND WHAT IS LEFT. Selections on this repo run from ~40
# to ~500 suites, and 80 of them took 820 s serially on an idle test host (the
# #1541 review). So the gate is bounded twice, strongest reason first:
#
#   self > reads > always > named > source > closure
#
# self is the diff's own suites; reads is a suite that greps, diffs or counts
# over the changed file; always is the whole-tree ratchets (the gh-rest line
# ceiling is one); named is a suite naming a function the changed file defines.
# `always` ranks above `named` because named is the noisier kind: every function
# a changed file defines counts, not only the changed ones.
#
#   --cap     at most this many suites          (TEST_IMPACT_GATE_CAP, 80)
#   --budget  stop STARTING suites after this   (TEST_IMPACT_GATE_BUDGET_S, 450)
#
# Both are settings rows: knobs of the `fly-pool` lane in catalog/lanes.d/
# (`lane.fly-pool[.<project>].test_impact_gate_cap` / `…_budget_s`), resolved
# by bin/lib/lane-gate.sh's lane_knob: row, then env, then the registry default.
# The numbers above are the code's last fallback, for a machine with no
# registry at all. The budget's default is 450 s (BH-1554, measured on the
# #1541 review: 450 s ran the self suites plus 28 of 30 reads pins in about
# 7.5 min, where 900 took about 15) because the tail past 450 is suites the
# always-ratchets CI runs anyway, and the gate can run up to three times in one
# build. The registry's max is 1250, not 1500: the build stage wraps this whole
# script in `timeout 1500` (HARNESS_IMPACT_GATE_RUN in bin/run-build.sh) and
# the suite that is running when the budget runs out still has to finish, and
# that overrun has to fit in the 250 s of headroom. The slowest suites here are
# measured, not estimated: on this fleet's test host the durations file below
# records tests/registry-no-commit-test.sh at 205-208 s and
# tests/share-publish-clean.bh-795-test.sh at 224 s (BH-1554, two isolated gate
# runs over this repo's own diff). 224 s is under 250, so the max holds — and a
# suite that grows past 250 s is what would make 1250 the wrong number, which
# is the thing to check before raising it.
#
# WHICH ONES RUN FIRST, inside a tier. The ranks below order the tiers; within
# one tier the shortest suite goes first, by the wall time this box last
# measured for it. Those times live in ONE per-box file, rewritten atomically by
# this script after every local or isolated run:
#
#   ${HARNESS_STATE_DIR:-${HARNESS:-/root/harness}/state}/test-impact-durations.tsv
#   (override with TEST_IMPACT_DURATIONS_FILE; `<suite>\t<seconds>` per line)
#
# It is a sort HINT and nothing else: a suite with no recorded time sorts after
# the ones that have one (alphabetically among themselves), a missing or
# unwritable file is a warning on stderr and yesterday's alphabetical order, and
# no value in it can change WHICH suites are selected or what the verdict is.
# The `plan` and `remote` runners record nothing (remote runs in parallel, so
# its times are not serial durations).
#
# Nothing past either bound is dropped silently. The cap's remainder and the
# budget's remainder are each counted and listed as left to CI, in the log and
# in the --table the PR body carries. CI still runs the full selection — EXCEPT
# the nightly tier (catalog/test-tiers.tsv), which no batch runs: those suites
# run first and outside the cap, and any the budget cannot start are listed as
# left to the nightly run, never as left to CI.
#
# THE RUNNER, AND WHY auto IS NOT "run them here". tests/lib/scratch.sh refuses
# to run as root next to a live harness unless HARNESS_TEST_SANDBOX=1, and that
# variable is never set by a bin/ lane (#463) — it is the guard that stops a
# test wiping the install it runs beside (#388). A pool builder is exactly that:
# root, beside /root/harness, with no flyctl and no test-host key (the image
# holds one credential, fly/Dockerfile). So auto picks by where it is:
#
#   isolated  root beside a live harness: HEAD is snapshotted into a scratch
#             tree (git archive, then a fresh `git init` — the shape
#             bin/remote-gate.sh gives the test host) and the suites run THERE
#             as `nobody`, through setpriv. The guard's danger is gone by
#             construction rather than waved through: nobody cannot write the
#             root-owned install, and the suites see only the snapshot.
#   local     anywhere else (a Mac, a CI runner): serial, in this checkout,
#             through bin/test-suite-run.sh.
#   remote    bin/remote-gate.sh on the Fly test host — by name only, for a
#             machine that has the key (a lead's Mac).
#   plan      select and rank, write --list/--table, run NOTHING; says NOT RUN
#
# GITLEAKS (BH-2115). tests/share-publish-clean.bh-795-test.sh skips its
# gitleaks arm when gitleaks is absent and GITLEAKS_REQUIRED is unset, and the
# isolated runner's `env -i` handed it neither, so every pool and box gate
# skipped it. The isolated runner now exports GITLEAKS_REQUIRED=1 to every
# suite, and when a selected suite contains `command -v gitleaks` it first puts
# the pinned, sha256-checked gitleaks from bin/lib/gitleaks-pin.sh in the
# snapshot's tools/ dir, first on the suites' PATH. It is lazy so a diff that
# reaches no such suite downloads nothing. An install that cannot happen (no
# network, a checksum mismatch, a platform with no pinned asset) is 125 with
# the step named: that is infrastructure, not a red suite and never a pass. The
# local, remote and plan runners are unchanged; CI's local run sets REQUIRED
# and installs the same pin itself.
#
# EXIT CODES, and they do not overlap:
#   0    every suite it ran passed
#   1    at least one suite it ran failed
#   2    no selection: bad arguments, an unresolvable range, a map that would
#        not build, or an empty answer — never a green of nothing
#   125  the run could not happen: no setpriv, a setpriv that cannot switch to
#        `nobody` (checked with the exact flags before any suite runs), a
#        snapshot that would not build, a pinned gitleaks that could not be
#        installed (BH-2115), or bin/remote-gate.sh's own 125
#
# SKIP-SUITES (BH-3513). --skip-suites <file> names suites (one tests/*.sh
# path per line) the rules pack already ran in this stage: HARNESS_IMPACT_GATE_RUN
# passes bin/rules-pack.sh's --out suites.txt. They are dropped AFTER ranking,
# printed as `plan: <suite>  run by the rules pack (outside the cap)`, and count
# neither against the cap nor as left to CI. An unreadable file is a stderr note
# and no skip. Without the flag nothing changes.
#
# FAST-LINT TIER (BH-3860). The PR check's lint step runs a fast set of cheap
# always-suites; the gate runs the same set, FIRST and outside the cap, so the
# cap or a long tail can never drop a 2 s lint and let it reach a batch. The set
# is the checkout's own `bin/fast-lints.sh --list` (TEST_IMPACT_GATE_FAST names
# a list file instead, for tests). A fast suite the selection picked keeps its
# reasons after `fast-lint (the PR check runs it too); `; one it did not pick is
# added at rank 0 and counts in the selected total. --skip-suites wins: a suite
# the rules pack ran is never in the tier. A list that fails or cannot be read
# is one stderr note and no tier, never fatal; a checkout with no
# bin/fast-lints.sh has no tier and no note. --table tags the rows `(fast)`. A
# fast suite the budget never started is left to CI like any other.
#
# SCRATCH-CLOSURE TIER (BH-4869). A diff that adds, edits or renames a
# tests/*.sh or tests/mc/*.sh suite always runs
# tests/scratch-closure-lint.bh-4552-test.sh in the fast tier, first and outside
# the cap: the selector reaches it only as a `source` pick, which the cap can
# drop. --skip-suites still wins, since the rules pack runs it as a component.
#
# FAILED (BH-4548). --failed <file> is emptied before anything else runs, so
# every exit (rc 2 included) leaves it empty rather than stale. After the run it
# names every suite whose rc was non-zero, one per line; a suite the budget
# never started and a remote run (no per-suite rc) are not in it. On green it
# is empty. It changes no exit code and no stdout. A path that cannot be
# written is rc 2 before any suite runs. .github/workflows/prequeue-gate.yml
# reads it to say which suites fail on the head merged onto main.
#
# PROGRESS LINES. Each finished suite prints `impact-gate: done <suite> rc=<n>`
# the moment it finishes, so a run the build stage's timeout kills still says
# which suites completed (HARNESS_IMPACT_GATE_RUN lists them). The ranked plan
# is printed with a `plan:` prefix, so nothing reading the log for pass markers
# (bin/lib/evidence.sh) can mistake a listed reason for a result.
#
# SUITE REUSE (BH-5354.1). On the local and isolated runners only, when the
# checkout carries an executable bin/suite-reuse.sh, the gate hands the run list
# minus the fast tier to `bin/suite-reuse.sh plan --class builder`. A suite the
# suite ledger already saw pass at the same input fingerprint leaves the run
# list and prints `impact-gate: reused <suite> from <run_id> (<d>s)`, never
# `impact-gate: done`: HARNESS_IMPACT_GATE_RUN (bin/lib/rb/gates.sh) lists the
# `done` lines as completed HERE when its timeout kills the gate. --table tags
# it `(reused <run_id>)`, and a line after the summary counts them. After the run
# `record` writes what ran (run key SUITE_REUSE_RUN_KEY, else
# builder-<host>-<epoch>-<pid>); recording never changes the rc. Any trouble,
# including a helper answer that does not match the list it was given, prints
# `suite-reuse: off (<why>)` and every suite runs. SUITE_REUSE=off is the kill
# switch. The repo is SUITE_REUSE_REPO, else origin's <owner>/<name>.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
BASE_REF="origin/main"
HEAD_REF="HEAD"
CAP=""
BUDGET=""
PROJECT_SLUG="${PROJECT:-}"
RUNNER="${TEST_IMPACT_GATE_RUNNER:-auto}"
LIST_OUT=""
TABLE_OUT=""
SKIP_SUITES=""
FAILED_OUT=""

die2() { echo "impact-gate: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base)    [ $# -ge 2 ] || die2 "--base needs a ref";  BASE_REF="$2"; shift ;;
    --head)    [ $# -ge 2 ] || die2 "--head needs a ref";  HEAD_REF="$2"; shift ;;
    --cap)     [ $# -ge 2 ] || die2 "--cap needs a number"; CAP="$2"; shift ;;
    --budget)  [ $# -ge 2 ] || die2 "--budget needs a number of seconds"; BUDGET="$2"; shift ;;
    --project) [ $# -ge 2 ] || die2 "--project needs a slug"; PROJECT_SLUG="$2"; shift ;;
    --runner)  [ $# -ge 2 ] || die2 "--runner needs a value"; RUNNER="$2"; shift ;;
    --list)    [ $# -ge 2 ] || die2 "--list needs a path";  LIST_OUT="$2"; shift ;;
    --table)   [ $# -ge 2 ] || die2 "--table needs a path"; TABLE_OUT="$2"; shift ;;
    --skip-suites) [ $# -ge 2 ] || die2 "--skip-suites needs a path"; SKIP_SUITES="$2"; shift ;;
    --failed)  [ $# -ge 2 ] || die2 "--failed needs a path"; FAILED_OUT="$2"; shift ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *) die2 "unknown argument '$1' (try --help)" ;;
  esac
  shift
done
[ -z "$FAILED_OUT" ] || { : > "$FAILED_OUT"; } 2>/dev/null || die2 "--failed: cannot write $FAILED_OUT"

# ── the knobs: a flag, else a settings row, else env, else the registry ─────
# lane-gate.sh is the one resolver every lane uses (row > env > registry
# default, clamped to the registry's bounds). The live harness's copy first —
# its registry and its settings cache are the ones that mean something on a
# box — then this checkout's. Neither readable (a Mac) is env, then the
# fallback. A resolver that answers something that is not a whole number is
# ignored rather than obeyed.
# The entry point owns the root default (BH-2613 rule 4): the libs below have none.
H="${HARNESS:-${H:-/root/harness}}"
for _lg in "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" "$SELF_DIR/lib/lane-gate.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_lg" ] && . "$_lg" 2>/dev/null && break
done
gate_knob() { # gate_knob <ENV> <fallback>
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob fly-pool "$1" "$PROJECT_SLUG" 2>/dev/null)
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}
[ -n "$CAP" ]    || CAP=$(gate_knob TEST_IMPACT_GATE_CAP 80)
[ -n "$BUDGET" ] || BUDGET=$(gate_knob TEST_IMPACT_GATE_BUDGET_S 450)
case "$CAP" in ''|*[!0-9]*) die2 "--cap wants a whole number, got '$CAP'" ;; esac
[ "$CAP" -ge 1 ] || die2 "--cap must be at least 1"
case "$BUDGET" in ''|*[!0-9]*) die2 "--budget wants whole seconds, got '$BUDGET'" ;; esac
[ "$BUDGET" -ge 1 ] || die2 "--budget must be at least 1 second"
case "$RUNNER" in auto|isolated|local|remote|plan) ;; *) die2 "--runner is auto, isolated, local, remote or plan — got '$RUNNER'" ;; esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/impact-gate.XXXXXX") || die2 "cannot make a temp dir"
trap 'rm -rf "$TMP"' EXIT

# ── the base is the MERGE-BASE ──────────────────────────────────────────────
# `select a..b` is a two-dot diff. Handed `origin/main` on a branch that main
# has moved past, it would count main's newer commits as this diff — selecting
# suites for work this branch never did. The fork point is what a build owes
# a gate for; a base with no merge-base (unrelated history, a bad ref) is used
# as given and the selector refuses it if it cannot resolve.
FORK=$(git -C "$ROOT" merge-base "$BASE_REF" "$HEAD_REF" 2>/dev/null) || FORK="$BASE_REF"

# ── select, with the reasons ────────────────────────────────────────────────
# The reason line comes back on stderr; the rows on stdout. A selector that
# fails, or answers nothing, is rc 2 here — the build record then reads
# HARNESS_EXIT: 2, which no reviewer mistakes for a pass.
( cd "$ROOT" && bin/test-impact.sh select "$FORK..$HEAD_REF" --map-only --why ) \
  > "$TMP/why" 2> "$TMP/reason" || die2 "the selector failed: $(tail -1 "$TMP/reason")"
REASON=$(grep '^impact:' "$TMP/reason" | tail -1)
case "$REASON" in *"full: cannot diff"*|*"full: the map could not"*)
  die2 "no selection — ${REASON#impact: }" ;; esac
[ -s "$TMP/why" ] || die2 "the selection came back empty (${REASON:-no reason given})"

# ── rank and cap ────────────────────────────────────────────────────────────
# One row per suite: its strongest reason's rank, then every reason it has,
# strongest first — the table a reviewer reads leads with the pin.
awk -F'\t' '
  BEGIN { r["self"] = 0; r["reads"] = 1; r["always"] = 2; r["named"] = 3
          r["source"] = 4; r["closure"] = 5; r["full"] = 6 }
  { k = ($2 in r) ? r[$2] : 6
    if (!($1 in best) || k < best[$1]) best[$1] = k
    w[$1, k] = w[$1, k] (w[$1, k] == "" ? "" : "; ") $2 " " $3 }
  END { for (s in best) { out = ""
          for (k = 0; k <= 6; k++) if ((s, k) in w) out = out (out == "" ? "" : "; ") w[s, k]
          print best[s] "\t" s "\t" out } }
' "$TMP/why" > "$TMP/ranked.raw"

# Shortest first inside a tier (BH-1554). Column 3 is the recorded duration, or
# 999999 for a suite this box has never timed, so unknowns fall to the end of
# their tier and keep today's alphabetical order among themselves. The column is
# dropped again straight after the sort: every reader downstream sees the same
# three fields it always did.
DURATIONS_FILE="${TEST_IMPACT_DURATIONS_FILE:-${HARNESS_STATE_DIR:-${HARNESS:-/root/harness}/state}/test-impact-durations.tsv}"
awk -F'\t' -v df="$DURATIONS_FILE" '
  BEGIN { while ((getline line < df) > 0) {
            n = split(line, f, "\t")
            if (n >= 2 && f[2] ~ /^[0-9]+$/) d[f[1]] = f[2] + 0 } }
  { print $1 "\t" (($2 in d) ? d[$2] : 999999) "\t" $2 "\t" $3 }
' "$TMP/ranked.raw" \
  | LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2n -k3,3 \
  | cut -f1,3,4 > "$TMP/ranked"
# SKIP-SUITES: what the rules pack already ran leaves the plan here, after the
# ranking and before the count, so the cap and "left to CI" never see it.
: > "$TMP/skipped"
if [ -n "$SKIP_SUITES" ]; then
  if [ -r "$SKIP_SUITES" ]; then
    if [ -s "$SKIP_SUITES" ]; then
      awk -F'\t' -v sf="$SKIP_SUITES" -v sk="$TMP/skipped" '
        FILENAME == sf { if ($0 != "") d[$0] = 1; next }
        ($2 in d) { print $2 > sk; next }
        { print }' "$SKIP_SUITES" "$TMP/ranked" > "$TMP/ranked.kept" && mv "$TMP/ranked.kept" "$TMP/ranked"
    fi
  else
    echo "impact-gate: --skip-suites $SKIP_SUITES is not readable — nothing skipped" >&2
  fi
fi
# FAST-LINT TIER (BH-3860): the PR check's fast set, first and outside the cap.
# TEST_IMPACT_GATE_FAST overrides the list (tests); otherwise the checkout's own
# bin/fast-lints.sh, so a checkout without it is exactly what it was.
FAST_FILE="${TEST_IMPACT_GATE_FAST:-}"
: > "$TMP/fast.all"
if [ -n "$FAST_FILE" ]; then
  if [ -r "$FAST_FILE" ]; then grep -v '^[[:space:]]*\(#\|$\)' "$FAST_FILE" > "$TMP/fast.all"
  else echo "impact-gate: fast-lint list unavailable — no fast tier" >&2; fi
elif [ -x "$ROOT/bin/fast-lints.sh" ]; then
  ( cd "$ROOT" && bin/fast-lints.sh --list ) > "$TMP/fast.all" 2>/dev/null \
    || { : > "$TMP/fast.all"; echo "impact-gate: fast-lint list unavailable — no fast tier" >&2; }
fi
# >>> scratch-closure tier (BH-4869)
# The selector reaches the scratch-closure lint only as a `source` pick, so the
# cap could drop it; the PR check runs it through the rules pack. Any suite this
# diff adds or edits puts it in the fast tier.
# A diff that fails answers "no suite touched": nothing is promoted.
SCL_SUITE=tests/scratch-closure-lint.bh-4552-test.sh
if [ -f "$ROOT/$SCL_SUITE" ]; then
  _scl=$(git -C "$ROOT" diff --name-only --diff-filter=ACMR "$FORK" "$HEAD_REF" -- tests 2>/dev/null) || _scl=""
  grep -qE '^tests/(mc/)?[^/]+\.sh$' <<< "$_scl" && printf '%s\n' "$SCL_SUITE" >> "$TMP/fast.all"
fi
# <<< scratch-closure tier (BH-4869)
# Skip-suites wins (the rules pack ran it), and a suite this checkout lacks is dropped.
: > "$TMP/fast.ranked"
if [ -s "$TMP/fast.all" ]; then
  _sf=""; [ -n "$SKIP_SUITES" ] && [ -r "$SKIP_SUITES" ] && _sf="$SKIP_SUITES"
  # A fast suite the rules pack ran is reported as such even if unselected.
  awk -v sf="$_sf" -v sk="$TMP/skipped" '
    BEGIN { if (sf != "") while ((getline l < sf) > 0) if (l != "") d[l] = 1
            while ((getline l < sk) > 0) said[l] = 1; close(sk) }
    ($0 in seen) { next }
    { seen[$0] = 1 }
    ($0 in d) { if (!($0 in said)) print >> sk; next }
    { print }' "$TMP/fast.all" \
    | while IFS= read -r _s; do [ -f "$ROOT/$_s" ] && printf '%s\n' "$_s"; done > "$TMP/fast.keep"
  # Selected fast suites keep their rank order and old reasons; the rest of the
  # fast set is appended at rank 0 in list order.
  awk -F'\t' -v ff="$TMP/fast.keep" -v of="$TMP/fast.ranked" -v orest="$TMP/rest0.ranked" '
    FILENAME == ff { f[$0] = ++nf; o[nf] = $0; next }
    ($2 in f) { print $1 "\t" $2 "\tfast-lint (the PR check runs it too); " $3 > of; hit[$2] = 1; next }
    { print > orest }
    END { for (i = 1; i <= nf; i++) if (!(o[i] in hit)) print "0\t" o[i] "\tfast-lint (the PR check runs it too)" > of }
  ' "$TMP/fast.keep" "$TMP/ranked"
  touch "$TMP/rest0.ranked"; mv "$TMP/rest0.ranked" "$TMP/ranked"
fi
F=$(grep -c . < "$TMP/fast.ranked")
cut -f2 "$TMP/fast.ranked" > "$TMP/fast.list"
# N counts the appended fast suites too, so "ran X of N" never reads past N.
N=$(( F + $(grep -c . < "$TMP/ranked") ))
# NIGHTLY-TIER SUITES RUN FIRST, OUTSIDE THE CAP (2026-09-28). catalog/test-tiers.tsv
# takes them out of every merge-queue batch, so for them "left to CI" would be
# false: nothing runs them before main but this gate. Every reached nightly
# suite goes ahead of the ranked list and the cap applies to the rest. Any the
# budget cannot start are named as left to the NIGHTLY run below.
# TEST_IMPACT_GATE_TIERS overrides the tier file (tests).
TIERS_FILE="${TEST_IMPACT_GATE_TIERS:-$ROOT/catalog/test-tiers.tsv}"
awk -F'\t' '!/^[[:space:]]*#/ && $2 == "nightly" { print $1 }' "$TIERS_FILE" 2>/dev/null > "$TMP/nightly.all"
: > "$TMP/nightly.ranked"; : > "$TMP/rest.ranked"
awk -F'\t' -v nf="$TMP/nightly.all" -v on="$TMP/nightly.ranked" -v orest="$TMP/rest.ranked" '
  FILENAME == nf { n[$1] = 1; next }
  ($2 in n) { print $1 "\t" $2 "\tnightly tier (no batch runs it); " $3 > on; next }
  { print > orest }
' "$TMP/nightly.all" "$TMP/ranked"
NN=$(grep -c . < "$TMP/nightly.ranked")
{ cat "$TMP/fast.ranked" "$TMP/nightly.ranked"; head -n "$CAP" "$TMP/rest.ranked"; } > "$TMP/run.ranked"
tail -n +"$((CAP + 1))" "$TMP/rest.ranked" > "$TMP/left.ranked"
cut -f2 "$TMP/nightly.ranked" > "$TMP/nightly.list"
cut -f2 "$TMP/run.ranked" > "$TMP/run.list"
K=$(grep -c . < "$TMP/run.list")
L=$((N - K))
[ -n "$LIST_OUT" ] && cp "$TMP/run.list" "$LIST_OUT"

echo "impact-gate: ${REASON#impact: }"
echo "impact-gate: running up to $K of $N selected suites (cap $CAP$([ "$F" -gt 0 ] && printf ' + %s fast-lint suite(s)' "$F")$([ "$NN" -gt 0 ] && printf ' + %s nightly-tier suite(s)' "$NN")$([ "$((F + NN))" -gt 0 ] && printf ' outside it'), budget ${BUDGET}s); left to CI by the cap: $L"
while IFS= read -r _s; do printf 'plan: %s  run by the rules pack (outside the cap)\n' "$_s"; done < "$TMP/skipped"
awk -F'\t' '{ printf "plan: %-56s %s\n", $2, $3 }' "$TMP/run.ranked"
[ "$L" -gt 0 ] && { echo "impact-gate: left to CI by the cap ($L):"; cut -f2 "$TMP/left.ranked" | sed 's/^/plan:   /'; }

# ── run ─────────────────────────────────────────────────────────────────────
# RUN_LOOP — one suite at a time, in rank order, until the list or the budget
# runs out. It runs as whatever user and in whatever tree the runner gives it,
# and it reports through two things only: a `done` line per finished suite on
# stdout, and a progress file (`<suite> <rc> <seconds>`, or `<suite> budget`
# for one it never started; every reader before BH-1554 used the first two
# fields and is unaffected by the third). It reads the clock to compare with a
# deadline the gate computed — so the budget is the gate's number, not the
# loop's — and to time each suite for the durations hint.
# shellcheck disable=SC2016
RUN_LOOP='cd "$1" || exit 2
list=$2; deadline=$3; prog=$4; one=$5; rc=0
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "$s budget" >> "$prog"; continue; fi
  printf "%s\n" "$s" > "$one"
  t0=$(date +%s)
  bash bin/test-suite-run.sh --only-file "$one" tests tests/mc; r=$?
  echo "impact-gate: done $s rc=$r"
  echo "$s $r $(( $(date +%s) - t0 ))" >> "$prog"
  [ "$r" -eq 0 ] || rc=1
done < "$list"
exit $rc'

# isolated_run — the snapshot-as-nobody runner. Every step that can fail before
# a suite runs is rc 125 with the step named: "could not run" must never be
# confused with "ran and failed", and never with a pass.
isolated_run() {
  local w="$TMP/iso" uid gid
  command -v setpriv >/dev/null 2>&1 || { echo "impact-gate: isolated runner: setpriv is not installed" >&2; return 125; }
  uid=$(id -u nobody 2>/dev/null) && gid=$(id -g nobody 2>/dev/null) \
    || { echo "impact-gate: isolated runner: there is no 'nobody' user" >&2; return 125; }
  # THE PROBE, with the exact flags the run uses (#1541 review C1). setpriv
  # that cannot switch — a caller that is not root, or is already nobody, or a
  # container without CAP_SETUID/SETGID — exits 127 from the RUN below, which
  # used to be scored as red suites. Asked first, it is what it is: could not
  # run.
  setpriv --reuid="$uid" --regid="$gid" --clear-groups true >/dev/null 2>&1 \
    || { echo "impact-gate: isolated runner: setpriv cannot switch to nobody here (not root, or no CAP_SETUID/SETGID)" >&2; return 125; }
  mkdir -p "$w/repo" "$w/home" "$w/tmp" || return 125
  git -C "$ROOT" archive --format=tar "$HEAD_REF" | tar -x -C "$w/repo" \
    || { echo "impact-gate: isolated runner: could not snapshot $HEAD_REF" >&2; return 125; }
  ( cd "$w/repo" && git init -q && git add -A \
      && git -c user.email=gate@harness -c user.name=gate commit -qm snapshot ) >/dev/null 2>&1 \
    || { echo "impact-gate: isolated runner: could not git-init the snapshot" >&2; return 125; }
  cp "$TMP/run.list" "$w/list"; : > "$w/progress"
  # GITLEAKS (BH-2115): a selected suite that looks for gitleaks gets the pinned,
  # checksum-verified one in $w/tools, or the run does not happen at all.
  mkdir -p "$w/tools" || return 125
  if (cd "$w/repo" && grep -qF 'command -v gitleaks' $(cat "$w/list")) </dev/null 2>/dev/null; then
    # shellcheck source=bin/lib/gitleaks-pin.sh
    . "$SELF_DIR/lib/gitleaks-pin.sh" \
      || { echo "impact-gate: isolated runner: cannot load bin/lib/gitleaks-pin.sh" >&2; return 125; }
    local gl_err
    if ! gl_err=$(gitleaks_pin_ensure "$w/tools" 2>&1); then
      echo "impact-gate: isolated runner: gitleaks $GITLEAKS_PIN_VERSION could not be installed (${gl_err:-no reason given}) — the gitleaks gate fails closed" >&2
      return 125
    fi
    echo "impact-gate: gitleaks $GITLEAKS_PIN_VERSION ready, checksum-verified, for the suites that need it"
  fi
  # mktemp -d is 0700 and nobody has to reach the tree under it.
  chmod 711 "$TMP" && chown -R "$uid:$gid" "$w" \
    || { echo "impact-gate: isolated runner: could not hand the snapshot to nobody" >&2; return 125; }
  # A clean environment: nothing of the builder's (tokens, HARNESS, the live
  # env dir) reaches a suite. The snapshot is nobody's own, so git trusts it.
  setpriv --reuid="$uid" --regid="$gid" --clear-groups \
    env -i PATH="$w/tools:$PATH" HOME="$w/home" TMPDIR="$w/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 GITLEAKS_REQUIRED=1 \
    bash -c "$RUN_LOOP" _ "$w/repo" "$w/list" "$DEADLINE" "$w/progress" "$w/one"
  local r=$?
  cp "$w/progress" "$TMP/progress" 2>/dev/null
  return "$r"
}

if [ "$RUNNER" = auto ]; then
  if [ "$(id -u)" -eq 0 ] && [ -d "${HARNESS_ROOT_OVERRIDE:-/root/harness}" ]; then RUNNER=isolated
  else RUNNER=local; fi
fi

# ── SUITE REUSE (BH-5354.1): drop what the ledger saw pass on these inputs ───
# Fail-safe both ways: the helper turns itself off on any trouble, and an answer
# that is not a partition of what it was handed is treated as off here.
SR_ON=0; SR_R=0; SR_S=0
: > "$TMP/sr.reused"; : > "$TMP/sr.fp"
case "$RUNNER" in local|isolated)
  if [ -x "$ROOT/bin/suite-reuse.sh" ]; then
    SR_ON=1
    if [ -s "$TMP/fast.list" ]; then grep -vxF -f "$TMP/fast.list" "$TMP/run.list" > "$TMP/sr.in" || true
    else cp "$TMP/run.list" "$TMP/sr.in"; fi
    SR_REPO="${SUITE_REUSE_REPO:-}"
    if [ -z "$SR_REPO" ]; then
      SR_REPO=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -e 's#\.git/*$##' -e 's#/*$##' -e 's#:#/#g' \
        | awk -F/ 'NF >= 2 && $(NF - 1) != "" && $NF != "" { print $(NF - 1) "/" $NF }')
    fi
    SR_KEY="${SUITE_REUSE_RUN_KEY:-builder-$(hostname 2>/dev/null || echo box)-$(date +%s)-$$}"
    if [ -z "$SR_REPO" ]; then
      echo "suite-reuse: off (no repo)"
    else
      rm -f "$TMP/sr.run"
      ( cd "$ROOT" && bin/suite-reuse.sh plan --class builder --repo "$SR_REPO" --ctx "$RUNNER" --suites "$TMP/sr.in" \
          --run "$TMP/sr.run" --reused "$TMP/sr.reused" --fingerprints "$TMP/sr.fp" --rev "$HEAD_REF" ) > "$TMP/sr.plan.out"
      grep -v '^suite-reuse: reused ' "$TMP/sr.plan.out"
      if ! [ -r "$TMP/sr.run" ] || ! [ -r "$TMP/sr.reused" ] \
         || [ "$({ cat "$TMP/sr.run"; cut -f1 "$TMP/sr.reused"; } | grep -v '^$' | LC_ALL=C sort)" \
              != "$(grep -v '^$' "$TMP/sr.in" | LC_ALL=C sort)" ]; then
        echo "suite-reuse: off (helper answer did not match its input)"
        : > "$TMP/sr.reused"; : > "$TMP/sr.fp"
      fi
    fi
    if [ -s "$TMP/sr.reused" ]; then
      grep -vxF -f <(cut -f1 "$TMP/sr.reused") "$TMP/run.list" > "$TMP/run.list.kept" || true
      mv "$TMP/run.list.kept" "$TMP/run.list"
      awk -F'\t' '{ print "impact-gate: reused " $1 " from " $2 " (" $3 "s)" }' "$TMP/sr.reused"
      SR_R=$(grep -c . < "$TMP/sr.reused")
      SR_S=$(awk -F'\t' '$3 ~ /^[0-9]+$/ { s += $3 } END { print s + 0 }' "$TMP/sr.reused")
    fi
  fi ;;
esac
# The budget is for suites: it starts after the ledger lookup, not before it.
DEADLINE=$(( $(date +%s) + BUDGET ))
RC=0
: > "$TMP/progress"
case "$RUNNER" in
  plan)   echo "impact-gate: NOT RUN (--runner plan) — this is a list, not a gate" ;;
  local)  bash -c "$RUN_LOOP" _ "$ROOT" "$TMP/run.list" "$DEADLINE" "$TMP/progress" "$TMP/one"; RC=$? ;;
  isolated) isolated_run; RC=$?
          # The loop's own 2 (it could not cd into its tree) and 125 keep
          # their meaning; anything else nonzero is a red suite.
          case "$RC" in 0|2|125) ;; *) RC=1 ;; esac ;;
  remote) _suites=()
          while IFS= read -r _s; do [ -n "$_s" ] && _suites+=("$_s"); done < "$TMP/run.list"
          # remote-gate runs in parallel on the test host; the budget is its
          # own REMOTE_GATE_SUITE_TIMEOUT there, and every listed suite runs.
          ( cd "$ROOT" && bin/remote-gate.sh . "${_suites[@]}" ); RC=$?
          while IFS= read -r _s; do [ -n "$_s" ] && echo "$_s remote" >> "$TMP/progress"; done < "$TMP/run.list"
          # remote-gate exits with the COUNT of red suites; 125 is its own
          # "nothing ran", kept as the number it is.
          [ "$RC" -gt 0 ] && [ "$RC" -lt 125 ] && RC=1 ;;
esac

# --failed: the suites that ran and went red, by name.
if [ -n "$FAILED_OUT" ]; then
  awk '$2 != "budget" && $2 != "remote" && $2 ~ /^[0-9]+$/ && $2 != 0 { print $1 }' "$TMP/progress" > "$FAILED_OUT" 2>/dev/null \
    || echo "impact-gate: could not write the failed list to $FAILED_OUT" >&2
fi
# What the budget left unstarted is left to CI, by name, exactly like the cap's.
awk '$2 == "budget" { print $1 }' "$TMP/progress" > "$TMP/budget.all"
# A nightly-tier suite the budget did not start is NOT left to CI: no batch
# runs it. It is split out and named as left to the nightly run.
grep -vxF -f "$TMP/nightly.list" "$TMP/budget.all" > "$TMP/budget.left" 2>/dev/null || true
[ -s "$TMP/nightly.list" ] || cp "$TMP/budget.all" "$TMP/budget.left"
grep -xF -f "$TMP/nightly.list" "$TMP/budget.all" > "$TMP/budget.nightly" 2>/dev/null || : > "$TMP/budget.nightly"
[ -s "$TMP/nightly.list" ] || : > "$TMP/budget.nightly"
B=$(grep -c . < "$TMP/budget.left")
BN=$(grep -c . < "$TMP/budget.nightly")
RAN=$(awk '$2 != "budget"' "$TMP/progress" | grep -c .)

# ── record what each suite COST, for the next run's ordering (BH-1554) ──────
# One row per suite, newest wins, written atomically. A red suite's time counts
# too (a slow red suite is still slow). Never fatal: a state dir this box cannot
# write is one warning and today's alphabetical order next time.
case "$RUNNER" in
  local|isolated)
    if awk 'NF >= 3 && $2 != "budget" && $3 ~ /^[0-9]+$/ { print $1 "\t" $3 }' "$TMP/progress" > "$TMP/dur.new" \
       && [ -s "$TMP/dur.new" ]; then
      mkdir -p "$(dirname "$DURATIONS_FILE")" 2>/dev/null
      { [ -r "$DURATIONS_FILE" ] && cat "$DURATIONS_FILE"; :; } > "$TMP/dur.old" 2>/dev/null
      if { awk -F'\t' 'NR == FNR { new[$1] = 1; print; next } !($1 in new) && NF >= 2 && $2 ~ /^[0-9]+$/' \
             "$TMP/dur.new" "$TMP/dur.old" | LC_ALL=C sort -t"$(printf '\t')" -k1,1 > "$DURATIONS_FILE.$$.tmp" \
           && mv "$DURATIONS_FILE.$$.tmp" "$DURATIONS_FILE"; }; then :
      else
        rm -f "$DURATIONS_FILE.$$.tmp" 2>/dev/null
        echo "impact-gate: could not record durations in $DURATIONS_FILE — the next run orders by name" >&2
      fi
    fi ;;
esac
[ "$B" -gt 0 ] && { echo "impact-gate: the ${BUDGET}s budget ran out — $B suite(s) not started, left to CI:"; sed 's/^/  /' "$TMP/budget.left"; }
[ "$BN" -gt 0 ] && { echo "impact-gate: the ${BUDGET}s budget ran out before $BN NIGHTLY-tier suite(s) — no batch runs them, so they reach main untested until the nightly run:"; sed 's/^/  /' "$TMP/budget.nightly"; }
case "$RC" in
  0)   VERDICT="passed" ;;
  125) VERDICT="COULD NOT RUN (runner $RUNNER, rc 125)" ;;
  *)   VERDICT="FAILED (rc $RC)" ;;
esac
[ "$RUNNER" = plan ] && { VERDICT="NOT RUN (plan only)"; RAN=0; }
NTAIL=""; [ "$BN" -gt 0 ] && NTAIL="; left to the nightly run only: $BN"
echo "impact-gate: ran $RAN of $N selected suites via $RUNNER: $VERDICT (left to CI: $L by the cap, $B by the budget$NTAIL)"
[ "$SR_ON" = 1 ] && echo "impact-gate: reused $SR_R of $N selected suites from the suite ledger (~${SR_S}s not re-run)"

# ── the PR body's gate table, generated from THIS run ───────────────────────
if [ -n "$TABLE_OUT" ]; then
  {
    echo "**Gate: \`bin/test-impact-gate.sh --base $BASE_REF\`: ran $RAN of $N selected suites (cap $CAP, budget ${BUDGET}s, runner $RUNNER): $VERDICT.**"
    echo "${REASON#impact: }. Left to CI: $L by the cap, $B by the budget.$([ "$BN" -gt 0 ] && printf ' Left to the nightly run only (nightly tier, no batch runs them): %s.' "$BN")$([ "$SR_R" -gt 0 ] && printf ' Reused from the suite ledger (not re-run here): %s.' "$SR_R")"
    echo
    echo "| suite | why |"
    echo "|---|---|"
    # N1 (BH-1554): a suite the budget never STARTED is marked, so the run
    # table never reads as if every listed suite had run.
    # FILENAME, not NR == FNR: budget.all is EMPTY on a run that finished
    # inside its budget, and with an empty first file NR == FNR is still true
    # for the first row of the second one — which ate the table's first suite.
    awk -F'\t' -v lf="$TMP/budget.all" -v ff="$TMP/fast.list" -v rf="$TMP/sr.reused" '
      FILENAME == lf { left[$1] = 1; next }
      FILENAME == ff { fast[$1] = 1; next }
      FILENAME == rf { ru[$1] = $2; next }
      { tag = (($2 in fast) ? "(fast) " : "") (($2 in left) ? "(not started: budget) " : "") (($2 in ru) ? "(reused " ru[$2] ") " : "")
        printf "| `%s` | %s%s |\n", $2, tag, $3 }' "$TMP/budget.all" "$TMP/fast.list" "$TMP/sr.reused" "$TMP/run.ranked"
    if [ "$((L + B))" -gt 0 ]; then
      echo; echo "<details><summary>Left to CI ($((L + B)))</summary>"; echo
      { cut -f2 "$TMP/left.ranked"; cat "$TMP/budget.left"; } | sed 's/^/- `/; s/$/`/'
      echo; echo "</details>"
    fi
    if [ "$BN" -gt 0 ]; then
      echo; echo "<details><summary>Left to the NIGHTLY run only ($BN): no batch runs these</summary>"; echo
      sed 's/^/- `/; s/$/`/' "$TMP/budget.nightly"
      echo; echo "</details>"
    fi
  } > "$TABLE_OUT"
fi

# ── SUITE REUSE: record what ran, after the verdict is out ──────────────────
# Last, so a slow ledger cannot cost the lines above to a stage timeout. Budget
# and remote rows drop out on the rc test; nothing ran on 125.
if [ "$SR_ON" = 1 ] && [ -s "$TMP/sr.fp" ] && [ "$RC" != 125 ]; then
  awk 'NF >= 3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { print $1 "\t" ($2 == 0 ? "ok" : "fail") "\t" $3 }' \
    "$TMP/progress" > "$TMP/sr.results"
  ( cd "$ROOT" && bin/suite-reuse.sh record --repo "$SR_REPO" --ctx "$RUNNER" --run-key "$SR_KEY" \
      --fingerprints "$TMP/sr.fp" --results "$TMP/sr.results" --reused "$TMP/sr.reused" )
fi
exit "$RC"
