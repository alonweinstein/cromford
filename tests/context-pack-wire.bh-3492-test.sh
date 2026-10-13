#!/bin/bash
# tests/context-pack-wire.bh-3492-test.sh — the shell side of the context-pack
# wire (bin/lib/context-pack.sh) and the plan.sh child plan tripwire hook.
# Implements the BH-3478.0 acceptance (the ticket body calls this suite
# context-pack-wire.bh-3478-test.sh; it is named for its own ticket key).
#
# No network anywhere: _jobs_req is always a shell stub driven by STUB_HTTP /
# STUB_BODY / STUB_RC, mirroring bin/lib/jobs/req.sh (2xx->0, 404->2, 409->9,
# other->1, unreachable -> rc 1 with JOBS_HTTP empty). The hook block is
# extracted VERBATIM from the flattened pipeline (tests/lib/rb-all.sh) and run
# in a scratch harness.
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/context-pack-wire.bh-3492-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
LIB="$DIR/bin/lib/context-pack.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }


# The stub, as text, so a fresh bash (the hook and loader cases) gets the same one.
STUB='_jobs_req() {
  [ -n "${STUB_HTTP+x}" ] && JOBS_HTTP="$STUB_HTTP"
  printf "%s %s\n" "$1" "$2" >> "$T/calls"
  [ -n "${3:-}" ] && printf "%s" "$3" > "$T/body"
  printf "%s" "${STUB_BODY:-}"
  return "${STUB_RC:-0}"
}'
eval "$STUB"
export T

reset() { rm -f "$T/calls" "$T/body" "$T/out"; : > "$T/calls"; }
called() { [ -s "$T/calls" ]; }

# ============================================================================
# P. cp_put: 2xx/400/413/500/unreachable -> 0/3/3/1/1
# ============================================================================
printf 'line one\n"quoted" \\ back\ttab\n' > "$T/pack.md"
put() { # put <http> <rc> [pack] [sha] [child] [parent] -> sets PRC, stdout in $T/out
  reset
  ( STUB_HTTP="$1" STUB_RC="$2" STUB_BODY='{}' JOBS_BOX="" JOBS_HTTP="${PRE_HTTP:-}"
    . "$LIB"; cp_put cromford "${5-BH-2}" "${6-BH-1}" "${4-abc123}" "${3:-$T/pack.md}" ) > "$T/out" 2>/dev/null
  PRC=$?
}

put 200 0
eq P1.rc "$PRC" 0
eq P1.stdout "$(cat "$T/out")" published
eq P1.call "$(cat "$T/calls")" "POST /api/context-packs"
eq P1.project "$(jq -r .project "$T/body")" cromford
eq P1.ticket_key "$(jq -r .ticket_key "$T/body")" BH-2
eq P1.parent_key "$(jq -r .parent_key "$T/body")" BH-1
eq P1.base_sha "$(jq -r .base_sha "$T/body")" abc123
jq -e 'has("box")' "$T/body" >/dev/null && bad "P1: box key sent with JOBS_BOX empty" || ok
jq -j .pack_md "$T/body" > "$T/sent.md"
cmp -s "$T/sent.md" "$T/pack.md" && ok || bad "P1: pack_md not byte-equal to the pack file"

put 400 1;  eq P2.rc "$PRC" 3
head -c 70000 /dev/zero | tr '\0' a > "$T/big.md"
put 413 1 "$T/big.md"
eq P3.rc "$PRC" 3
eq P3.sent-bytes "$(jq -j .pack_md "$T/body" | wc -c | tr -d ' ')" 70000
put 409 9;  eq P3b.409-rc "$PRC" 3
put 404 2;  eq P3c.404-rc "$PRC" 3
put 500 1;  eq P4.rc "$PRC" 1
PRE_HTTP=400 put "" 1
eq P5.unreachable-with-stale-400 "$PRC" 1
# P5b: a client that leaves JOBS_HTTP alone on a transport failure
reset
( unset STUB_HTTP; STUB_RC=1 JOBS_HTTP=400; . "$LIB"; cp_put cromford BH-2 BH-1 x "$T/pack.md" ) >/dev/null 2>&1
eq P5b.stale-400-not-refused "$?" 1
put 200 0 "" ""
eq P6.rc-empty-sha "$PRC" 0
jq -e 'has("base_sha")' "$T/body" >/dev/null && bad "P6: base_sha sent while empty" || ok
put 200 0 "" abc BH-1 BH-1
eq P6.child-eq-parent "$PRC" 1
called && bad "P6: child==parent reached the network" || ok
: > "$T/empty.md"
put 200 0 "$T/empty.md"
eq P6.empty-pack "$PRC" 1
called && bad "P6: empty pack reached the network" || ok
put 200 0 "" abc "BH 2"
eq P6.bad-token "$PRC" 1
called && bad "P6: bad token reached the network" || ok
reset
( STUB_HTTP=200 STUB_RC=0 JOBS_BOX=box-7; . "$LIB"; cp_put cromford BH-2 BH-1 x "$T/pack.md" ) >/dev/null 2>&1
eq P7.box "$(jq -r .box "$T/body")" box-7

# ============================================================================
# F. cp_fetch: 200/404/500/garbage/self-parent -> 0/2/1/1/2, files only on 0
# ============================================================================
fetch() { # fetch <http> <rc> <body> [key] -> FRC
  reset
  ( STUB_HTTP="$1" STUB_RC="$2" STUB_BODY="$3"; . "$LIB"; cp_fetch cromford "${4:-BH-2}" "$T/f/dst.md" ) > "$T/out" 2>/dev/null
  FRC=$?
}
none_written() { [ ! -e "$T/f/dst.md" ] && [ ! -e "$T/f/dst.md.parent" ] && ok || bad "$1: dst written on a non-zero rc"; }
mkdir -p "$T/f"

fetch 200 0 '{"context_pack":{"project":"cromford","ticket_key":"BH-2","parent_key":"BH-1","pack_md":"x\ny"}}'
eq F1.rc "$FRC" 0
eq F1.call "$(cat "$T/calls")" "GET /api/context-packs?project=cromford&key=BH-2"
printf 'x\ny' > "$T/want.md"
cmp -s "$T/f/dst.md" "$T/want.md" && ok || bad "F1: dst not byte-equal to pack_md"
eq F1.parent "$(cat "$T/f/dst.md.parent")" BH-1
grep -q tmp <<<"$(ls "$T/f")" && bad "F1: temp files left behind" || ok
# trailing newline survives byte-exact
fetch 200 0 '{"context_pack":{"parent_key":"BH-1","pack_md":"a\nb\n"}}'
printf 'a\nb\n' > "$T/want2.md"
cmp -s "$T/f/dst.md" "$T/want2.md" && ok || bad "F1b: trailing newline not preserved"
rm -f "$T/f/"*

fetch 404 2 '';                        eq F2.rc "$FRC" 2; none_written F2
fetch 500 1 'oops';                    eq F3.rc "$FRC" 1; none_written F3
fetch 200 0 'not json';                eq F4.garbage "$FRC" 1; none_written F4a
fetch 200 0 '{}';                      eq F4.empty-obj "$FRC" 1; none_written F4b
fetch 200 0 '{"context_pack":null}';   eq F4.null "$FRC" 1; none_written F4c
fetch 200 0 '{"context_pack":{"parent_key":"BH-1","pack_md":""}}'; eq F4.empty-pack "$FRC" 1; none_written F4d
fetch 200 0 '{"context_pack":{"parent_key":"","pack_md":"x"}}';    eq F4.empty-parent "$FRC" 1; none_written F4e
fetch 200 0 '{"context_pack":{"parent_key":"BH-2","pack_md":"x"}}'; eq F5.self-parent "$FRC" 2; none_written F5
# F6: an earlier run's files survive a 1 and a 2 untouched
printf 'old' > "$T/f/dst.md"; printf 'OLD-1' > "$T/f/dst.md.parent"
fetch 500 1 ''
eq F6.rc1 "$FRC" 1
eq F6.dst-after-1 "$(cat "$T/f/dst.md")" old
fetch 200 0 '{"context_pack":{"parent_key":"BH-2","pack_md":"new"}}'
eq F6.rc2 "$FRC" 2
eq F6.dst-after-2 "$(cat "$T/f/dst.md")" old
eq F6.parent-after-2 "$(cat "$T/f/dst.md.parent")" OLD-1
rm -f "$T/f/"*

# ============================================================================
# R. cp_preamble
# ============================================================================
WARM="WARM START: this ticket is a split child of BH-77. The parent's planner already mapped the codebase; the context pack below is that map. Do NOT re-survey what the pack already covers — read only the code this slice needs that the pack lacks, then write the plan."
printf 'map line 1\nmap line 2\n' > "$T/r.md"; echo BH-77 > "$T/r.md.parent"
( . "$LIB"; cp_preamble "$T/r.md" ) > "$T/pre.out"; RRC=$?
eq R1.rc "$RRC" 0
eq R1.line1 "$(sed -n 1p "$T/pre.out")" "$WARM"
eq R1.line2 "$(sed -n 2p "$T/pre.out")" ""
tail -n +3 "$T/pre.out" | cmp -s - "$T/r.md" && ok || bad "R1: remainder is not the pack byte for byte"
rm -f "$T/r.md.parent"
( . "$LIB"; cp_preamble "$T/r.md" ) > "$T/pre.out"; RRC=$?
eq R2.no-parent-rc "$RRC" 1; [ -s "$T/pre.out" ] && bad "R2: printed with no parent" || ok
echo BH-77 > "$T/r.md.parent"; : > "$T/r.md"
( . "$LIB"; cp_preamble "$T/r.md" ) > "$T/pre.out"; RRC=$?
eq R2.empty-pack-rc "$RRC" 1; [ -s "$T/pre.out" ] && bad "R2: printed with an empty pack" || ok

# ============================================================================
# L. lazy client load and the empty-root refusal (fresh bash: no stub defined)
# ============================================================================
mkdir -p "$T/l1/bin/lib/jobs"
cp "$LIB" "$T/l1/bin/lib/context-pack.sh"
: > "$T/l1/bin/lib/jobs/req.sh"
# a jobs-client that, like the real one, turns nounset + pipefail on
printf 'set -uo pipefail\n%s\n' "$STUB" > "$T/l1/bin/jobs-client.sh"
reset
env -u HARNESS -u H T="$T" STUB_HTTP=404 STUB_RC=2 bash -c '
  set +u; set +o pipefail
  . "$T/l1/bin/lib/context-pack.sh"
  cp_fetch cromford BH-2 "$T/l1/dst"; echo "rc=$?"
  set -o | awk '\''$1=="pipefail"||$1=="nounset"{print $1"="$2}'\''' > "$T/l1.out" 2>&1
eq L1.rc "$(grep '^rc=' "$T/l1.out")" rc=2
eq L1.reached "$(cat "$T/calls")" "GET /api/context-packs?project=cromford&key=BH-2"
grep -q '^pipefail=off$' "$T/l1.out" && grep -q '^nounset=off$' "$T/l1.out" && ok \
  || bad "L1: caller shell options not restored: $(tr '\n' ' ' < "$T/l1.out")"
# L1b: lib alone, client found through $HARNESS
mkdir -p "$T/l1b"; cp "$LIB" "$T/l1b/context-pack.sh"; reset
env -u H HARNESS="$T/l1" T="$T" STUB_HTTP=404 STUB_RC=2 bash -c '
  . "$T/l1b/context-pack.sh"; cp_fetch cromford BH-2 "$T/l1b/dst"; echo "rc=$?"' > "$T/l1b.out" 2>&1
eq L1b.rc "$(grep '^rc=' "$T/l1b.out")" rc=2
called && ok || bad "L1b: client under \$HARNESS was not loaded"
# L2: empty root, nothing beside the lib -> rc 1, nothing created
mkdir -p "$T/l2/cwd"; cp "$LIB" "$T/l2/context-pack.sh"; reset
( cd "$T/l2/cwd" && env HARNESS= H= T="$T" bash -c '
  . "$T/l2/context-pack.sh"
  cp_put cromford BH-2 BH-1 "" "$T/pack.md"; echo "put=$?"
  cp_fetch cromford BH-2 dst.md; echo "fetch=$?"' ) > "$T/l2.out" 2>&1
eq L2.put "$(grep '^put=' "$T/l2.out")" put=1
eq L2.fetch "$(grep '^fetch=' "$T/l2.out")" fetch=1
[ -z "$(ls -A "$T/l2/cwd")" ] && ok || bad "L2: files created in \$PWD: $(ls -A "$T/l2/cwd")"
called && bad "L2: reached a client with an empty root" || ok

# ============================================================================
# H. the plan.sh hook, extracted from the flattened pipeline
# ============================================================================
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all"; exit 1; }
awk 'index($0, "# >>> child plan tripwire")==1 {f=1;next} index($0, "# <<< child plan tripwire")==1 {exit} f' \
  "$RB" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "H0: could not extract the child plan tripwire block"
SG=$(grep -n '^# <<< size gate$' "$RB" | head -n1 | cut -d: -f1)
NX=$(awk -v s="${SG:-0}" 'NR>s && /^# (>>>|<<<) /{print NR": "$0; exit}' "$RB")
[ -n "$SG" ] && [ "${NX#*: }" = "# >>> child plan tripwire (BH-3478)" ] && ok \
  || bad "H0: first marker after '# <<< size gate' (line ${SG:-missing}) is [${NX:-none}]"

cat > "$T/drive.sh" <<EOF
set -uo pipefail
STAMP() { echo TS; }
$STUB
. "\$1"
echo "\$?" > "\$T/blockrc"
echo after > "\$T/after"
EOF
hsetup() { # fresh scratch harness + build dir
  rm -rf "$T/h" "$T/b" "$T/after" "$T/blockrc"; mkdir -p "$T/h/bin/lib" "$T/b"
  cp "$LIB" "$T/h/bin/lib/context-pack.sh"; : > "$T/b/pipeline.log"; reset
}
seed() { printf 'the map\n' > "$T/b/context-pack.md"; echo "$1" > "$T/b/context-pack.md.parent"; }
checker() { # checker <body of cpt_check>
  printf 'cpt_check() { %s; }\n' "$1" > "$T/h/bin/lib/child-plan-tripwire.sh"
}
hrun() { # hrun [VAR=val ...] -> HRC
  env -u CP_PARENT HARNESS="$T/h" PROJECT=cromford KEY=BH-3492 BUILD="$T/b" T="$T" "$@" \
    bash "$T/drive.sh" "$T/block.sh" > "$T/h.out" 2>&1
  HRC=$?
  [ "$(cat "$T/blockrc" 2>/dev/null)" = 0 ] || HRC="block-rc:$(cat "$T/blockrc" 2>/dev/null)"
}
logn() { grep -c 'CHILD_PLAN_TRIPWIRE' "$T/b/pipeline.log"; }
after_ran() { [ -s "$T/after" ] && ok || bad "$1: code after the block did not run"; }

hsetup; hrun STUB_HTTP=404 STUB_RC=2
eq H1.rc "$HRC" 0; eq H1.lines "$(logn)" 0; after_ran H1
[ -e "$T/b/context-pack.md" ] && bad "H1: context-pack.md written with no pack" || ok
eq H1.fetched "$(cat "$T/calls")" "GET /api/context-packs?project=cromford&key=BH-3492"

hsetup; seed BH-3478; hrun
eq H2.rc "$HRC" 0; eq H2.lines "$(logn)" 1; after_ran H2
eq H2.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b/pipeline.log")" "TS [cromford/BH-3492] CHILD_PLAN_TRIPWIRE skipped (no checker)"
called && bad "H2: fetched although the pack was already in \$BUILD" || ok

hsetup; seed BH-3478; checker 'echo "FIRE 71% of parent"; return 1'; hrun
eq H3.rc "$HRC" 0; after_ran H3
eq H3.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b/pipeline.log")" "TS [cromford/BH-3492] CHILD_PLAN_TRIPWIRE FIRE 71% of parent"
hsetup; seed BH-3478; checker 'echo "FIRE 71% of parent"; exit 1'; hrun
eq H3b.exit-rc "$HRC" 0; after_ran H3b
eq H3b.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b/pipeline.log")" "TS [cromford/BH-3492] CHILD_PLAN_TRIPWIRE FIRE 71% of parent"
hsetup; seed BH-3478; checker 'echo OK one; echo OK two; echo OK three'; hrun
eq H3c.chatty-lines "$(logn)" 1; after_ran H3c
hsetup; seed BH-3478; checker 'return 0'; hrun
eq H3d.silent "$(grep CHILD_PLAN_TRIPWIRE "$T/b/pipeline.log")" "TS [cromford/BH-3492] CHILD_PLAN_TRIPWIRE UNMEASURED checker printed nothing"

hsetup; rm -f "$T/h/bin/lib/context-pack.sh"; hrun STUB_HTTP=200 STUB_RC=0 \
  STUB_BODY='{"context_pack":{"parent_key":"BH-3478","pack_md":"m"}}'
eq H4.rc "$HRC" 0; eq H4.lines "$(logn)" 0; after_ran H4
called && bad "H4: fetched with no context-pack.sh on the box" || ok

hsetup; checker 'echo "OK parent=$3"'
hrun STUB_HTTP=200 STUB_RC=0 STUB_BODY='{"context_pack":{"parent_key":"BH-3478","pack_md":"the map"}}'
eq H5.rc "$HRC" 0; after_ran H5
eq H5.pack "$(cat "$T/b/context-pack.md" 2>/dev/null)" "the map"
eq H5.parent-file "$(cat "$T/b/context-pack.md.parent" 2>/dev/null)" BH-3478
eq H5.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b/pipeline.log")" "TS [cromford/BH-3492] CHILD_PLAN_TRIPWIRE OK parent=BH-3478"

hsetup; checker 'echo "OK parent=$3"'; hrun CP_PARENT=BH-9
eq H6.rc "$HRC" 0
called && bad "H6: fetched although CP_PARENT was preset" || ok
eq H6.line "$(grep CHILD_PLAN_TRIPWIRE "$T/b/pipeline.log")" "TS [cromford/BH-3492] CHILD_PLAN_TRIPWIRE OK parent=BH-9"

hsetup; checker 'echo FIRE'; hrun STUB_HTTP= STUB_RC=1
eq H7.rc "$HRC" 0; eq H7.lines "$(logn)" 0; after_ran H7
[ -e "$T/b/context-pack.md" ] && bad "H7: pack file written on an outage" || ok

echo "context-pack-wire: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
