#!/bin/bash
# bin/lib/cli-version.sh — the ONE place a CLI version string is parsed or
# compared. Sourced by bin/cli-update.sh (every box, daily) and
# bin/cli-version-check.sh (hub, daily). Pure bash: no sort -V, no python, so it
# runs identically on a box mid-bootstrap and inside a test with a stubbed PATH.
#
#   cli_version_parse <text>          -> "2.1.261" from "2.1.261 (Claude Code)" /
#                                        "codex-cli 0.153.4" / "v22.23.2"; empty
#                                        when no dotted number is present
#   cli_version_ge <have> <need>      -> rc 0 when have >= need (dotted numeric;
#                                        missing fields are 0, so 2.1 == 2.1.0)
#   cli_version_gt <a> <b>            -> rc 0 when a > b
#   cli_version_of <binary>           -> prints the parsed `<binary> --version`,
#                                        "missing" when it cannot run. Bounded
#                                        (10s) — a wedged binary must not hang
#                                        the daily tick.
#   cli_min_for_model <catalog> <model> -> "<cli> <min>" from
#                                        catalog/cli-min-versions.json, nothing
#                                        when the model has no entry (= no floor)

cli_version_parse() {
  printf '%s' "${1:-}" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1
}

# Field-by-field numeric compare. Returns 0 (ge), 1 (lt). Two unparseable
# inputs compare as 0 == 0; one unparseable input is "unknown" and compares as
# older than anything, so a missing binary never reads as "up to date".
cli_version_ge() {
  local a b i x y
  a=$(cli_version_parse "${1:-}"); b=$(cli_version_parse "${2:-}")
  [ -n "$b" ] || return 0
  [ -n "$a" ] || return 1
  local -a A B
  IFS=. read -r -a A <<<"$a"; IFS=. read -r -a B <<<"$b"
  for ((i = 0; i < ${#A[@]} || i < ${#B[@]}; i++)); do
    x=${A[i]:-0}; y=${B[i]:-0}
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}

cli_version_gt() {
  cli_version_ge "${1:-}" "${2:-}" && ! cli_version_ge "${2:-}" "${1:-}"
}

cli_version_of() {
  local bin="${1:-}" out v
  [ -n "$bin" ] || { echo missing; return 1; }
  out=$(timeout 10 "$bin" --version 2>/dev/null | head -1) || out=""
  v=$(cli_version_parse "$out")
  [ -n "$v" ] || { echo missing; return 1; }
  echo "$v"
}

cli_min_for_model() { # cli_min_for_model <catalog.json> <model>
  local cat="${1:-}" model="${2:-}"
  [ -s "$cat" ] && [ -n "$model" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r --arg m "$model" '.models[$m] | select(. != null) | "\(.cli) \(.min)"' "$cat" 2>/dev/null | grep .
}

# cli_patch_drift <have> <need> -> the number of PATCH versions <need> is ahead
# of <have>, on stdout, always an integer (BH-1517, bin/fly-image-refresh.sh's
# floor check: a Fly builder image whose baked CLI is behind the hub's by more
# than N patch versions).
#   - <need> unparseable (no hub version known yet) -> 0: nothing to compare
#     against, so nothing is reported as drifted.
#   - <have> unparseable (missing/never baked) or major.minor differ from
#     <need> -> 999999: a mismatch this big is never mistaken for "under the
#     floor", it always trips it, however small the caller's N is.
#   - same major.minor -> need's patch minus have's patch (negative when have
#     is AHEAD, which is never a drift).
cli_patch_drift() {
  local have need ah an ap bh bn bp
  have=$(cli_version_parse "${1:-}"); need=$(cli_version_parse "${2:-}")
  [ -n "$need" ] || { echo 0; return 0; }
  [ -n "$have" ] || { echo 999999; return 0; }
  IFS=. read -r ah an ap <<<"$have"
  IFS=. read -r bh bn bp <<<"$need"
  ah=${ah:-0}; an=${an:-0}; ap=${ap:-0}
  bh=${bh:-0}; bn=${bn:-0}; bp=${bp:-0}
  if [ "$ah" != "$bh" ] || [ "$an" != "$bn" ]; then echo 999999; return 0; fi
  echo $((bp - ap))
}
