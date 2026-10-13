# tests/lib/br-repeat-cuts-fixture.sh — the scratch harness the three BH-5946
# suites drive bin/blocked-resolver.sh in. Sourced, never run. Not a suite:
# tests/*.sh does not glob tests/lib/.
#
# The REAL lane runs over a scratch $HARNESS, with only the optional modules a
# suite names in BRF_MODULES (a space list of bin/lib/br/opt/<name>.sh). Every
# call that leaves the box is recorded:
#   $T/gh.txt      every `gh` argv, one line per call (the REST envelope stub)
#   $T/jobs.txt    every jobs-client call: `_jobs_req <method> <path>` and
#                  `job_ticket_abandoned <p> <key>`
#   $T/agent.txt   every bin/agent-call.sh call (a model call)
# The gh stub answers from $T/f: pr-<n>.json (the REST PR object; absent = 404),
# issue-<n>.json (default: an open issue), comments-<n>.json (default: []),
# status-<n> (an HTTP status every REST read of #<n> answers instead, e.g. 500),
# search-status (the same for every merged-PR search).
#
# Needs $T (tests/lib/scratch.sh), $DIR (the repo) and $NOW (the one clock read).
# shellcheck shell=bash

brf_setup() {
  H="$T/h"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
           "$H/state/merge-conductor" "$T/fakebin" "$T/repos" "$T/f" "$T/tmp" || return 1
  cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
     "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$H/bin/" || return 1
  # shellcheck source=tests/lib/br-modules.sh
  . "$DIR/tests/lib/br-modules.sh" || return 1
  br_modules_install "$DIR" "$H" || return 1
  scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || return 1
  # Only the modules this suite is about: the other optional rungs have their
  # own suites, and a carry or a CI park here would change the rows under test.
  OPTD="$H/bin/lib/br/opt"; mkdir -p "$OPTD"; rm -f "$OPTD"/*.sh
  local m
  for m in ${BRF_MODULES:-}; do
    cp "$DIR/bin/lib/br/opt/$m.sh" "$OPTD/$m.sh" 2>/dev/null || true
  done
  chmod +x "$H/bin/"*.sh
  export HARNESS_OPERATOR_LOGIN=operator
  printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
  export FLEET_CONF="$H/fleet.conf"
  # shellcheck source=tests/lib/model-route-stub.sh
  . "$DIR/tests/lib/model-route-stub.sh" || return 1
  mrs_fixture "$H" tproj
  : > "$H/env/global.env"
  for m in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh beat.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$H/bin/$m"; chmod +x "$H/bin/$m"
  done
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
  chmod +x "$H/bin/lane-alert.sh"
  cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s\n' "\$1" "\$2" >> "$T/agent.txt"
exit 1
EOF
  chmod +x "$H/bin/agent-call.sh"
  export HARNESS_SECRET="fixture-secret-not-real"
  # The jobs client. _jobs_req answers nothing (rc 2) for every path, so every
  # D1 read is "absent", and records the call. job_ticket_abandoned records the
  # call and answers "not abandoned".
  cat > "$H/bin/jobs-client.sh" <<EOF
jobs_configured() { return 0; }
_jobs_log() { :; }
_jobs_req() { printf '_jobs_req %s %s\n' "\$1" "\$2" >> "$T/jobs.txt"; return 2; }
job_ticket_abandoned() { printf 'job_ticket_abandoned %s %s\n' "\$1" "\$2" >> "$T/jobs.txt"; return 1; }
job_artifact_feed() { return 0; }
queue_put() { printf 'queue_put %s\n' "\$*" >> "$T/jobs.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
F="$T/f"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
num_of() { printf '%s' "\$1" | sed -nE 's#^repos/o/tproj/(pulls|issues)/([0-9]+).*#\2#p'; }
case "\$1 \$2" in
  "api rate_limit") cat "\$F/ratelimit.json"; exit 0 ;;
esac
if [ "\$1" = api ] && [ "\$2" = -i ] && [ "\$3" = -X ]; then
  M="\$4"; P="\$5"; N=\$(num_of "\$P")
  if [ -n "\$N" ] && [ -f "\$F/status-\$N" ]; then send "\$(cat "\$F/status-\$N")" '{"message":"fixture error"}'; exit 0; fi
  case "\$M \$P" in
    "GET repos/o/tproj/pulls"|"GET repos/o/tproj/pulls?"*) send 200 "\$(cat "\$F/list.json")" ;;
    "GET repos/o/tproj/pulls/"*/*) send 200 '[]' ;;
    "GET repos/o/tproj/pulls/"*)
      [ -f "\$F/pr-\$N.json" ] || { send 404 '{"message":"Not Found"}'; exit 0; }
      send 200 "\$(cat "\$F/pr-\$N.json")" ;;
    "GET repos/o/tproj/issues/"*/comments*) send 200 "\$(cat "\$F/comments-\$N.json" 2>/dev/null || echo '[]')" ;;
    "GET repos/o/tproj/issues/"*)
      send 200 "\$(cat "\$F/issue-\$N.json" 2>/dev/null || printf '{"number":%s,"state":"open","title":"TK-%s: the work","body":"","labels":[{"name":"ai-build"}],"user":{"login":"operator","type":"User"}}' "\$N" "\$N")" ;;
    "GET search/issues")
      if [ -f "\$F/search-status" ]; then send "\$(cat "\$F/search-status")" '{"message":"fixture error"}'; exit 0; fi
      send 200 '{"total_count":0,"items":[]}' ;;
    GET*) send 200 '[]' ;;
    *) send 200 '{}' ;;
  esac
  exit 0
fi
# The raw reads: br_pr_ref's \`gh api repos/<slug>/pulls/<n> --jq <filter>\`.
if [ "\$1" = api ]; then
  N=\$(num_of "\$2")
  case "\$2" in
    repos/o/tproj/pulls/*)
      if [ -n "\$N" ] && [ -f "\$F/status-\$N" ]; then echo "gh: fixture error (HTTP \$(cat "\$F/status-\$N"))" >&2; exit 1; fi
      [ -f "\$F/pr-\$N.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      if [ "\${3:-}" = --jq ]; then jq -r "\$4" "\$F/pr-\$N.json"; else cat "\$F/pr-\$N.json"; fi
      exit 0 ;;
    repos/o/tproj/issues/*/comments*) cat "\$F/comments-\$N.json" 2>/dev/null || echo '[]'; exit 0 ;;
  esac
fi
echo ""
exit 0
EOF
  chmod +x "$T/fakebin/gh"
  export PATH="$T/fakebin:$PATH"
  export GH_TOKEN=""
  export GH_BUDGET_TTL_S=0
  ROWS="$H/state/merge-conductor/pr-state.tsv"
  ST="$H/state/blocked-resolver"
  BRENV=()
  return 0
}

ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

# brf_reset — a clean board, a clean state tree and empty recorders.
brf_reset() {
  rm -rf "$T/f"/* "$ST" "$H/state/merge-conductor/"* "$H/builds"/* "$T/tmp"/* \
         "$H/logs/blocked-resolver.log" "$H/flags/blocked-resolver-observe" "$H/flags/br-"*-off 2>/dev/null
  mkdir -p "$T/f" "$H/state/merge-conductor"
  echo '[]' > "$T/f/list.json"
  : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$T/agent.txt"; : > "$T/lane-alert.txt"; : > "$T/run.log"
  : > "$ROWS"
  printf '%s\n' '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}' > "$T/f/ratelimit.json"
  BRENV=()
}

# HEAD_OF <n> [salt] — a 40-hex head for #<n>; a salt gives a different one.
HEAD_OF() { printf '%s%s' "$1" "${2:-}" | sha1sum | cut -c1-40; }

# PRADD <n> [branch] [title] [salt] — the REST PR object for #<n>.
PRADD() {
  jq -nc --argjson n "$1" --arg h "$(HEAD_OF "$1" "${4:-}")" --arg b "${2:-ticket/ts-$1}" \
        --arg t "${3:-TK-$1: the work}" --arg u "$(ISO 300)" \
    '{number:$n, html_url:("https://github.com/o/tproj/pull/"+($n|tostring)), state:"open",
      title:$t, body:"body", draft:false, updated_at:$u, created_at:$u, merged_at:null, closed_at:null,
      user:{login:"operator", type:"User"}, head:{sha:$h, ref:$b, repo:{full_name:"o/tproj", fork:false}},
      base:{ref:"main"}, labels:[], mergeable_state:"clean"}' > "$T/f/pr-$1.json"
}

# CROW <n> <raw reason> [head] [reviewed] — one conductor hand-off row for #<n>.
CROW() {
  printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#$1" "$((NOW - 3600))" \
    "${3:-$(HEAD_OF "$1")}" "${4:-$(HEAD_OF "$1")}" "$2" "https://github.com/o/tproj/pull/$1" >> "$ROWS"
}

# HOLDCMT <n> — a HOLD comment from a person on issue #<n>.
HOLDCMT() {
  jq -nc --arg c "$(ISO 3600)" '[{body:"HOLD — the operator: do not rebuild this.",created_at:$c,user:{login:"operator",type:"User"}}]' \
    > "$T/f/comments-$1.json"
}

# SEED <cap-key> <json> — a state record as an earlier tick left it.
SEED() {
  mkdir -p "$ST/tproj"
  printf '%s\n' "$2" | jq -c --arg k "$1" \
    '{project:"tproj",rkey:$k,first_seen:"2026-10-01 00:00:00Z",rebuilds:0,fixrounds:0,mechanicals:0,regens:0,adjudications:0,rereviews:0,outcome:"",attempts:[]} + .' \
    > "$ST/tproj/$1.json"
}

# TICK — one run of the real lane for tproj. The per-run memo and the open-PR
# list live under TMPDIR, so a suite can look at them.
TICK() {
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" TMPDIR="$T/tmp" \
    HUB_BUILD_OK=1 BR_PER_TICK=20 env ${BRENV[*]:+"${BRENV[@]}"} \
    bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>&1 ) || true
}

LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
# NGH <regex> — how many recorded gh calls match <regex> (ERE).
NGH() { grep -cE -- "$1" "$T/gh.txt" 2>/dev/null; }
# PROF — the last `prof:` line, without its stamp. PFIELD <name> — one field.
PROF() { grep ' prof: ' "$H/logs/blocked-resolver.log" 2>/dev/null | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { PROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
# PROWS — the newest per-row profile TSV.
PROWS() { local f; f=$(ls -1t "$ST/profile/"*.tsv 2>/dev/null | head -1); [ -n "$f" ] && cat "$f"; }
