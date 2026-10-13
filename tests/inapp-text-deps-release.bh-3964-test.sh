#!/bin/bash
# tests/inapp-text-deps-release.bh-3964-test.sh — BH-3964 (BH-3946 slice 3 of
# 4): a text-blocked in-app ticket is released by the REAL plain
# `bin/triage-gate.sh <p>` (step 1e answers `RUN inapp-deps-ready`) and handed
# to the tick by the REAL `inapp_released_lines` (bin/lib/rt/scope.sh) as one
# UNBLOCKED or STACKABLE line, with a human HOLD still winning.
#
#   R1-R6   the release, end to end: CLEAR, STACKABLE, the offered window, a
#           HOLD (logged once), HOLD then RESUME, a HOLD posted between the
#           gate and the take.
#   NEG-*   evidence that must NOT release; OWNPR / NEG-B retire the marker.
#   CAP     the lookup cap defers the newer marker, never drops it.
#   MULTI   two releasable markers cost one listing and one PR list.
#   UNREAD  a listing 500 stamps nothing.
#   RF      a malformed ready line is skipped and the file still consumed.
#   K1      the kill switch makes both halves inert.
#   H1-H4   inapp_deps_hold_check on its own.
#   M1      a mutant of the scratch release.sh the suite must catch (D1).
# The take half runs with NO BASE/BP/TOKEN in its environment, the way
# bin/run-triage.sh calls it: it resolves the board itself.
# Every decompose-child body comes out of fc_child_footer | _fcb_html (D4).
# No network, no model: a stub agent-call.sh records any call and the suite
# fails on it.
# Run from anywhere: tests/inapp-text-deps-release.bh-3964-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2], want [$3]"; fi; }

command -v jq >/dev/null 2>&1      || { echo "inapp-text-deps-release: jq missing, cannot run" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "inapp-text-deps-release: python3 missing, cannot run" >&2; exit 1; }

mkdir -p "$T/bin/lib/inapp-deps" "$T/bin/lib/rt" "$T/env" "$T/state" "$T/logs" "$T/flags" "$T/fixture" "$T/builds"

# ── the scratch harness (the shape of the BH-3963 suite) ────────────────────
cp "$DIR/bin/triage-gate.sh" "$DIR/bin/board-fetch.sh" "$T/bin/"
cp "$DIR/bin/lib/inapp-deps.sh" "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" \
   "$DIR/bin/lib/split-chain.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/inapp-deps/core.sh" "$DIR/bin/lib/inapp-deps/release.sh" "$T/bin/lib/inapp-deps/"
cp "$DIR/bin/lib/rt/scope.sh" "$T/bin/lib/rt/"
chmod +x "$T/bin/"*.sh

cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  p1)
    case "${2:-}" in
      repo) echo "example-org/p1" ;;
      prod) echo "https://board.example" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
printf '#!/bin/bash\necho tok\n' > "$T/bin/internal-token-for.sh"
# Nothing on this path may call a model.
printf '#!/bin/bash\ntouch "%s/agent-called"\nexit 1\n' "$T" > "$T/bin/agent-call.sh"
chmod +x "$T/bin/fleet-conf.sh" "$T/bin/internal-token-for.sh" "$T/bin/agent-call.sh"
cat > "$T/env/p1.env" <<'EOC'
P1_API_BASE=https://board.example
P1_INTERNAL_API_TOKEN=tok
EOC

# curl stand-in: honours -o and -w, logs every URL to curl.log and every
# argument list to curl-args.log, serves
#   /boards                 fixture/boards.json
#   /boards/<bid>/tickets   fixture/listing.json, status fixture/listing.code
#   /tickets/<id>           fixture/ticket-<id>.json, status fixture/ticket-<id>.code
cat > "$T/bin/curl" <<EOC
#!/bin/bash
printf '%s\n' "\$*" >> "$T/curl-args.log"
OUT=""; FMT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -w) shift; FMT="\${1:-}" ;;
    -H|-m|-X|-d|--data*) shift; : ;;
    -*) : ;;
    *) URL="\$1" ;;
  esac
  shift || true
done
printf '%s\n' "\$URL" >> "$T/curl.log"
BODY="stub: no route for \$URL"; HTTP="404"; F=""; C=""
case "\$URL" in
  */boards/*/tickets) F="$T/fixture/listing.json"; C="$T/fixture/listing.code" ;;
  */boards)           F="$T/fixture/boards.json";  C="$T/fixture/boards.code" ;;
  */tickets/*)        F="$T/fixture/ticket-\${URL##*/tickets/}.json"; C="$T/fixture/ticket-\${URL##*/tickets/}.code" ;;
esac
if [ -n "\$F" ] && [ -f "\$F" ]; then HTTP=\$(cat "\$C" 2>/dev/null || echo 200); BODY=\$(cat "\$F"); fi
if [ -n "\$OUT" ]; then printf '%s' "\$BODY" > "\$OUT"; else printf '%s' "\$BODY"; fi
printf '%s' "\$FMT" | sed "s/%{http_code}/\$HTTP/g"
case "\$HTTP" in 2*) exit 0 ;; *) [ -z "\$FMT" ] && exit 22; exit 0 ;; esac
EOC
# gh stand-in for gh_rest (`gh api -i`): the PR list answers fixture/prs.json
# with the status in fixture/st-prlist (default 200). Every call is logged.
cat > "$T/bin/gh" <<EOC
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  *"-X GET repos/example-org/p1/pulls"*)
    printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$(cat "$T/fixture/st-prlist" 2>/dev/null || echo 200)" \
      "\$(cat "$T/fixture/prs.json" 2>/dev/null || echo '[]')" ;;
  *) printf 'HTTP/2 404\r\nserver: x\r\n\r\n{}' ;;
esac
EOC
chmod +x "$T/bin/curl" "$T/bin/gh"

export HARNESS="$T"
export PATH="$T/bin:$PATH"
unset DEP_UNKNOWN_MODE INAPP_DEPS_MAX_LOOKUPS INAPP_DEPS_REMIND_S BASE BP TOKEN SELF_ACTORS \
      P1_API_BASE P1_INTERNAL_API_TOKEN BOARD_SELF_ACTORS

# ── fixtures ────────────────────────────────────────────────────────────────
FOOT=$( . "$DIR/bin/lib/file-children.sh" && . "$DIR/bin/lib/fc-board.sh" \
        && fc_child_footer decompose TK-1 2 3 'TK-12 (hard)' 'DEPENDS: TK-11 hard' 'c1' | _fcb_html )
case "$FOOT" in *"Blocked-by: TK-12 (hard)"*) ok ;; *) bad "fixture footer: [$FOOT]"; exit 1 ;; esac
CHILD_BODY="<p>scope</p>$FOOT"
FOOT2=$( . "$DIR/bin/lib/file-children.sh" && . "$DIR/bin/lib/fc-board.sh" \
         && fc_child_footer decompose TK-1 2 3 'TK-12 (hard), TK-13 (hard)' 'DEPENDS: TK-11 hard' 'c1' | _fcb_html )
case "$FOOT2" in *"Blocked-by: TK-12 (hard), TK-13 (hard)"*) ok ;; *) bad "fixture footer 2: [$FOOT2]"; exit 1 ;; esac

# ticket <id> <key> <status> <description> [jq mutation] — fixture/ticket-<id>.json
ticket() {
  jq -nc --arg id "$1" --arg k "$2" --arg s "$3" --arg d "$4" \
    "{id:\$id, key:\$k, status:\$s, boardId:\"b1\", title:(\"Child \" + \$k), description:\$d, comments:[]} ${5:+| $5}" \
    > "$T/fixture/ticket-$1.json" || bad "ticket fixture $1"
}
# listing <TK-12 status> [extra rows json]
listing() {
  jq -nc --arg s "$1" --argjson x "${2:-[]}" \
    '{tickets: ([{id:"t12",key:"TK-12",number:12,status:$s},
                 {id:"c40",key:"TK-40",number:40,status:"todo"}] + $x)}' > "$T/fixture/listing.json"
}
prs() { printf '%s' "$1" > "$T/fixture/prs.json"; }
MERGED_PR='[{"number":5,"state":"closed","merged_at":"2026-10-01T00:00:00Z","draft":false,"title":"x","head":{"ref":"ticket/TK-12"},"html_url":"https://github.com/example-org/p1/pull/5"}]'
OPEN_PR='[{"number":7,"state":"open","merged_at":null,"draft":false,"title":"TK-12: thing","head":{"ref":"ticket/TK-12"},"html_url":"https://github.com/example-org/p1/pull/7"}]'
HUMAN_HOLD='{id:"k1", body:"<p>HOLD — the client wants to rethink this.</p>", createdAt:"2026-10-02T00:00:00Z", author:{name:"Dana"}}'
HUMAN_RESUME='{id:"k2", body:"<p>RESUME</p>", createdAt:"2026-10-03T00:00:00Z", author:{name:"Dana"}}'

SD="$T/state/inapp-deps/p1"
RF="$T/state/inapp-deps-ready-p1"
reset() {
  scratch_rm "$T/state"; scratch_rm "$T/builds"; scratch_rm "$T/logs"
  mkdir -p "$T/state" "$T/builds" "$T/logs" "$SD"
  rm -f "$T/fixture/"* "$T/curl.log" "$T/curl-args.log" "$T/gh.log" "$T/flags/inapp-deps-off"
  echo '[{"id":"b1"}]' > "$T/fixture/boards.json"
  listing todo; prs '[]'
  ticket c40 TK-40 todo "$CHILD_BODY"
  touch "$SD/c40.held"
}

gate() { bash "$T/bin/triage-gate.sh" p1 2>/dev/null; }
# rel — the tick's scope hook exactly as bin/run-triage.sh reaches it: scope.sh
# sourced, HARNESS and PROJECT set, and no board credentials in the env.
rel() {
  ( unset BASE BP TOKEN SELF_ACTORS; HARNESS="$T"; PROJECT=p1
    . "$T/bin/lib/rt/scope.sh"; inapp_released_lines ) 2>/dev/null
}
lib() { ( . "$T/bin/lib/inapp-deps.sh"; "$@" ) 2>/dev/null; }
listings() { grep -c '/boards/b1/tickets$' "$T/curl.log" 2>/dev/null || true; }
prlists()  { grep -c 'repos/example-org/p1/pulls' "$T/gh.log" 2>/dev/null || true; }
nlines()   { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | grep -c .; fi; }
RUN="RUN inapp-deps-ready"

# ── R1. CLEAR: the blocker is done ──────────────────────────────────────────
reset; listing done
eq "R1 gate answers the reason" "$(gate)" "$RUN"
eq "R1 one listing GET" "$(listings)" "1"
eq "R1 one PR list" "$(prlists)" "1"
grep -q 'INAPP_DEP_READY TK-40 (TK-12 satisfied)' "$T/logs/p1.log" 2>/dev/null && ok \
  || bad "R1 the READY log line: $(cat "$T/logs/p1.log" 2>/dev/null)"
[ -f "$SD/offered/c40" ] && ok || bad "R1 offered/c40 must be stamped"
[ -e "$SD/c40.held" ] && bad "R1 a CLEAR offer retires the marker" || ok
[ ! "$SD/offered/c40" -nt "$RF" ] && ok || bad "R1 offered must be written before the ready line"
eq "R1 ready line" "$(tr '\t' '|' < "$RF" 2>/dev/null)" "c40|CLEAR||"
L=$(rel)
eq "R1 exactly one release line" "$(nlines "$L")" "1"
grep -qE '^board b1: UNBLOCKED c40 "Child TK-40" \(TK-40 — text dependency TK-12 satisfied \(done or PR merged\); fetch it and launch per the queue rules if no PR or build already covers it\)$' <<<"$L" \
  && ok || bad "R1 the UNBLOCKED line: [$L]"
[ -e "$RF" ] && bad "R1 the take must consume the ready file" || ok
eq "R1 a second take has nothing" "$(rel)" ""
grep -qE -- '-X (POST|PATCH|PUT|DELETE)' "$T/curl-args.log" "$T/gh.log" 2>/dev/null \
  && bad "R1 no board or GitHub write" || ok

# ── R2 / R3. STACKABLE: the blocker is in review with an open PR ───────────
reset; listing review; prs "$OPEN_PR"
eq "R2 gate answers the reason" "$(gate)" "$RUN"
grep -q 'INAPP_DEP_READY TK-40 (stackable on ticket/TK-12)' "$T/logs/p1.log" 2>/dev/null && ok \
  || bad "R2 the READY log line: $(cat "$T/logs/p1.log" 2>/dev/null)"
[ -e "$SD/c40.held" ] && ok || bad "R2 a STACKABLE offer keeps the marker"
eq "R3 an immediate second gate run" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
L=$(rel)
eq "R2 exactly one release line" "$(nlines "$L")" "1"
grep -qE '^board b1: STACKABLE c40 "Child TK-40" base=ticket/TK-12 parent-pr=https://github\.com/example-org/p1/pull/7 \(TK-40 — Blocked-by TK-12 is still open but its PR is open too — launchable NOW on top of that branch, same queue rules as UNBLOCKED, if no PR or build already covers it\)$' <<<"$L" \
  && ok || bad "R2 the STACKABLE line: [$L]"
eq "R3 still quiet after the take" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"

# ── R4. the newest human comment is HOLD ────────────────────────────────────
r4() {
  reset; listing done
  ticket c40 TK-40 todo "$CHILD_BODY" ".comments = [$HUMAN_HOLD]"
  R4A=$(gate); R4B=$(gate); R4L=$(rel)
  R4N=$(grep -c 'INAPP_DEP_HELD TK-40 — automatic release suppressed: hold:comment' "$T/logs/p1.log" 2>/dev/null || true)
}
r4_ok() {
  [ "$R4A" != "$RUN" ] && [ "$R4B" != "$RUN" ] && [ -z "$R4L" ] && [ "$R4N" = 1 ] \
    && [ ! -e "$RF" ] && [ ! -e "$SD/offered/c40" ] && [ -e "$SD/c40.held" ]
}
r4
eq "R4 no RUN" "$([ "$R4A" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
eq "R4 no line" "$R4L" ""
eq "R4 HELD logged once over two runs" "$R4N" "1"
[ -e "$RF" ] && bad "R4 no ready file" || ok
[ -e "$SD/offered/c40" ] && bad "R4 nothing stamped" || ok
[ -e "$SD/c40.held" ] && ok || bad "R4 the marker stays"
r4_ok && ok || bad "R4 r4_ok must hold on the real lib"

# ── R5. HOLD, then a later human RESUME ─────────────────────────────────────
reset; listing done
ticket c40 TK-40 todo "$CHILD_BODY" ".comments = [$HUMAN_HOLD, $HUMAN_RESUME]"
eq "R5 gate answers the reason" "$(gate)" "$RUN"
grep -qE '^board b1: UNBLOCKED c40 ' <<<"$(rel)" && ok || bad "R5 the line must be emitted"

# ── R6. a HOLD posted between the gate and the take ─────────────────────────
reset; listing done
eq "R6 gate answers the reason" "$(gate)" "$RUN"
ticket c40 TK-40 todo "$CHILD_BODY" ".comments = [$HUMAN_HOLD]"
eq "R6 the take re-checks the hold" "$(rel)" ""
[ -e "$SD/offered/c40" ] && bad "R6 an id the take did not hand over is re-offered later (offered cleared)" || ok

# ── H3'. a HOLD by the harness itself does not hold ─────────────────────────
reset; listing done
ticket c40 TK-40 todo "$CHILD_BODY" \
  '.comments = [{id:"k1", body:"HOLD", isInternal:true, createdAt:"2026-10-02T00:00:00Z", author:{name:"Ops"}}]'
eq "H3' an internal HOLD does not suppress" "$(gate)" "$RUN"

# ── NEG. evidence that must NOT release ─────────────────────────────────────
reset; listing todo '[{"id":"t13","key":"TK-13","number":13,"status":"todo"}]'; prs "$OPEN_PR"
ticket c40 TK-40 todo "<p>scope</p>$FOOT2"
eq "NEG-A two open blockers, one PR" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
grep -q STACKABLE <<<"$(rel)" && bad "NEG-A no STACKABLE line" || ok
[ -e "$SD/c40.held" ] && ok || bad "NEG-A the marker stays"

reset; listing done; ticket c40 TK-40 in_progress "$CHILD_BODY"
eq "NEG-B child in_progress" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
[ -e "$SD/c40.held" ] && bad "NEG-B the marker is retired" || ok
eq "NEG-B no line" "$(rel)" ""

reset; listing review
eq "NEG-C review with no PR" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
[ -e "$SD/c40.held" ] && ok || bad "NEG-C the marker stays"

reset; listing review; prs "$(jq -c '.[0].head.ref = "ticket/TK-120"' <<<"$MERGED_PR")"
eq "NEG-D merged ticket/TK-120 is not TK-12" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"

reset; listing done
prs '[{"number":9,"state":"open","merged_at":null,"draft":false,"title":"x","head":{"ref":"ticket/TK-40"},"html_url":"https://github.com/example-org/p1/pull/9"}]'
eq "OWNPR the child already has a PR" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
[ -e "$SD/c40.held" ] && bad "OWNPR the marker is retired" || ok

# ── CAP / MULTI ─────────────────────────────────────────────────────────────
reset; listing done '[{"id":"c41","key":"TK-41","number":41,"status":"todo"}]'
ticket c41 TK-41 todo "$CHILD_BODY"
touch -d "@$(( $(date +%s) - 600 ))" "$SD/c40.held"; touch "$SD/c41.held"
eq "CAP gate answers the reason" "$(INAPP_DEPS_MAX_LOOKUPS=1 gate)" "$RUN"
grep -q '/tickets/c40$' "$T/curl.log" && ok || bad "CAP the oldest marker is fetched"
grep -q '/tickets/c41$' "$T/curl.log" && bad "CAP the second marker is not fetched" || ok
grep -q 'inapp-deps: lookup cap hit (1 by-id reads) — 1 deferred to the next pass' "$T/logs/p1.log" 2>/dev/null && ok \
  || bad "CAP the cap line: $(cat "$T/logs/p1.log" 2>/dev/null)"
[ -e "$SD/c41.held" ] && ok || bad "CAP the deferred marker stays"
eq "CAP the next pass takes the deferred one" "$(INAPP_DEPS_MAX_LOOKUPS=1 gate)" "$RUN"
grep -q '^c41	CLEAR' "$RF" && ok || bad "CAP c41 offered on the next pass: $(cat "$RF" 2>/dev/null)"

reset; listing done '[{"id":"c41","key":"TK-41","number":41,"status":"todo"}]'
ticket c41 TK-41 todo "$CHILD_BODY"; touch "$SD/c41.held"
eq "MULTI gate answers the reason" "$(gate)" "$RUN"
eq "MULTI one listing for two markers" "$(listings)" "1"
eq "MULTI one PR list for two markers" "$(prlists)" "1"
L=$(rel)
eq "MULTI two lines" "$(nlines "$L")" "2"
eq "MULTI the take reads the listing once" "$(listings)" "2"

# ROT: a marker visited and kept goes to the back, so a permanently blocked
# old marker cannot starve a newer releasable one under the cap.
reset; listing review '[{"id":"c41","key":"TK-41","number":41,"status":"todo"}]'
ticket c41 TK-41 todo "<p>scope</p>" '.comments = [{id:"k3", body:"Blocked-by: none", createdAt:"2026-10-02T00:00:00Z", author:{name:"Dana"}}]'
touch -d "@$(( $(date +%s) - 600 ))" "$SD/c40.held"; touch -d "@$(( $(date +%s) - 300 ))" "$SD/c41.held"
INAPP_DEPS_MAX_LOOKUPS=1 gate >/dev/null
grep -q '/tickets/c41$' "$T/curl.log" && bad "ROT pass 1 visits only the oldest" || ok
INAPP_DEPS_MAX_LOOKUPS=1 gate >/dev/null
grep -q '/tickets/c41$' "$T/curl.log" && ok || bad "ROT pass 2 visits the marker behind the blocked one"
# NONE: the client's newest word is `Blocked-by: none`, so nothing text-holds
# c41 any more; the marker is retired (no line: the comment itself is a board
# change the fingerprint carries).
[ -e "$SD/c41.held" ] && bad "NONE a ticket whose text no longer declares a dependency retires its marker" || ok
[ -e "$SD/c40.held" ] && ok || bad "ROT the blocked marker stays"

# ── UNREAD ──────────────────────────────────────────────────────────────────
reset; listing done; echo 500 > "$T/fixture/listing.code"
eq "UNREAD listing 500" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
[ -e "$SD/offered/c40" ] && bad "UNREAD nothing stamped" || ok
[ -e "$SD/c40.held" ] && ok || bad "UNREAD the marker stays"
reset; listing done; echo 500 > "$T/fixture/st-prlist"
eq "UNREAD PR list 500" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
[ -e "$SD/c40.held" ] && ok || bad "UNREAD PR list: the marker stays"
reset; listing done; echo 404 > "$T/fixture/ticket-c40.code"
eq "UNREAD ticket 404" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
[ -e "$SD/c40.held" ] && ok || bad "UNREAD ticket 404: the marker stays"

# ── RF. a malformed ready line ──────────────────────────────────────────────
reset; listing done; scratch_rm "$SD/c40.held"
printf 'TK-1\nc40\tCLEAR\t\t\n' > "$RF"
L=$(rel)
eq "RF the malformed line is skipped, the good one emitted" "$(nlines "$L")" "1"
[ -e "$RF" ] && bad "RF the file is consumed" || ok

# ── K1. the kill switch ─────────────────────────────────────────────────────
reset; listing done; touch "$T/flags/inapp-deps-off"
eq "K1 gate" "$([ "$(gate)" = "$RUN" ] && echo RUN || echo quiet)" "quiet"
printf 'c40\tCLEAR\t\t\n' > "$RF"
eq "K1 take" "$(rel)" ""
[ -e "$SD/offered/c40" ] && bad "K1 nothing stamped" || ok

# ── H. inapp_deps_hold_check on its own ─────────────────────────────────────
reset
HF="$T/fixture/ticket-c40.json"
ticket c40 TK-40 todo "$CHILD_BODY" ".comments = [$HUMAN_HOLD]"
case "$(lib inapp_deps_hold_check "$HF" "System Harness")" in
  "held hold:comment 2026-10-02T00:00:00Z"*) ok ;; *) bad "H1 human HOLD: [$(lib inapp_deps_hold_check "$HF" "System Harness")]" ;;
esac
ticket c40 TK-40 todo "$CHILD_BODY" ".comments = [$HUMAN_HOLD, $HUMAN_RESUME]"
eq "H2 HOLD then RESUME" "$(lib inapp_deps_hold_check "$HF" "System Harness")" "clear"
ticket c40 TK-40 todo "$CHILD_BODY" \
  '.comments = [{id:"k1", body:"HOLD", isInternal:true, createdAt:"2026-10-02T00:00:00Z", author:{name:"Ops"}}]'
eq "H3 internal HOLD" "$(lib inapp_deps_hold_check "$HF" "System Harness")" "clear"
ticket c40 TK-40 todo "$CHILD_BODY" \
  '.comments = [{id:"k1", body:"HOLD", createdAt:"2026-10-02T00:00:00Z", author:{name:"System Harness"}}]'
eq "H3b self-actor HOLD" "$(lib inapp_deps_hold_check "$HF" "System Harness")" "clear"
eq "H4 /dev/null" "$(lib inapp_deps_hold_check /dev/null "")" "unreadable"
echo '[1,2]' > "$T/fixture/arr.json"
eq "H4b not an object" "$(lib inapp_deps_hold_check "$T/fixture/arr.json" "")" "unreadable"
ticket c40 TK-40 todo "<p>HOLD: waiting on legal</p>"
case "$(lib inapp_deps_hold_check "$HF" "")" in held\ hold:body*) ok ;; *) bad "H5 a HOLD line in the description: [$(lib inapp_deps_hold_check "$HF" "")]" ;; esac

[ -e "$T/agent-called" ] && bad "no model call on either path" || ok

# ── M1. a forced-clear hold check must turn R4 red ──────────────────────────
cp "$T/bin/lib/inapp-deps/release.sh" "$T/release.orig"
printf '\ninapp_deps_hold_check() { echo clear; }\n' >> "$T/bin/lib/inapp-deps/release.sh"
r4
r4_ok && bad "M1 hold_check forced clear must turn R4 red" || ok
cp "$T/release.orig" "$T/bin/lib/inapp-deps/release.sh"
r4
r4_ok && ok || bad "M1 restored: R4 must hold again"

echo "inapp-text-deps-release.bh-3964: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
