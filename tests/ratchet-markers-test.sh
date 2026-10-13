#!/bin/bash
# tests/ratchet-markers-test.sh — BH-1177: the two marker ratchets hold the same
# line the counted ones held, and two conversions in flight never collide.
#
# WHAT CHANGED AND WHY. tests/gh-app-ratchet-test.sh and
# tests/rb-modules-source-test.sh used to hold their line with SHARED state: an
# allow-list whose length was asserted to be exactly six, four baseline part
# files, and one pinned list of three absolute suite paths. Every PR that
# converted a script, allow-listed one, or added a raw reader had to re-type a
# line that belonged to no ticket — those two suites and that allow-list were
# touched by 13 of the last 200 merges and sat in six of one day's conflicts.
# The conflicts were never about the feature being built.
#
# Now each file declares its own status in its own header — a `gh-identity` line
# in bin/, a reader line in tests/ — and the "only shrinks" half is a DIRECTORY of
# one-file entries. This suite is the proof that the swap kept the guard:
#
#   block 1  two branches converting two different scripts merge CLEAN, both
#            conversions survive the merge, and both ratchets are green on it
#   block 2  …and the shape it replaced would NOT have: the same two deletions
#            against one sorted list conflict. That measurement is why the
#            registry is a directory, and it is pinned here rather than
#            remembered, because "a list is fine" is exactly the change someone
#            will propose again.
#   block 3  every way the guard must still fire: an unmarked raw call, a
#            marker with no registry entry, an entry whose file converted, an
#            app-token marker over a file that arms nothing, a raw-by-design
#            marker with no BY-DESIGN entry, an entry naming a script that is
#            not in bin/ (in either registry), an entry with no note, a raw-pat
#            marker whose ticket has shipped in both spellings of the key, a NEW
#            raw reader of the driver, and a reader marker with no entry.
#
# THE SELF-BLESS CASE IS WHY (g) AND (h) EXIST. The first cut of BH-1177 let a
# script exempt itself: `# gh-identity: raw-by-design — because I said so` over
# a raw `gh api` call raised no finding at all and moved the summary from 6
# raw-by-design to 7 in silence. The shape it replaced had pinned its allow-list
# at exactly six entries SO THAT the set grew only by a reviewed decision, and
# that pin had been dropped rather than carried over. Case (g) is that exact
# script, and it is red now.
#
# THE FIXTURE IS THE REAL REPO, sliced. bin/ whole (the gh ratchet RUNS the
# merge lib and the queue out of it, and the rb suite EXECUTES the driver), plus
# the two ratchet suites, all three registries, tests/lib/ and EVERY registered
# raw reader — the scan needs their text to find their markers. Nothing
# here is a hand-written stand-in for a ratchet: every assertion below runs the
# production suite, unmodified, against a tree on disk.
#
# Run from anywhere: tests/ratchet-markers-test.sh   (exit 0 = all pass)
# No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GH_SUITE=tests/gh-app-ratchet-test.sh
RB_SUITE=tests/rb-modules-source-test.sh

# ── the slice ────────────────────────────────────────────────────────────────
SRC="$T/src"
mkdir -p "$SRC/tests"
cp -a "$DIR/bin" "$SRC/bin"
cp -a "$DIR/tests/lib" "$SRC/tests/lib"
cp -a "$DIR/tests/gh-app-ratchet-baseline" "$SRC/tests/gh-app-ratchet-baseline"
cp -a "$DIR/tests/gh-app-ratchet-by-design" "$SRC/tests/gh-app-ratchet-by-design"
cp -a "$DIR/tests/rb-raw-readers-baseline" "$SRC/tests/rb-raw-readers-baseline"
# The raw readers are READ OFF THE REGISTRY, never re-typed here: registering one
# is meant to touch that suite and its own entry file and nothing else (BH-1177),
# and a literal list in this fixture would be exactly the shared cell that rule
# removed — the fourth reader found it, as a registry entry naming a suite this
# slice had not copied.
for S in gh-app-ratchet-test.sh rb-modules-source-test.sh \
         $(cd "$DIR/tests/rb-raw-readers-baseline" 2>/dev/null \
           && ls ./*.txt 2>/dev/null | sed 's|^\./||; s|\.txt$||'); do
  [ -r "$DIR/tests/$S" ] && cp "$DIR/tests/$S" "$SRC/tests/$S"
done
# ...and the suite behind every registry entry (BH-1319). The whole
# rb-raw-readers-baseline/ directory is copied above, and rb-modules-source-test.sh
# case (f) fails an entry whose suite is not in tests/ — so a slice that takes the
# registry but hand-picks its suites turns THIS fixture red the moment anyone
# registers a fourth raw reader, for a reason that has nothing to do with the
# ratchet. Derived from the registry, it stays true on its own.
for E in "$DIR"/tests/rb-raw-readers-baseline/*.txt; do
  [ -e "$E" ] || continue
  S=$(basename "$E" .txt)
  [ -r "$DIR/tests/$S" ] && cp "$DIR/tests/$S" "$SRC/tests/$S"
done
# TEST-CHANGE BH-1651: one registered raw lane that exists only in the slice.
# Block 1 converts the registry's first two entries and every case in block 3
# runs on that merged tree, so the slice has to hold at least three; with two
# left on main the merge emptied the registry, the gh ratchet went strict, and
# every block-3 case failed on that instead of on its own finding. The name sorts
# after every real entry, so block 1 still converts real ones.
printf '%s\n' '#!/bin/bash' \
  '# gh-identity: raw-pat (BH-425) — a fixture lane: the raw one the conversions leave behind' \
  'gh issue list -R x/y' > "$SRC/bin/zz-ratchet-fixture-lane.sh"
printf '%s\n' 'Fixture only: the raw lane block 1 leaves registered.' \
  > "$SRC/tests/gh-app-ratchet-baseline/zz-ratchet-fixture-lane.sh.txt"

# HARNESS_TEST_SANDBOX is forwarded, never invented: the child suite sources the
# same tests/lib/scratch.sh this one did, so it must see the same answer to the
# "am I allowed to run as root next to a live harness" question.
run_suite() { # run_suite <tree> <suite path> -> prints rc, output in $T/out
  local rc
  env ${HARNESS_TEST_SANDBOX:+HARNESS_TEST_SANDBOX=1} \
      bash "$1/$2" > "$T/out" 2>&1
  rc=$?
  printf '%s' "$rc"
}

# The slice is green before anything is done to it. Without this every assertion
# below could be passing for a reason that has nothing to do with the change.
RC=$(run_suite "$SRC" "$GH_SUITE")
[ "$RC" = 0 ] && ok || bad "fixture: the gh ratchet must be green on the untouched slice (rc $RC): $(tail -3 "$T/out")"
RC=$(run_suite "$SRC" "$RB_SUITE")
[ "$RC" = 0 ] && ok || bad "fixture: the rb ratchet must be green on the untouched slice (rc $RC): $(tail -3 "$T/out")"

# convert <tree> <path under bin/> — exactly what a conversion slice does, in
# the three places it does it: arm the script, flip its own header marker, drop
# its own registry file. Nothing else in the tree is touched, which is the whole
# claim being tested.
convert() {
  local tree="$1" rel="$2" f="$1/bin/$2"
  python3 - "$f" <<'PY'
import re, sys
p = sys.argv[1]
lines = open(p).read().split("\n")
for i, l in enumerate(lines[:40]):
    if re.match(r"^[ \t]*#[ \t]*gh-identity:", l):
        lines[i] = "# gh-identity: app-token"
        lines.insert(i + 1, '# shellcheck source=/dev/null')
        lines.insert(i + 2, '. "$HARNESS/bin/lib/gh-app-auth.sh" 2>/dev/null || true')
        break
else:
    sys.exit("no gh-identity marker in %s" % p)
open(p, "w").write("\n".join(lines))
PY
  rm -f "$tree/tests/gh-app-ratchet-baseline/$rel.txt"
}

# ══ 1. two conversions in flight merge clean, and the guard survives ═══════
# The two scripts to convert are the registry's own first two entries in sorted
# order, never names typed in here: they are then ADJACENT lines of the sorted
# list block 2 builds (which is the case that conflicts), and a conversion slice
# landing on main cannot turn this suite red by retiring a name it hardcoded.
ENTRIES=$(cd "$SRC/tests/gh-app-ratchet-baseline" && find . -name '*.txt' \
          | sed 's|^\./||; s|\.txt$||' | sort)
N_ENTRIES=$(grep -c . <<<"$ENTRIES")
A_FILE=$(sed -n 1p <<<"$ENTRIES")
B_FILE=$(sed -n 2p <<<"$ENTRIES")
[ "$N_ENTRIES" -ge 2 ] && ok \
  || bad "the registry holds $N_ENTRIES entries; this suite needs two still-raw scripts to convert on two branches"
if [ "$N_ENTRIES" -lt 2 ]; then
  echo "ratchet-markers-test: fewer than two registry entries — skipping the merge blocks"
elif ! command -v git >/dev/null 2>&1; then
  echo "ratchet-markers-test: git missing — skipping the merge blocks"
else
  R="$T/repo"; cp -a "$SRC" "$R"
  G() { git -C "$R" -c user.email=t@example.invalid -c user.name=t "$@"; }
  G init -q . >/dev/null 2>&1
  G symbolic-ref HEAD refs/heads/base
  G add -A >/dev/null 2>&1
  G commit -qm base >/dev/null 2>&1
  [ -n "$(G rev-parse --verify -q HEAD)" ] && ok || bad "block 1: the fixture repo has no base commit"

  G checkout -q -b conv-a
  convert "$R" "$A_FILE"
  G add -A >/dev/null 2>&1; G commit -qm "convert $A_FILE" >/dev/null 2>&1
  G checkout -q base
  G checkout -q -b conv-b
  convert "$R" "$B_FILE"
  G add -A >/dev/null 2>&1; G commit -qm "convert $B_FILE" >/dev/null 2>&1

  G checkout -q conv-a
  MOUT=$(G merge --no-edit conv-b 2>&1); MRC=$?
  [ "$MRC" = 0 ] && ok || bad "block 1: two conversions of two different scripts must merge clean (rc $MRC): $MOUT"
  grep -qi 'CONFLICT' <<<"$MOUT" && bad "block 1: the merge reported a conflict: $MOUT" || ok
  [ -z "$(G ls-files -u)" ] && ok || bad "block 1: the merge left unmerged paths: $(G ls-files -u)"

  # Both conversions survived it. A merge that silently kept one of the two
  # would be green on `git merge` and wrong in exactly the way that matters.
  for F in "$A_FILE" "$B_FILE"; do
    grep -q '^# gh-identity: app-token$' "$R/bin/$F" \
      && ok || bad "block 1: bin/$F lost its app-token marker in the merge"
    [ -e "$R/tests/gh-app-ratchet-baseline/$F.txt" ] \
      && bad "block 1: $F's registry entry came back in the merge" || ok
  done

  # …and the ratchets read the merged tree as a tree with two fewer raw lanes.
  RC=$(run_suite "$R" "$GH_SUITE")
  [ "$RC" = 0 ] && ok || bad "block 1: the gh ratchet must be green on the merge (rc $RC): $(tail -3 "$T/out")"
  grep -q "$((N_ENTRIES - 2)) raw files still in the registry" "$T/out" \
    && ok || bad "block 1: the merged tree must report two fewer registered raw files than $N_ENTRIES: $(tail -1 "$T/out")"
  RC=$(run_suite "$R" "$RB_SUITE")
  [ "$RC" = 0 ] && ok || bad "block 1: the rb ratchet must be green on the merge (rc $RC): $(tail -3 "$T/out")"
  MERGED="$R"

  # ══ 2. …and the shape this replaced would not have ══════════════════════
  # The same two entries, as two lines of one sorted list: two branches each
  # deleting their own line, and git cannot take both. This is the measurement
  # the directory exists for, kept executable so the next "a list would be
  # simpler" proposal meets it rather than the memory of it.
  L="$T/list"; mkdir -p "$L"
  LG() { git -C "$L" -c user.email=t@example.invalid -c user.name=t "$@"; }
  LG init -q . >/dev/null 2>&1
  LG symbolic-ref HEAD refs/heads/base
  ( cd "$SRC/tests/gh-app-ratchet-baseline" && find . -name '*.txt' | sed 's|^\./||; s|\.txt$||' | sort ) > "$L/baseline.txt"
  [ "$(grep -c . "$L/baseline.txt")" -ge 2 ] && ok || bad "block 2: need at least two registry entries to build the comparison"
  LG add -A >/dev/null 2>&1; LG commit -qm base >/dev/null 2>&1
  LG checkout -q -b la
  grep -vxF "$A_FILE" "$L/baseline.txt" > "$L/t" && mv "$L/t" "$L/baseline.txt"
  LG commit -qam la >/dev/null 2>&1
  LG checkout -q base; LG checkout -q -b lb
  grep -vxF "$B_FILE" "$L/baseline.txt" > "$L/t" && mv "$L/t" "$L/baseline.txt"
  LG commit -qam lb >/dev/null 2>&1
  LG checkout -q la
  LOUT=$(LG merge --no-edit lb 2>&1); LRC=$?
  if [ "$LRC" != 0 ] && grep -qi 'CONFLICT' <<<"$LOUT"; then
    ok
  else
    bad "block 2: the one-sorted-list shape merged cleanly (rc $LRC) — if git has learned to merge adjacent deletions, the registry can go back to being a list, and this suite's header should say so: $LOUT"
  fi
  LG merge --abort >/dev/null 2>&1
fi

# ══ 3. every way the guard must still fire ════════════════════════════════
# Each case starts from a pristine copy of the tree block 1 proved green, so a
# red here is the case and nothing else.
case_tree() { rm -rf "$T/c"; cp -a "${MERGED:-$SRC}" "$T/c"; rm -rf "$T/c/.git"; printf '%s' "$T/c"; }
red_gh() { # red_gh <what> <grep for the message>
  local rc; rc=$(run_suite "$T/c" "$GH_SUITE")
  if [ "$rc" = 0 ]; then
    bad "$1: the gh ratchet stayed GREEN — the guard is off"
  else
    ok
    grep -q "$2" "$T/out" && ok || bad "$1: the failure must name it ($2); got: $(grep -m2 '^FAIL\|^  bin' "$T/out")"
  fi
}
red_rb() {
  local rc; rc=$(run_suite "$T/c" "$RB_SUITE")
  if [ "$rc" = 0 ]; then
    bad "$1: the rb ratchet stayed GREEN — the guard is off"
  else
    ok
    grep -q "$2" "$T/out" && ok || bad "$1: the failure must name it ($2); got: $(grep -m2 '^FAIL' "$T/out")"
  fi
}

# (a) a raw gh call in a file that declares nothing
C=$(case_tree)
printf '#!/bin/bash\n# bin/newlane.sh — a lane somebody just wrote\ngh pr list -R x/y\n' > "$C/bin/newlane.sh"
red_gh "unmarked raw call" 'bin/newlane.sh:3 raw gh call'

# (b) …and declaring it raw-pat is not enough on its own: the registry entry is
# the reviewed decision, exactly as the pinned count used to be.
C=$(case_tree)
printf '#!/bin/bash\n# gh-identity: raw-pat (BH-9999) — a lane that wrote its own permission slip\ngh pr list -R x/y\n' > "$C/bin/newlane.sh"
red_gh "raw-pat with no registry entry" 'newlane.sh is marked raw-pat with no registry entry'

# (c) an entry whose file converted: the registry may not count a lane that is
# not there (the "only shrinks" half, read the other way round).
C=$(case_tree)
SOME=$(find "$C/tests/gh-app-ratchet-baseline" -name '*.txt' | sort | head -1)
cp "$SOME" "$C/tests/gh-app-ratchet-baseline/merge-queue.sh.txt"
red_gh "entry for a converted file" "registry entry 'merge-queue.sh' has no raw-pat marker"

# (d) a marker that claims a conversion nobody made. This is the case the old
# ratchet could not have: a file that SAYS app-token while arming nothing.
C=$(case_tree)
# Convert it first if block 1 did not (no git on the box): the case is a
# CONVERTED file whose arming went away, so it has to be converted either way.
convert "$C" "$A_FILE" >/dev/null 2>&1
python3 - "$C/bin/$A_FILE" <<'PY'
import sys
p = sys.argv[1]
out = [l for l in open(p).read().split("\n") if "gh-app-auth.sh" not in l]
open(p, "w").write("\n".join(out))
PY
red_gh "app-token over an unarmed file" "declares 'gh-identity: app-token' but arms nothing"

# (g) a raw-by-design marker with no by-design entry: a script exempting itself.
# This is the case the review of the first cut found green.
C=$(case_tree)
printf '#!/bin/bash\n# gh-identity: raw-by-design — because I said so\ngh api repos/x/y\n' > "$C/bin/selfblessed.sh"
red_gh "raw-by-design with no by-design entry" 'selfblessed.sh declares raw-by-design with no entry'

# (h) …and the by-design registry cannot hold an entry nobody owns either.
C=$(case_tree)
SOMEBD=$(find "$C/tests/gh-app-ratchet-by-design" -name '*.txt' | sort | head -1)
cp "$SOMEBD" "$C/tests/gh-app-ratchet-by-design/merge-queue.sh.txt"
red_gh "by-design entry for an armed file" "by-design registry entry 'merge-queue.sh'"

# (j) an entry naming a script that is not in bin/ — in EITHER registry.
# This is the two-step self-bless: land the entry on its own, land the script
# later. It is also the case that proved a refactor had gone wrong: when block
# 2's loader was called as `N=$(load_registry …)` its bad() ran in a command
# substitution's subshell, so the finding was thrown away, its text was stapled
# into the count, and the suite exited 0 with the FAIL printed INSIDE its own
# summary line. A guard whose finding lands in a variable is not a guard.
for R in gh-app-ratchet-baseline gh-app-ratchet-by-design; do
  C=$(case_tree)
  SOMER=$(find "$C/tests/$R" -name '*.txt' | sort | head -1)
  cp "$SOMER" "$C/tests/$R/ghost.sh.txt"
  red_gh "ghost entry in $R" "entry 'ghost.sh' names a file that is not in bin/"
done

# (k) …and an entry with nothing in it, which is a pinned count in disguise.
C=$(case_tree)
SOMER=$(find "$C/tests/gh-app-ratchet-by-design" -name '*.txt' | sort | head -1)
: > "$SOMER"
red_gh "entry with no note" 'carries no note'

# Neither of those may be reported by landing in the summary line: a finding
# belongs on its own FAIL line. This is the shape of the regression above, so it
# is pinned directly rather than inferred from the rc.
grep -q '^gh-app-ratchet-test:.*FAIL' "$T/out" \
  && bad "a finding was printed INSIDE the summary line — bad() ran in a subshell again" || ok

# (i) the raw-pat OWNER check: a marker whose ticket has shipped.
# It needs the two things it fails open without — a gh on PATH and an origin
# remote — so the case supplies both: a stub gh that answers `closed`, and a
# tree made into a repo with a remote. Without this case the block could never
# run anywhere (no gh in the test image) and would be a guard nobody has watched
# fire, which is the thing this whole suite exists to refuse.
mkdir -p "$T/stub"
# The stub ANSWERS ONLY A WELL-FORMED ISSUE PATH. A stub that echoes its state
# whatever it is handed would bless the bug this case exists for: the suite
# strips the number out of the ticket key, and a key it failed to strip (`#425`
# left whole) must reach the stub as a path it refuses, not as a question it
# answers. That is the difference between pinning the strip and pinning nothing.
gh_stub() { # gh_stub <open|closed>
  printf '%s\n' '#!/bin/bash' \
    'for a; do' \
    '  case "$a" in' \
    '    repos/*/issues/*)' \
    '      n=${a##*/}' \
    '      case "$n" in ""|*[!0-9]*) exit 1 ;; esac' \
    "      echo $1; exit 0 ;;" \
    '  esac' \
    'done' \
    'exit 1' > "$T/stub/gh"
  chmod +x "$T/stub/gh"
}
owner_tree() { # owner_tree -> a case tree that is a checkout with an origin
  local c; c=$(case_tree)
  git -C "$c" init -q . >/dev/null 2>&1
  git -C "$c" remote add origin https://github.com/example-org/cromford.git >/dev/null 2>&1
  printf '%s' "$c"
}
if command -v git >/dev/null 2>&1; then
  C=$(owner_tree); gh_stub closed
  RC=$(PATH="$T/stub:$PATH" run_suite "$C" "$GH_SUITE")
  if [ "$RC" = 0 ]; then
    bad "owner check: a raw-pat marker citing a CLOSED ticket left the ratchet green"
  else
    ok
    grep -q 'is CLOSED — a shipped ticket is not an owner' "$T/out" \
      && ok || bad "owner check: the failure must say the ticket shipped; got: $(grep -m1 '^FAIL' "$T/out")"
  fi
  # …and it is not a check that simply always fails: the same tree, same stub
  # binary, an OPEN answer, and the suite is green again.
  C=$(owner_tree); gh_stub open
  RC=$(PATH="$T/stub:$PATH" run_suite "$C" "$GH_SUITE")
  [ "$RC" = 0 ] && ok \
    || bad "owner check: an OPEN ticket must leave the ratchet green (rc $RC): $(grep -m2 '^FAIL' "$T/out")"
  # The other ticket spelling. The parser accepts `raw-pat (#425)` as well as
  # `raw-pat (BH-425)`, and the number has to be stripped out of BOTH or that
  # marker is silently never owner-checked — it was not, at first.
  #
  # EVERY marker is re-spelled, not one: leave a single `BH-` marker behind and
  # the suite goes red on THAT one, the case passes, and the `#NNN` half is
  # never exercised. (Which is what the first draft of this case did.) The
  # re-spell is then asserted, because a case whose setup silently did nothing
  # is the same vacuous green.
  C=$(owner_tree); gh_stub closed
  python3 - "$C" <<'PY'
import os, re, sys
root = os.path.join(sys.argv[1], "bin")
hit = 0
for d, _, fs in os.walk(root):
    for f in sorted(fs):
        if not f.endswith(".sh"):
            continue
        p = os.path.join(d, f)
        t = open(p, errors="ignore").read()
        n = re.sub(r"(# gh-identity: raw-pat )\(BH-([0-9]+)\)", r"\1(#\2)", t)
        if n != t:
            open(p, "w").write(n)
            hit += 1
sys.exit(0 if hit else "no raw-pat marker to re-spell")
PY
  RESPELL=$?
  [ "$RESPELL" = 0 ] && ok || bad "owner check: could not re-spell any raw-pat marker to the #NNN form — the case tested nothing"
  if grep -rq '# gh-identity: raw-pat (BH-' "$C/bin"; then
    bad "owner check: a BH- spelling survived the re-spell, so the #NNN half would pass on the old one"
  else
    ok
  fi
  RC=$(PATH="$T/stub:$PATH" run_suite "$C" "$GH_SUITE")
  if [ "$RC" = 0 ]; then
    bad "owner check: a raw-pat (#NNN) marker citing a CLOSED ticket left the ratchet green — the #NNN spelling is not being owner-checked"
  else
    ok
    grep -q 'is CLOSED — a shipped ticket is not an owner' "$T/out" \
      && ok || bad "owner check: the #NNN spelling must fail the same way; got: $(grep -m1 '^FAIL' "$T/out")"
  fi

  # A gh that cannot answer is a SKIP, never a red: this block is advisory.
  C=$(owner_tree); printf '#!/bin/bash\nexit 3\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
  RC=$(PATH="$T/stub:$PATH" run_suite "$C" "$GH_SUITE")
  if [ "$RC" = 0 ]; then
    ok
    grep -q 'could not read the state of' "$T/out" \
      && ok || bad "owner check: an unreadable answer must print the skip line; got: $(tail -2 "$T/out")"
  else
    bad "owner check: a gh that cannot answer must not turn the ratchet red (rc $RC): $(grep -m1 '^FAIL' "$T/out")"
  fi
  rm -f "$T/stub/gh"
fi

# (e) a NEW raw reader of the driver — the property the pinned list of three
# held, proven by making it fire rather than by trusting the rewrite.
#
# The reference is assembled at run time on purpose: written out whole, this
# suite would itself become a raw reader of the driver and land inside the very
# ratchet it is testing.
RAW_REF='"$'"DIR/bin/run-build.sh\""
C=$(case_tree)
{ printf '#!/bin/bash\n# tests/fourth-reader-test.sh — a suite that reads the driver as text\n'
  printf 'DIR=$(cd "$(dirname "$0")/.." && pwd)\n'
  printf 'awk "NR==1" %s\n' "$RAW_REF"
} > "$C/tests/fourth-reader-test.sh"
red_rb "new raw reader" 'tests/fourth-reader-test.sh reads bin/run-build.sh as raw text'

# (f) …and, again, declaring it is not enough without the entry.
python3 - "$C/tests/fourth-reader-test.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
lines.insert(1, "# reads-run-build: raw — because this suite says so")
open(p, "w").write("\n".join(lines))
PY
red_rb "reader marker with no registry entry" "declares '# reads-run-build: raw' with no registry entry"

echo "ratchet-markers-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
