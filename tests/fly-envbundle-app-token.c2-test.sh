#!/bin/bash
# tests/fly-envbundle-app-token.c2-test.sh — C2 (2026-09-24): the Fly builder
# bundle's GH_TOKEN comes from the owning box's bin/gh-token.sh, never from its
# gh keyring.
#
# THE FINDING. bin/fly-envbundle.sh built every builder bundle from the owning
# box's `gh auth token` — the keyring, which is the operator's PAT — and died "bundle
# missing GH_TOKEN" when it was empty. Logging the keyring out (the C2 rollout)
# would have stopped every pool build fleet-wide.
#
# PINNED: the extract asks `bin/gh-token.sh --pat <the project's repo>` — the
# box's PAT ladder (env/global.env, env/gh-pat, the keyring last), NEVER an App
# mint. Review of #2231: the dispatch route (bin/fly-dispatch.sh) ships this
# bundle as-is and never rotates, so a 1-hour installation token died under any
# build past ~60 min; and a hub-App token authored the PR as the same App that
# reviews it, so review-prs' APPROVE fell to COMMENT. The pool route replaces the
# line per machine anyway (builders App + rotation, bin/fly-pool.sh). A box that
# can answer nothing fails with a message naming gh-token.sh and the repo rather
# than the keyring.
#
# Run from anywhere: bash tests/fly-envbundle-app-token.c2-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$T/fake" "$T/out"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
cat > "$H/bin/fleet-conf.sh" <<'STUB'
#!/bin/bash
case "$1" in
  --tailnet-ip) echo local ;;
  *) [ "${2:-}" = repo ] && echo example-org/proj-repo ;;
esac
STUB
cat > "$H/bin/gh-token.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/mints.txt"
[ "\${ENVB_TOK_MODE:-app}" = app ] || exit 0
case " \$* " in *" --pat "*) printf 'ghp_ladderfixture\n' ;; *) printf 'ghs_bundlefixture\n' ;; esac
exit 0
STUB
# The keyring: a PAT that must NOT reach the bundle.
cat > "$T/fake/gh" <<'STUB'
#!/bin/bash
[ "$1 $2" = "auth token" ] && { echo ghp_keyringpat; exit 0; }
exit 1
STUB
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/gh-token.sh" "$T/fake/gh"
printf 'CLAUDE_CODE_OAUTH_TOKEN=oauth-fixture\nCONSOLE_URL=https://console.invalid\n' > "$H/env/global.env"
printf 'BOARD_TOKEN=board-fixture\n' > "$H/env/proj.env"

run_bundle() {
  : > "$T/mints.txt"; rm -rf "$T/out"; mkdir -p "$T/out"
  env -i PATH="$T/fake:/usr/bin:/bin" HOME="$T" HARNESS="$H" ENVB_TOK_MODE="${1:-app}" \
    bash "$DIR/bin/fly-envbundle.sh" proj "$T/out" >"$T/stdout.txt" 2>"$T/stderr.txt"
}

run_bundle app; RC=$?
[ "$RC" = 0 ] && ok || bad "1a: the bundle must build (rc $RC: $(cat "$T/stderr.txt"))"
grep -qx 'GH_TOKEN=ghp_ladderfixture' "$T/out/global.env" 2>/dev/null && ok \
  || bad "1b: the bundle's GH_TOKEN must be gh-token.sh's PAT-ladder answer"
grep -q 'ghp_keyringpat' "$T/out/global.env" 2>/dev/null && bad "1c: the keyring was read directly" || ok
[ "$(head -n 1 "$T/mints.txt")" = "--pat example-org/proj-repo" ] && ok \
  || bad "1d: the token must be asked for as gh-token.sh --pat <repo>, was '$(head -n 1 "$T/mints.txt")'"
grep -q 'ghs_' "$T/out/global.env" 2>/dev/null && bad "1g: an unrotated 1-hour App token reached the dispatch bundle" || ok
grep -qx 'REPO_SLUG=example-org/proj-repo' "$T/out/proj.env" 2>/dev/null && ok || bad "1e: REPO_SLUG still rides in the project env"
grep -qx 'BOARD_TOKEN=board-fixture' "$T/out/proj.env" 2>/dev/null && ok || bad "1f: the project env is still bundled whole"

run_bundle none; RC=$?
[ "$RC" != 0 ] && ok || bad "2a: no token at all must fail the bundle"
grep -q 'gh-token.sh --pat example-org/proj-repo printed nothing' "$T/stderr.txt" && ok \
  || bad "2b: the failure must name gh-token.sh and the repo, got: $(cat "$T/stderr.txt")"
grep -q 'gh auth token' "$T/stderr.txt" && bad "2c: the failure still blames the keyring" || ok

# ── 3. the real bin/gh-token.sh --pat: the PAT ladder, never a mint ─────────
G="$T/g"; mkdir -p "$G/bin/lib" "$G/env" "$G/state" "$G/logs" "$G/locks" "$T/fb3"
cp "$DIR/bin/gh-token.sh" "$G/bin/"; chmod +x "$G/bin/gh-token.sh"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$G/bin/lib/"
: > "$G/env/github-app.pem"
printf 'GH_APP_ID=1\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$G" > "$G/env/github-app.env"
printf '#!/bin/bash\necho "$*" >> "%s/curl.log"\necho "{}"\n' "$T" > "$T/fb3/curl"
printf '#!/bin/bash\nexit 1\n' > "$T/fb3/gh"      # no keyring login
chmod +x "$T/fb3/curl" "$T/fb3/gh"
gt3() { env -i PATH="$T/fb3:/usr/bin:/bin" HOME="$T" HARNESS="$G" HARNESS_ENV_DIR="$G/env" "$@" \
          bash "$G/bin/gh-token.sh" --pat example-org/proj-repo 2>/dev/null; }
: > "$T/curl.log"
OUT=$(gt3 GH_TOKEN=ghp_envpat)
[ "$OUT" = ghp_envpat ] && ok || bad "3a: --pat answers the env PAT on an armed box, got '$OUT'"
[ ! -s "$T/curl.log" ] && ok || bad "3b: --pat must never call GitHub to mint ($(wc -l < "$T/curl.log") curl calls)"
printf 'GH_PAT=ghp_filepat\n' > "$G/env/gh-pat"
OUT=$(gt3)
[ "$OUT" = ghp_filepat ] && ok || bad "3c: with no GH_TOKEN and no keyring, --pat reads env/gh-pat, got '$OUT'"
rm -f "$G/env/gh-pat"
gt3 >/dev/null; RC=$?
[ "$RC" != 0 ] && ok || bad "3d: --pat with no PAT anywhere must fail, not print nothing at rc 0"

# ── 4. the admin PAT never answers --pat, and never wins the default fallback ──
# Review round 2 of #2231 (security). On a box whose keyring is logged out
# (C2) and whose env/global.env carries no GH_TOKEN, the lib's default probe
# ran `env -u GH_TOKEN gh api repos/<slug>` — no identity at all — so a private
# repo failed it and the ADMIN rung answered before env/gh-pat was reached.
# `gh-token.sh --pat` printed GH_ADMIN_TOKEN and bin/fly-envbundle.sh shipped
# the org-admin PAT to a Fly machine running agents. Here with the REAL
# gh-token.sh, the REAL lib and the REAL fly-envbundle.sh: the private repo is
# visible to the plain PAT and to the admin PAT, invisible without a token.
R="$T/r"; mkdir -p "$R/bin/lib" "$R/env" "$R/state" "$R/logs" "$R/locks" "$T/fb4"
cp "$DIR/bin/gh-token.sh" "$DIR/bin/fly-envbundle.sh" "$R/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$R/bin/lib/"
cp "$H/bin/fleet-conf.sh" "$R/bin/"
chmod +x "$R/bin/gh-token.sh" "$R/bin/fly-envbundle.sh" "$R/bin/fleet-conf.sh"
ADMIN=ghp_ADMINsecretfixture
printf 'GH_ADMIN_TOKEN=%s\n' "$ADMIN" > "$R/env/github-admin.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=oauth-fixture\n' > "$R/env/global.env"
printf 'BOARD_TOKEN=board-fixture\n' > "$R/env/proj.env"
printf '#!/bin/bash\necho "{}"\n' > "$T/fb4/curl"
cat > "$T/fb4/gh" <<'STUB'
#!/bin/bash
# logged-out keyring: `gh auth token` has nothing; a repos/ read needs a token
[ "$1 $2" = "auth token" ] && exit 1
if [ "$1" = api ]; then
  case "${GH_TOKEN:-}" in ghp_filepat|ghp_ADMINsecretfixture) echo 42; exit 0 ;; esac
  echo "HTTP 404: Not Found" >&2; exit 1
fi
exit 1
STUB
chmod +x "$T/fb4/curl" "$T/fb4/gh"
gt4() { # gt4 <gh-token.sh args…>; env via GT4_ENV
  env -i PATH="$T/fb4:/usr/bin:/bin" HOME="$T" HARNESS="$R" HARNESS_ENV_DIR="$R/env" ${GT4_ENV:-} \
    bash "$R/bin/gh-token.sh" "$@" 2>"$T/gt4.err"
}
arm4()   { : > "$R/env/github-app.pem"; printf 'GH_APP_ID=1\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$R" > "$R/env/github-app.env"; }
unarm4() { rm -f "$R/env/github-app.env" "$R/env/github-app.pem"; }

# 4a — admin file + gh-pat, keyring empty, no GH_TOKEN: --pat is the plain PAT
printf 'GH_PAT=ghp_filepat\n' > "$R/env/gh-pat"
unarm4; OUT=$(GT4_ENV= gt4 --pat example-org/harness-console)
[ "$OUT" = ghp_filepat ] && ok || bad "4a: --pat must answer env/gh-pat, not the admin PAT (got '${OUT:+${OUT:0:8}…}')"
# 4b — same box, the NORMAL path after a mint that failed: the plain PAT, not admin
arm4; OUT=$(GT4_ENV= gt4 example-org/harness-console)
[ "$OUT" = ghp_filepat ] && ok || bad "4b: the post-mint-failure fallback must be env/gh-pat, not the admin PAT (got '${OUT:+${OUT:0:8}…}')"
# the lib alone: the default rung is the plain PAT and answers before admin
LIBOUT=$(env -i PATH="$T/fb4:/usr/bin:/bin" HOME="$T" HARNESS="$R" HARNESS_ENV_DIR="$R/env" _GHRT_NO_APP=1 \
  bash -c '. "$HARNESS/bin/lib/gh-repo-token.sh"; r=$(gh_repo_token_for example-org/harness-console); gh_repo_use_token example-org/harness-console; printf "%s %s" "$r" "${GH_TOKEN:-unset}"' 2>/dev/null)
[ "$LIBOUT" = "default ghp_filepat" ] && ok || bad "4b2: the lib's default rung must be env/gh-pat before admin (got '${LIBOUT%% *}')"
# 4d — ONLY the admin file (no gh-pat, no keyring, no GH_TOKEN): nothing, rc 1, a named error
rm -f "$R/env/gh-pat"; unarm4
OUT=$(GT4_ENV= gt4 --pat example-org/harness-console); RC=$?
[ -z "$OUT" ] && ok || bad "4d: --pat with only the admin file must print nothing (printed ${#OUT} chars)"
[ "$RC" != 0 ] && ok || bad "4d2: --pat with no plain PAT must fail (rc $RC)"
grep -q 'no PAT' "$T/gt4.err" && ok || bad "4d3: --pat must say why it has nothing, got: $(cat "$T/gt4.err")"
grep -q "$ADMIN" "$T/gt4.err" && bad "4d4: the admin token reached stderr" || ok
# 4e — an inherited GH_TOKEN that IS the admin PAT (a lane that routed through
# the admin rung, then built a bundle) is refused, and so is an App token
printf 'GH_PAT=ghp_filepat\n' > "$R/env/gh-pat"
OUT=$(GT4_ENV="GH_TOKEN=$ADMIN" gt4 --pat example-org/harness-console)
[ "$OUT" = ghp_filepat ] && ok || bad "4e: an inherited admin GH_TOKEN must never be --pat's answer"
OUT=$(GT4_ENV="GH_TOKEN=ghs_installfixture" gt4 --pat example-org/harness-console)
[ "$OUT" = ghp_filepat ] && ok || bad "4e2: an inherited App installation token is not a PAT"

# 4c — the real fly-envbundle.sh never carries the admin string, in any configuration
for pat in file none; do
  for inh in none admin; do
    for arm in armed unarmed; do
      if [ "$pat" = file ]; then printf 'GH_PAT=ghp_filepat\n' > "$R/env/gh-pat"; else rm -f "$R/env/gh-pat"; fi
      if [ "$arm" = armed ]; then arm4; else unarm4; fi
      rm -rf "$T/out4"; mkdir -p "$T/out4"
      IE=""; [ "$inh" = admin ] && IE="GH_TOKEN=$ADMIN"
      env -i PATH="$T/fb4:/usr/bin:/bin" HOME="$T" HARNESS="$R" HARNESS_ENV_DIR="$R/env" $IE \
        bash "$R/bin/fly-envbundle.sh" proj "$T/out4" >/dev/null 2>"$T/eb4.err"
      if grep -rq "$ADMIN" "$T/out4" "$T/eb4.err" 2>/dev/null; then
        bad "4c: the admin PAT reached the bundle (gh-pat=$pat inherited=$inh app=$arm)"
      else ok; fi
      if [ "$pat" = file ]; then
        grep -qx 'GH_TOKEN=ghp_filepat' "$T/out4/global.env" 2>/dev/null && ok \
          || bad "4c2: the bundle's GH_TOKEN must be env/gh-pat (gh-pat=$pat inherited=$inh app=$arm)"
      fi
    done
  done
done
rm -f "$R/env/gh-pat"

echo "fly-envbundle-app-token.c2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
