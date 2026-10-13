#!/bin/bash
# shellcheck shell=bash
# bin/lib/console-pages.sh — the console-ui Cloudflare Pages names, in one place.
#
# WHY: the live console sat 15 days on dee684a1 while about 230 console-ui
# commits merged (BH-3554). The deployer and the drift detector must agree on
# which project, which URL, which settings row and which main commit they mean.
# WHAT: the Pages project, the production URL, the settings key holding the last
# deployed sha, the sha main wants deployed, and the Cloudflare account id.
# Sourced by the deployer and the drift detector.
# FAILURE: each reader returns rc 1 and prints nothing when it has no answer, so
# a caller never deploys or compares against an empty sha. The API token is
# never read here.
#
# Side-effect-free when sourced, safe under the caller's `set -u`, and it does
# not change the caller's shell options.

CONSOLE_PAGES_SHA_KEY=deploy.console-ui.sha

console_pages_project() { printf '%s\n' "${CONSOLE_PAGES_PROJECT:-mission-control}"; }

console_pages_url() {
  local u="${CONSOLE_PAGES_URL:-https://console.example.pages.dev}"
  while [ "${u%/}" != "$u" ]; do u=${u%/}; done
  printf '%s\n' "$u"
}

# console_pages_want <git-dir> <ref> — main's last FIRST-PARENT commit touching
# console-ui/. A branch commit is not on main's first-parent line, and the drift
# detector compares against main, so the merge commit is the answer.
console_pages_want() {
  local d="${1:-}" ref="${2:-}" s
  [ -n "$d" ] && [ -n "$ref" ] || return 1
  s=$(git -C "$d" rev-list -1 --first-parent "$ref" -- console-ui 2>/dev/null) || return 1
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

# console_pages_account_id <tree> — a non-empty CLOUDFLARE_ACCOUNT_ID wins, else
# the first uncommented "account_id" in <tree>/worker/jobs/wrangler.jsonc.
console_pages_account_id() {
  local id="${CLOUDFLARE_ACCOUNT_ID:-}" f
  if [ -z "$id" ]; then
    f="${1:-}/worker/jobs/wrangler.jsonc"
    [ -n "${1:-}" ] && [ -r "$f" ] || return 1
    id=$(sed -n '/^[[:space:]]*\/\//d; /"account_id"[[:space:]]*:/{s/.*"account_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;q;}' "$f")
  fi
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}
