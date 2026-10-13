#!/bin/bash
# bin/lib/rule-evidence.sh — the evidence record behind every mined rule
# (BH-3692). Sourced, never run. Sourcing sets RE_DIR and RE_LINT_HEAD_RE and
# defines two functions; nothing else runs, nothing touches the network.
#
# One file per rule, committed in the harness repo at $RE_DIR/D<n>.json and
# keyed by the rule's D-number. The rule miner writes it, rule-adopt validates
# it before it lands a rule, rule-recur reads it to measure recurrence.
#
# THE SCHEMA (every key always present):
#   {
#     "rule":      "D45",                 rule id, as in build-discipline.md
#     "class":     "lint-backed",         "lint-backed" | "judgement", nothing else
#     "check":     "tests/foo-test.sh",   the path of the check that enforces a
#                                         lint-backed rule; null when there is none
#     "reason":    "...",                 why the miner put it in that class
#     "mined":     "2026-09-30",          the miner run's date
#     "source":    "findings",            the incident source it was mined from
#     "incidents": ["TK-1", "TK-2"],      incident ids (blank and "-" dropped)
#     "families":  ["aaaaaaaaaaaa"]       findings.log family keys (same)
#   }
#
# RE_LINT_HEAD_RE is the head branch of the lint-backed rules PR,
# rules/mined-<YYYYMMDD>-lint (ERE, for [[ =~ ]] and grep -E). The judgement PR
# rules/mined-<YYYYMMDD> deliberately does not match.

RE_DIR=prompts/rule-evidence
RE_LINT_HEAD_RE='^rules/mined-[0-9]{8}-lint$'

# re_write <out> <rule> <class> <check|-> <reason> <mined> <source> <incidents-file> <families-file>
# The list files hold one id per line. Non-zero, and <out> absent or untouched,
# on a bad class, an unreadable list file or a jq failure: the record is written
# to a tmp file and moved into place only once it is whole.
re_write() {
  local out=$1 rule=$2 class=$3 check=$4 reason=$5 mined=$6 source=$7 inc=$8 fam=$9
  local tmp="$out.tmp.$$" incj famj
  case "$class" in lint-backed|judgement) ;; *) return 2 ;; esac
  [ -r "$inc" ] && [ -r "$fam" ] || return 1
  incj=$(jq -Rn '[inputs | select(test("^\\s*$") | not) | select(. != "-")]' "$inc") || return 1
  famj=$(jq -Rn '[inputs | select(test("^\\s*$") | not) | select(. != "-")]' "$fam") || return 1
  if jq -n --arg rule "$rule" --arg class "$class" --arg check "$check" \
       --arg reason "$reason" --arg mined "$mined" --arg source "$source" \
       --argjson incidents "$incj" --argjson families "$famj" \
       '{rule: $rule, class: $class, check: (if $check == "-" then null else $check end),
         reason: $reason, mined: $mined, source: $source,
         incidents: $incidents, families: $families}' > "$tmp" \
     && mv "$tmp" "$out"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# re_field <file> <jq filter> — the raw value (a null prints "null"); jq's rc,
# so unparseable JSON is non-zero.
re_field() {
  jq -r "$2" "$1"
}
