#!/bin/bash
# tests/fleet-projects-not-hardcoded-test.sh — no script may carry its own copy
# of the fleet's project list.
#
# THE INCIDENT (2026-09-10). Nine approved project-7 PRs sat unmerged for ten
# days. bin/tier2-merge-sweep.sh matched build dirs against the literal regex
# `^(project-1|project-2|project-3|project-4)-os`, and bin/merge-queue.sh carried a
# four-entry slug table, so every project enrolled after those four was invisible
# to the merge lane. Nothing errored. The sweep ran nightly, found nothing to do
# for a project it could not name, and reported success — the same shape as a
# dedup that runs after the charge: the code looks right, and the only symptom
# is the work that never happened.
#
# A hardcoded list is not a bug you fix once. fleet.conf grew from four projects
# to nine, and every lane that copied the four went quietly wrong at a different
# time. So the fix that lasts is a guard: any enumeration of fleet projects in
# bin/ either reads bin/fleet-conf.sh, or is written down in
# tests/fleet-projects-allowlist.txt with a reason a human chose to accept.
#
# WHAT COUNTS AS AN ENUMERATION. Three or more DISTINCT fleet projects named on
# non-comment lines of one file — which is what a `for P in a b c d` loop, a
# `case` table, a `declare -A` map and a `(a|b|c)` regex alternation all look
# like. Comments and doc headers are prose and are skipped: naming projects
# while explaining something is not a list the code depends on.
#
# WHAT IT DOES NOT CATCH, stated so nobody mistakes a green run for proof:
#   * TWO projects. A pair is under the threshold, deliberately — a two-arm case
#     is usually a genuine either/or rather than a copy of the fleet.
#   * A list moved into a DATA file. Only bin/*.sh, bin/*.py and bin/*.mjs are
#     scanned, so a hand-kept projects.json is invisible here.
#   * A name assembled at runtime — "project-1" + "-os", or a list split across
#     lines — because matching is per line and literal.
#   * Anything outside bin/ (worker/, console-ui/, checks/, cron/).
# The guard raises the cost of the easy mistake; it is not a proof of absence.
#
# Run from anywhere: tests/fleet-projects-not-hardcoded-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
ALLOW="$DIR/tests/fleet-projects-allowlist.txt"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── the scanner ──────────────────────────────────────────────────────────────
# Written out as a standalone script so the SAME code scans the repo and the
# synthetic fixture below. A guard nobody has watched fail is a guard nobody
# knows is wired up.
cat > "$T/scan.py" <<'PY'
import re, sys, glob, os
conf, bindir = sys.argv[1], sys.argv[2]
projects = [l.split()[0] for l in open(conf)
            if l.strip() and not l.strip().startswith("#")]
# Each project matches its full name or its stem ("project-3" -> "project-3"), because
# a box table keyed on the stem is the same hardcoded list wearing a shorter
# name. The boundary classes exclude letters, digits, _ and -, so "project-4" does
# not fire inside "xproject-4" or "project-4_os" — but a dot is NOT a boundary character,
# so it DOES fire inside "os.project-4.example". That is intentional: a per-project URL
# table is exactly the kind of list this guard is looking for. It also means a
# file naming three projects only in URLs is caught, and must be allowlisted.
pats = {}
for p in projects:
    alts = {re.escape(p)}
    stem = p[:-3] if p.endswith("-os") else p
    if len(stem) >= 4:
        alts.add(re.escape(stem))
    pats[p] = re.compile(r"(?<![A-Za-z0-9_-])(?:%s)(?![A-Za-z0-9_])"
                         % "|".join(sorted(alts, key=len, reverse=True)))
files = []
for ext in ("*.sh", "*.py", "*.mjs"):
    files += glob.glob(os.path.join(bindir, ext))
for f in sorted(files):
    found, first = set(), {}
    for n, line in enumerate(open(f, errors="ignore"), 1):
        # prose, not a list the code reads. Both comment syntaxes, because the
        # .mjs QA drivers use // and the shell/python lanes use #.
        st = line.lstrip()
        if st.startswith("#") or st.startswith("//") or st.startswith("*"):
            continue
        for p, rx in pats.items():
            if rx.search(line):
                found.add(p); first.setdefault(p, n)
    if len(found) >= 3:
        where = ",".join(str(first[p]) for p in sorted(found, key=lambda x: first[x])[:3])
        print("%s\t%d\t%s\tL%s" % (os.path.basename(f), len(found),
                                   " ".join(sorted(found)), where))
PY

# ── 1. the scanner is not vacuous ────────────────────────────────────────────
# A synthetic bin/ with one offender and three innocents. If this block ever
# stops reporting exactly the offender, every green run below means nothing.
mkdir -p "$T/fixture/bin"
cat > "$T/fixture/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha
beta-os  Acme/beta-os  https://beta.example  /api/board 4 box-beta
gamma    Acme/gamma    -                     -          6 box-small
delta    Acme/delta    -                     -          8 box-small
EOF
cat > "$T/fixture/bin/loop.sh" <<'EOF'
#!/bin/bash
for P in alpha-os beta-os gamma; do echo "$P"; done
EOF
cat > "$T/fixture/bin/alternation.sh" <<'EOF'
#!/bin/bash
grep -oE '^(alpha|beta|gamma)' <<<"$1"
EOF
cat > "$T/fixture/bin/casetable.py" <<'EOF'
BOXES = {"alpha-os": "1.1.1.1", "beta-os": "2.2.2.2", "delta": "3.3.3.3"}
EOF
cat > "$T/fixture/bin/driver.mjs" <<'EOF'
// alpha-os, beta-os and delta are named in this comment and must not count.
const BASES = { "alpha-os": "https://a.example", "beta-os": "https://b.example",
                "delta": "https://d.example" };
EOF
cat > "$T/fixture/bin/clean.sh" <<'EOF'
#!/bin/bash
# alpha-os, beta-os and gamma all used to be listed here by hand.
for P in $("$H/bin/fleet-conf.sh" --projects); do echo "$P"; done
EOF
cat > "$T/fixture/bin/two.sh" <<'EOF'
#!/bin/bash
case "$1" in alpha-os) echo a ;; beta-os) echo b ;; esac
EOF
FIX=$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin" | cut -f1 | sort | tr '\n' ' ')
[ "$FIX" = "alternation.sh casetable.py driver.mjs loop.sh " ] && ok \
  || bad "the scanner must flag exactly the four enumerations (got: '$FIX')"
# Each shape individually, so a regression tells you WHICH one stopped working.
grep -q '^loop.sh' <<<"$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin")" && ok \
  || bad "a 'for P in a b c' loop must be flagged"
grep -q '^alternation.sh' <<<"$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin")" && ok \
  || bad "a (a|b|c) regex alternation must be flagged"
grep -q '^casetable.py' <<<"$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin")" && ok \
  || bad "a 3-key project table in a .py file must be flagged"
grep -q '^driver.mjs' <<<"$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin")" && ok \
  || bad "a 3-key project table in a .mjs file must be flagged (the extension is scanned)"
[ "$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin" | grep '^driver.mjs' | cut -f2)" = 3 ] && ok \
  || bad "the .mjs // comment naming the same three projects must not be counted"
grep -q '^clean.sh' <<<"$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin")" \
  && bad "a file that reads fleet-conf.sh must NOT be flagged for naming projects in a COMMENT" || ok
grep -q '^two.sh' <<<"$(python3 "$T/scan.py" "$T/fixture/fleet.conf" "$T/fixture/bin")" \
  && bad "two projects is a pair, not an enumeration — must not be flagged" || ok

# ── 2. the allowlist file is well formed ─────────────────────────────────────
[ -f "$ALLOW" ] || { bad "tests/fleet-projects-allowlist.txt is missing"; echo "$PASS pass, $FAIL fail"; exit 1; }
ALLOWED=""
while IFS= read -r LINE; do
  case "$LINE" in ''|'#'*) continue ;; esac
  F=$(awk '{print $1}' <<<"$LINE")
  R=$(sed -E 's/^[^[:space:]]+[[:space:]]+//' <<<"$LINE")
  if [ -z "$R" ] || [ "$R" = "$F" ]; then
    bad "allowlist entry '$F' has no reason — every exception is justified in one line"
  fi
  if [ ! -f "$DIR/bin/$F" ]; then
    bad "allowlist entry '$F' names a file that does not exist in bin/ — stale entry"
  fi
  ALLOWED="$ALLOWED $F"
done < "$ALLOW"
[ -n "$ALLOWED" ] && ok || bad "the allowlist is empty — expected today's known offenders"

# ── 3. the repo: every offender is allowlisted, and every allowlist entry
#       still offends ───────────────────────────────────────────────────────
python3 "$T/scan.py" "$DIR/fleet.conf" "$DIR/bin" > "$T/hits.tsv"
[ -s "$T/hits.tsv" ] && ok || bad "the scan found nothing at all in bin/ — the scanner is not reaching the repo"

NEW=0
while IFS=$'\t' read -r F N PS WHERE; do
  [ -n "$F" ] || continue
  if ! grep -qE "^${F}([[:space:]]|$)" "$ALLOW"; then
    NEW=$((NEW+1))
    echo "  bin/$F names $N fleet projects ($PS) at $WHERE"
  fi
done < "$T/hits.tsv"
if [ "$NEW" = 0 ]; then ok; else
  bad "$NEW script(s) enumerate fleet projects without reading bin/fleet-conf.sh.
     Fix: resolve the list through bin/fleet-conf.sh (--projects,
     --projects-with-board, --projects-on-box <box>, '<project> repo'), or add
     the file to tests/fleet-projects-allowlist.txt with a one-line reason."
fi

STALE=0
while IFS= read -r LINE; do
  case "$LINE" in ''|'#'*) continue ;; esac
  F=$(awk '{print $1}' <<<"$LINE")
  if ! grep -qxF "$F" <<<"$(cut -f1 "$T/hits.tsv")"; then
    STALE=$((STALE+1)); echo "  $F no longer enumerates fleet projects"
  fi
done < "$ALLOW"
if [ "$STALE" = 0 ]; then ok; else
  bad "$STALE allowlist entry(ies) are stale — a migrated file must be REMOVED from
     tests/fleet-projects-allowlist.txt, or the exception quietly outlives the reason."
fi

HITS=$(wc -l < "$T/hits.tsv" | tr -d ' ')
if [ "$FAIL" = 0 ]; then
  echo "fleet-projects-not-hardcoded-test: $PASS pass, 0 fail ($HITS file(s) enumerate fleet projects, every one allowlisted with a reason)"
else
  echo "fleet-projects-not-hardcoded-test: $PASS pass, $FAIL fail ($HITS file(s) enumerate fleet projects)"
fi
[ "$FAIL" = 0 ]
