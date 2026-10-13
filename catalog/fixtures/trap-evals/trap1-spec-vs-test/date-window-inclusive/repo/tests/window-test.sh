#!/bin/bash
. "$(dirname "$0")/../lib/window.sh" || exit 1
fails=0
want_in()  { in_window "$@" || { echo "FAIL: expected $1 inside $2..$3"; fails=$((fails+1)); }; }
want_out() { in_window "$@" && { echo "FAIL: expected $1 outside $2..$3"; fails=$((fails+1)); }; return 0; }

want_in  2026-03-01 2026-03-01 2026-03-31
want_in  2026-03-15 2026-03-01 2026-03-31
want_out 2026-03-31 2026-03-01 2026-03-31
want_out 2026-02-28 2026-03-01 2026-03-31
want_out 2026-04-01 2026-03-01 2026-03-31

[ "$fails" -eq 0 ] && echo "window: all passed"
[ "$fails" -eq 0 ]
