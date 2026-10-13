#!/bin/bash
# tests/hotfix-merge-requires-proof-test.sh — a `hotfix` PR that ADDS migration
# SQL does not enter the merge queue, and is not merged directly, until the
# hotfix stage has posted an accepted proof for exactly that SQL (BH-370.2).
#
# THE CASE THIS PINS. A migration PR is always tier 2, so bin/run-build.sh never
# merges it itself — the conductor is the merger. Without this gate the
# conductor happily lands a hotfix whose SQL nobody has applied, and the deploy
# that follows runs code against a schema that does not exist. The proof comment
# is the only evidence that somebody applied it (or deliberately deferred it),
# and it is keyed on a FINGERPRINT of the SQL bytes, so a proof for older SQL is
# not a proof for this head.
#
# WHAT IS ASSERTED IS THE REAL TICK: the whole bin/merge-conductor.sh runs
# against a scratch $HARNESS with a stubbed gh, and the assertions are the rows
# in state/merge-conductor/pr-state.tsv, the lines in logs/merge-conductor.log
# and logs/ALERTS.log, and the argv of every gh call. The stub applies the
# PRODUCTION `--jq` expression with real jq to the fixture JSON, so what is
# under test is the expression the lib ships, not a paraphrase of it.
#
# Red-first, both halves:
#   git show main:bin/merge-conductor.sh          > /tmp/mc-main.sh
#   git show main:bin/lib/merge-conductor-lib.sh  > /tmp/mc-lib-main.sh
#   CONDUCTOR=/tmp/mc-main.sh MCLIB=/tmp/mc-lib-main.sh bash tests/hotfix-merge-requires-proof-test.sh
#
# Run from anywhere: tests/hotfix-merge-requires-proof-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh): the proof
# bodies below are the only thing that carries a timestamp, and they all carry
# this one.
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
# gh-rest.sh rides with the conductor lib: since BH-784 every decision read in
# the lib goes through it, and a tree without it keeps the fail-closed shims,
# which answer "unverifiable" to everything — this suite would then be green on
# a conductor that never read a PR. tests/lib/rest-emit.sh is the shared emitter
# for the `gh api -i -X …` arms of the stub below, and it owns the exact REST
# shapes (the contract judges the HTTP STATUS LINE, never gh's exit code).
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "${MCLIB:-$DIR/bin/lib/merge-conductor-lib.sh}" "$T/h/bin/lib/merge-conductor-lib.sh"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "${CONDUCTOR:-$DIR/bin/merge-conductor.sh}" "$T/h/bin/merge-conductor.sh"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/deployreq.txt"\nexit 0\n' "$T" > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"
MSHA=cccccccc3333
head_of() { printf 'aaaaaaaa00%s' "$1"; }

# 41 is the hotfix PR under test, 42 the plain neighbour that must not be
# punished for it. Both APPROVE, bound to their own heads.
for N in 41 42; do
  REC="$T/h/builds/pool-mgfy-MG-$N-2026091700$N"
  mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$N" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  head_of "$N" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: hotfix\n  - name: default\n' | base64 | tr -d '\n')

# --- the SQL fixture and the contract's fingerprint --------------------------
SQL1=scripts/migrations/2026-09-15-x.sql
SQL2=prisma/migrations/manual/2026-09-15-y.sql
WORKFLOW_SQL=db/manual/2026-09-15-z.sql
BLOB1=1111111111111111111111111111111111111111
BLOB2=2222222222222222222222222222222222222222
BLOB3=3333333333333333333333333333333333333333
# FP per the shared contract: sha256 of the SORTED "<path> <blob sha>" lines.
# Computed here the way bin/hotfix-migrate.sh computes it from git hash-object,
# so the lib reading `.sha` off the files API must land on the same string.
fp_of() { printf '%s\n' "$@" | sort | sha256sum | awk '{print $1}'; }
FP_GOOD=$(fp_of "$SQL1 $BLOB1")
FP_BOTH=$(fp_of "$SQL1 $BLOB1" "$SQL2 $BLOB2")
FP_WORKFLOW=$(fp_of "$WORKFLOW_SQL $BLOB3")
FP_WRONG=$(printf 'somebody elses sql\n' | sha256sum | awk '{print $1}')

files_json() { # files_json <pr> <json-array> — the shape of `gh api pulls/N/files`
  printf '%s\n' "$2" > "$T/files-$1.json"
}
# One added migration + one added source file: the source file must not reach
# the fingerprint, or every push to src/ would invalidate an applied proof.
FILES_ONE_SQL="[{\"filename\":\"$SQL1\",\"sha\":\"$BLOB1\",\"status\":\"added\"},{\"filename\":\"src/x.ts\",\"sha\":\"$BLOB2\",\"status\":\"added\"}]"
FILES_TWO_SQL="[{\"filename\":\"$SQL1\",\"sha\":\"$BLOB1\",\"status\":\"added\"},{\"filename\":\"$SQL2\",\"sha\":\"$BLOB2\",\"status\":\"added\"}]"
FILES_MODIFIED="[{\"filename\":\"$SQL1\",\"sha\":\"$BLOB1\",\"status\":\"modified\"},{\"filename\":\"src/x.ts\",\"sha\":\"$BLOB2\",\"status\":\"added\"}]"
FILES_RENAMED="[{\"filename\":\"$SQL1\",\"sha\":\"$BLOB1\",\"status\":\"renamed\"}]"
FILES_NO_SQL="[{\"filename\":\"src/x.ts\",\"sha\":\"$BLOB2\",\"status\":\"added\"}]"
FILES_SEED_SQL="[{\"filename\":\"db/seed.sql\",\"sha\":\"$BLOB1\",\"status\":\"added\"}]"
FILES_WORKFLOW="[{\"filename\":\"$WORKFLOW_SQL\",\"sha\":\"$BLOB3\",\"status\":\"added\"}]"

proof_body() { # proof_body <fp> <decision> — the marker line the stage posts
  printf '<!-- hotfix-migrate-proof fp=%s decision=%s -->\n\nI ran it at %s. One file, %s.\nREVERT: none declared in file - write one before applying by hand.\n' \
    "$1" "$2" "$NOW" "$SQL1"
}
set_comments() { # set_comments <pr> [body ...] — oldest first, as gh lists them
  local n="$1"; shift
  jq -n '{comments: ($ARGS.positional | map({body: .}))}' --args "$@" > "$T/comments-$n.json"
}
set_comments 41
set_comments 42
files_json 41 "$FILES_ONE_SQL"
files_json 42 "$FILES_NO_SQL"

# ---------------------------------------------------------------------------
# The fixture repo: two READY PRs, a queue that answers nothing
# ---------------------------------------------------------------------------
for N in 41 42; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
echo none > "$T/checkmode"

labels_csv() { tr '\n' ',' < "$T/labels-$1" 2>/dev/null | sed 's/,$//'; }
open_list() { # open_list — the open list, minus whatever has merged
  local n out="" lbl csv
  for n in 41 42; do
    [ "$(cat "$T/prstate-$n" 2>/dev/null)" = open ] || continue
    csv=$(labels_csv "$n"); lbl="[]"
    [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/mgfy-os/pull/$n\",\"headRefOid\":\"$(head_of "$n")\",\"headRefName\":\"ticket/mg-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"isInMergeQueue\":false,\"labels\":$lbl},"
  done
  printf '[%s]\n' "${out%,}" > "$T/list.json"
}

# The gh stub. The two reads this ticket adds are answered by applying the
# PRODUCTION --jq expression, with real jq, to the fixture JSON — a stub that
# restated the filter would pass while the shipped expression was wrong.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
JQEXPR=""; WANT=0
for A in "\$@"; do
  [ "\$WANT" = 1 ] && { JQEXPR="\$A"; WANT=0; continue; }
  case "\$A" in --jq|-q) WANT=1 ;; esac
done
case "\$*" in
  # BH-1586: the files read is the paged gh_rest reader (\`api -i -X GET
  # …/pulls/N/files -F per_page=100 -F page=1\`), and the production jq filter
  # runs in the lib over the raw REST array — so this arm serves the array with
  # a status line, and a failure is gh's own non-answer (no status = 75).
  *"/pulls/"*"/files"*)
    PN=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+)/files.*#\1#p')
    [ -e "$T/files-fail" ] && exit 1
    [ -f "$T/files-\$PN.json" ] || exit 1
    case "\$*" in
      *"-i -X GET"*) printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$T/files-\$PN.json"; echo ;;
      *) jq -r "\${JQEXPR:-.}" "$T/files-\$PN.json" ;;
    esac; exit 0 ;;
  # BH-994's pre-merge state guard is the only -q template carrying ascii_upcase,
  # and it wants THREE WORDS, not a PR object. Two words, exactly as the arm in the second case block answers: no third
  # field means the base guard abstains, which is what this suite exercises.
  *"ascii_upcase"*)
    PN=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    case "\$(cat "$T/prstate-\$PN" 2>/dev/null || echo open)" in
      merged) echo "MERGED aaaaaaaa00\$PN" ;;
      closed) echo "CLOSED aaaaaaaa00\$PN" ;;
      *)      echo "OPEN aaaaaaaa00\$PN" ;;
    esac; exit 0 ;;
  # TEST-CHANGE (BH-1585): mc_hotfix_proof reads the proof comment through the
  # paged gh_rest reader, like the files arm above: ONE page of REST comment
  # objects with a status line; the production filter runs in the lib.
  *"api -i -X GET repos/"*"/issues/"[0-9]*"/comments"*)
    PN=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    [ -e "$T/comments-fail" ] && exit 1
    [ -f "$T/comments-\$PN.json" ] || exit 1
    printf 'HTTP/1.1 200 OK\r\n\r\n'; jq -c '.comments | map({body: .body, user: {login: "operator"}})' "$T/comments-\$PN.json"; exit 0 ;;
  *"--json comments"*)
    PN=\$(printf '%s' "\$*" | sed -nE 's#.*pr view ([0-9]+).*#\1#p')
    [ -e "$T/comments-fail" ] && exit 1
    [ -f "$T/comments-\$PN.json" ] || exit 1
    jq -r "\${JQEXPR:-.}" "$T/comments-\$PN.json"; exit 0 ;;
esac
CHECK=\$(cat "$T/checkmode" 2>/dev/null || echo none)
# /pulls/ joins the list because the decision reads are REST paths now (BH-784):
# without it every read of PR 42 would answer with PR 41's row.
N=\$(printf '%s' "\$*" | sed -nE 's#.*(/pull/|/pulls/|/issues/|issue close |issue comment )([0-9]+).*#\2#p' | head -1)
[ -n "\$N" ] || N=41
PRSTATE=\$(cat "$T/prstate-\$N" 2>/dev/null || echo open)
HEAD=aaaaaaaa00\$N
LBL=\$(tr '\n' ',' < "$T/labels-\$N" 2>/dev/null | sed 's/,\$//')
case "\$*" in
  # BH-1586: the provider probes are gh_rest reads in the real REST shapes.
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  # The Mergify check-runs read is a REST decision read on the contract now
  # (BH-784): "no check on this head" is what becomes an ejection, so it has to
  # come back as a real answer with a status line. Same facts as the old arm.
  *"api -i -X GET repos/"*"/check-runs"*)
    case "\$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"
    [ "\$CHECK" = running ] && { printf 'queued\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"; } ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    printf '%s\n' "\$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; echo merged > "$T/prstate-\$N"; exit 0 ;;
  *"issue comment"*|*"issue close"*) printf '%s\n' "\$*" >> "$T/issue-calls.txt" ;;
  # THE DECISION READS ARE REST NOW (BH-784): \`gh api -i -X GET\`, judged on the
  # HTTP status line, so restpr prints a whole response rather than one echoed
  # line. All the \`pr view --json …\` arms below collapse into the single
  # pulls/<n> read — one pull object carries state, head sha, head ref, labels,
  # mergeable, mergeStateStatus, author and the merge sha — so the facts are the
  # same ones, read out of one answer. mc_hotfix_proof's own two reads are NOT
  # here: they are still the old argv and are answered at the top of this stub.
  # The diff shares the pulls path and is told apart by its Accept header, so it
  # is matched first.
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    case "\$PRSTATE" in
      merged) restpr MERGED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator "$MSHA" ;;
      closed) restpr CLOSED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
      *)      restpr OPEN "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
    esac ;;
  # The issue writes the lib does over REST — the comment POST, the close PATCH,
  # and the re-read gh_rest_close does before it reports the close landed. Same
  # ledger as the \`issue comment\`/\`issue close\` arm above, which is what these
  # calls used to be.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *"pr view"*"--json state,headRefOid,labels"*)
    case "\$PRSTATE" in merged) echo "MERGED \$HEAD \$LBL" ;; closed) echo "CLOSED \$HEAD \$LBL" ;; *) echo "OPEN \$HEAD \$LBL" ;; esac ;;
  *"pr view"*"--json state,headRefName"*)
    case "\$PRSTATE" in merged) echo "MERGED ticket/mg-\$N" ;; closed) echo "CLOSED ticket/mg-\$N" ;; *) echo "OPEN ticket/mg-\$N" ;; esac ;;
  # BH-994: the pre-merge state guard reads this over REST now, so the same
  # answer is served to the REST spelling of the call, which is the only one
  # carrying an ascii_upcase in its -q template.
  *"ascii_upcase"*)
    case "\$PRSTATE" in merged) echo "MERGED \$HEAD" ;; closed) echo "CLOSED \$HEAD" ;; *) echo "OPEN \$HEAD" ;; esac ;;
  *"pr view"*"--json state,headRefOid"*)
    case "\$PRSTATE" in merged) echo "MERGED \$HEAD" ;; closed) echo "CLOSED \$HEAD" ;; *) echo "OPEN \$HEAD" ;; esac ;;
  *"pr view"*"--json labels"*) echo "\$LBL" ;;
  *"pr view"*"--json state,mergeStateStatus,author,headRefOid"*) echo "OPEN CLEAN operator \$HEAD" ;;
  *"pr view"*"--json state"*)
    case "\$PRSTATE" in merged) echo MERGED ;; closed) echo CLOSED ;; *) echo OPEN ;; esac ;;
  *"--json mergeCommit"*) [ "\$PRSTATE" = merged ] && echo "$MSHA" || echo "" ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
: > "$T/gh-calls.txt"

# ---------------------------------------------------------------------------
# 0. mc_hotfix_proof on its own: one word per shape of PR
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"
# shellcheck source=/dev/null
. "$T/h/bin/lib/hotfix-lib.sh"
mc_init
proof() { ( PATH="$T/fakebin:$PATH"; mc_hotfix_proof "$@" ); }
pw() { # pw <expected> <desc> <args to mc_hotfix_proof...>
  local exp="$1" desc="$2"; shift 2
  local got; got=$(proof "$@")
  [ "$got" = "$exp" ] && ok || bad "0: $desc — expected '$exp', got '$got'"
}

pw n/a "an unlabelled PR is not this gate's business" example-org/mgfy-os 41 "merge-queue,queued"
pw n/a "a near-miss label is not the hotfix label" example-org/mgfy-os 41 "hotfix-candidate,not-hotfix,hotfixes"
# ... and it costs no API call at all, which is what keeps this free for the
# 99% of PRs that are not hotfixes.
grep -q "pulls/41/files" "$T/gh-calls.txt" && bad "0: an unlabelled PR must cost ZERO gh calls (calls: $(cat "$T/gh-calls.txt"))" || ok

pw missing "a hotfix with added SQL and no proof comment at all" example-org/mgfy-os 41 hotfix
files_json 41 "$FILES_MODIFIED"
pw n/a "a MODIFIED migration file is not an added one" example-org/mgfy-os 41 hotfix
files_json 41 "$FILES_RENAMED"
pw n/a "a RENAMED migration file is not an added one" example-org/mgfy-os 41 hotfix
files_json 41 "$FILES_NO_SQL"
pw n/a "a hotfix that adds no SQL needs no proof" example-org/mgfy-os 41 hotfix
files_json 41 "$FILES_SEED_SQL"
pw n/a "a .sql outside the contract's globs is not a migration" example-org/mgfy-os 41 hotfix
files_json 41 "$FILES_WORKFLOW"
pw n/a "a workflow project's glob is not counted until it is configured" example-org/mgfy-os 41 hotfix
GOT=$( ( PATH="$T/fakebin:$PATH"; HOTFIX_MIGRATE_GLOB="db/manual/*.sql" mc_hotfix_proof example-org/mgfy-os 41 hotfix ) )
[ "$GOT" = missing ] && ok || bad "0: HOTFIX_MIGRATE_GLOB must add a counted path — expected 'missing', got '$GOT'"
set_comments 41 "$(proof_body "$FP_WORKFLOW" applied)"
GOT=$( ( PATH="$T/fakebin:$PATH"; HOTFIX_MIGRATE_GLOB="db/manual/*.sql" mc_hotfix_proof example-org/mgfy-os 41 hotfix ) )
[ "$GOT" = ok ] && ok || bad "0: a proof over the configured glob must be accepted — expected 'ok', got '$GOT'"
# The configured glob is a PATTERN, and stays one even when the working
# directory happens to hold a file matching it. Splitting the variable into
# words also pathname-expands it, so without `set -f` the pattern is replaced by
# whatever is on disk and the gate degrades to matching that one exact path.
mkdir -p "$T/cwd/db/manual"; : > "$T/cwd/db/manual/2026-01-01-unrelated.sql"
GOT=$( ( cd "$T/cwd" && PATH="$T/fakebin:$PATH"; HOTFIX_MIGRATE_GLOB="db/manual/*.sql" mc_hotfix_proof example-org/mgfy-os 41 hotfix ) )
[ "$GOT" = ok ] && ok \
  || bad "0: HOTFIX_MIGRATE_GLOB must not be pathname-expanded by the cwd — expected 'ok', got '$GOT'"

files_json 41 "$FILES_ONE_SQL"
set_comments 41 "$(proof_body "$FP_GOOD" applied)"
pw ok "applied + the FP of this SQL" example-org/mgfy-os 41 hotfix
set_comments 41 "$(proof_body "$FP_GOOD" deferred-to-deploy)"
pw ok "deferred-to-deploy + the FP of this SQL" example-org/mgfy-os 41 hotfix
# GitHub hands comment bodies back with CRLF line endings; the marker is still
# the first line and the words on it are still the words.
set_comments 41 "$(printf '<!-- hotfix-migrate-proof fp=%s decision=applied -->\r\n\r\nI applied it.\r\n' "$FP_GOOD")"
pw ok "a CRLF body is still a proof" example-org/mgfy-os 41 hotfix
for D in hold flagged no-path; do
  set_comments 41 "$(proof_body "$FP_GOOD" "$D")"
  pw hold "decision=$D is a hold, never an approval" example-org/mgfy-os 41 hotfix
done
set_comments 41 "$(proof_body "$FP_WRONG" applied)"
pw stale "applied, but for SQL this PR no longer carries" example-org/mgfy-os 41 hotfix
# FP FIRST, DECISION SECOND: a hold about different SQL says nothing about this
# SQL, and a fresh stage run is the cheaper, reversible answer.
set_comments 41 "$(proof_body "$FP_WRONG" hold)"
pw stale "a hold on a different FP is stale, not a park" example-org/mgfy-os 41 hotfix
set_comments 41 "$(proof_body "$FP_GOOD" maybe)"
pw stale "an unknown decision token is not an accepted one" example-org/mgfy-os 41 hotfix
set_comments 41 "$(printf '<!-- hotfix-migrate-proof fp=%s -->\n\nno decision at all\n' "$FP_GOOD")"
pw stale "a marker with no decision is not an accepted one" example-org/mgfy-os 41 hotfix
# A comment that QUOTES the marker is not a proof: only a body that STARTS with
# it is, which is the shape bin/hotfix-migrate.sh posts.
set_comments 41 "$(printf 'I think we need a <!-- hotfix-migrate-proof fp=%s decision=applied --> here\n' "$FP_GOOD")"
pw missing "a body that merely quotes the marker is not a proof" example-org/mgfy-os 41 hotfix
# Two proofs: the newest one decides, because it is the one that describes what
# the stage last did.
set_comments 41 "$(proof_body "$FP_GOOD" hold)" "$(proof_body "$FP_GOOD" applied)"
pw ok "the NEWEST marker decides (hold then applied)" example-org/mgfy-os 41 hotfix
set_comments 41 "$(proof_body "$FP_GOOD" applied)" "$(proof_body "$FP_GOOD" hold)"
pw hold "the NEWEST marker decides (applied then hold)" example-org/mgfy-os 41 hotfix
# Two migration files: the FP is over BOTH, sorted, so a proof for one of them
# is not a proof for the pair.
files_json 41 "$FILES_TWO_SQL"
set_comments 41 "$(proof_body "$FP_BOTH" applied)"
pw ok "the FP covers every added migration file, sorted" example-org/mgfy-os 41 hotfix
set_comments 41 "$(proof_body "$FP_GOOD" applied)"
pw stale "a proof for one of two migration files is stale" example-org/mgfy-os 41 hotfix

# A path with a space in it is still a path: the blob sha is the LAST field of
# the contract's line, so everything before it is the filename.
files_json 41 "[{\"filename\":\"scripts/migrations/2026-09-15 spaced.sql\",\"sha\":\"$BLOB1\",\"status\":\"added\"}]"
set_comments 41 "$(proof_body "$(fp_of "scripts/migrations/2026-09-15 spaced.sql $BLOB1")" applied)"
pw ok "a migration path containing a space is matched and fingerprinted" example-org/mgfy-os 41 hotfix

# FAIL CLOSED. An API outage must read as "no proof", never as "no migrations".
files_json 41 "$FILES_ONE_SQL"
set_comments 41 "$(proof_body "$FP_GOOD" applied)"
touch "$T/files-fail"
pw missing "a files-API failure is missing, never n/a" example-org/mgfy-os 41 hotfix
rm -f "$T/files-fail"
touch "$T/comments-fail"
pw missing "a comments read failure is missing, never ok" example-org/mgfy-os 41 hotfix
rm -f "$T/comments-fail"
# The lane's own kill switch switches this gate off with it: the PR is then not
# a hotfix for any purpose in this harness.
touch "$T/h/flags/hotfix-lane-off"
pw n/a "flags/hotfix-lane-off takes the gate off with the lane" example-org/mgfy-os 41 hotfix
rm -f "$T/h/flags/hotfix-lane-off"
# The label may also live on the ISSUE the PR was built from.
MREC="$T/h/builds/pool-mgfy-MG-98-202609170098"; mkdir -p "$MREC"
printf '{"labels":[{"name":"hotfix"}]}\n' > "$MREC/ticket-meta.json"
pw ok "the record's ticket-meta.json labels the PR too" example-org/mgfy-os 41 "-" "$MREC"
scratch_rm "$MREC"
# The reason this gate writes is NOT one bin/blocked-resolver.sh owns: a held
# migration needs a person to read the proof, not an agent rebuild.
mc_resolver_owns "hotfix-migration-hold: the stage held (flagged, quiet window, or no apply path); a human reads the proof comment" \
  && bad "0: hotfix-migration-hold must NOT be resolver-owned" || ok
[ "$(mc_state_display BLOCKED_HUMAN "hotfix-migration-hold: the stage held")" = BLOCKED_HUMAN ] && ok \
  || bad "0: a hotfix-migration-hold row displays as BLOCKED_HUMAN, not BLOCKED_AGENT"

# ---------------------------------------------------------------------------
# The driven tick
# ---------------------------------------------------------------------------
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
CLOG="$T/h/logs/merge-conductor.log"
ALERTS="$T/h/logs/ALERTS.log"
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
merged_41() { grep -q -- "/pull/41 " "$T/merge-calls.txt" 2>/dev/null; }
merged_42() { grep -q -- "/pull/42 " "$T/merge-calls.txt" 2>/dev/null; }
# TEST-CHANGE (BH-2199): a silent Mergify queue (checkmode none) no longer
# merges directly, so the positive checks below (1f 2b 2c 4h 5a 6a) cannot use a
# `gh pr merge` call as the witness that the proof gate let the PR through. The
# witness is now "released to its merge path": merged, OR asked of the queue
# (the merge-queue label add), which is the merge path on this queue_rules repo.
# The NEGATIVE checks (1c 1d 3d 4c: never merged / never enqueued) are unchanged.
released_41() { merged_41 || grep -q -- "issues/41/labels" "$T/label-adds.txt" 2>/dev/null; }
released_42() { merged_42 || grep -q -- "issues/42/labels" "$T/label-adds.txt" 2>/dev/null; }
reset_fixture() { # reset_fixture <labels-for-41>
  rm -rf "$T/h/state/merge-conductor" "$T/h/state/hotfix-announced" "$T/h/state/merge-sweep-done.txt"
  rm -f "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe 2>/dev/null
  for N in 41 42; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$T/labels-41"
  for f in gh-calls.txt merge-calls.txt issue-calls.txt deployreq.txt label-adds.txt \
           label-removes.txt queue-cmds.txt beats.txt; do : > "$T/$f"; done
  : > "$ALERTS"; : > "$CLOG"
  echo none > "$T/checkmode"
  files_json 41 "$FILES_ONE_SQL"
  set_comments 41
  open_list
}
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ---------------------------------------------------------------------------
# 1. No proof: the hotfix waits, and nothing is written to GitHub for it
# ---------------------------------------------------------------------------
reset_fixture hotfix
MC_PR_PARALLEL=1 run_tick
[ "$(state_of 'example-org/mgfy-os#41')" = WAIT_CI ] && ok \
  || bad "1a: a hotfix with unproven SQL must sit in WAIT_CI (got '$(state_of 'example-org/mgfy-os#41')')"
grep -q "proof missing" "$CLOG" && ok || bad "1b: the log must say the proof is missing (log: $(grep -i proof "$CLOG"))"
merged_41 && bad "1c: an unproven hotfix must never be merged (merge calls: $(cat "$T/merge-calls.txt"))" || ok
grep -q -- "issues/41/labels" "$T/label-adds.txt" && bad "1d: an unproven hotfix must never be enqueued (label adds: $(cat "$T/label-adds.txt"))" || ok
# This gate READS. A held hotfix gets no write of any kind — and in particular
# the conductor never posts the proof itself, which is the sibling's job.
# BOTH POST SHAPES (BH-784). The queue-command post is still `gh api -X POST`;
# a conductor comment now goes through mc_pr_comment, i.e. `gh api -i -X POST`
# with the body in a file. Matching only the first would let the second through
# on a gate whose whole claim is that NOTHING is written.
grep -qE -- "api (-i )?-X POST repos/example-org/mgfy-os/issues/41/comments" "$T/gh-calls.txt" \
  && bad "1e: nothing may be POSTed to PR 41 while its proof is missing (calls: $(grep 'issues/41' "$T/gh-calls.txt"))" || ok
# And the plain neighbour is not punished for it: 42 lands within two ticks.
open_list; MC_PR_PARALLEL=1 run_tick
released_42 && ok || bad "1f: the plain PR 42 must land within two ticks (merge calls: $(cat "$T/merge-calls.txt"))"
[ "$(state_of 'example-org/mgfy-os#41')" = WAIT_CI ] && ok \
  || bad "1g: the hotfix stays held on the second tick too (got '$(state_of 'example-org/mgfy-os#41')')"

# ---------------------------------------------------------------------------
# 2. An accepted proof: the PR takes its ordinary READY path, both ways out
# ---------------------------------------------------------------------------
# 2a — the queue is answering: the enqueue label is written.
reset_fixture hotfix
set_comments 41 "$(proof_body "$FP_GOOD" applied)"
echo running > "$T/checkmode"
MC_PR_PARALLEL=1 run_tick
grep -q -- "issues/41/labels" "$T/label-adds.txt" && ok \
  || bad "2a: a proven hotfix is enqueued exactly like any other PR (label adds: $(cat "$T/label-adds.txt"))"
[ "$(state_of 'example-org/mgfy-os#41')" = QUEUED ] && ok \
  || bad "2a2: a proven hotfix reaches QUEUED (got '$(state_of 'example-org/mgfy-os#41')')"
# 2b — degraded: the direct merge happens.
reset_fixture hotfix
set_comments 41 "$(proof_body "$FP_GOOD" applied)"
MC_PR_PARALLEL=1 run_tick
released_41 && ok || bad "2b: a proven hotfix is released to its merge path in degraded mode (the queue ask; never a direct merge since BH-2199) (merge calls: $(cat "$T/merge-calls.txt"))"
grep -q "hotfix migration proof on .*: ok" "$CLOG" && ok \
  || bad "2b2: the log must record the accepted proof (log: $(grep -i proof "$CLOG"))"
# 2c — deferred-to-deploy is accepted on the same terms.
reset_fixture hotfix
set_comments 41 "$(proof_body "$FP_GOOD" deferred-to-deploy)"
MC_PR_PARALLEL=1 run_tick
released_41 && ok || bad "2c: deferred-to-deploy is an accepted proof (merge calls: $(cat "$T/merge-calls.txt"))"

# ---------------------------------------------------------------------------
# 3. A proof for OTHER SQL is not a proof for this SQL
# ---------------------------------------------------------------------------
reset_fixture hotfix
set_comments 41 "$(proof_body "$FP_WRONG" applied)"
MC_PR_PARALLEL=1 run_tick
[ "$(state_of 'example-org/mgfy-os#41')" = WAIT_CI ] && ok \
  || bad "3a: a stale proof holds the PR in WAIT_CI (got '$(state_of 'example-org/mgfy-os#41')')"
grep -q "proof stale" "$CLOG" && ok || bad "3b: the log must say stale, not missing (log: $(grep -i proof "$CLOG"))"
grep -q "stale" <<<"$(reason_of 'example-org/mgfy-os#41')" && ok \
  || bad "3c: the row's reason must name the stale proof (got '$(reason_of 'example-org/mgfy-os#41')')"
merged_41 && bad "3d: a stale proof must never merge (merge calls: $(cat "$T/merge-calls.txt"))" || ok

# ---------------------------------------------------------------------------
# 4. A HELD proof parks the PR for a person, and no agent ladder touches it
# ---------------------------------------------------------------------------
for D in hold flagged no-path; do
  reset_fixture hotfix
  set_comments 41 "$(proof_body "$FP_GOOD" "$D")"
  MC_PR_PARALLEL=1 run_tick
  [ "$(state_of 'example-org/mgfy-os#41')" = BLOCKED_HUMAN ] && ok \
    || bad "4a($D): a held proof parks the PR (got '$(state_of 'example-org/mgfy-os#41')')"
  case "$(reason_of 'example-org/mgfy-os#41')" in
    hotfix-migration-hold:*) ok ;;
    *) bad "4b($D): the reason must start with hotfix-migration-hold (got '$(reason_of 'example-org/mgfy-os#41')')" ;;
  esac
  merged_41 && bad "4c($D): a held proof must never merge (merge calls: $(cat "$T/merge-calls.txt"))" || ok
  grep -q -- "issues/41/labels" "$T/label-adds.txt" \
    && bad "4d($D): a held proof must never be enqueued (label adds: $(cat "$T/label-adds.txt"))" || ok
  # It PAGES, in the same tick: BLOCKED_HUMAN's budget is 0 and nothing owns it.
  grep -q "example-org/mgfy-os#41" "$ALERTS" && ok \
    || bad "4e($D): the park must page at once (ALERTS: $(cat "$ALERTS"))"
  mc_resolver_owns "$(reason_of 'example-org/mgfy-os#41')" \
    && bad "4f($D): bin/blocked-resolver.sh must NOT own this park" || ok
  # No close/reopen: the CI kick and the stuck re-kick have no business here.
  grep -qE "pr (close|reopen)" "$T/gh-calls.txt" \
    && bad "4g($D): a held hotfix must not be closed or reopened" || ok
done
# The hold is not sticky: the moment the stage posts an accepted proof, the next
# tick releases the PR to its merge path. Nothing has to be un-parked by hand.
set_comments 41 "$(proof_body "$FP_GOOD" applied)"
: > "$T/label-adds.txt"; : > "$T/merge-calls.txt"   # 4h must be released by THIS tick
open_list; MC_PR_PARALLEL=1 run_tick
released_41 && ok || bad "4h: an accepted proof on a later tick releases the park (merge calls: $(cat "$T/merge-calls.txt"))"

# ---------------------------------------------------------------------------
# 5. A PR without the label costs nothing and is untouched
# ---------------------------------------------------------------------------
reset_fixture ""      # 41 carries the same added SQL, and no hotfix label
MC_PR_PARALLEL=1 run_tick
released_41 && ok || bad "5a: an unlabelled PR with migration SQL merges exactly as it does today (merge calls: $(cat "$T/merge-calls.txt"))"
grep -q "pulls/41/files" "$T/gh-calls.txt" && bad "5b: an unlabelled PR must cost ZERO extra gh calls (calls: $(grep pulls "$T/gh-calls.txt"))" || ok
grep -q "hotfix migration proof" "$CLOG" && bad "5c: an unlabelled PR must log nothing about proofs" || ok

# ---------------------------------------------------------------------------
# 6. A hotfix with no ADDED migration file is unaffected
# ---------------------------------------------------------------------------
reset_fixture hotfix
files_json 41 "$FILES_MODIFIED"
MC_PR_PARALLEL=1 run_tick
released_41 && ok || bad "6a: a hotfix whose .sql is MODIFIED (not added) merges as usual (merge calls: $(cat "$T/merge-calls.txt"))"
grep -q "hotfix migration proof" "$CLOG" && bad "6b: n/a says nothing in the log (log: $(grep -i proof "$CLOG"))" || ok

echo "hotfix-merge-requires-proof-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
