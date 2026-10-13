#!/bin/bash
# tests/lib/scratch-closure-lint.sh — the BH-4552 scratch-closure lint's
# counter and delta judge, moved here verbatim from
# tests/scratch-closure-lint.bh-4552-test.sh so tests/scratch-closure-lint-grace.bh-4632-test.sh
# drives the real lint() and not a copy. Sourced after tests/lib/scratch.sh and
# tests/lib/ratchet-delta.sh (it needs $T, $DIR, $NOTE and rd_*), never
# executed. Under tests/lib/, so the lint's own tests/*.sh scan never counts it.
#
# BH-4632: a raised suite whose every touching PR head was cut before the lint
# landed is graced by bin/lib/scratch-closure-grace.sh: its findings print with
# a WARN prefix after one grace line, and it does not fail the run. The knob
# resolves through bin/lib/lane-gate.sh against a registry rendered once into
# $T, so its default answers on a CI runner with no harness root.
#
# The new-line rule: a changed suite is also red on each hand-copy line whose
# trimmed text the base copy of that suite does not have (new_hand_lines), so an
# edit that keeps the count is still seen. Grace and the allow marker apply.

# SCL_LINT_REL — the lint suite whose introducing commit starts the grace.
SCL_LINT_REL="${SCL_LINT_REL:-tests/scratch-closure-lint.bh-4552-test.sh}"

# scl_grace_load — source the grace lib and lane-gate once; rc 1 if either is
# missing, which leaves every raised suite red.
scl_grace_load() {
  command -v scg_grace >/dev/null 2>&1 && command -v lane_knob >/dev/null 2>&1 && return 0
  if [ -z "${LANE_REGISTRY:-}" ]; then
    [ -s "$T/scl-lanes.json" ] || "$DIR/bin/lanes-build.sh" --to "$T/scl-lanes.json" >/dev/null 2>&1 || return 1
    LANE_REGISTRY="$T/scl-lanes.json"
  fi
  # shellcheck source=../../bin/lib/lane-gate.sh
  . "$DIR/bin/lib/lane-gate.sh" || return 1
  # shellcheck source=../../bin/lib/scratch-closure-grace.sh
  . "$DIR/bin/lib/scratch-closure-grace.sh" || return 1
}

# hand_copy_lines <file>... — "<file>\t<lineno>" per counted line.
hand_copy_lines() {
  [ "$#" -gt 0 ] || return 0
  awk '
    FNR == 1 { inloop = 0; counted = 0; listlib = 0 }
    /^[[:space:]]*#/ { next }
    /scratch_install_closure/ { next }
    {
      cp = ($0 ~ /(^|[;&|({[:space:]])(cp[[:space:]]|install[[:space:]]+-)/)
      if (cp && $0 ~ /bin\/lib\/[^[:space:]"'\'']*\.sh/) { print FILENAME "\t" FNR; next }
      if ($0 ~ /swf_install[[:space:]]/ && $0 ~ /bin\/lib\//) { print FILENAME "\t" FNR; next }
      if ($0 ~ /(^|[;&|({[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]/ && $0 ~ /\.sh/) {
        inloop = 1; counted = 0; listlib = ($0 ~ /bin\/lib\//)
      }
      if (inloop && !counted && ((cp && $0 ~ /bin\/lib\//) || (listlib && $0 ~ /swf_install/))) {
        print FILENAME "\t" FNR; counted = 1
      }
      if (inloop && $0 ~ /(^|[;&|[:space:]])done([;&|)[:space:]]|$)/) inloop = 0
    }
  ' "$@"
}

# counts <root> <rel>... — "<rel>\t<n>" for each <rel> that exists under <root>.
counts() {
  local root="$1" rel n; shift
  for rel in "$@"; do
    [ -f "$root/$rel" ] || continue
    n=$(hand_copy_lines "$root/$rel" | grep -c .)
    printf '%s\t%s\n' "$rel" "$n"
  done
}

# allowed <file> — the marker with a non-empty reason.
allowed() { grep -qE '^[[:space:]]*#[[:space:]]*scratch-closure-allow:[[:space:]]*[^[:space:]]' "$1"; }

# new_hand_lines <base-file|-> <head-file> — the head line numbers of hand-copy
# lines whose whitespace-trimmed text has no unused match in the base (a
# multiset). A missing base means every head hand line is new.
new_hand_lines() {
  local base="$1" head="$2" bl="" hl
  hl=$(hand_copy_lines "$head" | cut -f2 | tr '\n' ' ')
  [ -n "${hl// /}" ] || return 0
  [ "$base" != - ] && [ -f "$base" ] && bl=$(hand_copy_lines "$base" | cut -f2 | tr '\n' ' ')
  if [ -z "${bl// /}" ]; then tr ' ' '\n' <<< "$hl" | grep . ; return 0; fi
  awk -v bl="$bl" -v hl="$hl" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { n = split(bl, a, " "); for (i = 1; i <= n; i++) wb[a[i]] = 1
            n = split(hl, a, " "); for (i = 1; i <= n; i++) wh[a[i]] = 1 }
    FNR == 1 { f++ }
    f == 1 { if (FNR in wb) left[trim($0)]++; next }
    FNR in wh { t = trim($0); if (left[t] > 0) left[t]--; else print FNR }
  ' "$base" "$head"
}

# lint <repo> — red per changed suite whose hand-copy count this diff raised, or
# that has a hand-copy line the base does not have. Only suites that differ from
# the base (or are new) are looked at; the rest sit on both sides and cancel.
lint() {
  local repo="$1" base w rel head was bad=0 changed fresh nf n pfx
  local -A raised=()
  base=$(rd_base "$repo") || { echo "$base"; return 1; }
  changed=$( { git -C "$repo" diff --name-only "$base" -- 'tests/*.sh' 'tests/mc/*.sh'
               git -C "$repo" status --porcelain --untracked-files=all -- tests | sed -n 's/^?? //p'; } \
             | grep -E '^tests/(mc/)?[^/]+\.sh$' | LC_ALL=C sort -u)
  [ -n "$changed" ] || return 0
  w=$(mktemp -d "$T/lint-base.XXXXXX") || return 1
  mapfile -t rels <<< "$changed"
  rd_tree "$repo" "$base" "$w/tree" "${rels[@]}" || { echo "cannot read tests/ at base $base"; return 1; }
  counts "$w/tree" "${rels[@]}" > "$w/base.tsv"
  counts "$repo" "${rels[@]}" > "$w/head.tsv"
  while IFS=$'\t' read -r rel head was; do raised[$rel]="$head"$'\t'"$was"; done < <(rd_delta "$w/head.tsv" "$w/base.tsv")
  for rel in "${rels[@]}"; do
    [ -f "$repo/$rel" ] || continue
    allowed "$repo/$rel" && continue
    fresh=$(new_hand_lines "$w/tree/$rel" "$repo/$rel")
    [ -n "${raised[$rel]:-}" ] || [ -n "$fresh" ] || continue
    head=0; was=0
    [ -z "${raised[$rel]:-}" ] || IFS=$'\t' read -r head was <<< "${raised[$rel]}"
    nf=$(grep -c . <<< "$fresh")
    n=$((head - was)); [ "$nf" -le "$n" ] || n=$nf
    pfx=""
    if ! scl_grace_load; then
      echo "$rel: scratch-closure grace unavailable (cannot load bin/lib/scratch-closure-grace.sh or bin/lib/lane-gate.sh), judged as raised"
    elif scg_grace "$repo" "$base" "$rel" "$SCL_LINT_REL" "$n"; then
      pfx="WARN "
    fi
    if [ -n "${raised[$rel]:-}" ]; then
      while IFS=$'\t' read -r _ n; do
        echo "$pfx$rel:$n: hand-copies bin/lib files ($head such lines, base fewer): use scratch_install_closure <script> <dest>, or add '# scratch-closure-allow: <reason>' (see $NOTE)"
      done < <(cd "$repo" && hand_copy_lines "$rel")
    else
      while read -r n; do
        echo "$pfx$rel:$n: new or edited hand-copied bin/lib list: use scratch_install_closure <script> <dest>, or add '# scratch-closure-allow: <reason>' (see $NOTE)"
      done <<< "$fresh"
    fi
    [ -n "$pfx" ] || bad=1
  done
  return "$bad"
}
