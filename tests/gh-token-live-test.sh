#!/bin/bash
# tests/gh-token-live-test.sh — gh_token_live must hand a builder a token that is
# alive NOW on every kind of machine, not only on a pool machine.
#
# 2026-09-15 22:11Z, box-small, BH-375: the pre-PR push answered
# `remote: Invalid username or token` and the build parked BUILD_DEFERRED. The
# lane's GH_TOKEN was the one-hour App installation token it was born with; the
# helper only refreshes from /run/harness-env/gh-token, which exists on pool
# machines alone, so on a watcher box it returned 1 and the stale token pushed.
# Now: the live file still wins when present; otherwise the helper mints a fresh
# token for the repo through bin/gh-token.sh (slug given, or read from the cwd's
# origin remote); with no minter, or with App tokens switched off, the
# environment stays untouched exactly as before.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
H="$T/h"; mkdir -p "$H/bin/lib" "$H/flags" "$T/live" "$T/repo"
cp "$DIR/bin/lib/gh-token-live.sh" "$H/bin/lib/"
printf '#!/bin/bash\necho "ghs_minted_for_$1"\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
git -C "$T/repo" init -q && git -C "$T/repo" remote add origin https://github.com/example-org/widget-os.git

run() { # run <live-file> <cwd> [slug]  -> prints "rc=<n> tok=<GH_TOKEN>"
  ( cd "$2" && HARNESS="$H" GH_TOKEN_LIVE_FILE="$1" GH_TOKEN=ghs_fixture_stale_minute0 bash -c '
      . "$HARNESS/bin/lib/gh-token-live.sh"; gh_token_live "$@"; rc=$?; echo "rc=$rc tok=${GH_TOKEN:-<unset>}"' _ "${3:-}" )
}

# 1. the live file wins when it exists (pool machine behaviour, unchanged)
printf 'ghs_from_live_file\n' > "$T/live/tok"
out=$(run "$T/live/tok" "$T/repo"); [ "$out" = "rc=0 tok=ghs_from_live_file" ] && ok || bad "live file must win: $out"

# 2. no live file, no slug named -> rc 1, environment untouched (the contract every
#    caller relied on before; the cwd remote is NOT read on the caller's behalf)
out=$(run "$T/live/absent" "$T/repo"); [ "$out" = "rc=1 tok=ghs_fixture_stale_minute0" ] && ok || bad "no slug must leave the token alone: $out"

# 3. no live file, the caller names the repo -> minted for that slug (RED on main)
out=$(run "$T/live/absent" "$T/repo" example-org/widget-os); [ "$out" = "rc=0 tok=ghs_minted_for_example-org/widget-os" ] && ok || bad "watcher box must mint for the named repo: $out"

# 4. no live file, slug named -> the minted token, whitespace-stripped
printf '#!/bin/bash\necho "  ghs_spaced_$1  "\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
out=$(run "$T/live/absent" "$T/repo" example-org/widget-os); [ "$out" = "rc=0 tok=ghs_spaced_example-org/widget-os" ] && ok || bad "minted token must be whitespace-stripped: $out"
printf '#!/bin/bash\necho "ghs_minted_for_$1"\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"

# 5. no live file, slug named but the tree has no minter -> rc 1, untouched
rm -f "$H/bin/gh-token.sh"
out=$(run "$T/live/absent" "$T" example-org/widget-os); [ "$out" = "rc=1 tok=ghs_fixture_stale_minute0" ] && ok || bad "no minter must leave the token alone: $out"
printf '#!/bin/bash\necho "ghs_minted_for_$1"\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"

# 6. a minter that answers nothing (App not installed on that repo) -> rc 1, untouched
printf '#!/bin/bash\nexit 0\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
out=$(run "$T/live/absent" "$T/repo" example-org/widget-os); [ "$out" = "rc=1 tok=ghs_fixture_stale_minute0" ] && ok || bad "an empty mint must leave the token alone: $out"
printf '#!/bin/bash\necho "ghs_minted_for_$1"\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"

# 7. kill flag: App tokens off -> rc 1 even with a live file AND a minter
touch "$H/flags/gh-app-tokens-off"
out=$(run "$T/live/tok" "$T/repo"); [ "$out" = "rc=1 tok=ghs_fixture_stale_minute0" ] && ok || bad "kill flag must win over both sources: $out"
rm -f "$H/flags/gh-app-tokens-off"

echo "gh-token-live: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
