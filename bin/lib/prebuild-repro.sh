# bin/lib/prebuild-repro.sh — the pre-build repro gate's contract (BH-2039,
# order 1 of #2004). Sourced by bin/prebuild-repro.sh and bin/run-build.sh, so
# it defines functions and sources the five stage files, nothing else. A stage
# file that is missing leaves its function undefined; the runner records that
# as cannot-drive stage-missing. Formats: docs/repro-gate.md.
# shellcheck shell=bash

# BH-2133: WHO the harness is (the App allowlist pr_ledger_key and pr_stop read).
# Missing = an empty list = only `harness: true` comments are left out of the key.
# shellcheck source=bin/lib/harness-self.sh
[ -r "$(dirname "${BASH_SOURCE[0]}")/harness-self.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/harness-self.sh"

_pr_source_stages() {
  local d f
  d="$(dirname "${BASH_SOURCE[0]}")/prebuild-repro"
  for f in thread classify drive stop render; do
    # shellcheck disable=SC1090
    . "$d/$f.sh" 2>/dev/null || true
  done
}
_pr_source_stages

# pr_record <build> <project> <key> <gate> <reason> <evidence> — the ONLY
# writer of $build/prebuild-repro.txt. Written tmp+mv, so a crash never leaves
# a half record the resume guard would read as done. One line goes to both
# logs/<project>.log and $build/pipeline.log. An unknown gate writes nothing.
pr_record() {
  local build="${1:-}" project="${2:-}" key="${3:-}" gate="${4:-}" reason="${5:-}" ev="${6:-}" tmp line
  case "$gate" in skip|cannot-drive|reproduced|not-reproduced|already-fixed|stop) ;; *) return 2 ;; esac
  [ -d "$build" ] && [ -n "$project" ] && [ -n "$key" ] || return 2
  reason=$(printf '%s' "$reason" | tr '\n\t\r' '   '); reason="${reason:--}"
  ev=$(printf '%s' "$ev" | tr '\n\t\r' '   '); ev="${ev:0:500}"; ev="${ev:--}"
  tmp=$(mktemp "$build/.prebuild-repro.XXXXXX") || return 1
  if ! printf 'REPRO_GATE: %s\nREPRO_REASON: %s\nREPRO_EVIDENCE: %s\n' "$gate" "$reason" "$ev" > "$tmp" \
     || ! mv -f "$tmp" "$build/prebuild-repro.txt"; then
    rm -f "$tmp"; return 1
  fi
  line="repro=${gate//-/_} reason=$reason key=$key"
  # The project log is under the caller's root; with none it is skipped (BH-2613).
  local r="${HARNESS:-${H:-}}"
  if [ -n "$r" ]; then
    mkdir -p "$r/logs" 2>/dev/null
    printf '%s\n' "$line" >> "$r/logs/$project.log"
  fi
  printf '%s\n' "$line" >> "$build/pipeline.log"
}

# pr_ledger_key <project> <key> <thread-json> — `<project>/<KEY>/<thread_fp>`,
# the repro_gate ledger key. thread_fp is sha256 of the comment count, the
# newest comment's id and createdAt (newest by createdAt then id, never by
# array position; `-` with no comments) and sha256 of the body. Empty or
# unparseable input is rc 1 and prints nothing.
pr_ledger_key() {
  local p="${1:-}" k="${2:-}" j="${3:-}" f bsha fp apps
  [ -n "$p" ] && [ -n "$k" ] && [ -n "$j" ] || return 1
  # BH-2133: the harness's OWN comments never move the key. Otherwise the stop
  # comment is its own re-arm: new key, ledger miss, a second paid drive, a
  # second comment. OURS is a comment the fetcher flags `harness: true`, or one
  # that carries the stop stage's `<!-- harness:repro-stop … -->` marker AND
  # whose `author` is one of the harness Apps (HARNESS_SELF_APPS,
  # bin/lib/harness-self.sh). The marker alone is NOT enough (review of #2208,
  # N2): a client quoting our comment carries it in their own words. A
  # PAT-posted or in-app stop is caught by the fetcher instead: it flags the
  # marker from one of our authors `harness: true` (BH-2040, skip.md).
  apps=$(command -v harness_self_apps_json >/dev/null 2>&1 && harness_self_apps_json); [ -n "$apps" ] || apps='[]'
  f=$(printf '%s' "$j" | jq -r --argjson apps "$apps" "${HARNESS_SELF_JQ_DEF:-def hs_ours(\$a): false;}"'
      if type != "object" then error("not an object") else . end
      | [ (.comments // [])[]
          | select((.harness // false) != true)
          | select((((.body // "") | tostring | contains("<!-- harness:repro-stop")) and hs_ours($apps)) | not) ] as $c
      | ($c | sort_by([(.createdAt // "" | tostring), (.id // "" | tostring)]) | last) as $n
      | ($c | length | tostring), ($n.id // "-" | tostring), ($n.createdAt // "-" | tostring)' 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$f" | wc -l)" = 3 ] || return 1
  bsha=$(printf '%s' "$j" | jq -j '.body // ""' 2>/dev/null | sha256sum | cut -d' ' -f1) || return 1
  fp=$(printf '%s\n%s' "$f" "$bsha" | sha256sum | cut -d' ' -f1)
  printf '%s/%s/%s\n' "$p" "$k" "$fp"
}
