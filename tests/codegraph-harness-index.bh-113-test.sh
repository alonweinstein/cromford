#!/bin/bash
# tests/codegraph-harness-index.bh-113-test.sh — every box keeps a code graph of
# its own harness checkout, refreshed by bin/harness-sync.sh, and the sync never
# pays for it.
#
# WHY (BH-113). bin/codegraph-ensure.sh gives TARGET project clones a
# capability-tested index at build time, but /root/harness-checkout was never
# indexed, so a ticket that modifies the harness itself worked from grep alone.
# bin/codegraph-harness-index.sh runs that same ensure script against the
# checkout (no forked logic) and records its availability line in
# state/codegraph-harness-checkout; harness-sync calls it after the deploy is
# stamped.
#
# A1-A7 drive the wrapper against a tiny REAL repo with the REAL CLI (A4 and A5
# need no CLI at all; A7 runs it under the cron PATH). B1-B5 drive bin/harness-sync.sh itself — the production
# entry point — against a scratch $HARNESS and a real bare origin + clone.
#
# Run from anywhere: tests/codegraph-harness-index.bh-113-test.sh (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
IDX="$DIR/bin/codegraph-harness-index.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null \
  || { echo "codegraph-harness-index.bh-113-test: SKIPPED — git/flock missing"; exit 0; }
# Same rule as tests/codegraph-ensure-test.sh: the real-CLI cases may skip on a
# laptop with no codegraph, never where CODEGRAPH_REQUIRED is set.
HAVE_CG=1
if ! command -v codegraph >/dev/null 2>&1; then
  if [ -n "${CODEGRAPH_REQUIRED:-}" ]; then
    echo "FAIL: CODEGRAPH_REQUIRED is set but no codegraph CLI is on PATH"
    echo "codegraph-harness-index.bh-113-test: 0 passed, 1 failed"; exit 1
  fi
  echo "SKIP (real-CLI cases only): codegraph CLI not installed"
  HAVE_CG=0
fi
REALCG=$(command -v codegraph 2>/dev/null || echo /nonexistent/codegraph)

# ============================================================================
# A. THE WRAPPER, against a tiny real repo
# ============================================================================
H="$T/h"; CK="$T/ck"
mkdir -p "$H/state" "$H/logs" "$H/locks" "$CK/src"
printf 'export function alphaThing(x){ return betaHelper(x) }\nexport function betaHelper(x){ return x + 1 }\n' > "$CK/src/a.ts"
git -C "$CK" init -q .
git -C "$CK" add -A >/dev/null
git -C "$CK" -c user.email=t@t -c user.name=t commit -qm init >/dev/null
NOTE="$H/state/codegraph-harness-checkout"
ULOG="$H/logs/update-runners.log"
# shellcheck disable=SC2163  # "$@" is VAR=val pairs, exported as given
idx() { # idx [VAR=val ...] -> rc in $RC
  ( export HARNESS="$H" HARNESS_CHECKOUT="$CK"; [ $# -gt 0 ] && export "$@"
    bash "$IDX" ) >"$T/idx.out" 2>"$T/idx.err"
  RC=$?
}

if [ "$HAVE_CG" = 1 ]; then
  # A1. missing -> indexed, and the note says AVAILABLE for THIS checkout
  idx
  [ "$RC" = 0 ] && ok || bad "A1: rc must be 0, got $RC: $(cat "$T/idx.err")"
  [ -f "$CK/.codegraph/codegraph.db" ] && ok || bad "A1: a missing index must be created at $CK/.codegraph/codegraph.db"
  grep -qE '^# [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <(head -1 "$NOTE" 2>/dev/null) \
    && ok || bad "A1: note line 1 must be an ISO timestamp: $(head -1 "$NOTE" 2>/dev/null)"
  L2=$(sed -n 2p "$NOTE" 2>/dev/null)
  case "$L2" in "CODEGRAPH AVAILABLE ("*) ok ;; *) bad "A1: note line 2 must be the ensure AVAILABLE line: '$L2'" ;; esac
  case "$L2" in *"-p $CK "*) ok ;; *) bad "A1: the AVAILABLE line must point at the checkout ($CK): '$L2'" ;; esac
  grep -q 'CODEGRAPH AVAILABLE' "$ULOG" 2>/dev/null && ok || bad "A1: update-runners.log must carry the AVAILABLE line: $(cat "$ULOG" 2>/dev/null)"

  # A2. stale -> synced: a new symbol becomes queryable
  echo 'export function gammaNew(){ return 3 }' >> "$CK/src/a.ts"
  idx
  [ "$RC" = 0 ] && ok || bad "A2: rc must be 0, got $RC"
  codegraph query -p "$CK" gammaNew 2>&1 | grep -q gammaNew \
    && ok || bad "A2: a stale index must be refreshed so gammaNew is found"

  # A3. current -> no init, no sync
  cat > "$T/rec" <<EOF
#!/bin/bash
echo "\$1" >> "$T/rec.log"
exec "$REALCG" "\$@"
EOF
  chmod +x "$T/rec"; : > "$T/rec.log"
  idx CODEGRAPH_BIN="$T/rec"
  [ "$RC" = 0 ] && ok || bad "A3: rc must be 0, got $RC"
  grep -q '^status$' "$T/rec.log" && ok || bad "A3: the recorder must have been called (status): $(cat "$T/rec.log")"
  ! grep -qE '^(init|sync|index)$' "$T/rec.log" \
    && ok || bad "A3: a current index must not be re-built: $(tr '\n' ' ' < "$T/rec.log")"
  case "$(sed -n 2p "$NOTE")" in "CODEGRAPH AVAILABLE ("*) ok ;; *) bad "A3: a current index is still AVAILABLE: $(sed -n 2p "$NOTE")" ;; esac
fi

# A4. CLI absent -> NOT AVAILABLE, rc 0
idx CODEGRAPH_BIN="$T/nope"
[ "$RC" = 0 ] && ok || bad "A4: rc must be 0 with no CLI, got $RC"
case "$(sed -n 2p "$NOTE" 2>/dev/null)" in
  "CODEGRAPH NOT AVAILABLE (codegraph CLI not installed"*) ok ;;
  *) bad "A4: note must say the CLI is not installed: '$(sed -n 2p "$NOTE" 2>/dev/null)'" ;;
esac

# A5. a hanging CLI is bounded and reads NOT AVAILABLE, never AVAILABLE
printf '#!/bin/bash\nsleep 30\n' > "$T/hang"; chmod +x "$T/hang"
S=$(date +%s)
idx CODEGRAPH_BIN="$T/hang" CODEGRAPH_INDEX_TIMEOUT_S=1
E=$(( $(date +%s) - S ))
[ "$RC" = 0 ] && ok || bad "A5: rc must be 0 on a hang, got $RC"
[ "$E" -lt 10 ] && ok || bad "A5: a hang must be cut off by the timeout, took ${E}s"
case "$(sed -n 2p "$NOTE" 2>/dev/null)" in
  "CODEGRAPH NOT AVAILABLE (indexing $CK timed out after 1s)") ok ;;
  *) bad "A5: note must say the index timed out: '$(sed -n 2p "$NOTE" 2>/dev/null)'" ;;
esac
# A stub that answers but says nothing is not a verdict either.
printf '#!/bin/bash\nexit 0\n' > "$T/muteensure"
( mkdir -p "$T/mutebin"; cp "$IDX" "$T/mutebin/codegraph-harness-index.sh"; cp "$T/muteensure" "$T/mutebin/codegraph-ensure.sh"; chmod +x "$T/mutebin/"* )
( export HARNESS="$H" HARNESS_CHECKOUT="$CK"; bash "$T/mutebin/codegraph-harness-index.sh" ) >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "A5b: rc must be 0 when ensure is silent, got $RC"
case "$(sed -n 2p "$NOTE" 2>/dev/null)" in
  "CODEGRAPH NOT AVAILABLE (ensure produced no verdict)") ok ;;
  *) bad "A5b: an empty ensure answer must be NOT AVAILABLE: '$(sed -n 2p "$NOTE" 2>/dev/null)'" ;;
esac

# A7. the cron PATH (/usr/bin:/bin, the update-runners backstop) still finds the
# CLI in /usr/local/bin, and reads AVAILABLE rather than "not installed".
if [ "$HAVE_CG" = 1 ] && [ -x /usr/local/bin/codegraph ]; then
  rm -f "$NOTE"
  env -i HOME="$T" PATH=/usr/bin:/bin HARNESS="$H" HARNESS_CHECKOUT="$CK" \
    bash "$IDX" >/dev/null 2>&1
  RC=$?
  [ "$RC" = 0 ] && ok || bad "A7: rc must be 0 under the cron PATH, got $RC"
  case "$(sed -n 2p "$NOTE" 2>/dev/null)" in
    "CODEGRAPH AVAILABLE ("*"-p $CK "*) ok ;;
    *) bad "A7: under PATH=/usr/bin:/bin the note must say AVAILABLE: '$(sed -n 2p "$NOTE" 2>/dev/null)'" ;;
  esac
else
  # A box-layout case, not a capability one: the wrapper adds only
  # /usr/local/bin to the cron PATH, so a CLI installed elsewhere (CI's npm -g
  # lands in the node toolcache) is not what this case is about. The real-CLI
  # capability is still required by A1-A3 under CODEGRAPH_REQUIRED.
  echo "SKIP A7: skipped: CLI not at /usr/local/bin (installed CLI: $REALCG)"
fi

# A6. busy lock -> skipped, note untouched, rc 0
BEFORE=$(sha256sum < "$NOTE")
( flock 9; exec sleep 5 ) 9>"$H/locks/codegraph-harness-index.lock" &
HOLDER=$!
wait_holder "$HOLDER"
idx CODEGRAPH_BIN="$T/nope"
[ "$RC" = 0 ] && ok || bad "A6: rc must be 0 on a busy lock, got $RC"
[ "$(sha256sum < "$NOTE")" = "$BEFORE" ] && ok || bad "A6: a busy lock must leave the note untouched"
grep -q 'another run is indexing, skipped' "$ULOG" && ok || bad "A6: a busy lock must log the skip: $(tail -1 "$ULOG")"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# ============================================================================
# B. THROUGH bin/harness-sync.sh (the production entry point)
# ============================================================================
B="$T/b"
mkdir -p "$B/bin" "$B/logs" "$B/state" "$B/locks" "$B/flags" "$B/prompts" \
         "$B/fly" "$B/catalog" "$B/checks" "$B/guardrails" "$B/config" "$B/env"
cp "$DIR/bin/alert-line.sh" "$B/bin/"
mkfixture() { # mkfixture <origin> <clone>
  git init -q --bare "$1"
  git clone -q "$1" "$2" 2>/dev/null
  git -C "$2" config user.email t@t; git -C "$2" config user.name t
  mkdir -p "$2/bin" "$2/prompts" "$2/fly" "$2/catalog" "$2/src"
  printf '#!/bin/bash\n:\n' > "$2/bin/x.sh"
  cp "$DIR/bin/codegraph-ensure.sh" "$DIR/bin/codegraph-harness-index.sh" "$2/bin/" 2>/dev/null
  cp "$DIR/.gitignore" "$2/.gitignore"
  printf 'export function harnessThing(x){ return x }\n' > "$2/src/a.ts"
  printf 'p\n' > "$2/prompts/p.md"; printf 'f\n' > "$2/fly/f.txt"
  printf '{}\n' > "$2/catalog/c.json"; printf 'fleet\n' > "$2/fleet.conf"
  git -C "$2" add -A >/dev/null
  git -C "$2" commit -qm seed
  git -C "$2" branch -M main 2>/dev/null
  git -C "$2" push -q origin main
  git -C "$2" branch --set-upstream-to=origin/main main >/dev/null 2>&1
}
mkfixture "$T/origin" "$T/bck"
sync() { # sync <harness> <checkout> [VAR=val ...] -- [args] -> rc in $RC
  local h="$1" c="$2"; shift 2
  local envs=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  ( export HARNESS="$h" HARNESS_CHECKOUT="$c"; [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}

# S0. SAFETY PROBE — see tests/harness-sync-stamps-test.sh. A dirty checkout
# must refuse INSIDE the scratch tree before any deploy path runs.
echo probe >> "$T/bck/bin/x.sh"
sync "$B" "$T/bck"
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$B/logs/ALERTS.log" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — refusing to run the deploy path"
  echo "codegraph-harness-index.bh-113-test: $PASS passed, $((FAIL+1)) failed"
  exit 1
fi
ok
git -C "$T/bck" checkout -q -- bin/x.sh
rm -f "$B/state/harness-sync-last-refused"

BNOTE="$B/state/codegraph-harness-checkout"
if [ "$HAVE_CG" = 1 ]; then
  # B1. a deploy indexes the checkout and records AVAILABLE
  sync "$B" "$T/bck"
  [ "$RC" = 0 ] && ok || bad "B1: a clean deploy must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
  [ -f "$T/bck/.codegraph/codegraph.db" ] && ok || bad "B1: harness-sync must index the checkout ($T/bck/.codegraph/codegraph.db missing)"
  case "$(sed -n 2p "$BNOTE" 2>/dev/null)" in
    "CODEGRAPH AVAILABLE ("*"-p $T/bck "*) ok ;;
    *) bad "B1: the note must say AVAILABLE for the checkout: '$(sed -n 2p "$BNOTE" 2>/dev/null)'" ;;
  esac
  [ "$(wc -l < "$T/out.txt")" = 1 ] && ok || bad "B1: stdout must stay one status line: $(cat "$T/out.txt")"

  # B4. the index never dirties the checkout
  [ -z "$(git -C "$T/bck" status --porcelain)" ] \
    && ok || bad "B4: the index must not show in git status: $(git -C "$T/bck" status --porcelain)"
fi

# B5. the same through harness-sync under the cron PATH (update-runners' leg)
if [ "$HAVE_CG" = 1 ] && [ -x /usr/local/bin/codegraph ]; then
  rm -f "$BNOTE"
  env -i HOME="$T" PATH=/usr/bin:/bin HARNESS="$B" HARNESS_CHECKOUT="$T/bck" \
    bash "$DIR/bin/harness-sync.sh" >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
  [ "$RC" = 0 ] && ok || bad "B5: a cron-PATH deploy must exit 0, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
  case "$(sed -n 2p "$BNOTE" 2>/dev/null)" in
    "CODEGRAPH AVAILABLE ("*"-p $T/bck "*) ok ;;
    *) bad "B5: under PATH=/usr/bin:/bin the note must say AVAILABLE: '$(sed -n 2p "$BNOTE" 2>/dev/null)'" ;;
  esac
else
  echo "SKIP B5: skipped: CLI not at /usr/local/bin (installed CLI: $REALCG)"
fi

# B2. no CLI: the sync still deploys, stamps, and says one line
rm -f "$B/state/harness-sync-last-success"
sync "$B" "$T/bck" CODEGRAPH_BIN="$T/nope"
[ "$RC" = 0 ] && ok || bad "B2: no CLI must not fail the sync, got $RC: $(cat "$T/out.txt") $(cat "$T/err.txt")"
[ "$(wc -l < "$T/out.txt")" = 1 ] && grep -qE '^(deployed|synced) ' "$T/out.txt" \
  && ok || bad "B2: stdout must be exactly one status line: $(cat "$T/out.txt")"
[ -s "$B/state/harness-sync-last-success" ] && ok || bad "B2: the success stamp must still be written"
case "$(sed -n 2p "$BNOTE" 2>/dev/null)" in
  "CODEGRAPH NOT AVAILABLE (codegraph CLI not installed"*) ok ;;
  *) bad "B2: the note must say NOT AVAILABLE: '$(sed -n 2p "$BNOTE" 2>/dev/null)'" ;;
esac

# B3. --check indexes nothing and writes no note
B3="$T/b3"; mkdir -p "$B3/logs" "$B3/state" "$B3/locks"
mkfixture "$T/origin3" "$T/bck3"
sync "$B3" "$T/bck3" -- --check
[ ! -e "$B3/state/codegraph-harness-checkout" ] && ok || bad "B3: --check must not write the note"
[ ! -e "$T/bck3/.codegraph/codegraph.db" ] && ok || bad "B3: --check must not index"

echo "codegraph-harness-index.bh-113-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
