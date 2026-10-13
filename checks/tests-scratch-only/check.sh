#!/bin/bash
# checks/tests-scratch-only/check.sh
#
# FAMILY b3957447980a — "a test or a bin script deletes a path it does not own".
# This is an INCIDENT family, not a miner family: it was not ruled by
# bin/rule-miner.sh from repeated review findings, it was earned once, on
# 2026-09-15 at 16:50Z, when a tests/*.sh that never sourced the scratch lib
# re-derived $H as the LIVE harness root and rm -rf'd it (#388, root cause #404,
# scope #394).
#
# WHAT IT CATCHES. Three rules:
#   R1  a top-level test (tests/*.sh) that does not source tests/lib/scratch.sh
#       BEFORE its first mktemp / rm / trap / leading cd. Comments, blank lines,
#       set …, DIR=$(cd … && pwd) and plain assignments above the source line
#       are fine — a mechanical port keeps its preamble.
#   R2  a top-level test with a recursive rm, in command position, whose FIRST
#       argument is a $VAR / ${VAR} expansion for a VAR that is neither T nor
#       SCRATCH. Only the lib hands those two out. Heredoc bodies are skipped.
#   R3  a bin/**/*.sh recursive rm whose first argument is a $HARNESS-derived
#       path — textually $HARNESS…/${HARNESS}…/$H/…/${H}…, or a $VAR the same
#       file assigns from a HARNESS-derived expression — with no
#       `case "$VAR" in "$HARNESS/…"*)` prefix guard in the six lines above it.
#       That guard is bin/run-build.sh:1177, which must stay silent here.
#
# TWO MODES:
#   check.sh                 the normalized added-line stream on stdin
#                            (path<TAB>line<TAB>text) — R3 only, bin/ paths only.
#                            bin/checks-run.sh drops every tests/ path before a
#                            check sees it, so R1 and R2 cannot fire in diff mode.
#   check.sh --tree <root>   a whole checkout — R1 + R2 + R3. This is the
#                            complete pass, and the one CI wires up.
#
# Prints "path:line<TAB>reason (family b3957447980a)" per hit, sorted.
# rc 0 = clean, 1 = hits, 2 = could not run — and "could not run" includes an awk
# stage that DIED, in either mode. Empty output from a scan that never happened
# is not a clean tree, and this check fails closed on it rather than reporting a
# pass it never earned.
#
# DETECTION ONLY: it reads a stream or a tree and writes stdout. No git write,
# no gh call, no edit path, and above all no rm of its own — a checker for
# deletions that deletes would be the joke that writes itself.
#
# No interval quantifiers ({n}) anywhere in the patterns: /usr/bin/awk is mawk on
# Debian and on Ubuntu runners, and older mawk silently does not support them —
# a pattern that quietly matches nothing is the exact failure this catalog
# exists to prevent.
set -uo pipefail
FAMILY=b3957447980a
SELF_NAME=tests-scratch-only

usage() {
  echo "$SELF_NAME: usage: check.sh [-]            read the added-line stream on stdin (R3)" >&2
  echo "$SELF_NAME:        check.sh --tree <root>  scan a whole checkout (R1 + R2 + R3)" >&2
  exit 2
}

# ── the shared scanner ──────────────────────────────────────────────────────
# One program, two entry modes. mode=r12 reads test FILES (R1 + R2); mode=r3
# reads the path<TAB>line<TAB>text stream both modes normalize to (R3).
AWK_PROG='
# Split a line into command-position segments. Single quotes become separators
# because the wipe shapes that matter live inside them (trap "rm -rf $H", and
# bash -c "rm -rf $1/calls"); ; & | ( ) and whitespace-delimited { } are the
# ordinary ones. Double quotes are NOT split on: "$VAR" must survive intact.
function segmentize(s,   t) {
  t = s
  gsub(Q, "\n", t)
  gsub(/[;&|()]/, "\n", t)
  gsub(/\{[ \t]/, "\n", t)
  gsub(/[ \t]\}/, "\n", t)
  return t
}

# The identifier a first argument expands, or "" when it expands nothing.
# $T/x -> T, ${T:?}/x -> T, $1/calls -> 1, /root/x -> "", $(cmd) -> "".
function varname(a,   n) {
  if (a !~ /^\$/) return ""
  n = a
  sub(/^\$/, "", n)
  sub(/^\{/, "", n)
  sub(/[^A-Za-z0-9_].*$/, "", n)
  return n
}

# First argument of every RECURSIVE rm in command position on this line.
function rmargs(line, ARG,   t, n, segs, i, s, m, w, j, rec, a, cnt) {
  split("", ARG)
  cnt = 0
  t = segmentize(line)
  n = split(t, segs, "\n")
  for (i = 1; i <= n; i++) {
    s = segs[i]
    sub(/^[ \t]+/, "", s)
    while (s ~ /^(then|do|else|elif|if|while|until|!)[ \t]+/) sub(/^[^ \t]+[ \t]+/, "", s)
    if (s !~ /^rm[ \t]/) continue
    m = split(s, w, /[ \t]+/)
    j = 2; rec = 0
    while (j <= m && w[j] ~ /^-/) {
      if (w[j] ~ /^--/) { if (w[j] == "--recursive") rec = 1 }
      else if (w[j] ~ /^-[a-zA-Z]*[rR]/) rec = 1
      j++
    }
    if (!rec) continue
    if (j > m) continue
    a = w[j]
    gsub(/"/, "", a)
    cnt++
    ARG[cnt] = a
  }
  return cnt
}

# R1: what counts as "already handling its own scratch tree".
function is_trigger(line,   t, n, segs, i, s) {
  if (line ~ /mktemp/) return 1
  if (line ~ /^[ \t]*cd[ \t]/) return 1
  t = segmentize(line)
  n = split(t, segs, "\n")
  for (i = 1; i <= n; i++) {
    s = segs[i]
    sub(/^[ \t]+/, "", s)
    while (s ~ /^(then|do|else|elif|if|while|until|!)[ \t]+/) sub(/^[^ \t]+[ \t]+/, "", s)
    if (s ~ /^rm[ \t]/) return 1
    if (s ~ /^trap[ \t]/) return 1
  }
  return 0
}

function hasharness(s) {
  if (s ~ /\$\{?HARNESS\}?/) return 1
  if (s ~ /\$\{?H\}?"?\//) return 1
  if (s ~ /\/root\/harness/) return 1
  return 0
}

function hasguardprefix(s) {
  if (s ~ /\$\{?HARNESS\}?"?\//) return 1
  if (s ~ /\$\{?H\}?"?\//) return 1
  if (s ~ /\/root\/harness\//) return 1
  return 0
}

# ── R1 + R2, per test file ──────────────────────────────────────────────────
function flush1() {
  if (curf != "" && trig > 0 && (srcl == 0 || srcl > trig))
    printf "%s:%d\tR1: does not source tests/lib/scratch.sh before its first mktemp/rm/trap/cd — source the lib first so $T owns the scratch tree (family %s)\n", curf, trig, fam
}

function r12(   n, k, v, ARG, hd, tag) {
  if (inhd) {
    if ($0 ~ ("^[ \t]*" hdterm "[ \t]*$")) inhd = 0
    return
  }
  if ($0 ~ /^[ \t]*#/) return
  if (srcl == 0 && $0 ~ /(^|[ \t])(\.|source)[ \t]/ && $0 ~ /\/lib\/scratch\.sh/) srcl = FNR
  n = rmargs($0, ARG)
  for (k = 1; k <= n; k++) {
    v = varname(ARG[k])
    if (v == "" || v == "T" || v == "SCRATCH") continue
    printf "%s:%d\tR2: recursive rm on $%s, which is not proven to live under $T — use scratch_rm (family %s)\n", FILENAME, FNR, v, fam
    break
  }
  if (trig == 0 && is_trigger($0)) trig = FNR
  # Heredoc bodies are not code this check reads: a test that WRITES a fixture
  # script containing rm -rf "$H" is not itself deleting anything. <<< is a
  # herestring, not a heredoc, so it is neutralised before the tag is read, and
  # a single-quoted tag is normalised to the double-quoted spelling.
  hd = $0
  gsub(/<<</, "   ", hd)
  gsub(Q, "\"", hd)
  if (match(hd, /<<-?[ \t]*"?[A-Za-z_][A-Za-z0-9_]*/)) {
    tag = substr(hd, RSTART, RLENGTH)
    sub(/^<<-?[ \t]*"?/, "", tag)
    inhd = 1
    hdterm = tag
  }
}

# ── R3, over the path<TAB>line<TAB>text stream ──────────────────────────────
function flush3(   i, ln, t, nm, rest, v, k, n, gl, j, wtext, g2, m2, guarded, rem, ARG) {
  if (cur == "" || np == 0) return
  # Pass A: which names in THIS file carry a $HARNESS-derived value, and where
  # a prefix guard opens.
  for (i = 1; i <= np; i++) {
    ln = ORD[i]; t = TXT[ln]
    if (t ~ /^[ \t]*#/) continue
    if (match(t, /^[ \t]*(local[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) {
      nm = substr(t, RSTART, RLENGTH); rest = substr(t, RSTART + RLENGTH)
      sub(/^[ \t]*/, "", nm); sub(/^(local|export)[ \t]+/, "", nm); sub(/=$/, "", nm)
      if (hasharness(rest)) DER[nm] = 1
    }
    if (match(t, /(^|[ \t;])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]/)) {
      nm = substr(t, RSTART, RLENGTH); rest = substr(t, RSTART + RLENGTH)
      sub(/^.*for[ \t]+/, "", nm); sub(/[ \t]+in[ \t]$/, "", nm)
      if (hasharness(rest)) DER[nm] = 1
    }
    if (match(t, /case[ \t]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[ \t]+in/)) {
      v = substr(t, RSTART, RLENGTH)
      sub(/^case[ \t]+/, "", v); sub(/[ \t]+in$/, "", v)
      gsub(/["$]/, "", v); gsub(/[{}]/, "", v)
      CASEV[ln] = v
    }
  }
  # Pass B: the deletions themselves.
  for (i = 1; i <= np; i++) {
    ln = ORD[i]; t = TXT[ln]
    if (t ~ /^[ \t]*#/) continue
    n = rmargs(t, ARG)
    for (k = 1; k <= n; k++) {
      v = varname(ARG[k])
      if (v == "") continue
      if (v != "HARNESS" && v != "H" && !(v in DER)) continue
      guarded = 0
      for (j = 1; j <= np; j++) {
        gl = ORD[j]
        if (gl > ln || gl < ln - 6) continue
        if (!(gl in CASEV)) continue
        if (CASEV[gl] != v) continue
        # The pattern text of a case can sit on the case line itself or on the
        # arms between it and the rm, so the window is read as one string.
        wtext = ""
        for (m2 = 1; m2 <= np; m2++) {
          g2 = ORD[m2]
          if (g2 >= gl && g2 <= ln) wtext = wtext " " TXT[g2]
        }
        if (hasguardprefix(wtext)) { guarded = 1; break }
      }
      if (guarded) continue
      if (v == "HARNESS" || v == "H")
        rem = "bind the path to a variable and guard that — case \"$VAR\" in \"$HARNESS/...\"*) rm -rf \"$VAR\" ;; esac"
      else
        rem = "guard it — case \"$" v "\" in \"$HARNESS/...\"*) rm -rf \"$" v "\" ;; esac"
      printf "%s:%d\tR3: recursive rm on the $HARNESS-derived path $%s with no prefix guard — %s (family %s)\n", cur, ln, v, rem, fam
      break
    }
  }
}

function r3rec() {
  if ($1 != cur) {
    flush3()
    cur = $1; np = 0
    split("", ORD); split("", TXT); split("", DER); split("", CASEV)
  }
  np++
  ORD[np] = $2 + 0
  TXT[$2 + 0] = $3
}

BEGIN { Q = sprintf("%c", 39); if (mode == "r3") FS = "\t" }
mode == "r12" && FNR == 1 { flush1(); curf = FILENAME; trig = 0; srcl = 0; inhd = 0; hdterm = "" }
mode == "r12" { r12(); next }
mode == "r3"  { r3rec(); next }
END { if (mode == "r12") flush1(); else flush3() }
'

# ── mode dispatch ───────────────────────────────────────────────────────────
MODE=stdin
ROOT=""
case "${1:-}" in
  ""|-)   MODE=stdin ;;
  --tree) MODE=tree; ROOT="${2:-}" ;;
  *)      usage ;;
esac

if [ "$MODE" = tree ]; then
  if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "$SELF_NAME: could not run — no such tree '$ROOT'" >&2
    exit 2
  fi
  if [ ! -d "$ROOT/tests" ] || [ ! -d "$ROOT/bin" ]; then
    echo "$SELF_NAME: could not run — '$ROOT' has no tests/ and bin/ to scan" >&2
    exit 2
  fi
  # Every scanner stage carries `|| exit 3`, and the subshell's rc is read below.
  # Without that, a stage that DIED (mawk rejecting a pattern, an unreadable
  # file, a find that could not descend) leaves $OUT empty and the script exits
  # 0 — a scan that never happened reading as a clean tree, which is the exact
  # vacuous green this catalog exists to refuse. pipefail is already set, so the
  # find|xargs|awk pipeline reports a failure at any stage.
  OUT=$(
    cd "$ROOT" || exit 3
    FILES=()
    for F in tests/*.sh tests/mc/*.sh; do [ -f "$F" ] && FILES+=("$F"); done
    if [ "${#FILES[@]}" -gt 0 ]; then
      awk -v mode=r12 -v fam="$FAMILY" "$AWK_PROG" "${FILES[@]}" || exit 3
    fi
    find bin -name '*.sh' -type f -print0 2>/dev/null \
      | xargs -0 -r awk '{ printf "%s\t%d\t%s\n", FILENAME, FNR, $0 }' \
      | awk -v mode=r3 -v fam="$FAMILY" "$AWK_PROG" || exit 3
  )
  SCAN_RC=$?
else
  # bin/checks-run.sh already dropped tests/, specs and comment-only lines. The
  # bin/ filter here is what makes diff mode R3-only and says so out loud.
  OUT=$(awk -F'\t' '$1 ~ /^bin\//' | awk -v mode=r3 -v fam="$FAMILY" "$AWK_PROG")
  SCAN_RC=$?
fi

# Same answer in both modes: a scanner that could not run is rc 2 with a reason
# on stderr. bin/checks-run.sh turns that into CHECK-ERROR and fails the run.
if [ "$SCAN_RC" -gt 1 ]; then
  echo "$SELF_NAME: could not run — the scanner exited $SCAN_RC; no clean result can be claimed from it" >&2
  exit 2
fi

OUT=$(printf '%s' "$OUT" | grep -v '^$' | LC_ALL=C sort -t: -k1,1 -k2,2n)
[ -n "$OUT" ] || exit 0
printf '%s\n' "$OUT"
exit 1
