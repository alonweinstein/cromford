#!/bin/bash
# tests/ready-queue-scope.bh-4120-test.sh — BH-4120: the ready set is scoped to
# the project that asks for it.
#
# THE INCIDENT. box-small hosts cromford, harness-console and
# project-8, and its logs/READY-QUEUE.log held ~50 TK-* OWED-STALE
# lines that are project-8's. rq_lines/rq_any scoped only the ROW half
# by project, so `rq_any /root/harness harness-console` answered "there is work",
# bin/triage-gate.sh took the queue branch for a board with 0 open issues, and
# every churn of the shared file bought harness-console a paid session until the
# call-guard refused it (rc 74, shown as FAILED — that half is
# tests/run-triage-callguard-skip.bh-4120-test.sh).
#
# THE RULES (bin/lib/ready-queue.sh, "SCOPED TO THE PROJECT"):
#   a `project=` token wins; otherwise a GitHub-Issues project owns its own key
#   prefix (read from its rendered prompt, like preplan_key_prefix); an in-app
#   project owns untagged lines whose prefix is no GitHub-Issues project's.
#   Anything that cannot be decided fails OPEN to the whole file, which is
#   exactly what every caller saw before.
#
# Driven, not grepped: §L/§F source the real lib in a scratch root, §G runs the
# REAL bin/triage-gate.sh with a gh stub, §W evaluates the REAL `LINES=` jq
# expression extracted from bin/stale-owed-tickets.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ready-queue-scope.bh-4120-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date +%s)

# ── the lib fixture ─────────────────────────────────────────────────────────
# No bin/jobs-client.sh in the scratch root, so the ROW half is off and only
# the file half — the half this ticket scopes — is measured (§L8 stubs rows).
R="$T/r"
mkdir -p "$R/bin/lib" "$R/logs" "$R/prompts"
cp "$DIR/bin/fleet-conf.sh" "$R/bin/"
# scratch-closure-allow: unit-tests bin/lib/ready-queue.sh directly (its scoped file half), not a lane that sources it
cp "$DIR/bin/lib/ready-queue.sh" "$DIR/bin/lib/preplan-lib.sh" "$R/bin/lib/"
export FLEET_CONF="$R/fleet.conf"
cat > "$FLEET_CONF" <<'EOF'
# a comment row
cromford o/bh - - 3 small 1.1.1.1
harness-console o/hc - - 5 small 1.1.1.1
project-8 o/ia https://ia /api/board 1 small 1.1.1.1
EOF
echo 'setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > x' > "$R/prompts/cromford.md"
echo 'setsid /root/harness/bin/run-build.sh harness-console <issue-number> HC-<issue-number> > x' > "$R/prompts/harness-console.md"
Q="$R/logs/READY-QUEUE.log"
MIXED='TK-12 OWED-STALE 30h [todo/team] Widget
TK-13 OWED-STALE 31h [todo/team] harness-console widget
BH-9 9 — waiting on PR #7
TK-14 OWED-STALE 2h [todo/team] x project=cromford
[HOTFIX] BH-1 1 — hot
# comment

HC-3 3 — ready project=harness-console'
printf '%s\n' "$MIXED" > "$Q"

# lib <snippet> — the real lib, sourced from the scratch root, in a clean shell.
lib() { HARNESS="$R" bash -c '. "$HARNESS/bin/lib/ready-queue.sh"; '"$1"; }
lines() { lib "rq_lines \"\$HARNESS\" '$1'"; }

# L1 (test a) — harness-console sees only its own line.
OUT=$(lines harness-console)
[ "$OUT" = 'HC-3 3 — ready project=harness-console' ] && ok \
  || bad "L1: rq_lines harness-console must be exactly the HC-3 line, got: $OUT"

# L2 (test a) — cromford: its own prefix, plus a PB line tagged to it.
OUT=$(lines cromford)
[ "$OUT" = "BH-9 9 — waiting on PR #7
TK-14 OWED-STALE 2h [todo/team] x project=cromford" ] && ok \
  || bad "L2: rq_lines cromford must be exactly BH-9 and TK-14 (token beats prefix), got: $OUT"

# L3 (test c) — project-8 (in-app) still sees its untagged PB lines.
OUT=$(lines project-8)
[ "$OUT" = 'TK-12 OWED-STALE 30h [todo/team] Widget
TK-13 OWED-STALE 31h [todo/team] harness-console widget' ] && ok \
  || bad "L3: rq_lines project-8 must be exactly TK-12 and TK-13, got: $OUT"

# L4 (test b, lib level) — with the HC line gone, harness-console has no work.
grep -v '^HC-3' "$Q" > "$Q.n" && mv "$Q.n" "$Q"
lib 'rq_any "$HARNESS" harness-console'; RC=$?
[ "$RC" = 1 ] && ok || bad "L4: rq_any harness-console on a TK-only queue must be rc 1, got $RC"
lib 'rq_any "$HARNESS" project-8'; RC=$?
[ "$RC" = 0 ] && ok || bad "L4: rq_any project-8 must still be rc 0, got $RC"
printf '%s\n' "$MIXED" > "$Q"

# L5 (adversarial negatives).
for P in cromford harness-console project-8; do
  OUT=$(lines "$P")
  grep -qE '^\[HOTFIX\]|^#|^$' <<<"$OUT" && bad "L5: $P's set carries a non-key line: $OUT" || ok
done
grep -q '^TK-13' <<<"$(lines harness-console)" \
  && bad "L5: a PB line whose TITLE names harness-console was handed to harness-console" || ok
grep -q '^HC-3' <<<"$(lines project-8)" \
  && bad "L5: an HC line (a GitHub-Issues prefix) leaked into the in-app project" || ok
printf 'TK-60 OWED-STALE 1h [todo/team] y project=cromford\n' > "$Q"
OUT=$(lines harness-console)
[ -z "$OUT" ] && ok || bad "L5: project=cromford must not match harness-console (exact token), got: $OUT"
printf 'HC-61 61 — x project=harness-console-two\n' > "$Q"
OUT=$(lines harness-console)
[ -z "$OUT" ] && ok || bad "L5: project=harness-console-two must not match harness-console, got: $OUT"
printf '%s\n' "$MIXED" > "$Q"

# L6 (fail-open) — every undecidable case is the whole file, as before.
WHOLE=$(grep -E '^[A-Z]+-[0-9]' "$Q")
[ "$(lines '')" = "$WHOLE" ] && ok || bad "L6: an empty project must give the whole file"
[ "$(lines not-registered)" = "$WHOLE" ] && ok || bad "L6: a project not in fleet.conf must give the whole file"
echo 'project-6 o/mk - - 3 small 1.1.1.1' >> "$FLEET_CONF"
[ "$(lines project-6)" = "$WHOLE" ] && ok \
  || bad "L6: a GitHub-Issues project with no launch line in its prompt must give the whole file, got: $(lines project-6)"
mv "$R/bin/fleet-conf.sh" "$R/bin/fleet-conf.sh.off"
for P in cromford harness-console project-8; do
  [ "$(lines "$P")" = "$WHOLE" ] && ok || bad "L6: with no bin/fleet-conf.sh, $P must give the whole file"
done
mv "$R/bin/fleet-conf.sh.off" "$R/bin/fleet-conf.sh"

# L7 (parity) — the lib's prefix reader answers what preplan_key_prefix does.
for P in cromford harness-console project-6; do
  A=$(lib "_rq_key_prefix \"\$HARNESS\" '$P'"); B=$(HARNESS="$R" bash -c '. "$HARNESS/bin/lib/preplan-lib.sh" >/dev/null 2>&1; preplan_key_prefix "$HARNESS" '"'$P'")
  [ "$A" = "$B" ] && ok || bad "L7: _rq_key_prefix $P='$A' but preplan_key_prefix='$B'"
done
[ "$(lib '_rq_key_prefix "$HARNESS" harness-console')" = HC ] && ok || bad "L7: harness-console's prefix must be HC"

# L8 (row dedupe follows scope) — the row half on, through stubbed client calls
# that return queue_ready_list's TSV (project, key, ticket-id, line).
rows() { # rows <tsv> <snippet>
  ROWS_TSV="$1" HARNESS="$R" bash -c '
    ready_queue_rows_on() { return 0; }
    queue_ready_list() { printf "%s\n" "$ROWS_TSV" | awk -F"\t" -v p="$1" "p==\"\" || \$1==p"; }
    . "$HARNESS/bin/lib/ready-queue.sh"; '"$2"
}
TAB=$'\t'
OUT=$(rows "harness-console${TAB}HC-3${TAB}3${TAB}-" 'rq_lines "$HARNESS" harness-console')
[ "$(grep -c '^HC-3' <<<"$OUT")" = 1 ] && ok || bad "L8: a row and a file line for HC-3 must come out once, got: $OUT"
printf '%s\nBH-50 50 — x project=harness-console\n' "$MIXED" > "$Q"
OUT=$(rows "cromford${TAB}BH-50${TAB}50${TAB}-" 'rq_lines "$HARNESS" cromford')
grep -q '^BH-50 50 — ready row project=cromford$' <<<"$OUT" && ok \
  || bad "L8: cromford's BH-50 row must come out even though the file's BH-50 line is harness-console's, got: $OUT"
printf '%s\n' "$MIXED" > "$Q"

# ── §F: the fingerprint's file half ─────────────────────────────────────────
fp() { lib "rq_fp_file \"\$HARNESS\" '$1'"; }
# F1 — nothing foreign: byte-identical to the file, comment line included.
printf '# a comment\nBH-9 9 — waiting on PR #7\nPB-14 2h x project=cromford\n' > "$Q"
[ "$(fp cromford | sha256sum)" = "$(sha256sum < "$Q")" ] && ok \
  || bad "F1: with nothing foreign, rq_fp_file must be the file byte for byte, got: $(fp cromford)"
# F2 — foreign churn is invisible, our own churn is not.
printf '%s\n' "$MIXED" > "$Q"
A=$(fp cromford)
printf 'TK-99 OWED-STALE 1h [todo/team] z\n' >> "$Q"
B=$(fp cromford)
[ "$A" = "$B" ] && ok || bad "F2: a new foreign PB line must not change cromford's fingerprint"
printf 'BH-77 77 — new\n' >> "$Q"
C=$(fp cromford)
[ "$B" != "$C" ] && ok || bad "F2: a new BH line must change cromford's fingerprint"
# F3 — no project: the whole file.
[ "$(fp '' | sha256sum)" = "$(sha256sum < "$Q")" ] && ok || bad "F3: rq_fp_file with no project must be the whole file"
printf '%s\n' "$MIXED" > "$Q"

# ── §G: the REAL triage gate ────────────────────────────────────────────────
G="$T/g"
mkdir -p "$G/bin/lib" "$G/logs" "$G/state" "$G/plans" "$G/flags" "$G/env" \
         "$G/builds" "$G/locks" "$G/prompts" "$T/fakebin" "$T/ctl"
for f in triage-gate.sh fleet-conf.sh project-of.sh; do cp "$DIR/bin/$f" "$G/bin/"; done
for f in gh-rest.sh gh-rest-var.sh gh-pr-list.sh preplan-lib.sh dep-verify-lib.sh \
         hotfix-lib.sh scheduler-conf.sh test-home-lib.sh ready-queue.sh; do
  cp "$DIR/bin/lib/$f" "$G/bin/lib/"
done
cp "$R/prompts/"*.md "$G/prompts/"
export GH_CTL="$T/ctl"
# gh stub: `gh api -i <route>` replays status + blank + body; everything else fails.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift; inc=0; path=""
while [ $# -gt 0 ]; do
  case "$1" in -i) inc=1; shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) path="$1"; break ;; esac
done
key=other
case "$path" in repos/*/pulls*) key=pulls ;; repos/*/issues*) key=issues ;; esac
body=""; [ -f "$GH_CTL/$key.body" ] && body=$(cat "$GH_CTL/$key.body")
[ "$inc" = 1 ] && printf 'HTTP/2.0 200\r\ncontent-type: application/json\r\n\r\n'
[ -n "$body" ] && printf '%s\n' "$body"
exit 0
GH
chmod +x "$T/fakebin/gh"
printf '%s' '[{"number":7,"state":"open","title":"t","body":"b","comments":1,"updated_at":"2026-09-19T10:00:00Z","labels":[]}]' > "$T/ctl/issues.body"
printf '%s' '[]' > "$T/ctl/pulls.body"

gate() { OUT=$(HARNESS="$G" PATH="$T/fakebin:$PATH" "$G/bin/triage-gate.sh" "$1" ${2:+"$2"} 2>/dev/null); }
seeded() { # seeded <project> — a seeded board with a fresh full-sweep clock
  rm -f "$G/state/$1".*
  gate "$1" --seed
  printf '%s\n' "$NOW" > "$G/state/$1.gate-meta"
}
GQ="$G/logs/READY-QUEUE.log"

# G1 (test b, fix 3) — harness-console with only PB lines in the file SKIPs.
printf 'TK-12 OWED-STALE 30h [todo/team] Widget\nPB-13 OWED-STALE 31h [todo/team] harness-console widget\n' > "$GQ"
seeded harness-console
gate harness-console
case "$OUT" in "SKIP no-change"*) ok ;; *) bad "G1: harness-console with a TK-only queue must SKIP no-change, got: $OUT" ;; esac
[ ! -e "$G/state/harness-console.queuefp" ] && ok \
  || bad "G1: harness-console must never reach the queue branch (a queuefp was written)"

# G2 (fix 2) — another project's churn never re-offers this one.
printf 'BH-9 9 — waiting on PR #7 project=cromford\nPB-12 OWED-STALE 30h [todo/team] Widget\n' > "$GQ"
seeded cromford
gate cromford
[ "$OUT" = "RUN queue-pending" ] && ok || bad "G2: cromford's first queue tick must RUN queue-pending, got: $OUT"
gate cromford
case "$OUT" in "SKIP queue-unchanged"*) ok ;; *) bad "G2: an unchanged queue must SKIP queue-unchanged, got: $OUT" ;; esac
printf 'TK-98 OWED-STALE 1h [todo/team] y\n' >> "$GQ"
gate cromford
case "$OUT" in "SKIP queue-unchanged"*) ok ;; *) bad "G2: a new FOREIGN PB line must not re-offer cromford, got: $OUT" ;; esac

# G3 (no false skip) — our own new line still wakes the tick.
printf 'BH-10 10 — ready project=cromford\n' >> "$GQ"
gate cromford
[ "$OUT" = "RUN queue-pending" ] && ok || bad "G3: a new cromford line must RUN queue-pending, got: $OUT"

# ── §W: the writer tags its lines ───────────────────────────────────────────
# The REAL `LINES=` statement, extracted verbatim and evaluated with the inputs
# the sweep gives it (one queueable ticket for project-8).
STMT=$(grep -E '^[[:space:]]*LINES=\$\(echo "\$QUEUEABLE" \| jq' "$DIR/bin/stale-owed-tickets.sh" | head -1)
[ -n "$STMT" ] && ok || bad "W1: the LINES= statement was not found in bin/stale-owed-tickets.sh"
LINES=""
P=project-8
QUEUEABLE='[{"key":"TK-12","hours":30,"status":"todo","waitingOn":"team","title":"Widget"}]'
eval "$STMT"
[ "$LINES" = 'TK-12 OWED-STALE 30h [todo/team] Widget project=project-8' ] && ok \
  || bad "W1: a new owed-stale line must end with project=project-8, got: $LINES"
# …and the lib attributes that tagged line by the token alone.
printf '%s\n' "$LINES" > "$Q"
[ "$(lines project-8)" = "$LINES" ] && [ -z "$(lines cromford)" ] && ok \
  || bad "W1: the tagged line must belong to project-8 only"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
