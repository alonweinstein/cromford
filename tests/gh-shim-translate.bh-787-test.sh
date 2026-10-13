#!/bin/bash
# tests/gh-shim-translate.bh-787-test.sh — the contract of bin/gh-rest-shim (#769
# chunk 1): resolution, the kill switch, the pass-through log, the rate-limit
# classifier, and the ten shared gshim_* helpers the four sibling chunks import
# (gshim_api, gshim_passthru, gshim_parse, gshim_slug, gshim_fields_ok, gshim_emit,
# gshim_bodyfile, gshim_input, gshim_paginate, gshim_tmp).
#
# HOW IT DRIVES. Every block runs the REAL bin/gh-rest-shim through a PATH
# symlink ($T/shim/gh), with a stub standing in for the gh binary behind it
# (tests/lib/gh-shim-stub.sh). No block re-types the shim's logic and no block
# greps its source: the assertions are the recorded argv in $T/gh-calls.txt,
# stdout, an exit code, and the lines under $T/h/logs/.
#
# NO VERB HANDLERS EXIST IN THIS CHUNK, which is the point of the
# `no-verb-handlers` block. Everything that needs a handler to exercise a helper
# uses PROBE handlers written to $T/lib/probe.sh and loaded through
# GH_SHIM_LIB — the same door bin/lib/gh-shim/*.sh will come through.
#
# MUTATION CHECK (D1) is two blocks, not a claim: `mutation` runs a
# `sed 's/exit 75/exit 1/'` copy of the shim and fails if the rate-limit
# assertion still passes against it; `mutation-real-pinned` deletes the
# `$GH_REAL` branch out of gshim_resolve_real and fails if `real-pinned` survives.
# The other core behaviours were each broken once during the build and every one
# turned a block red:
#   - drop the `_fence.sh` skip in gshim_resolve_real   -> resolve-behind-fence red
#   - raise the depth ceiling out of reach            -> recursion-cap red (rc 124)
#   - stop exporting GH_REST_SHIM_DEPTH before exec   -> recursion-cap + killswitch red
#   - write the log line AFTER the exec in gshim_passthru -> passthru-log red
#   - return `[]` instead of exiting on a non-array page -> paginate-error-not-array red
#   - drop the --limit validation in gshim_parse        -> limit-flag-passthru red
#   - drop the "gh api exited N" stderr fallback      -> api-exited-N red
#   - pick fields with with_entries (no null fill)    -> emit-null-for-unset red
#   - let gshim_api's stdout flow on a failing call     -> api-error-body-swallowed red
#   - accumulate pages with `jq --argjson`            -> paginate-big-page red (E2BIG)
#   - log /proc/$PPID/cmdline as caller=              -> passthru-caller-no-secret red
#   - accept dot components in gshim_slug               -> the four dot cases red
#   - run -q on the body instead of the --json pick   -> emit-q-over-fields red
#
# Run from anywhere:  bash tests/gh-shim-translate.bh-787-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { # eq <name> <got> <want>
  if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi
}
match() { # match <name> <got> <ere>
  if [[ "$2" =~ $3 ]]; then ok; else bad "$1: [$2] does not match /$3/"; fi
}
has() { # has <name> <haystack> <needle>
  case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac
}
hasnt() { # hasnt <name> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1: [$2] must not contain [$3]" ;; *) ok ;; esac
}

SYS_PATH="$PATH"
gshim_stub_setup
STUB_PATH="$PATH"

# Every block loads its handlers from here; the shipped bin/lib/gh-shim is empty
# in this chunk and `no-verb-handlers` is the block that proves it.
export GH_SHIM_LIB="$T/lib"
cat >"$T/lib/probe.sh" <<'PROBE'
gshim_cmd_probe_get() {
  gshim_slug "${GSHIM_REST[0]:-}"
  gshim_fields_ok number,state,url
  local j
  j=$(gshim_api "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM") || exit $?
  gshim_emit "$j"
}
gshim_cmd_probe_list() {
  gshim_slug "${GSHIM_REST[0]:-}"
  gshim_paginate "repos/$GSHIM_SLUG/pulls?state=open"
}
# probe raw does NOT capture gshim_api in a $( ): a handler that captures hides a
# leaked error body inside its own variable, so the "empty stdout is always
# paired with a non-zero exit" rule can only be tested through this shape.
gshim_cmd_probe_raw() {
  gshim_slug "${GSHIM_REST[0]:-}"
  gshim_api "repos/$GSHIM_SLUG/pulls/$GSHIM_NUM" -H 'Accept: application/vnd.github.v3.diff'
}
gshim_cmd_probe_post() {
  gshim_slug "${GSHIM_REST[0]:-}"
  local body="" file="" bf inp i=0
  while [ "$i" -lt "${#GSHIM_REST[@]}" ]; do
    case "${GSHIM_REST[$i]}" in
      --body)      body="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      --body-file) file="${GSHIM_REST[$((i+1))]:-}"; i=$((i+2)) ;;
      *)           i=$((i+1)) ;;
    esac
  done
  bf=$(gshim_bodyfile "$body" "$file") || exit $?
  inp=$(gshim_input --rawfile body "$bf" --arg t probe '{title:$t,body:$body}') || exit $?
  gshim_api -X POST "repos/$GSHIM_SLUG/issues/$GSHIM_NUM/comments" --input "$inp" >/dev/null || exit $?
}
gshim_cmd_probe_echo() {
  printf 'REPO=%s|FIELDS=%s|JQ=%s|LIMIT=%s|REST=%s\n' \
    "$GSHIM_REPO" "$GSHIM_FIELDS" "$GSHIM_JQ" "$GSHIM_LIMIT" "${GSHIM_REST[*]:-}"
}
gshim_cmd_probe_tmp() {
  local f
  f=$(gshim_tmp) || exit 1
  dirname "$f"
}
PROBE

with_path() { # with_path <PATH> <gh args…>
  local p="$1"; shift
  local saved="$PATH"
  export PATH="$p"
  gshim_run "$@"
  export PATH="$saved"
}

logfile="$T/h/logs/gh-passthrough.log"
logline() { [ -f "$logfile" ] && cat "$logfile"; return 0; }
logcount() { if [ -f "$logfile" ]; then wc -l <"$logfile" | tr -d ' '; else echo 0; fi; }

pull1_json() {
  gshim_fixture repos_o_r_pulls_1 <<'J'
{"number":1,"state":"OPEN","url":"https://github.com/o/r/pull/1","mergeable":true}
J
}

# ── syntax ───────────────────────────────────────────────────────────────────
# The shim has no `.sh` suffix, so CI names it explicitly in both the `bash -n`
# loop and the shellcheck line; this block is the same gate at suite speed, and
# it is what catches the syntax error before CI does.
bash -n "$DIR/bin/gh-rest-shim" 2>"$T/.err"; RC=$?
eq "syntax parses" "$RC" "0"
eq "syntax quiet" "$(cat "$T/.err")" ""
eq "syntax executable" "$([ -x "$DIR/bin/gh-rest-shim" ] && echo yes || echo no)" "yes"

# ── resolve ──────────────────────────────────────────────────────────────────
gshim_reset; pull1_json
gshim_run probe get 1 -R o/r --json state -q .state
eq "resolve rc" "$RC" "0"
eq "resolve stdout" "$OUT" "OPEN"
eq "resolve one call" "$(gshim_calls | grep -c '^api repos/o/r/pulls/1$')" "1"
# The shim, not some other gh: only the shim exports GH_REST_SHIM_DEPTH, so
# depth=1 in the stub's env record is the proof the call came through it.
eq "resolve through the shim" "$(gshim_env | grep -c '^depth=1 api repos/o/r/pulls/1$')" "1"

# ── resolve-double-path ──────────────────────────────────────────────────────
# bin/agent-call.sh:629 composes the fenced PATH again on a nested lane, which
# leaves this directory on it twice. readlink -f skips both copies.
gshim_reset
with_path "$T/shim:$T/shim:$T/real:$SYS_PATH" probe get 1 -R o/r --json state -q .state
eq "resolve-double-path rc" "$RC" "0"
eq "resolve-double-path stdout" "$OUT" "OPEN"
eq "resolve-double-path one call" "$(gshim_calls | grep -c '^api repos/o/r/pulls/1$')" "1"

# ── resolve-behind-fence ─────────────────────────────────────────────────────
# bin/lane-shims/gh execs _fence.sh, which strips only ITS OWN dir from PATH and
# takes the next gh — us — with the fence dir still first. Taking "the first gh
# that is not me" would hand it straight back to the fence, forever.
mkdir -p "$T/fence"
cp "$DIR/bin/lane-shims/gh" "$DIR/bin/lane-shims/_fence.sh" "$T/fence/"
chmod 755 "$T/fence/gh" "$T/fence/_fence.sh"
gshim_reset
export HARNESS_LANE=execute IRON_LAW_GUARD="$DIR/bin/iron-law-guard.sh"
with_path "$T/fence:$T/shim:$T/real:$SYS_PATH" probe get 1 -R o/r --json state -q .state
unset HARNESS_LANE IRON_LAW_GUARD
eq "resolve-behind-fence rc" "$RC" "0"
eq "resolve-behind-fence stdout" "$OUT" "OPEN"
eq "resolve-behind-fence one call" "$(gshim_calls | grep -c '^api repos/o/r/pulls/1$')" "1"

# ── resolve-none-127 ─────────────────────────────────────────────────────────
# A PATH with no gh but us, and no reachable fallback. `env -i` is the only way
# to be sure of that (the box's own PATH may well carry a real gh), so the tool
# dir has to carry every command the shim reaches for on the way.
mkdir -p "$T/tools"
for _b in readlink dirname mktemp cat head grep tr rm date jq; do
  _p=$(command -v "$_b" 2>/dev/null) && ln -sf "$_p" "$T/tools/$_b"
done
unset _b _p
env -i PATH="$T/tools:$T/shim" HARNESS="$T/h" GH_SHIM_LIB="$T/lib" \
  GH_SHIM_FALLBACK=/nonexistent-gh "$T/shim/gh" probe get 1 -R o/r \
  >"$T/.out" 2>"$T/.err"
RC=$?
eq "resolve-none-127 rc" "$RC" "127"
eq "resolve-none-127 stderr" "$(cat "$T/.err")" "gh-rest-shim: real gh binary not found"

# ── real-pinned / real-unusable ($GH_REAL is step 2's first branch) ──────────
# Nothing in the suite drove GH_REAL before, so deleting that branch outright
# left every block green — the PATH walk answers the same way on a box where
# gh IS on PATH. The alt binary is deliberately NOT the stub: `OUT=ALT` can
# only come from the binary GH_REAL named.
mkdir -p "$T/alt"
{ printf '#!/bin/bash\nT=%q\n' "$T"
  cat <<'ALT'
printf 'ALT %s\n' "$*" >>"$T/gh-calls.txt"
echo ALT
exit 0
ALT
} >"$T/alt/gh"
chmod 755 "$T/alt/gh"
gshim_reset
export GH_REAL="$T/alt/gh"
with_path "$T/shim:$T/real:$SYS_PATH" label list -R o/r
unset GH_REAL
eq "real-pinned rc" "$RC" "0"
eq "real-pinned stdout" "$OUT" "ALT"
eq "real-pinned reached GH_REAL" "$(gshim_calls | grep -c '^ALT label list -R o/r$')" "1"
eq "real-pinned PATH gh untouched" "$(gshim_calls | grep -c '^PASSTHRU ')" "0"

# Set but not executable is not a binary: fall through to the PATH walk rather
# than exiting 127 on a box where gh is perfectly reachable.
gshim_reset
export GH_REAL="$T/none-such-gh"
with_path "$T/shim:$T/real:$SYS_PATH" label list -R o/r
unset GH_REAL
eq "real-unusable rc" "$RC" "0"
eq "real-unusable fell back to PATH" "$(gshim_calls | grep -c '^PASSTHRU label list -R o/r$')" "1"
eq "real-unusable did not use GH_REAL" "$(gshim_calls | grep -c '^ALT ')" "0"

# ── recursion-cap ────────────────────────────────────────────────────────────
# Two COPIES of the shim and no real binary behind them: each one resolves the
# other (a copy is not `readlink -f`-identical to me, so the self-check cannot
# see it) and execs it, forever. The depth ceiling is the thing that turns that
# hang into an exit code. `timeout 20` is the proof it terminates at all — the
# assertion that matters is that the rc is the shim's 127 and not timeout's 124.
mkdir -p "$T/loopa" "$T/loopb"
cp "$DIR/bin/gh-rest-shim" "$T/loopa/gh"
cp "$DIR/bin/gh-rest-shim" "$T/loopb/gh"
chmod 755 "$T/loopa/gh" "$T/loopb/gh"
gshim_reset
timeout 20 env -i PATH="$T/tools:$T/loopa:$T/loopb" HARNESS="$T/h" \
  GH_SHIM_LIB="$T/lib" GH_SHIM_FALLBACK=/nonexistent-gh \
  "$T/loopa/gh" label create x -R o/r >"$T/.out" 2>"$T/.err"
RC=$?
eq "recursion-cap rc" "$RC" "127"
match "recursion-cap stderr" "$(cat "$T/.err")" '^gh-rest-shim: '
eq "recursion-cap no body" "$(cat "$T/.out")" ""
eq "recursion-cap reached no binary" "$(gshim_calls)" ""

# ── depth-fastpath ───────────────────────────────────────────────────────────
gshim_reset
export GH_REST_SHIM_DEPTH=1
gshim_run probe get 1 -R o/r --json state
unset GH_REST_SHIM_DEPTH
eq "depth-fastpath rc" "$RC" "0"
eq "depth-fastpath untranslated" "$(gshim_calls)" "PASSTHRU probe get 1 -R o/r --json state"
eq "depth-fastpath unlogged" "$(logcount)" "0"

# ── killswitch-env / killswitch-flag ─────────────────────────────────────────
gshim_reset
export GH_SHIM_OFF=1
gshim_run probe get 1 -R o/r --json state
unset GH_SHIM_OFF
eq "killswitch-env rc" "$RC" "0"
eq "killswitch-env argv verbatim" "$(gshim_calls)" "PASSTHRU probe get 1 -R o/r --json state"
eq "killswitch-env unlogged" "$(logcount)" "0"
eq "killswitch-env went through the shim" "$(gshim_env | grep -c '^depth=1 ')" "1"

gshim_reset
: >"$T/h/flags/gh-shim-off"
gshim_run probe get 1 -R o/r --json state
rm -f "$T/h/flags/gh-shim-off"
eq "killswitch-flag rc" "$RC" "0"
eq "killswitch-flag argv verbatim" "$(gshim_calls)" "PASSTHRU probe get 1 -R o/r --json state"
eq "killswitch-flag unlogged" "$(logcount)" "0"
eq "killswitch-flag went through the shim" "$(gshim_env | grep -c '^depth=1 ')" "1"

# A value that is not exactly 1 is NOT off.
gshim_reset
export GH_SHIM_OFF=yes
gshim_run probe get 1 -R o/r --json state -q .state
unset GH_SHIM_OFF
eq "killswitch-not-1 still translates" "$OUT" "OPEN"

# ── passthru-log ─────────────────────────────────────────────────────────────
gshim_reset
gshim_run label create x -R o/r
eq "passthru-log rc" "$RC" "0"
eq "passthru-log argv verbatim" "$(gshim_calls)" "PASSTHRU label create x -R o/r"
eq "passthru-log one line" "$(logcount)" "1"
match "passthru-log format" "$(logline)" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z label create x pid=[0-9]+ caller=.* reason=untranslated$'
eq "passthru-log went through the shim" "$(gshim_env | grep -c '^depth=1 label create x -R o/r$')" "1"

# ── passthru-caller-no-secret ────────────────────────────────────────────────
# `caller=` used to be the first 80 bytes of the parent's /proc cmdline. A lane
# that runs `gh ... --token ghp_...` through `bash -c` therefore wrote that
# token into a durable log on the box. The field names the parent PROGRAM, not
# what it was told to do. The `; :` keeps bash as a real parent process instead
# of letting it exec-optimise itself away into the gh call.
gshim_reset
bash -c 'gh label create x -R o/r --token ghp_SECRETSECRETSECRET; :' >/dev/null 2>&1
eq "passthru-caller-no-secret ran" \
  "$(gshim_calls | grep -c '^PASSTHRU label create x -R o/r --token ghp_SECRETSECRETSECRET$')" "1"
eq "passthru-caller-no-secret one line" "$(logcount)" "1"
hasnt "passthru-caller-no-secret token not logged" "$(logline)" "ghp_"
match "passthru-caller-no-secret caller is the program" "$(logline)" \
  ' caller=bash reason=untranslated$'
match "passthru-caller-no-secret format holds" "$(logline)" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z label create x pid=[0-9]+ caller=[^ ]+ reason=untranslated$'

# A script parent names the script, which is the whole point of the field: it
# is there so an operator reading the log knows which lane spent the call.
gshim_reset
printf '#!/bin/bash\ngh label create x -R o/r\n:\n' >"$T/lane-probe.sh"
chmod 755 "$T/lane-probe.sh"
bash "$T/lane-probe.sh" >/dev/null 2>&1
match "passthru-caller-no-secret script parent" "$(logline)" ' caller=lane-probe\.sh '

# ── passthru-log-unwritable ──────────────────────────────────────────────────
# A directory where the log file goes: an append fails for root too, which
# `chmod 500` would not (this suite runs as root on the boxes).
gshim_reset
mkdir -p "$logfile"
gshim_run label create x -R o/r
rm -rf "$T/h/logs/gh-passthrough.log"
eq "passthru-log-unwritable rc" "$RC" "0"
eq "passthru-log-unwritable still ran" "$(gshim_calls)" "PASSTHRU label create x -R o/r"
eq "passthru-log-unwritable quiet" "$ERR" ""

# ── passthru-api-unlogged ────────────────────────────────────────────────────
gshim_reset
gshim_fixture rate_limit <<'J'
{"resources":{"core":{"reset":1758189600,"remaining":4999}}}
J
gshim_run api rate_limit
eq "passthru-api-unlogged api rc" "$RC" "0"
has "passthru-api-unlogged api reached stub" "$(gshim_calls)" "api rate_limit"
gshim_run auth token
eq "passthru-api-unlogged auth rc" "$RC" "0"
has "passthru-api-unlogged auth reached stub" "$(gshim_calls)" "PASSTHRU auth token"
eq "passthru-api-unlogged no log file" "$([ -e "$logfile" ] && echo present || echo absent)" "absent"

# ── no-verb-handlers (this chunk ships no verb logic) ────────────────────────
# GH_SHIM_LIB unset on purpose: this drives the SHIPPED bin/lib/gh-shim.
# The verbs are `release` and `gist` and not `pr`/`issue` on purpose: #788 and
# #789 translate pr and issue, so a block written on those would pass here for
# the wrong reason the day a handler exists and would have to be rewritten in
# the sibling. release and gist are translated by nothing in the #769 series.
gshim_reset
env -u GH_SHIM_LIB gh release list -R o/r >"$T/.out" 2>"$T/.err"; RC=$?
eq "no-verb-handlers release rc" "$RC" "0"
has "no-verb-handlers release passthru" "$(gshim_calls)" "PASSTHRU release list -R o/r"
env -u GH_SHIM_LIB gh gist list >"$T/.out" 2>"$T/.err"; RC=$?
has "no-verb-handlers gist passthru" "$(gshim_calls)" "PASSTHRU gist list"
eq "no-verb-handlers two lines logged" "$(logcount)" "2"
eq "no-verb-handlers reason" "$(logline | grep -c 'reason=untranslated$')" "2"
eq "no-verb-handlers no REST call" "$(gshim_calls | grep -c '^api ')" "0"

# ── ratelimit-75 / -429 / -abuse / -reset-unknown ────────────────────────────
# The reset time is RENDERED, not shape-matched: the rate_limit fixture's epoch
# 1758189600 is 10:00:00Z, and a regex of the right shape would pass just as
# well on a reset the shim invented. The call count matters too — the read is
# the only thing that makes the time real, and a classifier that skipped it and
# still printed a plausible hour is exactly the failure this pins.
ratelimit_case() { # ratelimit_case <name> <stderr line>
  gshim_reset
  printf '%s\n' "$2" | gshim_fixture repos_o_r_pulls_1 1
  gshim_run probe get 1 -R o/r --json state
  eq "$1 rc" "$RC" "75"
  eq "$1 no body" "$OUT" ""
  eq "$1 stderr" "$ERR" "gh-rest-shim: REST rate limited (resets 10:00:00Z)"
  eq "$1 one rate_limit read" "$(gshim_calls | grep -c '^api rate_limit')" "1"
}
ratelimit_case ratelimit-75 "HTTP 403: API rate limit exceeded for user ID 1 (https://api.github.com/repos/o/r/pulls/1)"
ratelimit_case ratelimit-429 "HTTP 429: You have exceeded a secondary rate limit. Please wait a few minutes"
ratelimit_case ratelimit-abuse "HTTP 403: You have triggered an abuse detection mechanism"
# Real gh says `gh: <message> (HTTP <code>)`, not the ticket's `HTTP <code>: …`.
# The classifier's regex covers both; until now the suite only ever fed it the
# ticket's shape, so the shape the fleet will actually meet was untested.
ratelimit_case ratelimit-real-shape "gh: API rate limit exceeded for user ID 1 (HTTP 403)"

gshim_reset
rm -f "$T/fixtures/rate_limit.json"
printf 'HTTP 403: API rate limit exceeded for user ID 1\n' | gshim_fixture repos_o_r_pulls_1 1
gshim_run probe get 1 -R o/r --json state
eq "ratelimit-reset-unknown rc" "$RC" "75"
eq "ratelimit-reset-unknown stderr" "$ERR" "gh-rest-shim: REST rate limited (resets unknown)"
gshim_fixture rate_limit <<'J'
{"resources":{"core":{"reset":1758189600}}}
J

# ── ratelimit-negatives (a wrong 75 turns a real error into a retry) ─────────
neg_case() { # neg_case <name> <stderr line>
  gshim_reset
  printf '%s\n' "$2" | gshim_fixture repos_o_r_pulls_1 1
  gshim_run probe get 1 -R o/r --json state
  eq "ratelimit-negatives $1 rc" "$RC" "1"
  eq "ratelimit-negatives $1 stderr" "$ERR" "gh-rest-shim: $2"
}
neg_case 403-integration "HTTP 403: Resource not accessible by integration"
neg_case 404             "HTTP 404: Not Found"
neg_case 401             "HTTP 401: Bad credentials"
neg_case 422             "HTTP 422: Validation Failed"
neg_case 405             "HTTP 405: Pull Request is not mergeable"
neg_case 409             "HTTP 409: Head branch was modified. Review and try the merge again"
neg_case network         "error connecting to api.github.com"
neg_case real-404        "gh: Not Found (HTTP 404)"
neg_case real-403-integration "gh: Resource not accessible by integration (HTTP 403)"

# A 200 whose BODY says "rate limit" is a successful answer, not a classification.
gshim_reset
rm -f "$T/fixtures/repos_o_r_pulls_1.rc" "$T/fixtures/repos_o_r_pulls_1.err"
gshim_fixture repos_o_r_pulls_1 <<'J'
{"number":1,"state":"OPEN","url":"https://github.com/o/r/pull/1","title":"raise the rate limit"}
J
gshim_run probe get 1 -R o/r --json state -q .state
eq "ratelimit-negatives 200-body rc" "$RC" "0"
eq "ratelimit-negatives 200-body stdout" "$OUT" "OPEN"

# ── parse-flags ──────────────────────────────────────────────────────────────
WANT='REPO=o/r|FIELDS=a,b|JQ=.x|LIMIT=7|REST=--state open --draft'
gshim_run probe echo -R o/r --json a --json b -q .x -L 7 --state open --draft
eq "parse-flags spaced" "$OUT" "$WANT"
gshim_run probe echo --repo=o/r --json=a --json=b --jq=.x --limit=7 --state open --draft
eq "parse-flags equals" "$OUT" "$WANT"
gshim_run probe echo -R o/r
eq "parse-flags defaults" "$OUT" 'REPO=o/r|FIELDS=|JQ=|LIMIT=30|REST='

# ── slug-url-wins-over-R ─────────────────────────────────────────────────────
gshim_reset
gshim_fixture repos_a_b_pulls_9 <<'J'
{"number":9,"state":"MERGED","url":"https://github.com/a/b/pull/9"}
J
gshim_run probe get https://github.com/a/b/pull/9 -R o/r --json state -q .state
eq "slug-url-wins-over-R rc" "$RC" "0"
eq "slug-url-wins-over-R stdout" "$OUT" "MERGED"
eq "slug-url-wins-over-R endpoint" "$(gshim_calls)" "api repos/a/b/pulls/9"

# ── slug-from-ssh-origin ─────────────────────────────────────────────────────
gshim_reset; pull1_json
printf 'git@github.com:o/r.git\n' >"$T/fixtures/git-origin.txt"
gshim_run probe get 1 --json state -q .state
eq "slug-from-ssh-origin ssh endpoint" "$(gshim_calls)" "api repos/o/r/pulls/1"
gshim_reset
printf 'https://github.com/o/r.git\n' >"$T/fixtures/git-origin.txt"
gshim_run probe get 1 --json state -q .state
eq "slug-from-ssh-origin https endpoint" "$(gshim_calls)" "api repos/o/r/pulls/1"
rm -f "$T/fixtures/git-origin.txt"

# The same, against REAL git in a real repo rather than the stub, so the origin
# parsing is pinned to git's actual output.
mkdir -p "$T/ghonly" "$T/gitrepo"
cp "$T/real/gh" "$T/ghonly/gh"; chmod 755 "$T/ghonly/gh"
# The stub git is first on PATH right now, so the real one is named explicitly.
env PATH="$SYS_PATH" git init -q "$T/gitrepo" >/dev/null 2>&1
env PATH="$SYS_PATH" git -C "$T/gitrepo" remote add origin git@github.com:o/r.git
gshim_reset
cd "$T/gitrepo" || exit 1
with_path "$T/shim:$T/ghonly:$SYS_PATH" probe get 1 --json state -q .state
cd "$DIR" || exit 1
eq "slug-from-ssh-origin real git rc" "$RC" "0"
eq "slug-from-ssh-origin real git endpoint" "$(gshim_calls)" "api repos/o/r/pulls/1"

# ── no-slug-passthru ─────────────────────────────────────────────────────────
gshim_reset
gshim_run probe get 1
eq "no-slug-passthru rc" "$RC" "0"
eq "no-slug-passthru argv" "$(gshim_calls)" "PASSTHRU probe get 1"
eq "no-slug-passthru reason" "$(logline | grep -c 'reason=no-slug$')" "1"

# ── slug-must-be-owner-repo ──────────────────────────────────────────────────
# An origin or -R that does not normalise to exactly owner/repo is discarded, so
# the call passes through instead of spending a request on repos/<junk>/… that
# can only 404. Each case asserts BOTH that no REST call was made and that the
# shim (depth=1) is the one that handed it over.
gshim_reset
printf 'https://github.com/o/r/tree/main\n' >"$T/fixtures/git-origin.txt"
gshim_run probe get 1
eq "slug-must-be-owner-repo origin-with-path rc" "$RC" "0"
eq "slug-must-be-owner-repo origin-with-path argv" "$(gshim_calls)" "PASSTHRU probe get 1"
eq "slug-must-be-owner-repo origin-with-path no REST call" "$(gshim_calls | grep -c '^api ')" "0"
eq "slug-must-be-owner-repo origin-with-path reason" "$(logline | grep -c 'reason=no-slug$')" "1"
eq "slug-must-be-owner-repo origin-with-path depth" "$(gshim_env | grep -c '^depth=1 probe get 1$')" "1"

gshim_reset
printf 'https://github.com/onlyowner\n' >"$T/fixtures/git-origin.txt"
gshim_run probe get 1
eq "slug-must-be-owner-repo owner-only argv" "$(gshim_calls)" "PASSTHRU probe get 1"
eq "slug-must-be-owner-repo owner-only no REST call" "$(gshim_calls | grep -c '^api ')" "0"
eq "slug-must-be-owner-repo owner-only reason" "$(logline | grep -c 'reason=no-slug$')" "1"

gshim_reset
printf 'https://github.example.com/o/r.git\n' >"$T/fixtures/git-origin.txt"
gshim_run probe get 1
eq "slug-must-be-owner-repo enterprise-host argv" "$(gshim_calls)" "PASSTHRU probe get 1"
eq "slug-must-be-owner-repo enterprise-host no REST call" "$(gshim_calls | grep -c '^api ')" "0"
rm -f "$T/fixtures/git-origin.txt"

gshim_reset
gshim_run probe get 1 -R ../../user/o
eq "slug-must-be-owner-repo traversal -R rc" "$RC" "0"
eq "slug-must-be-owner-repo traversal -R argv" "$(gshim_calls)" "PASSTHRU probe get 1 -R ../../user/o"
eq "slug-must-be-owner-repo traversal -R no REST call" "$(gshim_calls | grep -c '^api ')" "0"
eq "slug-must-be-owner-repo traversal -R reason" "$(logline | grep -c 'reason=no-slug$')" "1"

# `.` and `..` pass the owner/repo character class — they are nothing but legal
# characters — so `-R ../x` built `repos/../x/pulls/1`, which is a REST path
# pointing somewhere the caller never named. Each of the four shapes has to end
# in the pass-through with the argv it arrived with and zero requests spent.
dot_slug_case() { # dot_slug_case <name> <-R value>
  gshim_reset
  gshim_run probe get 1 -R "$2"
  eq "slug-must-be-owner-repo $1 rc" "$RC" "0"
  eq "slug-must-be-owner-repo $1 argv" "$(gshim_calls)" "PASSTHRU probe get 1 -R $2"
  eq "slug-must-be-owner-repo $1 no REST call" "$(gshim_calls | grep -c '^api ')" "0"
  eq "slug-must-be-owner-repo $1 reason" "$(logline | grep -c 'reason=no-slug$')" "1"
  eq "slug-must-be-owner-repo $1 depth" "$(gshim_env | grep -c '^depth=1 probe get 1 -R ')" "1"
}
dot_slug_case dot-parent-owner ../x
dot_slug_case dot-parent-repo  x/..
dot_slug_case dot-self-owner   ./x
dot_slug_case dot-self-repo    x/.

# The guard rejects junk, it does not reject legal slugs: dots, dashes and
# underscores are all valid in a repo name.
gshim_reset
gshim_fixture repos_my-org_repo._name_pulls_1 <<'J'
{"number":1,"state":"OPEN"}
J
printf 'git@github.com:my-org/repo._name.git\n' >"$T/fixtures/git-origin.txt"
gshim_run probe get 1 --json state -q .state
eq "slug-must-be-owner-repo legal-name rc" "$RC" "0"
eq "slug-must-be-owner-repo legal-name endpoint" "$(gshim_calls)" "api repos/my-org/repo._name/pulls/1"
rm -f "$T/fixtures/git-origin.txt"

# ── fields-passthru (absent is never invented) ───────────────────────────────
gshim_reset
gshim_run probe get 1 -R o/r --json number,isInMergeQueue
eq "fields-passthru rc" "$RC" "0"
eq "fields-passthru original argv" "$(gshim_calls)" "PASSTHRU probe get 1 -R o/r --json number,isInMergeQueue"
eq "fields-passthru no REST call" "$(gshim_calls | grep -c '^api ')" "0"
eq "fields-passthru reason" "$(logline | grep -c 'reason=field:isInMergeQueue$')" "1"

# ── emit-q-raw / emit-picks-fields / emit-array-picks-fields ─────────────────
gshim_reset; pull1_json
gshim_run probe get 1 -R o/r -q .url
eq "emit-q-raw" "$OUT" "https://github.com/o/r/pull/1"
gshim_run probe get 1 -R o/r --json number,state
eq "emit-picks-fields" "$OUT" '{"number":1,"state":"OPEN"}'
gshim_fixture repos_o_r_pulls_1 <<'J'
[{"number":1,"state":"OPEN","mergeable":true},{"number":2,"state":"CLOSED","mergeable":false}]
J
gshim_run probe get 1 -R o/r --json number,state
eq "emit-array-picks-fields" "$OUT" '[{"number":1,"state":"OPEN"},{"number":2,"state":"CLOSED"}]'

# ── emit-q-over-fields ───────────────────────────────────────────────────────
# gh applies --jq to what --json selected, not to the whole response. Running
# -q on the raw body answers a question about fields the caller asked gh to drop.
gshim_reset; pull1_json
gshim_run probe get 1 -R o/r --json state -q 'keys|join(",")'
eq "emit-q-over-fields rc" "$RC" "0"
eq "emit-q-over-fields keys" "$OUT" "state"
# The array shape too: the pick happens per element, then -q sees the picked list.
gshim_fixture repos_o_r_pulls_1 <<'J'
[{"number":1,"state":"OPEN","mergeable":true},{"number":2,"state":"CLOSED","mergeable":false}]
J
gshim_run probe get 1 -R o/r --json number -q '.[0]|keys|join(",")'
eq "emit-q-over-fields array keys" "$OUT" "number"
pull1_json

# ── emit-default / emit-null-for-unset ───────────────────────────────────────
gshim_reset; pull1_json
gshim_run probe get 1 -R o/r
eq "emit-default rc" "$RC" "0"
eq "emit-default compacted" "$OUT" \
  '{"number":1,"state":"OPEN","url":"https://github.com/o/r/pull/1","mergeable":true}'
# gh prints every field you asked for. A key the body did not carry comes back
# `null`, the way gh does it — dropping it would make `.[0].url` a jq error in
# every caller that trusted the field list it passed.
gshim_fixture repos_o_r_pulls_1 <<'J'
{"number":1,"state":"OPEN"}
J
gshim_run probe get 1 -R o/r --json number,url
eq "emit-null-for-unset" "$OUT" '{"number":1,"url":null}'
gshim_fixture repos_o_r_pulls_1 <<'J'
[{"number":1,"state":"OPEN"},{"number":2}]
J
gshim_run probe get 1 -R o/r --json number,url
eq "emit-null-for-unset array" "$OUT" '[{"number":1,"url":null},{"number":2,"url":null}]'
# A false value is a value: filling the gaps with `// null` would eat it.
gshim_fixture repos_o_r_pulls_1 <<'J'
{"number":1,"state":false}
J
gshim_run probe get 1 -R o/r --json number,state
eq "emit-keeps-false" "$OUT" '{"number":1,"state":false}'
pull1_json

# ── paginate-150 ─────────────────────────────────────────────────────────────
gshim_reset
jq -n -c '[range(100)|{number:(.+1),state:"OPEN"}]' >"$T/fixtures/repos_o_r_pulls.p1.json"
jq -n -c '[range(60)|{number:(.+101),state:"OPEN"}]' >"$T/fixtures/repos_o_r_pulls.p2.json"
gshim_run probe list 1 -R o/r -L 150
eq "paginate-150 rc" "$RC" "0"
eq "paginate-150 count" "$(printf '%s' "$OUT" | jq 'length')" "150"
eq "paginate-150 last" "$(printf '%s' "$OUT" | jq -r '.[149].number')" "150"
eq "paginate-150 two calls" "$(gshim_calls | grep -c '^api repos/o/r/pulls?')" "2"
has "paginate-150 page 1" "$(gshim_calls)" "state=open&per_page=100&page=1"
has "paginate-150 page 2" "$(gshim_calls)" "state=open&per_page=100&page=2"

# ── paginate-big-page (a production-sized page, not a toy one) ───────────────
# Every other paginate block uses 20-byte objects. A real page of 100 pull
# requests is ~200 KB, and an accumulator that moved the JSON through argv
# (`jq --argjson a "$acc"`) died on E2BIG at exactly that size — with an empty
# stdout and rc 0, which reads to every caller as "no open PRs".
gshim_reset
jq -n -c '[range(100)|{number:(.+1),state:"OPEN",body:("x"*2000)}]' \
  >"$T/fixtures/repos_o_r_pulls.p1.json"
jq -n -c '[range(10)|{number:(.+101),state:"OPEN",body:("x"*2000)}]' \
  >"$T/fixtures/repos_o_r_pulls.p2.json"
eq "paginate-big-page page is production sized" \
  "$([ "$(wc -c <"$T/fixtures/repos_o_r_pulls.p1.json")" -gt 200000 ] && echo yes || echo no)" "yes"
gshim_run probe list 1 -R o/r -L 150
eq "paginate-big-page rc" "$RC" "0"
eq "paginate-big-page count" "$(jq 'length' "$T/.out")" "110"
eq "paginate-big-page last" "$(jq -r '.[109].number' "$T/.out")" "110"
eq "paginate-big-page first" "$(jq -r '.[0].number' "$T/.out")" "1"
eq "paginate-big-page two calls" "$(gshim_calls | grep -c '^api repos/o/r/pulls?')" "2"
eq "paginate-big-page quiet" "$ERR" ""
rm -f "$T/fixtures/repos_o_r_pulls.p1.json" "$T/fixtures/repos_o_r_pulls.p2.json"

# ── paginate-stops-short-page ────────────────────────────────────────────────
gshim_reset
jq -n -c '[range(30)|{number:(.+1),state:"OPEN"}]' >"$T/fixtures/repos_o_r_pulls.p1.json"
gshim_run probe list 1 -R o/r -L 100
eq "paginate-stops-short-page rc" "$RC" "0"
eq "paginate-stops-short-page count" "$(printf '%s' "$OUT" | jq 'length')" "30"
eq "paginate-stops-short-page one call" "$(gshim_calls | grep -c '^api repos/o/r/pulls?')" "1"

# ── paginate-default-limit (gh's own 30 when --limit is absent) ──────────────
gshim_reset
jq -n -c '[range(40)|{number:(.+1),state:"OPEN"}]' >"$T/fixtures/repos_o_r_pulls.p1.json"
gshim_run probe list 1 -R o/r
eq "paginate-default-limit rc" "$RC" "0"
eq "paginate-default-limit count" "$(printf '%s' "$OUT" | jq 'length')" "30"
eq "paginate-default-limit one call" "$(gshim_calls | grep -c '^api repos/o/r/pulls?')" "1"
has "paginate-default-limit per_page" "$(gshim_calls)" "state=open&per_page=30&page=1"

# ── paginate-ratelimit (75 propagates out of the page walk) ──────────────────
# A partial array would read as "these are all the open PRs". It is not: the
# walk stopped because GitHub cut us off, and that has to reach the caller.
gshim_reset
jq -n -c '[range(100)|{number:(.+1)}]' >"$T/fixtures/repos_o_r_pulls.p1.json"
printf 'HTTP 403: API rate limit exceeded for user ID 1\n' >"$T/fixtures/repos_o_r_pulls.err"
printf '1\n' >"$T/fixtures/repos_o_r_pulls.rc"
gshim_run probe list 1 -R o/r -L 300
rm -f "$T/fixtures/repos_o_r_pulls.err" "$T/fixtures/repos_o_r_pulls.rc"
eq "paginate-ratelimit rc" "$RC" "75"
eq "paginate-ratelimit no partial array" "$OUT" ""
match "paginate-ratelimit stderr" "$ERR" '^gh-rest-shim: REST rate limited'

# ── paginate-error-not-array (an error is not "no PRs") ──────────────────────
gshim_reset
printf '%s\n' '{"message":"Bad credentials"}' >"$T/fixtures/repos_o_r_pulls.p1.json"
gshim_run probe list 1 -R o/r -L 100
eq "paginate-error-not-array rc" "$RC" "1"
eq "paginate-error-not-array no body" "$OUT" ""
eq "paginate-error-not-array stderr" "$ERR" "gh-rest-shim: unexpected response (not a list)"

# ── paginate-page-cap (never a silent partial array) ─────────────────────────
gshim_reset
jq -n -c '[range(100)|{number:(.+1)}]'   >"$T/fixtures/repos_o_r_pulls.p1.json"
jq -n -c '[range(100)|{number:(.+101)}]' >"$T/fixtures/repos_o_r_pulls.p2.json"
jq -n -c '[range(100)|{number:(.+201)}]' >"$T/fixtures/repos_o_r_pulls.p3.json"
export GH_SHIM_MAX_PAGES=2
gshim_run probe list 1 -R o/r -L 300
unset GH_SHIM_MAX_PAGES
eq "paginate-page-cap rc" "$RC" "1"
eq "paginate-page-cap no body" "$OUT" ""
match "paginate-page-cap stderr" "$ERR" 'more than 2 pages'
rm -f "$T/fixtures/repos_o_r_pulls.p1.json" "$T/fixtures/repos_o_r_pulls.p2.json" \
      "$T/fixtures/repos_o_r_pulls.p3.json"

# ── limit-flag-passthru (a --limit we cannot honour is gh's to reject) ───────
# Quietly substituting 30 for `--limit abc` answers a question the caller did
# not ask. The real binary already has the right error for it.
gshim_reset; pull1_json
gshim_run probe list 1 -R o/r --limit abc
eq "limit-flag-passthru rc" "$RC" "0"
eq "limit-flag-passthru original argv" "$(gshim_calls)" "PASSTHRU probe list 1 -R o/r --limit abc"
eq "limit-flag-passthru no REST call" "$(gshim_calls | grep -c '^api ')" "0"
eq "limit-flag-passthru reason" "$(logline | grep -c 'reason=flag:--limit$')" "1"
gshim_reset
gshim_run probe list 1 -R o/r -L 0
eq "limit-flag-passthru zero" "$(gshim_calls)" "PASSTHRU probe list 1 -R o/r -L 0"
eq "limit-flag-passthru zero reason" "$(logline | grep -c 'reason=flag:--limit$')" "1"
gshim_reset
gshim_run probe list 1 -R o/r --limit=-5
eq "limit-flag-passthru negative" "$(gshim_calls)" "PASSTHRU probe list 1 -R o/r --limit=-5"

# ── bodyfile-stdin ───────────────────────────────────────────────────────────
gshim_reset
gshim_fixture repos_o_r_issues_1_comments <<'J'
{"id":11,"body":"ok"}
J
printf 'hello from stdin' >"$T/body.txt"
gshim_run probe post 1 -R o/r --body-file - <"$T/body.txt"
eq "bodyfile-stdin rc" "$RC" "0"
has "bodyfile-stdin body in input" "$(gshim_calls)" 'input={"title":"probe","body":"hello from stdin"}'

# ── input-no-argv-leak ───────────────────────────────────────────────────────
gshim_reset
BODY="a|b 'c' \$(x) ünïcode"
gshim_run probe post 1 -R o/r --body "$BODY"
eq "input-no-argv-leak rc" "$RC" "0"
LINE=$(gshim_calls | grep '^api -X POST')
ARGV_PART="${LINE%% input=*}"
INPUT_PART="${LINE#* input=}"
hasnt "input-no-argv-leak argv clean" "$ARGV_PART" "ünïcode"
hasnt "input-no-argv-leak argv clean quoted" "$ARGV_PART" "\$(x)"
has "input-no-argv-leak body carried" "$INPUT_PART" "a|b 'c' \$(x) ünïcode"
eq "input-no-argv-leak body decoded" \
  "$(printf '%s' "$INPUT_PART" | jq -r .body)" "$BODY"

# ── bodyfile-missing-file (the shim's own bug is never a pass-through) ───────
# Passing this through would hand gh the same unreadable path and bury the
# reason one layer down. Real gh fails here too; say so in our own words.
gshim_reset
gshim_run probe post 1 -R o/r --body-file "$T/none"
eq "bodyfile-missing-file rc" "$RC" "1"
eq "bodyfile-missing-file stderr" "$ERR" "gh-rest-shim: cannot read $T/none"
eq "bodyfile-missing-file no REST call" "$(gshim_calls | grep -c '^api ')" "0"
eq "bodyfile-missing-file not passed through" "$(gshim_calls)" ""

# ── input-bad-jq ─────────────────────────────────────────────────────────────
gshim_reset
cat >"$T/lib/badjq.sh" <<'PROBE'
gshim_cmd_probe_badjq() {
  local p
  p=$(gshim_input --arg a 1 '{not valid jq') || exit $?
  printf 'unreachable %s\n' "$p"
}
PROBE
gshim_run probe badjq -R o/r
rm -f "$T/lib/badjq.sh"
eq "input-bad-jq rc" "$RC" "1"
eq "input-bad-jq stderr" "$ERR" "gh-rest-shim: could not build request body"
eq "input-bad-jq no body" "$OUT" ""

# ── api-exited-N (a failure with nothing on stderr still names itself) ──────
gshim_reset
: >"$T/fixtures/repos_o_r_pulls_1.err"
printf '7\n' >"$T/fixtures/repos_o_r_pulls_1.rc"
gshim_run probe get 1 -R o/r --json state
rm -f "$T/fixtures/repos_o_r_pulls_1.rc" "$T/fixtures/repos_o_r_pulls_1.err"
eq "api-exited-N rc" "$RC" "1"
eq "api-exited-N stderr" "$ERR" "gh-rest-shim: gh api exited 7"
pull1_json

# ── api-error-body-swallowed ─────────────────────────────────────────────────
# Real `gh api` prints the error BODY on stdout and its message on stderr, both.
# A handler that does `out=$(gshim_api …) || exit $?` hides that inside its own
# variable, which is why this block drives `probe raw`, the shape that lets
# gshim_api's stdout reach the caller. `{"message":"Not Found"}` arriving on
# stdout with a non-zero exit is the one thing every caller of this shim is
# allowed to assume cannot happen.
gshim_reset
printf '%s\n' '{"message":"Not Found","status":"404"}' >"$T/fixtures/repos_o_r_pulls_1.json"
printf 'gh: Not Found (HTTP 404)\n' >"$T/fixtures/repos_o_r_pulls_1.err"
printf '1\n' >"$T/fixtures/repos_o_r_pulls_1.rc"
gshim_run probe raw 1 -R o/r
eq "api-error-body-swallowed rc" "$RC" "1"
eq "api-error-body-swallowed no body" "$OUT" ""
eq "api-error-body-swallowed stderr" "$ERR" "gh-rest-shim: gh: Not Found (HTTP 404)"
eq "api-error-body-swallowed reached the stub" \
  "$(gshim_calls | grep -c '^api repos/o/r/pulls/1')" "1"
# The captured shape too, so the rule holds whichever way a handler calls in.
gshim_reset
gshim_run probe get 1 -R o/r --json state
eq "api-error-body-swallowed captured rc" "$RC" "1"
eq "api-error-body-swallowed captured no body" "$OUT" ""
rm -f "$T/fixtures/repos_o_r_pulls_1.rc" "$T/fixtures/repos_o_r_pulls_1.err"
pull1_json

# ── api-raw-on-success ───────────────────────────────────────────────────────
# Buffering the body to hide it on failure must not touch it on success: a
# `.diff` is bytes, not JSON, and its trailing newline is part of the patch.
gshim_reset
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' \
  >"$T/fixtures/repos_o_r_pulls_1.diff"
gshim_run probe raw 1 -R o/r
eq "api-raw-on-success rc" "$RC" "0"
cmp -s "$T/.out" "$T/fixtures/repos_o_r_pulls_1.diff"; RC=$?
eq "api-raw-on-success byte identical" "$RC" "0"
eq "api-raw-on-success trailing newline kept" \
  "$(wc -c <"$T/.out" | tr -d ' ')" "$(wc -c <"$T/fixtures/repos_o_r_pulls_1.diff" | tr -d ' ')"
rm -f "$T/fixtures/repos_o_r_pulls_1.diff"

# ── tmp-cleanup ──────────────────────────────────────────────────────────────
gshim_reset
gshim_run probe tmp -R o/r
eq "tmp-cleanup rc" "$RC" "0"
match "tmp-cleanup path" "$OUT" 'gh-rest-shim\.'
eq "tmp-cleanup removed" "$([ -d "$OUT" ] && echo present || echo gone)" "gone"
# A pass-through decided AFTER the temp dir exists leaves through exec, where an
# EXIT trap never fires. Both shapes have to leave $TMPDIR empty.
gshim_run probe get 1 -R o/r --json number,isInMergeQueue
eq "tmp-cleanup no leak through exec" "$(find "$T/tmp" -mindepth 1 -maxdepth 1 | wc -l)" "0"
gshim_run probe get 1 -R o/r --json state -q .state
eq "tmp-cleanup no leak on success" "$(find "$T/tmp" -mindepth 1 -maxdepth 1 | wc -l)" "0"

# ── stub-selftest (the harness four sibling suites will import) ──────────────
gshim_reset
gshim_fixture sel_f <<'J'
{"id":7,"name":"seven"}
J
eq "stub-selftest json" "$("$T/real/gh" api sel/f)" '{"id":7,"name":"seven"}'
eq "stub-selftest jq" "$("$T/real/gh" api sel/f -q .name)" "seven"
printf 'diff --git a/x b/x\n' >"$T/fixtures/sel_f.diff"
eq "stub-selftest diff" "$("$T/real/gh" api sel/f -H "Accept: application/vnd.github.v3.diff")" "diff --git a/x b/x"
jq -n -c '[{"page":2}]' >"$T/fixtures/sel_p.p2.json"
eq "stub-selftest page" "$("$T/real/gh" api 'sel/p?per_page=1&page=2')" '[{"page":2}]'
"$T/real/gh" api sel/missing >"$T/.out" 2>"$T/.err"; RC=$?
eq "stub-selftest missing rc" "$RC" "1"
match "stub-selftest missing stderr" "$(cat "$T/.err")" '^HTTP 404: Not Found'
printf 'HTTP 500: upstream\n' | gshim_fixture sel_e 1
"$T/real/gh" api sel/e >"$T/.out" 2>"$T/.err"; RC=$?
eq "stub-selftest rc fixture rc" "$RC" "1"
eq "stub-selftest rc fixture stderr" "$(cat "$T/.err")" "HTTP 500: upstream"
eq "stub-selftest rc fixture no body" "$(cat "$T/.out")" ""
# A .rc WITH a .json is real gh on a failing call: message on stderr, body on
# stdout. Without this the suite's "no body on failure" assertions prove
# nothing — there was no body for the shim to leak in the first place.
printf '%s\n' '{"message":"upstream"}' >"$T/fixtures/sel_e.json"
"$T/real/gh" api sel/e >"$T/.out" 2>"$T/.err"; RC=$?
eq "stub-selftest rc+json rc" "$RC" "1"
eq "stub-selftest rc+json stderr" "$(cat "$T/.err")" "HTTP 500: upstream"
eq "stub-selftest rc+json body on stdout" "$(cat "$T/.out")" '{"message":"upstream"}'
rm -f "$T/fixtures/sel_e.json" "$T/fixtures/sel_e.rc" "$T/fixtures/sel_e.err"
"$T/real/gh" pr list -R o/r >/dev/null 2>&1
has "stub-selftest passthru" "$(gshim_calls)" "PASSTHRU pr list -R o/r"
"$T/real/git" remote get-url origin >/dev/null 2>&1
has "stub-selftest git recorded" "$(cat "$T/git-calls.txt")" "git remote get-url origin"
gshim_run label create x -R o/r
gshim_reset
eq "stub-selftest reset calls" "$(gshim_calls)" ""
eq "stub-selftest reset log" "$(logcount)" "0"
eq "stub-selftest reset git" "$([ -e "$T/git-calls.txt" ] && echo present || echo gone)" "gone"

# ── mutation (D1): break exit 75, watch ratelimit-75 go red ──────────────────
mkdir -p "$T/mut"
sed 's/exit 75/exit 1/' "$DIR/bin/gh-rest-shim" >"$T/mut/gh"
chmod 755 "$T/mut/gh"
# Both halves, so a shim that never said `exit 75` cannot pass this by being
# identical to its own mutant.
if [ "$(grep -c 'exit 75' "$DIR/bin/gh-rest-shim")" -ge 1 ] &&
   [ "$(grep -c 'exit 75' "$T/mut/gh")" -eq 0 ]; then ok
else bad "mutation: the sed did not change anything"; fi
gshim_reset
printf 'HTTP 403: API rate limit exceeded for user ID 1\n' | gshim_fixture repos_o_r_pulls_1 1
gshim_run probe get 1 -R o/r --json state
eq "mutation baseline is 75" "$RC" "75"
gshim_reset
with_path "$T/mut:$T/real:$SYS_PATH" probe get 1 -R o/r --json state
if [ "$RC" = "75" ]; then
  bad "mutation: the mutant still exits 75 — ratelimit-75 pins nothing"
else
  ok
fi
rm -f "$T/fixtures/repos_o_r_pulls_1.rc" "$T/fixtures/repos_o_r_pulls_1.err"

# ── mutation-real-pinned (D1): delete the GH_REAL branch, watch real-pinned ──
# This is the mutant that was silently alive before real-pinned existed: with
# the branch gone the PATH walk answers every other block identically, so the
# whole suite stayed green while `GH_REAL` did nothing at all.
mkdir -p "$T/mut2"
sed '/^  if \[ -n "\${GH_REAL:-}" \]/,/^  fi$/d' "$DIR/bin/gh-rest-shim" >"$T/mut2/gh"
chmod 755 "$T/mut2/gh"
MUT2_CUT=$(( $(wc -l <"$DIR/bin/gh-rest-shim") - $(wc -l <"$T/mut2/gh") ))
if [ "$(grep -c 'GH_REAL:-' "$DIR/bin/gh-rest-shim")" -ge 1 ] &&
   [ "$(grep -c 'GH_REAL:-' "$T/mut2/gh")" -eq 0 ] &&
   [ "$MUT2_CUT" -eq 3 ]; then ok
else bad "mutation-real-pinned: the sed did not delete exactly the GH_REAL branch (cut $MUT2_CUT lines)"; fi
gshim_reset
export GH_REAL="$T/alt/gh"
with_path "$T/mut2:$T/real:$SYS_PATH" label list -R o/r
unset GH_REAL
if [ "$OUT" = "ALT" ]; then
  bad "mutation-real-pinned: the mutant still honours GH_REAL — real-pinned pins nothing"
else
  ok
fi
eq "mutation-real-pinned mutant used PATH instead" \
  "$(gshim_calls | grep -c '^PASSTHRU label list -R o/r$')" "1"

echo "gh-shim-translate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
