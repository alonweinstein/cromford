#!/bin/bash
# bin/lib/rule-class.sh — the mechanical classifier behind the weekly rule
# miner's two PRs (BH-3714, slice 2 of BH-3692). Sourced, never run. Pure: no
# network, no writes outside stdout/stderr, no harness root of its own.
#
# THE GRAMMAR the drafting session writes, one bullet per rule:
#   - **D<n> <title>.** <rule text, naming the check's path when there is one>
#     CLASS: lint <repo-relative path of the check>   |   CLASS: judgement
#     EVIDENCE: <incident id>[, <incident id>…]
#
# A rule is lint-backed ONLY when every condition below holds; the first one
# that fails is the judgement reason rc_class prints:
#   no CLASS line | more than one CLASS line | tagged judgement |
#   lint with no path | malformed CLASS line | path has glob or odd characters |
#   absolute path | path escapes the repo | outside check prefixes |
#   check not tracked on main | check not named in rule text
# The check prefixes are an ALGORITHM CONSTANT (what "a check" is), not a knob:
# bin/ tests/ guardrails/ checks/ .github/workflows/. v1 accepts only a check
# already tracked in the clone (main): one exact file, never a directory.
if [ -n "${RULE_CLASS_LIB:-}" ]; then return 0 2>/dev/null; fi
RULE_CLASS_LIB=1
RC_CHECK_PREFIXES='bin/ tests/ guardrails/ checks/ .github/workflows/'

# rc_class <bullet-file> <clone-dir> -> "lint-backed\t<path>" | "judgement\t<reason>", rc 0
rc_class() {
  local f=$1 wt=$2 n line w1 path rest p ok=
  _rc_j() { printf 'judgement\t%s\n' "$1"; }
  [ -r "$f" ] && [ -d "$wt" ] || { _rc_j "unreadable input"; return 0; }
  n=$(tr -d '\r' < "$f" | grep -cE '^[[:space:]]*CLASS:')
  [ "$n" -eq 0 ] && { _rc_j "no CLASS line"; return 0; }
  [ "$n" -gt 1 ] && { _rc_j "more than one CLASS line"; return 0; }
  line=$(tr -d '\r' < "$f" | grep -E '^[[:space:]]*CLASS:' | sed 's/^[[:space:]]*CLASS://')
  read -r w1 path rest <<< "$line"
  case "$w1" in
    judgement) _rc_j "tagged judgement"; return 0 ;;
    lint) ;;
    *) _rc_j "malformed CLASS line"; return 0 ;;
  esac
  [ -n "$path" ] || { _rc_j "lint with no path"; return 0; }
  [ -z "$rest" ] || { _rc_j "malformed CLASS line"; return 0; }
  [[ $path =~ ^[A-Za-z0-9._/-]+$ ]] || { _rc_j "path has glob or odd characters"; return 0; }
  case "$path" in /*) _rc_j "absolute path"; return 0 ;; esac
  [[ $path =~ (^|/)\.\.(/|$) ]] && { _rc_j "path escapes the repo"; return 0; }
  for p in $RC_CHECK_PREFIXES; do case "$path" in "$p"?*) ok=1 ;; esac; done
  [ -n "$ok" ] || { _rc_j "outside check prefixes"; return 0; }
  [ "$(git -C "$wt" ls-files -- ":(literal)$path" 2>/dev/null)" = "$path" ] \
    || { _rc_j "check not tracked on main"; return 0; }
  # The literal path, bounded by a non-path character (a sentence's closing
  # period counts as a boundary), somewhere in the text minus the tag lines.
  tr -d '\r' < "$f" | grep -vE '^[[:space:]]*(CLASS|EVIDENCE):' | awk -v p="$path" '
    function pc(c) { return c ~ /[A-Za-z0-9._\/-]/ }
    { s = $0; off = 0
      while ((i = index(s, p)) > 0) {
        b = substr(s, i - 1, 1); a = substr(s, i + length(p), 1); a2 = substr(s, i + length(p) + 1, 1)
        if ((i == 1 || !pc(b)) && (a == "" || !pc(a) || (a == "." && (a2 == "" || !pc(a2))))) { found = 1; exit }
        s = substr(s, i + 1)
      } }
    END { exit !found }' || { _rc_j "check not named in rule text"; return 0; }
  printf 'lint-backed\t%s\n' "$path"
}

# rc_evidence <bullet-file> <inventory.tsv> — the EVIDENCE ids that are real
# inventory ids (column 2), first-seen order, deduped; the rest are counted on
# stderr, never kept (D26). rc 1 only on an unreadable inventory.
rc_evidence() {
  local f=$1 inv=$2
  [ -r "$inv" ] || return 1
  [ -r "$f" ] || return 0
  tr -d '\r' < "$f" | grep -E '^[[:space:]]*EVIDENCE:' | sed 's/^[[:space:]]*EVIDENCE://' \
    | tr ', \t' '\n\n\n' | grep -v '^$' | awk -v inv="$inv" '
      BEGIN { while ((getline l < inv) > 0) { split(l, a, "\t"); ok[a[2]] = 1 } }
      seen[$0]++ { next }
      ($0 in ok) { print; next }
      { k++; bad = bad (bad == "" ? "" : " ") $0 }
      END { if (k) printf "rc_evidence: dropped %d id(s) not in this week%cs inventory: %s\n", k, 39, bad > "/dev/stderr" }'
  return 0
}

# rc_families <ids-file> <findings.log> — findings.log family keys behind the
# ids: findings:<FAM> is FAM; block:<build>:<file> and refuted:<build> are every
# family= on rows whose ticket= is that build's KEY (the right-split of
# bin/rule-miner.sh's harvester). Sorted, deduped, never "" or "-".
rc_families() {
  local ids=$1 log=$2 id b base key keys=
  [ -r "$ids" ] || return 0
  {
    while IFS= read -r id; do
      case "$id" in
        findings:*) printf '%s\n' "${id#findings:}"; continue ;;
        block:*:*) b=${id#block:}; b=${b%:*} ;;
        refuted:*) b=${id#refuted:} ;;
        *) continue ;;
      esac
      [[ $b =~ -[0-9]{12}$ ]] || continue
      base=${b%-*}
      key=$(printf '%s' "$base" | awk -F- 'NF>2 {print $(NF-1)"-"$NF}')
      [ -n "$key" ] && keys="$keys $key"
    done < "$ids"
    [ -n "$keys" ] && [ -r "$log" ] && awk -v keys="$keys" '
      BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want["ticket=" k[i]] = 1 }
      { t = 0; delete fam; m = 0
        for (i = 1; i <= NF; i++) {
          if ($i == "::") break
          if ($i in want) t = 1
          else if (substr($i, 1, 7) == "family=") fam[++m] = substr($i, 8)
        }
        if (t) for (i = 1; i <= m; i++) print fam[i] }' "$log"
  } | grep -vxE -- '-?' | sort -u
  return 0
}

# rc_next <clone-dir> — 1 + the highest **D<n> in prompts/build-discipline.md
# on the clone's checkout and on every refs/remotes/origin/rules/mined-* ref
# (pure local git: the caller fetches). No D anywhere prints 1.
rc_next() {
  local wt=$1 ref max
  max=$( {
    cat "$wt/prompts/build-discipline.md" 2>/dev/null
    for ref in $(git -C "$wt" for-each-ref --format='%(refname)' 'refs/remotes/origin/rules/mined-*' 2>/dev/null); do
      git -C "$wt" show "$ref:prompts/build-discipline.md" 2>/dev/null
    done
  } | grep -oE '\*\*D[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
  echo $(( ${max:-0} + 1 ))
}
