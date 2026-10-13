#!/bin/bash
# bin/context-gate.sh <project> <build-dir> [worktree] — acceptance gate run
# BEFORE a build does any work.
#
# Why (the operator, 2026-08-14): "stop work on a PR if the context was wrong, as a gate
# at the beginning rather than at the end." Reporting drift in the PR body still
# spends a whole build wave — plan, execute, review, QA — producing a diff made
# under rules that disagree with the repo, and then asks a human to notice a
# line in a collapsed block. Cheaper and safer to refuse to start.
#
# Drift means this box's rules or harness bin disagree with its OWN checkout —
# precisely the condition under which three boxes shipped client software for
# weeks against a 2.5KB ruleset while hub had 12.4KB.
#
# Rules drift SELF-HEALS once: re-rendering /root/.claude/CLAUDE.md from the
# checkout writes a data file, which is safe mid-run, and leaves the box correct
# rather than merely blocked.
#
# BIN DRIFT SELF-HEALS TOO, since 2026-09-15. It used to be the one drift a
# human had to resolve, on the reasoning that rsyncing over a script while it is
# executing ate a build in July. That reasoning was right about in-place writes
# and wrong about the cost of refusing: on 2026-09-15 at 12:27Z a lane hot-
# patched bin/queue-line-drop.sh on the hub and all 8 boxes without committing
# it, and this gate then refused EVERY box-side build fleet-wide for 77 minutes.
# The whole fleet stopped, and the evidence was four unrelated refusal lines in
# four project logs and no incident. The rules have healed from the checkout
# since August; bin was the half that did not.
#
# So the drifted files are restored from the checkout with temp-file + mv — a
# rename swaps the directory entry while any already-running copy keeps its open
# inode, which is exactly what the July failure lacked and what harness-sync's
# rsync already does — and the build PROCEEDS. Two conditions bound it:
#   * the checkout must itself be clean and at origin/main (nothing uncommitted,
#     HEAD == origin/main). Healing from a checkout someone is working in would
#     overwrite live bin with a half-finished edit, which is worse than refusing.
#   * flags/bin-self-heal-off turns it back into a refusal.
# Anything else — heal failed, drift survived it — refuses exactly as before.
#
# exit 0 = context accepted (build may proceed)
# exit 1 = REFUSED, reason on stdout
# exit 3 = the checkout was behind and is now synced: the caller re-execs itself
#          ONCE on the fresh harness (bin/lib/rb/gates.sh `# >>> context gate`)
#          and calls this gate again with RB_CTX_REEXEC=1, which proceeds.
#
# Kill switches (BH-2435: the settings row switch.<name>[.<box>], then the
# file): context-gate-disabled (whole gate), bin-self-heal-off (bin healing only).
set -uo pipefail
PROJECT="${1:?project}"; BUILD="${2:?build dir}"; WT="${3:-/root/repos/$PROJECT}"
# HARNESS / HARNESS_CHECKOUT are overridable for TESTS only (the
# pipeline-health.sh, fleet-heartbeat.sh, context-signature.sh idiom): cron and
# run-build.sh never set them, so production resolves to the paths it always had.
HARNESS="${HARNESS:-/root/harness}"
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v ls_isolated >/dev/null 2>&1 || ls_isolated() { [ -f "$HARNESS/flags/$2" ]; }
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/self-heal.sh" 2>/dev/null || true
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
note() { echo "$(STAMP) [$PROJECT] context gate: $*" >> "$HARNESS/logs/agent-rules.log"; }

if ls_isolated lane_switch context-gate-disabled file; then
  echo "gate disabled by $(lane_switch_src context-gate-disabled 2>/dev/null || echo flags/context-gate-disabled)"; exit 0
fi

measure() { "$HARNESS/bin/context-signature.sh" "$PROJECT" "$WT" > "$BUILD/context.json" 2>/dev/null; }

# --- STEP 0: is the CHECKOUT itself current? (the operator, 2026-08-14) -------------
# Everything below compares live files to this box's checkout. That proves
# nothing if the checkout is a day old — the box passes cleanly while building
# under superseded rules, prompts and pipeline code, because the only thing it
# ever checked was that it agreed with itself. So the first question is whether
# the checkout matches origin, and a stale one gets fixed BEFORE any build
# starts rather than reported after.
#
# behind origin -> sync, then answer 3 ("synced, re-exec now") so the caller
#   re-execs run-build.sh on the fresh harness and the build runs entirely on
#   one version instead of half on each. It used to REFUSE (exit 1, "the next
#   watcher tick picks it up") — but the watcher ticks every ~20 min and main
#   merges every few, so the next tick found the checkout behind again and
#   deferred again: BH-1174 and BH-1795 starved for an afternoon (2026-09-28).
#   On the re-exec pass (RB_CTX_REEXEC=1) a checkout that is behind AGAIN is
#   synced and the build PROCEEDS with a note: the rules that matter were
#   synced seconds ago, and a second immediate defer is the starvation itself.
#   A sync that fails still refuses: the fresh code is not on disk.
# diverged/dirty -> refuse; forcing a box's checkout could destroy a hot-fix.
# fetch failed -> proceed with a logged note: an offline box must not halt the
#   fleet, but silence never counts as proof of freshness either.
FRESH=$("$HARNESS/bin/harness-sync.sh" --check 2>/dev/null); FRC=$?
case "$FRC" in
  10)
    SYNC=$("$HARNESS/bin/harness-sync.sh" 2>/dev/null); SRC=$?
    if [ "$SRC" != 0 ]; then
      measure
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] BUILD DEFERRED — harness checkout was $FRESH and the sync failed ($SYNC, rc $SRC); the fresh harness is not on disk, so nothing was built. The next watcher tick retries. Manifest: $BUILD/context.json"
      echo "REFUSED: checkout was stale ($FRESH) and the sync failed ($SYNC, rc $SRC)"
      exit 1
    fi
    if [ -n "${RB_CTX_REEXEC:-}" ]; then
      note "checkout $FRESH again on the re-exec pass — synced ($SYNC) and PROCEEDING; the harness was synced seconds ago and a second defer is the starvation (no second re-exec)"
    else
      measure
      # A self-heal, not a page (BH-4724): info, plus a self_heal ledger row the
      # daily digest counts. No lib on this box yet -> the raw info line.
      MSG="[$PROJECT] BUILD RESTARTED on the fresh harness — checkout was $FRESH; $SYNC. The build re-execs now on the synced code instead of waiting a watcher tick. Manifest: $BUILD/context.json"
      { command -v self_heal_note >/dev/null 2>&1 && self_heal_note context-gate "$PROJECT:$(basename "$BUILD")" "$MSG"; } \
        || HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" --severity info "$MSG"
      echo "SYNCED: checkout was stale ($FRESH) — synced ($SYNC), re-exec on the fresh harness"
      exit 3
    fi ;;
  30)
    measure
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] BUILD REFUSED — harness checkout $FRESH on $(hostname). No plan, no code, no PR. A human resolves this (never force-reset a box): see what was committed locally or diverged, land it, then run /root/harness/bin/harness-sync.sh. Override with /root/harness/flags/context-gate-disabled."
    echo "REFUSED: harness checkout $FRESH"
    exit 1 ;;
  20)
    echo "$(STAMP) [$PROJECT] context gate: checkout freshness UNKNOWN ($FRESH) — proceeding on local context, unverified against origin" >> "$HARNESS/logs/agent-rules.log" ;;
esac

# What drifted, as a comma list. Empty means clean.
drifted() {
  python3 - "$BUILD/context.json" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print("unreadable context.json"); raise SystemExit(0)
bad=[]
if not d.get('machine_rules_in_sync'): bad.append('machine rules')
if not d.get('harness_bin_in_sync'):   bad.append('harness bin')
print(', '.join(bad))
PY
}

measure
BAD=$(drifted)
[ -z "$BAD" ] && { echo "context accepted"; exit 0; }

# One self-heal attempt for the rules, whenever they are among what drifted —
# not only when they are the ONLY thing. Healing what can be healed leaves the
# box closer to correct even if bin drift still forces a refusal.
if [[ "$BAD" == *"machine rules"* ]]; then
  echo "$(STAMP) [$PROJECT] context gate: machine rules drifted — re-applying from checkout" >> "$HARNESS/logs/agent-rules.log"
  "$HARNESS/bin/sync-agent-rules.sh" apply >/dev/null 2>&1
  "$HARNESS/bin/sync-agent-rules.sh" install >/dev/null 2>&1
  measure
  BAD=$(drifted)
  if [ -z "$BAD" ]; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] context gate: rules re-applied from checkout, build proceeding"
    echo "context healed (machine rules re-applied from checkout)"
    exit 0
  fi
fi

COMMIT=$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null || echo unknown)

# --- BIN SELF-HEAL (2026-09-15) --------------------------------------------
# Which top-level bin files disagree with the checkout, one per line. Parity
# with context-signature.sh is deliberate: it measures `maxdepth 1 -type f` and
# ignores everything the checkout does not own (.bak-*, __pycache__), so healing
# a wider set than the signature measures would rewrite files nothing complained
# about and could never clear the flag it was called for.
bin_drifted_files() {
  [ -d "$CHECKOUT/bin" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cmp -s "$CHECKOUT/bin/$f" "$HARNESS/bin/$f" || printf '%s\n' "$f"
  done < <(cd "$CHECKOUT/bin" && find . -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
}
sha8() { [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-8 || echo "-"; }

# The checkout is only a safe source when nothing in it is uncommitted and it is
# at origin/main. Reason on stdout when it is not, so the log says WHICH of the
# two failed rather than "not clean".
checkout_at_origin_main() {
  local dirty head origin
  # captured first: head on a git pipe is a SIGPIPE race under pipefail (BH-1248).
  # The guard matters: `head -3 <<<""` emits one newline, which tr turns into a
  # space, and a dirty of " " would report a clean checkout as uncommitted.
  dirty=$(git -C "$CHECKOUT" status --porcelain 2>/dev/null)
  [ -z "$dirty" ] || dirty=$(head -3 <<<"$dirty" | tr '\n' ' ')
  [ -z "$dirty" ] || { echo "uncommitted work in the checkout: ${dirty% }"; return 1; }
  head=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)
  origin=$(git -C "$CHECKOUT" rev-parse origin/main 2>/dev/null)
  [ -n "$head" ] && [ -n "$origin" ] || { echo "cannot resolve HEAD/origin/main in $CHECKOUT"; return 1; }
  [ "$head" = "$origin" ] || { echo "HEAD ${head:0:8} is not origin/main ${origin:0:8}"; return 1; }
  return 0
}

# temp + mv, NEVER a write into the live path: rename swaps the directory entry
# atomically and any copy already executing keeps its open inode.
#
# The displaced copy is kept under state/bin-selfheal/<stamp>/ first. What we
# are overwriting is, by definition, code no commit records — on 2026-09-15 it
# was somebody's hot patch — and a heal that destroys it is a worse trade than
# the refusal it replaces. Keeping it costs a few KB; a hot patch worth having
# still has to be committed and pushed, because the next harness-sync deploy
# overwrites it exactly the same way.
BACKUP="$HARNESS/state/bin-selfheal/$(date -u '+%Y%m%dT%H%M%SZ')"
heal_bin() {
  local f old new tmp rc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    old=$(sha8 "$HARNESS/bin/$f"); new=$(sha8 "$CHECKOUT/bin/$f")
    tmp="$HARNESS/bin/.ctxheal-$$.$f"
    [ -f "$HARNESS/bin/$f" ] && { mkdir -p "$BACKUP" 2>/dev/null; cp -p "$HARNESS/bin/$f" "$BACKUP/$f" 2>/dev/null; }
    if cp -p "$CHECKOUT/bin/$f" "$tmp" 2>/dev/null && mv -f "$tmp" "$HARNESS/bin/$f" 2>/dev/null; then
      echo "BIN SELF-HEAL $f $old -> $new"
    else
      rm -f "$tmp" 2>/dev/null; rc=1
      echo "BIN SELF-HEAL FAILED $f $old -> $new"
    fi
  done < <(bin_drifted_files)
  return $rc
}

HEAL_NOTE=""
if [[ "$BAD" == *"harness bin"* ]]; then
  if ls_isolated lane_switch bin-self-heal-off file; then
    SH_SRC=$(lane_switch_src bin-self-heal-off 2>/dev/null) || SH_SRC="flags/bin-self-heal-off"
    note "harness bin drifted but $SH_SRC is set — refusing instead of healing"
    HEAL_NOTE=" A bin self-heal was available but $SH_SRC is set."
  elif ! WHY=$(checkout_at_origin_main); then
    # The checkout is the source of truth we would copy FROM. If someone is
    # working in it, copying is how a half-finished edit reaches live bin.
    note "harness bin drifted but the checkout is not a clean origin/main ($WHY) — refusing, not healing"
    HEAL_NOTE=" Bin self-heal was skipped because the checkout is not a clean origin/main ($WHY)."
  else
    HEAL=$(heal_bin); HRC=$?
    while IFS= read -r L; do [ -n "$L" ] && note "$L"; done <<<"$HEAL"
    # grep -c always PRINTS the count, so `|| true` (never `|| echo 0`, which
    # would append a second line) is what keeps it from tripping set -e callers.
    NHEAL=$(grep -c '^BIN SELF-HEAL [^F]' <<<"$HEAL" || true)
    NAMES=$(awk '/^BIN SELF-HEAL [^F]/{print $3}' <<<"$HEAL" | head -6 | tr '\n' ' ')
    measure
    BAD=$(drifted)
    if [ -z "$BAD" ] && [ "$HRC" -eq 0 ]; then
      # ONE alert for the whole heal, not one per file: the operator needs to
      # know the box was running bin no commit records, and which files, once.
      HARNESS="$HARNESS" "$HARNESS/bin/lane-alert.sh" context-gate \
        "BIN SELF-HEAL on $(hostname): $NHEAL harness bin file(s) restored from the checkout ($COMMIT) before [$PROJECT] built — ${NAMES% }. The live copies disagreed with /root/harness-checkout, which used to refuse every build on the box (2026-09-15: 77 minutes, fleet-wide). Each file was replaced temp+mv so a running build kept its open inode, and this build proceeded. The displaced copies are under state/bin-selfheal/ in case one was a hot patch worth keeping — it has to be committed and pushed, because the next harness-sync deploy overwrites it the same way. If a hot-patch is in flight, land it and re-deploy; flags/bin-self-heal-off turns this back into a refusal." >/dev/null 2>&1 || true
      echo "context healed (harness bin restored from checkout: $NHEAL file(s))"
      exit 0
    fi
    HEAL_NOTE=" A bin self-heal ran and did not clear it (healed $NHEAL, still drifted: $BAD)."
    [ -n "$BAD" ] || BAD="harness bin"
  fi
fi

HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] BUILD REFUSED — context drift: $BAD disagree with this box's harness checkout ($COMMIT).$HEAL_NOTE No plan, no code, no PR. Fix on $(hostname): for bin drift, commit+push the change then rsync /root/harness-checkout/bin/ to /root/harness/bin/ (never over a running build); for rules drift that survived a self-heal, check /root/harness-checkout/rules/CLAUDE.md pulled cleanly. Override with /root/harness/flags/context-gate-disabled. Manifest: $BUILD/context.json"
echo "REFUSED: $BAD out of sync with harness checkout ($COMMIT)"
exit 1
