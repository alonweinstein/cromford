#!/bin/bash
# tests/internal-token-lib.bh-1953-test.sh — bin/lib/internal-token.sh is the one
# definition of the internal-token and app-base env-var patterns (BH-1953,
# BH-232.0), and bin/internal-token-for.sh resolves through it with the same
# stdout, rc and ALERTS text it had before.
#
# The lib cases feed real env-file shapes (quoted, unquoted, `export`, OTHER=x
# neighbours, a `_OLD` neighbour). The script cases run the REAL
# bin/internal-token-for.sh: copied with the lib, symlinked, and copied WITHOUT
# the lib, which must fail closed and say which file is missing.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/internal-token-lib.bh-1953-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/internal-token.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

[ -r "$LIB" ] && ok || bad "bin/lib/internal-token.sh is missing"

# run_fn <fn> <envfile> — prints "<rc>|<stdout>" from a fresh strict-mode shell
run_fn() {
  bash -c 'set -euo pipefail; . "$1"; out=$("$2" "$3") && rc=0 || rc=$?; printf "%s|%s" "$rc" "$out"' _ "$LIB" "$1" "$2" 2>/dev/null
}
E="$T/env"; mkdir -p "$E"

# ── S1: sourcing is side-effect free and safe under set -euo pipefail ────────
S1=$(cd "$T" && bash -c 'set -euo pipefail; before=$-; . "$1"; [ "$-" = "$before" ] || exit 9
  printf "%s\n%s\n" "$INTERNAL_TOKEN_RE" "$APP_BASE_RE"
  declare -F internal_token_var app_base_var internal_token_vars >/dev/null && echo fns' _ "$LIB" 2>&1)
eq "S1 source rc+output" "$?|$S1" "0|^[A-Z0-9_]*INTERNAL_API_TOKEN=
^[A-Z0-9_]+_(API|APP)_BASE=
fns"
[ ! -e "$T/logs" ] && [ ! -e "$T/ALERTS.log" ] && ok || bad "S1 sourcing wrote something"

# ── S2: the four live names, a digit prefix, and export each resolve ─────────
for n in project-1 TA project-3 project-4 project-32; do
  printf 'OTHER=x\n%s_INTERNAL_API_TOKEN="tok-secret-9"\nZ=1\n' "$n" > "$E/s2-$n.env"
  eq "S2 $n" "$(run_fn internal_token_var "$E/s2-$n.env")" "0|${n}_INTERNAL_API_TOKEN"
done
printf 'OTHER=x\nexport X_INTERNAL_API_TOKEN=tok-secret-9\n' > "$E/s2-exp.env"
eq "S2 export" "$(run_fn internal_token_var "$E/s2-exp.env")" "0|X_INTERNAL_API_TOKEN"

# ── S3: two tokens refuse, print nothing ─────────────────────────────────────
printf 'A_INTERNAL_API_TOKEN=a\nOTHER=x\nB_INTERNAL_API_TOKEN=b\n' > "$E/s3.env"
eq "S3 two tokens" "$(run_fn internal_token_var "$E/s3.env")" "2|"
eq "S3 plural lists both" "$(run_fn internal_token_vars "$E/s3.env")" "0|A_INTERNAL_API_TOKEN
B_INTERNAL_API_TOKEN"

# ── S4: a _OLD neighbour is not a token ──────────────────────────────────────
printf 'FOO_INTERNAL_API_TOKEN_OLD=junk\nproject-4_INTERNAL_API_TOKEN=v\n' > "$E/s4.env"
eq "S4 _OLD neighbour" "$(run_fn internal_token_var "$E/s4.env")" "0|PROJECT_4_INTERNAL_API_TOKEN"

# ── S5: empty / missing / same name twice ────────────────────────────────────
: > "$E/s5-empty.env"
eq "S5 empty" "$(run_fn internal_token_var "$E/s5-empty.env")" "1|"
eq "S5 missing" "$(run_fn internal_token_var "$E/nope.env")" "1|"
printf 'FOO_INTERNAL_API_TOKEN=a\nFOO_INTERNAL_API_TOKEN=b\n' > "$E/s5-dup.env"
eq "S5 same name twice" "$(run_fn internal_token_var "$E/s5-dup.env")" "2|"

# ── S6: app_base_var resolves each shape ─────────────────────────────────────
for v in PROJECT_1_API_BASE PROJECT_2_APP_BASE project-32_APP_BASE; do
  printf 'OTHER=x\n%s=https://a.example\n' "$v" > "$E/s6-$v.env"
  eq "S6 $v" "$(run_fn app_base_var "$E/s6-$v.env")" "0|$v"
done
printf 'export PROJECT_4_API_BASE=https://c.example\n' > "$E/s6-exp.env"
eq "S6 export" "$(run_fn app_base_var "$E/s6-exp.env")" "0|PROJECT_4_API_BASE"

# ── S7: app_base_var refusals ────────────────────────────────────────────────
printf 'X_API_BASE=1\nY_APP_BASE=2\n' > "$E/s7-two.env"
eq "S7 two bases" "$(run_fn app_base_var "$E/s7-two.env")" "2|"
printf 'FOO_API_BASE_OLD=1\nFOO_API_BASE_URL=3\nREAL_APP_BASE=2\n' > "$E/s7-old.env"
eq "S7 _OLD/_URL neighbours" "$(run_fn app_base_var "$E/s7-old.env")" "0|REAL_APP_BASE"
printf 'API_BASE=1\n' > "$E/s7-bare.env"
eq "S7 bare API_BASE" "$(run_fn app_base_var "$E/s7-bare.env")" "1|"
eq "S7 empty" "$(run_fn app_base_var "$E/s5-empty.env")" "1|"

# ── S8: the production entry point, copied with its lib ──────────────────────
H="$T/h"; mkdir -p "$H/bin/lib" "$H/env"
cp "$DIR/bin/internal-token-for.sh" "$H/bin/"
cp "$LIB" "$H/bin/lib/" 2>/dev/null
tok() { local h="$1"; shift; HARNESS="$h" "$h/bin/internal-token-for.sh" "$@" 2>/dev/null; }
printf 'OTHER=x\nproject-32_INTERNAL_API_TOKEN="tok-o2"\n' > "$H/env/p.env"
OUT=$(tok "$H" p); eq "S8 digit prefix through the real script" "$?|$OUT" "0|tok-o2"

# ── S8b: exact alert text, unchanged ─────────────────────────────────────────
printf 'A_INTERNAL_API_TOKEN=tok-secret-9\nB_INTERNAL_API_TOKEN=tok-secret-9\n' > "$H/env/p2.env"
OUT=$(tok "$H" p2); eq "S8b two tokens rc+stdout" "$?|$OUT" "1|"
# `paste -sd', '` ALTERNATES its two delimiters, so the list reads "A,B C" —
# that is the text main wrote before BH-1953, and it stays byte-identical.
grep -qF 'p2: env/p2.env defines 2 tokens (A_INTERNAL_API_TOKEN,B_INTERNAL_API_TOKEN) — refusing to guess which one is live — this project is SKIPPED by every board sweep until it is fixed.' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S8b two-token alert text"
printf 'A_INTERNAL_API_TOKEN=x\nB_INTERNAL_API_TOKEN=y\nA_INTERNAL_API_TOKEN=z\n' > "$H/env/p3.env"
OUT=$(tok "$H" p3); eq "S8b three tokens rc+stdout" "$?|$OUT" "1|"
grep -qF 'p3: env/p3.env defines 3 tokens (A_INTERNAL_API_TOKEN,B_INTERNAL_API_TOKEN A_INTERNAL_API_TOKEN) — refusing' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S8b three-token alert text (dupes kept, file order)"
printf 'OTHER=tok-secret-9\n' > "$H/env/q.env"
OUT=$(tok "$H" q); eq "S8b zero tokens rc+stdout" "$?|$OUT" "1|"
grep -qF 'q: env/q.env defines no *_INTERNAL_API_TOKEN — this project is SKIPPED' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S8b zero-token alert text"
OUT=$(tok "$H" absent); eq "S8b missing env rc+stdout" "$?|$OUT" "1|"
grep -qF 'absent: env/absent.env is missing or unreadable' "$H/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S8b missing-env alert text"

# ── S8c: a symlinked script finds the lib beside its real path ───────────────
S="$T/s"; mkdir -p "$S/bin" "$S/env"
ln -s "$DIR/bin/internal-token-for.sh" "$S/bin/internal-token-for.sh"
printf 'export PROJECT_4_INTERNAL_API_TOKEN=tok-sym\n' > "$S/env/c.env"
OUT=$(tok "$S" c); eq "S8c symlinked script" "$?|$OUT" "0|tok-sym"

# ── S8d: copied WITHOUT the lib fails closed and names it ────────────────────
N="$T/n"; mkdir -p "$N/bin" "$N/env"
cp "$DIR/bin/internal-token-for.sh" "$N/bin/"
printf 'PROJECT_4_INTERNAL_API_TOKEN=tok-secret-9\n' > "$N/env/c.env"
OUT=$(tok "$N" c); eq "S8d no lib rc+stdout" "$?|$OUT" "1|"
grep -qF 'bin/lib/internal-token.sh' "$N/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "S8d alert names the missing lib"

# ── S9: a token value never reaches ALERTS.log ───────────────────────────────
if grep -qF 'tok-secret-9' "$H/logs/ALERTS.log" "$N/logs/ALERTS.log" 2>/dev/null; then
  bad "S9 token value leaked into ALERTS.log"
else ok; fi

echo "internal-token-lib.bh-1953: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
