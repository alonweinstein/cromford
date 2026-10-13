#!/bin/bash
# merge-queue.sh must resolve a repo slug for EVERY fleet.conf project, not only
# the four original OS projects. 2026-09-10: nine approved tier-2 project-7 PRs
# sat unmerged for up to ten days because merge-queue.sh had a four-entry slug
# table. It now resolves through bin/fleet-conf.sh.
# BH-1366: moved from tests/tier2-sweep-projects-test.sh; the --project-of half
# drove the retired tier2-merge-sweep.sh and went with it. The slug_for loop is
# kept and now iterates every fleet project instead of three names.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
H="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; n=0
sed -n '/^slug_for()/,/^}/p' "$H/bin/merge-queue.sh" > "$T/slug.sh"
[ -s "$T/slug.sh" ] || { echo "FAIL slug_for() not found in bin/merge-queue.sh"; exit 1; }
for p in $("$H/bin/fleet-conf.sh" --projects 2>/dev/null) project-7 project-6 project-5; do
  want=$("$H/bin/fleet-conf.sh" "$p" repo)
  [ -n "$want" ] || continue
  n=$((n+1))
  got=$(HARNESS="$H" bash -c 'source "$1"; slug_for "$2"' bash "$T/slug.sh" "$p" 2>/dev/null)
  if [ "$got" = "$want" ]; then echo "ok   merge-queue slug $p -> $want"; else echo "FAIL merge-queue slug $p -> '$got' (want '$want')"; fail=1; fi
done
[ "$n" -ge 3 ] || { echo "FAIL only $n fleet projects resolved"; fail=1; }
exit $fail
