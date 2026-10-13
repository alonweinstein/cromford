#!/bin/bash
# bin/lib/review-provenance.sh — WHO ACTUALLY READ THE CODE (2026-09-16).
#
# "Judge provenance" (2026-08-03) is one rule with one purpose: an APPROVE that
# auto-merges must have been authored by CLAUDE, because the judge node is the
# one place a cheaper lane costs everything. Until today that rule was written
# everywhere as a string compare against the RUNNER word — `[ "$runner" =
# claude ]`, `[ "$LEDGER_PROV" != claude ]`, `grep -qx claude` — and the runner
# word names the CLI that made the call, not the model that answered.
#
# THAT IS WRONG IN EXACTLY ONE DIRECTION, AND IT COST US A FINISHED BUILD.
# bin/agent-call.sh's tier-3 survival lane runs the codex CLI against OpenRouter
# with the STAGE'S OWN MODEL — deliberately, so that the fallback keeps the
# phase model (the operator, 2026-08-02: "never substitute deepseek — keep the phase
# model"). A review served that way is `runner=openrouter, model=anthropic/
# claude-fable-<version>`: a Claude model, reading the diff, writing the verdict. It
# is a claude read in every sense the merge gate cares about, and the fleet was
# throwing it away as a "fallback lane" — parking PRs on `provenance` and
# converting its APPROVEs into BLOCKs.
#
# SO THE RULE IS ABOUT THE (RUNNER, MODEL) PAIR, NOT THE RUNNER ALONE.
#   claude                                    -> claude    (the primary lane)
#   openrouter + an anthropic/ slug           -> claude    (Claude, via OpenRouter)
#   anything else, INCLUDING a non-claude
#   runner whose stale .model file still
#   names a claude-* model                    -> that runner's own word
#
# THE MODEL IS ONLY EVER CONSULTED FOR A RUNNER ON THE ALLOWLIST, and that is
# load-bearing rather than tidy. `$OUT.model` is written by whichever attempt ran
# last, and on project-5 #1624 a grok attempt inherited an Opus model id from the
# claude attempt that had just failed above it. A rule that read the model alone
# would have called that grok review a Claude read. The runner decides WHETHER
# the model is evidence; the model decides WHICH Claude.
#
# ONE WORD FOR THE LEDGER, AND IT IS HONEST. A review served through OpenRouter
# is recorded as `claude-via-openrouter`, never as plain `claude`: the ledger
# keeps saying which lane served it, and any reader anywhere in the fleet that
# still compares against the literal `claude` treats it as non-primary — i.e. it
# HOLDS. Every direction an un-updated reader can be wrong in is the safe one.
#
# Sourced by bin/lib/merge-conductor-lib.sh (which reaches the conductor, the
# sweep, the resolver and bin/review-prs.sh) and directly by bin/run-build.sh,
# which is where the word is written in the first place.

# The word recorded for a Claude model served through the OpenRouter lane.
RP_VIA_OPENROUTER="claude-via-openrouter"

# rp_anthropic_slug <model> -> rc 0 when this model string is one of OpenRouter's
#   Anthropic slugs. Both shapes agent-call.sh can produce are accepted: the
#   plain `anthropic/claude-...` it derives from the stage model, and the
#   `~anthropic/claude-...-latest` variant form it uses for the bare model words.
rp_anthropic_slug() {
  case "${1:-}" in
    anthropic/claude-*|~anthropic/claude-*) return 0 ;;
  esac
  return 1
}

# rp_is_claude <runner> <model> -> rc 0 when a CLAUDE MODEL authored this call.
rp_is_claude() {
  case "${1:-}" in
    claude)     return 0 ;;
    openrouter) rp_anthropic_slug "${2:-}" && return 0 ;;
  esac
  return 1
}

# rp_prov_word <runner> <model> -> the provenance word to RECORD for this call.
#   `-` and empty pass straight through: they mean "nothing was recorded", which
#   is not a claim about any lane and must not become one here.
rp_prov_word() {
  local runner="${1:-}" model="${2:-}"
  case "$runner" in
    ''|-|null) printf '%s' "${runner:--}"; return 0 ;;
    claude)    printf 'claude'; return 0 ;;
  esac
  if [ "$runner" = openrouter ] && rp_anthropic_slug "$model"; then
    printf '%s' "$RP_VIA_OPENROUTER"; return 0
  fi
  printf '%s' "$runner"
}

# rp_prov_is_claude <word> -> rc 0 when a RECORDED provenance word means "a
#   Claude model authored it". The reader half of rp_prov_word, and the only
#   thing a merge gate should ever compare a provenance word against.
#   `-`/empty/null are NOT claude here — absence is the caller's own question
#   (mc_prov_held treats it as "the ledger said nothing", the sweep skips it),
#   and answering it here would flip a silence into a claim.
rp_prov_is_claude() {
  case "${1:-}" in claude|"$RP_VIA_OPENROUTER") return 0 ;; esac
  return 1
}

# rp_out_prov <out-file> -> the provenance word for an agent-call.sh output,
#   read from the markers it writes beside it (`<out>.runner`, `<out>.model`).
#   A MISSING .runner READS AS claude, which is the behaviour every call site
#   had before this lib existed: the marker has shipped since 2026-08-03, and a
#   record old enough to lack it predates the fallback lanes entirely.
rp_out_prov() {
  local out="${1:-}" runner model
  runner=$(head -1 "$out.runner" 2>/dev/null || true); [ -n "$runner" ] || runner=claude
  model=$(head -1 "$out.model" 2>/dev/null || true)
  rp_prov_word "$runner" "$model"
}

# rp_out_is_claude <out-file> -> rc 0 when that call was authored by Claude.
rp_out_is_claude() { rp_prov_is_claude "$(rp_out_prov "$1")"; }

# rp_out_label <out-file> -> "<runner>" or "<runner> (<model>)", for log lines
#   that have to say what actually served a call rather than just that it was
#   not the primary lane.
rp_out_label() {
  local out="${1:-}" runner model
  runner=$(head -1 "$out.runner" 2>/dev/null || true); [ -n "$runner" ] || runner=claude
  model=$(head -1 "$out.model" 2>/dev/null || true)
  case "$runner" in claude) printf '%s' "$runner"; return 0 ;; esac
  [ -n "$model" ] && { printf '%s (%s)' "$runner" "$model"; return 0; }
  printf '%s' "$runner"
}
