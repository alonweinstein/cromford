#!/bin/bash
# tests/conductor-claimed-page.bh-3630-test.sh — BH-3630: a BLOCKED_HUMAN park
# bin/blocked-resolver.sh has CLAIMED pages once when parked, once more when it
# is still parked MC_CLAIMED_REPAGE_S later with no resolver rung in that span,
# and is silent otherwise. An unclaimed park pages exactly as before.
#
# WHAT HAPPENED (2026-09-30). example-org/project-7#530 paged CRITICAL about every
# 30 minutes for days (`5370m in BLOCKED_HUMAN: provenance (verdict=APPROVE
# ci=red …)`). The claim file, not the row's `alerted` column, is the ledger for
# a claimed park, so C4 resets `alerted` before every call and still wants ONE page.
#
# THE ACCEPTANCE ROWS (plan C1-C6):
#   C1  mc_prov_detail_put writes/removes the detail; mc_resolver_claim keeps its
#       stamps on the same head and starts fresh on a new head.
#   C2  first page of a claimed park: exactly one critical page, paged_at stamped.
#   C3  a day of 30-minute ticks with the resolver working: no further page.
#   C4  the same with `alerted` reset to `-` every tick: still no further page.
#   C5  no resolver rung for MC_CLAIMED_REPAGE_S: exactly one more page, then none.
#   C6  unclaimed: the daily page as before; mc_stuck_check pages an unclaimed
#       park and folds a claimed-and-paged one (marker, no alert, rc 0).
#
# Drives the REAL bin/lib/merge-conductor-lib.sh.
#   bash tests/conductor-claimed-page.bh-3630-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_mc_harness "$DIR" "$T" || exit 1
export HARNESS="$T/h"
[ -f "$DIR/bin/lib/mc/classify.sh" ] || exit 1   # impact: the claim helpers and mc_stuck_check
[ -f "$DIR/bin/lib/mc/log.sh" ] || exit 1        # impact: mc_budget_check's claimed arm
# lane-alert.sh IS the page boundary: what it receives is the assertion.
cat > "$HARNESS/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.txt"
STUB
chmod +x "$HARNESS/bin/lane-alert.sh"
: > "$T/alerts.txt"

# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh"
mc_init

# THE CLOCK. mc_now is the lib's one clock read; the day mark is a `date -u
# +%Y%m%d`, answered from the same pinned clock so "day 2" is a fact of the test.
CLK="$NOW"
mc_now() { printf '%s\n' "$CLK"; }
date() {
  if [ "$*" = "-u +%Y%m%d" ]; then command date -u -d "@$CLK" +%Y%m%d; else command date "$@"; fi
}

KEY="example-org/tproj#530"
URL="https://github.com/example-org/tproj/pull/530"
HEADX=061efaf4061efaf4061efaf4061efaf4061efaf4
DETAILTXT="provenance (verdict=APPROVE ci=red mergeState=UNSTABLE mode=merge)"
CLAIMF="$MC_STATE_DIR/resolver-claim/example-org_tproj_530"
PAGES() { grep -c "conductor: $KEY BLOCKED_HUMAN" "$T/alerts.txt" 2>/dev/null || true; }
SEED() { # SEED <since> [alerted] — the conductor's row for the park
  mc_row_put "$KEY" BLOCKED_HUMAN "$1" "$HEADX" "$HEADX" "${2:--}" provenance "$URL"
}
RESET() {
  : > "$T/alerts.txt"; : > "$MC_LOG"; : > "$MC_ROWS"
  scratch_rm "$MC_STATE_DIR/resolver-claim"
  scratch_rm "$MC_STATE_DIR/prov-detail"
  scratch_rm "$MC_STUCK_DIR"
  CLK="$NOW"
}
TICK() { mc_budget_check "$KEY" BLOCKED_HUMAN "$SINCE" "$URL" "$DETAILTXT"; }

# ============================================================================
# C1 — the detail and the claim store.
# ============================================================================
RESET
mc_prov_detail_put "$KEY" BLOCKED_HUMAN provenance "$HEADX" APPROVE red
DF="$MC_STATE_DIR/prov-detail/example-org_tproj_530"
[ "$(cut -f1-3 "$DF" 2>/dev/null)" = "$HEADX	APPROVE	red" ] && ok || bad "C1: BLOCKED_HUMAN+provenance must write head/verdict/ci (got: $(cat "$DF" 2>/dev/null))"
[ "$(mc_prov_detail_get "$KEY" | cut -f1-3)" = "$HEADX	APPROVE	red" ] && ok || bad "C1: mc_prov_detail_get reads it back"
mc_prov_detail_put "$KEY" BLOCKED_HUMAN review-block "$HEADX" APPROVE red
[ -e "$DF" ] && bad "C1: another reason must remove the detail" || ok
mc_prov_detail_get "$KEY" >/dev/null && bad "C1: mc_prov_detail_get answers rc 1 when absent" || ok
mc_prov_detail_put "$KEY" BLOCKED_HUMAN provenance "$HEADX" APPROVE red
mc_prov_detail_put "$KEY" WAIT_CI provenance "$HEADX" APPROVE red
[ -e "$DF" ] && bad "C1: another state must remove the detail" || ok

mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
c1=$(cut -f3 "$CLAIMF"); a1=$(cut -f4 "$CLAIMF")
[ "$(cut -f1,2 "$CLAIMF")" = "$HEADX	provenance-ci-red" ] && [ "$c1" = "$NOW" ] && [ "$a1" = "$NOW" ] && ok \
  || bad "C1: a new claim carries head, reason, claimed_at and active_at (got: $(cat "$CLAIMF"))"
mc_resolver_claim_mark "$KEY" paged
CLK=$((NOW + 600))
mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
[ "$(cut -f3 "$CLAIMF")" = "$c1" ] && ok || bad "C1: a re-claim on the same head keeps claimed_at (got: $(cat "$CLAIMF"))"
[ "$(cut -f5 "$CLAIMF")" = "$NOW" ] && ok || bad "C1: a re-claim on the same head keeps paged_at (got: $(cat "$CLAIMF"))"
[ "$(cut -f4 "$CLAIMF")" = "$a1" ] && ok || bad "C1: a re-claim is not resolver ACTIVITY and must not move active_at (got: $(cat "$CLAIMF"))"
mc_resolver_claim_touch "$KEY"
[ "$(cut -f4 "$CLAIMF")" = "$((NOW + 600))" ] && ok || bad "C1: mc_resolver_claim_touch moves active_at to now (got: $(cat "$CLAIMF"))"
mc_resolver_claim_get "$KEY" "$HEADX" >/dev/null && ok || bad "C1: mc_resolver_claim_get answers for the claimed head"
mc_resolver_claim_get "$KEY" ffffffffffffffffffffffffffffffffffffffff >/dev/null && bad "C1: a claim on another head is not this park's" || ok
mc_resolver_claim "$KEY" ffffffffffffffffffffffffffffffffffffffff provenance-ci-red
[ "$(cut -f3 "$CLAIMF")" = "$((NOW + 600))" ] && [ "$(cut -f5 "$CLAIMF")" = - ] && ok \
  || bad "C1: a claim on a new head starts fresh (got: $(cat "$CLAIMF"))"
rm -f "$CLAIMF"
mc_resolver_claim_touch "$KEY"
[ -e "$CLAIMF" ] && bad "C1: touch with no claim must create none" || ok

# ============================================================================
# C2 — the first page of a claimed park.
# ============================================================================
RESET
SINCE=$((NOW - 600))
SEED "$SINCE"
mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
TICK
[ "$(PAGES)" = 1 ] && ok || bad "C2: a claimed park pages ONCE when parked (got $(PAGES): $(cat "$T/alerts.txt"))"
grep -q -- '--critical' "$T/alerts.txt" && ok || bad "C2: that page is critical, as a park page always was"
[ "$(cut -f5 "$CLAIMF")" = "$NOW" ] && ok || bad "C2: paged_at must be stamped (claim: $(cat "$CLAIMF"))"

# ============================================================================
# C3 — a day of 30-minute ticks, the resolver working: silent.
# ============================================================================
for i in $(seq 1 47); do
  CLK=$((NOW + i * 1800))
  [ $((i % 4)) = 0 ] && mc_resolver_claim_touch "$KEY"
  TICK
done
[ "$(PAGES)" = 1 ] && ok || bad "C3: no re-page while the resolver is working (got $(PAGES): $(tail -2 "$T/alerts.txt"))"
grep -q "$KEY .* claimed by bin/blocked-resolver.sh, not re-paged" "$MC_LOG" && ok \
  || bad "C3: the conductor log must say why it did not page (log: $(tail -3 "$MC_LOG"))"

# ============================================================================
# C4 — the same day with `alerted` wiped before every tick (the 30-min shape).
# ============================================================================
RESET
SINCE=$((NOW - 600))
SEED "$SINCE"
mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
TICK
for i in $(seq 1 47); do
  CLK=$((NOW + i * 1800))
  SEED "$SINCE" -
  [ $((i % 4)) = 0 ] && mc_resolver_claim_touch "$KEY"
  TICK
done
[ "$(PAGES)" = 1 ] && ok || bad "C4: the claim file is the page ledger — a wiped alerted column must not re-page (got $(PAGES))"

# ============================================================================
# C5 — no resolver rung for MC_CLAIMED_REPAGE_S: one more page, then silence.
# ============================================================================
RESET
export MC_CLAIMED_REPAGE_S=7200
SINCE=$((NOW - 600))
SEED "$SINCE"
mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
TICK
for i in 1 2 3; do CLK=$((NOW + i * 1800)); TICK; done
[ "$(PAGES)" = 1 ] && ok || bad "C5: inside the re-page window nothing more (got $(PAGES))"
CLK=$((NOW + 7200)); TICK
[ "$(PAGES)" = 2 ] && ok || bad "C5: past MC_CLAIMED_REPAGE_S with no rung, exactly one more page (got $(PAGES): $(cat "$T/alerts.txt"))"
tail -1 "$T/alerts.txt" | grep -q 'no resolver rung for 2h' && ok || bad "C5: the stale page says how long the resolver has done nothing (got: $(tail -1 "$T/alerts.txt"))"
tail -1 "$T/alerts.txt" | grep -q -- '--critical' && ok || bad "C5: the stale page is critical"
[ "$(cut -f6 "$CLAIMF")" = "$((NOW + 7200))" ] && ok || bad "C5: stale_paged_at stamped (claim: $(cat "$CLAIMF"))"
for i in $(seq 1 10); do CLK=$((NOW + 7200 + i * 1800)); SEED "$SINCE" -; TICK; done
[ "$(PAGES)" = 2 ] && ok || bad "C5: after the stale page, silence — even with alerted wiped (got $(PAGES))"
# the default is 24h: the same frozen claim at +2h is NOT stale without the knob
RESET
unset MC_CLAIMED_REPAGE_S
SINCE=$((NOW - 600))
SEED "$SINCE"
mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
TICK
CLK=$((NOW + 7200)); TICK
[ "$(PAGES)" = 1 ] && ok || bad "C5: with the default knob (24h) a 2h-quiet claim does not re-page (got $(PAGES))"
CLK=$((NOW + 86400)); TICK
[ "$(PAGES)" = 2 ] && ok || bad "C5: at 24h with no rung it does (got $(PAGES))"

# ============================================================================
# C6 — unclaimed parks are unchanged; the stuck page folds into the claim.
# ============================================================================
RESET
CLK=$(command date -u -d "$(command date -u -d "@$NOW" +%Y-%m-%d) 01:00:00" +%s)
SINCE=$((CLK - 600))
SEED "$SINCE"
TICK
for i in 1 2 3 4; do CLK=$((CLK + 1800)); TICK; done
[ "$(PAGES)" = 1 ] && ok || bad "C6: an unclaimed park pages once on day 1 (got $(PAGES))"
CLK=$((CLK + 86400)); TICK
[ "$(PAGES)" = 2 ] && ok || bad "C6: and once more on day 2, exactly as before (got $(PAGES))"
[ -e "$CLAIMF" ] && bad "C6: the conductor never claims on the resolver's behalf" || ok

# mc_stuck_check: unclaimed pages once past the TTL
RESET
SINCE=$((NOW - 7300))
mc_stuck_check "$KEY" BLOCKED_HUMAN "$SINCE" "$HEADX" "$URL" provenance "verdict=APPROVE ci=red"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'STUCK' "$T/alerts.txt")" = 1 ] && ok \
  || bad "C6: an unclaimed stuck park still pages once (rc $rc, alerts: $(cat "$T/alerts.txt"))"
# claimed and paged: the marker is written, no alert, rc 0
RESET
SINCE=$((NOW - 7300))
mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
mc_resolver_claim_mark "$KEY" paged
mc_stuck_check "$KEY" BLOCKED_HUMAN "$SINCE" "$HEADX" "$URL" provenance "verdict=APPROVE ci=red"; rc=$?
[ "$rc" = 0 ] && ok || bad "C6: the fold keeps rc 0 so stuck_rekick still runs (rc $rc)"
[ -s "$T/alerts.txt" ] && bad "C6: a claimed-and-paged park must not STUCK-page (alerts: $(cat "$T/alerts.txt"))" || ok
ls "$MC_STUCK_DIR"/example-org_tproj_530_BLOCKED_HUMAN_* >/dev/null 2>&1 && ok || bad "C6: the stuck marker is still written"
grep -q 'STUCK page folded into the claimed-park gate' "$MC_LOG" && ok || bad "C6: the fold says so in the conductor log (log: $(cat "$MC_LOG"))"
# claimed but NOT yet paged: the stuck page is not folded
RESET
SINCE=$((NOW - 7300))
mc_resolver_claim "$KEY" "$HEADX" provenance-ci-red
mc_stuck_check "$KEY" BLOCKED_HUMAN "$SINCE" "$HEADX" "$URL" provenance "verdict=APPROVE ci=red"
[ "$(grep -c 'STUCK' "$T/alerts.txt")" = 1 ] && ok || bad "C6: a claim that has not paged yet does not fold the stuck page (alerts: $(cat "$T/alerts.txt"))"

echo "conductor-claimed-page.bh-3630: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
