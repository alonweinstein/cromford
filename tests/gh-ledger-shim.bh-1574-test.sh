#!/bin/bash
# tests/gh-ledger-shim.bh-1574-test.sh — BH-1574: bin/gh-ledger/gh, the PATH-first
# `gh` that ledgers every raw gh invocation.
#
# WHAT IS BEING PINNED (2026-09-23, the gh-reads audit). The #1484 ledger saw
# ~1,400 counted calls an hour on the hub App bucket; ~2,000 more an hour were
# raw `gh` calls outside bin/lib/gh-rest*.sh, which nothing wrote down. The shim
# sits first on PATH on the hub, the boxes and the Fly builders, runs the real
# binary with GH_DEBUG=api, strips gh's HTTP trace out of stderr, and writes one
# ledger row per HTTP request — with the rate-limit BUCKET GitHub itself named in
# X-RateLimit-Resource, so a `gh pr view` lands as graphql and a `gh pr diff` as
# core instead of both being guessed.
#
# THE SHIM MUST NEVER BE THE REASON gh FAILS, so most of this file is about what
# it must leave alone:
#   1. stdout is byte-identical, stderr is gh's own lines only, rc is gh's rc;
#   2. a ledger that cannot be written costs a row, never the command;
#   3. `auth`, a caller's own GH_DEBUG, the kill switch, a nested call and
#      gh_rest's own `api -i -X` (already ledgered by gh-rest-ledger.sh) are
#      passed straight to the real binary, untouched;
#   4. the real binary is found past the shim's own dir and past the lane fence
#      (bin/lane-shims/, whose gh execs the next gh on PATH — us);
#   5. stdin reaches the real binary.
#
# Nothing touches the network. The real `gh` is a stub that, under GH_DEBUG=api,
# prints the exact trace shape gh 2.101 prints (captured 2026-09-23 on a live
# `gh pr list`), plus one genuine stderr line and a known stdout.
#
# Run from anywhere: bash tests/gh-ledger-shim.bh-1574-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SHIM="$DIR/bin/gh-ledger/gh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1790143200   # determinism: ok pinned; the stub's reset headers are derived from it
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/flags" "$T/tmp" "$T/real" "$T/lane" "$T/fence"
export TMPDIR="$T/tmp"
export GH_STUB_DIR="$T"
unset GH_TOKEN GH_DEBUG HARNESS_LANE HARNESS_LANE_PROJECT PROJECT GH_LEDGER_OFF GH_LEDGER_DEPTH GH_LEDGER_BY_CALLER
LED="$T/h/state/gh-rest-ledger"

# ── the real `gh`: records what it was given, prints a gh-2.101-shaped trace ──
cat > "$T/real/gh" <<STUB
#!/bin/bash
D="\$GH_STUB_DIR"
printf 'argv=%s|GH_DEBUG=%s\n' "\$*" "\${GH_DEBUG:-}" >> "\$D/real-calls.txt"
case " \$* " in *" --input - "*) cat > "\$D/stdin.txt" ;; esac
MODE="\${GH_STUB_MODE:-graphql}"
if [ "\$1 \$2" = "api -i" ]; then
  # gh_rest's shape: headers on STDOUT (-i), nothing on stderr.
  printf 'HTTP/2.0 200 OK\r\nx-ratelimit-remaining: 6100\r\nx-ratelimit-limit: 6600\r\nx-ratelimit-reset: $((NOW + 900))\r\nx-ratelimit-resource: core\r\nx-ratelimit-used: 500\r\n\r\n{"ok":true}'
  exit 0
fi
if [ "\${GH_DEBUG:-}" = api ]; then
  printf '[git remote -v]\n[git config --get-regexp ^remote\\\\..*\\\\.gh-resolved\$]\n' >&2
  if [ "\$MODE" = graphql ]; then
    cat >&2 <<'EOF'
* Request at 2026-09-23 03:00:00.000000 +0000 UTC m=+0.088895876
* Request to https://api.github.com/graphql
> POST /graphql HTTP/1.1
> Host: api.github.com
> Authorization: token ████████████████████

{
  "query": "query PullRequestByNumber(\$owner: String!) { repository { pullRequest { state } } }"
}

< HTTP/2.0 200 OK
< X-Ratelimit-Limit: 5000
< X-Ratelimit-Remaining: 4920
< X-Ratelimit-Reset: $((NOW + 1146))
< X-Ratelimit-Resource: graphql
< X-Ratelimit-Used: 80

{
  "data": {}
}

* Request took 466.274875ms
EOF
  else
    cat >&2 <<'EOF'
* Request at 2026-09-23 03:00:01.000000 +0000 UTC m=+0.042467085
* Request to https://api.github.com/repos/o/r/pulls/12
> GET /repos/o/r/pulls/12 HTTP/1.1
> Host: api.github.com

< HTTP/2.0 404 Not Found
< X-Ratelimit-Limit: 6600
< X-Ratelimit-Remaining: 6000
< X-Ratelimit-Reset: $((NOW + 900))
< X-Ratelimit-Resource: core
< X-Ratelimit-Used: 600

{
  "message": "Not Found"
}

* Request took 275.443541ms
EOF
  fi
fi
printf 'warning: the real stderr line\n' >&2
printf 'STDOUT-LINE-1\nSTDOUT-LINE-2'
exit "\${GH_STUB_RC:-0}"
STUB
chmod +x "$T/real/gh"

# A lane script that calls gh the way a lane does: by name, not exec, so the
# shim's parent is this script and the ledger names it.
cat > "$T/lane/my-lane.sh" <<'SH'
#!/bin/bash
gh "$@"
exit $?
SH
chmod +x "$T/lane/my-lane.sh"

SHIMDIR="$(dirname "$SHIM")"
P0="$SHIMDIR:$T/real:/usr/bin:/bin"
run() { # run <args…> — through a lane script, PATH shim-first; out/err/rc to files
  env PATH="$P0" "$T/lane/my-lane.sh" "$@" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
rows() { cat "$LED"/*.tsv 2>/dev/null; }
col() { rows | awk -F'\t' -v c="$1" 'NR==1{print $c}'; }
reset() {
  [ -e "$LED" ] && scratch_rm "$LED"
  rm -f "$T/real-calls.txt" "$T/stdin.txt" "$T/h/flags/gh-ledger-off"
}
printf 'STDOUT-LINE-1\nSTDOUT-LINE-2' > "$T/want-out"
printf 'warning: the real stderr line\n' > "$T/want-err"

[ -x "$SHIM" ] && ok || bad "0: bin/gh-ledger/gh must exist and be executable"
[ "$(ls -A "$SHIMDIR" 2>/dev/null | tr '\n' ' ')" = "gh " ] && ok \
  || bad "0b: bin/gh-ledger/ must hold ONLY gh — it is prepended to PATH, so anything else in it shadows a real command (got: $(ls -A "$SHIMDIR" 2>/dev/null | tr '\n' ' '))"

# ══ 1. a raw `gh pr view`: output untouched, one graphql row ═════════════════
reset
GH_STUB_RC=3 run pr view 12 --json state
cmp -s "$T/out" "$T/want-out" && ok || bad "1a: stdout must be byte-identical, got: $(od -c "$T/out" | head -3)"
cmp -s "$T/err" "$T/want-err" && ok || bad "1b: stderr must be gh's own line only (trace + [git …] stripped), got:
$(cat "$T/err")"
[ "$(cat "$T/rc")" = 3 ] && ok || bad "1c: the real binary's rc (3) must pass through, got $(cat "$T/rc")"
[ "$(rows | grep -c .)" = 1 ] && ok || bad "1d: ONE HTTP request = ONE ledger row, got:
$(rows)"
[ "$(col 11)" = graphql ] && ok || bad "1e: the bucket must come from X-RateLimit-Resource (graphql), got '$(col 11)'"
[ "$(col 4) $(col 5) $(col 6) $(col 7)" = "POST graphql 200 1" ] && ok \
  || bad "1f: method/path-class/status/counted must be POST graphql 200 1 (no leading slash, the class gh_rest writes), got '$(col 4) $(col 5) $(col 6) $(col 7)'"
[ "$(col 8) $(col 9)" = "4920 $((NOW + 1146))" ] && ok || bad "1g: remaining/reset from the headers, got '$(col 8) $(col 9)'"
[ "$(col 12) $(col 13) $(col 14)" = "gh 80 5000" ] && ok \
  || bad "1h: source=gh, used and limit from the headers, got '$(col 12) $(col 13) $(col 14)'"
[ "$(col 2)" = my-lane.sh ] && ok || bad "1i: the caller is the PARENT SCRIPT (my-lane.sh), got '$(col 2)'"
grep -q 'GH_DEBUG=api' "$T/real-calls.txt" && ok || bad "1j: the real binary must be run with GH_DEBUG=api, got: $(cat "$T/real-calls.txt")"
grep -q 'argv=pr view 12 --json state|' "$T/real-calls.txt" && ok || bad "1k: argv must reach the real binary unchanged, got: $(cat "$T/real-calls.txt")"
# SPEC CHANGE (rebase onto BH-1585): main now files a GraphQL answer under its
# own meter, `graphql-<token bucket>`, in gh_quota_bucket. Column 10 is still
# gh_quota_bucket's; for this graphql row that is graphql-pat-default.
[ "$(col 10)" = graphql-pat-default ] && ok || bad "1l: the token meter column is gh_quota_bucket's (BH-1585: graphql-<bucket> for a GraphQL answer), got '$(col 10)'"

# HARNESS_LANE wins over the parent's name, the same order _gh_led_write uses.
reset
HARNESS_LANE=merge-conductor HARNESS_LANE_PROJECT=project-4 run pr view 12
[ "$(col 2) $(col 3)" = "merge-conductor project-4" ] && ok || bad "1m: HARNESS_LANE/HARNESS_LANE_PROJECT name the row, got '$(col 2) $(col 3)'"

# ══ 2. a REST call through gh: bucket core, a 404 is still counted ══════════
reset
GH_STUB_MODE=rest GH_STUB_RC=1 run pr diff 12
[ "$(col 11) $(col 4) $(col 5) $(col 6) $(col 7)" = "core GET repos/o/r/pulls/N 404 1" ] && ok \
  || bad "2a: a REST request lands as core GET repos/o/r/pulls/N 404 counted (same class gh_rest writes), got '$(rows)'"
[ "$(cat "$T/rc")" = 1 ] && ok || bad "2b: rc 1 passes through, got $(cat "$T/rc")"
cmp -s "$T/err" "$T/want-err" && ok || bad "2c: stderr untouched on a failure too, got: $(cat "$T/err")"

# ══ 3. what the shim hands straight to gh, untouched ════════════════════════
reset
run auth token
grep -q 'argv=auth token|GH_DEBUG=$' "$T/real-calls.txt" && ok || bad "3a: \`auth\` goes straight through with no GH_DEBUG, got: $(cat "$T/real-calls.txt")"
[ -z "$(rows)" ] && ok || bad "3b: \`auth\` writes no row"
cmp -s "$T/out" "$T/want-out" && ok || bad "3c: \`auth token\` stdout must be untouched (fly-envbundle reads it)"

reset
GH_DEBUG=1 run pr view 12
grep -q 'GH_DEBUG=1$' "$T/real-calls.txt" && ok || bad "3d: a caller's own GH_DEBUG is left exactly as set, got: $(cat "$T/real-calls.txt")"
[ -z "$(rows)" ] && ok || bad "3e: and that call is not ledgered (its trace is the caller's to read)"

reset
touch "$T/h/flags/gh-ledger-off"
run pr view 12
grep -q 'GH_DEBUG=$' "$T/real-calls.txt" && ok || bad "3f: flags/gh-ledger-off passes through with no GH_DEBUG"
[ -z "$(rows)" ] && ok || bad "3g: flags/gh-ledger-off writes nothing"
reset
GH_LEDGER_OFF=1 run pr view 12
[ -z "$(rows)" ] && grep -q 'GH_DEBUG=$' "$T/real-calls.txt" && ok || bad "3h: GH_LEDGER_OFF=1 is the same switch"

# gh_rest's own call (gh-rest-ledger.sh already wrote its row) is NOT counted
# twice — but the marker only covers that exact shape, never a raw call.
reset
GH_LEDGER_BY_CALLER=1 run api -i -X GET repos/o/r/pulls/1
[ -z "$(rows)" ] && ok || bad "3i: gh_rest's \`api -i -X\` under GH_LEDGER_BY_CALLER must not be ledgered twice"
reset
GH_LEDGER_BY_CALLER=1 run pr view 12
[ "$(col 11)" = graphql ] && ok || bad "3j: the marker must NOT hide a raw call in the same shell, got '$(rows)'"

reset
GH_LEDGER_DEPTH=1 run pr view 12
[ -z "$(rows)" ] && grep -q 'GH_DEBUG=$' "$T/real-calls.txt" && ok || bad "3k: a nested call (GH_LEDGER_DEPTH) goes straight through"

# ══ 4. a ledger that cannot be written costs a row, never the command ═══════
reset
mkdir -p "$T/ro"; : > "$T/ro/state"   # state is a FILE, so state/gh-rest-ledger can never be created
HARNESS="$T/ro" GH_STUB_RC=5 run pr view 12
cmp -s "$T/out" "$T/want-out" && ok || bad "4a: stdout survives an unwritable ledger"
cmp -s "$T/err" "$T/want-err" && ok || bad "4b: stderr carries no shim noise when the ledger fails, got: $(cat "$T/err")"
[ "$(cat "$T/rc")" = 5 ] && ok || bad "4c: rc survives an unwritable ledger, got $(cat "$T/rc")"

# ══ 5. finding the real binary ══════════════════════════════════════════════
# The lane fence's own gh execs the next gh on PATH, which is us: a fence dir
# must be skipped, and the shim's own dir twice on PATH must not loop.
reset
printf '#!/bin/bash\necho FENCE-WAS-RUN >&2\nexit 99\n' > "$T/fence/gh"; chmod +x "$T/fence/gh"
: > "$T/fence/_fence.sh"
env PATH="$SHIMDIR:$SHIMDIR:$T/fence:$T/real:/usr/bin:/bin" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; rc=$?
[ "$rc" = 0 ] && cmp -s "$T/out" "$T/want-out" && ok || bad "5a: the real gh must be found past the shim dir (twice) and the fence dir, rc=$rc err=$(cat "$T/err")"
# A PATH with the tools the shim uses and no gh anywhere on it.
mkdir -p "$T/nogh"
for t in readlink; do ln -sf "$(command -v "$t")" "$T/nogh/$t"; done
env PATH="$SHIMDIR:$T/nogh" GH_LEDGER_FALLBACK=/nonexistent/gh "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; rc=$?
[ "$rc" = 127 ] && ok || bad "5b: no real gh anywhere is rc 127, got $rc"
grep -q 'gh-ledger' "$T/err" && ok || bad "5c: and it says who failed, got: $(cat "$T/err")"

# ══ 6. stdin reaches the real binary ════════════════════════════════════════
reset
printf '{"body":"from stdin"}' | env PATH="$P0" "$T/lane/my-lane.sh" api repos/o/r/issues --input - > "$T/out" 2> "$T/err"
[ "$(cat "$T/stdin.txt" 2>/dev/null)" = '{"body":"from stdin"}' ] && ok || bad "6a: stdin must reach the real binary, got '$(cat "$T/stdin.txt" 2>/dev/null)'"

# ══ 7. gh_rest's own rows carry the bucket too, and are not doubled ═════════
# gh_rest runs `gh api -i -X …` by name; with the shim first on PATH that call
# reaches the shim, and the ONLY row must be gh-rest-ledger.sh's (source rest).
reset
(
  export PATH="$P0"
  # shellcheck source=bin/lib/gh-rest.sh
  . "$DIR/bin/lib/gh-rest.sh"
  export GH_ETAG=0
  gh_rest GET repos/o/r/pulls/1 > "$T/out"
)
[ "$(rows | grep -c .)" = 1 ] && ok || bad "7a: a gh_rest call through the shim is ONE row, got:
$(rows)"
[ "$(col 11) $(col 12) $(col 13) $(col 14)" = "core rest 500 6600" ] && ok \
  || bad "7b: gh_rest's row names the bucket (core), its source (rest), used and limit, got '$(rows)'"
grep -q 'GH_DEBUG=$' "$T/real-calls.txt" && ok || bad "7c: gh_rest's call ran without GH_DEBUG (straight through), got: $(cat "$T/real-calls.txt")"

# ══ 8. two DIFFERENT copies of the shim on PATH (review round 1, item 1) ═════
# Two checkouts' bin/gh-ledger/ on one PATH (a worktree on a box prepending its
# own) exec'd each other for ever: each copy's "first gh that is not me" was the
# OTHER copy. Every copy must be skipped when resolving the real binary, and a
# nested call must still land on real gh. `timeout` turns a hang into rc 124.
reset
for c in c1 c2; do
  mkdir -p "$T/$c/bin/gh-ledger"
  cp "$SHIM" "$T/$c/bin/gh-ledger/gh"; chmod +x "$T/$c/bin/gh-ledger/gh"
  ln -s "$DIR/bin/lib" "$T/$c/bin/lib"
done
P2="$T/c1/bin/gh-ledger:$T/c2/bin/gh-ledger:$T/real:/usr/bin:/bin"
GH_STUB_RC=42 timeout 20 env PATH="$P2" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; rc=$?
[ "$rc" = 42 ] && ok || bad "8a: two shim copies on PATH must reach real gh (rc 42), got rc=$rc (124 = the exec loop) err=$(cat "$T/err")"
cmp -s "$T/out" "$T/want-out" && ok || bad "8b: stdout untouched through two copies"
[ "$(rows | grep -c .)" = 1 ] && ok || bad "8c: ONE row for one request — only the first copy ledgers, got:
$(rows)"
reset
GH_LEDGER_DEPTH=1 timeout 20 env PATH="$P2" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; rc=$?
[ "$rc" = 0 ] && cmp -s "$T/out" "$T/want-out" && ok \
  || bad "8d: a NESTED call (GH_LEDGER_DEPTH set) with two copies on PATH must exec real gh, got rc=$rc err=$(cat "$T/err")"

# ══ 9. an unknown trace format (review round 1, item 3) ════════════════════
# A gh whose GH_DEBUG trace is not the `* Request at … * Request took` shape the
# filter knows. The shim must find that out from a probe (a free `api
# rate_limit` under GH_DEBUG=api), then run the real call WITHOUT GH_DEBUG —
# stderr exactly gh's own, no trace text and no swallowed error — and write ONE
# row with status=unparsed. The verdict is cached per gh binary, so the probe
# runs once, not per call.
mkdir -p "$T/real2" "$T/h2/logs"
cat > "$T/real2/gh" <<'STUB'
#!/bin/bash
printf 'argv=%s|GH_DEBUG=%s\n' "$*" "${GH_DEBUG:-}" >> "$GH_STUB_DIR/real2-calls.txt"
if [ "${GH_DEBUG:-}" = api ]; then
  printf 'DEBUG >>> POST https://api.github.com/graphql\nDEBUG body: {"query":"secret-field-value"}\nDEBUG <<< 200 X-Ratelimit-Resource: graphql\n' >&2
fi
printf 'error: the real error line\n' >&2
printf 'OUT'
# rc 1, never 4: 4 is gh's own "not logged in" code, and an auth failure must
# not be what this case is about (round 2). The probe itself answers 0 — gh got
# an HTTP response, so its verdict on the format is one worth caching.
[ "$1 $2" = "api rate_limit" ] && exit 0
exit 1
STUB
chmod +x "$T/real2/gh"
P3="$SHIMDIR:$T/real2:/usr/bin:/bin"
LED2="$T/h2/state/gh-rest-ledger"
for i in 1 2; do
  HARNESS="$T/h2" env PATH="$P3" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; echo $? > "$T/rc"
done
printf 'error: the real error line\n' > "$T/want-err2"
cmp -s "$T/err" "$T/want-err2" && ok || bad "9a: an unknown trace format passes gh's own stderr through untouched and dumps no trace, got:
$(cat "$T/err")"
[ "$(cat "$T/out")" = OUT ] && [ "$(cat "$T/rc")" = 1 ] && ok || bad "9b: stdout and rc untouched, got '$(cat "$T/out")' rc $(cat "$T/rc")"
[ "$(cat "$LED2"/*.tsv 2>/dev/null | grep -c .)" = 2 ] && ok || bad "9c: ONE row per call (2 calls), got: $(cat "$LED2"/*.tsv 2>/dev/null)"
[ "$(cat "$LED2"/*.tsv 2>/dev/null | awk -F'\t' '{print $6}' | sort -u)" = unparsed ] && ok \
  || bad "9d: the rows say status=unparsed, got: $(cat "$LED2"/*.tsv 2>/dev/null)"
grep -q 'secret-field-value' "$LED2"/*.tsv "$T/err" 2>/dev/null && bad "9e: trace content reached stderr or the ledger" || ok
[ "$(grep -c 'argv=api rate_limit|GH_DEBUG=api' "$T/real2-calls.txt")" = 1 ] && ok \
  || bad "9f: the format probe runs ONCE per gh binary (cached), got: $(cat "$T/real2-calls.txt")"
[ "$(grep -c 'argv=pr view 12|GH_DEBUG=$' "$T/real2-calls.txt")" = 2 ] && ok \
  || bad "9g: the real call runs WITHOUT GH_DEBUG once the format is unknown, got: $(cat "$T/real2-calls.txt")"

# ══ 10. gh_rest never leaves the no-double-count marker behind ═════════════
# The gate exports GH_LEDGER_BY_CALLER for gh_rest's one request; if gh_rest
# returns before that request (mktemp failing), the marker must not stay
# exported, or a later raw `gh api -i -X` in the same shell goes unledgered.
OUTM=$(
  export PATH="$P0"
  # shellcheck source=bin/lib/gh-rest.sh
  . "$DIR/bin/lib/gh-rest.sh"
  export GH_ETAG=0
  TMPDIR="$T/no-such-dir" gh_rest GET repos/o/r/pulls/1 > /dev/null 2>&1; rc=$?
  printf '%s %s' "$rc" "${GH_LEDGER_BY_CALLER:-unset}"
)
[ "$OUTM" = "75 unset" ] && ok || bad "10a: a gh_rest that fails before its request (mktemp) must clear GH_LEDGER_BY_CALLER, got '$OUTM'"

# ══ 11. an UNAUTHENTICATED probe never condemns the binary (round 2) ════════
# `env -u GH_TOKEN gh api …` on a box with no keyring login (bin/merge-sweep.sh
# runs exactly that) answers rc 4 "please run gh auth login" with no trace at
# all. Round 1 cached that as `unknown` for the binary's whole life and every
# later call on the box went `unparsed`. A probe that did not get an HTTP
# response decides only its own call; the next authenticated call re-probes,
# is parsed and ledgered, and the cache never holds `unknown`.
mkdir -p "$T/real3" "$T/h3/logs"
cat > "$T/real3/gh" <<STUB
#!/bin/bash
printf 'argv=%s|GH_DEBUG=%s|TOKEN=%s\n' "\$*" "\${GH_DEBUG:-}" "\${GH_TOKEN:+set}" >> "\$GH_STUB_DIR/real3-calls.txt"
if [ -z "\${GH_TOKEN:-}" ]; then
  printf 'To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n' >&2
  exit 4
fi
if [ "\${GH_DEBUG:-}" = api ]; then
  cat >&2 <<'EOF'
* Request at 2026-09-23 03:00:00.000000 +0000 UTC m=+0.01
* Request to https://api.github.com/graphql
> POST /graphql HTTP/1.1

< HTTP/2.0 200 OK
< X-Ratelimit-Limit: 5000
< X-Ratelimit-Remaining: 4900
< X-Ratelimit-Reset: $((NOW + 1146))
< X-Ratelimit-Resource: graphql
< X-Ratelimit-Used: 100

* Request took 100ms
EOF
fi
printf 'OUT3'
exit 0
STUB
chmod +x "$T/real3/gh"
P4="$SHIMDIR:$T/real3:/usr/bin:/bin"
LED3="$T/h3/state/gh-rest-ledger"
FMT3="$T/h3/state/gh-ledger.trace-format"
HARNESS="$T/h3" env -u GH_TOKEN PATH="$P4" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; echo $? > "$T/rc"
[ "$(cat "$T/rc")" = 4 ] && grep -q 'gh auth login' "$T/err" && ok \
  || bad "11a: the unauthenticated call passes gh's own auth error and rc 4 through, got rc $(cat "$T/rc"): $(cat "$T/err")"
grep -q ' unknown' "$FMT3" 2>/dev/null && bad "11b: an unauthenticated probe must NOT cache 'unknown', got: $(cat "$FMT3")" || ok
HARNESS="$T/h3" GH_TOKEN=ghp_fixture env PATH="$P4" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; echo $? > "$T/rc"
L3=$(awk -F'\t' '$6 != "unparsed"' "$LED3"/*.tsv 2>/dev/null)
[ "$(printf '%s' "$L3" | awk -F'\t' 'NF{print $6, $11}')" = "200 graphql" ] && ok \
  || bad "11c: the next AUTHENTICATED call is parsed and ledgered (200 graphql), got: $(cat "$LED3"/*.tsv 2>/dev/null)"
[ "$(cat "$T/out")" = OUT3 ] && [ ! -s "$T/err" ] && ok || bad "11d: and its output is untouched, got '$(cat "$T/out")' err '$(cat "$T/err")'"
grep -q ' ok' "$FMT3" 2>/dev/null && ! grep -q ' unknown' "$FMT3" && ok \
  || bad "11e: the cache holds ok, never unknown, got: $(cat "$FMT3" 2>/dev/null)"

# ══ 12. `unknown` expires (round 2) ══════════════════════════════════════════
# No verdict is permanent: an `unknown` older than GH_LEDGER_UNKNOWN_TTL_S (the
# lib knob lib.gh-ledger.gh_ledger_unknown_ttl_s, code default 3600) is probed
# again; a fresh one is still honoured. The stub here speaks the known format,
# so a re-probe turns the cache back to ok and the call is parsed.
mkdir -p "$T/h4/state" "$T/h4/logs"
FMT4="$T/h4/state/gh-ledger.trace-format"
LED4="$T/h4/state/gh-rest-ledger"
ID=$(stat -Lc '%s:%Y' "$T/real/gh" 2>/dev/null || stat -Lf '%z:%m' "$T/real/gh")
REAL_NOW=$(date -u +%s)   # determinism: ok the shim compares against the live clock; ages are offsets from it, never calendar dates
printf '%s %s unknown %s\n' "$T/real/gh" "$ID" "$((REAL_NOW - 60))" > "$FMT4"
HARNESS="$T/h4" GH_LEDGER_UNKNOWN_TTL_S=3600 env PATH="$P0" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"
[ "$(awk -F'\t' '{print $6}' "$LED4"/*.tsv 2>/dev/null)" = unparsed ] && ok \
  || bad "12a: a FRESH unknown (60s old, TTL 3600) is honoured — unparsed, no re-probe, got: $(cat "$LED4"/*.tsv 2>/dev/null)"
[ -e "$LED4" ] && scratch_rm "$LED4"
printf '%s %s unknown %s\n' "$T/real/gh" "$ID" "$((REAL_NOW - 7200))" > "$FMT4"
HARNESS="$T/h4" GH_LEDGER_UNKNOWN_TTL_S=3600 env PATH="$P0" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"
[ "$(awk -F'\t' '{print $6, $11}' "$LED4"/*.tsv 2>/dev/null)" = "200 graphql" ] && ok \
  || bad "12b: an EXPIRED unknown (2h old, TTL 3600) is re-probed and the call parsed, got: $(cat "$LED4"/*.tsv 2>/dev/null)"
grep -q ' ok' "$FMT4" && ok || bad "12c: the re-probe rewrites the cache to ok, got: $(cat "$FMT4")"

# ══ 13. an expiring token's header is not an auth error (round 3) ════════════
# Every fine-grained PAT's response carries `Github-Authentication-Token-
# Expiration`. Round 2 grepped the WHOLE probe stderr — trace included — for
# "authentication", so `ok` was never cached and every gh call re-probed: one
# extra request and ~0.3 s per call, fleet-wide. A trace that shows the dated
# opener and the closer proves the format and is cached, whatever else it says.
mkdir -p "$T/real5" "$T/h5/logs"
cat > "$T/real5/gh" <<STUB
#!/bin/bash
printf 'argv=%s|GH_DEBUG=%s\n' "\$*" "\${GH_DEBUG:-}" >> "\$GH_STUB_DIR/real5-calls.txt"
if [ "\${GH_DEBUG:-}" = api ]; then
  cat >&2 <<'EOF'
* Request at 2026-09-23 03:00:00.000000 +0000 UTC m=+0.01
* Request to https://api.github.com/rate_limit
> GET /rate_limit HTTP/1.1
> Authorization: token ████████████████████

< HTTP/2.0 200 OK
< Github-Authentication-Token-Expiration: 2026-12-01 00:00:00 UTC
< X-Ratelimit-Limit: 5000
< X-Ratelimit-Remaining: 4999
< X-Ratelimit-Reset: $((NOW + 900))
< X-Ratelimit-Resource: core
< X-Ratelimit-Used: 1

* Request took 90ms
EOF
fi
printf 'OUT5'
exit 0
STUB
chmod +x "$T/real5/gh"
P5="$SHIMDIR:$T/real5:/usr/bin:/bin"
for i in 1 2; do
  HARNESS="$T/h5" env PATH="$P5" "$T/lane/my-lane.sh" api repos/o/r > "$T/out" 2> "$T/err"
done
grep -q ' ok ' "$T/h5/state/gh-ledger.trace-format" 2>/dev/null && ok \
  || bad "13a: a trace carrying Github-Authentication-Token-Expiration still proves the format — ok is cached, got: $(cat "$T/h5/state/gh-ledger.trace-format" 2>/dev/null)"
[ "$(grep -c 'argv=api rate_limit|' "$T/real5-calls.txt")" = 1 ] && ok \
  || bad "13b: the second call makes NO probe (one probe for two calls), got: $(cat "$T/real5-calls.txt")"
[ "$(cat "$T/out")" = OUT5 ] && [ ! -s "$T/err" ] && ok || bad "13c: output untouched, got '$(cat "$T/out")' err '$(cat "$T/err")'"

# ══ 14. a half-synced bin/ never kills the shim before gh runs (round 3) ═════
# _ghl_unknown_ttl resolves the knob through bin/lib/lane-gate.sh; a box whose
# bin/ arrived without jobs-client, or a lib_env_apply that exits (a required
# knob with no value), must cost the knob — the 3600 default — never the call.
# A FRESH unknown verdict is what makes the shim ask for the TTL at all.
ID2=$(stat -Lc '%s:%Y' "$T/real2/gh" 2>/dev/null || stat -Lf '%z:%m' "$T/real2/gh")
REAL_NOW2=$(date -u +%s)   # determinism: ok the shim compares against the live clock; the age is an offset from it
for variant in no-jobs-client exits; do
  H6="$T/h6-$variant"
  mkdir -p "$H6/bin/lib" "$H6/logs" "$H6/state"
  if [ "$variant" = no-jobs-client ]; then
    cp "$DIR/bin/lib/lane-gate.sh" "$H6/bin/lib/"
  else
    printf '#!/bin/bash\nlib_env_apply() { exit 3; }\n' > "$H6/bin/lib/lane-gate.sh"
  fi
  printf '%s %s unknown %s\n' "$T/real2/gh" "$ID2" "$((REAL_NOW2 - 60))" > "$H6/state/gh-ledger.trace-format"
  : > "$T/real2-calls.txt"
  HARNESS="$H6" env -u GH_LEDGER_UNKNOWN_TTL_S PATH="$P3" "$T/lane/my-lane.sh" pr view 12 > "$T/out" 2> "$T/err"; rc=$?
  [ "$rc" = 1 ] && [ "$(cat "$T/out")" = OUT ] && grep -q 'argv=pr view 12|' "$T/real2-calls.txt" && ok \
    || bad "14a/$variant: gh must still run (rc 1, OUT), got rc=$rc out='$(cat "$T/out")' err='$(cat "$T/err")'"
  grep -q 'argv=api rate_limit' "$T/real2-calls.txt" && bad "14b/$variant: a 60 s-old unknown under the 3600 fallback must not re-probe" || ok
  [ "$(awk -F'\t' '{print $6}' "$H6/state/gh-rest-ledger/"*.tsv 2>/dev/null)" = unparsed ] && ok \
    || bad "14c/$variant: one unparsed row, got: $(cat "$H6/state/gh-rest-ledger/"*.tsv 2>/dev/null)"
done

echo "gh-ledger-shim.bh-1574: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
