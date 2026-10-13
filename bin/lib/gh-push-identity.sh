#!/bin/bash
# gh-identity: raw-by-design — its gh calls ARE the identity probe (which token is about to push, and whether the branch admits it). Arming inside it would answer with an identity the lane is not holding, and the protection read walks its own current-then-admin-then-default ladder for the same reason.
# bin/lib/gh-push-identity.sh — WHICH identity is about to push, and whether the
# branch's protection lets it. Sourced, never executed.
#
#   gh_token_identity            -> `app/<slug>` | a PAT login | `unknown`
#   gh_branch_protection <slug> <branch>
#                                -> "ok<TAB><json>" | "unprotected"
#                                   | "unreadable <code>"
#   gh_push_blocked_verdict <json> <identity>
#                                -> protected | allowlisted | identity | unexplained
#   gh_push_allowlist_summary <json>   -> the allow-list, for the log line
#   gh_identity_alert <lane> <slug> <identity> <branch>
#                                -> ONE ALERTS line + beat per (lane, repo,
#                                   identity, UTC day)
#
# Why the lanes need this, what the four verdicts mean and which ones page:
# docs/verification-map/push-identity-not-permitted.md. TOKEN VALUES NEVER LEAVE
# THIS FILE — only the identity WORD is printed, logged, alerted or used in a
# filename, and tests/gh-push-identity.bh-800-test.sh asserts it.
[ -n "${_GHPI_LOADED:-}" ] && return 0
_GHPI_LOADED=1

declare -A _GHPI_ID _GHPI_PROT
# The token this process STARTED with: the last rung of the read ladder below,
# for a lane that has since exported a per-repo token over it.
_GHPI_DEFAULT_TOK="${GH_TOKEN:-}"

_ghpi_h() { printf '%s' "${HARNESS:-/root/harness}"; }

# Env files live in /etc/harness/env on a live box with $HARNESS/env a compat
# symlink, and bin/lib/env-path.sh owns that decision for every reader. A tree
# without the resolver (a fixture that copies one lib into a scratch root) falls
# back to the root's own env directory, which is what those trees have.
_ghpi_env_dir() {
  local h; h=$(_ghpi_h)
  command -v harness_env_dir >/dev/null 2>&1 || {
    # shellcheck source=bin/lib/env-path.sh
    [ -r "$h/bin/lib/env-path.sh" ] && . "$h/bin/lib/env-path.sh"; }
  if command -v harness_env_dir >/dev/null 2>&1; then harness_env_dir "$h"
  else printf '%s/env\n' "$h"; fi
}

# The App's own login, read (never sourced) from env/github-app.env, slugged the
# way GitHub slugs an App name. Same derivation and default as gh-pr-list.sh's
# _hpl_app_login.
_ghpi_app_login() {
  local raw
  raw=$(sed -n 's/^\(export \)\{0,1\}GH_APP_SLUG=//p;s/^\(export \)\{0,1\}GH_APP_NAME=//p' \
        "$(_ghpi_env_dir)/github-app.env" 2>/dev/null | tr -d "\"'" | head -n 1)
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$raw" ] || raw="cromford"
  printf 'app/%s\n' "$raw"
}

# `app/cromford` and `cromford[bot]` are one App spelled by GraphQL and
# by REST. The bare name is what a push allow-list holds.
_ghpi_bare() { local l="${1#app/}"; printf '%s' "${l%\[bot\]}"; }

_ghpi_admin_tok() {
  sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$(_ghpi_env_dir)/github-admin.env" 2>/dev/null \
    | tr -d "\"'" | head -n 1
}

# gh_token_identity -> the identity word for the GH_TOKEN in effect.
#   AN APP INSTALLATION TOKEN CANNOT CALL /user (403) and no endpoint it can
#   call carries the App's slug, so `ghs_` short-circuits to the configured slug
#   and the call is never made. Anything else is a PAT (or gh's keyring when
#   GH_TOKEN is unset) and answers its own login; nothing resolvable at all is
#   the word `unknown`, never a plausible login (D26).
#   Cached per token FINGERPRINT (never the value) for the life of the process.
#   KNOWN DRIFT (C2, 2026-09-24): with GH_TOKEN unset this names the keyring's
#   login (`gh api user` has no repo, so bin/gh-ledger/gh leaves it on the
#   keyring), while a later call from the same shell aimed at a example-org repo
#   runs on the App (the C2 default identity in the ledger shim). The word can
#   name the PAT for a merge the App made. Callers that must be exact set
#   GH_TOKEN before asking; after the fleet keyring logout the word reads
#   `unknown`.
gh_token_identity() {
  local tok="${GH_TOKEN:-}" fp id
  fp=$(printf '%s' "$tok" | sha256sum 2>/dev/null | cut -c1-12)
  [ -n "$fp" ] || fp="nofingerprint"
  if [ -n "${_GHPI_ID[$fp]+x}" ]; then printf '%s\n' "${_GHPI_ID[$fp]}"; return 0; fi
  case "$tok" in
    ghs_*) id=$(_ghpi_app_login) ;;
    *)     id=$(gh api user -q .login 2>/dev/null | head -n 1) ;;
  esac
  id=$(printf '%s' "$id" | tr -d '[:space:]')
  [ -n "$id" ] || id="unknown"
  _GHPI_ID[$fp]="$id"
  printf '%s\n' "$id"
}

# gh_branch_protection <owner/repo> <branch>
#   -> "ok<TAB><compact json>" | "unprotected" | "unreadable <code|unparseable|rcN>"
#
#   CLASSIFIED ONLY BY THE HTTP STATUS (D9/D10/D35, the #796 family; since
#   BH-1586 gh_rest's 0/44/75, no longer gh's stderr). A 403 is not a 404: the first means we
#   could not read the protection, the second means there is none, and reading
#   one as the other either invents a verdict or throws a real one away. A body
#   is never classified on its prose — only parsed, or refused as unparseable.
#
#   THE TOKEN LADDER: the token in effect, then the org-admin PAT from
#   env/github-admin.env, then the token this process started with. An App
#   installation token frequently lacks Administration:read and 403s on this
#   endpoint, which is exactly the case this feature exists for. The identity
#   WORD is always the token the MERGE would run on, never the one that managed
#   to read the protection.
#
#   Cached per (repo, branch) for the life of the PROCESS. A caller inside a
#   command substitution gets a fresh subshell and a fresh cache, which is why
#   each lane carries its own cache keyed the way that lane iterates — one read
#   per repo per run/tick is the property (D21); this cache is the belt.
#
#   READ THROUGH gh_rest (BH-1586), so the read is ledgered and ETag-cached,
#   and classified by the library's own 0 / 44 / 75: 44 is a 404 (unprotected),
#   75 names GH_REST_STATUS (403, 429, 5xx) or `rcN` when no status came back.
#   AND CACHED ACROSS PROCESSES for GH_POLICY_TTL_SECS (bin/lib/gh-policy-cache.sh):
#   `ok …` only, per token (see _ghpi_prot_cache_put). `unprotected` and
#   `unreadable …` are never kept, so they are asked again on the next tick.
_ghpi_rest_load() {
  local d
  for d in "$(_ghpi_h)/bin/lib" "${BASH_SOURCE[0]%/*}"; do
    command -v gh_policy_read >/dev/null 2>&1 || { [ -r "$d/gh-policy-cache.sh" ] && . "$d/gh-policy-cache.sh"; }
    command -v gh_rest >/dev/null 2>&1 || { [ -r "$d/gh-rest.sh" ] && . "$d/gh-rest.sh"; }
  done
  return 0
}

# _ghpi_prot_read <slug> <branch> <cur|adm|def> <tok> <outfile> -> gh_rest's rc.
#   A GH_TOKEN prefix on a FUNCTION lasts for that call only, and the read goes
#   to a FILE so GH_REST_STATUS survives in this shell for the `unreadable` word.
_ghpi_prot_read() {
  local rc=0
  command -v gh_rest >/dev/null 2>&1 || { GH_REST_STATUS=000; return 75; }
  if [ "$3" = cur ]; then gh_rest GET "repos/$1/branches/$2/protection" > "$5" || rc=$?
  else GH_TOKEN="$4" gh_rest GET "repos/$1/branches/$2/protection" > "$5" || rc=$?
  fi
  return "$rc"
}

# _ghpi_prot_ladder <slug> <branch> <tmpfile> — walks the token ladder and sets
#   _GHPI_ANS in THIS shell (never call it inside `$( )`).
_ghpi_prot_ladder() {
  local slug="$1" branch="$2" t="$3" cand tok rc last="unknown" seen=" " compact
  _GHPI_ANS=""
  for cand in "cur:${GH_TOKEN:-}" "adm:$(_ghpi_admin_tok)" "def:$_GHPI_DEFAULT_TOK"; do
    tok="${cand#*:}"
    [ "${cand%%:*}" = cur ] || [ -n "$tok" ] || continue
    case "$seen" in *" $tok "*) continue ;; esac
    seen="$seen$tok "
    rc=0; _ghpi_prot_read "$slug" "$branch" "${cand%%:*}" "$tok" "$t" || rc=$?
    case "$rc" in
      0)  compact=$(jq -c . "$t" 2>/dev/null)
          if [ -n "$compact" ]; then _GHPI_ANS=$(printf 'ok\t%s' "$compact"); return 0; fi
          last="unparseable" ;;
      44) _GHPI_ANS="unprotected"; return 0 ;;
      *)  last="${GH_REST_STATUS:-000}"; [ "$last" = 000 ] && last="rc$rc" ;;
    esac
  done
  _GHPI_ANS="unreadable $last"
}

# _ghpi_prot_cache_put <slug> <branch> <answer> <tmpfile> — answers only.
#   ONLY `ok …` IS EVER CACHED, AND PER TOKEN (#1605 review). `unprotected` is a
#   404, and GitHub answers 404 for a branch the token cannot see, so it is
#   re-asked every time (an ETag'd read). The entry name carries a FINGERPRINT
#   of the token in effect (never the value), so two identities on one hub can
#   never be served each other's answer.
_ghpi_tok_fp() {
  local fp
  fp=$(printf '%s' "${GH_TOKEN:-}" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -c1-12)
  printf '%s' "${fp:-nofp}"
}

_ghpi_prot_cache_put() { # <slug> <branch> <answer> <tmpfile> <token-fp>
  command -v gh_policy_cache_put >/dev/null 2>&1 || return 0
  case "$3" in
    ok*) printf '%s' "$3" > "$4" && gh_policy_cache_put "$1" "protection-$2-$5" 0 "$4" ;;
  esac
  return 0
}

gh_branch_protection() {
  local slug="$1" branch="$2" key="$1 $2" ans="" t fp
  if [ -n "${_GHPI_PROT[$key]+x}" ]; then printf '%s\n' "${_GHPI_PROT[$key]}"; return 0; fi
  _ghpi_rest_load
  t=$(mktemp) || t=/dev/null
  fp=$(_ghpi_tok_fp)
  if command -v gh_policy_cache_get >/dev/null 2>&1; then
    gh_policy_ttl_resolve
    gh_policy_cache_get "$slug" "protection-$branch-$fp" "$t" && ans=$(cat "$t" 2>/dev/null)
  fi
  if [ -z "$ans" ]; then
    _ghpi_prot_ladder "$slug" "$branch" "$t"; ans="$_GHPI_ANS"
    _ghpi_prot_cache_put "$slug" "$branch" "$ans" "$t" "$fp"
  fi
  [ "$t" = /dev/null ] || rm -f "$t"
  _GHPI_PROT[$key]="$ans"
  printf '%s\n' "$ans"
}

# gh_push_blocked_verdict <protection-json> <identity> -> one of four words:
#   protected    something on this branch genuinely gates the merge — a required
#                check, a required review, conversation resolution, or a lock
#   allowlisted  nothing gates it and this identity IS allowed to push, so the
#                block comes from somewhere this box cannot see; retry, no page
#   identity     nothing gates it, there IS a push allow-list, and this identity
#                is not on it: no amount of waiting fixes that
#   unexplained  we cannot say — no `restrictions` block to be absent from, or
#                an identity we could not name. Annotated, never paged.
#   Pure: no calls, no state, no writes.
gh_push_blocked_verdict() {
  local json="${1:-}" id="${2:-}" bare
  # Any gate at all, INCLUDING the two #846 did not look at: a branch with
  # `required_conversation_resolution` or `lock_branch` on and no checks reads
  # as "nothing required" to a two-field test, and BLOCKED there is the merge
  # being gated, not the push being refused.
  jq -e '(.required_status_checks != null) or (.required_pull_request_reviews != null)
         or (.required_conversation_resolution.enabled == true) or (.lock_branch.enabled == true)' \
     >/dev/null 2>&1 <<<"$json" && { printf 'protected\n'; return 0; }
  # No allow-list means nothing to be absent FROM, so BLOCKED came from
  # something this read does not cover (a ruleset, a queue). Naming an identity
  # here would page an admin about a list that does not exist.
  jq -e '.restrictions != null' >/dev/null 2>&1 <<<"$json" || { printf 'unexplained\n'; return 0; }
  [ -n "$id" ] && [ "$id" != unknown ] || { printf 'unexplained\n'; return 0; }
  # GitHub keeps the two lists apart and a push permission does not cross them:
  # a USER named cromford does not allow-list the cromford App, and an
  # App slug does not allow-list a PAT of the same name.
  case "$id" in
    app/*|*'[bot]')
      bare=$(_ghpi_bare "$id")
      jq -e --arg b "$bare" '((.restrictions.apps // []) | map((.slug // "") | ascii_downcase))
                             | index($b | ascii_downcase) != null' >/dev/null 2>&1 <<<"$json" ;;
    *)
      jq -e --arg u "$id" '((.restrictions.users // []) | map((.login // "") | ascii_downcase))
                           | index($u | ascii_downcase) != null' >/dev/null 2>&1 <<<"$json" ;;
  esac && printf 'allowlisted\n' || printf 'identity\n'
  return 0
}

# gh_push_allowlist_summary <protection-json> -> what the branch's push
#   allow-list actually holds, for the log line. `none listed` and `empty` are
#   different answers: the first is no restrictions block at all (the
#   `unexplained` verdict), the second is a block that admits nobody.
gh_push_allowlist_summary() {
  local sum
  sum=$(jq -r 'if (.restrictions // null) == null then "none listed"
               else (((.restrictions.users // []) | map(.login // empty))
                   + ((.restrictions.apps  // []) | map("app:" + (.slug // ""))))
                    | if length == 0 then "empty" else join(",") end end' <<<"${1:-}" 2>/dev/null)
  [ -n "$sum" ] || sum="unreadable"
  printf '%s\n' "$sum"
}

# gh_identity_alert <lane> <owner/repo> <identity> <branch>
#   ONE ALERTS.log line + fleet_alert beat per (lane, repo, identity, UTC day),
#   deduped on a flag file the way the sweep's invisible-repo page is. Per day,
#   not for ever: a config gap that comes back three weeks later is news again.
#   The flag is touched BEFORE the writes and the ALERTS line goes down before
#   the beat — the line is the record, the beat is best effort.
gh_identity_alert() {
  local lane="$1" slug="$2" id="$3" branch="${4:-main}" h flag line
  h=$(_ghpi_h)
  flag="$h/flags/alerted-identity-not-permitted-${lane}-${slug//\//_}-${id//\//_}-$(date -u +%Y%m%d)"
  [ -f "$flag" ] && return 0
  mkdir -p "$h/flags" "$h/logs" 2>/dev/null
  touch "$flag"
  line="[$lane] IDENTITY_NOT_PERMITTED $slug $id — GitHub says BLOCKED on $branch, but that branch requires no status check and no review, so this is a push restriction and not a PR state. Nothing merges on $slug while we run as $id. A repo admin needs to add $id to repos/$slug/branches/$branch/protection/restrictions."
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $line" >> "$h/logs/ALERTS.log"
  "$h/bin/beat.sh" "$(jq -nc --arg akey "identitynotpermitted:$lane:$slug:$id" --arg l "$line" \
    '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
  return 0
}
