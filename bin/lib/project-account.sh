#!/bin/bash
# bin/lib/project-account.sh — WHICH Claude account a project is pinned to (BH-1657).
#
#   . bin/lib/project-account.sh
#   account_for_project <project>      -> "label=<label|> source=db|env|none", rc 0
#   project_account_exports <project>  -> "export CLAUDE_CODE_OAUTH_TOKEN='...'" for eval
#                                         rc 0 pinned, rc 1 not pinned, rc 3 pinned but
#                                         <harness_env_dir>/accounts.d/<label>.env missing/unreadable
#   account_label_aliases <pin>        -> labels naming the same account (catalog/account-aliases.json)
#   project_account_live_matches <pin> -> rc 0 iff the live claude fp label is the pin or an alias
#   project_account_alert_unavailable <project> <label> <where> / project_account_alert_resolve <project>
#                                      -> the deduped account-pin-<box>-<project> warn alert (BH-3559)
#   ACCOUNT_PROJECT_FOR_LANE=<word>=<project> -> every lookup above for exactly <word>
#                                         reads <project> instead (_pacct_project)
#
# The assignment is DATA: a settings row `account.<project>` whose value is a LABEL,
# never a token (read through lane-gate's settings fetch and its 60s cache). Only
# when this box has no settings answer at all does the documented fallback apply:
# env ACCOUNT_OWN_PROJECTS="proj=label,proj2=label2". Nothing configured = the
# shared pool, exactly as before. The value `shared` is the explicit unpin: the
# worker refuses an empty value and has no DELETE, so this word is how the console
# puts a project back on the pool. It answers `label= source=db` (or env), so the
# caller can tell "unpinned on purpose" from "nothing configured". The token itself stays on disk in accounts.d and
# is only ever printed to stdout for the caller's eval, never to stderr or a log.

_pacct_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v _lg_setting_lookup >/dev/null 2>&1 && [ -r "$_pacct_dir/lane-gate.sh" ]; then
  . "$_pacct_dir/lane-gate.sh" >/dev/null 2>&1 || true
fi

_pacct_h() { printf '%s' "${HARNESS:-${H:-/root/harness}}"; }
command -v harness_env_dir >/dev/null 2>&1 || . "$_pacct_dir/env-path.sh" || return 1

# A label names a file under accounts.d, so it may not walk out of it.
_pacct_label_ok() {
  case "${1:-}" in ''|*/*|*..*|.*|*[!A-Za-z0-9:._@-]*) return 1 ;; esac
  return 0
}

# _pacct_project <name> — the project whose pin a lookup reads. An LLM alert
# lane calls bin/agent-call.sh with its lane WORD as the project, so its cost
# rows and its daily cap keep counting the lane. bin/lib/llm-lane-project.sh
# exports ACCOUNT_PROJECT_FOR_LANE=<word>=<project> for one project's run, and a
# lookup for exactly <word> then reads <project>'s pin. Any other name, an unset
# map, or a <project> that is not a plain name: <name> unchanged.
_pacct_project() {
  local n="${1:-}" m="${ACCOUNT_PROJECT_FOR_LANE:-}" w t
  case "$m" in ?*=*) ;; *) printf '%s' "$n"; return 0 ;; esac
  w="${m%%=*}"; t="${m#*=}"
  if [ -z "$n" ] || [ "$w" != "$n" ]; then printf '%s' "$n"; return 0; fi
  case "$t" in
    ''|.*|*[!A-Za-z0-9._-]*)
      printf 'project-account: refused ACCOUNT_PROJECT_FOR_LANE for %s: not a project name\n' "$n" >&2
      printf '%s' "$n"; return 0 ;;
  esac
  printf '%s' "$t"
}

account_for_project() {
  local p v="" src=none state=none pair unpinned=0
  p=$(_pacct_project "${1:-}")
  case "$p" in ''|*[!A-Za-z0-9._-]*) printf 'label= source=none\n'; return 0 ;; esac
  if command -v _lg_setting_lookup >/dev/null 2>&1; then
    _lg_settings_refresh >/dev/null 2>&1 || true
    state=$(_lg_settings_state 2>/dev/null || printf none)
    if [ "$state" != none ]; then
      v=$(_lg_setting_lookup "account.$p" 2>/dev/null) || v=""
      src=db
    fi
  fi
  if [ "$state" = none ]; then
    local IFS=','
    for pair in ${ACCOUNT_OWN_PROJECTS:-}; do
      pair="${pair// /}"
      [ "${pair%%=*}" = "$p" ] && { v="${pair#*=}"; src=env; break; }
    done
  fi
  [ "$v" = shared ] && { v=""; unpinned=1; }
  if [ -n "$v" ] && ! _pacct_label_ok "$v"; then
    printf 'project-account: refused label for %s (%s): not a plain label\n' "$p" "$src" >&2
    v=""
  fi
  [ -n "$v" ] || [ "$unpinned" = 1 ] || src=none
  printf 'label=%s source=%s\n' "$v" "$src"
}

account_label_for_project() {
  local r; r=$(account_for_project "${1:-}"); r="${r#label=}"; printf '%s' "${r%% *}"
}

project_account_exports() {
  local label f tok
  label=$(account_label_for_project "${1:-}")
  [ -n "$label" ] || return 1
  f="$(harness_env_dir "$(_pacct_h)")/accounts.d/$label.env"
  [ -r "$f" ] || return 3
  tok=$( set +u; CLAUDE_CODE_OAUTH_TOKEN=""; . "$f" >/dev/null 2>&1; printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" )
  case "$tok" in ''|*[!A-Za-z0-9._-]*) return 3 ;; esac
  printf "export CLAUDE_CODE_OAUTH_TOKEN='%s'\n" "$tok"
}

# ALIASES (BH-3559). An owning box labels its own project token by the name its
# overlay gave it (state/auth-accounts.local.json: claude:project-3-dedicated), while
# the pin says own:project-3. Same account, two labels, so every pin refused on the
# box it belongs to. catalog/account-aliases.json (repo-managed, synced with the
# rest of catalog/) maps a pin label to the labels that name the same account.
# Labels only, never a token. A missing or malformed file gives no aliases, which
# is the exact-label match of before, never a wider one.
account_label_aliases() { # <pin> -> one alias per line
  local pin="${1:-}" f a
  _pacct_label_ok "$pin" || return 0
  f="${ACCOUNT_ALIASES_CATALOG:-$(_pacct_h)/catalog/account-aliases.json}"
  [ -r "$f" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg p "$pin" '.[$p][]? | strings' "$f" 2>/dev/null | while IFS= read -r a; do
    [ "$a" != unknown ] && _pacct_label_ok "$a" && printf '%s\n' "$a"
  done
}

# project_account_live_matches <pin> — rc 0 iff the live claude credential's fp
# label is the pin or one of its aliases. An unmapped fp (`unknown`) never matches.
project_account_live_matches() {
  local pin="${1:-}" live a
  _pacct_label_ok "$pin" || return 1
  if ! command -v auth_account_for_fp >/dev/null 2>&1; then
    [ -r "$_pacct_dir/../auth-fingerprint.sh" ] || return 1
    . "$_pacct_dir/../auth-fingerprint.sh" >/dev/null 2>&1 || return 1
  fi
  live=$(auth_account_for_fp "$(auth_fp_for_runner claude 2>/dev/null)" 2>/dev/null)
  case "$live" in ''|unknown) return 1 ;; esac
  [ "$live" = "$pin" ] && return 0
  while IFS= read -r a; do
    [ "$live" = "$a" ] && return 0
  done < <(account_label_aliases "$pin")
  return 1
}

# A PIN THAT RESOLVES NOWHERE IS A CONFIG DEFECT, NOT A QUOTA EVENT (BH-3559).
# It was only ever written to failovers.log and account-routing.log, and three
# boxes refused every claude call for 32 hours with nobody told. One warn
# lane-alert per box+project per ACCOUNT_PIN_ALERT_WINDOW_S (default 6 h),
# stamped in state/account-pin/<project>.alerted. The stamp is written first,
# under a non-blocking flock so concurrent refusals send once, and removed again
# when the send fails so the next refusal retries. No lane-alert.sh, no alert
# and no stamp: the routing logs still carry the refusal.
_pacct_alert_box() { local b="${ACCOUNT_PIN_BOX:-$(hostname -s 2>/dev/null)}"; printf '%s' "${b:-unknown-box}"; }
_pacct_alert_id() { printf 'account-pin-%s-%s' "$(_pacct_alert_box)" "$1" | tr -c 'A-Za-z0-9._-' '_'; }

project_account_alert_unavailable() { # <project> <label> <where>
  local p label="${2:-}" where="${3:-}" h dir stamp la box win age now
  p=$(_pacct_project "${1:-}")
  case "$p" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  h=$(_pacct_h); la="$h/bin/lane-alert.sh"
  [ -x "$la" ] || return 0
  dir="$h/state/account-pin"; stamp="$dir/$p.alerted"
  mkdir -p "$dir" 2>/dev/null || return 0
  win="${ACCOUNT_PIN_ALERT_WINDOW_S:-21600}"
  case "$win" in ''|*[!0-9]*) win=21600 ;; esac
  (
    flock -n 8 || exit 1
    if [ -f "$stamp" ]; then
      now=$(date +%s); age=$(( now - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ))
      [ "$age" -ge "$win" ] || exit 1
    fi
    touch "$stamp"
  ) 8>"$stamp.lock" || return 0
  box=$(_pacct_alert_box)
  timeout 30 "$la" --severity warn --id "$(_pacct_alert_id "$p")" account-pin \
    "$box: pinned account $label for $p cannot resolve a token ($where); claude calls for $p on this box are refused rc 76 and descend to non-claude rungs. Fix: accounts.d/$label.env on the box or an alias in catalog/account-aliases.json" \
    >/dev/null 2>&1 || rm -f "$stamp"
  return 0
}

project_account_alert_resolve() { # <project>
  local p h stamp
  p=$(_pacct_project "${1:-}")
  case "$p" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  h=$(_pacct_h); stamp="$h/state/account-pin/$p.alerted"
  [ -f "$stamp" ] && [ -x "$h/bin/lane-alert.sh" ] || return 0
  timeout 30 "$h/bin/lane-alert.sh" --resolve --id "$(_pacct_alert_id "$p")" account-pin \
    "$(_pacct_alert_box): pinned account for $p resolves again" >/dev/null 2>&1 && rm -f "$stamp"
  return 0
}
