#!/bin/bash
# tests/fixround-preflight-defer.bh-1992-test.sh — BH-1992 items 3 and 5.
#
# ITEM 3. The resolver runs every 10 minutes, bin/review-prs.sh at :07/:37, so
# the tick after an evidence route usually ran the fix round before the review
# lane had even read the request. On a review-lane park that route now defers
# the round until the review lane has answered on the head, or one review
# cadence (BR_PREFLIGHT_DEFER_S) has passed.
#   D1  +10 min, no new review on the head       -> deferred, nothing spent
#   D2  +31 min                                  -> the round runs
#   D3  +10 min but a verdict author reviewed the head after the request
#                                                -> the round runs (an
#       untrusted review does not count; an unreadable list runs the round)
#   D4  no route stamp on the record             -> the round runs (as before)
#   D5  a conductor park is not deferred: its re-review was bought in-line
# ITEM 5. The preflight's re-review has its own budget reason.
#   B1  br_rereview ... preflight: `preflight_rereviews` +1, `rereviews`
#       untouched, logged [preflight-rereview] never [no-verdict], and neither
#       BR_NOVERDICT_MAX nor the lane-failure cap gates it
#   B2  the no-verdict rung's own call reads and spends exactly what it did
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/fixround-preflight-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
frpx_setup
unset HARNESS_VERDICT_AUTHORS
NOW=$(date -u +%s)
ISO() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
REVIEW() { # REVIEW <login> <commit> <epoch> — pulls/7/reviews, one row
  jq -nc --arg l "$1" --arg c "$2" --arg t "$(ISO "$3")" '[{user:{login:$l}, commit_id:$c, state:"COMMENTED", submitted_at:$t, body:"VERDICT: REQUEST_CHANGES"}]' > "$T/gh/reviews-7.json"
}
ROUTED() { # ROUTED <route-at epoch> — the record after an evidence route on NEW
  jq -nc --arg h "$NEW" --argjson a "$1" '{preflight_heads:[$h], preflight_route_at:$a}' > "$T/rec.json"
}
STAGE() { reset_gh; reset_rec; RUNS "$NEW" success; PRBODY "$NEW" "$STALE_BODY"; }

# D1: the route itself stamps the record; ten minutes on, the round waits.
STAGE
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 1 ] && ok || bad "D1 the evidence route must not run a round"
RA=$(jq -r '.preflight_route_at // ""' "$T/rec.json" 2>/dev/null)
case "$RA" in ''|*[!0-9]*) bad "D1 the evidence route must stamp preflight_route_at (got '$RA')" ;; *) [ $((NOW - RA)) -le 60 ] && ok || bad "D1 the route stamp must be now (got $RA)" ;; esac
STAGE; ROUTED $((NOW - 600))
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 1 ] && ok || bad "D1 ten minutes after the request, with no new review, the round must be deferred"
grep -q "deferring the fix round on ${NEW:0:8}: re-review requested 10 min ago" "$T/say.log" 2>/dev/null && ok || bad "D1 the defer must be said: $(cat "$T/say.log" 2>/dev/null)"
grep -q "defer on ${NEW:0:8}" "$T/events.log" 2>/dev/null && ok || bad "D1 one event row for the defer: $(cat "$T/events.log" 2>/dev/null)"
[ "$(lines "$T/comments.log")" = 0 ] && [ "$(patches)" = 0 ] && ok || bad "D1 a deferred tick spends nothing (no comment, no PATCH)"

# D2: one cadence later the round runs.
STAGE; ROUTED $((NOW - 1860))
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 0 ] && ok || bad "D2 31 minutes after the request the round must run"
[ "$(BR_PREFLIGHT_DEFER_S=0 PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 0 ] && ok || bad "D2 BR_PREFLIGHT_DEFER_S=0 turns the defer off"
STAGE; ROUTED $((NOW - 600))
[ "$(BR_PREFLIGHT_DEFER_S=0 PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 0 ] && ok || bad "D2 BR_PREFLIGHT_DEFER_S=0 must never defer"

# D3: the review lane already answered on this head after the request.
STAGE; ROUTED $((NOW - 600)); REVIEW 'cromford[bot]' "$NEW" $((NOW - 300))
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 0 ] && ok || bad "D3 a verdict author's review on the head after the request means it was consumed — the round runs"
STAGE; ROUTED $((NOW - 600)); REVIEW 'cromford[bot]' "$NEW" $((NOW - 900))
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 1 ] && ok || bad "D3 a review from BEFORE the request is not the answer to it"
STAGE; ROUTED $((NOW - 600)); REVIEW evil-user "$NEW" $((NOW - 300))
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 1 ] && ok || bad "D3 an untrusted review does not consume the request"
STAGE; ROUTED $((NOW - 600)); REVIEW 'cromford[bot]' "$OLD" $((NOW - 300))
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 1 ] && ok || bad "D3 a review of another head does not consume the request"
STAGE; ROUTED $((NOW - 600)); touch "$T/gh/reviews-fail"
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 0 ] && ok || bad "D3 an unreadable review list must not defer (when in doubt the round runs)"

# D4: routed on this head but no stamp (a record from before BH-1992).
STAGE; jq -nc --arg h "$NEW" '{preflight_heads:[$h]}' > "$T/rec.json"
[ "$(PRE review-changes-requested "$STALE_FINDINGS" | head -1)" = 0 ] && ok || bad "D4 a route with no stamp must run the round as before"

# D5: a conductor park's re-review was bought in-line; nothing to wait for.
STAGE; ROUTED $((NOW - 600))
[ "$(PRE head-not-reapproved "$OLD_FINDINGS" | head -1)" = 0 ] && ok || bad "D5 a conductor park already routed on this head runs the round"

# The preflight hands its re-review the `preflight` reason.
STAGE
[ "$(PRE head-not-reapproved "$OLD_FINDINGS" | head -1)" = 1 ] && ok || bad "B0 the conductor rereview route must not run a round"
grep -q ' preflight$' "$T/rereview.log" 2>/dev/null && ok || bad "B0 br_preflight must call br_rereview with the preflight reason: $(cat "$T/rereview.log" 2>/dev/null)"

# ============================================================================
# B1/B2 — br_rereview, the real function
# ============================================================================
cat > "$T/rr-stubs.sh" <<EOF
OBSERVE=0; BR_NOVERDICT_MAX=5; BR_LANEFAIL_MAX=5
mc_lane_epoch() { printf 7; }
mc_slug_of_url() { printf '%s' "$SLUG"; }
br_pr_field() { printf '%s' "$NEW"; }
mc_row_field() { printf rev; }
br_count() { :; }
mc_rereview() { cat "$T/mc-verdict" 2>/dev/null; return "\$(cat "$T/mc-rc" 2>/dev/null || echo 0)"; }
rp_post() { printf '%s\n' "\$5" >> "$T/rp-post.log"; }
mc_transition() { :; }
br_lane_down_alert() { printf 'lane-down %s\n' "\$*" >> "$T/alerts.log"; }
br_record() { printf 'record %s\n' "\$*" >> "$T/record.log"; [ -n "\${6:-}" ] && _rec_w --arg b "\$6" '.[\$b] = ((.[\$b] // 0) + 1)'; return 0; }
EOF
RR() { # RR [preflight] — one br_rereview call
  rm -f "$T/record.log" "$T/rp-post.log"
  bash -c '. "$1"; . "$2"; . "$3"; br_rereview tproj rk head-not-reapproved "$4" /rec TK-7 ${5:+"$5"}' _ \
    "$T/stubs.sh" "$T/rr-stubs.sh" "$T/rereview.sh" "$URL" "${1:-}"
}
# B1: at the no-verdict cap (5 of 5) and the lane-failure cap, the preflight's
# re-review still runs, and charges only its own counter.
reset_rec; echo APPROVE > "$T/mc-verdict"; echo 0 > "$T/mc-rc"
jq -nc '{rereviews:5, lanefails:5, lanefail_epoch:7}' > "$T/rec.json"
RR preflight
[ "$(jq -r '.rereviews' "$T/rec.json")" = 5 ] && ok || bad "B1 the preflight re-review must not touch rereviews: $(cat "$T/rec.json")"
[ "$(jq -r '.preflight_rereviews // 0' "$T/rec.json")" = 1 ] && ok || bad "B1 preflight_rereviews must be 1: $(cat "$T/rec.json")"
grep -q '\[preflight-rereview\]' "$T/say.log" 2>/dev/null && ok || bad "B1 the log must carry [preflight-rereview]: $(cat "$T/say.log" 2>/dev/null)"
grep -q '\[no-verdict\]' "$T/say.log" 2>/dev/null && bad "B1 the preflight re-review was logged [no-verdict]: $(grep no-verdict "$T/say.log")" || ok
grep -q 'no verdict' "$T/rp-post.log" 2>/dev/null && bad "B1 the posted re-review must not say the conductor got no verdict: $(cat "$T/rp-post.log")" || ok
[ ! -s "$T/alerts.log" ] && ok || bad "B1 the no-verdict caps must not gate the preflight re-review"
# ...a lane failure on the preflight re-review is not a no-verdict lane failure.
reset_rec; : > "$T/mc-verdict"; echo 2 > "$T/mc-rc"
jq -nc '{rereviews:1, lanefails:1, lanefail_epoch:7}' > "$T/rec.json"
RR preflight
[ "$(jq -r '.lanefails' "$T/rec.json")" = 1 ] && [ "$(jq -r '.rereviews' "$T/rec.json")" = 1 ] && ok || bad "B1 a lane failure on the preflight re-review must not charge the no-verdict axes: $(cat "$T/rec.json")"
# B2: the no-verdict rung is unchanged.
reset_rec; echo APPROVE > "$T/mc-verdict"; echo 0 > "$T/mc-rc"
jq -nc '{rereviews:1}' > "$T/rec.json"
RR
[ "$(jq -r '.rereviews' "$T/rec.json")" = 2 ] && [ "$(jq -r '.preflight_rereviews // 0' "$T/rec.json")" = 0 ] && ok || bad "B2 the no-verdict rung must still spend rereviews: $(cat "$T/rec.json")"
grep -q '\[no-verdict\]' "$T/say.log" 2>/dev/null && ok || bad "B2 the no-verdict rung still logs [no-verdict]"
reset_rec; jq -nc '{rereviews:5}' > "$T/rec.json"
RR
[ "$(jq -r '.rereviews' "$T/rec.json")" = 5 ] && [ -s "$T/alerts.log" ] && ok || bad "B2 BR_NOVERDICT_MAX still stops the no-verdict rung"

echo "fixround-preflight-defer.bh-1992: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
