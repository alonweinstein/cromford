#!/bin/bash
# tests/lib-root-plan-queue.bh-2613-test.sh — BH-2651 (BH-2613.3): the preplan,
# prebuild-repro, ready-queue and merge-adjacent libs resolve their root as
# HARNESS, then H (MC_H and a positional root keep their place ahead of both),
# and never fall back to a literal /root/harness
# (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md, rules 1-6).
#
# Every "no root" case runs in a fresh `bash -c 'set -eu; …'` under `env -i`
# (so no HARNESS, H, MC_H, JOBS_*, HARNESS_ENV_DIR or token var reaches it, and
# lane-gate's settings refresh has no credentials to call out with), under
# xtrace, from an empty cwd. It asserts the answer, the rc, that nothing was
# written (the scratch roots, the cwd and the filesystem root are listed before
# and after) and that the trace names /root/harness zero times and builds no
# path from an empty root. As root those children drop to nobody, so a lib that
# still reaches the literal cannot write into a live harness on this box.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd -P)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The ten libs this child converts, by rooted path.
LIBS=(
  "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/prebuild-repro.sh"
  "$DIR/bin/lib/prebuild-repro/drive.sh" "$DIR/bin/lib/prebuild-repro/stop.sh"
  "$DIR/bin/lib/ready-queue.sh" "$DIR/bin/lib/orc-account.sh"
  "$DIR/bin/lib/rt/scope.sh" "$DIR/bin/lib/mc/rebase.sh"
  "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/revdep-lib.sh"
)
for f in "${LIBS[@]}"; do [ -r "$f" ] || bad "missing $f"; done

# A private copy of bin/ the unprivileged child can read wherever the checkout
# lives. The libs are sourced from here, so their sibling sources resolve too.
# NQ is a second copy with no ready-queue.sh, for rt/scope's fallbacks.
NB="$T/nb"; L="$NB/bin/lib"; NQ="$T/nq"
mkdir -p "$NB/cwd" "$NB/io/bin" "$NB/io/tmp" "$NB/io/b" "$NB/sr/state" "$NB/sr/env" "$NB/sr/flags" \
         "$NB/sr/logs" "$NB/sr/bin" "$NB/sr2"
cp -r "$DIR/bin" "$NB/bin"
mkdir -p "$NQ"; cp -r "$DIR/bin" "$NQ/bin"; rm -f "$NQ/bin/lib/ready-queue.sh"
SR="$NB/sr"        # the scratch root, for the HARNESS-only and H-only runs
E="$NB/sr2"        # an EMPTY root: today's "unreadable state dir" answer
# curl and gh stubs: every call is counted, none reaches a network.
for c in curl gh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s/io/calls"\nexit 1\n' "$c" "$NB" > "$NB/io/bin/$c"
done
chmod 755 "$NB/io/bin/"*; : > "$NB/io/calls"
unpriv() { "$@"; }
if [ "$(id -u)" = 0 ]; then
  if command -v setpriv >/dev/null 2>&1; then
    unpriv() { setpriv --reuid=65534 --regid=65534 --clear-groups -- "$@"; }
  else
    echo "SKIP: root without setpriv cannot drop to nobody, and a no-root run as root could write a live harness"
    exit 0
  fi
  chmod o+x "$T"; chmod -R a+rX "$NB" "$NQ"
  chmod 777 "$NB/cwd" "$NB/io" "$NB/io/tmp" "$NB/io/b" "$SR" "$SR/state" "$SR/flags" "$SR/logs" "$E"
  chmod 666 "$NB/io/calls"
fi

# snap — every path a no-root write could land on: the scratch roots, the
# cwd, and the filesystem root's would-be strays.
snap() {
  find "$SR" "$E" "$NB/cwd" -mindepth 1 2>/dev/null | sort
  local p; for p in /state /flags /logs /env /builds /locks; do [ -e "$p" ] && echo "STRAY $p"; done
  return 0
}

# child <pre> <script> — one isolated bash: env -i, nobody, empty cwd, set -eu.
child() {
  unpriv env -i PATH="$NB/io/bin:/usr/local/bin:/usr/bin:/bin" HOME="$NB/cwd" TMPDIR="$NB/io/tmp" \
    LANG=C PS4='+ ' bash -c "cd '$NB/cwd' || exit 98; set -eu; $1; set -x; $2"
}
# nr <name> <script> — a no-root run. OUT, RC, and $NB/<name>.trace.
PATHRE="(^|[ '\"=])/(state|flags|logs|env|builds|locks|plans|bin)(/|\$|[ '\"])"
nr() {
  local name="$1" script="$2" before after n
  before=$(snap)
  OUT=$(child : "$script" 2>"$NB/$name.trace"); RC=$?
  after=$(snap)
  [ "$before" = "$after" ] || bad "$name wrote with no root: $(diff <(echo "$before") <(echo "$after") | grep '^[<>]' | head -5 | tr '\n' ' ')"
  n=$(grep -c '/root/harness' "$NB/$name.trace")
  [ "$n" = 0 ] && ok || bad "$name: xtrace names /root/harness $n time(s): $(grep -m2 '/root/harness' "$NB/$name.trace" | tr '\n' ' ')"
  # A path built from an empty root (`/state/…`, `/logs/…`) is as bad as the
  # literal, even where / is not writable and nothing lands.
  n=$(grep -cE "$PATHRE" "$NB/$name.trace")
  [ "$n" = 0 ] && ok || bad "$name: xtrace builds a path from an empty root $n time(s): $(grep -m2 -E "$PATHRE" "$NB/$name.trace" | tr '\n' ' ')"
}
# rr <name> <prefix-assignments> <script> — a run WITH a root, same isolation.
rr() { OUT=$(child "$2" "$3" 2>"$NB/$1.trace"); RC=$?; }
eq() { [ "$1" = "$2" ] && ok || bad "$3: want [$2] got [$1] rc=$RC"; }

# ---------------------------------------------------------------- preplan-lib
PP=". '$L/preplan-lib.sh'"
PPQ='echo "$(preplan_speculative) $(preplan_ahead) $(preplan_parallel) $(overlap_schedule) $(preplan_cost_rows) $(preplan_max_attempts) $(preplan_stale_max) $(preplan_skip_small_on) $(preplan_ahead_ready) [$(preplan_midbuild_keys "" p)] $(preplan_replan_fp "" BH-1)"; rc=0; preplan_billed "" 75 0 || rc=$?; echo billed=$rc'
nr pp-none "$PP; printf '[%s]\n' \"\$(_preplan_root)\"; $PPQ"
NOROOT="$RC:$OUT"
FP=$(printf '%s' "no-queue-line/BH-1" | sha256sum | tr -dc '0-9a-f' | cut -c1-16)
eq "$NOROOT" "0:[]
1 2 3 1 0 3 2 1 10 [] $FP
billed=1" "preplan no root: every knob its default, no mid-build keys, no queue line, not billed"
rr pp-empty "export HARNESS='$E'" "$PP; printf '[]\n'; $PPQ"
eq "$RC:$OUT" "$NOROOT" "preplan no root answers exactly what an empty root answers"
printf 'PREPLAN_AHEAD=5\nPREPLAN_STALE_MAX=4\n' > "$SR/env/global.env"; chmod 644 "$SR/env/global.env"
printf 'BH-1 7 — ready project=p\n' > "$SR/logs/READY-QUEUE.log"; chmod 644 "$SR/logs/READY-QUEUE.log"
rr pp-harness "export HARNESS='$SR'" "$PP; echo \"\$(_preplan_root) \$(preplan_ahead) \$(preplan_stale_max)\""
eq "$OUT" "$SR 5 4" "preplan HARNESS only reads the scratch root"
rr pp-h "H='$SR'" "$PP; echo \"\$(_preplan_root) \$(preplan_ahead) \$(preplan_stale_max)\"; [ \"\$(preplan_replan_fp '' BH-1)\" != '$FP' ] && echo fp-from-root"
eq "$OUT" "$SR 5 4
fp-from-root" "preplan H only reads the scratch root (knobs and queue line)"
rr pp-pos "export HARNESS='$E'" "$PP; preplan_ahead '$SR'"
eq "$OUT" "5" "preplan positional root beats HARNESS"

# -------------------------------------------------- prebuild-repro (+ drive, stop)
# bin/lib/harness-self.sh (sourced by prebuild-repro.sh at load) resolves its
# allowlist through bin/lib/lane-gate.sh, which is #2649's slice and still has
# its own /root/harness default. Its seam (`command -v lib_env_apply`) is
# stubbed here so the trace judges THESE libs, not that one.
PR="lib_env_apply() { :; }; _lg_registry() { :; }; . '$L/prebuild-repro.sh'"
B="$NB/io/b"
nr prr-none "$PR; printf '[%s]\n' \"\$(_prs_root)\"; pr_record '$B' p BH-1 skip why ev; echo rec=\$?; _prs_log p '$B' line; echo log=\$?; rc=0; _prs_posted p 12 BH-1 m - || rc=\$?; echo posted=\$rc"
eq "$RC:$OUT" "0:[]
rec=0
log=0
posted=1" "prebuild-repro no root: pr_record and _prs_log rc 0 under set -eu, _prs_posted says not posted"
grep -q 'REPRO_GATE: skip' "$B/prebuild-repro.txt" 2>/dev/null && ok || bad "pr_record no root still writes the build dir it was handed"
rm -f "$B/prebuild-repro.txt" "$B/pipeline.log"
rr prr-harness "export HARNESS='$SR'" "$PR; pr_record '$B' p BH-1 skip why ev"
grep -q 'repro=skip reason=why key=BH-1' "$SR/logs/p.log" 2>/dev/null && ok || bad "pr_record HARNESS only logs under the scratch root"
rm -f "$SR/logs/p.log"
rr prr-h "H='$SR'" "$PR; pr_record '$B' p BH-1 skip why ev"
grep -q 'repro=skip reason=why key=BH-1' "$SR/logs/p.log" 2>/dev/null && ok || bad "pr_record H only logs under the scratch root"
rm -f "$SR/logs/p.log" "$B/prebuild-repro.txt" "$B/pipeline.log"
# pr_drive: no root is the no-prod-url answer, before any spend.
nr drv-none "$PR; pr_drive p BH-1 '$B' '{}'"
eq "$RC:$OUT" "0:CANNOT_DRIVE	no-prod-url" "pr_drive no root: CANNOT_DRIVE no-prod-url"
printf '#!/bin/bash\necho "$*" >> "%s/io/prod-url"\necho -\n' "$NB" > "$SR/bin/prod-url.sh"; chmod 755 "$SR/bin/prod-url.sh"
: > "$NB/io/prod-url"; chmod 666 "$NB/io/prod-url"
rr drv-h "H='$SR'" "$PR; pr_drive p BH-1 '$B' '{}'"
eq "$OUT:$(cat "$NB/io/prod-url")" "CANNOT_DRIVE	no-prod-url:p" "pr_drive H only asks the scratch root's prod-url.sh (the local H reads the caller's)"
rm -f "$SR/bin/prod-url.sh"
# pr_stop: no root sends what an empty root sends, and stamps nothing.
: > "$NB/io/calls"
nr stop-none "$PR; rc=0; pr_stop p 12 BH-1 '$B' '{\"comments\":[]}' NOT_REPRODUCED || rc=\$?; echo rc=\$rc"
NOROOT="$RC:$OUT:$(wc -l < "$NB/io/calls")"
eq "$NOROOT" "0:rc=0:0" "pr_stop no root: rc 0, nothing sent"
rr stop-empty "export HARNESS='$E'" "$PR; rc=0; pr_stop p 12 BH-1 '$B' '{\"comments\":[]}' NOT_REPRODUCED || rc=\$?; echo rc=\$rc"
eq "$RC:$OUT:$(wc -l < "$NB/io/calls")" "$NOROOT" "pr_stop no root sends exactly what an empty root sends"
[ -z "$(ls -A "$B")" ] && ok || bad "pr_stop no root stamped the build dir: $(ls -A "$B" | tr '\n' ' ')"
printf '#!/bin/bash\necho "$*" >> "%s/io/jobs"\nexit 3\n' "$NB" > "$SR/bin/jobs-client.sh"; chmod 755 "$SR/bin/jobs-client.sh"
: > "$NB/io/jobs"; chmod 666 "$NB/io/jobs"
rr stop-h "H='$SR'" "$PR; rc=0; pr_stop p 12 BH-1 '$B' '{\"comments\":[]}' NOT_REPRODUCED || rc=\$?; echo rc=\$rc"
grep -q '^ledger-get repro_gate ' "$NB/io/jobs" && ok || bad "pr_stop H only reads the scratch root's ledger client: $(cat "$NB/io/jobs")"
rm -f "$SR/bin/jobs-client.sh"

# ---------------------------------------------------------------- ready-queue
RQ=". '$L/ready-queue.sh'"
RQQ='Q=$(rq_lines); any=0; rq_any || any=1; fp=$(rq_fp); rq_log "" msg; rq_put "" p BH-1; rq_drop "" p BH-1; echo "Q=[$Q] any=$any fp=[$fp]"'
: > "$NB/io/calls"
nr rq-none "$RQ; printf '[%s][%s]\n' \"\$(rq_root)\" \"\$(rq_file)\"; $RQQ"
eq "$RC:$OUT" "0:[][]
Q=[] any=1 fp=[]" "ready-queue no root: no file, nothing queued, no fingerprint, writers rc 0"
rr rq-empty "export HARNESS='$E'" "$RQ; printf '[][]\n'; $RQQ"
eq "$RC:$OUT" "0:[][]
Q=[] any=1 fp=[]" "ready-queue no root offers exactly what an empty (unreadable) root offers"
eq "$(wc -l < "$NB/io/calls")" "0" "ready-queue no root: no request made"
rr rq-h "H='$SR'" "$RQ; rq_lines; rq_log '' hello"
eq "$OUT" "BH-1 7 — ready project=p" "ready-queue H only reads the scratch root's queue"
grep -q 'hello' "$SR/logs/ready-queue.log" 2>/dev/null && ok || bad "rq_log H only writes the scratch root's log"
rm -f "$SR/logs/ready-queue.log"
rr rq-harness "export HARNESS='$SR'" "$RQ; rq_any && echo any"
eq "$OUT" "any" "ready-queue HARNESS only reads the scratch root's queue"
rr rq-pos "export HARNESS='$E'" "$RQ; rq_file '$SR'"
eq "$OUT" "$SR/logs/READY-QUEUE.log" "rq_file positional root beats HARNESS"

# ---------------------------------------------------------------- rt/scope
nr rts-none ". '$L/rt/scope.sh'; command -v rq_root; printf '[%s]\n' \"\$(rq_lines)\""
eq "$RC:$OUT" "0:rq_root
[]" "rt/scope no root: sibling ready-queue loaded, nothing queued"
nr rts-stub ". '$NQ/bin/lib/rt/scope.sh'; command -v rq_root || echo no-rq; printf '[%s]\n' \"\$(rq_lines)\"; echo rc=\$?"
eq "$RC:$OUT" "0:no-rq
[]
rc=0" "rt/scope no root, no ready-queue lib: the rq_lines stub answers empty, rc 0"
rr rts-h "H='$NB'" ". '$NQ/bin/lib/rt/scope.sh'; command -v rq_root"
eq "$OUT" "rq_root" "rt/scope H only loads ready-queue.sh from the root"
rr rts-harness "export HARNESS='$NB'" ". '$NQ/bin/lib/rt/scope.sh'; command -v rq_root"
eq "$OUT" "rq_root" "rt/scope HARNESS only loads ready-queue.sh from the root"
rr rts-stub-h "H='$SR'" ". '$NQ/bin/lib/rt/scope.sh'; rq_lines"
eq "$OUT" "BH-1 7 — ready project=p" "rt/scope rq_lines stub, H only, reads the scratch root's queue"

# ---------------------------------------------------------------- orc-account
OA=". '$L/orc-account.sh'"
# fcd_put is fleet-cooldown's send (its client, bin/lib/jobs/req.sh, is #2649's
# slice): stubbed to count, because rule 6 says the fleet row is still sent.
: > "$NB/io/fcd"; chmod 666 "$NB/io/fcd"
nr orc-none "$OA; fcd_put() { echo \"\$*\" >> '$NB/io/fcd'; }; printf '[%s]\n' \"\$(_orc_root)\"; ACCOUNT_ROUTING=1; orc_pick_account m; echo \$ORC_ACCOUNT \$ORC_ACCOUNT_REASON; orc_pin_clear; orc_account_refuse acct; echo survived"
eq "$RC:$OUT" "0:[]
default no-picker
survived" "orc-account no root: no picker, pin clear and refuse rc 0, nothing written"
eq "$(cut -d' ' -f1-3 "$NB/io/fcd")" "account claude acct" "orc_account_refuse no root still sends the fleet cooldown row, with no stamp"
mkdir -p "$SR/env/tokens.d" "$SR/state/quota/pins"
printf '#!/bin/bash\nprintf "name=max2\\nreason=headroom\\n"\n' > "$SR/bin/account-pick.sh"; chmod 755 "$SR/bin/account-pick.sh"
printf 'CLAUDE_CODE_OAUTH_TOKEN=tok2\n' > "$SR/env/tokens.d/max2-setup-token.env"
: > "$SR/state/quota/pins/orchestrator"
chmod -R a+rwX "$SR/env" "$SR/state"
rr orc-h "H='$SR'" "$OA; ACCOUNT_ROUTING=1 LANE_GATE_DISABLE=1; orc_pick_account m; echo \$ORC_ACCOUNT \$ORC_TOKEN \$ORC_ACCOUNT_REASON; orc_account_refuse max2"
eq "$OUT" "max2 tok2 headroom" "orc-account H only picks through the scratch root"
[ -s "$SR/state/quota/cooldown/claude/max2" ] && ok || bad "orc_account_refuse H only stamps the scratch root's cooldown"
[ ! -e "$SR/state/quota/pins/orchestrator" ] && ok || bad "orc_pin_clear H only removes the scratch root's pin"
rr orc-harness "export HARNESS='$SR'" "$OA; ACCOUNT_ROUTING=1 LANE_GATE_DISABLE=1; orc_pick_account m; echo \$ORC_ACCOUNT"
eq "$OUT" "max2" "orc-account HARNESS only picks through the scratch root"
: > "$SR/flags/orc-account-routing-off"; chmod 644 "$SR/flags/orc-account-routing-off"
rr orc-off "H='$SR'" "$OA; ACCOUNT_ROUTING=1 LANE_GATE_DISABLE=1; orc_pick_account m; echo \$ORC_ACCOUNT_REASON"
eq "$OUT" "orc-routing-off" "orc-account H only reads the scratch root's kill switch"
scratch_rm "$SR/state/quota"; rm -f "$SR/flags/orc-account-routing-off" "$SR/bin/account-pick.sh"; scratch_rm "$SR/env/tokens.d"
# Rule 3, run directly: HARNESS/H unset resolves the lib's own install root,
# through `pwd -P`, so a symlinked checkout names the real tree. The sibling
# fleet-cooldown.sh is removed from the copy so the root-built candidate runs.
OC="$T/oc"; mkdir -p "$OC"; cp -r "$DIR/bin" "$OC/bin"; rm -f "$OC/bin/lib/fleet-cooldown.sh"
ln -s "$OC" "$T/oclink"; chmod -R a+rX "$OC"
unpriv env -i PATH="/usr/bin:/bin" HOME="$NB/cwd" PS4='+ ' bash -x "$T/oclink/bin/lib/orc-account.sh" >/dev/null 2>"$NB/orc-direct.trace"; RC=$?
eq "$RC" "0" "orc-account.sh run directly exits 0"
grep -qF "$OC/bin/lib/fleet-cooldown.sh" "$NB/orc-direct.trace" && ok || bad "orc-account.sh run directly does not resolve its own install root $OC: $(grep -m3 fleet-cooldown "$NB/orc-direct.trace" | tr '\n' ' ')"
eq "$(grep -c '/root/harness' "$NB/orc-direct.trace")" "0" "orc-account.sh run directly: xtrace names no /root/harness"

# ---------------------------------------------------------------- mc/rebase
# bin/lib/mc/log.sh is outside this slice and still sets MC_H to its own
# default. It is loaded against a throwaway root (the prefix HARNESS is scoped
# to the source), and MC_H is then put back to whatever the case set, so
# rebase.sh's own chain is what is judged. Empty MC_H is the no-root case.
mkdir -p "$NB/io/mclog"; chmod 777 "$NB/io/mclog"
MR="_mh=\"\${MC_H:-}\"; HARNESS='$NB/io/mclog' . '$L/mc/log.sh'; MC_H=\"\$_mh\"; . '$L/mc/rebase.sh'"
nr mc-none "$MR; printf '[%s]\n' \"\$(_mc_root)\"; rc=0; mc_hold_keeps_pr o/r 5 || rc=\$?; echo hold=\$rc; command -v hold_check || echo no-hold; rc=0; mc_git_auth o/r || rc=\$?; echo auth=\$rc"
eq "$RC:$OUT" "0:[]
hold=1
no-hold
auth=1" "mc/rebase no root: hold lib not loaded (not held), the gh-token rung skipped, no token"
rr mc-mch "export MC_H='$E' HARNESS='$SR'" "$MR; _mc_root"
eq "$OUT" "$E" "mc/rebase MC_H stays ahead of HARNESS"
rr mc-harness "export HARNESS='$SR'" "$MR; _mc_root"
eq "$OUT" "$SR" "mc/rebase HARNESS only"
printf '#!/bin/bash\necho "$*" >> "%s/io/ghtok"\necho tok-from-root\n' "$NB" > "$SR/bin/gh-token.sh"; chmod 755 "$SR/bin/gh-token.sh"
: > "$NB/io/ghtok"; chmod 666 "$NB/io/ghtok"
# GIT_ALLOW_PROTOCOL=file: the ls-remote probe is refused locally, never sent.
rr mc-h "H='$SR'; export GIT_ALLOW_PROTOCOL=file" "$MR; _mc_root; mc_git_auth o/r || true; rm -f \"\$MC_ASKPASS\""
eq "$RC:$OUT:$(cat "$NB/io/ghtok")" "0:$SR:--min-life 600 o/r" "mc/rebase H only: mc_git_auth asks the scratch root's gh-token.sh"
: > "$NB/io/ghtok"
rr mc-none-tok "export GIT_ALLOW_PROTOCOL=file" "$MR; mc_git_auth o/r || echo refused"
eq "$OUT:$(cat "$NB/io/ghtok")" "refused:" "mc/rebase no root never runs a gh-token.sh"
rm -f "$SR/bin/gh-token.sh"

# ---------------------------------------------------------------- dep-verify-lib
DV=". '$L/dep-verify-lib.sh'"
# The adversarial plant: a SOFT verdict where a path built from an empty root
# would find it (relative to the cwd).
mkdir -p "$NB/cwd/state/dep-verify/fx"; echo SOFT > "$NB/cwd/state/dep-verify/fx/C-B"; chmod -R a+rwX "$NB/cwd/state"
DVQ='echo "$(dep_verify_on) $(dep_verify_dry) $(dep_unknown_mode)"'
nr dep-none "$DV; printf '[%s]\n' \"\$(_dep_root)\"; $DVQ; F=\$(cat \"\$(dep_cache_file '' fx C B)\" 2>/dev/null || true); echo \"F=[\$F] D=[\$(dep_cache_dir '' fx)]\""
eq "$RC:$OUT" "0:[]
1 0 soft
F=[] D=[]" "dep-verify no root: on, not dry, soft, and no cached verdict is reachable"
rr dep-empty "export HARNESS='$E'" "$DV; $DVQ"
eq "$OUT" "1 0 soft" "dep-verify no root answers exactly what an empty root answers"
printf 'DEP_UNKNOWN_MODE=hard\nDEP_VERIFY_DRY_RUN=1\n' > "$SR/env/global.env"
: > "$SR/flags/dep-verify-off"; chmod 644 "$SR/flags/dep-verify-off"
rr dep-h "H='$SR'" "$DV; LANE_GATE_DISABLE=1; $DVQ"
eq "$OUT" "0 1 hard" "dep-verify H only reads the scratch root (switch and knobs)"
rr dep-harness "export HARNESS='$SR'" "$DV; LANE_GATE_DISABLE=1; $DVQ; dep_cache_file '$SR' fx C B"
eq "$OUT" "0 1 hard
$SR/state/dep-verify/fx/C-B" "dep-verify HARNESS only reads the scratch root"
rm -f "$SR/flags/dep-verify-off"

# ---------------------------------------------------------------- revdep-lib
RV=". '$L/revdep-lib.sh'"
echo 12 > "$NB/cwd/state/wake-closed-p"; chmod 666 "$NB/cwd/state/wake-closed-p"
nr revdep-none "$RV; printf '[%s]\n' \"\$(_revdep_root)\"; echo \"\$(revdep_on) [\$(revdep_closed_file '' p)]\"; note=0; revdep_note_closed '' p 12 || note=\$?; take=0; t=\$(revdep_take_closed '' p) || take=\$?; echo \"note=\$note take=\$take [\$t]\"; command -v gh_auth_for || echo no-auth"
eq "$RC:$OUT" "0:[]
1 []
note=1 take=1 []
no-auth" "revdep no root: expansion on, no closure file, nothing recorded or taken, gh-app-auth not loaded"
[ -s "$NB/cwd/state/wake-closed-p" ] && ok || bad "revdep no root consumed a cwd-relative closure file"
rr revdep-root "H='$SR'" "$RV; revdep_note_closed '$SR' p 12 && echo \"take=[\$(revdep_take_closed '$SR' p)]\"; echo \$(revdep_on)"
eq "$OUT" "take=[12]
1" "revdep with a root: a noted closure is taken once, and H only reads the scratch root's (absent) kill flag"
: > "$SR/flags/revdep-wake-off"; chmod 644 "$SR/flags/revdep-wake-off"
rr revdep-h "H='$SR'" "$RV; revdep_on"
eq "$OUT" "0" "revdep H only reads the scratch root's kill flag"
rr revdep-harness "export HARNESS='$SR'" "$RV; revdep_on"
eq "$OUT" "0" "revdep HARNESS only reads the scratch root's kill flag"
rm -f "$SR/flags/revdep-wake-off"

# ---------------------------------------- D2: bin/queue-line-drop.sh as shipped
# A scratch HARNESS: the entry point consumes the line through ready-queue.sh's
# own root resolution and the pass touches no /root/harness path.
# harden-state.sh is left out of the copy: it would chattr +a the scratch file.
QH="$T/qh"; mkdir -p "$QH/logs"; cp -r "$DIR/bin" "$QH/bin"; rm -f "$QH/bin/harden-state.sh"
printf 'BH-1 7 — ready project=p\nBH-2 8 — ready project=p\n' > "$QH/logs/READY-QUEUE.log"
( env -i PATH="/usr/bin:/bin" HOME="$T" HARNESS="$QH" PS4='+ ' bash -x "$QH/bin/queue-line-drop.sh" BH-1 ) >/dev/null 2>"$T/qld.trace"; RC=$?
eq "$RC:$(cat "$QH/logs/READY-QUEUE.log")" "0:BH-2 8 — ready project=p" "D2 queue-line-drop.sh drops the line under a scratch HARNESS"
eq "$(grep -c '/root/harness' "$T/qld.trace")" "0" "D2 queue-line-drop.sh pass touches no /root/harness path"

echo "lib-root-plan-queue.bh-2613: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
