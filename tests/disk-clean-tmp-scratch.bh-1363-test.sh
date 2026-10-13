#!/bin/bash
# tests/disk-clean-tmp-scratch.bh-1363-test.sh — disk-clean's stage 8: the stale
# scratch under $H/tmp that nothing owns and nothing else ever removes (BH-1363).
#
# WHY IT EXISTS. The hub hit 92% disk on 2026-09-22 with 14 GB of
# blocked-resolver fix worktrees in /root/harness/tmp/brfix/, dated 09-17..09-20.
# Stage 3 walks every registered worktree and KEEPS any whose HEAD is on no
# remote unless its basename is `triage-*` — and a `brfix/<ck>` checkpoint is
# local-only by construction, so a leaked fix worktree was ineligible for that
# sweep for ever. The resolver's own trap (tests/blocked-resolver-wt-cleanup.bh-1363-test.sh)
# covers every exit a shell can catch; this stage is the backstop for the ones
# it cannot — SIGKILL, OOM, a power cut.
#
# What is proved here, against the REAL bin/disk-clean.sh over a REAL git repo
# with REAL registered worktrees and a frozen clock:
#   §1  a 48 h old brfix worktree nothing holds is removed and its registration
#       pruned;                                    §2  a fresh one is kept;
#   §3  one whose path is a /proc/<pid>/cwd target is kept and counted skipped;
#   §4  one named in the stage-3 pgrep line is kept and counted skipped;
#   §5  the `brfix/<ck>` branches still resolve, `git worktree list` has no
#       stale entry and the repo is clean — the checkpoint is never collateral;
#   §6  the summary line's three counters are the work that really happened;
#   §7  a stale state-backup staging dir goes, a fresh one stays;
#   §8  tmp/batch-resolve/<slug> (a deliberate clone cache), tmp/state-restore,
#       a FILE under tmp/brfix/ and a SYMLINK under tmp/brfix/ are untouched at
#       any age, and a stale dir whose .git names a repo outside $REPOS is
#       removed without any git command being run against that repo;
#   §9  an empty $H/tmp is silent and counts zero;
#   §10 a non-numeric TMP_SCRATCH_STALE_H says so and falls back to 24 h.
# Run from anywhere: tests/disk-clean-tmp-scratch.bh-1363-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

NOW=1789514400            # 2026-09-15T23:20:00Z — every fixture age derives from this
OLD=$((NOW - 48 * 3600))  # two days: past the 24 h default
export GIT_AUTHOR_NAME=harness GIT_AUTHOR_EMAIL=harness@test
export GIT_COMMITTER_NAME=harness GIT_COMMITTER_EMAIL=harness@test

H="$T/h"
REPO="$T/repos/tproj"
OUTREPO="$T/outside/other"
LOG="$H/logs/disk-clean.log"
mkdir -p "$T/fakebin" "$T/nonpm"
# pgrep: whatever the case put in $T/pgrep.txt, "nothing running" otherwise.
cat > "$T/fakebin/pgrep" <<SH
#!/bin/bash
[ -f "$T/pgrep.txt" ] || exit 1
cat "$T/pgrep.txt"
SH
# THE BREAKER (§11 only, and only for the one path DC_BREAK names). A removal
# that fails everything is not reachable as root with permission bits — root
# ignores them — so the failure is injected where the code meets the system.
cat > "$T/fakebin/git" <<'SH'
#!/bin/bash
if [ -n "${DC_BREAK:-}" ]; then
  case " $* " in
    *" worktree remove "*) case " $* " in *"$DC_BREAK"*) exit 128 ;; esac ;;
  esac
fi
exec /usr/bin/git "$@"
SH
cat > "$T/fakebin/rm" <<'SH'
#!/bin/bash
if [ -n "${DC_BREAK:-}" ]; then
  case " $* " in *"$DC_BREAK"*) exit 1 ;; esac
fi
exec /usr/bin/rm "$@"
SH
chmod +x "$T/fakebin/git" "$T/fakebin/rm"
[ -x /usr/bin/git ] && [ -x /usr/bin/rm ] || { echo "git/rm not where the shims expect them — skipping"; exit 0; }
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/crontab"
printf '#!/bin/bash\nprintf "%%s\\n" "npm \$*" >> "%s/calls.log"\nexit 1\n' "$T" > "$T/fakebin/npm"
chmod +x "$T/fakebin/pgrep" "$T/fakebin/crontab" "$T/fakebin/npm"
export PATH="$T/fakebin:$PATH"

age() { # age <epoch> <dir> — the dir and everything directly inside it
  find "$2" -maxdepth 1 -exec touch -h -d "@$1" {} + 2>/dev/null
}

mkfix() { # a scratch harness, a real repo, and the tmp tree under test
  scratch_rm "$H"; scratch_rm "$T/repos"; scratch_rm "$T/outside"; scratch_rm "$T/proc"
  rm -f "$T/pgrep.txt" "$T/calls.log"
  mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/tmp" \
           "$T/repos" "$T/proc"
  cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
  : > "$H/env/global.env"
  git init -q -b main "$REPO"
  echo base > "$REPO/base.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm base
}

mkwt() { # mkwt <name> <ck> <epoch> [payload-mb]
  git -C "$REPO" worktree add -q -b "brfix/$2" "$H/tmp/brfix/$1" >/dev/null 2>&1 \
    || { bad "fixture: worktree add failed for $1"; return 1; }
  [ -n "${4:-}" ] && dd if=/dev/zero of="$H/tmp/brfix/$1/payload.bin" bs=1M count="$4" >/dev/null 2>&1
  age "$3" "$H/tmp/brfix/$1"
}

run() { # run [VAR=VAL ...] — the production entry point, as cron drives it
  env PATH="$T/fakebin:$PATH" HARNESS_ROOT="$H" ETC_HARNESS_ENV="$T/no-such-etc" \
      DISK_CLEAN_REPOS="$T/repos" DISK_CLEAN_NPM_DIR="$T/nonpm" \
      DISK_CLEAN_NOW="$NOW" DISK_CLEAN_PROC="$T/proc" \
      "$@" bash "$DIR/bin/disk-clean.sh" > "$T/run.out" 2>&1
}
summary() { grep 'disk-clean: ' "$LOG" 2>/dev/null | tail -1; }
wtlist()  { git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}'; }

# ============================================================================
# THE MAIN SWEEP: four brfix worktrees (stale, fresh, held two different ways),
# two state-backup staging dirs, and every must-NOT-fire neighbour.
# ============================================================================
mkfix
mkwt brfix-stale      tproj-TK-91 "$OLD" 1     # 1 MB payload: tmp_freed_kb has to see it
mkwt brfix-fresh      tproj-TK-92 "$NOW"
mkwt brfix-held-cwd   tproj-TK-93 "$OLD"
mkwt brfix-held-pgrep tproj-TK-94 "$OLD"
# A stale dir whose .git names a repo OUTSIDE $REPOS: the scratch goes, and no
# git command may be aimed at the repo it names.
git init -q -b main "$OUTREPO"
echo o > "$OUTREPO/o.txt"; git -C "$OUTREPO" add -A && git -C "$OUTREPO" commit -qm o
git -C "$OUTREPO" worktree add -q -b brfix/outside "$H/tmp/brfix/brfix-outside" >/dev/null 2>&1
age "$OLD" "$H/tmp/brfix/brfix-outside"
# The neighbours. None of these is ever a candidate.
mkdir -p "$H/tmp/batch-resolve/o_tproj" "$H/tmp/state-restore" "$H/tmp/state-backup.OLDaa" \
         "$H/tmp/state-backup.NEWbb"
printf 'clone cache\n' > "$H/tmp/batch-resolve/o_tproj/marker"
printf 'restore\n'     > "$H/tmp/state-restore/marker"
printf 'staging\n'     > "$H/tmp/state-backup.OLDaa/marker"
printf 'staging\n'     > "$H/tmp/state-backup.NEWbb/marker"
printf 'not a worktree\n' > "$H/tmp/brfix/loose-file"
ln -s "$REPO" "$H/tmp/brfix/a-symlink"
age "$OLD" "$H/tmp/batch-resolve/o_tproj"; age "$OLD" "$H/tmp/batch-resolve"
age "$OLD" "$H/tmp/state-restore"
age "$OLD" "$H/tmp/state-backup.OLDaa"
age "$NOW" "$H/tmp/state-backup.NEWbb"
touch -h -d "@$OLD" "$H/tmp/brfix/loose-file" "$H/tmp/brfix/a-symlink"
# The holders: one /proc/<pid>/cwd symlink, one pgrep cmdline.
mkdir -p "$T/proc/4242"
ln -s "$H/tmp/brfix/brfix-held-cwd" "$T/proc/4242/cwd"
printf '5150 /root/harness/bin/agent-call.sh execute in %s\n' "$H/tmp/brfix/brfix-held-pgrep" > "$T/pgrep.txt"
KB_BEFORE=$(du -sk "$H/tmp/brfix/brfix-stale" 2>/dev/null | cut -f1)

run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "the sweep exited $RC ($(tail -5 "$T/run.out"))"

# §1 / §2
[ ! -e "$H/tmp/brfix/brfix-stale" ] \
  && ok || bad "§1 a 48h brfix worktree nothing holds survived the sweep"
[ -d "$H/tmp/brfix/brfix-fresh" ] \
  && ok || bad "§2 a brfix worktree from this minute was deleted"
# §3 / §4
[ -d "$H/tmp/brfix/brfix-held-cwd" ] \
  && ok || bad "§3 a worktree a live process has as its cwd was deleted"
[ -d "$H/tmp/brfix/brfix-held-pgrep" ] \
  && ok || bad "§4 a worktree named in the pgrep line was deleted"
# §5 the checkpoint branches and the repo itself
for ck in tproj-TK-91 tproj-TK-92 tproj-TK-93 tproj-TK-94; do
  git -C "$REPO" rev-parse --verify -q "brfix/$ck" >/dev/null \
    && ok || bad "§5 brfix/$ck was deleted with its worktree — that branch is the round's paid-for work"
done
grep -qF "$H/tmp/brfix/brfix-stale" <<<"$(wtlist)" \
  && bad "§5 the removed worktree is still registered: $(wtlist)" || ok
wtlist | grep -qF "$H/tmp/brfix/brfix-fresh" \
  && ok || bad "§5 the kept worktree lost its registration: $(wtlist)"
[ -z "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] \
  && ok || bad "§5 the sweep left the repo dirty: $(git -C "$REPO" status --porcelain)"
# §6 the counters
summary | grep -q 'tmp_removed=3' \
  && ok || bad "§6 want tmp_removed=3 (brfix-stale, brfix-outside, state-backup.OLDaa): $(summary)"
summary | grep -q 'tmp_skipped_held=2' \
  && ok || bad "§6 want tmp_skipped_held=2 (the cwd holder and the pgrep holder): $(summary)"
FREED=$(summary | sed -n 's/.*tmp_freed_kb=\([0-9]*\).*/\1/p')
[ -n "$FREED" ] && [ "${FREED:-0}" -ge "${KB_BEFORE:-1024}" ] \
  && ok || bad "§6 tmp_freed_kb=${FREED:-<missing>} is below the ${KB_BEFORE:-?} KB the fixture really freed: $(summary)"
summary | grep -q 'disk-clean: [0-9]*%->[0-9]*% npm=' \
  && ok || bad "§6 the original counters left the summary line: $(summary)"
# §7 state-backup staging
[ ! -e "$H/tmp/state-backup.OLDaa" ] \
  && ok || bad "§7 a stale state-backup staging dir survived"
[ -d "$H/tmp/state-backup.NEWbb" ] \
  && ok || bad "§7 a staging dir from this minute was deleted — a live backup was mid-flight"
# §8 the must-NOT-fire neighbours
[ -f "$H/tmp/batch-resolve/o_tproj/marker" ] \
  && ok || bad "§8 the batch-resolve clone cache was swept — that buys a re-clone every run"
[ -f "$H/tmp/state-restore/marker" ] \
  && ok || bad "§8 tmp/state-restore (an operator CLI's explicit DEST) was swept"
[ -f "$H/tmp/brfix/loose-file" ] \
  && ok || bad "§8 a plain file under tmp/brfix/ was removed"
[ -L "$H/tmp/brfix/a-symlink" ] && [ -d "$REPO/.git" ] \
  && ok || bad "§8 a symlink under tmp/brfix/ was followed or removed"
[ -d "$H/tmp/brfix" ] \
  && ok || bad "§8 the parent tmp/brfix was itself removed"
[ ! -e "$H/tmp/brfix/brfix-outside" ] \
  && ok || bad "§8 a stale dir whose .git names a repo outside \$REPOS was not removed"
[ -d "$OUTREPO/.git/worktrees/brfix-outside" ] \
  && ok || bad "§8 the sweep ran git against a repo outside \$REPOS — its worktree admin entry is gone"

# ============================================================================
# §9. AN EMPTY tmp IS SILENT (CLAUDE.md: a run that finds nothing exits quietly).
# ============================================================================
mkfix
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "§9 exited $RC ($(tail -5 "$T/run.out"))"
[ "$(grep -c 'disk-clean: ' "$LOG" 2>/dev/null)" -eq 1 ] \
  && ok || bad "§9 expected one summary line, got: $(cat "$LOG")"
summary | grep -q 'tmp_removed=0 tmp_freed_kb=0 tmp_skipped_held=0' \
  && ok || bad "§9 an empty tmp reported work: $(summary)"
grep -q '\[disk-clean\]' <<<"$(grep -v 'disk-clean: ' "$LOG" 2>/dev/null)" \
  && bad "§9 an empty tmp wrote a [disk-clean] line: $(cat "$LOG")" || ok

# ============================================================================
# §10. A KNOB THAT IS NOT A NUMBER says so and falls back to 24 h.
# ============================================================================
mkfix
mkwt brfix-stale tproj-TK-95 "$OLD"
printf 'TMP_SCRATCH_STALE_H=abc\n' > "$H/env/global.env"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "§10 exited $RC ($(tail -5 "$T/run.out"))"
grep -q 'TMP_SCRATCH_STALE_H is not a number - using 24' "$LOG" \
  && ok || bad "§10 a typo'd knob was applied in silence: $(cat "$LOG")"
[ ! -e "$H/tmp/brfix/brfix-stale" ] \
  && ok || bad "§10 the fallback did not behave like the 24 h default: $(summary)"
summary | grep -q 'tmp_removed=1' \
  && ok || bad "§10 the counters are: $(summary)"

# A LONGER WINDOW KEEPS IT. The knob has to be read, not decorative.
mkfix
mkwt brfix-stale tproj-TK-96 "$OLD"
printf 'TMP_SCRATCH_STALE_H=96\n' > "$H/env/global.env"
run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "§10 exited $RC with a 96 h window ($(tail -5 "$T/run.out"))"
[ -d "$H/tmp/brfix/brfix-stale" ] \
  && ok || bad "§10 a 48 h dir was swept under a 96 h window — the knob is not read"
summary | grep -q 'tmp_removed=0 tmp_freed_kb=0 tmp_skipped_held=0' \
  && ok || bad "§10 the 96 h window reported work: $(summary)"

# ============================================================================
# §11. A REMOVAL THAT FAILED IS NOT A REMOVAL. The counter is the work that
#      really happened, so a directory that survived bumps nothing and says so.
# ============================================================================
mkfix
mkwt brfix-stuck tproj-TK-97 "$OLD" 1
run DC_BREAK="$H/tmp/brfix/brfix-stuck"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "§11 exited $RC ($(tail -5 "$T/run.out"))"
[ -d "$H/tmp/brfix/brfix-stuck" ] \
  && ok || bad "§11 the fixture did not actually break the removal — the case proves nothing"
summary | grep -q 'tmp_removed=0 tmp_freed_kb=0 tmp_skipped_held=0' \
  && ok || bad "§11 a removal that failed was counted as freed disk: $(summary)"
grep -q "tmp scratch kept: $H/tmp/brfix/brfix-stuck" "$LOG" \
  && ok || bad "§11 the failed removal is not named in the log: $(cat "$LOG")"

echo "disk-clean-tmp-scratch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
