#!/bin/bash
# tests/rebase-on-pool-contract-test.sh — the REBASE_ON_POOL contract (BH-486.0).
#
# WHAT THIS PINS. Under the flag, a rebase is a pool job, so the hub must do
# NOTHING: no credential resolved, no clone, no worktree, no temp directory —
# and mc_rebase must answer rc 7 (queue unreachable, nothing spent) while the
# enqueue is still a stub. With the flag off the very same call must reach git
# exactly as it does today, because the flag ships OFF and every conductor,
# resolver and train-ahead rebase runs through this one function.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q mc_pool_rebase_enabled bin/lib/...` passes
# on a guard that sits BELOW mc_git_auth, which is the whole failure this file
# exists to catch: the credential would already be on disk and the askpass
# helper already written. The fake `git` here records every argv and answers
# $GIT_ASKPASS the way git does, so the assertions are about what actually
# reached the process — an empty argv file is the proof, not a source line.
#
# Run from anywhere: tests/rebase-on-pool-contract-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

OLDSHA=1111111111111111111111111111111111111111
OTHERSHA=3333333333333333333333333333333333333333
TOK=tok_FAKE_VALUE_0001
SLUG=Example/private-repo
PROJ=tproj
URL="https://github.com/$SLUG/pull/21"

export HARNESS="$T/h"
unset REBASE_ON_POOL
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/fakebin" "$T/repos"

# --- the fake git: records argv, and asks askpass exactly like git does -------
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git-argv.txt"
if [ -n "\${GIT_ASKPASS:-}" ] && [ -x "\${GIT_ASKPASS:-}" ]; then
  "\$GIT_ASKPASS" "Password for 'https://x-access-token@github.com': " >> "$T/git-askpass.txt"
fi
SUB=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -C) shift 2 ;;
    -c) shift 2 ;;
    *) SUB="\$1"; shift; break ;;
  esac
done
case "\$SUB" in
  ls-remote) case " \$* " in *" -h "*|*" --heads "*) exit 2 ;; esac; exit 0 ;;
  clone)     D="\${!#}"; mkdir -p "\$D/.git"; exit 0 ;;
  worktree)  if [ "\${1:-}" = add ]; then for a in "\$@"; do case "\$a" in /*) mkdir -p "\$a" ;; esac; done; fi; exit 0 ;;
  rev-parse) echo "$OTHERSHA"; exit 0 ;;   # never the head we read -> mc_rebase stops at the lease check
  *)         exit 0 ;;
esac
EOF
chmod +x "$T/fakebin/git"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  "api repos/$SLUG -q .id") exit 0 ;;
  "auth token") echo "$TOK"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
export PATH="$T/fakebin:$PATH"

printf 'GH_ADMIN_TOKEN=%s\n' "tok_FAKE_ADMIN_0002" > "$T/h/env/github-admin.env"; chmod 600 "$T/h/env/github-admin.env"
export GH_TOKEN="$TOK"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebase-job.sh" "$T/h/bin/lib/" 2>/dev/null
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/gh-repo-token.sh"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=/dev/null
. "$T/h/bin/lib/rebase-job.sh" 2>/dev/null || true
export MC_REPOS="$T/repos"   # no hub clone -> the scratch-clone path, which is where $H/tmp/conductor appears

reset_run() { : > "$T/git-argv.txt"; : > "$T/git-askpass.txt"; : > "$MC_LOG"; rm -rf "$T/h/tmp"; touch "$T/mark"; }
nopool_lines() { grep -c "REBASE_ON_POOL=1 but no pool app for $PROJ" "$MC_LOG" 2>/dev/null || true; }

# ============================================================================
# (a) FLAG OFF is today: mc_rebase reaches git.
# ============================================================================
reset_run
mc_rebase "$SLUG" "$PROJ" ticket/x-1 "$OLDSHA" "$URL" >/dev/null 2>&1; RC_A=$?
grep -q "fetch" "$T/git-argv.txt" && ok || bad "flag off: mc_rebase must still reach git (argv: $(tr '\n' '|' < "$T/git-argv.txt"))"
[ "$RC_A" != 7 ] && ok || bad "flag off must never answer rc 7 — that is the pool arm"

# ============================================================================
# (b) FLAG ON: rc 7, and the hub ran NOTHING. No git argv, no credential, no
#     scratch clone, no $TMPDIR/mc-rebase-* worktree.
# ============================================================================
reset_run
touch "$T/h/flags/fly-pool-app-$PROJ"
export REBASE_ON_POOL=1
mc_rebase "$SLUG" "$PROJ" ticket/x-1 "$OLDSHA" "$URL" >/dev/null 2>&1; RC_B=$?
[ "$RC_B" = 7 ] && ok || bad "flag on must answer rc 7 from the enqueue stub (got $RC_B)"
[ "$(wc -c < "$T/git-argv.txt")" = 0 ] && ok || bad "flag on ran git: $(tr '\n' '|' < "$T/git-argv.txt")"
[ "$(wc -c < "$T/git-askpass.txt")" = 0 ] && ok || bad "flag on resolved a credential — the guard is below mc_git_auth"
[ ! -d "$T/h/tmp/conductor" ] && ok || bad "flag on left a scratch clone at \$H/tmp/conductor"
[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mc-rebase-*' -newer "$T/mark" 2>/dev/null)" ] \
  && ok || bad "flag on left a mc-rebase-* worktree in TMPDIR"
[ "$(nopool_lines)" = 0 ] && ok || bad "a project WITH a pool app must not log the no-pool-app line"

# ============================================================================
# (c1) The env file is the other source: REBASE_ON_POOL=1 in env/<project>.env
#      with NO pool app falls back to the hub and says so exactly once.
# ============================================================================
reset_run
unset REBASE_ON_POOL
rm -f "$T/h/flags/fly-pool-app-$PROJ"
printf 'REBASE_ON_POOL=1\n' > "$T/h/env/$PROJ.env"
mc_rebase "$SLUG" "$PROJ" ticket/x-1 "$OLDSHA" "$URL" >/dev/null 2>&1; RC_C=$?
[ "$RC_C" = "$RC_A" ] && ok || bad "flag 1 with no pool app must rebase on the hub exactly as flag off (rc $RC_C vs $RC_A)"
grep -q "fetch" "$T/git-argv.txt" && ok || bad "flag 1 with no pool app must still reach git"
[ "$(nopool_lines)" = 1 ] && ok || bad "exactly one 'no pool app' line per call (got $(nopool_lines))"

# ============================================================================
# (c2) The environment beats the file: REBASE_ON_POOL=0 exported over a file 1,
#      pool app present -> off, and silently (nothing to say, nothing to page).
# ============================================================================
reset_run
touch "$T/h/flags/fly-pool-app-$PROJ"
export REBASE_ON_POOL=0
mc_rebase "$SLUG" "$PROJ" ticket/x-1 "$OLDSHA" "$URL" >/dev/null 2>&1; RC_C2=$?
[ "$RC_C2" = "$RC_A" ] && ok || bad "an exported 0 must override an env-file 1 (rc $RC_C2 vs $RC_A)"
grep -q "fetch" "$T/git-argv.txt" && ok || bad "an exported 0 must leave the hub path intact"
[ "$(nopool_lines)" = 0 ] && ok || bad "an explicit 0 must say nothing (got $(nopool_lines) lines)"

# ============================================================================
# (c3) Unset, no env file, no pool app -> rc 1, silently.
# ============================================================================
reset_run
unset REBASE_ON_POOL
rm -f "$T/h/env/$PROJ.env" "$T/h/flags/fly-pool-app-$PROJ"
mc_pool_rebase_enabled "$PROJ"; RC_C3=$?
[ "$RC_C3" = 1 ] && ok || bad "unset must be rc 1 (got $RC_C3)"
[ "$(wc -c < "$MC_LOG")" = 0 ] && ok || bad "unset must log nothing (log: $(cat "$MC_LOG"))"
# and the pool app alone, with no flag, is not a pool project either
touch "$T/h/flags/fly-pool-app-$PROJ"
mc_pool_rebase_enabled "$PROJ" && bad "a pool app with no REBASE_ON_POOL must not enable the pool arm" || ok
rm -f "$T/h/flags/fly-pool-app-$PROJ"

# ============================================================================
# (d) The queue/ledger key.
# ============================================================================
# The fixture head is assembled from pieces, same as everywhere else in the
# suite: the mirror's leak guard matches any 32-run of [0-9a-f] and cannot tell
# a made-up id from a real one — hex holds no fixture marker, and
# tests/share-known-fakes-test.sh check 3 only proves uuid and address shapes —
# so a 32-character literal here refuses every publish. The value is unchanged.
HEAD_FIXTURE="aaaaaaaa""bbbbbbbb""cccccccc""dddddddd"
K=$(mc_pool_rebase_key 21 "$HEAD_FIXTURE")
[ "$K" = "RB-21-aaaaaaaa" ] && ok || bad "mc_pool_rebase_key must print RB-<num>-<head8> (got '$K')"
K2=$(mc_pool_rebase_key 7 abc)
[ "$K2" = "RB-7-abc" ] && ok || bad "a short head is printed as it is, never padded (got '$K2')"

# ============================================================================
# (e) The machine side, from the hub's seat: a RESULT file the reap can read,
#     and rc 1 on the one refusal that needs no git at all.
#
#     BH-543 replaced the stub body, so the word this used to pin
#     ("not implemented") is gone. What the CONTRACT owns is unchanged and is
#     what is pinned here: rebase_job_run answers with a canonical first line
#     plus the full PR:/HEAD:/BRANCH:/BASE: trailer, and it refuses before it
#     touches git when its <harness> carries no conflict resolver. The harness
#     is named EXPLICITLY — this suite has already sourced the conductor lib, so
#     an inherited one would find a resolver and go on to the fake git.
# ============================================================================
reset_run
rebase_job_run r "$SLUG" ticket/x-1 "$OLDSHA" main "$T/RESULT" "$T/no-such-harness" >/dev/null 2>&1; RC_E=$?
[ "$RC_E" = 1 ] && ok || bad "rebase_job_run must return 1 when it refuses (got $RC_E)"
[ "$(head -1 "$T/RESULT" 2>/dev/null)" = "REBASE_SETUP_FAILED no conflict resolver" ] \
  && ok || bad "a harness with no conductor lib must answer REBASE_SETUP_FAILED no conflict resolver (got '$(head -1 "$T/RESULT" 2>/dev/null)')"
[ "$(wc -c < "$T/git-argv.txt")" = 0 ] \
  && ok || bad "the resolver guard runs BEFORE any git: $(tr '\n' '|' < "$T/git-argv.txt")"
for L in "PR: " "HEAD: $OLDSHA" "BRANCH: ticket/x-1" "BASE: main"; do
  grep -qF "$L" "$T/RESULT" && ok || bad "the RESULT must carry '$L' on every path"
done
"$DIR/bin/result-prefix-ok.sh" "$(head -1 "$T/RESULT" 2>/dev/null)" \
  && ok || bad "the reap gate must read that first line as a RESULT"
for W in "REBASED abc" "CONFLICT a.txt" "GATE_RED unit"; do
  "$DIR/bin/result-prefix-ok.sh" "$W" && ok || bad "the reap gate must accept '$W'"
done
"$DIR/bin/result-prefix-ok.sh" "  REBASED abc" && bad "a leading space is still a mexec miss" || ok
mc_pool_rebase_apply "$PROJ" RB-21-aaaaaaaa "$T/RESULT"; RC_AP=$?
[ "$RC_AP" = 1 ] && ok || bad "the mc_pool_rebase_apply stub must return 1 until BH-486.2 (got $RC_AP)"
# sourcing the job lib must write nothing: a lane sources it, it is not a script
D="$T/rebase-job-source"; mkdir -p "$D"
OUT=$( cd "$D" && . "$DIR/bin/lib/rebase-job.sh" >/dev/null 2>&1; ls -A )
[ -z "$OUT" ] && ok || bad "sourcing bin/lib/rebase-job.sh created files: $OUT"
scratch_rm "$D"

# ============================================================================
# (f) The pool timeout knob: a documented default, overridable by an operator.
# ============================================================================
[ "${MC_REBASE_POOL_TIMEOUT_SECS:-unset}" = 5400 ] && ok || bad "MC_REBASE_POOL_TIMEOUT_SECS must default to 5400 (got '${MC_REBASE_POOL_TIMEOUT_SECS:-unset}')"
V=$( MC_REBASE_POOL_TIMEOUT_SECS=7 bash -c '. "$1"; echo "$MC_REBASE_POOL_TIMEOUT_SECS"' _ "$T/h/bin/lib/merge-conductor-lib.sh" 2>/dev/null )
[ "$V" = 7 ] && ok || bad "an exported MC_REBASE_POOL_TIMEOUT_SECS must win (got '$V')"

echo "rebase-on-pool-contract-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
