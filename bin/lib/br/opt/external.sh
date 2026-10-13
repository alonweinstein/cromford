#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/external.sh — BH-4664.0 (BH-4667): EXTERNAL PRs, the tracer.
#
# A third party's PR on an opted-in project (collaborator-1 on project-4 / project-3) gets
# the same pipeline a harness PR gets: a review that asks for changes, or a
# branch that went dirty, becomes a candidate of this lane. This file is the
# SOURCE and the SHARED GATES only. It pushes nothing and writes nothing on the
# PR: every action is a hook a sibling module defines in its own file —
#
#   br_xpr_fix      (extfix)     an external-changes-requested row that passed the gates
#   br_xpr_rebase   (extrebase)  an external-dirty row that passed the gates
#   br_xpr_nopush   (extpark)    the gate found no push right on the head repo
#   br_xpr_terminal (extpark)    the ladder reached a terminal on an external PR
#
# and an absent hook is one log line and rc 3 (no rung). AN EXTERNAL PR IS NEVER
# CLOSED, REBUILT OR ABANDONED by this lane: that belt is in the lane itself
# (br_is_external, br_close_pr), so it holds with this file missing too.
#
# Functions only. Nothing runs on source (bin/lib/br/opt/README.md).

# br_xpr_knob <settings-key> <ENV> <default> -> "<value>\t<src>"
#   The D1 settings row, then the env var, then the default; numbers only.
#   src is setting | env | default | outage. A settings OUTAGE reads the
#   default and never the env: a knob that turns on when the worker is down is
#   a knob nobody set.
br_xpr_knob() {
  local key="$1" env="$2" def="$3" v="" rc=1 e
  if command -v setting_get >/dev/null 2>&1; then
    rc=0; v=$(setting_get "$key" 2>/dev/null) || rc=$?
  fi
  case "$rc" in
    0) case "$v" in ''|*[!0-9]*) printf '%s\tdefault\n' "$def" ;; *) printf '%s\tsetting\n' "$v" ;; esac ;;
    2) e="${!env:-}"
       case "$e" in ''|*[!0-9]*) printf '%s\tdefault\n' "$def" ;; *) printf '%s\tenv\n' "$e" ;; esac ;;
    *) printf '%s\toutage\n' "$def" ;;
  esac
}

# br_xpr_candidate_reason <p> <slug> <num> <head> <pr-file> -> the reason word, or nothing.
#   A standing CHANGES_REQUESTED on the head first, then a dirty merge state.
#   An unreadable reviews list is one line and NO row: unreadable is not "no review".
br_xpr_candidate_reason() {
  local p="$1" slug="$2" num="$3" head="$4" pf="$5" b64 body rc=0
  b64=$(br_review_newest "$slug" "$num" "$head") || rc=$?
  case "$rc" in
    2) say "$p/$slug#$num: external PR — the reviews list would not read — unreadable is not 'no review', no row this tick"
       return 1 ;;
    0) body=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
       case "$body" in
         "$BR_LEAD_HDR"*) printf 'external-changes-requested'; return 0 ;;
       esac
       [ "$(br_review_verdict "$body")" = REQUEST_CHANGES ] && { printf 'external-changes-requested'; return 0; } ;;
  esac
  [ "$(jq -r '.mergeable_state // ""' "$pf" 2>/dev/null)" = dirty ] && printf 'external-dirty'
  return 0
}

# br_opt_external_candidates — the candidate source (br_candidates calls it last).
#   Rows: xreviews <p> <rkey> <reason> <url> - - -   (no ticket key, on purpose:
#   an outsider's branch name is not one of our keys).
br_opt_external_candidates() {
  local cutoff p slug k ksrc lf pf rc rows row num head url draft upd login upd_ep reason
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low blocked-resolver >/dev/null 2>&1; then
    say "the external-PR source is skipped this tick — the GitHub API budget is low"
    return 0
  fi
  command -v gh_rest_pr_list_all >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/../../gh-rest-list.sh" 2>/dev/null
  cutoff=$(( $(date -u +%s) - ${BR_REVIEW_LOOKBACK_SECS:-172800} ))
  lf=$(mktemp "${TMPDIR:-/tmp}/br-xpr.XXXXXX") || return 0
  pf=$(mktemp "${TMPDIR:-/tmp}/br-xpr.XXXXXX") || { rm -f "$lf"; return 0; }
  while read -r p; do
    [ -n "${p:-}" ] || continue
    [ -z "$ONLY" ] || [ "$ONLY" = "$p" ] || continue
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    [ -n "$slug" ] && [ "$slug" != "-" ] || continue
    IFS=$'\t' read -r k ksrc <<<"$(br_xpr_knob "external_pr.fix_rounds.$p" EXTERNAL_PR_FIX_ROUNDS 0)"
    if [ "${k:-0}" = 0 ]; then say "external fix rounds off for $p ($ksrc)"; continue; fi
    if ! command -v harness_pr_author_match >/dev/null 2>&1 || ! command -v gh_rest_pr_list_all >/dev/null 2>&1; then
      say "$p: external-PR source skipped — bin/lib/gh-pr-list.sh or gh-rest-list.sh is not loaded, and unknown ownership is never external"
      continue
    fi
    br_use_token "$slug"
    rc=0; gh_rest_pr_list_all "$slug" open 200 > "$lf" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ]; then
      say "$p: the open-PR list would not read (rc $rc, HTTP ${GH_REST_STATUS:-000}) — no external rows this tick"
      br_reset_token; continue
    fi
    rows=()
    mapfile -t rows < <(jq -r '.[]? | [((.number // "") | tostring), (.head.sha // ""), (.html_url // ""),
        ((.draft // false) | tostring), (.updated_at // ""), (.user.login // "")] | join("\u001f")' "$lf" 2>/dev/null)
    for row in "${rows[@]:-}"; do
      [ -n "${row:-}" ] || continue
      IFS=$'\x1f' read -r num head url draft upd login <<<"$row"
      [ -n "${num:-}" ] && [ -n "${head:-}" ] && [ -n "${login:-}" ] || continue
      [ "${draft:-false}" = true ] && continue
      [ -n "${upd:-}" ] || continue
      upd_ep=$(date -u -d "$upd" +%s 2>/dev/null) || continue
      [ "$upd_ep" -ge "$cutoff" ] || continue
      harness_pr_author_match "$login" && continue
      rc=0; gh_rest GET "repos/$slug/pulls/$num" > "$pf" 2>/dev/null || rc=$?
      if [ "$rc" != 0 ]; then
        say "$p/$slug#$num: external PR read failed (rc $rc, HTTP ${GH_REST_STATUS:-000}) — no row this tick"
        continue
      fi
      reason=$(br_xpr_candidate_reason "$p" "$slug" "$num" "$head" "$pf") || continue
      [ -n "$reason" ] || continue
      [ -n "${url:-}" ] || url="https://github.com/$slug/pull/$num"
      printf 'xreviews\t%s\t%s\t%s\t%s\t-\t-\t-\n' "$p" "$(br_rkey "$slug#$num")" "$reason" "$url"
    done
    br_reset_token
  done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
  rm -f "$lf" "$pf"
  return 0
}

# br_xpr_gate <p> <url> — rc 0 pass (BR_XPR_* exported), rc 3 refuse. A refusal
# writes nothing and pushes nothing, and a read that failed is a refusal (D11):
# an unreadable head repo is never "no push right" and an unreadable commit is
# never "quiet".
br_xpr_gate() {
  local p="$1" url="$2" slug num f rc k ksrc st head ref login hrepo fork mcm cdate cmail ep q qsrc m
  slug=$(br_slug_of_url "$url") || return 3
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 3
  f=$(mktemp "${TMPDIR:-/tmp}/br-xpr.XXXXXX") || return 3
  rc=0; gh_rest GET "repos/$slug/pulls/$num" > "$f" 2>/dev/null || rc=$?
  if [ "$rc" != 0 ] || ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    say "external $slug#$num: the PR would not read (rc $rc) — nothing done, retried next tick"
    rm -f "$f"; return 3
  fi
  # Joined on \x1f, not a tab: a tab is IFS whitespace, so an empty field (a
  # deleted head repo) would collapse and shift every field after it. The two
  # booleans are `tostring`, never `// ""`: jq's `//` reads false as absent.
  IFS=$'\x1f' read -r st head ref login hrepo fork mcm < <(jq -r '[(.state // ""), (.head.sha // ""), (.head.ref // ""),
      (.user.login // ""), (.head.repo.full_name // ""), (.head.repo.fork | tostring),
      (.maintainer_can_modify | tostring)] | join("\u001f")' "$f" 2>/dev/null)
  rm -f "$f"
  [ "${st:-}" = open ] || return 3
  IFS=$'\t' read -r k ksrc <<<"$(br_xpr_knob "external_pr.fix_rounds.$p" EXTERNAL_PR_FIX_ROUNDS 0)"
  if [ "${k:-0}" = 0 ]; then say "external fix rounds off for $p ($ksrc)"; return 3; fi
  # D3: our token can push to the head only when it is this repo, or a fork whose
  # author allowed maintainer edits.
  if [ -z "$hrepo" ] || [ -z "$head" ] || { [ "$fork" != true ] && [ "$fork" != false ]; }; then
    say "external $slug#$num: push right unreadable (head repo '${hrepo:-}') — nothing done, retried next tick"
    return 3
  fi
  if [ "$hrepo" != "$slug" ] && ! { [ "$fork" = true ] && [ "$mcm" = true ]; }; then
    command -v br_xpr_nopush >/dev/null 2>&1 && br_xpr_nopush "$p" "$url"
    say "external $slug#$num: no push right (fork, maintainer edits off) — left for the author"
    return 3
  fi
  # D4: the author is still working. A head this harness authored is quiet.
  f=$(mktemp "${TMPDIR:-/tmp}/br-xpr.XXXXXX") || return 3
  rc=0; gh_rest GET "repos/$slug/commits/$head" > "$f" 2>/dev/null || rc=$?
  cdate=$(jq -r '.commit.committer.date // ""' "$f" 2>/dev/null)
  cmail=$(jq -r '.commit.author.email // ""' "$f" 2>/dev/null)
  rm -f "$f"
  if [ "$rc" != 0 ] || [ -z "$cdate" ]; then
    say "external $slug#$num: the head commit would not read (rc $rc) — nothing done, retried next tick"
    return 3
  fi
  [ -n "${GI_EMAIL:-}" ] || { command -v gi_resolve >/dev/null 2>&1 && gi_resolve >/dev/null 2>&1; }
  if [ -z "$cmail" ] || [ -z "${GI_EMAIL:-}" ] || [ "$cmail" != "$GI_EMAIL" ]; then
    ep=$([ -n "$cdate" ] && date -u -d "$cdate" +%s 2>/dev/null) || { say "external $slug#$num: head commit date '$cdate' unparseable — nothing done"; return 3; }
    IFS=$'\t' read -r q qsrc <<<"$(br_xpr_knob external_pr.author_quiet_min EXTERNAL_PR_AUTHOR_QUIET_MIN 60)"
    m=$(( ( $(date -u +%s) - ep ) / 60 ))
    if [ "$m" -lt "$q" ]; then
      say "AUTHOR_ACTIVE $slug#$num head=${head:0:8} committed ${m}m ago (quiet window ${q}m) — retried next tick"
      return 3
    fi
  fi
  export BR_XPR_HEAD="$head" BR_XPR_REF="$ref" BR_XPR_SLUG="$slug" BR_XPR_NUM="$num" \
         BR_XPR_AUTHOR="$login" BR_XPR_ROUNDS="$k"
  return 0
}

# br_opt_external_rung <p> <rkey> <reason> <url> <rec> <tkey> — the gates, then
# the sibling's hook. rc is the hook's; rc 3 (no rung) on any refusal or when
# no hook is installed.
br_opt_external_rung() {
  local p="$1" rkey="$2" reason="$3" url="$4" hook
  say "$p/$rkey [$reason]: external PR $url — the shared gates"
  br_xpr_gate "$p" "$url" || return 3
  # The stamp is what keeps the belt on this record when a later candidate for
  # the same row arrives from another source with a non-external reason.
  br_set_field "$p" "$(br_cap_key "$p" "$rkey" -)" external true \
    || say "$p/$rkey [$reason]: the external stamp was not written — the close belt still refuses on the PR's author"
  BR_XPR_ACTIVE=1
  case "$reason" in
    external-changes-requested) hook=br_xpr_fix ;;
    external-dirty)             hook=br_xpr_rebase ;;
    *) hook="" ;;
  esac
  if [ -z "$hook" ] || ! command -v "$hook" >/dev/null 2>&1; then
    say "external $reason $BR_XPR_SLUG#$BR_XPR_NUM: no handler installed"
    return 3
  fi
  "$hook" "$@"
}
