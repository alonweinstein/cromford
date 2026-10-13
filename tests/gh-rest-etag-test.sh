#!/bin/bash
# tests/gh-rest-etag-test.sh — the ETag/If-None-Match cache bin/lib/gh-rest.sh's
# `gh_rest` GET path grew (BH-1295): the conditional header sent on a cached
# GET, the 304-hit replay (rc 0, GH_REST_REASON=cached, body byte-identical to
# the first read), the 304-miss (rc 75, GH_REST_REASON=cache-miss, never an
# empty answer standing in for a state), the GH_ETAG=0 kill switch, the store
# skip on a non-GET or an empty 2xx body, and the TTL/size sweep.
#
# Same shape as tests/gh-rest-lib-test.sh: `gh` is a stub on PATH that replays
# queued fixture responses (now carrying an Etag: header) and records its own
# argv so a row can assert the If-None-Match header actually went out.
#
# Run from anywhere: bash tests/gh-rest-etag-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/gh-rest.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/tmp" "$T/bin" "$T/fx"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T"

# ── the stub `gh` — identical shape to tests/gh-rest-lib-test.sh ────────────
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
f=$(find "$D/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
rc=0
[ -f "$f.rc" ] && rc=$(cat "$f.rc")
cat "$f"
rm -f "$f" "$f.rc"
exit "$rc"
STUB
chmod +x "$T/bin/gh"

FXN=0
fx() { # fx <status> [body] [etag] [proto] [rc]
  FXN=$((FXN + 1))
  local f rc
  f="$T/fx/$(printf '%02d' "$FXN")"
  { printf '%s %s Status\r\n' "${4:-HTTP/2.0}" "$1"
    printf 'X-RateLimit-Remaining: 0\r\n'
    [ -n "${3:-}" ] && printf 'ETag: %s\r\n' "$3"
    printf '\r\n'
    printf '%s' "${2:-}"
  } > "$f"
  rc="${5:-}"
  if [ -z "$rc" ]; then case "$1" in 2*|304) rc=0 ;; *) rc=1 ;; esac; fi
  [ "$1" = 304 ] && rc=1
  printf '%s' "$rc" > "$f.rc"
}
reset() { # drop every queued fixture, every recording, the cache dir and the
  # counter file gh_rest_etag_report reads (B2 fix: the counter is a FILE now,
  # since mc_pr_view's callers are all `$( )` and no shell variable survives
  # that — see gh-rest-etag.sh's own header on _gh_etag_count_file). Also
  # unsets GH_ETAG_COUNT_FILE (F1, round 2: counting is opt-in now — a section
  # that wants its reads counted must export it itself, and reset() must not
  # let one section's export leak into the next section's assumptions).
  rm -rf "$T/fx" "$T/h/state/gh-etag"
  mkdir -p "$T/fx"
  FXN=0
  rm -f "$T/gh-calls.txt" "$T/out" "${GH_ETAG_COUNT_FILE:-${TMPDIR:-/tmp}/gh-etag-count.$$}"
  unset GH_ETAG GH_ETAG_TTL_H GH_ETAG_MAX GH_ETAG_MAX_BYTES GH_ETAG_COUNT_FILE GH_LIMIT_IDENTITY
}
calls()  { cat "$T/gh-calls.txt" 2>/dev/null; }
ncalls() { if [ -f "$T/gh-calls.txt" ]; then wc -l < "$T/gh-calls.txt"; else echo 0; fi; }
cachefiles() { find "$T/h/state/gh-etag" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

if ! . "$LIB"; then
  bad "bin/lib/gh-rest.sh is missing or cannot be sourced — every row below is red"
fi
if ! command -v _gh_etag_key >/dev/null 2>&1; then
  bad "bin/lib/gh-rest-etag.sh did not load — gh-rest.sh sources it, so this is the library, not the test"
fi

# ══ 1. first GET stores; second GET sends If-None-Match; 304 replays ═══════
reset
fx 200 '{"a":1}' '"v1"'
O1=$(gh_rest GET repos/o/r/pulls/7 2>/dev/null); RC1=$?
[ "$RC1" = 0 ] && [ "$O1" = '{"a":1}' ] || bad "first GET: rc=$RC1 out='$O1'"
[ "$(cachefiles)" = 1 ] || bad "first GET: expected exactly one cache file, got $(cachefiles)"

fx 304 ''
gh_rest GET repos/o/r/pulls/7 > "$T/out" 2>/dev/null; RC2=$?
O2=$(cat "$T/out")
if [ "$RC2" = 0 ] && [ "$O2" = "$O1" ] && [ "$GH_REST_STATUS" = 304 ] && [ "$GH_REST_REASON" = cached ]; then ok
else bad "cache hit: rc=$RC2 status=$GH_REST_STATUS reason=$GH_REST_REASON out='$O2' want='$O1'"; fi
case "$(calls)" in *'If-None-Match: "v1"'*) ok ;; *) bad "cache hit: If-None-Match \"v1\" missing from argv: $(calls)" ;; esac

# ══ 1b. byte for byte, proven with `cmp` on two files, not two `$( )`
# captures (review I3/I1): a `$( )`-vs-`$( )` compare strips trailing
# newlines from BOTH sides and cannot see a divergence there. A body ending
# in a blank line is the shape that broke the earlier "convergence"
# claim: strip-then-reprint (the fresh path) and a raw re-scan of the
# original bytes (what the store used to do) disagree past one trailing
# newline. The fix stores gh_rest's OWN `$body` string, not a second
# extraction, so this must now be identical on the wire, not just when both
# sides are captured through the newline-eating shell construct.
reset
BODY=$'line1\nline2\n\n'
fx 200 "$BODY" '"vnl"'
gh_rest GET repos/o/r/pulls/7 > "$T/fresh.out" 2>/dev/null
fx 304 ''
gh_rest GET repos/o/r/pulls/7 > "$T/replay.out" 2>/dev/null
if cmp -s "$T/fresh.out" "$T/replay.out"; then ok
else bad "byte-for-byte: fresh ($(wc -c < "$T/fresh.out") bytes) and replayed ($(wc -c < "$T/replay.out") bytes) differ on a body ending in a blank line"; fi

# ══ 1c. a 200 with no ETag header REMOVES any stale entry (review I2) ═══════
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
[ "$(cachefiles)" = 1 ] || bad "1c setup: expected a cache file before the no-etag fetch"
fx 200 '{"a":2}'   # no third arg: no ETag header on this response
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
[ "$(cachefiles)" = 0 ] \
  && ok || bad "a 200 with no ETag must drop the stale entry, not leave it for the next 304 to replay"

# ══ 1d. a body over GH_ETAG_MAX_BYTES is never stored, and drops any stale
# entry too (review F3) — bounds a diff/patch read's worst case to entry-
# count x cap instead of unbounded.
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
[ "$(cachefiles)" = 1 ] || bad "1d setup: expected a cache file before the oversize fetch"
export GH_ETAG_MAX_BYTES=8
fx 200 '{"way too big for the cap":1}' '"v2"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
[ "$(cachefiles)" = 0 ] \
  && ok || bad "a body over GH_ETAG_MAX_BYTES must not be stored, and must drop the stale entry too"
unset GH_ETAG_MAX_BYTES

# ══ 2. a fresh 200 with a NEW etag replaces the stored one ══════════════════
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
fx 200 '{"a":2}' '"v2"'
O=$(gh_rest GET repos/o/r/pulls/7 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$O" = '{"a":2}' ] || bad "second fetch: rc=$RC out='$O'"
case "$(calls)" in *'If-None-Match: "v1"'*) ok ;; *) bad "second fetch: did not send the v1 etag it had cached: $(calls)" ;; esac
fx 304 ''
gh_rest GET repos/o/r/pulls/7 > "$T/out" 2>/dev/null
[ "$(cat "$T/out")" = '{"a":2}' ] || bad "replaced etag: the 304 after replacement replayed the OLD body, not '{\"a\":2}'"
case "$(calls)" in *'If-None-Match: "v2"'*) ok ;; *) bad "third fetch: did not send the replaced v2 etag: $(calls)" ;; esac

# ══ 3. GH_ETAG=0 — byte-for-byte today's behaviour: no header, no file ══════
reset
export GH_ETAG=0
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
[ "$(cachefiles)" = 0 ] || bad "GH_ETAG=0: a cache file was written anyway"
case "$(calls)" in *If-None-Match*) bad "GH_ETAG=0: an If-None-Match header went out anyway: $(calls)" ;; *) ok ;; esac
# a 304 fixture under GH_ETAG=0 is unreachable in real traffic (no conditional
# header was ever sent), but the contract must still be "exactly today's
# behaviour" if one somehow arrives: 75, no special reason, nothing printed.
fx 304 ''
gh_rest GET repos/o/r/pulls/7 > "$T/out" 2>/dev/null; RC=$?
if [ "$RC" = 75 ] && [ -z "$GH_REST_REASON" ] && [ -z "$(cat "$T/out")" ]; then ok
else bad "GH_ETAG=0, a 304: want rc 75, no reason, no output — got rc=$RC reason=$GH_REST_REASON out='$(cat "$T/out")'"; fi
unset GH_ETAG

# ══ 4. a 304 with the cache file gone mid-tick is 75, never an empty answer ═
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
rm -f "$T/h"/state/gh-etag/*
fx 304 ''
gh_rest GET repos/o/r/pulls/7 > "$T/out" 2>/dev/null; RC=$?
if [ "$RC" = 75 ] && [ "$GH_REST_REASON" = cache-miss ] && [ -z "$(cat "$T/out")" ]; then ok
else bad "304 cache-miss: want rc 75 reason cache-miss empty out — got rc=$RC reason=$GH_REST_REASON out='$(cat "$T/out")'"; fi

# ══ 4b. a 304 replayed from a file a STALE WRITER already replaced is a
# cache-miss, never a reply built from two different writes (review B3/P4).
# Driven directly at _gh_etag_on_304, which is the one place this can be
# proven without a real race: store "v1", then ask the function to honour a
# 304 that was sent for the etag gh_rest actually READ before the request
# ("v1"), and separately one for an etag nothing ever sent ("v2" — as if
# another writer replaced the file between gh_rest's read and this reply).
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
KEY=$(_gh_etag_key GET repos/o/r/pulls/7)
_gh_etag_on_304 "$KEY" '"v1"' > "$T/out" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = '{"a":1}' ] \
  && ok || bad "on_304 with the etag that was sent: want a hit, got rc=$RC out='$(cat "$T/out")'"
_gh_etag_on_304 "$KEY" '"v2"' > "$T/out" 2>/dev/null; RC=$?
[ "$RC" = 1 ] && [ -z "$(cat "$T/out")" ] \
  && ok || bad "on_304 with an etag that does NOT match the stored one: want a miss (rc 1, no output), got rc=$RC out='$(cat "$T/out")'"

# ══ 4c. a hit touches the entry's mtime, so the TTL sweep ages out cold keys,
# not ones a lane keeps asking about and getting 304s for (review N2) ════════
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
CF=$(find "$T/h/state/gh-etag" -maxdepth 1 -type f ! -name '.*')
touch -t 202001010000 "$CF" 2>/dev/null || touch -d '2020-01-01' "$CF" 2>/dev/null
OLDM=$(_gh_etag_mtime "$CF")
fx 304 ''
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
NEWM=$(_gh_etag_mtime "$CF")
[ "$NEWM" -gt "$OLDM" ] \
  && ok || bad "a cache hit must touch the entry's mtime (old=$OLDM new=$NEWM)"

# ══ 4d. `-r` passes, the read after it fails (review B3/P3, reproduced the
# way the review's own probe did: the entry is replaced by a directory of the
# same name between the two file operations `_gh_etag_on_304` makes). Must be
# a miss, never rc 0 with an empty body standing in for a state.
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
KEY=$(_gh_etag_key GET repos/o/r/pulls/7)
CF=$(find "$T/h/state/gh-etag" -maxdepth 1 -type f ! -name '.*')
rm -f "$CF" && mkdir "$CF"
_gh_etag_on_304 "$KEY" '"v1"' > "$T/out" 2>/dev/null; RC=$?
[ "$RC" = 1 ] && [ -z "$(cat "$T/out")" ] \
  && ok || bad "on_304 whose entry became unreadable mid-call: want a miss (rc 1, no output), got rc=$RC out='$(cat "$T/out")'"
rmdir "$CF" 2>/dev/null

# ══ 4e. the SAME shape, one step later: the etag line (line 1) is still
# readable but the body read (`tail -n +2`) itself fails. 4d's directory trick
# cannot reach this specific line — a directory fails the `sed -n '1p'` etag
# check first, before `_gh_etag_on_304` ever calls `tail` — so this row shadows
# `tail` on PATH instead, the standard way to fault-inject a command a test
# does not otherwise control. Removed again immediately after, since `tail`
# is a real dependency of nothing else run past this point EXCEPT more calls
# to this same function.
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
KEY=$(_gh_etag_key GET repos/o/r/pulls/7)
cat > "$T/bin/tail" <<'TAILSTUB'
#!/bin/bash
[ "$1" = -n ] && exit 1
TAILSTUB
chmod +x "$T/bin/tail"
_gh_etag_on_304 "$KEY" '"v1"' > "$T/out" 2>/dev/null; RC=$?
rm -f "$T/bin/tail"
[ "$RC" = 1 ] && [ -z "$(cat "$T/out")" ] \
  && ok || bad "on_304 whose body read fails after the etag line was already confirmed: want a miss (rc 1, no output), got rc=$RC out='$(cat "$T/out")'"

# ══ 4f. an entry truncated to JUST the etag line (review F2, round 2): `tail
# -n +2` SUCCEEDS here (rc 0) with an empty capture — 4e's tail-shadow does
# not reach this, because the old code's only guard was tail's own exit code,
# and a truncated file gives tail nothing to fail on. This is the ticket's
# own sentence, verbatim: "A 304 with NO cached body is 75, never an empty
# answer." A crash mid-write, a disk-full write, or a hand edit can produce
# this; the atomic tmp+mv writer in _gh_etag_on_2xx cannot.
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
KEY=$(_gh_etag_key GET repos/o/r/pulls/7)
CF=$(find "$T/h/state/gh-etag" -maxdepth 1 -type f ! -name '.*')
printf '"v1"\n' > "$CF"   # the etag line survives; the body line does not
_gh_etag_on_304 "$KEY" '"v1"' > "$T/out" 2>/dev/null; RC=$?
[ "$RC" = 1 ] && [ -z "$(cat "$T/out")" ] \
  && ok || bad "on_304 against an entry truncated to just the etag line: want a miss (rc 1, no output), got rc=$RC out='$(cat "$T/out")'"

# ══ 5. non-GET never touches the cache; an empty-body 2xx GET writes nothing ═
reset
fx 200 '{"ok":true}' '"v1"'
gh_rest PATCH repos/o/r/issues/7 -f state=closed >/dev/null 2>&1
[ "$(cachefiles)" = 0 ] || bad "a PATCH must never write a cache file"
case "$(calls)" in *If-None-Match*) bad "a PATCH must never send If-None-Match: $(calls)" ;; *) ok ;; esac
reset
fx 200 '' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1; RC=$?
[ "$RC" = 75 ] && [ "$GH_REST_REASON" = empty ] || bad "empty 2xx GET: want rc 75 reason empty, got rc=$RC reason=$GH_REST_REASON"
[ "$(cachefiles)" = 0 ] || bad "empty 2xx GET: a cache file was written for a body that was never stored"

# ══ 6. the key does not depend on the TOKEN VALUE: the SAME resource under a
#      different GH_TOKEN reuses the SAME cache entry (review F2: the key is
#      salted with GH_LIMIT_IDENTITY, a label like "app:owner/repo" — never
#      with the token itself) ════════════════════════════════════════════════
reset
export GH_TOKEN=ghp_first
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/9 >/dev/null 2>&1
export GH_TOKEN=ghp_second
fx 304 ''
gh_rest GET repos/o/r/pulls/9 > "$T/out" 2>/dev/null; RC=$?
if [ "$RC" = 0 ] && [ "$(cat "$T/out")" = '{"a":1}' ]; then ok
else bad "token-independent key: a second GH_TOKEN did not hit the first identity's cache entry (rc=$RC)"; fi
unset GH_TOKEN

# ══ 6b. ...but a different GH_LIMIT_IDENTITY LABEL is a different key on
# purpose (review F2): each identity gets its own entry, so a permissions-
# dependent representation can never replay across identities.
reset
export GH_LIMIT_IDENTITY="pat:o/r"
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/9 >/dev/null 2>&1
[ "$(cachefiles)" = 1 ] || bad "GH_LIMIT_IDENTITY setup: expected one cache file"
export GH_LIMIT_IDENTITY="app:o/r"
fx 200 '{"a":2}' '"v2"'
gh_rest GET repos/o/r/pulls/9 >/dev/null 2>&1
[ "$(cachefiles)" = 2 ] \
  && ok || bad "a different GH_LIMIT_IDENTITY must key a separate entry, got $(cachefiles) file(s)"
unset GH_LIMIT_IDENTITY

# ══ 7. two different paths never collide on one key ═════════════════════════
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
fx 200 '{"b":2}' '"v2"'
gh_rest GET repos/o/r/pulls/8 >/dev/null 2>&1
[ "$(cachefiles)" = 2 ] || bad "two distinct paths must produce two cache files, got $(cachefiles)"

# ══ 8. the TTL/size sweep: only the old entries go, never the newest ════════
reset
export GH_ETAG_TTL_H=1
fx 200 '{"old":1}' '"v-old"'
gh_rest GET repos/o/r/pulls/1 >/dev/null 2>&1
OLDF=$(find "$T/h/state/gh-etag" -maxdepth 1 -type f ! -name '.*')
touch -t 202001010000 "$OLDF" 2>/dev/null || touch -d '2020-01-01' "$OLDF" 2>/dev/null
fx 200 '{"new":1}' '"v-new"'
gh_rest GET repos/o/r/pulls/2 >/dev/null 2>&1
rm -f "$T/h/state/gh-etag/.swept"
_gh_etag_sweep
[ "$(cachefiles)" = 1 ] || bad "TTL sweep: want exactly 1 survivor (the new one), got $(cachefiles)"
NEWF=$(find "$T/h/state/gh-etag" -maxdepth 1 -type f ! -name '.*')
[ -n "$NEWF" ] && grep -q '"v-new"' "$NEWF" 2>/dev/null && ok || bad "TTL sweep: the survivor is not the newest entry"
unset GH_ETAG_TTL_H
# the once-per-hour stamp: a second call right after must not re-sweep (the
# stamp file itself must not be treated as a cache entry to prune)
reset
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/1 >/dev/null 2>&1
_gh_etag_sweep
BEFORE=$(cachefiles)
rm -f "$T/h/state/gh-etag"/[0-9a-f]*   # simulate: nothing left to sweep, stamp is fresh
touch "$T/h/state/gh-etag/x" 2>/dev/null
_gh_etag_sweep
[ -f "$T/h/state/gh-etag/x" ] && ok || bad "the sweep ran again inside the same hour and touched a file it should have left alone"
# size cap: GH_ETAG_MAX keeps only the newest N
reset
export GH_ETAG_MAX=2
i=1
while [ "$i" -le 4 ]; do
  fx 200 "{\"n\":$i}" "\"v$i\""
  gh_rest GET "repos/o/r/pulls/$i" >/dev/null 2>&1
  i=$((i+1))
done
[ "$(cachefiles)" = 4 ] || bad "size cap setup: expected 4 entries before any sweep, got $(cachefiles)"
rm -f "$T/h/state/gh-etag/.swept"
_gh_etag_sweep
[ "$(cachefiles)" = 2 ] || bad "size cap: want exactly GH_ETAG_MAX=2 survivors, got $(cachefiles)"
grep -ql '"v4"' "$T/h/state/gh-etag"/[0-9a-f]* 2>/dev/null && ok || bad "size cap: the newest entry (v4) did not survive"
unset GH_ETAG_MAX

# ══ 8b. F1 (review round 2): a GET with NO report armed (no GH_ETAG_COUNT_FILE
# exported — the shape 14 of the 17 gh_rest-reading bin/*.sh scripts are in,
# since only 4 lanes call gh_rest_etag_report) must leave NOTHING in $TMPDIR.
# Before the fix, every process's every GET wrote gh-etag-count.$$ and only
# the report ever deleted it — an unbounded leak on every box that never
# calls the report. This is the exact repro the review gave: a stub 200 GET
# with an ETag, no GH_ETAG_COUNT_FILE, then `ls "$TMPDIR"/gh-etag-count.*`.
reset
BEFORE_COUNT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gh-etag-count.*' 2>/dev/null | wc -l | tr -d ' ')
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/1 >/dev/null 2>&1
fx 304 ''
gh_rest GET repos/o/r/pulls/1 >/dev/null 2>&1
AFTER_COUNT=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gh-etag-count.*' 2>/dev/null | wc -l | tr -d ' ')
[ "$AFTER_COUNT" = "$BEFORE_COUNT" ] \
  && ok || bad "unarmed GETs must leave no counter file in \$TMPDIR (before=$BEFORE_COUNT after=$AFTER_COUNT)"

# ══ 9. gh_rest_etag_report: one line, then the counters reset ═══════════════
reset
export GH_ETAG_COUNT_FILE="$T/counter-9"
rm -f "$T/h/logs/gh-rate.log"
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/1 >/dev/null 2>&1
fx 304 ''
gh_rest GET repos/o/r/pulls/1 >/dev/null 2>&1
gh_rest_etag_report demo-lane
LINE=$(cat "$T/h/logs/gh-rate.log" 2>/dev/null)
case "$LINE" in
  *"gh-etag lane=demo-lane fetched=1 cached=1"*) ok ;;
  *) bad "report line: want 'gh-etag lane=demo-lane fetched=1 cached=1', got '$LINE'" ;;
esac
[ ! -e "$GH_ETAG_COUNT_FILE" ] \
  && ok || bad "report: the counter file was not cleared after flushing"
# a second report with nothing in between must read as 0/0, not repeat the
# first report's numbers — proves the counter file, not a leftover variable
# or a re-read of the same evidence, is what gh_rest_etag_report consults.
gh_rest_etag_report demo-lane
LINE2=$(tail -1 "$T/h/logs/gh-rate.log" 2>/dev/null)
case "$LINE2" in
  *"gh-etag lane=demo-lane fetched=0 cached=0"*) ok ;;
  *) bad "report: a second call with nothing new must read fetched=0 cached=0, got '$LINE2'" ;;
esac

# ══ 9b. B2 (review): the dominant caller — mc_pr_view, always `$( )` — must
# still be counted. bin/lib/merge-conductor-lib.sh's mc_rest_pr_json is the
# one gh_rest call every mc_pr_view read makes; before the review fix it ran
# `b=$(gh_rest GET …)`, which is its own subshell, so the counters died there
# even with the choke-point fix in gh_rest itself. This drives the REAL
# caller, not a stand-in for it.
MCLIB="$DIR/bin/lib/merge-conductor-lib.sh"
if [ -r "$MCLIB" ]; then
  reset
  export GH_ETAG_COUNT_FILE="$T/counter-9b"
  # shellcheck source=/dev/null
  . "$MCLIB"
  fx 200 '{"state":"open","merged_at":null,"closed_at":null,"merge_commit_sha":null,"mergeable":true,"mergeable_state":"clean","labels":[]}' '"v1"'
  O=$(mc_pr_view "https://github.com/o/r/pull/9" '.STATE' 2>/dev/null)
  [ "$O" = OPEN ] || bad "mc_pr_view fresh read: got '$O'"
  fx 304 ''
  O2=$(mc_pr_view "https://github.com/o/r/pull/9" '.STATE' 2>/dev/null)
  [ "$O2" = OPEN ] || bad "mc_pr_view cache-hit read: got '$O2'"
  gh_rest_etag_report mc-probe
  LINE3=$(tail -1 "$T/h/logs/gh-rate.log" 2>/dev/null)
  case "$LINE3" in
    *"gh-etag lane=mc-probe fetched=1 cached=1"*) ok ;;
    *) bad "mc_pr_view: want 'gh-etag lane=mc-probe fetched=1 cached=1', got '$LINE3'" ;;
  esac
else
  echo "merge-conductor-lib.sh not found — skipping section 9b"
fi

# ══ 10. mutation checks (D1), same shape as gh-rest-lib-test.sh's block 10 ══
cat > "$T/core.sh" <<'CORE'
set -uo pipefail
LIB=$1; ELIB=$2; T=$3; LABEL=$4
export HARNESS="$T/h-$LABEL"
mkdir -p "$HARNESS/state"
F=0
say() { F=$((F + 1)); echo "  core($LABEL): $1"; }
GH_REST_ETAG_LIB=""
. "$ELIB" || { echo "  core($LABEL): cannot source $ELIB"; exit 9; }
GH_REST_LIB=""
. "$LIB" || { echo "  core($LABEL): cannot source $LIB"; exit 9; }
rm -rf "$T/fx"; mkdir -p "$T/fx"
fx() {
  local f="$T/fx/01" rc
  { printf 'HTTP/2.0 %s Status\r\n' "$1"
    [ -n "${3:-}" ] && printf 'ETag: %s\r\n' "$3"
    printf '\r\n%s' "${2:-}"
  } > "$f"
  rc=0; case "$1" in 2*) rc=0 ;; *) rc=1 ;; esac
  printf '%s' "$rc" > "$f.rc"
}
rm -f "$T/gh-calls.txt"
fx 200 '{"a":1}' '"v1"'
O=$(gh_rest GET repos/o/r/pulls/7 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$O" = '{"a":1}' ] || say "fresh 200 row (rc=$RC out='$O')"
N=$(find "$HARNESS/state/gh-etag" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 1 ] || say "a fresh 200 with an ETag must store one cache file (got $N)"
rm -f "$T/fx"/*
fx 304 ''
gh_rest GET repos/o/r/pulls/7 > "$T/out" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = '{"a":1}' ] && [ "$GH_REST_REASON" = cached ] || say "304 cache-hit row (rc=$RC reason=$GH_REST_REASON out='$(cat "$T/out")')"
rm -rf "$HARNESS/state/gh-etag"
rm -f "$T/fx"/*
fx 304 ''
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1; RC=$?
[ "$RC" = 75 ] && [ "$GH_REST_REASON" = cache-miss ] || say "304 cache-miss row (rc=$RC reason=$GH_REST_REASON)"
rm -f "$T/gh-calls.txt"
fx 200 '{"c":1}' '"vc"'
gh_rest GET repos/o/r/pulls/9 >/dev/null 2>&1
export GH_ETAG=0
fx 200 '{"c":1}' '"vc"'
gh_rest GET repos/o/r/pulls/9 >/dev/null 2>&1
grep -q 'If-None-Match' "$T/gh-calls.txt" 2>/dev/null && say "GH_ETAG=0 kill-switch row: an If-None-Match header went out despite GH_ETAG=0"
unset GH_ETAG
rm -rf "$HARNESS/state/gh-etag"
rm -f "$T/fx"/*
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
KEY=$(_gh_etag_key GET repos/o/r/pulls/7)
_gh_etag_on_304 "$KEY" '"v2"' >/dev/null 2>&1
[ "$?" = 1 ] || say "etag-consistency row: on_304 with an etag nobody sent must be a miss (rc 1)"
CF=$(find "$HARNESS/state/gh-etag" -maxdepth 1 -type f ! -name '.*' 2>/dev/null)
rm -f "$CF" && mkdir "$CF" 2>/dev/null
_gh_etag_on_304 "$KEY" '"v1"' > "$T/out" 2>/dev/null
[ "$?" = 1 ] && [ -z "$(cat "$T/out")" ] || say "unreadable-entry row: on_304 must miss, not rc 0 with an empty body"
rmdir "$CF" 2>/dev/null
# the directory trick above consumed the entry entirely (rm -f then rmdir): a
# fresh one is needed for the truncated-entry row (review F2, round 2) —
# `tail -n +2` SUCCEEDS on a file holding only the etag line, with an empty
# capture, so this is the one row the guard right after the read exists for.
rm -f "$T/fx"/*
fx 200 '{"a":1}' '"v1"'
gh_rest GET repos/o/r/pulls/7 >/dev/null 2>&1
printf '"v1"\n' > "$CF"
_gh_etag_on_304 "$KEY" '"v1"' > "$T/out" 2>/dev/null
RC2=$?
[ "$RC2" = 1 ] && [ -z "$(cat "$T/out")" ] || say "truncated-entry row: on_304 must miss when the entry has only the etag line, not rc 0 empty"
exit "$F"
CORE
ELIB="$DIR/bin/lib/gh-rest-etag.sh"
mkdir -p "$T/mut"
if bash "$T/core.sh" "$LIB" "$ELIB" "$T" real >"$T/core.log" 2>&1; then ok
else bad "the mutation runner is red against the REAL libraries: $(cat "$T/core.log")"; fi

mut() { # mut <n> <label> <target: lib|etaglib> <sed expression>
  local n=$1 label=$2 target=$3 expr=$4
  local src dst
  if [ "$target" = etaglib ]; then src="$ELIB"; else src="$LIB"; fi
  dst="$T/mut/m$n.sh"
  cp "$src" "$dst" 2>/dev/null || { bad "mutant $n ($label): no library to mutate"; return; }
  sed -i "$expr" "$dst"
  if cmp -s "$src" "$dst"; then
    bad "mutant $n ($label): the mutation changed nothing — the row it guards is untested"
    return
  fi
  local runlib runelib
  if [ "$target" = etaglib ]; then runlib="$LIB"; runelib="$dst"; else runlib="$dst"; runelib="$ELIB"; fi
  if bash "$T/core.sh" "$runlib" "$runelib" "$T" "m$n" >/dev/null 2>&1; then
    bad "mutant $n ($label): the suite stayed GREEN under the mutation"
  else
    echo "mutant $n caught ($label)"; ok
  fi
}
mut 1 '304 with no cache answers success instead of cache-miss' etaglib 's/\[ -r "\$f" \] || return 1/[ -r "$f" ] || return 0/'
mut 2 'GH_ETAG=0 stops disabling the header' gh 's/\[ "\${GH_ETAG:-1}" != 0 \]/true/'
mut 3 'the etag-consistency check on a 304 replay is dropped' etaglib \
  's/\[ -n "\$cur" \] && \[ "\$cur" = "\${2:-}" \] || return 1/true/'
mut 4 'an entry truncated to just the etag line answers a hit with an empty body (review F2, round 2)' etaglib \
  's/\[ -n "\$body" \] || return 1/true/'

echo "gh-rest-etag: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
