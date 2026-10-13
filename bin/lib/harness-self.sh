#!/bin/bash
# bin/lib/harness-self.sh — WHO THE HARNESS IS on a GitHub thread (BH-2133).
# Sourced; defines functions and resolves its two knobs, nothing else.
#
# One allowlist, read by the two readers that must tell the harness's own
# comments from the board moving:
#   - bin/lib/gate-self-comments.sh (the GitHub-Issues triage gate), and
#   - bin/lib/prebuild-repro.sh pr_ledger_key (the repro gate's thread_fp).
#
# "Ours" is an ALLOWLIST of this fleet's GitHub Apps, never "any bot": a
# third-party bot (intercom[bot], a CRM relay) can carry a client's words, and
# absorbing it would eat a client turn. The PAT login is never in it — it is
# also the operator's own hand. The list is HARNESS_SELF_APPS, registered in
# catalog/lanes.d/_lib.harness-self.json with `settable: false` (a trust list
# moves only in env/global.env). Resolved through lib_env_apply harness-self, in
# a subshell, the way bin/lib/main-red-gate.sh does it. Nothing resolved = an
# empty list = nothing is ours = the behaviour before BH-2133.

_HSF_KV=$(
  exec 3>&1
  _HSF_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_HSF_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_HSF_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_HSF_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _HSF_K in HARNESS_SELF_APPS GATE_SELF_FAILOPEN_ALERT; do printf "%s\t%s\n" "$_HSF_K" "${!_HSF_K:-}" >&3; done' EXIT
  lib_env_apply harness-self >/dev/null 2>&1)
while IFS=$'\t' read -r _HSF_K _HSF_V; do
  if [ -n "$_HSF_K" ] && [ -n "$_HSF_V" ]; then printf -v "$_HSF_K" '%s' "$_HSF_V"; fi
done <<<"$_HSF_KV"
unset _HSF_KV _HSF_K _HSF_V

# harness_self_apps_json -> the allowlist as a JSON array of lowercase bare
# slugs (`app/x`, `x[bot]` and `x` all become "x"). `[]` when nothing resolved.
harness_self_apps_json() {
  local a out=""
  for a in ${HARNESS_SELF_APPS:-}; do
    a="${a#app/}"; a="${a%\[bot\]}"
    a=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
    [ -n "$a" ] && out="$out$a"$'\n'
  done
  printf '%s' "$out" | jq -R . | jq -sc 'map(select(length > 0)) | unique' 2>/dev/null || printf '[]'
}

# The jq predicate every reader uses, with $apps bound to harness_self_apps_json.
# Input: one comment, REST (`user.login`, `user.type`,
# `performed_via_github_app.slug`) or the normalized thread's `author` string.
# A login counts only when it is the App's own bot account: `<slug>[bot]`, or
# the bare slug on a `type: "Bot"` user.
# shellcheck disable=SC2034  # read by the sourcing libs
HARNESS_SELF_JQ_DEF='def hs_ours($apps):
  ((.user.login // .author // "") | tostring | ascii_downcase) as $l
  | ((.user.type // "") | tostring | ascii_downcase) as $t
  | ((.performed_via_github_app.slug // "") | tostring | ascii_downcase) as $s
  | ($l | sub("\\[bot\\]$"; "")) as $b
  | (($l | endswith("[bot]")) or $t == "bot") as $isbot
  | ($isbot and ($apps | index($b)) != null) or ($s != "" and ($apps | index($s)) != null);'
