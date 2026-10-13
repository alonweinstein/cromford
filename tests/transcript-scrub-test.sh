#!/bin/bash
# tests/transcript-scrub-test.sh — bin/transcript-scrub.sh, driven with
# secret-shaped fixtures.
#
# WHY THIS SUITE IS THE ONE THAT MATTERS MOST IN THIS FEATURE. Job transcripts
# take the single most sensitive artefact this fleet produces — a whole agent
# session, which routinely reads env files and echoes curl commands — and put it
# in a database the console renders in a browser. Every other test here checks
# that a feature works. This one checks that shipping it does not leak a live
# credential, and a scrubber nobody drove with a real-looking token is a scrubber
# nobody has any reason to believe.
#
# Driven, never grepped: `grep -q Bearer bin/transcript-scrub.sh` passes on a
# regex that matches nothing.
# Run from anywhere: tests/transcript-scrub-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A fixture env dir shaped like a real one: KEY=VALUE files, a quoted value, a
# numeric setting, an unfilled placeholder, and env/.watchdog-secret — a DOTFILE
# holding a bare secret with NO trailing newline, which is exactly how
# bin/watchdog-ping.sh documents provisioning it.
cat > "$T/env/global.env" <<'EOF'
# comment line
HARNESS_SECRET=Zx9QwertyLongFleetSecret
CONSOLE_URL=https://harness-console.example.workers.dev
QUOTED_TOKEN="qtLongQuotedSecretValue"
MODEL_COOLDOWN_SECS=21600
UNFILLED=<your-token-here>
SHORT=abc
EOF
cat > "$T/env/project.env" <<'EOF'
PROJECT_2_INTERNAL_API_TOKEN=taInternalTokenAbcdef123456
EOF
printf 'watchdogPingSecretNoNewline' > "$T/env/.watchdog-secret"

scrub() { HARNESS_ENV_DIR="$T/env" TRANSCRIPT_SCRUB_COUNT_FILE="$T/count" \
  bash "$DIR/bin/transcript-scrub.sh"; }

# --- 1. layer 1: literal env values, wherever they appear --------------------
# Not "in an assignment" and not "after a known prefix" — ANYWHERE. An agent
# session pastes a secret into prose, into a URL and into a shell command, and a
# scrubber that only understands one of those shapes is a scrubber that leaks.
OUT=$(printf 'the secret is Zx9QwertyLongFleetSecret in prose\ncurl https://x/api?k=Zx9QwertyLongFleetSecret\nexport H=Zx9QwertyLongFleetSecret\n' | scrub)
case "$OUT" in *Zx9QwertyLongFleetSecret*) bad "an env value survived in: $OUT" ;; *) ok ;; esac
[ "$(printf '%s' "$OUT" | grep -c 'REDACTED')" = 3 ] && ok || bad "expected 3 redactions, got: $OUT"

OUT=$(printf 'token qtLongQuotedSecretValue here\n' | scrub)
case "$OUT" in *qtLongQuotedSecretValue*) bad "a QUOTED env value survived unquoting: $OUT" ;; *) ok ;; esac

OUT=$(printf 'board token taInternalTokenAbcdef123456 used\n' | scrub)
case "$OUT" in *taInternalTokenAbcdef123456*) bad "a per-project env value survived: $OUT" ;; *) ok ;; esac

# THE DOTFILE. env/.watchdog-secret is a dotfile whose whole content is one
# secret with no trailing newline: a plain glob misses the file and a plain read
# loop drops its last (only) line. Both bugs leak the same secret silently.
OUT=$(printf 'ping with watchdogPingSecretNoNewline now\n' | scrub)
case "$OUT" in *watchdogPingSecretNoNewline*) bad "the bare-secret dotfile leaked: $OUT" ;; *) ok ;; esac

# --- 2. what must NOT be redacted -------------------------------------------
# Over-redaction is the intended failure direction, but not to the point of
# uselessness: a numeric setting is a knob, not a credential, and redacting
# every "21600" in a transcript would gut it to protect nothing.
OUT=$(printf 'MODEL_COOLDOWN_SECS is 21600 seconds\n' | scrub)
case "$OUT" in *21600*) ok ;; *) bad "a pure-numeric env value was treated as a secret: $OUT" ;; esac
# A placeholder in a half-filled env file is not a secret, and redacting it
# would HIDE the fact that the var is unset.
OUT=$(printf 'the var still reads <your-token-here> so it is unset\n' | scrub)
case "$OUT" in *'<your-token-here>'*) ok ;; *) bad "an unfilled placeholder was redacted, hiding that it is unset: $OUT" ;; esac
# A short value is below the floor, because "abc" appears in half the English
# language and redacting it destroys the transcript.
OUT=$(printf 'the abc of it\n' | scrub)
case "$OUT" in *'the abc of it'*) ok ;; *) bad "a 3-char env value was redacted: $OUT" ;; esac

# --- 3. layer 2: shapes this box has never seen ------------------------------
# The credential an agent read out of a repo, a CI log or another machine is not
# in this box's env dir, so layer 1 cannot know it. These are the shapes.
shape() { # shape <input> <must-not-contain> <label>
  local out; out=$(printf '%s\n' "$1" | scrub)
  case "$out" in *"$2"*) bad "$3 survived: $out" ;; *)
    case "$out" in *REDACTED*) ok ;; *) bad "$3 was neither redacted nor kept: $out" ;; esac ;;
  esac
}
shape 'curl -H "authorization: Bearer eyJhbGciOiJIUzI1NiJ9payloadpart.sigsigsig" x' 'eyJhbGciOiJIUzI1NiJ9payloadpart' 'a bearer header'
shape 'GET /api/dash?s=aVerySecretQueryParam&limit=5' 'aVerySecretQueryParam' 'an ?s= query param'
shape 'CRON_SECRET=hunter2plusmore' 'hunter2plusmore' 'a KEY=VALUE with a secret-shaped name'
shape 'export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz1234' 'abcdefghijklmnopqrstuvwxyz1234' 'a GitHub PAT'
shape 'ANTHROPIC key sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA' 'sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA' 'an sk- key'
shape 'slack xoxb-1234567890-abcdefghijk' 'xoxb-1234567890-abcdefghijk' 'a slack token'
shape 'aws AKIAIOSFODNN7EXAMPLE here' 'AKIAIOSFODNN7EXAMPLE' 'an AWS access key id'
shape 'authorization: tokenvaluegoeshere123' 'tokenvaluegoeshere123' 'a bare authorization header'
shape '-----BEGIN RSA PRIVATE KEY-----' 'BEGIN RSA PRIVATE KEY' 'a PEM header'

# The LABEL survives even when the value does not: a reader has to be able to
# see that the session set CRON_SECRET without learning what it is.
OUT=$(printf 'CRON_SECRET=hunter2plusmore\n' | scrub)
case "$OUT" in CRON_SECRET=*) ok ;; *) bad "the whole assignment was destroyed, not just its value: $OUT" ;; esac

# --- 4. the count is honest --------------------------------------------------
# It is rendered in the transcript header, so it has to mean something: the
# number of values THIS run replaced, not the number of markers in the output.
printf 'already [REDACTED] once, and now Zx9QwertyLongFleetSecret\n' | scrub >/dev/null
[ "$(cat "$T/count")" = 1 ] && ok || bad "the count double-counted a pre-existing marker: $(cat "$T/count")"
printf 'nothing sensitive at all\n' | scrub >/dev/null
[ "$(cat "$T/count")" = 0 ] && ok || bad "a clean input reported $(cat "$T/count") redactions"

# --- 5. metacharacters in a secret must not break the scrub ------------------
# A value containing . * / [ ] is a valid secret and an invalid regex. If the
# escaping is wrong the sed script fails to parse and the WHOLE scrub falls
# through — every secret in the file ships intact, which is the exact failure
# this layer exists to prevent, arriving silently.
mkdir -p "$T/env2"
printf 'WEIRD=a.b*c/d[e]f^g$h\\i\nOTHER=plainSecretValue123\n' > "$T/env2/x.env"
OUT=$(printf 'here is a.b*c/d[e]f^g$h\\i and plainSecretValue123\n' \
  | HARNESS_ENV_DIR="$T/env2" bash "$DIR/bin/transcript-scrub.sh")
case "$OUT" in *'a.b*c/d[e]f'*) bad "a metacharacter-laden secret survived: $OUT" ;; *) ok ;; esac
case "$OUT" in *plainSecretValue123*) bad "one bad needle broke the whole scrub, leaking a normal secret: $OUT" ;; *) ok ;; esac

# --- 6. no env dir at all ----------------------------------------------------
# The hub, a fly builder mid-provision, or a test box. Layer 2 must still run:
# degrading to "no scrubbing" the moment the env dir is absent would be the
# worst possible default.
OUT=$(printf 'Bearer eyJhbGciOiJIUzI1NiJ9payloadpart.sigsigsig\n' \
  | HARNESS_ENV_DIR="$T/nope" bash "$DIR/bin/transcript-scrub.sh")
case "$OUT" in *REDACTED*) ok ;; *) bad "with no env dir the shape layer stopped working: $OUT" ;; esac

# --- 7. it is a filter, not a rewriter ---------------------------------------
# Clean text must come out byte-identical, or every transcript in the console is
# subtly not what the session said.
IN=$(printf 'line one\n  indented two\n\nline four with unicode → ← ·\n')
OUT=$(printf '%s\n' "$IN" | scrub)
[ "$OUT" = "$IN" ] && ok || bad "clean text was altered by the scrub"

echo "transcript-scrub-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
