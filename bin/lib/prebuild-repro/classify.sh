# bin/lib/prebuild-repro/classify.sh — pr_skip_classify (BH-2040, order 2 of #2004).
# pr_skip_classify <thread-json>: `skip<TAB><marker|cause-proven><TAB><evidence>`
# or `run<TAB><thread-truncated|-><TAB>-`. Pure jq: no network, no files.
# Function-only: run-build.sh sources this file. docs/repro-gate/skip.md.
# shellcheck shell=bash

# Only a principal's words count: the newest principal comment first, then the
# body when its reporter is a principal. In each text the first line that
# STARTS with `[no-repro]` or `[no-repro: <text>]` wins, outside a ``` fence
# and not on a `>` quote line. `no-repro` is the only case-insensitive part.
pr_skip_classify() {
  local out
  # shellcheck disable=SC2016
  out=$(printf '%s' "${1:-}" | jq -r '
    def mk: "^[[:space:]]*\\[[Nn][Oo]-[Rr][Ee][Pp][Rr][Oo]";
    def hit:
      reduce (split("\n")[] | sub("\r$"; "")) as $l ({f: false, h: null};
        if .h != null then .
        elif ($l | test("^[[:space:]]*```")) then .f = (.f | not)
        elif .f or ($l | test("^[[:space:]]*>")) then .
        elif ($l | test(mk + "\\]")) then .h = ""
        elif ($l | test(mk + ":.*\\]")) then .h = ($l | capture(mk + ":[[:space:]]*(?<t>.*)\\]").t)
        else . end) | .h;
    def flat: gsub("[\t\r\n]"; " ");
    if type != "object" then "run\t-\t-" else
      ([ ((.comments // []) | if type == "array" then . else [] end
          | map(select(type == "object" and .principal == true))
          | sort_by([(.createdAt // "" | tostring), (.id // "" | tostring)]) | reverse | .[] | (.body // "" | tostring)),
         (if .body_principal == true then (.body // "" | tostring) else empty end)
       | hit | select(. != null) ] | .[0]) as $h
      | if $h == null then (if .truncated == true then "run\tthread-truncated\t-" else "run\t-\t-" end)
        elif ($h | startswith("cause-proven")) then
          ($h | ltrimstr("cause-proven") | sub("^[[:space:]—–:-]*"; "") | flat | .[0:300]) as $e
          | "skip\tcause-proven\t" + (if $e == "" then "-" else $e end)
        else ($h | flat) as $e | "skip\tmarker\t" + (if $e == "" then "-" else $e end) end
    end' 2>/dev/null | head -1) || out=""
  case "$out" in
    skip$'\t'*|run$'\t'*) printf '%s\n' "$out" ;;
    *) printf 'run\t-\t-\n' ;;
  esac
}
