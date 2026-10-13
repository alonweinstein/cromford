# shellcheck shell=bash
# tests/lib/driver-shape.sh — the structural shape of a split DRIVER: it calls
# its stage bodies and does not carry them. Sourced by the split-layout suites
# (tests/rb-split-layout.bh-572-test.sh, tests/rt-split-layout-test.sh), never
# executed. Not a suite: tests/*.sh does not glob tests/lib/.
#
# WHY THIS AND NOT A LINE COUNT (BH-5228). The drivers used to be held under a
# line ceiling (run-build.sh 400, run-triage.sh 380). A ceiling is a proxy: it
# fails a driver that grew by honest dispatch lines and passes a slice body that
# happens to fit under it. What the ceiling was standing in for is three facts
# about the text, and this file checks those directly:
#
#   S1  the driver defines no stage function. S1 is an ALLOWLIST:
#       DRIVER_SHAPE_ALLOW_FNS holds the exact names (space-separated, no
#       globs) of the helpers the driver may define, and any other function
#       fails whatever its name, so a slice body pasted in under a fresh,
#       unprefixed name is refused. Unset means an empty list. A listed name
#       still fails when it starts with <prefix> or a stage module defines it:
#       the list cannot whitelist a shadow of the module's function.
#   S2  no `# >>> <name>` marker (the whole marker text) that a stage module
#       opens is opened again in the driver: a moved block pasted back keeps
#       its marker, and reader suites extract blocks by marker, so two copies
#       is a silent fork.
#   S3  no run of DRIVER_SHAPE_RUN (default 5) consecutive code lines of the
#       driver appears, consecutively and verbatim, in a stage module: a slice
#       body pasted inline without its marker is still a copy of the module's
#       text. Blank and comment lines are skipped on both sides, leading and
#       trailing whitespace is trimmed, so re-indenting a pasted body does not
#       hide it.
#
# Usage: [DRIVER_SHAPE_ALLOW_FNS="a b"] driver_shape <driver> <entry-prefix> <module>...
#   prints one line per violation; rc 0 when there are none, 1 otherwise,
#   2 when the driver or a module cannot be read (never a vacuous green).
driver_shape() {
  local drv="$1" pfx="$2" m rc=0 out
  shift 2
  [ -r "$drv" ] || { echo "driver_shape: cannot read $drv"; return 2; }
  [ "$#" -gt 0 ] || { echo "driver_shape: no stage modules named"; return 2; }
  for m in "$@"; do [ -r "$m" ] || { echo "driver_shape: cannot read $m"; return 2; }; done

  # S1
  out=$(awk -v pfx="$pfx" -v allow="${DRIVER_SHAPE_ALLOW_FNS:-}" '
    BEGIN { na=split(allow, al, /[[:space:]]+/); for (i=1; i<=na; i++) if (al[i] != "") ok[al[i]]=1 }
    function fname(s) { if (!match(s, /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/)) return ""
      s=substr(s, 1, RLENGTH); sub(/^[[:space:]]*(function[[:space:]]+)?/, "", s); sub(/[[:space:]]*\(\)$/, "", s); return s }
    FILENAME != drv { f=fname($0); if (f != "") mod[f]=1; next }
    { f=fname($0); if (f == "") next
      if ((f in mod) || index(f, pfx) == 1) printf "S1: driver line %d defines %s(), a stage function: it lives in its module\n", FNR, f
      else if (!(f in ok)) printf "S1: driver line %d defines %s(), not on this driver'"'"'s allowlist: a stage function lives in its module\n", FNR, f }
  ' drv="$drv" "$@" "$drv")
  [ -z "$out" ] || { rc=1; printf '%s\n' "$out"; }

  # S2
  out=$(awk '
    FNR==NR { if (match($0, /^[[:space:]]*# >>> /)) { k=substr($0, RLENGTH+1); sub(/[[:space:]]+$/, "", k); mod[k]=1 }; next }
    match($0, /^[[:space:]]*# >>> /) { k=substr($0, RLENGTH+1); sub(/[[:space:]]+$/, "", k)
      if (k in mod) printf "S2: driver line %d opens # >>> %s, a block a stage module already holds\n", FNR, k }
  ' <(cat "$@") "$drv")
  [ -z "$out" ] || { rc=1; printf '%s\n' "$out"; }

  # S3
  out=$(awk -v n="${DRIVER_SHAPE_RUN:-5}" '
    function code(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function skip(s) { return s == "" || substr(s, 1, 1) == "#" }
    FILENAME != drv { s=code($0); if (skip(s)) next
      w[FILENAME]=(c[FILENAME]++ ? w[FILENAME] "\034" : "") s
      if (c[FILENAME] > n) { sub(/^[^\034]*\034/, "", w[FILENAME]); c[FILENAME]=n }
      if (c[FILENAME] == n) seen[w[FILENAME]]=1
      next }
    { s=code($0); if (skip(s)) next
      dw=(dc++ ? dw "\034" : "") s; dl[dc]=FNR
      if (dc > n) { sub(/^[^\034]*\034/, "", dw) }
      if (dc >= n && (dw in seen)) { printf "S3: driver lines %d-%d repeat %d consecutive code lines of a stage module\n", dl[dc-n+1], FNR, n; hit++ } }
  ' drv="$drv" "$@" "$drv")
  [ -z "$out" ] || { rc=1; printf '%s\n' "$out" | head -5; }
  return "$rc"
}
