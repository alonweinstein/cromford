#!/bin/bash
# bin/ensure-box-gh-app-default.sh <owner/repo | fleet.conf project>
#
# Make the GitHub App installation token this BOX's default GitHub identity:
# for interactive shells, for plain git, and for anything that reads GH_TOKEN
# out of the environment. Cron lanes do not read a login shell profile, so they
# are NOT covered by this script — they resolve the identity in-process through
# bin/lib/gh-app-auth.sh. This is the other half: the shell and git half.
#
# WHY (#424). One PAT is one 5000/h REST bucket for every lane on every box, and
# every box is still logged into github.com as a person in gh's keyring. An
# installation token is per-installation rate-limited, scoped to one repo, and
# dead in an hour.
#
# THE ORDER IS THE SAFETY ARGUMENT, and it is the order below:
#   1. not armed for App tokens at all -> say so and change NOTHING.
#   2. the mint did not return an installation token -> refuse. bin/gh-token.sh
#      prints the PAT when a mint fails, and swapping a working keyring login
#      for the PAT we already have is all downside.
#   3. write the profile snippet (whole file, tmp+mv, idempotent).
#   4. point git's credential helper for github.com at an INLINE helper that
#      mints through bin/gh-token.sh.
#   5. only THEN log the keyring login out, and only when a plain PAT survives
#      it (BH-4798). When the keyring is the box's only plain PAT (no GH_TOKEN in
#      env/global.env, no env/gh-pat), the logout is refused with one warn alert
#      naming env/gh-pat, step 6 still runs, and the script exits 3 ("installed,
#      logout deferred"). A re-run once env/gh-pat exists completes the logout.
#   6. print a smoke summary of what the App identity can actually read.
# Each step exits non-zero before the next one on failure, so "logged out with
# no credential path" cannot happen. At no instant is the box without one.
#
# WHY STEP 5 CHECKS FOR A SURVIVING PAT (BH-4798, 2026-10-06). The App token is
# the box's identity, but bin/gh-token.sh --pat still has to answer for the Fly
# env bundle, and its ladder is GH_TOKEN, the keyring, env/gh-pat. The small
# box's keyring was its only rung; this step logged it out at 02:38Z and every
# cromford and project-8 pool spawn died at the bundle after it.
#
# IT IS IDEMPOTENT. The snippet is rewritten whole, the .bashrc line is appended
# only when it is absent, and a box with no login says "nothing to log out"
# rather than claiming a logout it did not do.
#
# NO TOKEN VALUE IS EVER PRINTED OR WRITTEN. The profile snippet holds the
# COMMAND (`gh-token.sh <slug>`), never its answer, so the token it exports is
# minted fresh per shell and expires on its own.
#
# The smoke read is `repos/<slug>`, never `gh api user`: an installation is not
# a user, so /user answers HTTP 403 for a perfectly good token.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-$(cd "$HERE/.." && pwd)}"
SNIP="${GH_DEFAULT_PROFILE_SNIPPET:-/etc/profile.d/harness-gh-default.sh}"
BRC="${GH_DEFAULT_BASHRC:-/root/.bashrc}"
say() { echo "gh-app-default: $*"; }
die() { echo "gh-app-default: $*" >&2; exit 1; }

ARG="${1:-}"
[ -n "$ARG" ] || { echo "usage: ensure-box-gh-app-default.sh <owner/repo | fleet.conf project>" >&2; exit 2; }
case "$ARG" in
  */*) SLUG="$ARG" ;;
  *)   SLUG=$("$HERE/fleet-conf.sh" "$ARG" repo 2>/dev/null || true)
       case "${SLUG:-}" in */*) ;; *) echo "gh-app-default: '$ARG' is neither owner/repo nor a project with a fleet.conf row" >&2; exit 2 ;; esac ;;
esac

# 1. armed? -------------------------------------------------------------------
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"
if ! command -v gh_auth_armed >/dev/null 2>&1 || ! gh_auth_armed; then
  say "this box is NOT ARMED for App tokens (no env/github-app.env, GH_APP_TOKENS=0, or flags/gh-app-tokens-off) — gh's login is left exactly as it is"
  exit 0
fi

# 2. a real installation token, or nothing happens ----------------------------
TOK=$("$HERE/gh-token.sh" "$SLUG" 2>/dev/null)
case "${TOK:-}" in
  ghs_*) ;;
  *) die "the mint for $SLUG did not return an installation token (gh-token.sh answers the PAT when a mint fails). Nothing was written and nobody was logged out — fix env/github-app.env, the .pem, or the App's installation on $SLUG and re-run." ;;
esac

# 3. the profile snippet ------------------------------------------------------
mkdir -p "$(dirname "$SNIP")" 2>/dev/null
{
  printf '# Written by %s/bin/ensure-box-gh-app-default.sh — this box%s default GitHub identity.\n' "$H" "'s"
  printf '# The COMMAND lives here, never the token: gh-token.sh answers from its cache and\n'
  printf '# mints when it must, so every shell gets a token that dies in an hour.\n'
  printf '_hgt=$(%s/bin/gh-token.sh "%s" 2>/dev/null); [ -n "$_hgt" ] && export GH_TOKEN="$_hgt"; unset _hgt\n' "$H" "$SLUG"
} > "$SNIP.tmp" 2>/dev/null || die "cannot write $SNIP.tmp — nothing was changed and nobody was logged out"
mv "$SNIP.tmp" "$SNIP" 2>/dev/null || { rm -f "$SNIP.tmp" 2>/dev/null; die "cannot install $SNIP — nothing was changed and nobody was logged out"; }
chmod 644 "$SNIP" 2>/dev/null
say "wrote $SNIP (it exports GH_TOKEN from gh-token.sh for $SLUG)"
if [ -e "$BRC" ] && grep -qF "$SNIP" "$BRC" 2>/dev/null; then
  say "$BRC already sources it"
else
  printf '[ -r %s ] && . %s\n' "$SNIP" "$SNIP" >> "$BRC" 2>/dev/null \
    || die "cannot append the source line to $BRC — nobody was logged out"
  say "added one source line to $BRC"
fi

# 4. git's credential helper --------------------------------------------------
# WHY GIT NEEDS ONE AT ALL. Plain `git pull` on these boxes authenticates
# through gh's keyring helper, and step 5 below logs that login out. Without a
# replacement every `git pull` — bin/harness-sync.sh's included — answers "could
# not read Username for https://github.com", which cost the project-10 box 4 builds on
# 2026-07-29.
#
# WHY IT IS INLINE AND NOT A FILE. git runs a `!`-prefixed helper as
# `sh -c '<helper> "$@"' - get`, so a shell function is a complete helper: no
# new script to ship, propagate and keep in step with gh-token.sh.
#
# useHttpPath is what makes it repo-scoped: with it git's request carries
# `path=<owner>/<repo>.git`, so the token minted is the token for the repo git
# is actually talking to. The fallbacks, in order: that repo's installation
# token, then $GH_TOKEN (the PAT — a repo the App is not installed on still has
# to work), then nothing at all, which leaves git's own error as the answer. We
# never invent a credential. `store` and `erase` are answered with silence
# because nothing here caches, so there is nothing to write or forget.
CRED_HELPER="!f() { [ \"\$1\" = get ] || exit 0; p=; while IFS= read -r l; do [ -n \"\$l\" ] || break; case \"\$l\" in path=*) p=\${l#path=} ;; esac; done; t=; case \"\$p\" in */*) o=\${p%%/*}; r=\${p#*/}; r=\${r%%/*}; r=\${r%.git}; t=\$($H/bin/gh-token.sh \"\$o/\$r\" 2>/dev/null) ;; esac; [ -n \"\$t\" ] || t=\${GH_TOKEN:-}; [ -n \"\$t\" ] || exit 0; printf 'username=x-access-token\\npassword=%s\\n' \"\$t\"; }; f"
if ! git config --global --replace-all credential.https://github.com.helper "$CRED_HELPER" 2>/dev/null \
   || ! git config --global credential.https://github.com.useHttpPath true 2>/dev/null; then
  die "WARN could not set git's credential helper — the box keeps its current git auth and nobody was logged out"
fi
say "git's credential helper for github.com mints through $H/bin/gh-token.sh (useHttpPath, so it is scoped to the repo git asks for)"

# 5. and only now, the logout -------------------------------------------------
# env -u GH_TOKEN so gh reads the KEYRING rather than the token in this
# environment: with GH_TOKEN set, `gh auth status` reports that token and tells
# us nothing about whether a person is still logged in here.
#
# surviving_pat: rc 0 when a plain PAT other than the keyring exists, mirroring
# bin/gh-token.sh plain_pat's other two rungs. global.env is read as a FILE, not
# from this process: in a login shell GH_TOKEN is the snippet's ghs_ App token.
# An App token or the admin PAT does not count, because plain_pat skips both.
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
surviving_pat() {
  local adm t
  adm=$(sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$HENV/github-admin.env" 2>/dev/null | tr -d "\"' \t\r" | head -n 1)
  for t in \
    "$(sed -n 's/^\(export \)\{0,1\}GH_TOKEN=//p' "$HENV/global.env" 2>/dev/null | tr -d "\"' \t\r" | head -n 1)" \
    "$( [ -r "$HENV/gh-pat" ] && sed -e '/^[[:space:]]*#/d' -e 's/^export //' -e 's/^GH_TOKEN=//' -e 's/^GH_PAT=//' "$HENV/gh-pat" 2>/dev/null \
         | tr -d "\"' \t\r" | sed -n '/./{p;q;}')"; do
    [ -n "$t" ] || continue
    case "$t" in ghs_*) continue ;; esac
    [ -n "$adm" ] && [ "$t" = "$adm" ] && continue
    return 0
  done
  return 1
}
RC=0
if env -u GH_TOKEN gh auth status --hostname github.com >/dev/null 2>&1; then
  if ! surviving_pat; then
    say "logout SKIPPED: the keyring login is this box's only plain PAT (no GH_TOKEN in env/global.env, no env/gh-pat). Put the PAT in $HENV/gh-pat (mode 600) and re-run; that run completes the logout."
    "$H/bin/lane-alert.sh" --severity warn --id gh-keyring-only-pat gh-app-default \
      "$(hostname 2>/dev/null): keyring logout refused, the keyring is the only plain PAT, so the pool/dispatch env bundle would lose its GH_TOKEN. Action: write the PAT to $HENV/gh-pat (mode 600), then re-run bin/ensure-box-gh-app-default.sh $SLUG." \
      >/dev/null 2>&1 || true
    RC=3
  elif env -u GH_TOKEN gh auth logout --hostname github.com >/dev/null 2>&1; then
    say "logged the box login out of github.com"
    "$H/bin/lane-alert.sh" --resolve --id gh-keyring-only-pat gh-app-default \
      "$(hostname 2>/dev/null): keyring logout completed, a plain PAT survives it" >/dev/null 2>&1 || true
  else
    die "WARN gh auth logout failed — the keyring login is still there. The snippet and the git helper ARE installed, so the box is not stranded; re-run this once gh is healthy."
  fi
else
  say "nothing to log out — gh holds no github.com login on this box"
fi

# 6. the smoke summary --------------------------------------------------------
FULL=$(GH_TOKEN="$TOK" gh api "repos/$SLUG" --jq .full_name 2>/dev/null)
if [ -n "$FULL" ]; then
  say "the App identity reads $FULL"
  say "PAT fallback for repos the App is not installed on: bin/lib/gh-repo-token.sh (unchanged)"
  exit "$RC"
fi
die "WARN the App token could not read repos/$SLUG — the snippet and git helper are installed, but check the App's installation on that repo"
