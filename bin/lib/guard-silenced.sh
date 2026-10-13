#!/bin/bash
# bin/lib/guard-silenced.sh — a fix round that makes a guard pass by editing the
# guard is not a fix.
#
# WHY THIS EXISTS (BH-641). A review blocks on a static check. The fix round
# answers it by adding the flagged path to the checker's allow-list, or to its
# ignore file, or by rewriting the fixture the check reads — the guard goes
# quiet, the diff looks green, and the code the guard was pointing at never
# changed. That is the cheapest way to turn a BLOCK into an APPROVE and the
# hardest to see in a diff, so it is counted here before any LLM is asked to
# notice it.
#
# gs_classify reads a changed-file list on stdin and prints exactly one word:
#   EMPTY          no paths at all            rc 0  (the no-commit path owns it)
#   CODE_CHANGED   at least one real file     rc 0
#   GUARD_SILENCED every path is a guard's    rc 1  (the caller blocks)
#                  own rule, list or fixture
#
# THE NEGATIVES ARE THE DESIGN. This gates an irreversible action (a build
# BLOCKed, a push refused), so ONE line of real code anywhere in the diff makes
# it CODE_CHANGED. A `.md` is never a guard — a doc inside checks/ is
# documentation. A test is not a fixture. Manifests, tsconfig and CI workflows
# are deliberately NOT guards: editing those is the scope gate's business, not
# this one, and calling them guard silencing would block honest fix rounds.
#
# GUARD_SILENCED_EXTRA_GLOBS (env, space-separated shell globs) extends the list
# for a target repo without editing this file.
#
# Sourced, never executed. No side effects on source.

# gs_is_guard <path> — rc 0 when this path is a guard's own rule module,
#   allow-list, ignore file, config or fixture.
gs_is_guard() {
  local p="${1:-}" b g
  p="${p#./}"
  [ -n "$p" ] || return 1
  b="${p##*/}"
  # Documentation is never a guard, wherever it lives.
  case "$p" in *.md|*.markdown) return 1 ;; esac
  # The repo's own extension, read first so a target repo can add its rules.
  for g in ${GUARD_SILENCED_EXTRA_GLOBS:-}; do
    # shellcheck disable=SC2254
    case "$p" in $g) return 0 ;; esac
  done
  case "$p" in
    checks/*|*/checks/*)                                  return 0 ;;
    guardrails/*|*/guardrails/*)                          return 0 ;;
    *allowlist*|*allow-list*|*.allow)                     return 0 ;;
    gitleaks.toml|.gitleaks.toml|*/gitleaks.toml|*/.gitleaks.toml) return 0 ;;
    .semgrep/*|*/.semgrep/*|.semgrep.yml|.semgrep.yaml)   return 0 ;;
    semgrep*.yml|semgrep*.yaml|*/semgrep*.yml|*/semgrep*.yaml) return 0 ;;
    .eslintrc*|*/.eslintrc*|eslint.config.*|*/eslint.config.*)  return 0 ;;
    biome.json*|*/biome.json*)                            return 0 ;;
    .stylelintrc*|*/.stylelintrc*)                        return 0 ;;
    knip.json*|*/knip.json*)                              return 0 ;;
    config/generated-paths.conf)                          return 0 ;;
    config/regenerated-paths.conf)                        return 0 ;;
    fixtures/*|*/fixtures/*)                              return 0 ;;
    __snapshots__/*|*/__snapshots__/*|*.snap)             return 0 ;;
    testdata/*|*/testdata/*)                              return 0 ;;
  esac
  # .eslintignore, .gitleaksignore, .semgrepignore, .prettierignore and kin.
  case "$b" in *ignore) return 0 ;; esac
  return 1
}

# gs_classify — the changed-file list on stdin, one path a line.
gs_classify() {
  local p n=0 guards=0
  while IFS= read -r p; do
    p="${p#./}"
    [ -n "$p" ] || continue
    n=$((n + 1))
    gs_is_guard "$p" && guards=$((guards + 1))
  done
  if [ "$n" = 0 ]; then printf 'EMPTY\n'; return 0; fi
  if [ "$guards" = "$n" ]; then printf 'GUARD_SILENCED\n'; return 1; fi
  printf 'CODE_CHANGED\n'
  return 0
}
