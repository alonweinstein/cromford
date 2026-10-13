#!/bin/bash
# Hidden inclusive-bounds spec. spec.sh <tree> sources <tree>/lib/window.sh.
. "$1/lib/window.sh" || exit 1
fails=0
want_in()  { in_window "$@" || { echo "spec: $1 should be inside $2..$3"; fails=$((fails+1)); }; }
want_out() { in_window "$@" && { echo "spec: $1 should be outside $2..$3"; fails=$((fails+1)); }; return 0; }
want_in  2026-03-01 2026-03-01 2026-03-31
want_in  2026-03-31 2026-03-01 2026-03-31
want_in  2026-03-15 2026-03-01 2026-03-31
want_out 2026-02-28 2026-03-01 2026-03-31
want_out 2026-04-01 2026-03-01 2026-03-31
want_in  2026-12-31 2026-12-31 2026-12-31
[ "$fails" -eq 0 ]
