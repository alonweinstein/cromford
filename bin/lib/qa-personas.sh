#!/bin/bash
# bin/lib/qa-personas.sh — the fleet's ONE reader of a repo's qa/personas.json
# and qa/apps.json: schema v1 validation, scoping a persona set to a diff, and
# the two line shapes the QA lanes print. Sourced, never executed: no `set -e`,
# no `exit`, no side effect at source time. bash + jq only, no network, no node.
#
# WHY ONE FILE. Four consumers read these files — the flow engine
# (bin/qa-drive.mjs), the preview lane, the production lane and the persona
# generator — and a second copy of the schema is how a write flow one lane
# refuses becomes a write flow another lane drives against production. The
# written half of the contract is docs/E2E-POLICY.md § Personas; keep the two in
# step. Nothing is wired yet: the callers are the other children of #528.
#
#   qa_personas_validate <personas.json> [apps.json]
#       rc 0 and silent when valid. On the FIRST defect, one line
#       `personas.json: <jq path>: <problem>` on stderr and rc 1. A given
#       apps.json is checked before the persona rules and refused the same
#       way, as one `apps.json: <jq path>: <problem>` line.
#   qa_personas_scope <personas.json> <apps.json|""> <changed-files> <preview|production>
#       the scoped document, or the word NONE, on stdout. A file that does not
#       validate gives the validate line on stderr and rc 1 — never NONE, never
#       a partial document. A bad mode and a missing changed-files file are
#       refused the same way (a missing diff is not an empty diff).
#   qa_personas_pick <personas.json> <apps.json|""> <changed-files> <preview|production> <per-area>
#       qa_personas_scope narrowed to the first <per-area> owners of each
#       changed app area (personas.json order, least privileged first), each
#       picked persona's flows narrowed to its areas, plus a `pick` object
#       (areas, skipped with why, flows_dropped). NONE when no persona owns a
#       changed area. Refusals are qa_personas_scope's; a bad <per-area> is 1.
#   qa_personas_pick_note <picked.json>
#       the one-line `picked area:id …; skipped (…): …` summary of `pick`.
#   qa_personas_per_area
#       the qa.personas_per_area knob: the settings row when the caller has
#       _lg_setting_lookup (lane-gate.sh) loaded, else QA_PERSONAS_PER_AREA,
#       else 1. No network.
#   qa_personas_list <scoped.json>
#       one `<persona-id><TAB><role>` line per persona, in file order.
#   qa_personas_blocked_rows <scoped.json> <persona-id|*> <reason>
#       one `FLOW <persona-id> <flow-id> blocked <reason>` row per flow.
#
# Diagnostics go to stderr; stdout carries only documents, NONE, list lines and
# FLOW rows, so a caller can pipe stdout straight into jq.

_qap_jq() { # every entry point starts here: no jq, no silent pass
  command -v jq >/dev/null 2>&1 && return 0
  printf 'personas.json: jq missing\n' >&2
  return 1
}

# The app map, checked before any persona is read, so a malformed one is an
# `apps.json: <path>: <problem>` line and rc 1 rather than a raw jq error out of
# the glob compiler. Reads document 0, the same one --slurpfile hands the
# programs below.
_QAP_APPS='
$apps[0] as $d
| if ($d.apps|type) != "object" then ".apps: must be an object"
  else first($d.apps | to_entries[]
    | select((.value|type) != "array" or ([.value[]|type != "string"]|index(true)) != null)
    | ".apps[\"\(.key)\"]: must be an array of strings")
  end'

# Walks the document in file order and prints the FIRST defect as
# `<jq path>: <problem>`. $apps is the slurped apps.json (or null).
_QAP_VALIDATE='
($apps | if type == "array" then .[0].apps else null end) as $A
| def stepd($sp): . as $s
  | (if type == "object" then keys else [] end) as $k
  | if ($k|length) != 1 then "\($sp): must have exactly one of goto, click, fill, expect"
    elif (["goto","click","fill","expect"]|index($k[0])) == null then "\($sp): unknown step key \"\($k[0])\""
    elif $k[0] == "goto" and (($s.goto|type) != "string" or ($s.goto|startswith("/")) == false) then "\($sp).goto: must be a string starting with /"
    elif $k[0] == "click" and ($s.click|type) != "string" then "\($sp).click: must be a string"
    elif $k[0] == "fill" and (($s.fill|type) != "object" or ($s.fill.selector|type) != "string" or ($s.fill.value|type) != "string") then "\($sp).fill: must be an object with a string selector and value"
    elif $k[0] == "expect" and (($s.expect|type) != "object" or ($s.expect.selector|type) != "string" or ($s.expect.text != null and ($s.expect.text|type) != "string")) then "\($sp).expect: must be an object with a string selector and an optional string text"
    else empty end;
  def flowd($p; $fp; $j): . as $f
  | if type != "object" then "\($fp): must be an object"
    elif ($f.id|type) != "string" or $f.id == "" then "\($fp).id: must be a non-empty string"
    elif ([$p.flows[0:$j][]|.id?]|index($f.id)) != null then "\($fp).id: duplicate flow id \"\($f.id)\""
    elif ($f.route|type) != "string" or ($f.route|startswith("/")) == false then "\($fp).route: must be a string starting with /"
    elif ($f.observable|type) != "string" or $f.observable == "" then "\($fp).observable: must be a non-empty string"
    elif ($f.production_safe|type) != "boolean" then "\($fp).production_safe: must be a JSON boolean"
    elif ($f.steps|type) != "array" or ($f.steps|length) == 0 then "\($fp).steps: must be a non-empty array"
    else (range(0; $f.steps|length) as $k | $f.steps[$k] | stepd("\($fp).steps[\($k)]")),
         (if $f.production_safe == false and (($f.cleanup|type) != "string" or $f.cleanup == "")
          then "\($fp).cleanup: must be a non-empty string when production_safe is false" else empty end),
         (if $f.apps == null then empty
          elif ($f.apps|type) != "array" or ($f.apps|length) == 0 or ([$f.apps[]|type != "string"]|index(true)) != null
            then "\($fp).apps: must be a non-empty array of strings"
          else first(range(0; $f.apps|length) as $k | $f.apps[$k] as $x
            | if ($p.apps|type) == "array" and ($p.apps|length) > 0 and ($p.apps|index([$x])) == null
                then "\($fp).apps[\($k)]: \"\($x)\" is not one of this persona'"'"'s apps"
              elif $A != null and ($x|in($A)) == false then "\($fp).apps[\($k)]: unknown app \"\($x)\" (not in apps.json)"
              else empty end)
          end)
    end;
  def persd($doc; $i): . as $p | ".personas[\($i)]" as $pp
  | if type != "object" then "\($pp): must be an object"
    elif ($p.id|type) != "string" or ($p.id|test("^[a-z0-9-]+$")) == false then "\($pp).id: must be a string matching ^[a-z0-9-]+$"
    elif ([$doc.personas[0:$i][]|.id?]|index($p.id)) != null then "\($pp).id: duplicate persona id \"\($p.id)\""
    elif ($p.role|type) != "string" or $p.role == "" then "\($pp).role: must be a non-empty string"
    elif $p.sign_in != "clerk-ticket" then "\($pp).sign_in: must be \"clerk-ticket\""
    elif $p.apps != null and (($p.apps|type) != "array" or ([$p.apps[]|type != "string"]|index(true)) != null) then "\($pp).apps: must be an array of strings"
    elif $A != null and $p.apps != null and ([$p.apps[]|in($A)]|index(false)) != null
      then ([$p.apps[]|in($A)]|index(false)) as $k | "\($pp).apps[\($k)]: unknown app \"\($p.apps[$k])\" (not in apps.json)"
    elif ($p.out_of_bounds|type) != "array" then "\($pp).out_of_bounds: must be a non-empty array"
    elif ($p.out_of_bounds|length) == 0 then "\($pp).out_of_bounds: must list at least one route or action (refunds, sends, deletes, ...)"
    elif ([$p.out_of_bounds[]|(type != "string" or . == "")]|index(true)) != null
      then ([$p.out_of_bounds[]|(type != "string" or . == "")]|index(true)) as $k | "\($pp).out_of_bounds[\($k)]: must be a non-empty string"
    elif ($p.flows|type) != "array" or ($p.flows|length) == 0 then "\($pp).flows: must be a non-empty array"
    else range(0; $p.flows|length) as $j | $p.flows[$j] | flowd($p; "\($pp).flows[\($j)]"; $j)
    end;
  def defects: . as $doc
  | if ($doc|type) != "object" then ".: must be a JSON object"
    elif $doc.version != 1 then ".version: must be 1"
    elif ($doc.personas|type) != "array" or ($doc.personas|length) == 0 then ".personas: must be a non-empty array"
    else range(0; $doc.personas|length) as $i | $doc.personas[$i] | persd($doc; $i)
    end;
  first(defects)'

# Globs compile to a root-anchored, segment-aware ERE: specials escaped, then
# ** -> .* and * -> [^/]* (the sentinel keeps the two apart). One prelude for
# the scoper and the picker, so the two can never disagree on what a glob hits.
_QAP_RE='def re: gsub("(?<c>[.+?^$(){}|\\[\\]\\\\])"; "\\\(.c)")
    | gsub("\\*\\*"; "\u0001") | gsub("\\*"; "[^/]*") | gsub("\u0001"; ".*")
    | "^" + . + "$";
'

# Scopes to the diff. In production mode a write flow keeps its metadata,
# loses its steps and gains `skipped`.
_QAP_SCOPE="$_QAP_RE"'
($apps | if type == "array" then .[0].apps else null end) as $A
| ($changed | split("\n") | map(select(length > 0))) as $paths
| def inscope: . as $p | ($p.apps // []) as $n
  | if $A == null or ($n|length) == 0 then true
    else [$n[] as $x | ($A[$x] // [])[] as $g | ($paths[] | select(test($g|re)))] | length > 0
    end;
  { version: 1, mode: $mode,
    personas: [.personas[] | select(inscope)
      | if $mode == "production"
        then .flows |= map(if .production_safe == false then del(.steps) + {skipped: "write flow, production"} else . end)
        else . end] }
| if (.personas|length) == 0 then "NONE" else . end'

# Narrows a scoped document (the input) to the fewest personas that cover the
# diff: the first $n owners of each changed app area, in personas.json order
# (least privileged first, by the skill's convention). $orig is the slurped
# personas.json, for the full id list the skipped list is written from.
_QAP_PICK="$_QAP_RE"'
($apps | if type == "array" then .[0].apps else null end) as $A
| ($changed | split("\n") | map(select(length > 0))) as $paths
| . as $sc
| def hit($p; $gs): any($gs[]; . as $g | $p | test($g|re));
  def noapps: ((.apps // []) | length) == 0;
  def owners($a): [$sc.personas[]
    | select($a == "*" or noapps or ($a != "(unmapped)" and any((.apps // [])[]; . == $a)))
    | .id];
  def keep($as): (has("apps") | not)
    or any($as[]; . == "*" or . == "(unmapped)")
    or any(.apps[]; . as $x | any($as[]; . == $x));
  (if $A == null then ["*"]
   else [$A | keys_unsorted[] as $k | select(any($paths[]; hit(.; $A[$k]))) | $k]
      + (if any($paths[]; . as $p | any($A[]; hit($p; .)) | not) then ["(unmapped)"] else [] end)
   end) as $areas
| [$areas[] as $a | {area: $a, personas: owners($a)[0:$n]}] as $by
| [$orig[0].personas[].id as $id | select(any($by[].personas[]; . == $id)) | $id] as $picked
| if ($picked|length) == 0 then "NONE"
  else
    [$sc.personas[] | .id as $id | select(any($picked[]; . == $id))
     | [$by[] | select(any(.personas[]; . == $id)) | .area] as $as
     | if any(.flows[]; keep($as)) then
         {p: (.flows |= map(select(keep($as)))),
          d: [.flows[] | select(keep($as) | not) | {persona: $id, flow: .id}]}
       else {p: ., d: []} end] as $nar
    | $sc + {personas: [$nar[].p],
             pick: {per_area: $n, areas: $by,
                    skipped: [$orig[0].personas[].id as $id | select(any($picked[]; . == $id) | not)
                      | {id: $id, why: (if any($areas[]; . as $a | owners($a) | any(.[]; . == $id))
                                        then "area already covered" else "not relevant to the diff" end)}],
                    flows_dropped: [$nar[].d[]]}}
  end'

qa_personas_validate() { # qa_personas_validate <personas.json> [apps.json]
  _qap_jq || return 1
  local pf="${1:-}" af="${2:-}" out bad
  jq . "$pf" >/dev/null 2>&1 || { printf 'personas.json: .: not valid JSON\n' >&2; return 1; }
  if [ -n "$af" ]; then
    bad=$(jq -rn --slurpfile apps "$af" "$_QAP_APPS" 2>/dev/null) \
      || bad='.apps: must be an object'   # unreadable or not JSON at all
    [ -z "$bad" ] || { printf 'apps.json: %s\n' "$bad" >&2; return 1; }
    out=$(jq -r --slurpfile apps "$af" "$_QAP_VALIDATE" "$pf") || return 1
  else
    out=$(jq -r --argjson apps null "$_QAP_VALIDATE" "$pf") || return 1
  fi
  [ -n "$out" ] || return 0
  printf 'personas.json: %s\n' "$out" >&2
  return 1
}

qa_personas_scope() { # qa_personas_scope <personas.json> <apps.json|""> <changed-files> <preview|production>
  _qap_jq || return 1
  local pf="${1:-}" af="${2:-}" cf="${3:-}" mode="${4:-}"
  case "$mode" in
    preview|production) ;;
    *) printf 'qa_personas_scope: mode must be preview or production, not "%s"\n' "$mode" >&2; return 1 ;;
  esac
  [ -f "$cf" ] || { printf 'qa_personas_scope: no such changed-files file: %s\n' "$cf" >&2; return 1; }
  qa_personas_validate "$pf" "$af" || return 1
  if [ -n "$af" ]; then
    jq -r --rawfile changed "$cf" --arg mode "$mode" --slurpfile apps "$af" "$_QAP_SCOPE" "$pf"
  else
    jq -r --rawfile changed "$cf" --arg mode "$mode" --argjson apps null "$_QAP_SCOPE" "$pf"
  fi
}

qa_personas_list() { # qa_personas_list <scoped.json>
  _qap_jq || return 1
  jq -r '.personas[] | "\(.id)\t\(.role)"' "${1:-}"
}

qa_personas_blocked_rows() { # qa_personas_blocked_rows <scoped.json> <persona-id|*> <reason>
  _qap_jq || return 1
  jq -r --arg p "${2:-}" --arg r "${3:-}" \
    '.personas[] | select($p == "*" or .id == $p) | .id as $pid | .flows[] | "FLOW \($pid) \(.id) blocked \($r)"' \
    "${1:-}"
}

# A per-area count that is not a whole number >= 1 is 1, said once on stderr
# (the lanes' convention for a knob that is not a number).
_qap_per_area_ok() { # _qap_per_area_ok <who> <value> — prints the count to use
  case "$2" in
    ''|*[!0-9]*) ;;
    *) [ "$((10#$2))" -ge 1 ] && { printf '%s\n' "$((10#$2))"; return 0; } ;;
  esac
  printf '%s: per-area must be a whole number >= 1, not "%s" — using 1\n' "$1" "$2" >&2
  printf '1\n'
}

qa_personas_pick() { # qa_personas_pick <personas.json> <apps.json|""> <changed-files> <preview|production> <per-area>
  _qap_jq || return 1
  local pf="${1:-}" af="${2:-}" cf="${3:-}" mode="${4:-}" n sc
  n=$(_qap_per_area_ok qa_personas_pick "${5:-}")
  sc=$(qa_personas_scope "$pf" "$af" "$cf" "$mode") || return 1
  [ "$sc" = NONE ] && { printf 'NONE\n'; return 0; }
  if [ -n "$af" ]; then
    printf '%s\n' "$sc" | jq -r --rawfile changed "$cf" --argjson n "$n" \
      --slurpfile orig "$pf" --slurpfile apps "$af" "$_QAP_PICK"
  else
    printf '%s\n' "$sc" | jq -r --rawfile changed "$cf" --argjson n "$n" \
      --slurpfile orig "$pf" --argjson apps null "$_QAP_PICK"
  fi
}

qa_personas_pick_note() { # qa_personas_pick_note <picked.json>
  _qap_jq || return 1
  jq -r '.pick as $k
    | def ids($w): [$k.skipped[] | select(.why == $w) | .id] | if length == 0 then "none" else join(" ") end;
    "picked " + ([$k.areas[] | "\(.area):\(if (.personas|length) == 0 then "none" else (.personas|join("+")) end)"] | join(" "))
    + "; skipped (not relevant to the diff): " + ids("not relevant to the diff")
    + "; skipped (area already covered): " + ids("area already covered")
    + (if ($k.flows_dropped|length) > 0
       then "; flows not relevant to the diff: " + ([$k.flows_dropped[] | "\(.persona)/\(.flow)"] | join(" "))
       else "" end)
    | gsub("[\r\n]"; " ")' "${1:-}"
}

qa_personas_per_area() { # qa_personas_per_area — the knob: settings row, env, 1
  local v=""
  if command -v _lg_setting_lookup >/dev/null 2>&1; then
    v=$(_lg_setting_lookup qa.personas_per_area 2>/dev/null) || v=""
  fi
  [ -n "$v" ] || v="${QA_PERSONAS_PER_AREA:-1}"
  _qap_per_area_ok qa_personas_per_area "$v"
}
