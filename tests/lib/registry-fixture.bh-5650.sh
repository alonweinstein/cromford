#!/bin/bash
# shellcheck shell=bash
# tests/lib/registry-fixture.bh-5650.sh — BH-5650: a registry API for the
# shell suites. Sourced after tests/lib/scratch.sh (it needs $T and $DIR);
# defines functions, runs nothing.
#
#   rfx_setup      put a `curl` on $T/bin that answers from the REAL
#                  harness-jobs worker over the SQLite file $T/registry.db
#                  (tests/lib/registry-fixture-curl.bh-5650.mjs), and seed it
#                  through POST /api/registry/import with bin/registry-seed.sh
#                  --emit of this tree. rc 3 = no node:sqlite (print SKIP).
#   rfx_db <cmd>   run <cmd> in db mode against the fixture, HARNESS=$RFX_H
#   rfx_q <sql>    the rows of one SELECT as JSON
#   rfx_calls      how many curl calls the fixture has answered
#   rfx_down 0|1   make every call fail as a refused connection, or not
#
# The admin token is the fixture's own (fixture-admin-token); a suite that
# needs a wrong one sets REGISTRY_ADMIN_TOKEN on the command.

RFX_MJS="$DIR/tests/lib/registry-fixture-curl.bh-5650.mjs"
RFX_H="$T/h"

rfx_setup() {
  mkdir -p "$T/bin" "$RFX_H"
  : > "$T/curl.log"
  cat > "$T/bin/curl" <<SH
#!/bin/bash
{ printf "%s " "\$@" | tr "\\n" " "; echo; } >> "$T/curl.log"
[ ! -e "$T/fixture-down" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
REGISTRY_FIXTURE_DB="$T/registry.db" exec node --no-warnings "$RFX_MJS" "\$@"
SH
  chmod +x "$T/bin/curl"
  REGISTRY_FIXTURE_DB="$T/registry.db" node --no-warnings "$RFX_MJS" --query 'SELECT 1 AS one' >/dev/null 2>&1
  [ $? -ne 3 ] || return 3
  "$DIR/bin/registry-seed.sh" --emit --root "$DIR" > "$T/seed.json" || return 1
  local out
  out=$(printf 'authorization: Bearer fixture-secret\nx-registry-admin-token: fixture-admin-token\ncontent-type: application/json\n' > "$T/seed.headers" \
    && "$T/bin/curl" -sS -w $'\n%{http_code}' -X POST -H "@$T/seed.headers" --data-binary "@$T/seed.json" https://jobs.test/api/registry/import)
  [ "${out##*$'\n'}" = 200 ] || { echo "rfx_setup: the seed import answered: $out" >&2; return 1; }
  : > "$T/curl.log"
}

rfx_db() {
  env PATH="$T/bin:$PATH" HARNESS="$RFX_H" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
    REGISTRY_ADMIN_TOKEN="${REGISTRY_ADMIN_TOKEN-fixture-admin-token}" REGISTRY_SOURCE=db "$@"
}

rfx_q() { REGISTRY_FIXTURE_DB="$T/registry.db" node --no-warnings "$RFX_MJS" --query "$1"; }

rfx_calls() { wc -l < "$T/curl.log" | tr -d ' '; }

rfx_down() { if [ "$1" = 1 ]; then : > "$T/fixture-down"; else rm -f "$T/fixture-down"; fi; }
