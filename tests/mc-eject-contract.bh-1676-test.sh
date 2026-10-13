#!/bin/bash
# tests/mc-eject-contract.bh-1676-test.sh — the BH-1669 contract as BH-1676
# ships it: two knobs and two stubs, one of which (pdg_ticket_deps) BH-1678 has
# since implemented.
#
# WHAT THIS PINS. MC_EJECT_REBASE defaults to 1 and an explicit 0 survives the
# source; mc_dequeue_conflict answers "" with rc 0 when its read fails;
# pdg_ticket_enabled is true unless PR_DEP_GATE_TICKET=0; pdg_ticket_deps (no
# longer a stub since BH-1678) prints the issue body's Blocked-by parents. Case
# F pins where the four names are defined: it is the one case that reads source
# text, because that claim IS about source.
# TEST-CHANGE (BH-1677): mc_dequeue_conflict is live now (it reads Mergify's
# comments, pinned by tests/eject-rebase.bh-1677-test.sh), so B2's "no read" no
# longer holds for it by design.
#
# The production entry point is the real one: every case sources
# bin/lib/merge-conductor-lib.sh in a fresh `bash -u`, the way every lane does.
# Run from anywhere: tests/mc-eject-contract.bh-1676-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/flags" "$T/fakebin"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/pr-dep-gate.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
# TEST-CHANGE (BH-1677): the REST read libs ride along, so B1's read is a real
# gh_rest read that FAILS rather than a helper that is simply missing.
for f in gh-budget.sh gh-rest.sh gh-rest-var.sh gh-rest-list.sh; do cp "$DIR/bin/lib/$f" "$T/h/bin/lib/" || exit 1; done

# gh: every call is recorded and answers something a real read would act on, so
# a stub that quietly grew a read shows up in gh.calls rather than passing.
cat > "$T/fakebin/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.calls"
[ -n "\${GHFAIL:-}" ] && { echo "gh: HTTP 403 (fixture)" >&2; exit 1; }  # TEST-CHANGE (BH-1677): an unreadable read
echo '[{"user":{"login":"mergify[bot]"},"body":"## Reason\nThis pull request conflicts with the base branch"}]'
SH
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

RC=0; OUT=""
run_case() {
  local code="$1"; shift
  : > "$T/gh.calls"
  OUT=$(env -u MC_EJECT_REBASE -u PR_DEP_GATE_TICKET HARNESS="$T/h" "$@" bash -u -c \
        ". \"\$HARNESS/bin/lib/merge-conductor-lib.sh\"; $code" 2>"$T/stderr")
  RC=$?
}
calls() { wc -l < "$T/gh.calls" | tr -d ' '; }

# ══ A1. MC_EJECT_REBASE defaults to 1 ═══════════════════════════════════════
run_case 'printf %s "$MC_EJECT_REBASE"'
[ "$RC" = 0 ] && [ "$OUT" = 1 ] && ok || bad "A1: MC_EJECT_REBASE default must be 1 (rc=$RC out=[$OUT])"

# ══ A2. an explicit MC_EJECT_REBASE=0 survives the source ═══════════════════
run_case 'printf %s "$MC_EJECT_REBASE"' MC_EJECT_REBASE=0
[ "$RC" = 0 ] && [ "$OUT" = 0 ] && ok || bad "A2: MC_EJECT_REBASE=0 must survive sourcing (rc=$RC out=[$OUT])"

# ══ B1. an unreadable read: mc_dequeue_conflict answers "" rc 0 ═════════════
# TEST-CHANGE (BH-1677): the stub gh FAILS, so this is the D11 rule (a read that
# could not answer is never a base conflict) rather than the stub's inertness.
run_case 'printf "[%s]" "$(mc_dequeue_conflict o/r https://github.com/o/r/pull/5 deadbeef)"; mc_dequeue_conflict o/r https://github.com/o/r/pull/5 deadbeef >/dev/null' GHFAIL=1
[ "$RC" = 0 ] && [ "$OUT" = "[]" ] && ok || bad "B1: an unreadable read must print nothing with rc 0 (rc=$RC out=[$OUT] err=$(head -c 300 "$T/stderr"))"

# ══ B2. ...the read was attempted, and it is defined by mc/queue.sh ═════════
# TEST-CHANGE (BH-1677): was "zero gh calls" — the function reads now, so the
# assertion is that the failed answer above came from a real attempt.
[ "$(calls)" -ge 1 ] && ok || bad "B2: mc_dequeue_conflict must attempt its comments read (calls=$(calls))"
run_case 'shopt -s extdebug; declare -F mc_dequeue_conflict'
case "$OUT" in
  "mc_dequeue_conflict "*" $T/h/bin/lib/mc/queue.sh") ok ;;
  *) bad "B2: mc_dequeue_conflict must be defined by bin/lib/mc/queue.sh (rc=$RC out=[$OUT])" ;;
esac

# ══ C1-C3. pdg_ticket_enabled ═══════════════════════════════════════════════
run_case 'pdg_ticket_enabled'
[ "$RC" = 0 ] && ok || bad "C1: pdg_ticket_enabled must be rc 0 with PR_DEP_GATE_TICKET unset (rc=$RC)"
run_case 'pdg_ticket_enabled' PR_DEP_GATE_TICKET=1
[ "$RC" = 0 ] && ok || bad "C2: pdg_ticket_enabled must be rc 0 with PR_DEP_GATE_TICKET=1 (rc=$RC)"
run_case 'pdg_ticket_enabled' PR_DEP_GATE_TICKET=0
[ "$RC" = 1 ] && ok || bad "C3: pdg_ticket_enabled must be rc 1 with PR_DEP_GATE_TICKET=0 (rc=$RC)"

# ══ C4. pdg_ticket_deps reads the issue body (BH-1678 implemented the stub) ═
# The issue body is faked by a gh function in the case's own shell: one REST
# read of repos/o/r/issues/12, and the Blocked-by parent printed with rc 0.
# TEST-CHANGE (BH-1677 x BH-1678): BH-1677's fixture copies the REST read libs,
# so pdg_ticket_deps takes its gh_rest_var path (`api -i`, status + headers +
# JSON) rather than the raw `gh api -q .body` fallback; the fake answers both.
run_case 'gh() { printf "%s\n" "$*" >> "'"$T"'/gh.calls"
            case "$*" in
              "api -i "*) printf "HTTP/1.1 200 OK\r\nX-RateLimit-Remaining: 4000\r\nX-RateLimit-Limit: 5000\r\nX-RateLimit-Resource: core\r\n\r\n"
                          printf "%s" "{\"body\":\"Part of #1\\nBlocked-by: #7 (hard)\\n\"}" ;;
              *) printf "Part of #1\nBlocked-by: #7 (hard)\n" ;;
            esac; }
          pdg_ticket_deps o/r 12'
[ "$RC" = 0 ] && [ "$OUT" = 7 ] && [ "$(calls)" = 1 ] && grep -q 'repos/o/r/issues/12' "$T/gh.calls" && ok \
  || bad "C4: pdg_ticket_deps must print the Blocked-by parent 7, rc 0, one issue read (rc=$RC out=[$OUT] calls=$(cat "$T/gh.calls") err=$(head -c 300 "$T/stderr"))"

# ══ F1. each name is defined exactly once, where the contract put it ═══════
# Exactly one definition line per name, in its own file, and no second
# definition anywhere under bin/. A missing definition fails this as surely as
# a duplicate does, so it cannot pass on an empty grep.
# TEST-CHANGE (BH-1677 x BH-1678): this case used to pin "nothing calls them
# yet". BH-1678 gave the pdg_ticket_* pair callers (pdg_hold) and BH-1677 gave
# MC_EJECT_REBASE and mc_dequeue_conflict theirs (mc/queue.sh, mc/rebase.sh), so
# no name is inert any more; both children kept the definition-location pin,
# which is what stays here. Their callers are pinned by
# tests/pr-dep-gate-order.bh-1678-test.sh and tests/eject-rebase.bh-1677-test.sh.
hits=$(cd "$DIR" && grep -rnE '^[[:space:]]*(MC_EJECT_REBASE=|mc_dequeue_conflict\(\)|pdg_ticket_deps\(\)|pdg_ticket_enabled\(\))' bin/ --include='*.sh')
want_files="bin/lib/mc/log.sh:MC_EJECT_REBASE=
bin/lib/mc/queue.sh:mc_dequeue_conflict()
bin/lib/pr-dep-gate.sh:pdg_ticket_deps()
bin/lib/pr-dep-gate.sh:pdg_ticket_enabled()"
got=$(printf '%s\n' "$hits" | sed -nE 's#^([^:]+):[0-9]+:[[:space:]]*(MC_EJECT_REBASE=|mc_dequeue_conflict\(\)|pdg_ticket_deps\(\)|pdg_ticket_enabled\(\)).*#\1:\2#p' | sort)
n=$(printf '%s\n' "$hits" | grep -c .)
[ "$got" = "$want_files" ] && [ "$n" = 4 ] && ok || bad "F1: expected exactly the four definition lines under bin/, got:
$hits"

echo "mc-eject-contract.bh-1676: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
