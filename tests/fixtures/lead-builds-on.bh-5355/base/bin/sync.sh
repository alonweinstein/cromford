#!/bin/bash
# bin/sync.sh <run-id> — copy the vendor's items into the local store.
set -uo pipefail
run="${1:?run id}"
API="${SYNC_API_URL:?SYNC_API_URL unset}"

mark_done() { printf '%s done\n' "$1" >> state/sync-runs.log; }
mark_failed() { printf '%s failed %s\n' "$1" "$2" >> state/sync-runs.log; }

resp=$(curl -fsS "$API/items") || { mark_failed "$run" "read failed"; exit 1; }
printf '%s\n' "$resp" > "state/items.$run.json"
mark_done "$run"
