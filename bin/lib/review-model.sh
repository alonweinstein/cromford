#!/bin/bash
# bin/lib/review-model.sh — which model reads a diff.
# Side-effect-free: READS the env file rather than sourcing it (the same shape as
# bin/lib/triage-shards-lib.sh:_tsh_env), prints only a model word, never a secret.
#
# rules/CLAUDE.md "AI model config": agents never hardcode claude-* model strings.
# The operator's per-box edit point is still REVIEW_MODEL (the environment, then
# env/global.env). With neither set, the answer is the `build.review`
# model_routes row (BH-1510.1), read through bin/lib/model-route.sh — the
# project's own ladder when the caller names a project. There is no literal
# fallback any more: with no route and no cached answer the answer is empty with
# rc 75, the resolver has already written the ALERTS line naming the role, and
# the caller buys no review on it.
# Bash, like bin/lib/model-route.sh and every caller.

# review_model [harness] [project] -> the model word; rc 75 = no route anywhere
review_model() {
  local h="${1:-${HARNESS:-/root/harness}}" p="${2:-}" v="${REVIEW_MODEL:-}" dir="" self
  if [ -z "$v" ]; then
    if command -v harness_env_dir >/dev/null 2>&1; then
      dir=$(harness_env_dir "$h")
    elif [ -r "$h/bin/lib/env-path.sh" ]; then
      # shellcheck source=bin/lib/env-path.sh
      . "$h/bin/lib/env-path.sh" && dir=$(harness_env_dir "$h")
    fi
    [ -n "$dir" ] || dir="$h/env"
    if [ -r "$dir/global.env" ]; then
      v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}REVIEW_MODEL=//p' "$dir/global.env" \
          | tr -d '"'"'"' \t' | tail -1)
    fi
  fi
  if [ -z "$v" ]; then
    if ! command -v model_for >/dev/null 2>&1; then
      # The resolver keeps its cache and alerts under the harness it was
      # loaded for, so it is loaded for THIS one.
      self="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
      # shellcheck source=bin/lib/model-route.sh
      if [ -n "$self" ] && [ -r "$self/model-route.sh" ]; then HARNESS="$h" . "$self/model-route.sh"
      elif [ -r "$h/bin/lib/model-route.sh" ]; then HARNESS="$h" . "$h/bin/lib/model-route.sh"; fi
    fi
    command -v model_for >/dev/null 2>&1 || return 75
    v=$(model_for build.review "$p") || return $?
  fi
  [ -n "$v" ] || return 75
  printf '%s\n' "$v"
}
