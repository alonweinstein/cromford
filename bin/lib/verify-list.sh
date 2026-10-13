#!/bin/bash
# bin/lib/verify-list.sh — the planner's rule for paths a build only RUNS
# (BH-6299). Sourced, never executed.
#
# vl_plan_rule   prints one prompt sentence: list only files the build will
#                MODIFY or CREATE, and put a test or check it only runs under
#                '## Verify (run, not edited)'. bin/planned-files.sh skips that
#                section and every VALIDATE: line, so a run-only path is not
#                claimed and never defers a sibling.
# shellcheck shell=bash

vl_plan_rule() {
  printf '%s ' "FILES TO TOUCH ARE EDITS ONLY: under files to touch, list only files this build will MODIFY or CREATE. A test, check or script the build only RUNS (a repo-wide guard test, a lint, a check script) goes under a separate '## Verify (run, not edited)' heading, never in the files-to-touch list. bin/planned-files.sh skips that section and every VALIDATE: line, so a path named only there is not claimed and never defers a sibling build. If a task does edit such a file, name it in files to touch as well."
}
