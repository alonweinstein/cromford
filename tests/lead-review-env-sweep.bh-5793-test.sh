#!/bin/bash
# tests/lead-review-env-sweep.bh-5793-test.sh — BH-5793: the one-time sweep that
# supersedes lead BLOCKs whose findings are environment failures only.
#
# Drives the REAL bin/lead-review-env-sweep.sh in a scratch harness whose jobs
# client, lead-reviews lib and GitHub REST lib are stubs that log every call:
#   S1 an env-only BLOCK (repo setup failed, a suite missing at the PR head) is
#      superseded: a ledger row first, then POST /<id>/reset (the re-review)
#   S2 a BLOCK with one real finding is kept
#   S3 dry-run (the default) writes nothing and says would-supersede
#   S4 a second --apply run skips what the ledger already superseded
#   S5 a BLOCK whose PR head moved, or whose report cannot be read, is skipped
#   S6 a MERGE request is never read
#   S7 "does not resolve" is an env failure only in the runner's own wording
#   S8 without gh-rest.sh the PR state cannot be checked, so nothing is superseded
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-env-sweep.bh-5793-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SCRIPT="$DIR/bin/lead-review-env-sweep.sh"
[ -r "$SCRIPT" ] && [ -r "$DIR/bin/lib/review-env-fail.sh" ] && ok || bad "D41: $SCRIPT or bin/lib/review-env-fail.sh is missing"

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$T/art"
cp "$SCRIPT" "$H/bin/lead-review-env-sweep.sh" 2>/dev/null
# scratch-closure-allow: BH-5793 the jobs client, the lead-reviews lib and gh-rest are logging stubs here, so the closure (which installs the real ones) is not wanted; the classifier lib alone is copied
cp "$DIR/bin/lib/review-env-fail.sh" "$H/bin/lib/"

# The stubs. Every call lands in $T/calls.
cat > "$H/bin/jobs-client.sh" <<EOF
job_artifact_detail() { echo "artifact \$*" >> "$T/calls"; [ -s "$T/art/\$2" ] || return 1; cat "$T/art/\$2"; }
job_ledger_row() { echo "ledger_get \$*" >> "$T/calls"; [ -e "$T/ledger-\$(printf '%s' "\$2" | tr '/#@' '___')" ] && { echo '{"status":"superseded"}'; return 0; }; return 2; }
job_ledger_put() { echo "ledger_put \$1 \$2 \$3 \$4" >> "$T/calls"; touch "$T/ledger-\$(printf '%s' "\$2" | tr '/#@' '___')"; }
EOF
cat > "$H/bin/lib/lead-reviews.sh" <<EOF
lr_get() { echo "lr_get \$*" >> "$T/calls"; cat "$T/requests.json"; }
lr_post_lead() { echo "lr_post_lead \$*" >> "$T/calls"; echo '{"request":{"status":"requested"}}'; }
EOF
cat > "$H/bin/lib/gh-rest.sh" <<EOF
gh_rest() { echo "gh_rest \$*" >> "$T/calls"; GH_REST_STATUS=200
  case "\$2" in
    repos/example-org/demo-os/pulls/43) printf '{"state":"open","head":{"sha":"$SHA1"}}' ;;   # moved
    repos/example-org/demo-os/pulls/*) n=\${2##*/}; h=\$(jq -r --argjson n "\$n" '.requests[] | select(.pr == \$n) | .head_sha' "$T/requests.json" | head -1)
                                     printf '{"state":"open","head":{"sha":"%s"}}' "\$h" ;;
  esac; }
# gh-rest.sh's variable-assigning variant (bin/lib/gh-rest-var.sh): the reply
# lands in the named variable and the helper's rc comes back.
gh_rest_var() { local _v="\$1" _o _rc; shift; _o=\$(gh_rest "\$@"); _rc=\$?; printf -v "\$_v" '%s' "\$_o"; return "\$_rc"; }
EOF

req() { jq -nc --arg i "$1" --argjson p "$2" --arg h "$3" --arg v "$4" --arg j "$5" \
  '{id:$i, repo:"example-org/demo-os", pr:$p, head_sha:$h, status:"done", verdict:$v, job_id:$j}'; }
art() { # art <job> <pr> <head> <finding line>...
  local j="$1" p="$2" h="$3"; shift 3
  { printf '# Lead review lr-%s-%s (example-org/demo-os#%s at %s)\n\n- verdict: BLOCK\n- rules pack: red\n\nFindings\n' "$p" "${h:0:12}" "$p" "$h"
    for l in "$@"; do printf -- '- [BLOCK] %s\n' "$l"; done
    printf '\nVERDICT: BLOCK\n'; } | jq -Rsc '{body:.}' > "$T/art/$j"
}
setup() {
  rm -f "$T/calls" "$T"/ledger-* "$T/art"/*
  jq -nc --argjson r "[$(req lr-41 41 "$SHA1" BLOCK j41),$(req lr-42 42 "$SHA2" BLOCK j42),$(req lr-43 43 "$SHA3" BLOCK j43),$(req lr-44 44 "$SHA1" MERGE j44),$(req lr-45 45 "$SHA2" BLOCK j45)]" \
    '{requests:$r, truncated:false}' > "$T/requests.json"
  art j41 41 "$SHA1" 'gh-graphql-reads-lint: FAIL: 3 (x): repo setup failed' 'rules-pack: suite missing at the PR head: tests/new-test.sh'
  art j42 42 "$SHA2" 'ratchet-x: bin/foo.sh:3 bad default' 'gh-graphql-reads-lint: FAIL: 3 (x): repo setup failed'
  art j43 43 "$SHA3" 'gh-graphql-reads-lint: FAIL: 3 (x): repo setup failed'
  # j45: no artifact at all (unreadable)
}
run() { OUT=$(cd "$T" && HARNESS="$H" bash "$H/bin/lead-review-env-sweep.sh" "$@" 2>"$T/err"); RC=$?; }
calls() { cat "$T/calls" 2>/dev/null; }

# S3 dry-run first
setup; run
[ "$RC" = 0 ] && ok || bad "S3 rc $RC: $(cat "$T/err")"
grep -qx 'would-supersede lr-41 example-org/demo-os#41 111111111111' <<<"$OUT" && ok || bad "S3 dry-run line for lr-41: $OUT"
grep -q 'ledger_put\|lr_post_lead' <<<"$(calls)" && bad "S3 dry-run wrote: $(calls)" || ok

# S1/S2/S5/S6 apply
setup; run --apply
[ "$RC" = 0 ] && ok || bad "S1 rc $RC: $(cat "$T/err")"
grep -qx 'superseded lr-41 example-org/demo-os#41 111111111111' <<<"$OUT" && ok || bad "S1 lr-41 not superseded: $OUT"
grep -qx "ledger_put lead_block_env_superseded example-org/demo-os#41@$SHA1 superseded lr-41" <<<"$(calls)" && ok || bad "S1 no ledger row: $(calls)"
grep -qx "lr_post_lead /lr-41/reset {}" <<<"$(calls)" && ok || bad "S1 no reset (re-review request): $(calls)"
[ "$(calls | grep -n 'ledger_put .*#41@' | cut -d: -f1)" -lt "$(calls | grep -n 'lr_post_lead /lr-41/reset' | cut -d: -f1)" ] && ok || bad "S1 the ledger row must come before the reset"
grep -q '^kept lr-42 ' <<<"$OUT" && ok || bad "S2 lr-42 (a real finding) must be kept: $OUT"
grep -q 'lr-42/reset' <<<"$(calls)" && bad "S2 lr-42 was reset" || ok
grep -q '^skipped lr-43 .*head moved' <<<"$OUT" && ok || bad "S5 lr-43 (head moved) must be skipped: $OUT"
grep -q 'lr-43/reset' <<<"$(calls)" && bad "S5 lr-43 was reset" || ok
grep -q '^skipped lr-45 .*report' <<<"$OUT" && ok || bad "S5 lr-45 (no report) must be skipped: $OUT"
grep -q 'artifact .* j44' <<<"$(calls)" && bad "S6 a MERGE request's report was read" || ok

# S4 a second run skips what is already superseded
: > "$T/calls"; run --apply
grep -q '^skipped lr-41 .*already superseded' <<<"$OUT" && ok || bad "S4 lr-41 must be skipped on the second run: $OUT"
grep -q 'lr-41/reset' <<<"$(calls)" && bad "S4 lr-41 reset twice" || ok

# S8 (lead review lr-5809-1a62fbb06f34, NOTE): without gh-rest.sh the PR state
# cannot be checked, so --apply supersedes nothing and says why.
setup; mv "$H/bin/lib/gh-rest.sh" "$T/gh-rest.off"; run --apply; mv "$T/gh-rest.off" "$H/bin/lib/gh-rest.sh"
grep -q '^skipped lr-41 .*gh-rest' <<<"$OUT" && ok || bad "S8 lr-41 must be skipped without gh-rest: $OUT"
grep -q '/reset' <<<"$(calls)" && bad "S8 a reset went out without the PR check: $(calls)" || ok

# S7 (lead review lr-5809-b2360d16170d): "does not resolve" is an environment
# failure only in the runner's own wording, about a base ref. A real finding
# that ends in the same words stays a real finding.
( . "$DIR/bin/lib/review-env-fail.sh"
  rev_env_line "rules-pack: base 'origin/main' does not resolve to a commit in /src" || echo "S7 the runner's base line is not an env failure"
  rev_env_line "could-not-run: the snapshot base 0a1b2c does not resolve as nobody in /tmp/x/repo" || echo "S7 the snapshot base line is not an env failure"
  rev_env_line 'tests/lane-stage-ratchet.bh-2304-test.sh:119 agent-call stage argument "$1" does not resolve' && echo "S7 a real finding about a stage argument was read as an env failure"
) > "$T/s7" 2>&1
[ -s "$T/s7" ] && bad "$(cat "$T/s7")" || ok

echo "lead-review-env-sweep.bh-5793: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
