#!/bin/bash
# tests/mergify-pat-identity.c2-test.sh — review round 3 of #2231: a Mergify
# command (`@mergifyio queue`, `requeue`, `refresh`) is posted as a PAT, never
# as the GitHub App, on a C2 box.
#
# THE FINDING. Mergify ignores `@mergifyio …` commands authored by the App.
# bin/lib/autoenqueue.sh asks gh_repo_use_pat for exactly that reason, but
# when the PAT rung was `default` the lib RESET — GH_TOKEN unset — and gh_rest's
# gate (_gh_quota_gate, bin/lib/gh-rest-ledger.sh) then put the App token on the
# POST for any repos/example-org/* path. The comment landed 201 as the App, the
# row went `enqueued`, Mergify did nothing, and approved PRs stalled silently.
# It needs no keyring logout: the conductor's shell has no GH_TOKEN, so
# _GHRT_DEFAULT_TOK is empty from the first tick after the C2 merge. Worse, the
# PAT probe itself (`env -u GH_TOKEN gh api repos/<slug>`) went through the gh
# shim, which minted the App token, so "default" could be answered by the App
# on a box with no PAT at all. The conductor's own mc_enqueue_mergify and the
# stuck-batch `@mergifyio refresh` post with a bare `gh api` and had the same
# hole through the shim.
#
# PINNED, through the REAL bin/gh-ledger/gh shim, the REAL gh_rest gate and the
# REAL tier2-autoenqueue _ae_send (bin/gh-token.sh and the real gh are stubs):
#   0. the harness is live: a bare gh_rest POST with no GH_TOKEN DOES get the App
#   1. keyring logged in (right after merge): the queue comment runs on it
#   2. keyring logged out, env/gh-pat: the comment runs on env/gh-pat
#   3. only the admin PAT sees the repo: admin (a PAT), never the App
#   4. no PAT anywhere: nothing is posted, the send refuses
#   5. mc_mergify_command (enqueue + refresh): the same, through the shim
# Run from anywhere: bash tests/mergify-pat-identity.c2-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/mg
APPTOK=ghs_APPTOKENfixture
H="$T/h"
mkdir -p "$H/bin/gh-ledger" "$H/bin/lib/mc" "$H/env" "$H/state" "$H/flags" "$H/logs" "$T/real" "$T/home" "$T/tmp"
cp "$DIR/bin/gh-ledger/gh" "$H/bin/gh-ledger/gh"; chmod +x "$H/bin/gh-ledger/gh"
for f in gh-rest-ledger.sh gh-rest.sh gh-app-default.sh gh-repo-token.sh env-path.sh autoenqueue.sh deployment.sh; do
  cp "$DIR/bin/lib/$f" "$H/bin/lib/"
done
cp "$DIR/bin/lib/mc/queue.sh" "$H/bin/lib/mc/"
: > "$H/env/github-app.env"
cat > "$H/bin/gh-token.sh" <<STUB
#!/bin/bash
printf '%s\n' "$APPTOK"
STUB
chmod +x "$H/bin/gh-token.sh"

# The real gh: records every call with its token. The repo is visible to the
# keyring PAT, env/gh-pat's PAT, the admin PAT and the App, per $T/visible.
cat > "$T/real/gh" <<STUB
#!/bin/bash
[ "\$1 \$2" = "api rate_limit" ] && exit 1
printf 'argv=%s|tok=%s\n' "\$*" "\${GH_TOKEN:-}" >> "$T/calls.txt"
if [ "\$1 \$2" = "auth token" ]; then [ -s "$T/keyring" ] && { cat "$T/keyring"; exit 0; }; exit 1; fi
case "\$*" in
  "api repos/$SLUG -q .id")
    tok="\${GH_TOKEN:-}"; [ -n "\$tok" ] || tok=\$(cat "$T/keyring" 2>/dev/null)
    [ -n "\$tok" ] && grep -qxF "\$tok" "$T/visible" && { echo 1; exit 0; }; exit 1 ;;
  "api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf 'HTTP/2.0 201 Created\r\nx-ratelimit-remaining: 5000\r\nx-ratelimit-limit: 5000\r\n\r\n{"id":777}'; exit 0 ;;
  "api -X POST repos/$SLUG/issues/"*) echo '{}'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$T/real/gh"

# world <keyring> <gh-pat> <admin> <visible...> — "-" = absent
world() {
  : > "$T/calls.txt"; rm -f "$H/state/gh-app-default.knobs" "$H/state/tier2-autoenqueue.txt"; scratch_rm "$H/state/gh-app-default.fail"
  if [ "$1" = - ]; then : > "$T/keyring"; else printf '%s\n' "$1" > "$T/keyring"; fi
  if [ "$2" = - ]; then rm -f "$H/env/gh-pat"; else printf 'GH_PAT=%s\n' "$2" > "$H/env/gh-pat"; fi
  if [ "$3" = - ]; then rm -f "$H/env/github-admin.env"; else printf 'GH_ADMIN_TOKEN=%s\n' "$3" > "$H/env/github-admin.env"; fi
  shift 3; printf '%s\n' "$APPTOK" "$@" > "$T/visible"
}
# cron <script> — the conductor's shell as cron makes it: env -i, shim first, no GH_TOKEN
cron() {
  env -i PATH="$H/bin/gh-ledger:$T/real:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
    HARNESS="$H" HARNESS_ENV_DIR="$H/env" MC_H="$H" MC_ATTEMPTS="$T/attempts" \
    bash -c ". \$HARNESS/bin/lib/gh-rest.sh; . \$HARNESS/bin/lib/gh-repo-token.sh
      mc_log() { :; }; mc_alert() { :; }; $1" 2>"$T/err.txt"
}
AE_SEND='. $HARNESS/bin/lib/autoenqueue.sh
  job_ledger_get() { return 2; }; job_ledger_put() { return 0; }; job_artifact_put() { return 0; }
  AE_P=mg AE_SLUG='"$SLUG"' AE_NUM=5 AE_URL=https://github.com/'"$SLUG"'/pull/5 AE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  AE_KEY=k AE_JOB=- AE_RECOVER=0 AE_STATUS=new
  _ae_send; echo "rc=$?"'
post_tok() { grep "comments" "$T/calls.txt" | grep 'POST' | sed -n 's/.*|tok=//p' | tail -n 1; }
posts()    { grep "comments" "$T/calls.txt" | grep -c 'POST'; }

# ── 0. the harness is live: a bare POST with no GH_TOKEN gets the App ─────────
world ghp_keyring - ghp_ADMIN ghp_keyring ghp_ADMIN
cron 'gh_rest POST repos/'"$SLUG"'/issues/9/comments -f body=x >/dev/null' >/dev/null
[ "$(post_tok)" = "$APPTOK" ] && ok || bad "0: the gate must put the App on a tokenless POST (else this suite proves nothing), saw '$(post_tok)'"

# ── 1. right after merge: keyring logged in, conductor shell has no GH_TOKEN ──
world ghp_keyring - ghp_ADMIN ghp_keyring ghp_ADMIN
OUT=$(cron "$AE_SEND")
[ "$OUT" = rc=0 ] && ok || bad "1a: the send must succeed ($OUT: $(cat "$T/err.txt"))"
[ "$(post_tok)" = ghp_keyring ] && ok || bad "1b: @mergifyio queue must run on the keyring PAT, saw '$(post_tok)'"

# ── 2. keyring logged out, env/gh-pat holds the PAT ──────────────────────────
world - ghp_filepat ghp_ADMIN ghp_filepat ghp_ADMIN
OUT=$(cron "$AE_SEND")
[ "$(post_tok)" = ghp_filepat ] && ok || bad "2: @mergifyio queue must run on env/gh-pat, saw '$(post_tok)' ($OUT)"

# ── 3. only the admin PAT can see the repo ───────────────────────────────────
world - - ghp_ADMIN ghp_ADMIN
OUT=$(cron "$AE_SEND")
[ "$(post_tok)" = ghp_ADMIN ] && ok || bad "3: with only the admin PAT seeing the repo it is the (PAT) identity, never the App, saw '$(post_tok)' ($OUT)"

# ── 4. no PAT at all: nothing posted ─────────────────────────────────────────
world - - -
OUT=$(cron "$AE_SEND")
[ "$(posts)" = 0 ] && ok || bad "4a: no PAT anywhere must post nothing (App authored it?), posted as '$(post_tok)'"
[ "$OUT" = rc=1 ] && ok || bad "4b: the send must refuse with no PAT ($OUT)"

# ── 5. the conductor's own Mergify commands (mc_mergify_command) ─────────────
MCQ='. $HARNESS/bin/lib/mc/queue.sh; mc_num_of_url() { grep -oE "[0-9]+\$" <<<"$1"; }; command -v mc_mergify_command >/dev/null || { echo nofn; exit 0; }'
world ghp_keyring - ghp_ADMIN ghp_keyring ghp_ADMIN
OUT=$(cron "$MCQ; mc_mergify_command $SLUG 7 '@mergifyio refresh'; echo rc=\$?")
[ "$OUT" = rc=0 ] && ok || bad "5a: mc_mergify_command must exist and post ($OUT)"
[ "$(post_tok)" = ghp_keyring ] && ok || bad "5b: @mergifyio refresh must run on the keyring PAT, saw '$(post_tok)'"
world - ghp_filepat - ghp_filepat
OUT=$(cron "$MCQ; mc_mergify_command $SLUG 7 '@mergifyio queue'; echo rc=\$?")
[ "$(post_tok)" = ghp_filepat ] && ok || bad "5c: on a logged-out box the command runs on env/gh-pat, saw '$(post_tok)' ($OUT)"
world - - -
OUT=$(cron "$MCQ; mc_mergify_command $SLUG 7 '@mergifyio queue'; echo rc=\$?")
[ "$(posts)" = 0 ] && ok || bad "5d: no PAT: the command is not posted as the App (posted as '$(post_tok)')"
[ "$OUT" = rc=1 ] && ok || bad "5e: no PAT: mc_mergify_command answers rc 1 ($OUT)"
# mc_enqueue_mergify's command goes through it (the label may use any identity)
world ghp_keyring - - ghp_keyring
OUT=$(cron "$MCQ; mc_queue_state() { echo open; }; mc_mergify_witness() { return 0; }; MC_MERGIFY_LABEL=merge-queue
  mc_enqueue_mergify $SLUG https://github.com/$SLUG/pull/8 aaaa; echo rc=\$?")
[ "$(post_tok)" = ghp_keyring ] && ok || bad "5f: mc_enqueue_mergify's @mergifyio queue must run on the PAT, saw '$(post_tok)' ($OUT)"
# the two command senders carry no bare comment POST of their own (the dequeue
# NOTICE in mc_dequeue_surface is prose for humans, not a Mergify command)
for fn in mc_enqueue_mergify mc_mergify_stuck_pass; do
  body=$(awk -v f="$fn() {" '$0==f {on=1} on {print} on && /^}/ {exit}' "$DIR/bin/lib/mc/queue.sh")
  [ -n "$body" ] || { bad "5g: $fn not found in bin/lib/mc/queue.sh"; continue; }
  if grep -q 'gh api .*comments' <<<"$body"; then bad "5g: $fn posts a comment with a bare gh api, not mc_mergify_command"
  elif grep -q 'mc_mergify_command' <<<"$body"; then ok; else bad "5g: $fn does not use mc_mergify_command"; fi
done

echo "mergify-pat-identity.c2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
