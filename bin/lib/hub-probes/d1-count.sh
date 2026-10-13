#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/d1-count.sh — BH-3449 (BH-3434.2): a row count from the
# jobs worker's D1 through the contract verb hp_d1_count. Sourced by common.sh's hp_run.
#
# hp_probe_d1_count <table> <template>
#   PASS (rc 0): prints `count=<n>`, HP_HTTP_STATUS=200. Any worker failure
#   (hp_d1_count rc 1, a non-integer answer, no jobs client) →
#   `FAIL worker-unavailable`, HP_HTTP_STATUS=000, rc 1. _jobs_req does not
#   expose the HTTP code, so 200 and 000 are the only two values.
command -v hp_d1_count >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../../jobs-client.sh" >/dev/null 2>&1

hp_probe_d1_count() {
  local n
  if command -v hp_d1_count >/dev/null 2>&1 && n=$(hp_d1_count "$1" "$2") && [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "count=$n"; HP_HTTP_STATUS=200; return 0
  fi
  echo "FAIL worker-unavailable"; HP_HTTP_STATUS=000
  return 1
}
