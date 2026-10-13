#!/bin/bash
# bin/render-cron.sh [--root <dir>] <box-id>
#
# Print cron/<box-id>.cron from the LANE REGISTRY plus one file per lane.
#
# WHY THIS EXISTS (BH-1178). cron/<box>.cron was ten hand-maintained monoliths
# that every new lane appended to at the same place. In the last 200 merges
# cron/hub.cron alone was touched by 6, and two branches adding two different
# lanes conflicted every time even though they had nothing to say to each
# other. Adding a lane is now one registry entry (catalog/lanes.json, which
# says WHICH boxes run it) plus one file (cron/lanes/<NNN>-<id>.cron, which
# says what the line is). Two branches adding two lanes touch two files.
#
# THE INPUTS
#
#   catalog/lanes.json        .lanes[] .id, .boxes[] — membership, per box.
#   cron/lanes/<NNN>-<id>.cron   one lane's crontab text, verbatim. <NNN> is
#                             the fleet-wide order; <id> is the registry id.
#   cron/boxes/<box>.d/<NNN>-<slug>.cron   this box's own lines — @reboot, the
#                             SHELL=, a note, the fleet-managed placeholder.
#                             Never a registered lane.
#   cron/boxes/<box>.order    `<lane-id> <NNN>` per line: this box runs that
#                             lane somewhere other than its fleet-wide spot.
#
# A FRAGMENT'S FORMAT is its crontab text with `# @` directives at column 0:
#
#   # @hub-lanes              this section's lines belong inside a hub-lanes
#                             block (the renderer coalesces adjacent ones).
#   # @ungated <why>          this section is a hub-scoped lane that runs on
#                             EVERY box holding the file, on purpose. One of
#                             the two is REQUIRED on a hub-scoped lane: a hub
#                             lane that simply forgot `# @hub-lanes` renders
#                             with no lease check and fires on every box at
#                             once, and nothing downstream says so — only
#                             tests/hub-cron-gated-test.sh catches it, after
#                             the crontab is already committed. THE REASON IS
#                             REQUIRED TOO: a bare `# @ungated` refuses the
#                             render by file:line (BH-1185). The directive's
#                             whole job is to say why this lane fires on every
#                             box, and the reason is what a reviewer reads; bare,
#                             it is a typo that reads as a decision.
#   # @fleet-managed          emit the fleet-managed marker pair here, so
#                             render-crontab.sh splices the project blocks at
#                             this position rather than at the end. A box whose
#                             fragments carry no such directive (hub,
#                             project-10 — neither has a fleet.conf row)
#                             gets them appended, which is what
#                             render-crontab.sh does for a marker-less file
#                             today. Give such a box a placeholder fragment
#                             when it takes its first project.
#   # @box <box-id>           start this box's variant. Lines above the first
#                             `# @box` are the default every other box gets; a
#                             lane with a variant for THIS box uses only that.
#
# Everything else is body, emitted byte for byte, except for TWO substitutions.
# A `#` comment that is not a directive is body like any other.
#
#   @BOX@        the box id. It exists so the two lanes that take the box as an
#                argument (extra-usage-track, cost-rows-push) are one file
#                rather than ten.
#   @WATCHDOG@   the name this box pings the watchdog with, from
#                cron_watchdog_name_for in bin/lib/cron-lines.sh — the fleet.conf
#                box column of the first project on this box, machine generation
#                and all. It exists so the watchdog lane is ONE line rather than
#                ten, and so a new box needs a fleet.conf row and a registry
#                entry, never a fragment edit (BH-1185). Before it, the ping
#                lane's default line carried no `# @box` header, so a box newly
#                added to the lane's .boxes silently pinged under project-4's name.
#                A box the registry cannot name REFUSES the render: a ping under
#                the wrong name is, at the watchdog, a box that is down.
#                Resolution is LAZY — a box with no fleet.conf row that runs no
#                lane using the placeholder (project-10) renders as before.
#
# TWO MORE REFUSALS, both BH-1185, both about a crontab that is green everywhere
# and still wrong:
#
#   DUPLICATE LINE. Two fragments emitting the SAME schedule line for one box
#   refuse the render, naming the box, the line and both fragments. Each
#   fragment is exactly what its author wrote, the registry is consistent, every
#   --check is green — and the box runs that lane twice, every tick, forever.
#   The comparison is over the expanded text, across lane fragments and
#   cron/boxes/<box>.d together, and BEFORE render-crontab.sh's hub-lease prefix.
#   A `# @box` variant REPLACES its default, so a variant equal to its own
#   default is not a duplicate and does not refuse.
#
#   A MANAGED SCRIPT FOR A PROJECT THE BOX DOES NOT OWN. A cron/boxes/<box>.d
#   line invoking one of cron_managed_scripts with a project fleet.conf does not
#   put on this box refuses, by file:line and project name. render-crontab.sh
#   absorbs such a line into the managed block when the box OWNS the project —
#   that is the migration path off the hand-maintained files and is unchanged —
#   but a FOREIGN project has no block to be absorbed into, so the line is
#   preserved verbatim as "the operator's" and the box quietly runs a lane for a
#   project (or a parked one) with no registry row and no switch. Scripts
#   deliberately outside the managed set (security-scan and kin, see
#   bin/lib/cron-lines.sh) take a project argument and are NOT refused.
#
# THE OUTPUT goes through bin/render-crontab.sh, which owns the fleet-managed
# project blocks (fleet.conf) and the hub-lease gate. This script never writes
# those two things itself: one renderer per concern, and the crontab a box
# installs is still produced by exactly the script that produced it before.
#
# AND THE OUTPUT IS NOT COMMITTED (BH-1247). BH-1178 left the ten rendered
# crontabs in git, which made each of them a shared mutable cell: a PR that
# edited a lane and did not re-render turned red, and once such a PR merged
# every OTHER open PR inherited the red on a crontab its ticket never mentioned.
# Three merge trains died that way on 2026-09-21 (#1241, #1257, #1263). Same
# doctrine as BH-1175's docs/verification-map/README.md — take the contested
# cell out of git rather than resolve it.
#
# So cron/<box>.cron is git-ignored and rendered on the box, at install time, by
# whatever is about to install it (bin/render-crontab.sh resolves its base
# through this script, and bin/update-runners.sh, bin/bootstrap-machine.sh and
# bin/fleet-propagate.sh all install through that). bin/render-diff.sh is what
# puts the reviewable diff back into a PR.
#
# THE BOX LIST therefore comes from cron/boxes/<box>.d — the box's OWN committed
# fragments — and no longer from the rendered cron/*.cron it used to glob. A
# list derived from the artifact would be empty in a fresh checkout, and `--all`
# would report success having rendered nothing.
#
# `--all` rewrites every cron/<box>.cron from its fragments instead of printing
# one; that is what the `## Generated files` table in
# docs/verification-map/index/tail.md calls, and what to run after editing a
# fragment. `--out-dir <dir>` puts the same set somewhere else (what
# bin/render-diff.sh renders two revisions into). `--check` proves the sources
# render, and render DETERMINISTICALLY, and that no crontab is tracked in git;
# `--check-committed` is the OLD byte comparison, for a repo that still commits
# them. Neither repairs anything — a check that fixes what it was asked to
# report makes the drift invisible, which is the one thing CI's step must not do.
#
# rc 0 with the crontab on stdout. Any failure exits non-zero with an EMPTY
# stdout — a half-rendered crontab is a crontab nobody wrote.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BOX=""; ALL=0; CHECK=0; CHECK_COMMITTED=0; OUT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="$2"; shift 2 ;;
    --all)     ALL=1; shift ;;
    --out-dir) ALL=1; OUT_DIR="$2"; shift 2 ;;
    --check)   ALL=1; CHECK=1; shift ;;
    --check-committed) ALL=1; CHECK=1; CHECK_COMMITTED=1; shift ;;
    # The range is DERIVED: awk stops at the first non-comment line, so a
    # paragraph added to this header is printed rather than silently cut
    # (the literal range in render-crontab.sh grew stale twice).
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --*)       echo "render-cron.sh: unknown flag $1" >&2; exit 2 ;;
    *)         [ -z "$BOX" ] && BOX="$1" || { echo "render-cron.sh: unexpected argument $1" >&2; exit 2; }; shift ;;
  esac
done

# --all rewrites every cron/<box>.cron in place — the form the `## Generated
# files` table calls, and the one to run after editing a fragment. Every box
# renders to a temp file FIRST and nothing is moved until all of them
# succeeded: a half-written set is a fleet where some boxes got the change.
if [ "$ALL" = 1 ]; then
  [ -z "$BOX" ] || { echo "render-cron.sh: --all, --out-dir and --check take no box argument" >&2; exit 2; }
  OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
  # THE BOX LIST IS cron/boxes/<box>.d, not the rendered cron/*.cron (BH-1247).
  # Every box in the fleet has a fragment directory of its own — at minimum the
  # fleet-managed placeholder — and that directory is COMMITTED, so this list
  # survives a fresh checkout where the renders do not exist yet.
  # A directory whose name starts with `_` is not a box: cron/boxes/_template.d
  # (BH-5650) is what a box with no directory of its own renders from.
  BOXES=""
  for DD in "$ROOT"/cron/boxes/*.d; do
    [ -d "$DD" ] || continue
    B=$(basename "$DD" .d)
    case "$B" in _*) continue ;; esac
    BOXES="$BOXES $B"
  done
  [ -n "${BOXES// /}" ] || { echo "render-cron.sh: found no cron/boxes/<box>.d — there is no fleet to render" >&2; exit 1; }
  for B in $BOXES; do
    "$0" --root "$ROOT" "$B" > "$OUT/$B" || { echo "render-cron.sh: --all failed on box $B; nothing was written" >&2; exit 1; }
    [ -s "$OUT/$B" ] || { echo "render-cron.sh: --all rendered an EMPTY crontab for box $B; nothing was written" >&2; exit 1; }
  done
  if [ "$CHECK" = 1 ] && [ "$CHECK_COMMITTED" = 1 ]; then
    # The OLD byte comparison, for a repo or a lane that still has committed
    # crontabs to compare against. cromford itself reaches this only
    # through tests/registry-no-commit-test.sh.
    DRIFT=""
    for B in $BOXES; do
      cmp -s "$OUT/$B" "$ROOT/cron/$B.cron" || DRIFT="$DRIFT $B"
    done
    if [ -n "${DRIFT// /}" ]; then
      for B in $DRIFT; do
        echo "render-cron.sh: cron/$B.cron does not match its fragments (committed vs rendered):" >&2
        diff -u "$ROOT/cron/$B.cron" "$OUT/$B" 2>/dev/null | head -30 >&2
      done
      echo "render-cron.sh: run bin/render-cron.sh --all and commit the result." >&2
      exit 1
    fi
    echo "render-cron.sh: every cron/<box>.cron is in sync ($(printf '%s' "$BOXES" | wc -w | tr -d ' ') boxes)"
    exit 0
  fi
  if [ "$CHECK" = 1 ]; then
    # THE FRAGMENTS ARE WHAT IS COMMITTED, so they are what is checked, and
    # nothing below writes into the tree.
    BAD=0
    # 1. deterministic: a second render of the same fragments must be the same
    #    bytes, for every box. This is what the byte comparison stood in for.
    OUT2=$(mktemp -d)
    for B in $BOXES; do
      if ! "$0" --root "$ROOT" "$B" > "$OUT2/$B" 2>/dev/null; then
        echo "render-cron.sh: the second render of box $B FAILED" >&2; BAD=1; continue
      fi
      cmp -s "$OUT/$B" "$OUT2/$B" || {
        echo "render-cron.sh: box $B does not render to the same bytes twice:" >&2
        diff -u "$OUT/$B" "$OUT2/$B" 2>/dev/null | head -20 >&2
        BAD=1; }
    done
    rm -rf "$OUT2"
    # 2. a TRACKED crontab, full stop — and not "tracked AND ignored": a PR that
    #    drops the ignore line and force-adds the render must not be able to
    #    switch its own gate off (BH-1175's wording).
    if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      TRACKED=""
      for B in $BOXES; do
        [ -n "$(git -C "$ROOT" ls-files -- "cron/$B.cron" 2>/dev/null)" ] && TRACKED="$TRACKED cron/$B.cron"
      done
      if [ -n "${TRACKED// /}" ]; then
        echo "render-cron.sh: these crontabs are TRACKED in git. They are GENERATED and must not be committed (BH-1247):$TRACKED" >&2
        echo "render-cron.sh:   git rm --cached$TRACKED   — the sources are cron/lanes/, cron/boxes/ and catalog/lanes.d/" >&2
        for P in $TRACKED; do
          git -C "$ROOT" check-ignore -q --no-index -- "$P" 2>/dev/null \
            || echo "render-cron.sh:   and .gitignore no longer covers $P — restore that line too" >&2
        done
        BAD=1
      fi
    fi
    [ "$BAD" = 0 ] || { echo "render-cron.sh: the sources are cron/lanes/ and cron/boxes/ — the crontabs are generated and ignored." >&2; exit 1; }
    echo "render-cron.sh: every box renders, deterministically ($(printf '%s' "$BOXES" | wc -w | tr -d ' ') boxes); cron/<box>.cron is generated, not committed"
    exit 0
  fi
  if [ -n "$OUT_DIR" ]; then
    mkdir -p "$OUT_DIR" || { echo "render-cron.sh: cannot create $OUT_DIR" >&2; exit 1; }
    for B in $BOXES; do cp "$OUT/$B" "$OUT_DIR/$B.cron"; done
    echo "render-cron.sh: wrote$BOXES into $OUT_DIR"
    exit 0
  fi
  for B in $BOXES; do cp "$OUT/$B" "$ROOT/cron/$B.cron"; done
  echo "render-cron.sh: wrote$BOXES"
  exit 0
fi
[ -n "$BOX" ] || { echo "usage: render-cron.sh [--root dir] <box-id> | --all" >&2; exit 2; }
# cron/boxes/_template.d is a template, never a box (BH-5650).
case "$BOX" in _*) echo "render-cron.sh: $BOX is not a box id: cron/boxes/_*.d is a template" >&2; exit 2 ;; esac

# The registry is GENERATED and no longer committed (BH-1247), so it is
# resolved through the ONE loader, which renders it from catalog/lanes.d/ when
# it is missing or stale. LANE_REGISTRY still wins, unchanged.
# shellcheck source=bin/lib/lanes-registry.sh
. "$HERE/lib/lanes-registry.sh"
REG=$(lanes_json_path "$ROOT") || { echo "render-cron.sh: no lane registry, and none could be rendered from $ROOT/catalog/lanes.d" >&2; exit 1; }
[ -f "$REG" ] || { echo "render-cron.sh: no lane registry at $REG" >&2; exit 1; }
LANES_D="$ROOT/cron/lanes"
BOXES_D="$ROOT/cron/boxes"
[ -d "$LANES_D" ] || { echo "render-cron.sh: no $LANES_D" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# REGISTRY_SOURCE=db (BH-5649): lane membership from the D1 registry's
# .lane_boxes overlays the file .boxes. A lane with registry rows takes them. A
# lane in the registry's .known_lanes (every lane the audit ever held a row
# for, BH-5650) with no rows left was drained, and gets zero boxes. Any other
# lane (one a PR added after the seed) keeps its file .boxes, so the registry
# can never drop a lane it has never heard of. A failed overlay keeps the file
# registry: the render never fails on the DB.
RJ=""
if [ "${REGISTRY_SOURCE:-file}" = db ]; then
  # shellcheck source=bin/lib/registry.sh
  if . "$HERE/lib/registry.sh" 2>/dev/null && RJ=$(HARNESS="${HARNESS:-/root/harness}" registry_json_path 2>/dev/null); then
    if jq --slurpfile r "$RJ" '($r[0].lane_boxes | group_by(.lane) | map({key: .[0].lane, value: map(.box_id)}) | from_entries) as $m
        | (($r[0].known_lanes // []) | map({key: ., value: true}) | from_entries) as $k
        | .lanes |= map(if $m[.id] then .boxes = $m[.id] elif $k[.id] then .boxes = [] else . end)' "$REG" > "$TMP/lanes.json" 2>/dev/null && [ -s "$TMP/lanes.json" ]; then
      REG="$TMP/lanes.json"
    else
      echo "render-cron.sh: the registry lane overlay failed; rendering from $REG" >&2
    fi
  fi
fi

# The box's first fleet.conf project, used only to NAME the marker pair that
# tells render-crontab.sh where the project blocks go. It drops every pair and
# splices all of them at the first one, so the name is a position, not a list.
# shellcheck source=bin/lib/cron-lines.sh
. "$HERE/lib/cron-lines.sh"
# rf_fragments is the repo's ONE spelling of "list a fragment directory": it
# sorts under LC_ALL=C (so the render does not depend on the operator's locale)
# and REFUSES a CR byte. A CRLF fragment otherwise renders rc 0 with the \r
# inside the crontab line, cron hands bash a redirect target `1\r`, the lane
# fails every tick — and every --check stays green, because the committed
# crontab was rendered from the same bytes.
# shellcheck source=bin/lib/render-fragments.sh
. "$HERE/lib/render-fragments.sh"
FLEET_CONF="$ROOT/fleet.conf"; export FLEET_CONF
# OWNED is the same pass, kept going: every project fleet.conf puts on this box,
# space-delimited and space-padded so a membership test is a substring test. It
# is what says whether a cron/boxes/<box>.d line naming a managed script is this
# box's lane or somebody else's.
FIRST_PROJ=""; OWNED=""
while read -r P; do
  [ -n "$P" ] || continue
  B=$("$HERE/box-for.sh" "$P" 2>/dev/null) || continue
  [ "$(cron_box_id_for "$B")" = "$BOX" ] || continue
  [ -n "$FIRST_PROJ" ] || FIRST_PROJ="$P"
  OWNED="$OWNED $P"
done < <("$HERE/fleet-conf.sh" --projects)

# The name this box pings the watchdog with, for @WATCHDOG@. Resolution is LAZY:
# an empty answer is only fatal in the fragment that actually uses the
# placeholder (below), so a box with no fleet.conf row that runs no such lane
# renders exactly as it did.
WD=$(cron_watchdog_name_for "$BOX" 2>/dev/null) || WD=""
# A box with no project yet (one bin/registry.sh add-box just made) has no
# fleet.conf row to name it. In db mode the registry's boxes row does.
if [ -z "$WD" ] && [ -n "$RJ" ]; then
  WD=$(jq -r --arg b "$BOX" '[.boxes[]? | select(.box_id == $b) | .box][0] // empty' "$RJ" 2>/dev/null) || WD=""
fi

# ---- 1. which lanes does the registry give this box? ------------------------
# Two classes of registry lane are NOT rendered from a fragment, and each is
# excluded for a stated reason rather than by being forgotten:
#
#   - the seven per-project lanes of the fleet-managed block (run-triage,
#     run-product, healthcheck, apply-migrations, merge-queue, deploy-train,
#     review-prs). bin/lib/cron-lines.sh owns those, keyed on fleet.conf's
#     per-project minute offset; their registry cadence is the LIST of offsets
#     in use, not one schedule.
#   - a lane another lane schedules, which the registry writes as a cadence
#     naming its caller (fly-pool: "*/10 * * * * (via bin/fly-pool-tick.sh)").
#     It is registered because it spends and needs a kill switch; it has no
#     crontab line of its own to render.
#
# Everything left must have a cadence AND a fragment. A lane with no cadence is
# a registry row nobody can schedule — rendering it would put a command where a
# schedule goes — so it fails the render by name. A lane whose cadence is a
# semicolon-separated LIST runs on a different minute per box or per project;
# the fragment carries the per-box lines and the registry carries the set.
MANAGED=$(cron_managed_scripts)
jq -er --arg b "$BOX" --arg managed "$MANAGED" '
  ($managed | split("|")) as $m
  | [ .lanes[] | select(.boxes // [] | index($b)) | select(.id as $i | $m | index($i) | not) ] as $l
  | ($l | map(select((.cadence // "") == "")) | map(.id)) as $nocad
  | if ($nocad | length) > 0
    then ("lanes with no cadence: " + ($nocad | join(" "))) | halt_error(1)
    else ($l
          | map(select(.cadence | test("\\(via ") | not))
          | map(.id) | .[]) end' "$REG" > "$TMP/box-lanes" 2>"$TMP/err" || {
  # `jq -e` answers rc 1 on an EMPTY result and writes nothing to stderr, so an
  # unknown box used to refuse with a blank reason. The two failures are
  # different mistakes — a typo'd box id, and a registry that named a lane it
  # could not schedule — and each now says which it is. In db mode a box with a
  # registry boxes row and no lane is not a typo: bin/registry.sh drain-box
  # emptied it (BH-5650), and it renders its box fragments with no lane line.
  if [ -s "$TMP/err" ]; then echo "render-cron.sh: $BOX: $(cat "$TMP/err")" >&2; exit 1
  elif [ -n "$RJ" ] && jq -e --arg b "$BOX" 'any(.boxes[]?; .box_id == $b)' "$RJ" >/dev/null 2>&1; then
    : > "$TMP/box-lanes"
  else echo "render-cron.sh: $BOX: no registry lane lists this box in .boxes — is the box id right? (read from $REG)" >&2; exit 1; fi
}

# ---- 2. the ordered fragment list -------------------------------------------
# `<order>\t<path>\t<lane-id-or-empty>`, numerically sorted. A lane the registry
# does not give this box is skipped here and nowhere else.
: > "$TMP/plan"
LANE_LIST=$(rf_fragments "$LANES_D" '*.cron') || { echo "render-cron.sh: $BOX: $LANES_D was refused" >&2; exit 1; }
while IFS= read -r F; do
  [ -n "$F" ] || continue
  BN=$(basename "$F" .cron)
  N=${BN%%-*}; ID=${BN#*-}
  case "$N" in ''|*[!0-9]*) echo "render-cron.sh: $F: filename must be <NNN>-<lane-id>.cron" >&2; exit 1 ;; esac
  grep -qxF "$ID" "$TMP/box-lanes" || continue
  if [ -f "$BOXES_D/$BOX.order" ]; then
    OV=$(awk -v i="$ID" '$1==i {print $2}' "$BOXES_D/$BOX.order")
    [ -n "$OV" ] && N=$OV
  fi
  printf '%s\t%s\t%s\n' "$N" "$F" "$ID" >> "$TMP/plan"
done <<<"$LANE_LIST"
# A box with no fragments of its own is normal (most boxes have only the
# fleet-managed placeholder), so a missing directory is not an error here — but
# a directory that EXISTS is listed through the same refusal. A box with no
# directory renders from cron/boxes/_template.d (BH-5650): the PATH line and the
# fleet-managed placeholder every plain box carries, so a box that
# bin/registry.sh add-box made needs no commit to render.
BOX_DIR=""
if [ -d "$BOXES_D/$BOX.d" ]; then BOX_DIR="$BOXES_D/$BOX.d"
elif [ -d "$BOXES_D/_template.d" ]; then BOX_DIR="$BOXES_D/_template.d"
fi
if [ -n "$BOX_DIR" ]; then
  BOX_LIST=$(rf_fragments "$BOX_DIR" '*.cron') || { echo "render-cron.sh: $BOX: $BOX_DIR was refused" >&2; exit 1; }
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    BN=$(basename "$F" .cron); N=${BN%%-*}
    case "$N" in ''|*[!0-9]*) echo "render-cron.sh: $F: filename must be <NNN>-<slug>.cron" >&2; exit 1 ;; esac
    # A managed script here is only legal for a project this box OWNS, where
    # render-crontab.sh absorbs the line into that project's block. For a
    # foreign project there is no block, the line is preserved verbatim as the
    # operator's, and the box runs a lane nothing in the registry can switch off.
    FOREIGN=$(awk -v scripts="$MANAGED" -v owned=" $OWNED " '
      /^[ \t]*#/ { next }
      match($0, "/root/harness/bin/(" scripts ")\\.sh[ \t]+[^ \t]+") {
        seg = substr($0, RSTART, RLENGTH)
        sub(/^.*\.sh[ \t]+/, "", seg)
        if (index(owned, " " seg " ") == 0) print FNR "\t" seg
      }' "$F")
    if [ -n "$FOREIGN" ]; then
      while IFS=$'\t' read -r LN PRJ; do
        [ -n "$LN" ] || continue
        echo "render-cron.sh: $BOX: ${F#"$ROOT"/}:$LN invokes a managed script for project '$PRJ', which fleet.conf does not assign to this box — a managed lane for a project the box does not own has no registry row and no switch; give the project a fleet.conf row on this box or drop the line" >&2
      done <<<"$FOREIGN"
      exit 1
    fi
    printf '%s\t%s\t\n' "$N" "$F" >> "$TMP/plan"
  done <<<"$BOX_LIST"
fi
[ -s "$TMP/plan" ] || { echo "render-cron.sh: no fragments apply to box $BOX" >&2; exit 1; }
LC_ALL=C sort -n -k1,1 -k2,2 "$TMP/plan" > "$TMP/plan.sorted"

# ---- 3. every lane the registry promised must have a fragment ---------------
# The registry saying a box runs a lane and the box having no line for it is the
# 2026-08-30 project-7 failure in the other direction: a lane that is registered,
# visible on the settings page, and never scheduled anywhere.
MISSING=$(comm -23 <(sort -u "$TMP/box-lanes") <(cut -f3 "$TMP/plan.sorted" | grep -v '^$' | sort -u) | tr '\n' ' ')
[ -z "${MISSING// /}" ] || { echo "render-cron.sh: $BOX: registry lanes with no cron/lanes fragment:$MISSING" >&2; exit 1; }

# ---- 4. emit each fragment's section for this box ---------------------------
# Output carries one sentinel per line class so the marker pass below can see
# where a hub-lanes run starts and stops without re-parsing shell:
#   H<tab><line>  a line that belongs inside a hub-lanes block
#   P<tab><line>  plain
#   F<tab>        the fleet-managed placeholder
SECT_AWK='
  BEGIN { want = (box == "") ? "" : box; sect = "default"; hub["default"] = 0; n = 0 }
  /^# @hub-lanes$/     { hub[sect] = 1; next }
  /^# @ungated[ \t]+[^ \t]/ { ung[sect] = 1; next }
  /^# @fleet-managed$/ { kind[sect, ++cnt[sect]] = "F"; text[sect, cnt[sect]] = ""; next }
  /^# @box / { sect = $3; if (!((sect) in cnt)) { cnt[sect] = 0; hub[sect] = 0 }; next }
  { kind[sect, ++cnt[sect]] = "L"; text[sect, cnt[sect]] = $0 }
  END {
    s = ((box SUBSEP 1) in kind || (box in cnt)) ? box : "default"
    if (!(s in cnt)) exit 0
    # gate mode answers WHICH declaration the chosen section carries, so the
    # caller can refuse a hub-scoped lane that carries neither. Same section
    # selection as the render — one reader, so the two cannot disagree.
    if (mode == "gate") {
      print (hub[s] ? "hub-lanes" : (ung[s] ? "ungated" : "none")); exit 0
    }
    for (i = 1; i <= cnt[s]; i++) {
      if (kind[s, i] == "F") { print "F\t"; continue }
      t = text[s, i]
      if (t ~ /@WATCHDOG@/) {
        if (wd == "") {
          printf "render-cron.sh: %s: %s: @WATCHDOG@, but fleet.conf names no box whose id is \"%s\" (and it is not hub) — a ping under the wrong name is, at the watchdog, a box that is down\n", box, frag, box > "/dev/stderr"
          exit 1
        }
        gsub(/@WATCHDOG@/, wd, t)
      }
      # Only a schedule line can be gated; a blank or a comment rides along with
      # whatever run it sits in, which is what keeps the marker where it was.
      gsub(/@BOX@/, box, t)
      if (hub[s] && t ~ /^[0-9*]/) print "H\t" t; else print "P\t" t
    }
  }'
# A BARE `# @ungated` is refused BEFORE anything is emitted, over every fragment
# that renders for this box — lane or boxes file, hub-scoped or not, because the
# directive is a typo wherever it is bare. It runs ahead of the gate check below
# so that a bare directive can never be counted as the declaration a hub lane
# owes: the reason is the declaration.
BARE_UNGATED=""
while IFS=$'\t' read -r _N F _ID; do
  while IFS= read -r HIT; do
    [ -n "$HIT" ] || continue
    echo "render-cron.sh: $BOX: ${F#"$ROOT"/}:${HIT%%:*}: '# @ungated' must carry a reason ('# @ungated <why>') — the reason is what a reviewer reads when this lane fires on every box" >&2
    BARE_UNGATED=1
  done < <(grep -nE '^# @ungated[[:space:]]*$' "$F" || :)
done < "$TMP/plan.sorted"
[ -z "$BARE_UNGATED" ] || exit 1

: > "$TMP/stream"
# <line>\t<fragment>, one record per EXPANDED schedule line, for the duplicate
# check below. The fragment path is last so a line containing a tab still
# compares whole.
: > "$TMP/sched"
UNGATED_HUB=""
while IFS=$'\t' read -r _N F ID; do
  # A hub-scoped lane must SAY whether it is gated. The three that legitimately
  # are not (poll-commands, claude-auth-check, heartbeat-reaper) declare
  # `# @ungated` with the reason; a fourth that just forgot the directive is
  # refused here rather than discovered by tests/hub-cron-gated-test.sh after
  # the crontab was committed and propagated.
  if [ -n "$ID" ] && [ "$(jq -r --arg i "$ID" '[.lanes[]|select(.id==$i)|.scope]|first // ""' "$REG")" = hub ]; then
    case "$(awk -v box="$BOX" -v mode=gate "$SECT_AWK" "$F")" in
      hub-lanes|ungated) ;;
      *) UNGATED_HUB="$UNGATED_HUB $ID" ;;
    esac
  fi
  # Each fragment's section is rendered on its own first, so the duplicate check
  # can say WHICH fragments collided, and so a refusal inside the awk never
  # half-fills the stream. Nothing has reached stdout at this point — the whole
  # render is assembled in $TMP — so an exit here leaves stdout EMPTY.
  awk -v box="$BOX" -v wd="$WD" -v frag="${F#"$ROOT"/}" "$SECT_AWK" "$F" > "$TMP/one" \
    || { echo "render-cron.sh: $BOX: ${F#"$ROOT"/} was refused; nothing was rendered" >&2; exit 1; }
  cat "$TMP/one" >> "$TMP/stream"
  awk -F'\t' -v f="${F#"$ROOT"/}" '
    $1 == "F" { next }
    { t = $0; sub(/^[^\t]*\t/, "", t); if (t ~ /^[0-9*@]/) print t "\t" f }' "$TMP/one" >> "$TMP/sched"
done < "$TMP/plan.sorted"
[ -z "${UNGATED_HUB// /}" ] || { echo "render-cron.sh: $BOX: hub-scoped lanes whose fragment declares neither '# @hub-lanes' nor '# @ungated <why>':$UNGATED_HUB — a hub lane with no lease check fires on every box at once" >&2; exit 1; }

# Two fragments emitting the same schedule line for one box: each is exactly
# what its author wrote, every check is green, and the box runs that lane twice
# every tick. Compared on the EXPANDED text and before render-crontab.sh's
# hub-lease prefix, which is the text cron will actually see modulo that gate.
DUP=$(sed 's/\t[^\t]*$//' "$TMP/sched" | LC_ALL=C sort | uniq -d)
if [ -n "$DUP" ]; then
  while IFS= read -r L; do
    [ -n "$L" ] || continue
    FRAGS=$(awk -F'\t' -v l="$L" '
      { t = $0; sub(/\t[^\t]*$/, "", t); if (t == l) { printf "%s%s", sep, $NF; sep = " " } }' "$TMP/sched")
    echo "render-cron.sh: $BOX: the same cron line is emitted by more than one fragment — '$L' from $FRAGS" >&2
  done <<<"$DUP"
  exit 1
fi

# ---- 5. hub-lanes markers, by coalescing adjacent gated lines ---------------
# BEGIN goes immediately before a run's FIRST schedule line and END immediately
# after its last, so a comment paragraph ABOVE a run stays outside the block and
# one BETWEEN two gated lines stays inside — which is exactly where the
# hand-maintained files had them. Blanks and comments neither open nor close a
# run: they are held until the next line says which side of the END they are on.
awk -F'\t' '
  function flush(   i) { for (i = 1; i <= h; i++) print hold[i]; h = 0 }
  function close_block() { if (inb) { print "# END hub-lanes"; inb = 0 }; flush() }
  BEGIN { h = 0; inb = 0 }
  { k = $1; sub(/^[^\t]*\t/, ""); t = $0 }
  k == "F" { close_block(); print "@@FLEET_MANAGED@@"; next }
  k == "H" { if (!inb) { flush(); print "# BEGIN hub-lanes"; inb = 1 } else flush()
             print t; next }
  # A schedule line, an @reboot or a VAR= assignment closes an open run; a blank
  # or a comment is held, so it lands after the END only if the run really ended.
  t ~ /^[0-9*@]/ || t ~ /^[A-Za-z_][A-Za-z0-9_]*=/ { close_block(); print t; next }
  { if (inb) { hold[++h] = t; next } print t }
  END { close_block() }
  ' "$TMP/stream" > "$TMP/base1"

if [ -n "$FIRST_PROJ" ]; then
  awk -v p="$FIRST_PROJ" '
    $0 == "@@FLEET_MANAGED@@" { print "# BEGIN fleet-managed project=" p
                                print "# END fleet-managed project=" p; next }
    { print }' "$TMP/base1" > "$TMP/base"
else
  grep -vxF '@@FLEET_MANAGED@@' "$TMP/base1" > "$TMP/base" || :
fi

# ---- 6. hand to the crontab renderer ----------------------------------------
# It owns the project blocks (fleet.conf) and the hub-lease prefix. Rendering a
# rendered file is a no-op, which is what makes cron/<box>.cron BE this output.
"$HERE/render-crontab.sh" --root "$ROOT" --base "$TMP/base" "$BOX"
