#!/bin/bash
# tests/lib/rendered.sh — the ONE way a suite gets the repo's RENDERED files.
# Sourced after tests/lib/scratch.sh, never executed; needs $T and $DIR.
#
#   rendered_registry          prints a path to this repo's catalog/lanes.json
#   rendered_cron <box>        prints a path to this repo's cron/<box>.cron
#   rendered_env               prints a path to env-templates/global.env.example
#   rendered_boxes             prints every box id, one per line
#
# WHY (BH-1247). Those twelve files are GENERATED from cron/lanes/,
# cron/boxes/, catalog/lanes.d/ and env-templates/lanes/, and they are not
# committed — so `$DIR/catalog/lanes.json` is present in one checkout and absent
# in the next, and a suite that opens it directly passes or fails on whether
# somebody happened to have rendered. Every suite that needs one renders it,
# into its own $T, through here.
#
# NOTHING IS WEAKENED BY THIS. A suite asserting "cron/hub.cron runs lane X" is
# asserting something about what the hub will actually run, and the render IS
# what the hub will run — bin/render-crontab.sh produces its base with the very
# command below. The file the assertion reads changed location; the claim did
# not. What a suite must NOT do is fall back to "skip if absent": that turns a
# renderer regression into a green run, which is the failure mode this library
# exists to make impossible, so every helper here FAILS LOUDLY instead.
#
# LOUDLY MEANS RED (BH-2263). Callers run the helpers inside $(...), where the
# die's `exit 1` ends only that subshell, and the suite read an empty path and
# could still exit 0. So the die also records itself in $T/.rendered/FAILED,
# and the EXIT trap this file installs forces a suite that would exit 0 to
# exit 1 (a suite's own nonzero code is kept). A suite that installs its OWN
# EXIT trap replaces that one, so its trap must call rendered_verdict, before
# it cleans up $T, and exit 1 when it fails.
#
# Each artifact is rendered ONCE per suite and reused: a render is a few hundred
# milliseconds and some suites want six boxes.

_rendered_dir() { printf '%s' "$T/.rendered"; }

_rendered_die() {
  echo "FAIL: tests/lib/rendered.sh: $1" >&2
  echo "FAIL: these files are GENERATED (BH-1247); the suite cannot continue without them." >&2
  { mkdir -p "$(_rendered_dir)" && printf '%s\n' "$1" >> "$(_rendered_dir)/FAILED"; } 2>/dev/null
  exit 1
}

# rendered_verdict — 0 when no helper has died in this suite, else 1 with the
# recorded failures on stderr.
rendered_verdict() {
  local f="${T:-}/.rendered/FAILED"
  [ -n "${T:-}" ] && [ -s "$f" ] || return 0
  echo "FAIL: tests/lib/rendered.sh: $(wc -l < "$f") helper failure(s) inside a subshell, suite forced red:" >&2
  sed 's/^/FAIL:   /' "$f" >&2
  return 1
}

# Replaces scratch.sh's EXIT trap and chains to it. The verdict is read BEFORE
# the cleanup, which deletes $T and the marker with it. Owner-guarded like
# scratch.sh's, so a forked subshell that inherits it does nothing.
__rendered_exit_trap() {
  local rc=$?
  [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
  rendered_verdict || { [ "$rc" -eq 0 ] && rc=1; }
  __scratch_exit_trap
  exit "$rc"
}
trap __rendered_exit_trap EXIT

# rendered_registry — catalog/lanes.json, composed from catalog/lanes.d/.
rendered_registry() {
  local d out
  d=$(_rendered_dir); out="$d/lanes.json"
  [ -s "$out" ] && { printf '%s' "$out"; return 0; }
  mkdir -p "$d" || _rendered_die "cannot create $d"
  "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$out" >/dev/null 2>&1 \
    || _rendered_die "bin/lanes-build.sh could not compose catalog/lanes.json from $DIR/catalog/lanes.d"
  [ -s "$out" ] || _rendered_die "bin/lanes-build.sh composed an empty registry"
  printf '%s' "$out"
}

# rendered_cron <box> — cron/<box>.cron, as the box would install it.
rendered_cron() {
  local box="${1:-}" d out
  [ -n "$box" ] || _rendered_die "rendered_cron needs a box id"
  d=$(_rendered_dir); out="$d/$box.cron"
  [ -s "$out" ] && { printf '%s' "$out"; return 0; }
  mkdir -p "$d" || _rendered_die "cannot create $d"
  "$DIR/bin/render-cron.sh" --root "$DIR" "$box" > "$out" 2>"$d/$box.err" \
    || _rendered_die "bin/render-cron.sh $box failed: $(head -3 "$d/$box.err" | tr '\n' ' ')"
  [ -s "$out" ] || _rendered_die "bin/render-cron.sh $box rendered an EMPTY crontab"
  printf '%s' "$out"
}

# rendered_env — env-templates/global.env.example, from env-templates/lanes/.
rendered_env() {
  local d out
  d=$(_rendered_dir); out="$d/global.env.example"
  [ -s "$out" ] && { printf '%s' "$out"; return 0; }
  mkdir -p "$d" || _rendered_die "cannot create $d"
  "$DIR/bin/render-env-example.sh" --root "$DIR" --to "$out" >/dev/null 2>&1 \
    || _rendered_die "bin/render-env-example.sh could not render the env template"
  [ -s "$out" ] || _rendered_die "bin/render-env-example.sh rendered an empty template"
  printf '%s' "$out"
}

# rendered_boxes — the fleet's box ids, from the COMMITTED cron/boxes/<box>.d,
# which is where bin/render-cron.sh --all gets them too. Globbing the rendered
# cron/*.cron would be empty in a fresh checkout and a suite looping over it
# would pass having asserted nothing.
rendered_boxes() {
  local dd n=0
  for dd in "$DIR"/cron/boxes/*.d; do
    [ -d "$dd" ] || continue
    # cron/boxes/_template.d is not a box (BH-5650); bin/render-cron.sh --all skips it too.
    case "$(basename "$dd")" in _*) continue ;; esac
    basename "$dd" .d; n=$((n+1))
  done
  [ "$n" -gt 0 ] || _rendered_die "no cron/boxes/<box>.d — there is no fleet to render"
}

# rendered_cron_dir — a directory holding EVERY box's cron/<box>.cron, for the
# suites that glob the fleet (`"$(rendered_cron_dir)"/*.cron`) rather than name
# one box. Rendered once per suite.
#
# It must never print a directory it did not fill: a glob over an empty dir
# expands to the literal pattern, and a `grep -ho ... /nope/*.cron` then finds
# nothing and reports the fleet as having no lanes — a vacuous pass, which is
# what several of these suites explicitly guard against.
rendered_cron_dir() {
  local d box n=0
  d="$(_rendered_dir)/fleet"
  if [ -d "$d" ] && [ -n "$(ls -1 "$d"/*.cron 2>/dev/null)" ]; then printf '%s' "$d"; return 0; fi
  mkdir -p "$d" || _rendered_die "cannot create $d"
  "$DIR/bin/render-cron.sh" --root "$DIR" --out-dir "$d" >/dev/null 2>&1 \
    || _rendered_die "bin/render-cron.sh --out-dir could not render the fleet"
  for box in "$d"/*.cron; do [ -f "$box" ] && n=$((n+1)); done
  [ "$n" -gt 0 ] || _rendered_die "bin/render-cron.sh --out-dir rendered no crontabs"
  printf '%s' "$d"
}
