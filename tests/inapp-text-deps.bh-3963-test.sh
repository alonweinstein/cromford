#!/bin/bash
# tests/inapp-text-deps.bh-3963-test.sh — BH-3963 (BH-3946 slice 2 of 4): an
# in-app board ticket whose own text says `Blocked-by: TK-12` is refused by
# the REAL `bin/triage-gate.sh <p> --buildable <id>` until TK-12 is done or its
# PR merged, and the three functions in bin/lib/inapp-deps/core.sh behind it.
#
#   P1-P9   inapp_deps_lines / inapp_deps_eval, the lib sourced in a subshell:
#           the reader (HTML, recency, `build after`), the resolver (key,
#           keyPrefix-number, #N, keymap by-id refetch) and the judge (status,
#           merged PR, split-chain, open PR = STACKABLE).
#   N1-N8   the negatives: text that must NOT add a blocker, and evidence that
#           must NOT release one.
#   G1-G11  the production entry point, bin/triage-gate.sh --buildable[-strict],
#           against a stub curl (logs every URL) and a stub gh on a scratch
#           tree; F1 is the no-dependency fast path; G6 drives
#           bin/preplan-candidates.sh; K1 is the kill switch.
#   M1-M2   mutants of the scratch core.sh the suite must catch (D1).
# Every decompose-child body comes out of fc_child_footer | _fcb_html (D4).
# No network, no model.
# Run from anywhere: tests/inapp-text-deps.bh-3963-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
CORE="$DIR/bin/lib/inapp-deps/core.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2], want [$3]"; fi; }

command -v jq >/dev/null 2>&1      || { echo "inapp-text-deps: jq missing, cannot run" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "inapp-text-deps: python3 missing, cannot run" >&2; exit 1; }

mkdir -p "$T/bin/lib/inapp-deps" "$T/env" "$T/state" "$T/logs" "$T/flags" "$T/fixture" "$T/builds"

# ── the scratch harness (the shape of the BH-900 / BH-3962 suites) ──────────
cp "$DIR/bin/triage-gate.sh" "$DIR/bin/board-fetch.sh" "$DIR/bin/preplan-candidates.sh" "$T/bin/"
cp "$DIR/bin/lib/inapp-deps.sh" "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/internal-token.sh" \
   "$DIR/bin/lib/split-chain.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
cp "$DIR/bin/lib/inapp-deps/core.sh" "$DIR/bin/lib/inapp-deps/release.sh" "$T/bin/lib/inapp-deps/"
chmod +x "$T/bin/"*.sh

cat > "$T/bin/fleet-conf.sh" <<'EOC'
#!/bin/bash
case "${1:-}" in
  x-os)
    case "${2:-}" in
      repo) echo "example-org/x-os" ;;
      prod) echo "https://board.example" ;;
      board_prefix|*) echo "/api/board" ;;
    esac ;;
  *) echo "" ;;
esac
EOC
printf '#!/bin/bash\necho tok\n' > "$T/bin/internal-token-for.sh"
chmod +x "$T/bin/fleet-conf.sh" "$T/bin/internal-token-for.sh"
cat > "$T/env/x-os.env" <<'EOC'
XOS_API_BASE=https://board.example
XOS_INTERNAL_API_TOKEN=tok
EOC

# curl stand-in: honours -o and -w (board-fetch.sh and the listing read both
# use them), logs every URL, serves
#   /boards                 fixture/boards.json
#   /boards/<bid>/tickets   fixture/listing.json, status fixture/listing.code
#   /tickets/<id>           fixture/ticket-<id>.json, status fixture/ticket-<id>.code
cat > "$T/bin/curl" <<EOC
#!/bin/bash
OUT=""; FMT=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUT="\${1:-}" ;;
    -w) shift; FMT="\${1:-}" ;;
    -H|-m) shift; : ;;
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
  *"-X GET repos/example-org/x-os/pulls"*)
    printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$(cat "$T/fixture/st-prlist" 2>/dev/null || echo 200)" \
      "\$(cat "$T/fixture/prs.json" 2>/dev/null || echo '[]')" ;;
  *) printf 'HTTP/2 404\r\nserver: x\r\n\r\n{}' ;;
esac
EOC
chmod +x "$T/bin/curl" "$T/bin/gh"

export HARNESS="$T"
export PATH="$T/bin:$PATH"
unset DEP_UNKNOWN_MODE INAPP_DEPS_MAX_LOOKUPS

# ── fixtures ────────────────────────────────────────────────────────────────
# The decompose child body, exactly as bin/lib/fc-board.sh files it.
FOOT=$( . "$DIR/bin/lib/file-children.sh" && . "$DIR/bin/lib/fc-board.sh" \
        && fc_child_footer decompose TK-1 2 3 'TK-12 (hard)' 'DEPENDS: TK-11 hard' 'c1' | _fcb_html )
case "$FOOT" in *"Blocked-by: TK-12 (hard)"*"DEPENDS: TK-11 hard"*) ok ;; *) bad "fixture footer: [$FOOT]"; exit 1 ;; esac
CHILD_BODY="<p>scope</p>$FOOT"

# ticket <file> <id> <key> <status> <description> [jq mutation] — a raw ticket.
ticket() {
  jq -nc --arg id "$2" --arg k "$3" --arg s "$4" --arg d "$5" \
    "{id:\$id, key:\$k, status:\$s, boardId:\"b1\", description:\$d, comments:[]} ${6:+| $6}" > "$1" \
    || bad "ticket fixture $1"
}
# listing <TK-12 status> [extra rows json] — the board listing the gate reads.
listing() {
  jq -nc --arg s "$1" --argjson x "${2:-[]}" \
    '{tickets: ([{id:"t12",key:"TK-12",number:12,status:$s},
                 {id:"t2",key:"TK-2",number:2,status:"todo"}] + $x)}' > "$T/fixture/listing.json"
}
prs() { printf '%s' "$1" > "$T/fixture/prs.json"; }
MERGED_PR='[{"number":5,"state":"closed","merged_at":"2026-10-01T00:00:00Z","draft":false,"title":"x","head":{"ref":"ticket/TK-12"},"html_url":"https://github.com/example-org/x-os/pull/5"}]'
OPEN_PR='[{"number":6,"state":"open","merged_at":null,"draft":false,"title":"TK-12: thing","head":{"ref":"ticket/TK-12"},"html_url":"https://github.com/example-org/x-os/pull/6"}]'

reset() {
  scratch_rm "$T/state"; scratch_rm "$T/builds"; mkdir -p "$T/state" "$T/builds"
  rm -f "$T/fixture/"* "$T/curl.log" "$T/gh.log" "$T/flags/inapp-deps-off"
  echo '[{"id":"b1"}]' > "$T/fixture/boards.json"
  listing todo; prs '[]'
}

# lib <cmd...> — run in a subshell with the scratch lib sourced and the gate's
# globals set the way bin/triage-gate.sh sets them for x-os.
lib() {
  ( BASE=https://board.example BP=/api/board TOKEN=tok SELF_ACTORS="System Harness"
    . "$T/bin/lib/inapp-deps.sh"; "$@" ) 2>/dev/null
}
LF="$T/t.json"
lines() { lib inapp_deps_lines "$LF" "System Harness" | paste -sd, -; }
# ev — the eval of $LF against the fixture listing and PR list.
ev() { lib inapp_deps_eval x-os "$LF" "$T/fixture/listing.json" "$T/fixture/prs.json"; }
verdict() { ev | grep '^VERDICT' | tr '\t' '|'; }
refline() { ev | awk -F'\t' -v r="$1" '$1 == r' | tr '\t' '|'; }

gate() { bash "$T/bin/triage-gate.sh" x-os "${2:---buildable}" "$1" 2>/dev/null; }
listings() { grep -c '/boards/b1/tickets$' "$T/curl.log" 2>/dev/null || true; }
HELD="$T/state/inapp-deps/x-os"

# ── P: the reader ───────────────────────────────────────────────────────────
reset
ticket "$LF" t2 TK-2 todo "$CHILD_BODY";                                eq "P1 fc_child_footer|_fcb_html body" "$(lines)" "TK-12"
ticket "$LF" t2 TK-2 todo "<p>R&amp;D &lt;tools&gt; &#39;x&#39;</p>$FOOT"; eq "P1-amp escaped text" "$(lines)" "TK-12"
QUOTE=$( . "$DIR/bin/lib/fc-board.sh" && printf '> Blocked-by: TK-12\n' | _fcb_html )
ticket "$LF" t2 TK-2 todo "$QUOTE";                                      eq "P1-quote &gt; is unescaped before matching" "$(lines)" "TK-12"
ticket "$LF" t2 TK-2 todo "Needs: TK-14";                                eq "P2 needs line" "$(lines)" "TK-14"
ticket "$LF" t2 TK-2 todo "Needs: TK-14 (see \`utf-8\`) and TK-15";       eq "P2c refs after a closed code span survive" "$(lines)" "TK-14,TK-15"
ticket "$LF" t2 TK-2 todo "Blocked-by: #12, TK-13 and #12";             eq "P2b refs in order, deduped" "$(lines)" "#12,TK-13"
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12" \
  '.comments = [{body:"Blocked-by: TK-13", createdAt:"2026-10-02T00:00:00Z", author:{name:"Dana"}}]'
eq "P4 newer client comment replaces the description" "$(lines)" "TK-13"
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12" \
  '.comments = [{body:"Blocked-by: none", createdAt:"2026-10-02T00:00:00Z", author:{name:"Dana"}},
                {body:"Blocked-by: TK-13", createdAt:"2026-10-01T00:00:00Z", author:{name:"Dana"}}]'
eq "P4b newest Blocked-by: none clears" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12" '.blocked = false';       eq "P5 blocked:false is PRIMITIVE" "$(lines)" "PRIMITIVE"
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12" '{ticket: (. + {blocked: true})}'
eq "P5b .ticket.blocked is PRIMITIVE" "$(lines)" "PRIMITIVE"
ticket "$LF" t2 TK-2 todo "$(printf 'Part of #TK-1\nOrder: 2 of 3\nbuild after TK-33\n')"
eq "P6 build after with Order + Part of" "$(lines)" "TK-33"
eq "C1b lines on /dev/null" "$(lib inapp_deps_lines /dev/null '')" "NONE"

# ── N: text that must NOT add a blocker ─────────────────────────────────────
ticket "$LF" t2 TK-2 todo "<p>Honestly this is not blocked by anything TK-12 does.</p>"; eq "N1 prose" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "<p>Write \`Blocked-by: TK-12\` to hold it.</p>";            eq "N2a inline code" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "<p>Write <code>Blocked-by: TK-12</code> to hold it.</p>";   eq "N2a <code>" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "<p><code>Blocked-by: TK-12</code> is the syntax.</p>";       eq "N2a <code> at line start" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "<pre>Blocked-by: TK-12</pre><p>scope</p>";                   eq "N2a <pre>" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "Needs: \`utf-8\` support";                                  eq "N2c a code ref on a needs line" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "$(printf 'Example:\n```\nBlocked-by: TK-12\n```\n')";         eq "N2b fenced" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "$(printf 'Example:\n~~~\nBlocked-by: TK-12\n')";              eq "N2b unterminated fence" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "<p>scope</p>" \
  '.comments = [{body:"<p>To hold this ticket, write `Blocked-by: TK-12 (hard)` in the issue body.</p>", isInternal:true, createdAt:"2026-10-02T00:00:00Z", author:{name:"System Harness"}}]'
eq "N3 the harness's own internal dep-note" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "<p>scope</p>" \
  '.comments = [{body:"Blocked-by: TK-12", createdAt:"2026-10-02T00:00:00Z", author:{name:"System Harness"}}]'
eq "N3b a self-actor comment is not the client's" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "<p>scope</p>" \
  '.comments = [{body:"Blocked-by: TK-12", isInternal:true, createdAt:"2026-10-02T00:00:00Z", author:{name:"Ops"}}]'
eq "N3c an internal comment is not the client's" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "build after TK-33";                              eq "N4 build after alone" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "Needs: review from the operator";                        eq "N5 needs with no ref" "$(lines)" "NONE"
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12" \
  '.comments = [{body:"Needs: review from the operator", createdAt:"2026-10-02T00:00:00Z", author:{name:"Dana"}}]'
eq "N5b a newer refless Needs does not release" "$(lines)" "TK-12"
ticket "$LF" t40 TK-40 todo "Blocked-by: TK-40";                            eq "N6 self reference" "$(lines)" "NONE"

# ── P: the resolver and the judge ───────────────────────────────────────────
eq "C1b eval on /dev/null" "$(lib inapp_deps_eval x-os /dev/null /dev/null /dev/null | tr '\t' '|')" "VERDICT|NONE|||"
ticket "$LF" t2 TK-2 todo "Blocked-by: #12"
eq "P3 #12 by number" "$(refline '#12')" "#12|OPEN|TK-12|t12|"
jq -c '.tickets[0] |= (del(.key) + {keyPrefix:"PB"})' "$T/fixture/listing.json" > "$T/l2" && mv "$T/l2" "$T/fixture/listing.json"
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12"
eq "P3b keyless row by keyPrefix-number" "$(refline TK-12)" "TK-12|OPEN|TK-12|t12|"
listing review; prs "$MERGED_PR"
eq "P7a review + merged PR is SATISFIED" "$(refline TK-12)" "TK-12|SATISFIED|TK-12|t12|"
eq "P7a verdict" "$(verdict)" "VERDICT|CLEAR|||"
prs "$OPEN_PR"
eq "P7b review + open PR is STACKABLE" "$(verdict)" "VERDICT|STACKABLE|TK-12|ticket/TK-12|https://github.com/example-org/x-os/pull/6"
prs "$(jq -c '.[0].draft = true' <<<"$OPEN_PR")"
eq "P7b' a draft PR is no base" "$(verdict)" "VERDICT|BLOCKED|TK-12||"
prs '[{"number":7,"state":"closed","merged_at":"2026-10-01T00:00:00Z","title":"TK-12: other head","head":{"ref":"feat/x"},"html_url":"u"}]'
eq "P7c merged PR titled TK-12: is SATISFIED" "$(refline TK-12 | cut -d'|' -f2)" "SATISFIED"
prs '[]'; mkdir -p "$T/builds/x-os-TK-12-202610010000"
echo "PR_MERGED https://github.com/example-org/x-os/pull/5" > "$T/builds/x-os-TK-12-202610010000/RESULT"
eq "P7d split-chain PR_MERGED is SATISFIED" "$(refline TK-12 | cut -d'|' -f2)" "SATISFIED"
scratch_rm "$T/builds/x-os-TK-12-202610010000"
listing done
eq "P7e status done is SATISFIED" "$(verdict)" "VERDICT|CLEAR|||"
# P8: a key missing from the (capped) listing, mapped by the keymap.
listing todo; echo '{"TK-50":"t50","t50":"TK-50"}' > "$T/state/x-os.keymap.json"
ticket "$T/fixture/ticket-t50.json" t50 TK-50 done ""
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-50"
eq "P8 keymap by-id refetch, done" "$(refline TK-50)" "TK-50|SATISFIED|TK-50|t50|"
echo 500 > "$T/fixture/ticket-t50.code"
eq "P8 keymap refetch 500 is UNKNOWN" "$(refline TK-50 | cut -d'|' -f2)" "UNKNOWN"
eq "P8 UNKNOWN under soft is CLEAR" "$(verdict)" "VERDICT|CLEAR|||"
eq "P8 UNKNOWN under hard is BLOCKED" "$(DEP_UNKNOWN_MODE=hard verdict)" "VERDICT|BLOCKED|TK-50||"
rm -f "$T/fixture/ticket-t50.code"
eq "P8c lookup cap 0 leaves it UNKNOWN" "$(INAPP_DEPS_MAX_LOOKUPS=0 refline TK-50 | cut -d'|' -f2)" "UNKNOWN"
# P9: two OPEN, one with an open PR.
listing todo '[{"id":"t13","key":"TK-13","number":13,"status":"todo"}]'; prs "$OPEN_PR"
ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12, TK-13"
eq "P9 two OPEN, one PR is BLOCKED on both" "$(verdict)" "VERDICT|BLOCKED|TK-12,TK-13||"

# ── N: evidence that must NOT release ───────────────────────────────────────
listing review; ticket "$LF" t2 TK-2 todo "Blocked-by: TK-12"
prs "$(jq -c '.[0].head.ref = "ticket/TK-120"' <<<"$MERGED_PR")"
eq "N7 merged ticket/TK-120 does not satisfy TK-12" "$(refline TK-12 | cut -d'|' -f2)" "OPEN"
prs "$(jq -c '.[0].head.ref = "ticket/TK-12-r2"' <<<"$MERGED_PR")"
eq "N7b merged ticket/TK-12-r2 does" "$(refline TK-12 | cut -d'|' -f2)" "SATISFIED"
prs '[]'
eq "N8 review with no PR stays OPEN" "$(refline TK-12 | cut -d'|' -f2)" "OPEN"
eq "N8 verdict" "$(verdict)" "VERDICT|BLOCKED|TK-12||"

# ── G: the real gate ────────────────────────────────────────────────────────
reset
ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY"
eq "G1 todo blocker refuses" "$(gate t2)" "BLOCKED dependencies TK-12"
[ -f "$HELD/t2.held" ] && ok || bad "G1 the held marker must exist"
eq "G1 one listing GET" "$(listings)" "1"
grep -q 'repos/example-org/x-os/pulls' "$T/gh.log" 2>/dev/null && ok || bad "G1 the PR list must be read"
eq "G1 strict refuses too" "$(gate t2 --buildable-strict)" "BLOCKED dependencies TK-12"

reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY"; listing done
eq "G2 done blocker" "$(gate t2)" "OK"
[ -e "$HELD/t2.held" ] && bad "G2 no held marker on CLEAR" || ok

reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY" '.blocked = false'
eq "G3 blocked:false wins over text" "$(gate t2)" "OK"
eq "G3 no listing GET" "$(listings)" "0"

reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY" '.blocked = true | .dependsOn = [{key:"TK-12"}]'
eq "G4 blocked:true is the primitive arm" "$(gate t2)" "BLOCKED dependencies TK-12"

reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "Blocked-by: TK-999"
eq "G5 unresolvable under soft" "$(gate t2)" "OK"
eq "G5 unresolvable under hard" "$(DEP_UNKNOWN_MODE=hard gate t2)" "BLOCKED dependencies TK-999"
[ -f "$HELD/t2.held" ] && ok || bad "G5 hard BLOCKED writes the held marker"

reset; echo 500 > "$T/fixture/listing.code"; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY"
eq "G7 listing 500, strict" "$(gate t2 --buildable-strict)" "BLOCKED unreadable"
eq "G7 listing 500, plain" "$(gate t2)" "OK"
echo 200 > "$T/fixture/listing.code"; echo 'not json' > "$T/fixture/listing.json"
eq "G7b listing not JSON, strict" "$(gate t2 --buildable-strict)" "BLOCKED unreadable"

for s in review in_progress done; do
  reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 "$s" "$CHILD_BODY"
  eq "G8 child $s" "$(gate t2)" "OK"
  eq "G8 child $s fetches no listing" "$(listings)" "0"
done

reset; echo 500 > "$T/fixture/st-prlist"; prs "$MERGED_PR"; listing done
ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY"
eq "G9 PR list down, done blocker" "$(gate t2)" "OK"
listing review
eq "G9 PR list down, review blocker is not released" "$(gate t2)" "BLOCKED dependencies TK-12"

reset; listing review; prs "$OPEN_PR"; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY"
eq "G10 STACKABLE answers OK" "$(gate t2)" "OK"
[ -f "$HELD/t2.held" ] && ok || bad "G10 STACKABLE writes the held marker"

# G11: a thread board-fetch trims (first + last 10) hides a middle Blocked-by;
# the arm re-fetches it --full.
reset
ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "<p>scope</p>" \
  '.comments = [range(0;14) | {body: (if . == 2 then "Blocked-by: TK-12" else "note \(.)" end),
                               createdAt: ("2026-10-01T00:" + (if . < 10 then "0" else "" end) + "\(.):00Z"),
                               author: {name: "Dana"}}]'
jq -e '.comments | length == 12' <(INTERNAL_TOKEN=tok bash "$T/bin/board-fetch.sh" https://board.example/api/board/tickets/t2) >/dev/null \
  && ok || bad "G11 fixture: board-fetch must trim this thread"
eq "G11 a trimmed middle Blocked-by is still read" "$(gate t2)" "BLOCKED dependencies TK-12"

# G12: no boardId on the ticket: the gate's fingerprint names the board.
reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY" 'del(.boardId)'
echo '{"b1":[{"id":"t2","status":"todo"}]}' > "$T/state/x-os.gate.json"
echo '[{"id":"b1"},{"id":"b9"}]' > "$T/fixture/boards.json"
eq "G12 board id from gate.json" "$(gate t2)" "BLOCKED dependencies TK-12"
scratch_rm "$T/state/x-os.gate.json"
eq "G13 two boards, no boardId: strict is unreadable" "$(gate t2 --buildable-strict)" "BLOCKED unreadable"
eq "G13 two boards, no boardId: plain falls through" "$(gate t2)" "OK"
echo '[{"id":"b1"}]' > "$T/fixture/boards.json"
eq "G13 the only board" "$(gate t2)" "BLOCKED dependencies TK-12"

reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "<p>Just a plain ask.</p>"
eq "F1 no dependency text" "$(gate t2 --buildable-strict)" "OK"
eq "F1 no listing GET" "$(listings)" "0"

reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY"; touch "$T/flags/inapp-deps-off"
eq "K1 the switch makes the arm inert" "$(gate t2)" "OK"

# G6: bin/preplan-candidates.sh still offers the text-blocked child once its
# blocker is busy (it reads the listing itself; this slice does not touch it).
# A plain-text body: its own line regex runs over the raw description, so an
# HTML body's footer is not at a line start there (a trait of that script).
reset; listing review
jq -c --arg d "Blocked-by: TK-12" '.tickets[1].description = $d' "$T/fixture/listing.json" > "$T/l2" && mv "$T/l2" "$T/fixture/listing.json"
OUT6=$(bash "$T/bin/preplan-candidates.sh" x-os 2>/dev/null)
grep -qP '^TK-2\tt2\tchild$' <<<"$OUT6" && ok || bad "G6 preplan-candidates must list the text-blocked child: [$OUT6]"

# No model on this path.
grep -nE 'agent-call|claude|anthropic' "$CORE" >/dev/null && bad "core.sh must make no LLM call" || ok

# ── M: mutants the suite must catch ─────────────────────────────────────────
cp "$T/bin/lib/inapp-deps/core.sh" "$T/core.orig"
printf '\ninapp_deps_eval() { printf "VERDICT\\tCLEAR\\t\\t\\t\\n"; }\n' >> "$T/bin/lib/inapp-deps/core.sh"
reset; ticket "$T/fixture/ticket-t2.json" t2 TK-2 todo "$CHILD_BODY"
[ "$(gate t2)" = "BLOCKED dependencies TK-12" ] && bad "M1 eval forced CLEAR must turn G1 red" || ok
cp "$T/core.orig" "$T/bin/lib/inapp-deps/core.sh"
sed -i 's/blocked\[- \]by|needs/blocked[- ]by/' "$T/bin/lib/inapp-deps/core.sh"
cmp -s "$T/core.orig" "$T/bin/lib/inapp-deps/core.sh" && bad "M2 the needs mutant did not apply"
ticket "$LF" t2 TK-2 todo "Needs: TK-14"
[ "$(lines)" = "TK-14" ] && bad "M2 line_re without needs must turn P2 red" || ok
cp "$T/core.orig" "$T/bin/lib/inapp-deps/core.sh"
eq "M restored" "$(lines)" "TK-14"

echo "inapp-text-deps.bh-3963: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
