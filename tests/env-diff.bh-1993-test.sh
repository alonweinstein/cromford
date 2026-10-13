#!/bin/bash
# tests/env-diff.bh-1993-test.sh — bin/env-diff.sh masks a credential that sits
# inside a VALUE, whatever the key is called (BH-1993, the #1972 review).
#
# Same rig as tests/env-diff.bh-19-test.sh: a scratch harness, the REAL script
# and the REAL bin/lib/lane-gate.sh, and a stub bin/beat.sh that records each
# payload and answers $STUB_BEAT_RC.
#
# What is proved here:
#   V1  URL userinfo (https://user:tok@host, redis://:pw@h) is masked;
#   V2  a credential query parameter (?token=, &api_key=) is masked;
#   V3  a known token prefix (sk-, sk-or-, ghp_, ghs_, gho_, ghu_, github_pat_,
#       xai-) is masked;
#   V4  a long letters-and-digits run is masked, including base64 with / and +
#       (V4c-V4e, the #2045 lead review probes);
#   every V case: the beat reads "<KEY> changed (value redacted)" and the
#       credential is in none of the beat, logs/ and state/;
#   V5  no console (rc 2): the ALERTS.log path is just as clean;
#   V6  a snapshot written before this fix, holding a raw credential, never
#       echoes it: a changed value reads "(value redacted)", an unchanged one
#       sends nothing and the snapshot is rewritten masked;
#   V6c the same holds for an env file the tick cannot read: its carried-
#       forward rows are masked, so a raw pre-fix row neither beats every tick
#       nor is written back into the snapshot;
#   V7  a masked value that does not change sends nothing on the next tick;
#   N1  ordinary values (billing modes, model ids, a URL with a port or a plain
#       query, numbers, a long lowercase path) still read old→new;
#   K1  a secret-looking key NAME is still masked as before.
# Run from anywhere: tests/env-diff.bh-1993-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
BEATS="$T/beats.log"
SNAP="$H/state/env-diff/snapshot.tsv"
ALERTS="$H/logs/ALERTS.log"

reset() {
  [ -d "$H" ] && { chmod -R u+w "$H" 2>/dev/null; scratch_rm "$H"; }
  rm -f "$BEATS"
  mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/flags" "$H/locks"
  cp "$DIR/bin/env-diff.sh" "$H/bin/" 2>/dev/null
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
  cat > "$H/bin/beat.sh" <<SH
#!/bin/bash
printf 'strict=%s\t%s\n' "\${BEAT_STRICT:-}" "\$1" >> "$BEATS"
exit "\${STUB_BEAT_RC:-0}"
SH
  chmod +x "$H/bin/beat.sh"
}
run() {
  env -u CONSOLE_URL -u HARNESS_SECRET HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
    ENV_DIFF_BOX=testbox STUB_BEAT_RC="${1:-0}" bash "$H/bin/env-diff.sh" >/dev/null 2>&1
}
nbeats() { [ -f "$BEATS" ] && wc -l < "$BEATS" | tr -d ' ' || echo 0; }
line1()  { sed -n 1p "$BEATS" 2>/dev/null | cut -f2- | jq -r .line 2>/dev/null; }
# leaks <needle> — every file under the scratch harness and the beat log that
# holds the needle, one per line; empty means clean.
leaks() { grep -rlF -- "$1" "$H/logs" "$H/state" "$BEATS" 2>/dev/null; }

# masked <case> <KEY> <value> <needle> [beat rc]
masked() {
  local c="$1" k="$2" v="$3" n="$4" rc="${5:-0}" L lk
  reset
  printf 'GROK_BILLING=api\n%s=plain\n' "$k" > "$H/env/global.env"
  run
  [ -f "$SNAP" ] && ok || bad "$c: the baseline tick must write the snapshot"
  printf 'GROK_BILLING=api\n%s=%s\n' "$k" "$v" > "$H/env/global.env"
  run "$rc"
  [ "$(nbeats)" = 1 ] && ok || bad "$c: one beat expected for $k=$v, got $(nbeats)"
  L=$(line1)
  case "$L" in *"global.env $k changed (value redacted)"*) ok ;;
    *) bad "$c: the beat must read '$k changed (value redacted)' for $v: $L" ;; esac
  lk=$(leaks "$n")
  [ -z "$lk" ] && ok || bad "$c: '$n' (from $k=$v) leaked into: $(echo $lk)"
}

# ---------------------------------------------------------------------- V1
masked V1a RUNNER_URL   'https://user:FAKEtok1@host'        FAKEtok1
masked V1b RUNNER_REDIS 'redis://:FAKEpw2@h:6379'           FAKEpw2
# ---------------------------------------------------------------------- V2
masked V2a RUNNER_URL   'https://h/x?token=FAKEq3'          FAKEq3
masked V2b RUNNER_URL   'https://h/x?region=us&api_key=FAKEq4' FAKEq4
masked V2c RUNNER_URL   'https://h/x#access_token=FAKEq5'   FAKEq5
# A compound name: words joined by `_` or `-` before the credential word.
masked V2d RUNNER_URL   'https://h/x?auth_token=FAKEq6'     FAKEq6
masked V2e RUNNER_URL   'https://h/x?a=1&client_secret=FAKEq7' FAKEq7
masked V2f RUNNER_URL   'https://h/x?private_token=FAKEq8'  FAKEq8
masked V2g RUNNER_URL   'https://h/x?refresh_token=FAKEq9'  FAKEq9
masked V2h RUNNER_URL   'https://h/x?x-api-key=FAKEq10'     FAKEq10
# ---------------------------------------------------------------------- V3
masked V3a RUNNER_CRED  'sk-ant-FAKEp1'                     FAKEp1
masked V3b RUNNER_CRED  'sk-or-v1-FAKEp2'                   FAKEp2
masked V3c RUNNER_CRED  'ghp_FAKEp3'                        FAKEp3
masked V3d RUNNER_CRED  'ghs_FAKEp4'                        FAKEp4
masked V3e RUNNER_CRED  'xai-FAKEp5'                        FAKEp5
masked V3f RUNNER_CRED  'gho_FAKEp6'                        FAKEp6
masked V3g RUNNER_CRED  'ghu_FAKEp7'                        FAKEp7
masked V3h RUNNER_CRED  'github_pat_FAKEp8'                 FAKEp8
masked V3i RUNNER_AUTH  'Bearer sk-FAKEp9'                  FAKEp9
# ---------------------------------------------------------------------- V4
masked V4a RUNNER_ID    'Q7fK2mZ9xL4pW8rT1vB6nC3yH5jD0sG2aE9u' Q7fK2mZ9xL4pW8rT1vB6nC3y
masked V4b RUNNER_ID    'x=Q7fK2mZ9xL4pW8rT1vB6nC3yH5jD0sG2aE9u' Q7fK2mZ9xL4pW8rT1vB6nC3y
# Base64 keys carry `/` and `+` (the #2045 lead review probes): the run check
# must read through them, or about half of all base64 secrets leak raw.
masked V4c RUNNER_ID    'q8Zr3m+Vd/9kLp2Xw7Tn/Yb4Hc6Jf1Ga8Ue5Ri0So3M=' Vd/9kLp2Xw7Tn/Yb4Hc6
masked V4d RUNNER_ID    'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY' K7MDENG/bPxRfiCY
masked V4e RUNNER_ID    'aB3dE6gH9jK2mN5pQ8sT1vW4yZ7+cF0hL3oR6uX9' L3oR6uX9
# ---------------------------------------------------------------------- V5
masked V5  RUNNER_URL   'https://user:FAKEtok5@host'        FAKEtok5 2
[ -s "$ALERTS" ] && ok || bad "V5: rc 2 must write the ALERTS.log line"
grep -q 'RUNNER_URL changed (value redacted)' "$ALERTS" 2>/dev/null && ok \
  || bad "V5: the ALERTS.log line must carry the redacted item: $(cat "$ALERTS" 2>/dev/null)"

# ---------------------------------------------------------------------- V6
# A snapshot written by the pre-fix script holds the raw value.
reset
printf 'RUNNER_URL=plain\n' > "$H/env/global.env"
run
printf 'global.env\tRUNNER_URL\thttps://user:FAKEold6@h\n' > "$SNAP"
printf 'RUNNER_URL=https://user:FAKEnew6@h\n' > "$H/env/global.env"
run
[ "$(nbeats)" = 1 ] && ok || bad "V6a: one beat expected, got $(nbeats)"
case "$(line1)" in *"RUNNER_URL changed (value redacted)"*) ok ;;
  *) bad "V6a: a raw old value must still read '(value redacted)': $(line1)" ;; esac
lk=$(leaks FAKEold6); [ -z "$lk" ] && ok || bad "V6a: the pre-fix raw value leaked into: $(echo $lk)"
lk=$(leaks FAKEnew6); [ -z "$lk" ] && ok || bad "V6a: the new raw value leaked into: $(echo $lk)"
# Same raw value on both sides: nothing changed, nothing sent, and the
# snapshot no longer holds it.
reset
printf 'RUNNER_URL=https://user:FAKEsame6@h\n' > "$H/env/global.env"
run
printf 'global.env\tRUNNER_URL\thttps://user:FAKEsame6@h\n' > "$SNAP"
run
[ "$(nbeats)" = 0 ] && ok || bad "V6b: an unchanged value under a pre-fix snapshot must not beat, got $(nbeats): $(line1)"
lk=$(leaks FAKEsame6); [ -z "$lk" ] && ok || bad "V6b: the pre-fix snapshot must be rewritten masked, still in: $(echo $lk)"
grep -q $'global.env\tRUNNER_URL\tsha256:' "$SNAP" 2>/dev/null && ok \
  || bad "V6b: the rewritten snapshot must hold sha256:<hash>: $(cat "$SNAP" 2>/dev/null)"

# An unreadable env file keeps its previous rows. A raw pre-fix row among
# them must be masked on the way through: no beat on any tick, and the
# snapshot no longer holds it. Root reads through mode 000, so as root the
# unreadable file is a dangling symlink (the same failed read).
reset
printf 'GROK_BILLING=api\n' > "$H/env/global.env"
printf 'RUNNER_URL=plain\n' > "$H/env/project-3.env"
run
printf 'global.env\tGROK_BILLING\tapi\nproject-3.env\tRUNNER_URL\thttps://user:FAKEunr6@h\n' > "$SNAP"
if [ "$(id -u)" -eq 0 ]; then
  rm -f "$H/env/project-3.env"; ln -s "$T/nowhere/project-3.env" "$H/env/project-3.env"
else
  chmod 000 "$H/env/project-3.env"
fi
run; run; run
[ "$(nbeats)" = 0 ] && ok || bad "V6c: an unreadable file's pre-fix raw row must not beat, got $(nbeats): $(line1)"
lk=$(leaks FAKEunr6); [ -z "$lk" ] && ok || bad "V6c: the carried-forward raw value must be rewritten masked, still in: $(echo $lk)"
grep -q $'project-3.env\tRUNNER_URL\tsha256:' "$SNAP" 2>/dev/null && ok \
  || bad "V6c: the carried-forward row must be kept, masked: $(cat "$SNAP" 2>/dev/null)"
chmod 644 "$H/env/project-3.env" 2>/dev/null

# ---------------------------------------------------------------------- V7
masked V7 RUNNER_URL 'https://user:FAKEtok7@host' FAKEtok7
run
[ "$(nbeats)" = 1 ] && ok || bad "V7: an unchanged masked value must not beat again, got $(nbeats)"

# ---------------------------------------------------------------------- N1
while IFS='|' read -r k v; do
  reset
  printf '%s=x0\n' "$k" > "$H/env/global.env"
  run
  printf '%s=%s\n' "$k" "$v" > "$H/env/global.env"
  run
  case "$(line1)" in *"global.env $k x0→$v"*) ok ;;
    *) bad "N1: $k=$v must stay visible as x0→$v: $(line1)" ;; esac
done <<'EOF'
GROK_BILLING|api
CLAUDE_BILLING|subscription
BUILD_MODEL|claude-opus-5-5
TRIAGE_MODEL|claude-haiku-4-5-20251001
PLAN_MODEL|accounts/fireworks/models/kimi-k2p7-code
RUNNER_URL|https://host:8443/v1/path
RUNNER_URL|https://host/path?region=us
RUNNER_URL|https://host/path?monkey=1
RUNNER_URL|https://host/path?passage=1&donkey_ride=2
X_EFFORT|high
RUNNER_TIMEOUT|450
RUNNER_PLAN|sk
RUNNER_TASK|task-runner-disk-xai
RUNNER_DIR|/srv/data/archive2026/backups/nightly/rotation3
RUNNER_URL|https://host/api/v2/projects/alpha/builds/nightly/latest
EOF

# ---------------------------------------------------------------------- K1
reset
printf 'RUNNER_API_KEY=FAKEk1a\n' > "$H/env/global.env"
run
printf 'RUNNER_API_KEY=FAKEk1b\n' > "$H/env/global.env"
run
case "$(line1)" in *"RUNNER_API_KEY changed (value redacted)"*) ok ;;
  *) bad "K1: a secret-named key must still be redacted: $(line1)" ;; esac
lk=$(leaks FAKEk1); [ -z "$lk" ] && ok || bad "K1: a secret-named key's value leaked into: $(echo $lk)"

echo "env-diff.bh-1993: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
