#!/bin/bash
# bin/lib/fc-linear.sh — the Linear lane module of the child filer
# (bin/lib/file-children.sh). It files one Linear sub-issue per child under the
# parent, in order, links each to the children it waits on with a `blocks`
# relation, then comments on the master and takes the build label off it.
# file_children sources it for a project whose tracker_adapter row is linear.
#
# ITS INPUTS ARE THE FC_* VARIABLES file_children SETS, never arguments:
# FC_PROJECT, FC_PARENT, FC_KEY (the parent's identifier, e.g. CRO-12),
# FC_BUILD, FC_SPEC (children.json, validated by the caller), FC_KIND
# (decompose|rollout), FC_LANE.
#
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source
# time, safe under `set -u`. A failure RETURNS 1 with its reason in FC_ERROR and
# one fc_log line.
#
# WHAT IT WRITES in $FC_BUILD:
#   children.txt          one identifier per filed child, append-only, written
#                         once the child AND its relations exist
#   decompose-linear.log  every write, the key as its variable NAME only
#   children/             child-<n>.md (the description) and comment.md
#
# THE ORDER IS THE RELATIONS. A child is created with the build label, so the
# triage tick lists it, and the children it waits on `block` it: a decompose
# sibling is blocked by the contract (and by any earlier sibling its `after`
# names), a rollout wave only by the waves its `after` names. bin/triage-gate.sh
# --buildable refuses a child while a blocker is not completed or canceled
# (trk_linear_gate_raw's `blocked`). So a sibling waits for the contract to be
# DONE — merged — not for its pull request to open, as on GitHub.
#
# NO DUPLICATES ON A RERUN. Linear takes a client id on create, so every child
# and every relation gets one derived from (build, parent, kind, position): a
# run killed between a create and its record finds the child by that id and
# adopts it instead of filing a second one on someone's workspace.

if ! command -v trk_linear_context >/dev/null 2>&1; then
  _fcl_d="$(dirname "${BASH_SOURCE[0]}")"
  if [ ! -r "$_fcl_d/tracker/linear.sh" ] && [ -n "${HARNESS:-${H:-}}" ]; then _fcl_d="${HARNESS:-${H:-}}/bin/lib"; fi
  if [ -r "$_fcl_d/tracker.sh" ] && [ -r "$_fcl_d/tracker/linear.sh" ]; then
    # shellcheck source=bin/lib/tracker.sh
    . "$_fcl_d/tracker.sh"
    # shellcheck source=bin/lib/tracker/linear.sh
    . "$_fcl_d/tracker/linear.sh"
  fi
  unset _fcl_d
fi

_fcl_fail() { FC_ERROR="$1"; fc_log "$FC_BUILD" "$FC_ERROR"; return 1; }

_fcl_append() {
  [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ] && printf '\n' >> "$1"
  printf '%s\n' "$2" >> "$1"
}

# _fcl_uuid <seed> — a version-4-shaped UUID that is the same for the same seed.
_fcl_uuid() {
  local h
  h=$(printf '%s' "$1" | sha256sum | cut -c1-32)
  printf '%s-%s-4%s-%s%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" \
    "$(printf '%s' "89ab" | cut -c$(( 0x${h:16:1} % 4 + 1 )))" "${h:17:3}" "${h:20:12}"
}

# _fcl_cid <n> — child n's id, the same on every run of this build.
_fcl_cid() { _fcl_uuid "fc-linear/$(basename "$FC_BUILD")/$FC_KEY/$FC_KIND/$1"; }

# _fcl_child <uuid> <title> <descfile> — create the child, or adopt the one an
# earlier run created under that id. Prints its identifier.
_fcl_child() {
  local d
  d=$(_trk_linear_gql 'mutation TrkChildCreate($in: IssueCreateInput!) { issueCreate(input: $in) { success issue { identifier } } }' \
    '{in: ({id: $id, teamId: $team, parentId: $parent, title: $title, description: $desc}
          + (if $label != "" then {labelIds: [$label]} else {} end)
          + (if $pri != "" then {priority: ($pri | tonumber)} else {} end))}' \
    --arg id "$1" --arg team "$_FCL_TEAM" --arg parent "$_FCL_PARENT" --arg title "$2" --rawfile desc "$3" \
    --arg label "$_FCL_LABEL" --arg pri "$_FCL_PRI" 2>/dev/null) \
    && printf '%s' "$d" | jq -re 'select(.issueCreate.success == true) | .issueCreate.issue.identifier // empty' 2>/dev/null && return 0
  d=$(_trk_linear_gql 'query TrkChildFind($id: String!) { issue(id: $id) { identifier parent { id } } }' '{id: $id}' --arg id "$1" 2>/dev/null) || return 1
  printf '%s' "$d" | jq -re --arg p "$_FCL_PARENT" '.issue | select(.parent.id == $p) | .identifier // empty' 2>/dev/null
}

# _fcl_blocks <uuid> <blocker uuid> <child uuid> — idempotent the same way. Ids,
# not identifiers: every child's id is _fcl_uuid of its position, known whether
# this run filed it or an earlier one did.
_fcl_blocks() {
  local d
  d=$(_trk_linear_gql 'mutation TrkRelate($in: IssueRelationCreateInput!) { issueRelationCreate(input: $in) { success } }' \
    '{in: {id: $id, issueId: $a, relatedIssueId: $b, type: "blocks"}}' --arg id "$1" --arg a "$2" --arg b "$3" 2>/dev/null) \
    && printf '%s' "$d" | jq -e '.issueRelationCreate.success == true' >/dev/null 2>&1 && return 0
  _trk_linear_gql 'query TrkRelFind($id: String!) { issueRelation(id: $id) { id } }' '{id: $id}' --arg id "$1" >/dev/null 2>&1
}

# fc_file_linear — files every child in FC_SPEC. 0 = filed (or a dry run),
# 1 = refused or failed, FC_ERROR says why.
fc_file_linear() {
  local DRY=0 N P d i n A p KEEP AFTERS TITLE CT BODY BLOCK DEPENDS CONTRACT="" DESC KEY U FILED_NEW=0 WORD _ei _eln=0 LI
  local EXISTING=() KEYS=() TITLES=() BLOCKERS=()
  local TRK_LOG="" TRK_DRY=0 _FCL_TEAM="" _FCL_PARENT="" _FCL_LABEL="" _FCL_PRI=""
  fc_dry && DRY=1
  FC_PROJECT="${FC_PROJECT:-}"; FC_PARENT="${FC_PARENT:-}"; FC_KEY="${FC_KEY:-}"
  FC_BUILD="${FC_BUILD:-}"; FC_SPEC="${FC_SPEC:-}"; FC_KIND="${FC_KIND:-decompose}"
  FC_ERROR=""
  if [ -s "$FC_BUILD/children.txt" ] && [ "$DRY" = 1 ]; then
    fc_log "$FC_BUILD" "already filed: $(paste -sd, "$FC_BUILD/children.txt") — nothing re-filed (dry run)"
    return 0
  fi
  # The record is read before anything is sent; every line is an identifier.
  if [ -s "$FC_BUILD/children.txt" ]; then
    while IFS= read -r _ei || [ -n "$_ei" ]; do
      _eln=$((_eln + 1))
      printf '%s\n' "$_ei" | grep -qE '^[A-Za-z]+-[0-9]+$' \
        || { _fcl_fail "children.txt line $_eln is not an issue key ('$_ei') — left as it was, resolve by hand"; return 1; }
      EXISTING+=("$_ei")
    done < "$FC_BUILD/children.txt"
  fi
  N=$(jq 'length' "$FC_SPEC" 2>/dev/null)
  case "${N:-}" in ''|*[!0-9]*) _fcl_fail "cannot read a child count from $FC_SPEC"; return 1 ;; esac
  [ "${#EXISTING[@]}" -le "$N" ] \
    || { _fcl_fail "children.txt records ${#EXISTING[@]} children but the spec has $N — left as it was, resolve by hand"; return 1; }

  command -v trk_linear_context >/dev/null 2>&1 \
    || { _fcl_fail "tracker adapter bin/lib/tracker/linear.sh not found — nothing filed"; return 1; }
  trk_linear_context "$FC_PROJECT" 2>/dev/null \
    || { _fcl_fail "the Linear context of $FC_PROJECT did not load (LINEAR_API_KEY, tracker_linear rows) — nothing filed"; return 1; }
  [[ "$FC_KEY" =~ ^([A-Z][A-Z0-9]*)-[0-9]+$ ]] && [ "${BASH_REMATCH[1]}" = "$TRK_LINEAR_TEAM" ] \
    || { _fcl_fail "parent '$FC_KEY' is not an issue of team $TRK_LINEAR_TEAM — nothing filed"; return 1; }
  mkdir -p "$FC_BUILD/children"
  TRK_LOG="$FC_BUILD/decompose-linear.log"; TRK_DRY="$DRY"
  : > "$TRK_LOG"

  # ---- the parent: its UUID, team and priority, and the build label ------
  if [ "$DRY" = 1 ]; then
    _FCL_PARENT="{parent of $FC_KEY}"
  else
    P=$(_trk_linear_gql 'query TrkParent($id: String!, $label: String!) { issue(id: $id) { id priority team { id key } } issueLabels(first: 50, filter: { name: { eqIgnoreCase: $label } }) { nodes { id name team { key } } } }' \
      '{id: $id, label: $label}' --arg id "$FC_KEY" --arg label "${TRK_LINEAR_LABEL:-ai-build}" 2>/dev/null) \
      || { _fcl_fail "could not read the parent $FC_KEY on Linear — nothing filed"; return 1; }
    _FCL_PARENT=$(printf '%s' "$P" | jq -r --arg t "$TRK_LINEAR_TEAM" '.issue | select(.team.key == $t) | .id // empty')
    _FCL_TEAM=$(printf '%s' "$P" | jq -r '.issue.team.id // empty')
    _FCL_PRI=$(printf '%s' "$P" | jq -r '.issue.priority // empty | tostring')
    [ "$_FCL_PRI" = 0 ] && _FCL_PRI=""
    _FCL_LABEL=$(printf '%s' "$P" | jq -r --arg t "$TRK_LINEAR_TEAM" \
      '[.issueLabels.nodes[]? | select(.team == null or .team.key == $t)] | if length == 1 then .[0].id else empty end')
    [ -n "$_FCL_PARENT" ] && [ -n "$_FCL_TEAM" ] \
      || { _fcl_fail "the parent $FC_KEY is not an issue of team $TRK_LINEAR_TEAM on Linear — nothing filed"; return 1; }
    # Without the label the triage tick never lists a child: refuse, file nothing.
    [ -n "$_FCL_LABEL" ] \
      || { _fcl_fail "Linear has no single label '${TRK_LINEAR_LABEL:-ai-build}' for team $TRK_LINEAR_TEAM — nothing filed"; return 1; }
  fi
  [ "$FC_KIND" = rollout ] \
    || CONTRACT=$(jq -r 'if ((.[0].contract? // "") | type) == "string" then (.[0].contract // "") else "" end' "$FC_SPEC" 2>/dev/null)

  # ---- the creates, in order ---------------------------------------------
  i=0
  while [ "$i" -lt "$N" ]; do
    n=$((i + 1))
    TITLE=$(jq -r --argjson i "$i" '.[$i].title' "$FC_SPEC")
    TITLES[n]="$TITLE"
    if [ -n "${EXISTING[$i]:-}" ]; then
      KEYS[n]="${EXISTING[$i]}"
      fc_log "$FC_BUILD" "child $n: already filed as ${KEYS[n]}"
      i=$n; continue
    fi
    BODY=$(jq -r --argjson i "$i" '.[$i].body' "$FC_SPEC")
    CT=$(fc_child_title "$FC_KIND" "$FC_KEY" "$i" "$TITLE")
    # `after` is 1-based positions (2, "2", "2:hard"); earlier positions only,
    # and a decompose sibling's contract (1) is seeded below.
    AFTERS=$(jq -r --argjson i "$i" '(.[$i].after // []) | .[] | tostring' "$FC_SPEC" 2>/dev/null)
    KEEP=""
    if [ "$FC_KIND" = rollout ] || [ "$i" != 0 ]; then
      while IFS= read -r A; do
        p=$(printf '%s' "${A%%:*}" | tr -d '[:space:]')
        case "$p" in ''|*[!0-9]*) continue ;; esac
        [ "$FC_KIND" != rollout ] && [ "$p" = 1 ] && continue
        if [ "$p" -lt 1 ] || [ "$p" -ge "$n" ]; then
          fc_log "$FC_BUILD" "child $n: dropped 'after: $A' — a child can only wait on one that lands before it"
        else
          case " $KEEP " in *" $p "*) ;; *) KEEP="$KEEP $p" ;; esac
        fi
      done <<<"$AFTERS"
    fi
    [ "$FC_KIND" != rollout ] && [ "$i" != 0 ] && KEEP="1$KEEP"
    BLOCKERS[n]="$KEEP"
    BLOCK=""; DEPENDS=""
    for p in $KEEP; do BLOCK="${BLOCK:+$BLOCK, }${KEYS[p]} (hard)"; done
    [ "$FC_KIND" != rollout ] && [ "$i" != 0 ] \
      && DEPENDS="DEPENDS: ${KEYS[1]} hard — this slice imports the contract ($CONTRACT)"
    DESC="$FC_BUILD/children/child-$n.md"
    { printf '%s\n\n' "$BODY"; fc_child_footer "$FC_KIND" "$FC_KEY" "$n" "$N" "$BLOCK" "$DEPENDS" "$CONTRACT"; } > "$DESC"
    U=$(_fcl_cid "$n")
    FILED_NEW=1
    _trk_linear_w issueCreate "parent=$FC_KEY title=$(_trk_sq "$CT") id=$U blocked-by=${BLOCK:-none}"
    if [ "$DRY" = 1 ]; then KEYS[n]="$FC_KEY.$n"; i=$n; continue; fi
    KEY=$(_fcl_child "$U" "$CT" "$DESC") && [ -n "$KEY" ] \
      || { _fcl_fail "create failed on child $n of $N — $((n - 1)) filed, the master is not parked"; return 1; }
    KEYS[n]="$KEY"
    for p in ${BLOCKERS[n]}; do
      _trk_linear_w issueRelationCreate "${KEYS[p]} blocks $KEY"
      _fcl_blocks "$(_fcl_uuid "fc-linear-rel/$U/$p")" "$(_fcl_cid "$p")" "$U" \
        || { _fcl_fail "child $n was filed as $KEY but ${KEYS[p]} could not be set to block it — not recorded, the rerun adopts it"; return 1; }
    done
    # Recorded once the child and its order exist: a run killed before this
    # line leaves a child the rerun adopts by its id.
    _fcl_append "$FC_BUILD/children.txt" "$KEY"
    fc_log "$FC_BUILD" "child $n of $N filed as $KEY"
    i=$n
  done

  # ---- park the master, LAST ---------------------------------------------
  if [ "$FILED_NEW" = 1 ]; then
    [ "$FC_KIND" = rollout ] && WORD=waves || WORD=parts
    LI=""
    for n in $(seq 1 "$N"); do LI="$LI$n. ${KEYS[n]}: ${TITLES[n]}"$'\n'; done
    printf 'We split this one into %s %s and filed each as a sub-issue. They are built in order, and this issue stays open as the master until they land.\n\n%s' \
      "$N" "$WORD" "$LI" > "$FC_BUILD/children/comment.md"
    if [ "$DRY" = 1 ]; then
      _trk_linear_w commentCreate "issue=$FC_KEY body=@$FC_BUILD/children/comment.md"
      _trk_linear_w issueRemoveLabel "issue=$FC_KEY label=${TRK_LINEAR_LABEL:-ai-build}"
      fc_log "$FC_BUILD" "DRY RUN: nothing was filed — the writes are in $TRK_LOG"
      return 0
    fi
    trk_linear_comment "$FC_KEY" "$FC_BUILD/children/comment.md" >/dev/null 2>&1 \
      || fc_log "$FC_BUILD" "WARN: children are filed but the comment did not post on the master $FC_KEY"
    # Off the list, so the master is not offered for a build of its own.
    d=0; trk_linear_label_remove "$FC_KEY" "${TRK_LINEAR_LABEL:-ai-build}" >/dev/null 2>&1 || d=$?
    case "$d" in
      0|44) fc_log "$FC_BUILD" "master $FC_KEY parked (label ${TRK_LINEAR_LABEL:-ai-build} off)" ;;
      *) fc_log "$FC_BUILD" "WARN: children are filed but the label could not be taken off the master $FC_KEY (rc $d)" ;;
    esac
    fc_log "$FC_BUILD" "filed into: $(paste -sd, "$FC_BUILD/children.txt")"
  else
    fc_log "$FC_BUILD" "already filed into: $(paste -sd, "$FC_BUILD/children.txt") — nothing re-filed, master not re-parked"
  fi
  return 0
}
